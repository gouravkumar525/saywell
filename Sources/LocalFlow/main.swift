import AppKit
import Foundation
import LocalFlowCore

let args = CommandLine.arguments

func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// CLI modes for testing individual pipeline stages without the UI.
if let text = argValue("--process") {
    print(TextProcessor().process(text))
    exit(0)
}

// Training data. `--db <path>` points at another database (e.g. a scratch copy).
if args.contains("--seed-demo-samples") || argValue("--export-training") != nil || argValue("--export-rejects") != nil {
    TrainingCLI.run(dbPath: argValue("--db"),
                    seedDemo: args.contains("--seed-demo-samples"),
                    trainingOut: argValue("--export-training"),
                    validSplit: Double(argValue("--valid-split") ?? "0.1") ?? 0.1,
                    rejectsOut: argValue("--export-rejects"))
}

if let path = argValue("--dump-prompts") {
    BenchCLI.dumpPrompts(path)
}

if let i = args.firstIndex(of: "--verify-model"), i + 2 < args.count {
    // --verify-model <repo> <dir>: check a model folder against the pinned manifest (B3, package.sh).
    guard let manifest = ModelManifest.pinned(for: args[i + 1]) else {
        print("no pinned manifest for \(args[i + 1])"); exit(2)
    }
    let errors = manifest.verify(directory: URL(fileURLWithPath: args[i + 2]))
    errors.forEach { print("✗ \($0)") }
    print(errors.isEmpty ? "✓ \(manifest.repo)@\(manifest.revision.prefix(8)) verified (\(manifest.files.count) files)" : "verification failed")
    exit(errors.isEmpty ? 0 : 1)
}

let cliEngine = CleanupEngine(rawValue: argValue("--engine") ?? "apple") ?? .apple
CLIEngine.modelOverride = argValue("--model")

if let i = args.firstIndex(of: "--gate"), i + 2 < args.count {
    BenchCLI.gate(base: args[i + 1], new: args[i + 2])
}

if args.contains("--bench-long") {
    // --bench-long [--engine X] [--words 50,200,500,1000,2000] [--level light]
    let sizes = (argValue("--words") ?? "50,200,500,1000,2000").split(separator: ",").compactMap { Int($0) }
    LongBenchCLI.run(engine: cliEngine, sizes: sizes,
                     level: CleanupLevel(rawValue: argValue("--level") ?? "light") ?? .light)
    RunLoop.main.run()
}

if let path = argValue("--simulate") {
    // --simulate <audio file> [--speed 1.0]: feed audio through the live recognizer path.
    SimulateCLI.run(url: URL(fileURLWithPath: path), speed: Double(argValue("--speed") ?? "1") ?? 1,
                    asr: argValue("--asr") ?? "sfspeech")
    RunLoop.main.run()
}

if let prefix = argValue("--dmg-background") {
    // Scripts/package.sh: the installer window's background.
    let ok = MainActor.assumeIsolated { DMGArt.write(prefix: prefix) }
    print(ok ? "wrote \(prefix).png and \(prefix)@2x.png" : "dmg-background: failed")
    exit(ok ? 0 : 1)
}

if let dir = argValue("--make-call") {
    NoteCLI.make(dir: dir)
}

if let dir = argValue("--note-test") {
    // --note-test <dir with mic.wav, system.wav> [--diarizer <verified model folder>]
    NoteCLI.run(dir: dir, diarizer: argValue("--diarizer"), engine: cliEngine)
    RunLoop.main.run()
}

if let dir = argValue("--make-asr-set") {
    ASRBenchCLI.makeSet(dir: dir)
}

if let i = args.firstIndex(of: "--score-asr"), i + 3 < args.count {
    ASRBenchCLI.score(dir: args[i + 1], results: args[i + 2], name: args[i + 3])
}

if let dir = argValue("--bench-asr") {
    // --bench-asr <dir> [--asr sfspeech|analyzer|parakeet|all]
    ASRBenchCLI.run(dir: dir, backend: argValue("--asr") ?? "all")
    RunLoop.main.run()
}

if let action = argValue("--control") {
    // Drives an app launched with --enable-test-control (toggle, undo, memory, engine:qwen3, level:full).
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.gourav.saywell.test"), object: action, userInfo: nil, deliverImmediately: true)
    exit(0)
}

if let i = args.firstIndex(of: "--test-window"), i + 2 < args.count {
    // --test-window <seconds> <out.txt>: a plain text view to dictate into (E2E tests).
    TestWindowCLI.run(seconds: Double(args[i + 1]) ?? 30, out: args[i + 2])
}

for flag in ["--bench", "--bench-apple"] {
    if let i = args.firstIndex(of: flag), i + 2 < args.count {
        BenchCLI.bench(args[i + 1], out: args[i + 2], engine: flag == "--bench-apple" ? .apple : cliEngine)
        RunLoop.main.run()
    }
}

if let i = args.firstIndex(of: "--vet") {
    BenchCLI.vet(Array(args[(i + 1)...]))
}

if let text = argValue("--clean") {
    // Rules + LLM, e.g. --clean "um hi" --app com.tinyspeck.slackmacgap --level full --engine qwen3
    CleanCLI.run(text: text, bundleID: argValue("--app"),
                 level: CleanupLevel(rawValue: argValue("--level") ?? "light") ?? .light,
                 engine: cliEngine)
    RunLoop.main.run()
}

if let path = argValue("--transcribe") {
    let url = URL(fileURLWithPath: path)
    TranscriptionCLI.run(url: url)   // exits when done
    RunLoop.main.run()
}

if let text = argValue("--inject") {
    let delay = Double(argValue("--delay") ?? "3") ?? 3
    print("Injecting into the frontmost app in \(Int(delay))s... switch to your target window.")
    if !TextInserter.hasAccessibilityPermission(promptIfNeeded: true) {
        print("WARNING: Accessibility permission not granted. Grant it in System Settings > Privacy & Security > Accessibility, then retry.")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        let context = ContextProvider.capture()
        print("target: \(context.appName) role=\(context.role ?? "-")")
        TextInserter.insert(text, context: context) { result in
            print("Inserted via \(result.method.rawValue).")
            exit(result.method == .clipboard ? 1 : 0)
        }
    }
    RunLoop.main.run()
}

if args.contains("--listen") {
    let seconds = Double(argValue("--listen") ?? "8") ?? 8
    ListenCLI.run(seconds: seconds)  // exits when done
    RunLoop.main.run()
}

if args.contains("--status") {
    PermissionStatus.printAll()
    exit(0)
}

// Default: run the full notch app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
