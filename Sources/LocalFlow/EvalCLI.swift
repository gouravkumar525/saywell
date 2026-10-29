import AppKit
import AVFoundation
import Foundation
import LocalFlowCore
import Speech

/// `--bench-long`: how long a dictation can be and still get cleaned. For each
/// size, compares one big request against the chunked pipeline the app uses,
/// and estimates key-up latency with streaming (only the last chunk is left).
enum LongBenchCLI {
    /// Natural spoken sentences with fillers and repeats, cycled to any length.
    static let bank = [
        "um so i wanted to give everyone a quick update on the the migration project",
        "we moved the billing service over last week and it has been pretty stable so far",
        "uh the one thing that came up is that the nightly export job was running twice",
        "basically the scheduler had two entries and we only noticed because the reports were duplicated",
        "i think we should add an alert for that kind of thing going forward",
        "next week the plan is to move the user profile service which is a bit bigger",
        "it has like three databases and a cache so we need to be careful with the cutover",
        "sarah is going to own the database part and i will handle the the traffic switch",
        "if anything goes wrong we can roll back within about ten minutes",
        "we also need to update the runbook because the old one still mentions the previous cluster",
        "can someone from support review the customer facing notice before we send it on thursday",
        "the budget is fine for now but we might need two more servers in december",
        "um i will send a summary email after this so you have all the dates in one place",
        "let me know if you have questions or if i missed anything important",
    ]

    static func text(words: Int) -> String {
        var out: [String] = []
        var count = 0
        var i = 0
        while count < words {
            let s = bank[i % bank.count]
            out.append(s)
            count += CleanupPrompt.wordCount(s)
            i += 1
        }
        // Spoken text arrives with recognizer punctuation; end each sentence.
        return out.map { $0 + "." }.joined(separator: " ")
    }

    static func run(engine: CleanupEngine, sizes: [Int], level: CleanupLevel) {
        CLIEngine.timeout = 300
        CLIEngine.prepare(engine) { clean in
            var remaining = sizes
            print("engine=\(engine.rawValue) level=\(level.rawValue)")
            print("words | single-shot ms | single ok | chunks | chunked total ms | chunks ok | last-chunk ms (≈ key-up w/ streaming) | peak memory")
            func next() {
                guard !remaining.isEmpty else { exit(0) }
                let n = remaining.removeFirst()
                let rules = TextProcessor().process(text(words: n))
                let words = CleanupPrompt.wordCount(rules)
                let started = Date()
                clean(CleanupRequest(transcript: rules, style: .neutral, level: level)) { output, reason in
                    let singleMs = Int(Date().timeIntervalSince(started) * 1000)
                    let verdict = output.map { CleanupPrompt.vet(output: $0, input: rules, level: level) }
                    let single = verdict?.text != nil ? "yes" : "no (\(verdict?.reason ?? reason))"
                    let segments = SentenceSplitter.segments(rules)
                    var okCount = 0, total = 0, last = 0
                    var queue = segments
                    var preceding = ""
                    func chunk() {
                        guard !queue.isEmpty else {
                            let peak = MemoryInfo.format(MemoryInfo.footprint().peak)
                            print("\(words) | \(singleMs) | \(single) | \(segments.count) | \(total) | \(okCount)/\(segments.count) | \(last) | \(peak)")
                            next()
                            return
                        }
                        let seg = queue.removeFirst()
                        let t = Date()
                        clean(CleanupRequest(transcript: seg.text, style: .neutral, level: level,
                                             precedingText: preceding.isEmpty ? nil : String(preceding.suffix(400)))) { out, _ in
                            let ms = Int(Date().timeIntervalSince(t) * 1000)
                            total += ms
                            last = ms
                            let ok = out.flatMap { CleanupPrompt.accept(output: $0, input: seg.text, level: level) }
                            if ok != nil { okCount += 1 }
                            preceding += " " + (ok ?? seg.text)
                            chunk()
                        }
                    }
                    chunk()
                }
            }
            next()
        }
    }
}

