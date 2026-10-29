import AVFoundation
import AppKit
import Speech
import LocalFlowCore

/// Owns one dictation at a time:
/// capture context → stream audio to ASR (finished sentences are already
/// cleaned in the background) → rules → snippets → LLM polish per chunk
/// (with fallback) → vocabulary fix → smart spacing → insert → watch for edits.
final class SessionController {
    enum Trigger { case toggle, push }

    private let state: AppState
    private let panel: NotchPanel
    let store: Store?
    private var processor = TextProcessor()
    private let cleanup = CleanupClient()
    /// Local Qwen3 model via MLX; one resident at a time.
    let mlx = MLXCleanupClient()
    /// Shared, prepared microphone (G3).
    let mic = MicCapture()
    private let watcher: EditWatcher

    private var engine: SpeechEngine?
    /// Recognizer used for the current dictation ("sfspeech" or "parakeet").
    private var asrName = "sfspeech"
    private var context: FocusContext?
    private var style: AppStyle = .neutral
    /// Writing mode for this dictation (B9), from the app, website, or a spoken trigger.
    private var mode: WritingMode?
    /// Style chosen from the app, before any mode overrides it.
    private var appStyle: AppStyle = .neutral
    private var startedAt = Date()
    private var trigger: Trigger = .toggle
    private var autoStopTimer: Timer?
    private var capTimer: Timer?
    private let media = MediaControl()
    /// B12: recordings stop on their own after this long.
    static let maxRecordingSeconds = 600
    private var idleTimer: Timer?
    /// Bumped per session so late callbacks from an old session are ignored.
    private var generation = 0
    private var stopRequestedAt = Date()
    /// The last text inserted or copied, for ⌃⌘V (not stored on disk).
    private(set) var lastText: String?

    var onListeningChanged: ((Bool) -> Void)?
    /// When Saywell's own window is focused (onboarding "Try it"), text goes here.
    var localInsertTarget: ((String) -> Void)?

