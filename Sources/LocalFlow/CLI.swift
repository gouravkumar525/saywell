import AVFoundation
import AppKit
import Foundation
import LocalFlowCore
import Speech

/// `--transcribe <file>`: run a recorded audio file through the recognizer and
/// the cleanup pipeline. Used to validate the pipeline without a live mic.
enum TranscriptionCLI {
    static func run(url: URL) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                FileHandle.standardError.write("Speech recognition not authorized (status \(status.rawValue)).\n".data(using: .utf8)!)
                exit(2)
            }
            FileTranscriber.transcribe(url: url) { result in
                switch result {
                case .success(let raw):
                    let clean = TextProcessor().process(raw)
                    print("RAW: \(raw)")
                    print("CLEAN: \(clean)")
                    exit(0)
                case .failure(let error):
                    FileHandle.standardError.write("Transcription failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }
}

/// `--clean <text>`: the rules + LLM cleanup path, with the style picked for `--app`.
enum CleanCLI {
    static func run(text: String, bundleID: String?, level: CleanupLevel, engine: CleanupEngine) {
        let style = AppStyle.forBundleID(bundleID)
        let processed = TextProcessor().process(text)
        let rules = style == .code ? CodeDictation.apply(processed) : processed
        print("RULES: \(rules)")
        print("MODEL: \(engine.rawValue), style=\(style.rawValue), level=\(level.rawValue)")
        CLIEngine.prepare(engine) { clean in
            let started = Date()
            let request = CleanupRequest(transcript: rules, style: style, level: level)
            clean(request) { output, reason in
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let verdict = output.map { CleanupPrompt.vet(output: $0, input: rules, level: level) }
                print("LLM (\(ms)ms, \(reason)): \(output ?? "-")")
                print("FINAL: \(verdict?.text ?? rules)\(verdict?.text == nil ? "  [fell back to rules: \(verdict?.reason ?? reason)]" : "")")
                exit(0)
            }
        }
    }
}

/// Gets one cleanup engine ready for a CLI run (loading a local model first)
/// and hands back a `clean` function. Generous timeouts: this is measurement.
enum CLIEngine {
    typealias Clean = (CleanupRequest, @escaping (String?, String) -> Void) -> Void
    private static let apple = CleanupClient()
    private static let mlx = MLXCleanupClient()

    /// `--model <repo or path>` overrides the engine's default model.
    static var modelOverride: String?
    static var timeout: TimeInterval = 30

    static func prepare(_ engine: CleanupEngine, then body: @escaping (@escaping Clean) -> Void) {
        guard engine.isLocal, let spec = modelOverride ?? engine.modelSpec(store: nil) else {
            body { apple.clean($0, timeout: timeout, onPartial: { _ in }, completion: $1) }
            return
        }
        let started = Date()
        FileHandle.standardError.write("loading \(spec)…\n".data(using: .utf8)!)
        mlx.load(engine, spec: spec) { ok in
            guard ok else {
                FileHandle.standardError.write("load failed: \(mlx.statusDescription)\n".data(using: .utf8)!)
                exit(1)
            }
            FileHandle.standardError.write(String(format: "loaded in %.1fs\n", Date().timeIntervalSince(started)).data(using: .utf8)!)
            body { mlx.clean($0, timeout: timeout, onPartial: { _ in }, completion: $1) }
        }
    }
}

/// `--listen <seconds>`: run live mic dictation for N seconds, then print the
/// raw and cleaned transcript. Validates the real streaming path.
enum ListenCLI {
    static func run(seconds: Double) {
        DictationEngine.requestPermissions { result in
            if case .failure(let error) = result {
                FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
                exit(2)
            }
            let engine = DictationEngine()
            engine.onPartial = { text in
                FileHandle.standardError.write("partial: \(text)\n".data(using: .utf8)!)
            }
            engine.onFinal = { raw in
                let clean = TextProcessor().process(raw)
                print("RAW: \(raw)")
                print("CLEAN: \(clean)")
                exit(0)
            }
            do {
                try engine.start()
                FileHandle.standardError.write("listening for \(seconds)s...\n".data(using: .utf8)!)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    engine.stop()
                }
                // Hard exit if no final ever arrives.
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 5) {
                    print("RAW: ")
                    print("CLEAN: ")
                    exit(0)
                }
            } catch {
                FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }
}

/// `--status`: print permission and capability status for diagnostics.
enum PermissionStatus {
    static func printAll() {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let ax = TextInserter.hasAccessibilityPermission()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
        print("speech-recognition: \(name(for: speech.rawValue))")
        print("microphone: \(name(for: mic.rawValue))")
        print("accessibility: \(ax ? "granted" : "not granted")")
        print("recognizer-available: \(recognizer?.isAvailable ?? false)")
        print("on-device: \(recognizer?.supportsOnDeviceRecognition ?? false)")
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        print("notch-display: \(screen != nil ? "yes (inset \(screen!.safeAreaInsets.top)pt)" : "no")")
    }

    private static func name(for raw: Int) -> String {
        switch raw {
        case 0: return "not determined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"
        default: return "unknown(\(raw))"
        }
    }
}

/// `--export-training <train.jsonl> [--valid-split 0.1]`, `--export-rejects <out.jsonl>`,
/// and `--seed-demo-samples` (only with `--db`, so the real database never gets demo rows).
enum TrainingCLI {
    static func run(dbPath: String?, seedDemo: Bool, trainingOut: String?, validSplit: Double,
                    rejectsOut: String?) -> Never {
        let url = dbPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Store.defaultURL
        guard let store = try? Store(url: url) else { fail("can't open database at \(url.path)") }
        print("database: \(url.path)")

        if seedDemo {
            guard dbPath != nil else { fail("--seed-demo-samples requires --db <path>") }
            seed(store)
        }
        if let trainingOut {
            exportTraining(store, to: path(trainingOut), validSplit: validSplit)
        }
        if let rejectsOut {
            let lines = store.rejectedSamples().compactMap(TrainingExport.preferenceLine)
            write(lines, to: path(rejectsOut))
            print("rejects: \(lines.count) → \(path(rejectsOut).path)")
        }
        exit(0)
    }

    private static func exportTraining(_ store: Store, to out: URL, validSplit: Double) {
        let samples = store.trainingSamples()
        var skipped = 0
        let lines = samples.compactMap { s -> String? in
            let line = TrainingExport.chatLine(for: s)
            if line == nil { skipped += 1 }
            return line
        }
        let (train, valid) = TrainingExport.split(lines, validFraction: validSplit)
        let validURL = out.deletingLastPathComponent().appendingPathComponent("valid.jsonl")
        write(train, to: out)
        write(valid, to: validURL)
        print("eligible samples: \(samples.count) (skipped \(skipped) with no usable target or a missing snippet token)")
        print("train: \(train.count) → \(out.path)")
        print("valid: \(valid.count) → \(validURL.path)")
        if out.lastPathComponent != "train.jsonl" {
            print("note: mlx_lm.lora --data <dir> expects train.jsonl and valid.jsonl in that directory")
        }
    }

    /// A handful of rows covering each export path.
    private static func seed(_ store: Store) {
        func sample(_ raw: String, rules: String, llm: String?, accepted: Bool?, inserted: String,
                    style: AppStyle = .neutral, engine: String = "apple") -> Store.Sample {
            Store.Sample(app: "com.example.demo", style: style.rawValue, level: CleanupLevel.light.rawValue,
                         engine: engine, model: engine == "apple" ? CleanupClient.modelName : nil,
                         promptVersion: CleanupPrompt.promptVersion, raw: raw, rules: rules,
                         preceding: "Hi team,", dictionary: ["Kubernetes", "Gaurav"], llmOutput: llm,
                         accepted: accepted, rejectReason: accepted == false ? "rejected by accept()" : nil,
                         inserted: inserted, latencyMs: llm == nil ? nil : 640)
        }
        let accepted = store.addSample(sample("um so lets meet on tuesday", rules: "So lets meet on tuesday.",
                                              llm: "So let's meet on Tuesday.", accepted: true,
                                              inserted: "So let's meet on Tuesday.", style: .formal))
        let edited = store.addSample(sample("deploy it to cooper netties", rules: "Deploy it to cooper netties.",
                                            llm: "Deploy it to cooper netties.", accepted: true,
                                            inserted: "Deploy it to cooper netties.", style: .code))
        store.updateSampleFinal(id: edited, finalText: "Deploy it to Kubernetes")
        let rejected = store.addSample(sample("what time is it in tokyo", rules: "What time is it in tokyo.",
                                              llm: "It is currently 3 PM in Tokyo, Japan, which is in the JST time zone.",
                                              accepted: false, inserted: "What time is it in tokyo."))
        let snippet = store.addSample(sample("send it to my email", rules: "Send it to ⟦1⟧.",
                                             llm: "Send it to ⟦1⟧.", accepted: true,
                                             inserted: "Send it to me@example.com.", style: .casual))
        let bad = store.addSample(sample("hello there", rules: "Hello there.", llm: "Hello there!",
                                         accepted: true, inserted: "Hello there!"))
        store.setSampleLabel(id: bad, label: "bad")
        let rulesOnly = store.addSample(sample("um ok", rules: "Ok.", llm: nil, accepted: nil,
                                               inserted: "Ok.", engine: "rules"))
        print("seeded demo samples: accepted=\(accepted) edited=\(edited) rejected=\(rejected) snippet=\(snippet) bad=\(bad) rulesOnly=\(rulesOnly)")
    }

    private static func path(_ p: String) -> URL {
        URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    private static func write(_ lines: [String], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("can't write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// Model bake-off helpers (NEXT_STEPS Phase B). Cases are TSV lines:
/// id, style, level, dictionary (comma-separated or -), raw transcript.
///   --dump-prompts <cases.tsv>             JSONL of the exact runtime prompts per case
///   --bench <cases.tsv> <out.jsonl> [--engine apple|qwen3]  run one engine on every case
///   (--bench-apple <cases.tsv> <out.jsonl> is the same with --engine apple)
///   --vet <results.jsonl>...               apply CleanupPrompt.accept and print a table
enum BenchCLI {
    struct Case {
        let id: String
        let request: CleanupRequest
        let raw: String
    }

    struct PromptLine: Codable {
        let id, style, level, rules, system, user: String
    }

    struct Result: Codable {
        let id: String
        let engine: String
        let rules: String
        let level: String
        let output: String?
        let ms: Int
        var dictionary: [String]? = nil
    }

    static func loadCases(_ path: String) -> [Case] {
        guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else {
            FileHandle.standardError.write("can't read \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        return text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { return nil }
            let dictionary = f[3] == "-" ? [] : f[3].split(separator: ",").map(String.init)
            let style = AppStyle(rawValue: f[1]) ?? .neutral
            let processed = TextProcessor().process(f[4])
            // Same rules pass as SessionController.rules(for:).
            let request = CleanupRequest(transcript: style == .code ? CodeDictation.apply(processed) : processed,
                                         style: style,
                                         level: CleanupLevel(rawValue: f[2]) ?? .light,
                                         dictionary: dictionary)
            return Case(id: f[0], request: request, raw: f[4])
        }
    }

    static func dumpPrompts(_ path: String) -> Never {
        for c in loadCases(path) {
            let line = PromptLine(id: c.id, style: c.request.style.rawValue, level: c.request.level.rawValue,
                                  rules: c.request.transcript,
                                  system: CleanupPrompt.instructions(level: c.request.level, style: c.request.style),
                                  user: CleanupPrompt.prompt(for: c.request))
            print(encode(line))
        }
        exit(0)
    }

    static func bench(_ path: String, out: String, engine: CleanupEngine) {
        CLIEngine.prepare(engine) { clean in run(path, out: out, engine: engine, clean: clean) }
    }

    private static func run(_ path: String, out: String, engine: CleanupEngine, clean: @escaping CLIEngine.Clean) {
        var remaining = loadCases(path)
        var lines: [String] = []
        func next() {
            guard !remaining.isEmpty else {
                try? (lines.joined(separator: "\n") + "\n").write(toFile: (out as NSString).expandingTildeInPath,
                                                                    atomically: true, encoding: .utf8)
                print("wrote \(lines.count) results → \(out)")
                let m = MemoryInfo.footprint()
                print("memory: now \(MemoryInfo.format(m.current)), peak \(MemoryInfo.format(m.peak))")
                exit(0)
            }
            let c = remaining.removeFirst()
            let started = Date()
            clean(c.request) { output, reason in
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                lines.append(encode(Result(id: c.id, engine: engine.rawValue + "-swift", rules: c.request.transcript,
                                           level: c.request.level.rawValue, output: output, ms: ms,
                                           dictionary: c.request.dictionary)))
                FileHandle.standardError.write("\(c.id): \(ms)ms \(reason)\n".data(using: .utf8)!)
                next()
            }
        }
        next()
    }

    static func vet(_ paths: [String]) -> Never {
        var rows: [String: [Result]] = [:]
        var engines: [String] = []
        for path in paths {
            guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let r = try? JSONDecoder().decode(Result.self, from: Data(line.utf8)) else { continue }
                rows[r.id, default: []].append(r)
                if !engines.contains(r.engine) { engines.append(r.engine) }
            }
        }
        var accepted: [String: Int] = [:], total: [String: Int] = [:], ms: [String: [Int]] = [:]
        CommonWords.shared.loadNow()
        for id in rows.keys.sorted() {
            print("== \(id): \(rows[id]?.first?.rules ?? "")")
            for r in rows[id] ?? [] {
                let level = CleanupLevel(rawValue: r.level) ?? .light
                let verdict = r.output.map { CleanupPrompt.vet(output: $0, input: r.rules, level: level, dictionary: r.dictionary ?? []) }
                let ok = verdict?.text
                total[r.engine, default: 0] += 1
                if ok != nil { accepted[r.engine, default: 0] += 1 }
                ms[r.engine, default: []].append(r.ms)
                let mark = ok == nil ? "REJECT" : "ok    "
                let why = ok == nil ? "  [\(verdict?.reason ?? "no output")]" : ""
                print("   \(mark) \(r.engine) \(r.ms)ms: \((r.output ?? "<none>").replacingOccurrences(of: "\n", with: " ⏎ "))\(why)")
                // What the app would insert: the vocabulary fix runs after the model.
                if let ok, let terms = r.dictionary, !terms.isEmpty {
                    let fixed = VocabularyCorrector(terms: terms, isCommonWord: CommonWords.shared.isProtected).correct(ok)
                    if !fixed.replacements.isEmpty { print("          → inserted: \(fixed.text)") }
                }
            }
        }
        print("\n== summary")
        for e in engines {
            let sorted = (ms[e] ?? []).sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            print("   \(e): accepted \(accepted[e] ?? 0)/\(total[e] ?? 0), median \(median)ms, max \(sorted.last ?? 0)ms")
        }
        exit(0)
    }

    /// `--gate <base.jsonl> <new.jsonl>`: exit 0 when the new model's accept
    /// rate (which includes the faithfulness check) is at least the base's.
    static func gate(base: String, new: String) -> Never {
        func score(_ path: String) -> (Int, Int) {
            let text = (try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
            var ok = 0, n = 0
            for line in text.split(separator: "\n") {
                guard let r = try? JSONDecoder().decode(Result.self, from: Data(line.utf8)) else { continue }
                n += 1
                let level = CleanupLevel(rawValue: r.level) ?? .light
                if r.output.flatMap({ CleanupPrompt.accept(output: $0, input: r.rules, level: level, dictionary: r.dictionary ?? []) }) != nil { ok += 1 }
            }
            return (ok, n)
        }
        let (b, bn) = score(base), (x, xn) = score(new)
        print("gate: base \(b)/\(bn), new \(x)/\(xn) → \(x >= b && xn > 0 ? "switch" : "keep")")
        exit(x >= b && xn > 0 ? 0 : 1)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