/// `--simulate <audio> [--asr parakeet]`: feeds a recording through the
/// recognizer exactly as the mic would (SFSpeech: same request, restarts, and
/// segment banking; Parakeet: live passes, agreement, window cuts), to test
/// long dictations without speaking for minutes.
enum SimulateCLI {
    static func run(url: URL, speed: Double, asr: String = "sfspeech") {
        if asr == "parakeet" {
            ParakeetService.shared.load { ok in
                guard ok else { print("parakeet: \(ParakeetService.shared.statusDescription)"); exit(1) }
                start(url: url, speed: speed, engine: ParakeetEngine(mic: nil))
            }
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { print("speech not authorized"); exit(2) }
            DispatchQueue.main.async { start(url: url, speed: speed, engine: DictationEngine()) }
        }
    }

    private static func start(url: URL, speed: Double, engine: SpeechEngine) {
        guard let file = try? AVAudioFile(forReading: url) else { print("can't read \(url.path)"); exit(1) }
        let format = file.processingFormat
        let seconds = Double(file.length) / format.sampleRate
        var partials = 0
        var stableUpdates = 0
        var firstStable: TimeInterval?
        let started = Date()
        var fedAt = Date()
        var lastReport = Date.distantPast
        engine.onPartial = { text in
            partials += 1
            // Timeline: does the transcript keep growing for the whole recording?
            if Date().timeIntervalSince(lastReport) >= 10 {
                lastReport = Date()
                FileHandle.standardError.write(String(format: "t=%5.1fs words=%d\n", Date().timeIntervalSince(started),
                                                      CleanupPrompt.wordCount(text)).data(using: .utf8)!)
            }
        }
        engine.onStable = { _ in
            stableUpdates += 1
            if firstStable == nil { firstStable = Date().timeIntervalSince(started) }
        }
        engine.onFinal = { raw in
            let words = CleanupPrompt.wordCount(raw)
            print("audio: \(String(format: "%.1f", seconds))s, fed at \(speed)x")
            print("partials: \(partials)")
            if stableUpdates > 0 {
                print(String(format: "confirmed-word updates: %d (first after %.1fs)", stableUpdates, firstStable ?? 0))
            }
            print("transcript words: \(words)")
            print(String(format: "final arrived %.2fs after the audio ended (total %.1fs)",
                         Date().timeIntervalSince(fedAt), Date().timeIntervalSince(started)))
            print("TRANSCRIPT: \(raw)")
            exit(0)
        }
        do {
            if let e = engine as? DictationEngine { try e.startSimulated() } else { try engine.start() }
        } catch { print("\(error.localizedDescription)"); exit(1) }
        DispatchQueue.global().async {
            let frames: AVAudioFrameCount = 4096
            while true {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
                do { try file.read(into: buffer, frameCount: frames) } catch { break }
                if buffer.frameLength == 0 { break }
                if let e = engine as? DictationEngine { e.feed(buffer) } else { (engine as? ParakeetEngine)?.feed(buffer) }
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / format.sampleRate / speed)
            }
            DispatchQueue.main.async {
                fedAt = Date()
                engine.stop()
            }
        }
    }
}

/// G11 ASR bake-off. `--make-asr-set <dir>` writes TTS clips with reference
/// transcripts; `--bench-asr <dir>` scores each recognizer on every
/// `<name>.aiff|wav` + `<name>.txt` pair: word error rate, dropped words, time.
enum ASRBenchCLI {
    static let sentences = [
        "So we should meet on Tuesday to talk about the budget.",
        "Can you send me the quarterly report before the meeting?",
        "I think the new design looks great, but the colors are a bit too bright.",
        "Please remind me to call the dentist tomorrow at nine thirty.",
        "The flight lands at six forty five, so I will be home around eight.",
        "Tell Camila the LocalFlow build is ready to deploy on Kubernetes.",
        "Gaurav and Priya are reviewing the pull request on GitHub.",
        "Our Postgres database is running out of disk space on the staging cluster.",
        "Run git status and then npm install in the project folder.",
        "The API returns a four oh four when the user ID is missing.",
        "We spent twelve thousand five hundred dollars on cloud costs last month.",
        "The meeting moved from the third floor to room two hundred and four.",
        "Honestly I am not sure that the deadline on Friday is realistic.",
        "Let's grab lunch at the Thai place near the office.",
        "Number one, review the doc. Number two, ship it.",
        "The quick brown fox jumps over the lazy dog near the river bank.",
        "Our TypeScript compiler throws an error about an undefined variable.",
        "Schedule a call with Anika from the marketing team next Wednesday.",
        "Add Redis as a cache in front of the user profile service.",
        "I would like to order two large pizzas and a bottle of sparkling water.",
    ]