    init(state: AppState, panel: NotchPanel, store: Store?) {
        self.state = state
        self.panel = panel
        self.store = store
        watcher = EditWatcher(store: store)
        mic.keepReady = store?.setting("mic.preroll") == "on"
        mic.prepare()
        mic.onBands = { [weak state] bands in DispatchQueue.main.async { state?.bands = bands } }
        CommonWords.shared.preload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DictationEngine.warmUp() }
        DispatchQueue.global(qos: .utility).async { Self.refreshLocales() }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.unloadIfIdle() }
    }

    // MARK: Settings

    var level: CleanupLevel {
        get { CleanupLevel(rawValue: store?.setting("cleanup.level") ?? "") ?? .light }
        set { store?.setSetting("cleanup.level", newValue.rawValue) }
    }

    var autoStopSeconds: Int {
        get { Int(store?.setting("autostop.seconds") ?? "") ?? 0 }
        set { store?.setSetting("autostop.seconds", String(newValue)) }
    }

    /// Minutes of no dictation before the local model is unloaded (0 = never).
    var idleUnloadMinutes: Int {
        get { Int(store?.setting("mlx.idle.minutes") ?? "") ?? 15 }
        set { store?.setSetting("mlx.idle.minutes", String(newValue)) }
    }

    /// Pre-roll: keep the mic running into a 0.5 s memory ring (G3).
    var keepMicReady: Bool {
        get { mic.keepReady }
        set {
            mic.keepReady = newValue
            store?.setSetting("mic.preroll", newValue ? "on" : "off")
        }
    }

    /// C2 setting `asr.locale`: "auto" (the Mac's languages) or a locale identifier.
    var languageSetting: String {
        get { store?.setting("asr.locale") ?? SpeechLanguage.automatic }
        set { store?.setSetting("asr.locale", newValue) }
    }

    /// Locales Apple's recognizer can run on this Mac without a server, sorted
    /// by name. Grows when the user adds a Dictation language in System Settings.
    private(set) static var onDeviceLocales: [String] = [SpeechLanguage.fallback]

    /// ~100 ms (creates a recognizer per supported locale); at launch and on menu open.
    static func refreshLocales() {
        let found = SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .map(\.identifier)
            .sorted { SpeechLanguage.displayName($0) < SpeechLanguage.displayName($1) }
        DispatchQueue.main.async { if !found.isEmpty { onDeviceLocales = found } }
    }

    /// Languages offered in the menu for the selected recognizer.
    var languageChoices: [String] {
        SpeechLanguage.choices(appleOnDevice: Self.onDeviceLocales, parakeet: speechBackend == .parakeet)
    }

    /// The language this dictation is in.
    var languageID: String {
        SpeechLanguage.resolve(setting: languageSetting, preferred: Locale.preferredLanguages,
                               supported: languageChoices)
    }

    private var isEnglish = true
    /// For the model prompt: nil when English.
    private var promptLanguage: String? { isEnglish ? nil : SpeechLanguage.englishName(languageID) }

    /// The common-word guard and phonetic matching are English-only (C2).
    private func makeCorrector(_ dictionary: [String]) -> VocabularyCorrector {
        VocabularyCorrector(terms: isEnglish ? dictionary : [], isCommonWord: CommonWords.shared.isProtected)
    }

    /// User-defined writing modes (B9), setting `modes` (JSON).
    var modes: [WritingMode] {
        get { WritingMode.decodeList(store?.setting("modes")) }
        set { store?.setSetting("modes", WritingMode.encodeList(newValue)) }
    }

    /// The level after the mode's override.
    private var effectiveLevel: CleanupLevel { mode?.level ?? level }

    private func applyMode(_ match: ModeMatcher.Match?) {
        guard let match, match.mode != mode else { return }
        mode = match.mode
        style = match.mode.style ?? appStyle
        Log.write("mode: \"\(match.mode.name)\" (\(match.reason)) style=\(style.rawValue) level=\(effectiveLevel.rawValue)")
        if let ctx = context { state.target = "\(ctx.appName) · \(match.mode.name)" }
    }

    /// Removes a spoken mode trigger from the start of the transcript and
    /// switches to that mode. Deterministic, so streamed and final text agree.
    private func applyTrigger(_ transcript: String) -> String {
        let modes = activeModes
        guard modes.contains(where: { $0.trigger != nil }),
              let (m, stripped) = ModeMatcher.triggerMatch(modes, transcript: transcript) else { return transcript }
        applyMode(ModeMatcher.Match(mode: m, transcript: stripped, reason: "trigger"))
        return stripped
    }

    /// B11: names visible on screen, as spelling hints for this dictation only.
    private var screenHints: [String] = []

    /// B11 setting `context.screenNames`, off by default.
    var screenNamesEnabled: Bool {
        get { store?.setting("context.screenNames") == "on" }
        set { store?.setSetting("context.screenNames", newValue ? "on" : "off") }
    }

    /// Modes loaded once per dictation.
    private var activeModes: [WritingMode] = []

    /// B12: quiet start/stop sounds (setting `sounds`, off by default).
    var soundsEnabled: Bool {
        get { store?.setting("sounds") == "on" }
        set { store?.setSetting("sounds", newValue ? "on" : "off") }
    }

    /// B12: pause Music/Spotify while dictating (setting `media.pause`, off by default).
    var pauseMediaEnabled: Bool {
        get { store?.setting("media.pause") == "on" }
        set { store?.setSetting("media.pause", newValue ? "on" : "off") }
    }

    /// B8: leave each dictation on the clipboard after inserting it.
    var keepOnClipboard: Bool {
        get { store?.setting("insert.keepClipboard") == "on" }
        set { store?.setSetting("insert.keepClipboard", newValue ? "on" : "off") }
    }

    /// Background sentence cleanup while talking (G2), setting `stream.enabled`.
    var streamingEnabled: Bool { store?.setting("stream.enabled") != "off" }

    /// Which recognizer turns speech into text (setting `asr.engine`, default Apple).
    var speechBackend: SpeechBackend {
        get { SpeechBackend(rawValue: store?.setting("asr.engine") ?? "") ?? .apple }
        set {
            store?.setSetting("asr.engine", newValue.rawValue)
            Log.write("asr: selected \(newValue.rawValue)")
        }
    }

    /// Loads Parakeet when it's the selected recognizer (B1).
    func loadSpeechBackend(allowDownload: Bool = false) {
        guard speechBackend == .parakeet else { return }
        ParakeetService.shared.load(allowDownload: allowDownload)
    }

    /// Which model cleans up (setting `cleanup.engine`, default Apple).
    var cleanupEngine: CleanupEngine {
        CleanupEngine(rawValue: store?.setting("cleanup.engine") ?? "") ?? .apple
    }

    /// Switches engines: loads a local model (unloading any other) or frees it.
    func selectEngine(_ engine: CleanupEngine, allowDownload: Bool = false) {
        store?.setSetting("cleanup.engine", engine.rawValue)
        Log.write("engine: selected \(engine.rawValue)")
        loadSelectedEngine(allowDownload: allowDownload)
    }

    func loadSelectedEngine(allowDownload: Bool = false) {
        let engine = cleanupEngine
        if engine.isLocal, let spec = engine.modelSpec(store: store) {
            mlx.load(engine, spec: spec, allowDownload: allowDownload)
        } else {
            mlx.unload()
        }
    }

    /// G8: free the model's ~2.5 GB after a quiet spell; it reloads on the next trigger.
    private func unloadIfIdle() {
        let minutes = idleUnloadMinutes
        guard minutes > 0, mlx.isLoaded, !isBusy,
              Date().timeIntervalSince(mlx.lastUsed) > Double(minutes) * 60 else { return }
        let before = MemoryInfo.footprint().current
        mlx.unload()
        Log.write("mlx: unloaded after \(minutes) min idle (memory \(MemoryInfo.format(before)) → \(MemoryInfo.format(MemoryInfo.footprint().current)))")
    }

    private enum Route {
        case local(CleanupEngine, String)
        case apple
        case unavailable(String)
    }

    /// The engine that will actually run: the selected one if it's ready,
    /// otherwise Apple's model, otherwise nothing (rules text).
    private func route() -> Route {
        let selected = cleanupEngine
        if selected.isLocal {
            if mlx.isReady(selected), let spec = mlx.modelSpec { return .local(selected, spec) }
            let why = "\(selected.rawValue) \(mlx.engine == selected ? mlx.statusDescription : "not loaded")"
            if CleanupClient.isAvailable {
                Log.write("engine: \(why); using apple")
                return .apple
            }
            return .unavailable(why)
        }
        return CleanupClient.isAvailable ? .apple : .unavailable(CleanupClient.availabilityDescription)
    }

    /// Save each dictation as a training sample (setting `training.capture`, default on).
    var captureTraining: Bool { store?.setting("training.capture") != "off" }

    private var isBusy: Bool {
        switch state.phase {
        case .listening, .processing: return true
        default: return false
        }
    }

    // MARK: Triggers

    func toggle() {
        if state.isListening { stop() } else { start(.toggle) }
    }

    func pushStart() {
        guard !isBusy else { return }
        start(.push)
    }

    func pushEnd() {
        guard state.isListening else { return }
        stop()
    }

    func pushCancel() {
        guard state.isListening else { return }
        cancel()
    }

    /// Double tap on the hold key: hands-free, like ⌃⌥D (auto-stop applies).
    func pushLock() {
        guard trigger == .push, state.isListening else { return }
        trigger = .toggle
        Log.write("hands-free: locked")
        scheduleAutoStop()
    }

    /// Esc cancels a dictation that is still listening.
    func escape() {
        guard state.isListening else { return }
        Log.write("escape: cancelled")
        cancel()
    }

    /// ⌃⌘V: types the last dictation again where the cursor is.
    func pasteLast() {
        guard !isBusy else { return }
        guard let text = lastText, !text.isEmpty else {
            showError("Nothing dictated yet")
            return
        }
        Log.write("paste-last: \(text.count) chars")
        TextInserter.pasteAgain(text)
    }

    // MARK: Session

    /// Set while something else owns the microphone (a call being recorded, C5).
    var micBusyReason: (() -> String?)?

    private func start(_ trigger: Trigger) {
        guard !isBusy else { return }
        if let reason = micBusyReason?() {
            showError(reason)
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.write("startDictation: mic=\(micStatus.rawValue) trigger=\(trigger)")
        guard micStatus == .authorized else {
            if micStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Log.write("mic request -> \(granted)")
                }
                showError("Allow microphone access to dictate")
            } else {
                showError("Mic denied: System Settings → Privacy → Microphone")
            }
            return
        }
        watcher.stop()
        generation += 1
        self.trigger = trigger
        let language = languageID
        DictationEngine.localeIdentifier = SpeechLanguage.appleLocale(for: language, onDevice: Self.onDeviceLocales)
        isEnglish = SpeechLanguage.isEnglish(language)
        processor = TextProcessor(englishRules: isEnglish)
        if !isEnglish { Log.write("language: \(language) (English-only rules off)") }

        let ctx = ContextProvider.capture()
        context = ctx
        let override = store?.setting("style.\(ctx.bundleID ?? "")").flatMap(AppStyle.init(rawValue:))
        appStyle = override ?? AppStyle.forBundleID(ctx.bundleID)
        style = appStyle
        mode = nil
        activeModes = modes
        if !activeModes.isEmpty {
            let url = ModeMatcher.needsURL(activeModes) ? ContextProvider.browserURL(for: ctx) : nil
            if let url { Log.write("context: url=\(url.prefix(120))") }
            applyMode(ModeMatcher.match(activeModes, transcript: "", bundleID: ctx.bundleID, url: url))
        }
        Log.write("context: app=\(ctx.bundleID ?? "?") role=\(ctx.role ?? "-") style=\(style.rawValue) electron=\(ctx.isElectron) selection=\(ctx.selection.map { "\($0.location)+\($0.length)" } ?? "-")")
        if ctx.isSecure {
            showError("Won't dictate into a password field")
            return
        }
        // G8: an idle-unloaded model reloads while the user speaks.
        let selected = cleanupEngine
        if selected.isLocal, !mlx.isReady(selected), !mlx.isLoading {
            Log.write("mlx: reloading \(selected.rawValue) on trigger")
            loadSelectedEngine()
        }
        if case .apple = route() {
            let command = !(ctx.selectedText ?? "").isEmpty
            cleanup.prepare(level: effectiveLevel, style: style, command: command, mode: mode?.cleanInstructions,
                            language: promptLanguage)
        }

        let engine: SpeechEngine
        if speechBackend == .parakeet, ParakeetService.shared.isReady {
            engine = ParakeetEngine(mic: mic)
            asrName = "parakeet"
        } else {
            if speechBackend == .parakeet {
                Log.write("asr: parakeet \(ParakeetService.shared.statusDescription); using Apple for this dictation")
                if !ParakeetService.shared.isLoading { loadSpeechBackend() }
            }
            engine = DictationEngine(mic: mic)
            asrName = "sfspeech"
        }
        screenHints = []
        if screenNamesEnabled {
            let started = Date()
            let known = Set((store?.dictionaryTerms() ?? []).map { $0.lowercased() })
            screenHints = ScreenNames.extract(ContextProvider.windowText(for: ctx), isCommonWord: CommonWords.shared.isProtected)
                .filter { !known.contains($0.lowercased()) }
            Log.write("context: \(screenHints.count) on-screen names in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        engine.contextualStrings = (store?.rankedTerms(app: ctx.bundleID) ?? []) + screenHints
        self.engine = engine
        resetStream()
        let gen = generation
        // Batch recognizers report confirmed words separately; stream only those (B2).
        let hasStable = engine is ParakeetEngine
        engine.onPartial = { [weak self] text in
            guard self?.generation == gen else { return }
            self?.state.transcript = text
            if !hasStable { self?.streamObserve(text) }
        }
        engine.onStable = { [weak self] text in
            guard self?.generation == gen else { return }
            self?.streamObserve(text)
        }
        engine.onLevel = { [weak self] level in self?.state.level = level }
        engine.onFinal = { [weak self] raw in
            guard self?.generation == gen else { return }
            self?.finish(raw: raw)
        }

        do {
            try engine.start()
            state.transcript = ""
            state.bands = [Float](repeating: 0, count: AudioBands.count)
            state.polished = ""
            state.note = ""
            state.streamed = 0
            state.target = "\(ctx.appName) · \(mode?.name ?? style.label)"
            state.secondsLeft = nil
            startedAt = Date()
            startCapTimer()
            if soundsEnabled { DictationSound.start() }
            if pauseMediaEnabled { media.pauseIfPlaying() }
            state.phase = .listening
            panel.layout(expanded: true, animated: true)
            onListeningChanged?(true)
            scheduleAutoStop()
            startStreamTimer()
        } catch {
            Log.write("engine start failed: \(error.localizedDescription)")
            self.engine = nil
            showError(error.localizedDescription)
        }
    }

    func stop() {
        guard state.isListening else { return }
        autoStopTimer?.invalidate()
        endRecordingExtras()
        if soundsEnabled { DictationSound.stop() }
        stopStreamTimer()
        stopRequestedAt = Date()
        state.phase = .processing
        onListeningChanged?(false)
        engine?.stop()
    }

    func cancel() {
        autoStopTimer?.invalidate()
        endRecordingExtras()
        stopStreamTimer()
        generation += 1
        resetStream()
        engine?.cancel()
        engine = nil
        onListeningChanged?(false)
        Log.write("session cancelled")
        collapse()
    }

    /// B12: a countdown in the pill for the last 30 s, then stop.
    private func startCapTimer() {
        capTimer?.invalidate()
        capTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state.isListening else { return }
            let left = Self.maxRecordingSeconds - Int(Date().timeIntervalSince(self.startedAt))
            self.state.secondsLeft = left <= 30 ? max(0, left) : nil
            if left <= 0 {
                Log.write("recording cap: stopping after \(Self.maxRecordingSeconds / 60) min")
                self.stop()
            }
        }
    }

    private func endRecordingExtras() {
        capTimer?.invalidate()
        capTimer = nil
        state.secondsLeft = nil
        media.resume()
    }

    private func scheduleAutoStop() {
        autoStopTimer?.invalidate()
        let seconds = autoStopSeconds
        guard trigger == .toggle, seconds > 0 else { return }
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            if engine.secondsSinceVoice > Double(seconds) {
                Log.write("auto-stop after \(seconds)s of silence")
                self.stop()
            }
        }
    }

    // MARK: Cleanup of one chunk

    /// One piece of a dictation after cleanup.
    private struct Chunk {
        /// Rules text sent to the model (snippets as ⟦n⟧ tokens).
        var rules: String
        /// Rules text with tokens restored and vocabulary fixed: the "raw" version.
        var rulesText: String
        var hasTokens: Bool
        var output: String?
        var accepted: Bool?
        var reason: String?
        var engine = "rules"
        var model: String?
        /// What gets inserted.
        var text: String
        var ms = 0
    }

    private typealias Run = (CleanupRequest, @escaping (String) -> Void, @escaping (String?, String) -> Void) -> Void

    private func runner(for route: Route) -> (engine: String, model: String, run: Run)? {
        switch route {
        case .local(_, let spec):
            return ("mlx", spec, { [mlx] request, partial, done in
                let words = Double(CleanupPrompt.wordCount(request.transcript))
                mlx.clean(request, timeout: max(6, 2 + words * 0.06), onPartial: partial, completion: done)
            })
        case .apple:
            return (CleanupClient.engineName, CleanupClient.modelName, { [cleanup] request, partial, done in
                let words = Double(CleanupPrompt.wordCount(request.transcript))
                cleanup.clean(request, timeout: max(4, 2 + words * 0.06), onPartial: partial, completion: done)
            })
        case .unavailable:
            return nil
        }
    }

    /// Rules → snippet tokens → model → vet → vocabulary → restore tokens.
    private func cleanChunk(_ rules: String, preceding: String?, route: Route, level: CleanupLevel,
                            dictionary: [String], corrector: VocabularyCorrector,
                            onPartial: @escaping (String) -> Void, completion: @escaping (Chunk) -> Void) {
        let (tokenized, tokens) = SnippetExpander(snippets: store?.snippets() ?? [:]).tokenize(rules)
        func finalize(_ text: String) -> String? {
            let fixed = corrector.correct(SpokenFormatting.joinAddresses(text))
            for r in fixed.replacements { Log.write("vocab: \"\(r.heard)\" → \"\(r.term)\"") }
            return SnippetExpander.restore(fixed.text, tokens: tokens)
        }
        let rulesText = finalize(tokenized) ?? rules
        var chunk = Chunk(rules: tokenized, rulesText: rulesText, hasTokens: !tokens.isEmpty, text: rulesText)
        guard level != .off, let runner = runner(for: route) else {
            if case .unavailable(let why) = route { chunk.reason = why }
            completion(chunk)
            return
        }
        // On-screen names help spelling but are never stored with the sample.
        let hinted = dictionary + screenHints
        let request = CleanupRequest(transcript: tokenized, style: style, level: level,
                                     dictionary: hinted, precedingText: preceding,
                                     modeInstructions: mode?.cleanInstructions, language: promptLanguage)
        let started = Date()
        runner.run(request, { partial in
            var display = partial
            for (token, expansion) in tokens { display = display.replacingOccurrences(of: token, with: expansion) }
            onPartial(display)
        }, { output, reason in
            chunk.engine = runner.engine
            chunk.model = runner.model
            chunk.output = output
            chunk.ms = Int(Date().timeIntervalSince(started) * 1000)
            let verdict = output.map { CleanupPrompt.vet(output: $0, input: tokenized, level: level,
                                                         dictionary: hinted, preceding: preceding) }
            if let accepted = verdict?.text, let restored = finalize(accepted) {
                chunk.accepted = true
                chunk.text = restored
            } else {
                chunk.accepted = false
                chunk.reason = output == nil ? reason : (verdict?.text == nil ? verdict?.reason ?? "rejected" : "snippet token missing")
                Log.write("llm[\(runner.engine)]: rejected after \(chunk.ms)ms (\(chunk.reason ?? "")) output=\"\(output ?? "")\"")
            }
            completion(chunk)
        })
    }

    // MARK: Serial work queue (the local model can't run two requests at once)

    private var jobs: [(@escaping () -> Void) -> Void] = []
    private var jobRunning = false

    private func enqueue(_ job: @escaping (@escaping () -> Void) -> Void) {
        jobs.append(job)
        runNextJob()
    }

    private func runNextJob() {
        guard !jobRunning, !jobs.isEmpty else { return }
        jobRunning = true
        let job = jobs.removeFirst()
        job { [weak self] in
            DispatchQueue.main.async {
                self?.jobRunning = false
                self?.runNextJob()
            }
        }
    }

    // MARK: Streaming cleanup (G2)

    /// Raw sentence groups already sent for cleanup, in order.
    private var streamGroups: [String] = []
    private var streamResults: [Int: Chunk] = [:]
    /// Finished sentences not yet sent, with when each was first seen as-is.
    private var streamCandidates: [(text: String, since: Date)] = []
    private var streamEpoch = 0
    private var streamBroken = false
    private var streamTimer: Timer?
    private var liveTranscript = ""

    private func resetStream() {
        streamEpoch += 1
        streamGroups = []
        streamResults = [:]
        streamCandidates = []
        streamBroken = false
        liveTranscript = ""
    }

    private func startStreamTimer() {
        stopStreamTimer()
        guard streamingEnabled, effectiveLevel != .off else { return }
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.streamTick() }
    }

    private func stopStreamTimer() {
        streamTimer?.invalidate()
        streamTimer = nil
    }

    private func streamObserve(_ transcript: String) {
        liveTranscript = applyTrigger(transcript)
    }

    /// Sends sentences that have stayed unchanged for 600 ms.
    private func streamTick() {
        guard !streamBroken, state.isListening else { return }
        if case .unavailable = route() { return }
        let sentences = SentenceSplitter.split(liveTranscript).sentences
        let sent = streamGroups.flatMap { SentenceSplitter.split($0).sentences }
        guard sentences.count >= sent.count else { return }
        // The recognizer revised a sentence we already sent: stop streaming;
        // the whole text gets cleaned at key-up instead.
        if Array(sentences.prefix(sent.count)) != sent {
            Log.write("stream: recognizer revised a sent sentence; falling back to key-up cleanup")
            streamBroken = true
            return
        }
        let fresh = Array(sentences.dropFirst(sent.count))
        let now = Date()
        var ready: [String] = []
        for (i, s) in fresh.enumerated() {
            if i < streamCandidates.count, streamCandidates[i].text == s {
                if now.timeIntervalSince(streamCandidates[i].since) >= 0.6, ready.count == i { ready.append(s) }
            } else {
                streamCandidates = Array(streamCandidates.prefix(i)) + [(s, now)]
            }
        }
        if streamCandidates.count > fresh.count { streamCandidates = Array(streamCandidates.prefix(fresh.count)) }
        guard !ready.isEmpty else { return }
        streamCandidates.removeFirst(ready.count)
        submitStreamGroup(ready.joined(separator: " "))
    }

    private func submitStreamGroup(_ raw: String) {
        let index = streamGroups.count
        streamGroups.append(raw)
        let epoch = streamEpoch, route = self.route(), level = self.effectiveLevel
        let dictionary = store?.dictionaryTerms() ?? []
        let corrector = makeCorrector(dictionary)
        enqueue { [weak self] done in
            guard let self, self.streamEpoch == epoch else { done(); return }
            let rules = self.rules(for: raw)
            guard !rules.isEmpty else { done(); return }
            self.cleanChunk(rules, preceding: self.streamPreceding(before: index), route: route, level: level,
                            dictionary: dictionary, corrector: corrector, onPartial: { _ in }) { chunk in
                if self.streamEpoch == epoch {
                    self.streamResults[index] = chunk
                    self.state.streamed = self.streamResults.count
                    Log.write("stream: chunk \(index) cleaned in \(chunk.ms)ms (\(chunk.accepted == true ? "llm" : "rules"))")
                }
                done()
            }
        }
    }

    /// Field text before the cursor plus everything cleaned so far.
    private func streamPreceding(before index: Int) -> String? {
        let cleaned = (0..<index).compactMap { streamResults[$0]?.text }.joined(separator: " ")
        let joined = [context?.precedingText ?? "", cleaned].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : String(joined.suffix(400))
    }

    // MARK: Finish

    /// Rules pass, plus spoken symbols and identifier casing in code style.
    private func rules(for raw: String) -> String {
        let text = processor.process(raw)
        return style == .code ? CodeDictation.apply(text) : text
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func finish(raw recognized: String) {
        engine = nil
        endRecordingExtras()
        let raw = applyTrigger(recognized)
        let rulesText = rules(for: raw)
        Log.write("final: raw=\"\(raw)\" rules=\"\(rulesText)\"")
        guard !rulesText.isEmpty else {
            resetStream()
            showError("Didn't catch any speech")
            return
        }
        if let selected = context?.selectedText, !selected.isEmpty, CleanupPrompt.isCommand(rulesText) {
            resetStream()
            runCommand(rulesText, on: selected, raw: raw)
            return
        }

        let level = self.effectiveLevel
        let dictionary = store?.dictionaryTerms() ?? []
        let corrector = makeCorrector(dictionary)
        let route = level == .off ? Route.unavailable("off") : self.route()
        let gen = generation
        state.phase = .processing

        // Reuse sentences cleaned while talking when the final transcript
        // still starts with them and no correction reaches across.
        var remainingRules = rulesText
        if !streamGroups.isEmpty {
            let trimmedRaw = raw.trimmingCharacters(in: .whitespaces)
            let layoutCommand = raw.range(of: "(?i)\\b(new line|new paragraph|number (one|1)|bullet)\\b",
                                          options: .regularExpression) != nil
            // Keep the longest run of streamed chunks the final transcript still
            // starts with (the recognizer may re-punctuate the end in its final pass).
            var kept = 0
            if !streamBroken, !layoutCommand {
                for k in stride(from: streamGroups.count, through: 1, by: -1) {
                    let streamed = streamGroups.prefix(k).joined(separator: " ")
                    // Words, not characters: a final pass may only re-punctuate (B2).
                    guard let tail = SentenceSplitter.remainder(of: trimmedRaw, afterWordsOf: streamed) else { continue }
                    let pieces = streamGroups.prefix(k).map(rules(for:)) + (tail.isEmpty ? [] : [rules(for: tail)])
                    if Faithfulness.normalizedWords(pieces.joined(separator: " ")) == Faithfulness.normalizedWords(rulesText) {
                        kept = k
                        remainingRules = tail.isEmpty ? "" : rules(for: tail)
                    }
                    break
                }
            }
            if kept > 0 {
                if kept < streamGroups.count {
                    Log.write("stream: final transcript changed after chunk \(kept - 1); re-cleaning from there")
                    streamGroups = Array(streamGroups.prefix(kept))
                }
                Log.write("stream: reusing \(kept) chunk(s); \(CleanupPrompt.wordCount(remainingRules)) words left at key-up")
            } else {
                Log.write("stream: final transcript differs from the streamed text; cleaning the whole text")
                resetStream()
            }
        }

        let streamCount = streamGroups.count
        let epoch = streamEpoch
        let segments = remainingRules.isEmpty ? [] : SentenceSplitter.segments(remainingRules)
        var tailChunks: [Int: Chunk] = [:]
        for (i, segment) in segments.enumerated() {
            enqueue { [weak self] done in
                guard let self, self.generation == gen else { done(); return }
                let before = (0..<streamCount).compactMap { self.streamResults[$0]?.text }
                    + (0..<i).compactMap { tailChunks[$0].map { $0.text } }
                let preceding = ([self.context?.precedingText ?? ""] + before).filter { !$0.isEmpty }.joined(separator: " ")
                self.cleanChunk(segment.text, preceding: preceding.isEmpty ? nil : String(preceding.suffix(400)),
                                route: route, level: level, dictionary: dictionary, corrector: corrector,
                                onPartial: { [weak self] partial in
                                    guard let self, self.generation == gen else { return }
                                    let done = before.joined(separator: " ")
                                    self.state.polished = done.isEmpty ? partial : done + " " + partial
                                }) { chunk in
                    tailChunks[i] = chunk
                    done()
                }
            }
        }
        enqueue { [weak self] done in
            defer { done() }
            guard let self, self.generation == gen else { return }
            var chunks: [(Chunk, String)] = []
            if streamCount > 0, self.streamEpoch == epoch {
                chunks = (0..<streamCount).compactMap { self.streamResults[$0] }.map { ($0, " ") }
                if chunks.count < streamCount { chunks = [] }
            }
            if chunks.isEmpty && streamCount > 0 {
                // Streamed chunks went missing: clean everything now instead.
                Log.write("stream: chunks incomplete; cleaning the whole text")
                self.resetStream()
                self.cleanWhole(rulesText, raw: raw, route: route, level: level, dictionary: dictionary, corrector: corrector)
                return
            }
            if !chunks.isEmpty, segments.isEmpty { chunks[chunks.count - 1].1 = "" }
            for (i, segment) in segments.enumerated() {
                guard let c = tailChunks[i] else { continue }
                chunks.append((c, segment.separator))
            }
            self.resetStream()
            self.complete(chunks, raw: raw, rulesText: rulesText, level: level, dictionary: dictionary)
        }
    }

    /// Fallback when streamed results can't be used: plain chunked cleanup.
    private func cleanWhole(_ rulesText: String, raw: String, route: Route, level: CleanupLevel,
                            dictionary: [String], corrector: VocabularyCorrector) {
        let gen = generation
        let segments = SentenceSplitter.segments(rulesText)
        var results: [Int: Chunk] = [:]
        for (i, segment) in segments.enumerated() {
            enqueue { [weak self] done in
                guard let self, self.generation == gen else { done(); return }
                let before = (0..<i).compactMap { results[$0]?.text }
                let preceding = ([self.context?.precedingText ?? ""] + before).filter { !$0.isEmpty }.joined(separator: " ")
                self.cleanChunk(segment.text, preceding: preceding.isEmpty ? nil : String(preceding.suffix(400)),
                                route: route, level: level, dictionary: dictionary, corrector: corrector,
                                onPartial: { _ in }) { chunk in
                    results[i] = chunk
                    done()
                }
            }
        }
        enqueue { [weak self] done in
            defer { done() }
            guard let self, self.generation == gen else { return }
            let chunks = segments.indices.compactMap { i in results[i].map { ($0, segments[i].separator) } }
            self.complete(chunks, raw: raw, rulesText: rulesText, level: level, dictionary: dictionary)
        }
    }

    /// Joins cleaned chunks, records the sample, and inserts.
    private func complete(_ chunks: [(Chunk, String)], raw: String, rulesText: String,
                          level: CleanupLevel, dictionary: [String]) {
        guard !chunks.isEmpty else { showError("Didn't catch any speech"); return }
        let text = chunks.map { $0.0.text + $0.1 }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let rawVersion = chunks.map { $0.0.rulesText + $0.1 }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let keyUpMs = Int(Date().timeIntervalSince(stopRequestedAt) * 1000)
        let llmChunks = chunks.filter { $0.0.accepted == true }.count
        let modelRan = chunks.contains { $0.0.output != nil || $0.0.accepted != nil }

        var sample = Store.Sample(app: context?.bundleID ?? "?", style: style.rawValue, level: level.rawValue,
                                  engine: chunks.first?.0.engine ?? "rules", model: chunks.first?.0.model,
                                  promptVersion: CleanupPrompt.promptVersion, raw: raw,
                                  rules: chunks.map { $0.0.rules + $0.1 }.joined().trimmingCharacters(in: .whitespacesAndNewlines),
                                  preceding: context?.precedingText, dictionary: dictionary, inserted: "")
        if modelRan {
            let outputs = chunks.map { $0.0.output }
            sample.llmOutput = outputs.contains(where: { $0 == nil }) ? nil
                : zip(outputs, chunks).map { $0!.trimmingCharacters(in: .whitespacesAndNewlines) + $1.1 }.joined()
            sample.accepted = llmChunks == chunks.count
            sample.rejectReason = chunks.compactMap { $0.0.reason }.first
        } else {
            sample.rejectReason = chunks.first?.0.reason
        }
        sample.latencyMs = keyUpMs
        sample.mode = mode?.name
        sample.asr = asrName
        sample.durationMs = Int(stopRequestedAt.timeIntervalSince(startedAt) * 1000)
        let source: String
        if llmChunks == chunks.count, modelRan {
            source = "llm"
        } else if llmChunks > 0 {
            source = "llm \(llmChunks)/\(chunks.count)"
        } else {
            source = "rules" + (chunks.first?.0.reason.map { " (\($0))" } ?? "")
        }
        let engineMs = chunks.map { $0.0.ms }.reduce(0, +)
        Log.write("llm[\(sample.engine)]: \(chunks.count) chunk(s), key-up→ready \(keyUpMs)ms, model time \(engineMs)ms \"\(text)\"")
        // Snippet tokens restart at ⟦1⟧ per chunk, so multi-chunk samples with
        // tokens can't be rebuilt faithfully for training.
        if chunks.count > 1, chunks.contains(where: { $0.0.hasTokens }) { sample.label = "exclude" }
        let changed = source.hasPrefix("llm") ? EditDiff.changedFraction(rawVersion, text) : 0
        insert(text, rawVersion: rawVersion, raw: raw, source: source, sample: sample, changed: changed)
    }

    // MARK: Command mode (G10)

    private func runCommand(_ instruction: String, on selected: String, raw: String) {
        let route = self.route()
        guard let runner = runner(for: route) else {
            showError("Command mode needs a model (none ready)")
            return
        }
        Log.write("command: \"\(instruction)\" on \((selected as NSString).length) chars")
        state.phase = .processing
        state.target = "Command · \(instruction.prefix(30))"
        let request = CleanupRequest(transcript: instruction, style: style,
                                     level: effectiveLevel == .off ? .light : effectiveLevel,
                                     selectedText: selected)
        let gen = generation
        let started = Date()
        runner.run(request, { [weak self] partial in
            guard let self, self.generation == gen else { return }
            self.state.polished = partial
        }, { [weak self] output, reason in
            guard let self, self.generation == gen else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard let output, let text = CleanupPrompt.acceptCommand(output: output) else {
                Log.write("command: failed after \(ms)ms (\(reason)) output=\"\(output ?? "")\"")
                self.showError("Couldn't apply \"\(instruction.prefix(40))\"")
                return
            }
            Log.write("command[\(runner.engine)]: \(ms)ms \"\(text)\"")
            // Undo restores the original selection.
            self.insert(text, rawVersion: selected, raw: raw, source: "command", sample: nil, changed: 1, spacing: false)
        })
    }

    // MARK: Insert

    /// The most recent insertion, for undo to raw (⌃⌥Z).
    private struct LastInsertion {
        let context: FocusContext
        let element: AXUIElement?
        let location: Int?
        let method: TextInserter.Method
        let inserted: String
        let rawVersion: String
        let sampleID: Int64?
        let at: Date
    }

    private var lastInsertion: LastInsertion?

    var canUndoToRaw: Bool {
        guard let last = lastInsertion else { return false }
        return Date().timeIntervalSince(last.at) < 120 && last.rawVersion != last.inserted
    }

    private func insert(_ cleaned: String, rawVersion: String, raw: String, source: String,
                        sample: Store.Sample?, changed: Double, spacing: Bool = true) {
        let ctx = context
        let dictionary = store?.dictionaryTerms() ?? []
        func spaced(_ s: String) -> String {
            guard spacing else { return s }
            return SmartSpacing.adjust(s, preceding: ctx?.precedingText, following: ctx?.followingText,
                                       keepCapitalized: dictionary, isCommonWord: CommonWords.shared.isLowercasable)
        }
        let text = spaced(cleaned)
        let rawSpaced = spaced(rawVersion)
        lastText = text.trimmingCharacters(in: .whitespaces)
        let storable = PrivacyPolicy.shouldStore(bundleID: ctx?.bundleID, store: store)

        // Our own window (onboarding "Try it").
        if ctx?.pid == ProcessInfo.processInfo.processIdentifier, let target = localInsertTarget {
            target(cleaned)
            Log.write("inserted into Saywell window [\(source)] \"\(cleaned)\"")
            flashInserted(note: "")
            return
        }
        // G4 target lock: never type into a window the user switched to.
        if let ctx, FocusCheck.moved(from: ctx) {
            TextInserter.copyToClipboard(text.trimmingCharacters(in: .whitespaces))
            Log.write("insert: focus moved since the trigger; copied instead [\(source)] \"\(text)\"")
            if storable {
                store?.addHistory(app: ctx.bundleID ?? "?", raw: raw, cleaned: text, method: "clipboard (focus moved), \(source)")
            }
            showError("Copied — focus moved. Press ⌘V to paste")
            return
        }

        let override = store?.setting("insert.\(ctx?.bundleID ?? "")").flatMap(TextInserter.Method.init(rawValue:))
        TextInserter.insert(text, context: ctx, override: override, keepOnClipboard: keepOnClipboard) { [weak self] result in
            guard let self else { return }
            Log.write("inserted via \(result.method.rawValue) [\(source)] \"\(text)\"")
            if storable, ctx?.bundleID != Bundle.main.bundleIdentifier {
                self.store?.recordUsage(app: ctx?.bundleID ?? "?", rawWords: CleanupPrompt.wordCount(raw),
                                        words: CleanupPrompt.wordCount(text),
                                        durationMs: Int(self.stopRequestedAt.timeIntervalSince(self.startedAt) * 1000),
                                        asr: self.asrName, language: DictationEngine.localeIdentifier)
            }
            if storable {
                self.store?.addHistory(app: ctx?.bundleID ?? "?", raw: raw, cleaned: text,
                                       method: "\(result.method.rawValue), \(source)")
                self.store?.recordTermUsage(in: text, app: ctx?.bundleID ?? "?")
            } else {
                Log.write("privacy: \(ctx?.bundleID ?? "?") is on the deny list; nothing stored")
            }
            switch result.method {
            case .clipboard:
                Log.write("training: no sample (text only reached the clipboard)")
                self.showError("On clipboard — press ⌘V (grant Accessibility)")
            case .accessibility, .paste:
                // Only after a real insert, so `inserted` is what the user got.
                var sampleID: Int64?
                if var sample, storable, self.captureTraining, ctx?.isSecure != true {
                    sample.inserted = text
                    let label = sample.label
                    sampleID = self.store?.addSample(sample)
                    if let label, let sampleID { self.store?.setSampleLabel(id: sampleID, label: label) }
                    Log.write("training: sample \(sampleID ?? 0) engine=\(sample.engine) accepted=\(sample.accepted.map(String.init) ?? "-")")
                }
                if let ctx {
                    self.lastInsertion = LastInsertion(context: ctx, element: result.element, location: result.location,
                                                       method: result.method, inserted: text, rawVersion: rawSpaced,
                                                       sampleID: sampleID, at: Date())
                }
                // G1: say so when the model changed a lot, and offer the raw text.
                let note = changed > 0.3 && rawSpaced != text ? "Polished ✓ · Raw ⌃⌥Z" : ""
                self.flashInserted(note: note)
                if let element = result.element, let location = result.location {
                    self.watcher.watch(element: element, location: location, inserted: text, sampleID: sampleID)
                }
            }
        }
    }

    // MARK: Undo to raw (G1)

    /// Replaces the last insertion with the rules-only text (or, after a
    /// command, the original selection). Marks the sample bad: a free
    /// negative training signal.
    func undoToRaw() {
        guard let last = lastInsertion, canUndoToRaw else {
            showError("Nothing to revert")
            return
        }
        lastInsertion = nil
        watcher.stop()
        if let id = last.sampleID { store?.setSampleLabel(id: id, label: "bad") }
        Log.write("undo-to-raw: sample=\(last.sampleID.map(String.init) ?? "-") \"\(last.inserted)\" → \"\(last.rawVersion)\"")
        let length = (last.inserted as NSString).length
        guard !FocusCheck.moved(from: last.context), let element = last.element, let location = last.location,
              ContextProvider.text(in: element, startingAt: location, length: length) == last.inserted else {
            TextInserter.copyToClipboard(last.rawVersion.trimmingCharacters(in: .whitespaces))
            showError("Raw text copied — select the text and press ⌘V")
            return
        }
        TextInserter.replace(location: location, length: length, with: last.rawVersion, element: element,
                             allowAccessibilityWrite: last.method == .accessibility) { [weak self] ok in
            if ok {
                Log.write("undo-to-raw: replaced in place")
                self?.flashInserted(note: "Reverted to raw")
            } else {
                TextInserter.copyToClipboard(last.rawVersion.trimmingCharacters(in: .whitespaces))
                self?.showError("Raw text copied — select the text and press ⌘V")
            }
        }
    }

    // MARK: Pill

    private func flashInserted(note: String) {
        state.note = note
        state.phase = .inserted
        panel.layout(expanded: true, animated: true)
        let seconds = note.isEmpty ? 1.2 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if case .inserted = self?.state.phase { self?.collapse() }
        }
    }

    private func collapse() {
        state.phase = .idle
        state.transcript = ""
        state.polished = ""
        state.note = ""
        panel.layout(expanded: false, animated: true)
    }

    func showError(_ message: String) {
        state.phase = .error(message)
        panel.layout(expanded: true, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if case .error = self?.state.phase { self?.collapse() }
        }
    }
}