    static func makeSet(dir: String) -> Never {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let voices = ["Samantha", "Daniel", "Karen"]
        for (i, s) in sentences.enumerated() {
            let name = String(format: "%02d", i + 1)
            let audio = url.appendingPathComponent("\(name).aiff")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", voices[i % voices.count], "-o", audio.path, s]
            try? p.run()
            p.waitUntilExit()
            try? s.write(to: url.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
        print("wrote \(sentences.count) clips (voices: \(voices.joined(separator: ", "))) → \(url.path)")
        exit(0)
    }

    struct Score {
        var errors = 0, deletions = 0, words = 0, ms = 0, clips = 0
    }

    static func run(dir: String, backend: String) {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let files = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["aiff", "wav", "m4a", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var backends = backend == "all" ? ["sfspeech", "analyzer", "parakeet"] : [backend]
        if #unavailable(macOS 26.0) { backends.removeAll { $0 == "analyzer" } }
        if backends.contains("parakeet") && !ParakeetService.shared.isReady {
            ParakeetService.shared.load { ok in
                if !ok { print("parakeet: \(ParakeetService.shared.statusDescription); skipping it") }
                run(dir: dir, backend: ok ? backend : backends.filter { $0 != "parakeet" }.joined(separator: ","))
            }
            return
        }
        if backend.contains(",") { backends = backend.split(separator: ",").map(String.init) }
        SFSpeechRecognizer.requestAuthorization { _ in
            Task {
                var scores: [String: Score] = [:]
                for file in files {
                    guard let ref = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8) else { continue }
                    for b in backends {
                        let started = Date()
                        let hyp = (try? await transcribe(file, backend: b)) ?? ""
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        let (errors, deletions, n) = wer(reference: ref, hypothesis: hyp)
                        var s = scores[b, default: Score()]
                        s.errors += errors; s.deletions += deletions; s.words += n; s.ms += ms; s.clips += 1
                        scores[b] = s
                        print("\(file.lastPathComponent) [\(b)] \(ms)ms WER \(String(format: "%.0f%%", 100 * Double(errors) / Double(max(n, 1)))): \(hyp)")
                    }
                }
                print("\n== ASR summary (\(files.count) clips)")
                for b in backends {
                    let s = scores[b, default: Score()]
                    print(String(format: "   %@: WER %.1f%%, dropped words %.1f%%, mean %d ms/clip",
                                 b, 100 * Double(s.errors) / Double(max(s.words, 1)),
                                 100 * Double(s.deletions) / Double(max(s.words, 1)), s.ms / max(s.clips, 1)))
                }
                exit(0)
            }
        }
    }

    /// `--score-asr <dir> <results.tsv> <name>`: scores another recognizer's
    /// "<file>\t<ms>\t<text>" lines (Tools/parakeet-bench) with the same WER code.
    static func score(dir: String, results: String, name: String) -> Never {
        let base = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let text = (try? String(contentsOfFile: (results as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
        var s = Score()
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let ms = Int(f[1]),
                  let ref = try? String(contentsOf: base.appendingPathComponent(f[0]).deletingPathExtension()
                                          .appendingPathExtension("txt"), encoding: .utf8) else { continue }
            let (errors, deletions, n) = wer(reference: ref, hypothesis: f[2])
            s.errors += errors; s.deletions += deletions; s.words += n; s.ms += ms; s.clips += 1
            print("\(f[0]) [\(name)] \(ms)ms WER \(String(format: "%.0f%%", 100 * Double(errors) / Double(max(n, 1)))): \(f[2])")
        }
        print(String(format: "   %@: WER %.1f%%, dropped words %.1f%%, mean %d ms/clip (%d clips)",
                     name, 100 * Double(s.errors) / Double(max(s.words, 1)),
                     100 * Double(s.deletions) / Double(max(s.words, 1)), s.ms / max(s.clips, 1), s.clips))
        exit(0)
    }

    static func transcribe(_ url: URL, backend: String) async throws -> String {
        if backend == "analyzer", #available(macOS 26.0, *) {
            return try await analyzer(url)
        }
        if backend == "parakeet" {
            return try await ParakeetService.shared.transcribe(file: url)
        }
        return try await withCheckedThrowingContinuation { c in
            FileTranscriber.transcribe(url: url) { result in c.resume(with: result) }
        }
    }

    /// SpeechAnalyzer + SpeechTranscriber (macOS 26): Apple's newer on-device model.
    @available(macOS 26.0, *)
    static func analyzer(_ url: URL) async throws -> String {
        let locale = Locale(identifier: "en_US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            FileHandle.standardError.write("installing SpeechTranscriber assets for en_US (system download)…\n".data(using: .utf8)!)
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> String in
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collect.value.trimmingCharacters(in: .whitespaces)
    }

    /// Word-level edit distance after normalizing case, punctuation, and numbers.
    static func wer(reference: String, hypothesis: String) -> (errors: Int, deletions: Int, words: Int) {
        func words(_ s: String) -> [String] {
            Faithfulness.normalizedWords(s)
        }
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return (h.count, 0, 0) }
        // dp over (cost, deletions)
        var prev = (0...h.count).map { ($0, 0) }
        for i in 1...r.count {
            var cur = [(i, i)] + Array(repeating: (0, 0), count: h.count)
            for j in 1...max(h.count, 1) where !h.isEmpty {
                let sub = (prev[j - 1].0 + (r[i - 1] == h[j - 1] ? 0 : 1), prev[j - 1].1)
                let del = (prev[j].0 + 1, prev[j].1 + 1)
                let ins = (cur[j - 1].0 + 1, cur[j - 1].1)
                cur[j] = [sub, del, ins].min { $0.0 < $1.0 }!
            }
            prev = cur
        }
        return (prev[h.count].0, prev[h.count].1, r.count)
    }
}

/// `--test-window <seconds> <out>`: a plain window with a text view, used as the
/// target for end-to-end dictation tests so no real document is touched.
enum TestWindowCLI {
    static func run(seconds: Double, out: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Saywell Test Target"
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        if let seed = ProcessInfo.processInfo.environment["LF_TEST_SEED"] { textView.string = seed }
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        // LF_TEST_SELECT=all starts with everything selected (command-mode tests).
        let selectAll = ProcessInfo.processInfo.environment["LF_TEST_SELECT"] == "all"
        textView.setSelectedRange(NSRange(location: selectAll ? 0 : length, length: selectAll ? length : 0))
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            try? textView.string.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
            print("TEXT: \(textView.string)")
            exit(0)
        }
        app.run()
        exit(0)
    }
}

/// C5 test harness. `--make-call <dir>` writes a scripted three-person call as
/// mic.wav (you, plus a little echo of the call) and system.wav (two other
/// voices); `--note-test <dir> [--diarizer <verified model folder>]` runs the
/// Notetaker's processing on them and prints the transcript and summary.
enum NoteCLI {
    static let script: [(voice: String, side: String, text: String)] = [
        ("Samantha", "mic", "Hi both, um, thanks for joining. So so let's go over the the launch plan for next week."),
        ("Daniel", "system", "Sure. Uh the landing page is ready, but we we still need the pricing table from finance."),
        ("Karen", "system", "I can get the pricing table to you by Wednesday afternoon."),
        ("Samantha", "mic", "Great. Daniel, can you also check the signup flow on mobile?"),
        ("Daniel", "system", "Yes, I will test it on iOS and Android tomorrow and send a short report."),
        ("Karen", "system", "One more thing, the press release needs legal review before Friday."),
        ("Samantha", "mic", "Okay, I will book a call with legal for Thursday morning. Anything else?"),
        ("Daniel", "system", "No, that's everything from my side. We decided to launch on Monday, right? Talk soon."),
    ]

    static func make(dir: String) -> Never {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var mic: [Float] = [], system: [Float] = []
        func pad(_ a: inout [Float], to n: Int) { if a.count < n { a += [Float](repeating: 0, count: n - a.count) } }
        for (i, line) in script.enumerated() {
            let clip = url.appendingPathComponent("line\(i).aiff")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", line.voice, "-o", clip.path, line.text]
            try? p.run()
            p.waitUntilExit()
            guard let samples = try? read16k(clip) else { continue }
            try? FileManager.default.removeItem(at: clip)
            let start = max(mic.count, system.count) + Int(ChannelRecorder.rate * 0.6)
            pad(&mic, to: start)
            pad(&system, to: start)
            if line.side == "mic" {
                mic += samples
            } else {
                system += samples
                mic += samples.map { $0 * 0.12 }   // the call, faintly, through the speakers
            }
        }
        let n = max(mic.count, system.count)
        pad(&mic, to: n)
        pad(&system, to: n)
        do {
            try write(mic, to: url.appendingPathComponent("mic.wav"))
            try write(system, to: url.appendingPathComponent("system.wav"))
        } catch {
            print("make-call: \(error)")
            exit(1)
        }
        print("wrote mic.wav + system.wav (\(Int(Double(n) / ChannelRecorder.rate)) s, \(script.count) lines) → \(url.path)")
        exit(0)
    }

    static func read16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return Resampler().convert(buffer)
    }

    static func write(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: ChannelRecorder.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ChannelRecorder.rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, samples.count * 4) }
        try file.write(from: buffer)
    }

    static func run(dir: String, diarizer: String?, engine: CleanupEngine) {
        let src = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saywell-note-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        NoteTaker.folder = tmp.appendingPathComponent("Notes")
        guard let store = try? Store(url: tmp.appendingPathComponent("test.sqlite")) else { print("no store"); exit(1) }
        var note = Note(title: "Test call", start: Date(), status: .processing)
        note.end = Date().addingTimeInterval(60)
        let folder = NoteTaker.folder(for: note.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["mic.wav", "system.wav"] {
            try? FileManager.default.copyItem(at: src.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        store.saveNote(note)
        let mlx = MLXCleanupClient()
        let generate: (String, String, Int) async -> String? = { instructions, prompt, maxTokens in
            if engine == .qwen3, let text = await mlx.generate(instructions: instructions, prompt: prompt, maxTokens: maxTokens) { return text }
            return await CleanupClient.generate(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
        }
        let taker = NoteTaker(store: store, mic: MicCapture(), generate: generate)
        taker.cleanLine = { heard in
            let rules = TextProcessor().process(heard)
            let request = CleanupRequest(transcript: rules, style: .neutral, level: .light)
            let maxTokens = max(48, CleanupPrompt.wordCount(rules) * 3 + 24)
            guard let output = await generate(CleanupPrompt.instructions(for: request), CleanupPrompt.userPrompt(for: request), maxTokens)
            else { return rules }
            return CleanupPrompt.accept(output: output, input: rules, level: .light) ?? rules
        }
        if engine == .qwen3, let spec = engine.modelSpec(store: nil) {
            mlx.load(.qwen3, spec: spec, allowDownload: false) { ok in
                print("qwen3: \(ok ? "loaded" : mlx.statusDescription)")
                run2(taker: taker, store: store, note: note, folder: folder, tmp: tmp, diarizer: diarizer)
            }
        } else {
            run2(taker: taker, store: store, note: note, folder: folder, tmp: tmp, diarizer: diarizer)
        }
    }

    private static func run2(taker: NoteTaker, store: Store, note: Note, folder: URL, tmp: URL, diarizer: String?) {
        ParakeetService.shared.load { ok in
            guard ok else { print("parakeet: \(ParakeetService.shared.statusDescription)"); exit(1) }
            Task {
                if let diarizer {
                    let d = URL(fileURLWithPath: (diarizer as NSString).expandingTildeInPath)
                    let errors = DiarizerService.manifest.verify(directory: d)
                    if errors.isEmpty {
                        try? await DiarizerService.shared.load(verified: d, root: tmp.appendingPathComponent("fa"))
                    } else {
                        print("diarizer folder failed verification: \(errors.map(\.description))")
                    }
                }
                let started = Date()
                await taker.process(note.id)
                let done = store.notes().first!
                print("== \(done.title) [\(done.status.rawValue)] in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                print("speakers: \(done.speakers.map(\.name).joined(separator: ", "))")
                for line in done.lines {
                    let who = done.speaker(line.speaker)?.name ?? "?"
                    if let raw = line.raw, raw != line.text { print("\(who) (heard): \(raw)") }
                    print("\(who): \(line.text)")
                }
                print("summary: \(done.summary ?? "-")")
                done.keyPoints.forEach { print("  • \($0)") }
                (done.decisions ?? []).forEach { print("  ✓ \($0)") }
                done.todos.forEach { print("  [ ] \($0.text) (\($0.owner ?? "-"), \($0.due ?? "-"))") }
                (done.openQuestions ?? []).forEach { print("  ? \($0)") }
                print("audio deleted: \(!FileManager.default.fileExists(atPath: folder.path))")
                try? FileManager.default.removeItem(at: tmp)
                exit(done.status == .ready ? 0 : 1)
            }
        }
    }
}
