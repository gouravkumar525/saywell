import AppKit
import Combine
import AVFoundation
import LocalFlowCore
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private var iconWatch: AnyCancellable?
    private var noteWatch: AnyCancellable?
    private var cardsWatch: AnyCancellable?
    private var hubWatch: AnyCancellable?
    private var panel: NotchPanel!
    private var bottomPill: BottomPill!
    private var statusItem: NSStatusItem!
    private var session: SessionController!
    private var hotkeys: HotkeyManager!
    private var settings: SettingsWindowController?
    private var noteTaker: NoteTaker?
    private var hub: HubWindowController?
    private let agents = AgentCenter()
    private let agentServer = AgentServer()
    private var onboarding: OnboardingWindowController?
    private var trainer: ModelTrainer?
    private let updater = Updater()
    private var store: Store?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) ax=\(TextInserter.hasAccessibilityPermission()) listen=\(CGPreflightListenEventAccess()) llm=\(CleanupClient.availabilityDescription)")
        do {
            store = try Store()
        } catch {
            Log.write("store: \(error.localizedDescription)")
        }
        if let store {
            settings = SettingsWindowController(store: store)
            if let days = SettingsModel.retentionDays(in: store) {
                let removed = store.pruneSamples(olderThanDays: days)
                if removed > 0 { Log.write("training: pruned \(removed) samples older than \(days) days") }
            }
        }

        panel = NotchPanel(state: state, toggle: { [weak self] in self?.session.toggle() },
                           undo: { [weak self] in self?.session.undoToRaw() })
        session = SessionController(state: state, panel: panel, store: store)
        state.showSprig = store?.setting("sprig.show") != "off"
        if let store {
            let mlx = session.mlx
            // Notes use Qwen3 when it's on disk (loaded on demand, freed when idle like
            // dictation), else Apple's on-device model.
            let qwenSpec = CleanupEngine.qwen3.modelSpec(store: store)
            let ensureQwen: () async -> Bool = {
                guard let spec = qwenSpec, MLXCleanupClient.isDownloaded(spec) else { return false }
                for _ in 0..<240 {
                    if mlx.isReady(.qwen3) { return true }
                    let loading = await MainActor.run { mlx.isLoading }
                    if !loading { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if mlx.isReady(.qwen3) { return true }
                return await withCheckedContinuation { c in
                    DispatchQueue.main.async { mlx.load(.qwen3, spec: spec, allowDownload: false) { c.resume(returning: $0) } }
                }
            }
            let generate: (String, String, Int) async -> String? = { instructions, prompt, maxTokens in
                if await ensureQwen(),
                   let text = await mlx.generate(instructions: instructions, prompt: prompt, maxTokens: maxTokens) { return text }
                return await CleanupClient.generate(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
            }
            let taker = NoteTaker(store: store, mic: session.mic, generate: generate)
            // Each line: the dictation rules, then a light model pass, kept only if it
            // passes the same faithfulness check as dictation (no added or lost content).
            taker.cleanLine = { [weak self] heard in
                let language = await MainActor.run { self?.session.languageID ?? SpeechLanguage.fallback }
                let english = SpeechLanguage.isEnglish(language)
                let rules = TextProcessor(englishRules: english).process(heard)
                guard !rules.isEmpty else { return nil }
                let request = CleanupRequest(transcript: rules, style: .neutral, level: .light,
                                             language: english ? nil : SpeechLanguage.englishName(language))
                let maxTokens = max(48, CleanupPrompt.wordCount(rules) * 3 + 24)
                guard let output = await generate(CleanupPrompt.instructions(for: request), CleanupPrompt.userPrompt(for: request), maxTokens)
                else { return rules }
                return CleanupPrompt.accept(output: output, input: rules, level: .light) ?? rules
            }
            taker.onRecordingChanged = { [weak self] on in
                guard let self else { return }
                self.state.noteStarted = on ? Date() : nil
                self.state.noteLine = ""
                self.state.takingNotes = on
                self.panel.layout(expanded: on, animated: true)
            }
            state.stopRecording = { [weak self] in self?.toggleCallRecording() }
            state.recordMeeting = { [weak self] in
                guard let self, let app = self.state.meetingPrompt else { return }
                self.beginRecording(meeting: app)
            }
            state.dismissMeeting = { [weak self] in self?.dismissMeetingPrompt() }
            noteWatch = taker.$recording.receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let note, let last = note.liveLines.last else { return }
                let who = note.speaker(last.speaker)?.name ?? ""
                self?.state.noteLine = "\(who): \(last.text)"
            }
            noteTaker = taker
            settings?.notes = NotesViewModel(taker: taker)
            settings?.record = { [weak self] in self?.toggleCallRecording() }
            session.micBusyReason = { [weak taker] in
                taker?.isRecording == true ? "Recording a call — stop it to dictate" : nil
            }
            taker.resumeUnfinished()
            DispatchQueue.main.async { self.updateMeetingWatch() }
        }
        // C6: Claude Code in the notch.
        state.agents = agents
        agents.cardsEnabled = store?.setting("agents.cards") != "off"
        agents.onChange = { [weak self] in
            guard let self else { return }
            let card = self.agents.current.map { $0.isQuestion ? "question" : "approval" }
            if card != self.state.agentCard {
                self.state.agentCard = card
                self.panel.layout(expanded: card != nil, animated: true)
                if card == nil, case .idle = self.state.phase, !self.state.takingNotes {
                    self.panel.layout(expanded: false, animated: true)
                }
            }
            if self.agents.isWorking != self.state.agentWorking { self.state.agentWorking = self.agents.isWorking }
        }
        agents.onFinished = { [weak self] in
            self?.state.agentDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.state.agentDone = false }
        }
        agentServer.onEvent = { [weak self] event, fd in self?.agents.handle(event, fd: fd) }
        agentServer.start()
        if ClaudeHooks.isInstalled() { try? ClaudeHooks.installHelper() }
        settings?.agents = AgentsViewModel(center: agents)
        cardsWatch = agents.$cardsEnabled.dropFirst().sink { [weak self] on in self?.store?.setSetting("agents.cards", on ? "on" : "off") }
        bottomPill = BottomPill(state: state,
                                dictate: { [weak self] in self?.session.toggle() },
                                record: { [weak self] in self?.toggleCallRecording() },
                                settings: { [weak self] in self?.openSettings() })
        applyPillPosition()
        onboarding = OnboardingWindowController(session: session, store: store)
        if let store {
            trainer = ModelTrainer(store: store)
            trainer?.onFinish = { [weak self] model, message in self?.trainingFinished(model: model, message: message) }
        }
        session.onListeningChanged = { [weak self] listening in
            self?.statusItem.menu?.items.first { $0.action == #selector(AppDelegate.menuToggle) }?.title =
                listening ? "Stop Dictation (⌃⌥D)" : "Start Dictation (⌃⌥D)"
            if !listening { self?.hotkeys.reset() }
        }

        hotkeys = HotkeyManager()
        hotkeys.holdKey = holdKey
        hotkeys.onPasteLast = { [weak self] in self?.session.pasteLast() }
        hotkeys.onPushLock = { [weak self] in self?.session.pushLock() }
        hotkeys.onEscape = { [weak self] in self?.session.escape() }
        hotkeys.onToggle = { [weak self] in self?.session.toggle() }
        hotkeys.onUndoToRaw = { [weak self] in self?.session.undoToRaw() }
        hotkeys.onPushStart = { [weak self] in self?.session.pushStart() }
        hotkeys.onPushEnd = { [weak self] in self?.session.pushEnd() }
        hotkeys.onPushCancel = { [weak self] in self?.session.pushCancel() }
        setUpStatusItem()

        DictationEngine.requestPermissions { [weak self] result in
            if case .failure(let error) = result {
                Log.write("permissions: \(error.localizedDescription)")
                self?.session.showError(error.localizedDescription)
            } else {
                Log.write("permissions: mic+speech granted")
            }
        }
        // Nudge the accessibility prompt early so insertion and Fn work later.
        _ = TextInserter.hasAccessibilityPermission(promptIfNeeded: true)
        // Load a local model in the background if one is selected (never downloads).
        session.loadSelectedEngine()
        session.loadSpeechBackend()
        setUpHub()
        // C7: opening Saywell shows its window (it asks your name the first time).
        if !CommandLine.arguments.contains("--enable-test-control") || store?.setting("user.name") == nil { hub?.show() }
        if onboarding?.shouldShowAtLaunch == true, store?.setting("user.name") != nil { onboarding?.show() }
        if CommandLine.arguments.contains("--enable-test-control") { enableTestControl() }
    }

    /// Lets the end-to-end test script drive the app (start/stop/undo) through
    /// distributed notifications. Off unless launched with --enable-test-control,
    /// so other apps can't use Saywell's microphone permission.
    private func enableTestControl() {
        Log.write("test-control: enabled")
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.gourav.saywell.test"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let self, let action = note.object as? String else { return }
            Log.write("test-control: \(action)")
            switch action {
            case "toggle": self.session.toggle()
            case "undo": self.session.undoToRaw()
            case "cancel": self.session.escape()
            case "record": self.toggleCallRecording()
            case "meeting:ask", "meeting:always", "meeting:off":
                self.autoRecord = AutoRecord(rawValue: String(action.dropFirst(8))) ?? .off
            case "micusers": Log.write("micusers: \(MicUsers.current())")
            case "agent:allow": self.agents.decide(.allow)
            case "agent:deny": self.agents.decide(.deny)
            case "agent:always": self.agents.decide(.always)
            case "agent:terminal": self.agents.toTerminal()
            case "agent:next": self.agents.next()
            case "notes": self.openNotes()
            case "pill:notch", "pill:bottom", "pill:left", "pill:right":
                self.pillPosition = PillPosition(rawValue: String(action.dropFirst(5))) ?? .notch
            case "insights": Log.write("insights: \(self.store.map { UsageInsights.compute($0.usageRows(), watched: $0.insightRows()) }.map { "words=\($0.wordsAllTime) dictations=\($0.dictations) saved=\(Int($0.minutesSaved))min wpm=\(Int($0.wordsPerMinute ?? 0)) streak=\($0.streakDays)" } ?? "-")")
            case "pastelast": self.session.pasteLast()
            case "lock": self.session.pushLock()
            case "push": self.session.pushStart()
            case "memory": Log.write("memory: \(MemoryInfo.format(MemoryInfo.footprint().current)) (peak \(MemoryInfo.format(MemoryInfo.footprint().peak)))")
            default:
                if action.hasPrefix("hub:") {
                    self.openHub(page: HubPage(rawValue: String(action.dropFirst(4))))
                } else if action.hasPrefix("username:") {
                    // username:<name> sets it; "username:" clears it (shows the name step again).
                    let name = String(action.dropFirst(9))
                    self.store?.setSetting("user.name", name.isEmpty ? nil : name)
                    self.hub?.model.userName = name
                } else if action.hasPrefix("agent:choose:") {
                    self.agents.choose(String(action.dropFirst(13)))
                } else if action.hasPrefix("sprig:") {
                    // sprig:<state> previews Sprig with the pill open; sprig:off closes it.
                    let name = String(action.dropFirst(6))
                    self.state.sprigPreview = name == "off" ? nil : name
                    self.panel.layout(expanded: name != "off", animated: true)
                } else if action.hasPrefix("sprigplay:") {
                    self.state.sprig.play(String(action.dropFirst(10)))
                } else if action.hasPrefix("sprigpoke") {
                    self.state.sprig.poke()
                } else if action.hasPrefix("language:") {
                    self.session.languageSetting = String(action.dropFirst(9))
                    Log.write("language: \(self.session.languageID)")
                } else if action.hasPrefix("holdkey:"), let k = HoldKey(rawValue: String(action.dropFirst(8))) {
                    self.holdKey = k
                    self.hotkeys.holdKey = k
                } else if action.hasPrefix("engine:"), let e = CleanupEngine(rawValue: String(action.dropFirst(7))) {
                    self.session.selectEngine(e)
                } else if action.hasPrefix("level:"), let l = CleanupLevel(rawValue: String(action.dropFirst(6))) {
                    self.session.level = l
                } else if action.hasPrefix("asr:"), let b = SpeechBackend(rawValue: String(action.dropFirst(4))) {
                    self.session.speechBackend = b
                    self.session.loadSpeechBackend()
                } else if action.hasPrefix("addmode:") {
                    // addmode:<name>|<trigger>|<instructions> (E2E tests; removed with removemode:<name>)
                    let f = action.dropFirst(8).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard f.count == 3 else { return }
                    self.session.modes = self.session.modes.filter { $0.name != f[0] }
                        + [WritingMode(name: f[0], trigger: f[1], instructions: f[2])]
                } else if action.hasPrefix("removemode:") {
                    let name = String(action.dropFirst(11))
                    self.session.modes = self.session.modes.filter { $0.name != name }
                }
            }
        }
    }

    /// `hotkey.hold`; older installs only had `fn.enabled` (false → Off).
    private var holdKey: HoldKey {
        get {
            if let raw = store?.setting("hotkey.hold"), let key = HoldKey(rawValue: raw) { return key }
            return store?.setting("fn.enabled") == "false" ? .off : .fn
        }
        set { store?.setSetting("hotkey.hold", newValue.rawValue) }
    }

    // MARK: Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        // The menu-bar Sprig changes colour with what Saywell is doing.
        iconWatch = state.$phase.combineLatest(state.$showSprig, state.$takingNotes)
            .combineLatest(state.$agentCard, state.$agentWorking, state.$agentDone)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
                // The bottom pill moves to the display you're working on.
                if self?.state.isListening == true, self?.pillPosition != .notch { self?.bottomPill.place() }
            }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        menuNeedsUpdate(menu)
    }

    /// Rebuilt on every open so checkmarks and status stay current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Open Saywell…", #selector(openHubFromMenu)))
        menu.addItem(.separator())
        let listening = state.isListening
        menu.addItem(item(listening ? "Stop Dictation (⌃⌥D)" : "Start Dictation (⌃⌥D)", #selector(menuToggle)))
        let undo = item("Revert Last to Raw (⌃⌥Z)", #selector(menuUndo))
        undo.isEnabled = session.canUndoToRaw
        menu.addItem(undo)
        menu.addItem(.separator())

        let cleanupMenu = NSMenu()
        for level in CleanupLevel.allCases {
            let i = item(level.label, #selector(selectLevel(_:)))
            i.representedObject = level.rawValue
            i.state = session.level == level ? .on : .off
            cleanupMenu.addItem(i)
        }
        cleanupMenu.addItem(.separator())
        let header = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        header.isEnabled = false
        cleanupMenu.addItem(header)
        let selected = session.cleanupEngine
        for engine in CleanupEngine.allCases {
            let status: String
            if engine == .apple {
                status = CleanupClient.availabilityDescription
            } else if session.mlx.engine == engine {
                status = session.mlx.statusDescription
            } else {
                status = MLXCleanupClient.isDownloaded(engine.modelSpec(store: store) ?? "") ? "not loaded" : "download ~2.5 GB"
            }
            let i = item("\(engine.label) — \(status)", #selector(selectEngine(_:)))
            i.representedObject = engine.rawValue
            i.state = selected == engine ? .on : .off
            cleanupMenu.addItem(i)
        }
        if selected.isLocal && !session.mlx.isReady(selected) {
            let note = NSMenuItem(title: "  Uses Apple's model until the local one is ready", action: nil, keyEquivalent: "")
            note.isEnabled = false
            cleanupMenu.addItem(note)
        }
        // B3: delete a downloaded model (marker → unload → files).
        let removable = CleanupEngine.allCases.filter { engine in
            guard engine.isLocal, let spec = engine.modelSpec(store: store), let m = ModelManifest.pinned(for: spec) else { return false }
            return FileManager.default.fileExists(atPath: MLXCleanupClient.modelsDirectory.appendingPathComponent(m.folderName).path)
        }
        if !removable.isEmpty {
            let removeMenu = NSMenu()
            for engine in removable {
                let i = item(engine.label, #selector(removeModel(_:)))
                i.representedObject = engine.rawValue
                removeMenu.addItem(i)
            }
            let removeItem = NSMenuItem(title: "Remove Downloaded Model", action: nil, keyEquivalent: "")
            removeItem.submenu = removeMenu
            cleanupMenu.addItem(removeItem)
        }
        cleanupMenu.addItem(.separator())
        let stream = item("Clean Sentences While Talking", #selector(toggleStreaming))
        stream.state = session.streamingEnabled ? .on : .off
        cleanupMenu.addItem(stream)
        let idleMenu = NSMenu()
        for minutes in [5, 15, 60, 0] {
            let i = item(minutes == 0 ? "Never" : "After \(minutes) min", #selector(selectIdleUnload(_:)))
            i.tag = minutes
            i.state = session.idleUnloadMinutes == minutes ? .on : .off
            idleMenu.addItem(i)
        }
        let idleItem = NSMenuItem(title: "Unload Local Model When Idle", action: nil, keyEquivalent: "")
        idleItem.submenu = idleMenu
        cleanupMenu.addItem(idleItem)
        // B1: which recognizer turns speech into text.
        let asrMenu = NSMenu()
        for backend in SpeechBackend.allCases {
            let status = backend == .parakeet ? " — \(ParakeetService.shared.statusDescription)" : ""
            let i = item(backend.label + status, #selector(selectSpeechBackend(_:)))
            i.representedObject = backend.rawValue
            i.state = session.speechBackend == backend ? .on : .off
            asrMenu.addItem(i)
        }
        if let store {
            let rates = SpeechBackend.allCases.compactMap { b -> String? in
                let m = store.metrics(asr: b == .apple ? "sfspeech" : "parakeet")
                return m.noEditRate.map { String(format: "%@ %.0f%% (%d)", b == .apple ? "Apple" : "Parakeet", $0 * 100, m.watched) }
            }
            if !rates.isEmpty { asrMenu.addItem(info("No-edit rate: " + rates.joined(separator: " · "))) }
        }
        let asrItem = NSMenuItem(title: "Speech Recognizer", action: nil, keyEquivalent: "")
        asrItem.submenu = asrMenu
        menu.addItem(asrItem)

        // C2: language for Apple's recognizer; Parakeet detects it itself.
        let languageMenu = NSMenu()
        SessionController.refreshLocales()
        let current = session.languageID
        let auto = item("Automatic (\(SpeechLanguage.displayName(current)))", #selector(selectLanguage(_:)))
        auto.representedObject = SpeechLanguage.automatic
        auto.state = session.languageSetting == SpeechLanguage.automatic ? .on : .off
        languageMenu.addItem(auto)
        languageMenu.addItem(.separator())
        for id in session.languageChoices {
            let l = item(SpeechLanguage.displayName(id), #selector(selectLanguage(_:)))
            l.representedObject = id
            l.state = session.languageSetting == id ? .on : .off
            languageMenu.addItem(l)
        }
        languageMenu.addItem(.separator())
        languageMenu.addItem(item("More Languages… (add in Keyboard ▸ Dictation)", #selector(openDictationSettings)))
        languageMenu.addItem(info(session.speechBackend == .parakeet
            ? "Parakeet recognizes 25 languages by itself" : "Parakeet adds 25 languages offline"))
        languageMenu.addItem(info("Spoken numbers and \"scratch that\" work in English only"))
        let languageItem = NSMenuItem(title: "Language: \(SpeechLanguage.displayName(current))", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let cleanupItem = NSMenuItem(title: "AI Cleanup", action: nil, keyEquivalent: "")
        cleanupItem.submenu = cleanupMenu
        menu.addItem(cleanupItem)

        let keyMenu = NSMenu()
        for key in HoldKey.allCases {
            let k = item(key.label, #selector(selectHoldKey(_:)))
            k.representedObject = key.rawValue
            k.state = holdKey == key ? .on : .off
            keyMenu.addItem(k)
        }
        keyMenu.addItem(.separator())
        keyMenu.addItem(info("Hold to talk · tap twice for hands-free"))
        keyMenu.addItem(info("Esc cancels · ⌃⌘V pastes the last dictation"))
        let keyItem = NSMenuItem(title: "Hold Key to Talk: \(holdKey.label)", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)
        if holdKey != .off && !hotkeys.isKeyTapInstalled {
            let hint = NSMenuItem(title: "  The hold key needs Input Monitoring permission", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let preroll = item("Keep Mic Ready (catches first word, mic stays on)", #selector(togglePreroll))
        preroll.state = session.keepMicReady ? .on : .off
        menu.addItem(preroll)

        let keepClip = item("Keep Dictation on Clipboard", #selector(toggleKeepClipboard))
        keepClip.state = session.keepOnClipboard ? .on : .off
        menu.addItem(keepClip)
        let pillMenu = NSMenu()
        for position in PillPosition.allCases {
            let p = item(position.label, #selector(selectPillPosition(_:)))
            p.representedObject = position.rawValue
            p.state = pillPosition == position ? .on : .off
            pillMenu.addItem(p)
        }
        let pillItem = NSMenuItem(title: "Pill Position: \(pillPosition.label)", action: nil, keyEquivalent: "")
        pillItem.submenu = pillMenu
        menu.addItem(pillItem)
        let sprigItem = item("Show Sprig", #selector(toggleSprig))
        sprigItem.state = state.showSprig ? .on : .off
        menu.addItem(sprigItem)
        let sounds = item("Play Start/Stop Sounds", #selector(toggleSounds))
        sounds.state = session.soundsEnabled ? .on : .off
        menu.addItem(sounds)
        let names = item("Use Names on Screen for Spelling", #selector(toggleScreenNames))
        names.state = session.screenNamesEnabled ? .on : .off
        menu.addItem(names)
        let media = item("Pause Music While Dictating", #selector(togglePauseMedia))
        media.state = session.pauseMediaEnabled ? .on : .off
        menu.addItem(media)

        let autoMenu = NSMenu()
        for seconds in [0, 5, 10, 20] {
            let i = item(seconds == 0 ? "Off" : "After \(seconds)s of silence", #selector(selectAutoStop(_:)))
            i.tag = seconds
            i.state = session.autoStopSeconds == seconds ? .on : .off
            autoMenu.addItem(i)
        }
        let autoItem = NSMenuItem(title: "Auto-Stop (⌃⌥D mode)", action: nil, keyEquivalent: "")
        autoItem.submenu = autoMenu
        menu.addItem(autoItem)

        menu.addItem(.separator())
        // G5 / G8 / G7 status rows.
        menu.addItem(info("🔒 Offline: speech and AI run on this Mac; dictation audio is never saved"))
        let footprint = MemoryInfo.format(MemoryInfo.footprint().current)
        let loaded = session.mlx.isLoaded ? "\(session.mlx.engine?.label ?? "model") loaded" : "no local model loaded"
        menu.addItem(info("Memory: \(footprint) (\(loaded))"))
        if let store {
            let m = store.metrics()
            if let rate = m.noEditRate {
                menu.addItem(info(String(format: "No-edit rate: %.0f%% of %d dictations (30 days)", rate * 100, m.watched)))
            }
        }
        if let trainer {
            let title: String
            if trainer.isRunning {
                title = "Improving Your Model… (training)"
            } else {
                title = "Improve My Model… (\(trainer.newSampleCount)/\(trainer.minimumNewSamples) new samples)"
            }
            let improve = item(title, #selector(improveModel))
            improve.isEnabled = !trainer.isRunning && trainer.newSampleCount >= trainer.minimumNewSamples
            menu.addItem(improve)
        }
        menu.addItem(.separator())
        if let taker = noteTaker {
            menu.addItem(.separator())
            menu.addItem(item(taker.isRecording ? "Stop Recording Call" : "Record a Call…", #selector(toggleCallRecording)))
            let autoMenu = NSMenu()
            for (mode, title) in [(AutoRecord.off, "Off"), (.ask, "Ask Me in the Notch"), (.always, "Always Record")] {
                let m = item(title, #selector(selectAutoRecord(_:)))
                m.representedObject = mode.rawValue
                m.state = autoRecord == mode ? .on : .off
                autoMenu.addItem(m)
            }
            autoMenu.addItem(.separator())
            autoMenu.addItem(info("When Zoom, Teams or Webex starts a meeting;"))
            autoMenu.addItem(info("stops when the meeting ends"))
            let autoItem = NSMenuItem(title: "Auto-Record Meetings: \(autoRecord == .off ? "Off" : autoRecord == .ask ? "Ask" : "Always")",
                                      action: nil, keyEquivalent: "")
            autoItem.submenu = autoMenu
            menu.addItem(autoItem)
            menu.addItem(item("Notes…", #selector(openNotes)))
            menu.addItem(item(ClaudeHooks.isInstalled() ? "Claude Code: \(agents.sessions.count) session\(agents.sessions.count == 1 ? "" : "s")…"
                                                     : "Connect Claude Code…", #selector(openAgents)))
        }
        let settingsItem = item("Dictionary, Snippets, History & Privacy…", #selector(openSettings))
        settingsItem.isEnabled = settings != nil
        menu.addItem(settingsItem)
        menu.addItem(item("Set Up Saywell…", #selector(openOnboarding)))
        if updater.isEnabled {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(item("Acknowledgements…", #selector(openAcknowledgements)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Saywell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func menuToggle() { session.toggle() }

    @objc private func selectLevel(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let level = CleanupLevel(rawValue: raw) {
            session.level = level
        }
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = CleanupEngine(rawValue: raw) else { return }
        // G5: the model download is the app's only network use; ask first.
        if engine.isLocal, let spec = engine.modelSpec(store: store), !MLXCleanupClient.isDownloaded(spec) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Download \(engine.label)?"
            alert.informativeText = "Saywell will download \(spec) (about 2.5 GB) from huggingface.co. This is the only time Saywell uses the network; after that the model runs offline."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            session.selectEngine(engine, allowDownload: true)
            return
        }
        session.selectEngine(engine)
    }

    @objc private func menuUndo() { session.undoToRaw() }

    @objc private func selectSpeechBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let backend = SpeechBackend(rawValue: raw) else { return }
        if backend == .parakeet, !ParakeetService.isDownloaded {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Download Parakeet v3?"
            alert.informativeText = "Saywell will download NVIDIA's Parakeet TDT v3 speech model (about 460 MB, Core ML) from huggingface.co. It then runs offline on the Neural Engine."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            session.speechBackend = backend
            session.loadSpeechBackend(allowDownload: true)
            return
        }
        session.speechBackend = backend
        if backend == .parakeet { session.loadSpeechBackend() } else { ParakeetService.shared.unload() }
    }

    @objc private func removeModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = CleanupEngine(rawValue: raw),
              let spec = engine.modelSpec(store: store) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove \(engine.label)?"
        alert.informativeText = "This deletes the model from Saywell's models folder and frees its disk space. You can download it again from the Model menu."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.mlx.removeModel(spec: spec)
        if session.cleanupEngine == engine { session.selectEngine(.apple) }
    }

    @objc private func toggleStreaming() {
        store?.setSetting("stream.enabled", session.streamingEnabled ? "off" : "on")
    }

    @objc private func selectIdleUnload(_ sender: NSMenuItem) {
        session.idleUnloadMinutes = sender.tag
    }

    @objc private func togglePreroll() {
        session.keepMicReady.toggle()
    }

    @objc private func toggleKeepClipboard() {
        session.keepOnClipboard.toggle()
    }

    @objc private func toggleSounds() { session.soundsEnabled.toggle() }

    @objc private func togglePauseMedia() { session.pauseMediaEnabled.toggle() }

    @objc private func toggleScreenNames() { session.screenNamesEnabled.toggle() }

    @objc private func openOnboarding() { onboarding?.show() }

    @objc private func checkForUpdates() { updater.checkForUpdates() }

    /// Credits and licences for the models and libraries (THIRD_PARTY_NOTICES.md in the bundle).
    @objc private func openAcknowledgements() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func improveModel() {
        guard let trainer else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Fine-tune a personal model?"
        alert.informativeText = "Saywell will train on your \(trainer.newSampleCount) new dictations on this Mac (about 10–30 minutes, needs ~8 GB free RAM and ~/lf-mlx). It switches only if the new model scores at least as well on the bench. The local model is unloaded while training."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.mlx.unload()
        trainer.start(baseModel: CleanupEngine.qwen3.modelSpec(store: nil) ?? "")
    }

    private func trainingFinished(model: String?, message: String) {
        if let model {
            store?.setSetting("mlx.model.qwen3", model)
            session.selectEngine(.qwen3)
        } else {
            session.loadSelectedEngine()
        }
        session.showError(message)
    }

    @objc private func openDictationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// C4 setting `pill.position`.
    private var pillPosition: PillPosition {
        get { PillPosition(rawValue: store?.setting("pill.position") ?? "") ?? .notch }
        set { store?.setSetting("pill.position", newValue.rawValue); applyPillPosition() }
    }

    private func applyPillPosition() {
        let position = pillPosition
        panel.isEnabled = position == .notch
        if position == .notch {
            bottomPill.orderOut(nil)
        } else {
            bottomPill.position = position
            bottomPill.show()
        }
    }

    @objc private func selectPillPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = PillPosition(rawValue: raw) else { return }
        pillPosition = position
    }

    /// C5: Record Call / Stop Recording (menu, bottom pill, Notes tab). Asks for
    /// the model downloads it needs, and reminds you to tell people once.
    @objc private func toggleCallRecording() {
        guard let taker = noteTaker else { return }
        if taker.isRecording {
            taker.stop()
            return
        }
        beginRecording(meeting: nil)
    }

    /// Asks for what's missing (downloads, consent), then records. `meeting` is the
    /// detected Zoom/Teams meeting, when recording starts for one.
    private func beginRecording(meeting: String?) {
        state.meetingPrompt = nil
        if state.isListening { session.stop() }
        NSApp.activate(ignoringOtherApps: true)
        if !ParakeetService.isDownloaded {
            let alert = NSAlert()
            alert.messageText = "Notes need Parakeet"
            alert.informativeText = "Saywell transcribes calls with NVIDIA's Parakeet TDT v3 (about 460 MB) and separates voices with a small speaker model (about 22 MB), both downloaded from huggingface.co once. Everything then runs offline."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { try? await DiarizerService.shared.load(allowDownload: true) }
            ParakeetService.shared.load(allowDownload: true) { [weak self] ok in
                if ok { self?.startRecording(meeting: meeting) } else { self?.session.showError("Parakeet download failed") }
            }
            return
        }
        if !DiarizerService.isDownloaded {
            let alert = NSAlert()
            alert.messageText = "Download the speaker model?"
            alert.informativeText = "To tell people apart in the transcript, Saywell downloads a small speaker-separation model (about 22 MB, pyannote Community-1) from huggingface.co once. Without it, everyone else on the call is one speaker."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { try? await DiarizerService.shared.load(allowDownload: true) }
            }
        }
        if !ParakeetService.shared.isReady {
            session.showError("Loading Parakeet…")
            ParakeetService.shared.load { [weak self] ok in
                if ok { self?.startRecording(meeting: meeting) } else { self?.session.showError("Parakeet couldn't load") }
            }
            return
        }
        startRecording(meeting: meeting)
    }

    private func startRecording(meeting: String? = nil) {
        guard let taker = noteTaker else { return }
        if store?.setting("notes.consentShown") == nil {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Tell people you're recording"
            alert.informativeText = "Saywell records your microphone and what your Mac plays, then writes a transcript and notes on this Mac. No bot joins the call, so let the other people know. The first time, macOS asks to allow System Audio Recording."
            alert.addButton(withTitle: "Start Recording")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store?.setSetting("notes.consentShown", "1")
        }
        let app = meeting ?? NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0.localizedName }
        if let error = taker.start(app: app, meeting: meeting) { session.showError(error) }
    }

    // MARK: Meetings (auto-record)

    enum AutoRecord: String { case off, ask, always }

    /// Setting `notes.auto`: start notes when a Zoom/Teams/Webex meeting starts.
    private var autoRecord: AutoRecord {
        get { AutoRecord(rawValue: store?.setting("notes.auto") ?? "") ?? .off }
        set {
            store?.setSetting("notes.auto", newValue.rawValue)
            updateMeetingWatch()
        }
    }

    private var meetingDetector = MeetingDetector()
    private var meetingTimer: Timer?
    private var promptExpiry: DispatchWorkItem?

    private func updateMeetingWatch() {
        meetingTimer?.invalidate()
        meetingTimer = nil
        guard autoRecord != .off, noteTaker != nil else { return }
        meetingDetector = MeetingDetector()
        // Every 2 s: which apps hold the microphone (process metadata only, no audio).
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.meetingTick() }
        Log.write("meetings: watching Zoom, Teams and Webex (\(autoRecord.rawValue))")
    }

    private func meetingTick() {
        guard let event = meetingDetector.update(micUsers: MicUsers.current(),
                                                 at: ProcessInfo.processInfo.systemUptime) else { return }
        switch event {
        case .started(let app):
            Log.write("meetings: \(app) meeting started")
            guard noteTaker?.isRecording == false else { return }
            if autoRecord == .always {
                beginRecording(meeting: app)
            } else {
                state.meetingPrompt = app
                panel.layout(expanded: true, animated: true)
                promptExpiry?.cancel()
                let expiry = DispatchWorkItem { [weak self] in self?.dismissMeetingPrompt() }
                promptExpiry = expiry
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiry)
            }
        case .ended(let app):
            Log.write("meetings: \(app) meeting ended")
            if state.meetingPrompt == app { dismissMeetingPrompt() }
            if let taker = noteTaker, taker.isRecording, taker.meetingApp == app { taker.stop() }
        }
    }

    private func dismissMeetingPrompt() {
        promptExpiry?.cancel()
        guard state.meetingPrompt != nil else { return }
        state.meetingPrompt = nil
        panel.layout(expanded: state.isExpanded, animated: true)
    }

    @objc private func selectAutoRecord(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AutoRecord(rawValue: raw) else { return }
        if mode == .always, store?.setting("notes.consentShown") == nil {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Record every Zoom, Teams and Webex meeting?"
            alert.informativeText = "When one of these apps starts using the microphone, Saywell records the meeting and writes a transcript and notes on this Mac. No bot joins, so let people know you take notes. You can stop any recording from the notch."
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store?.setSetting("notes.consentShown", "1")
        }
        autoRecord = mode
    }

    @objc private func openNotes() { openHub(page: .notetaker) }
    @objc private func openAgents() { openHub(page: .agents) }
    @objc private func openHubFromMenu() { openHub(page: nil) }

    func openHub(page: HubPage?) {
        if hub == nil { setUpHub() }
        hub?.show(page: page)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub(page: nil)
        return true
    }

    // MARK: Hub (C7)

    private func setUpHub() {
        guard hub == nil, let store else { return }
        let hubSettings = HubSettings()
        hubSettings.read = { [weak self] in self?.hubValues() ?? [:] }
        hubSettings.apply = { [weak self] key, value in self?.applyHubSetting(key, value) }
        hubSettings.options = { [weak self] key in
            guard let self, key == "language" else { return [] }
            SessionController.refreshLocales()
            return [(SpeechLanguage.automatic, "Automatic (\(SpeechLanguage.displayName(self.session.languageID)))")]
                + self.session.languageChoices.map { ($0, SpeechLanguage.displayName($0)) }
        }
        let model = HubModel(store: store, hubSettings: hubSettings)
        model.notes = settings?.notes
        model.agents = settings?.agents
        model.recordCall = { [weak self] in self?.toggleCallRecording() }
        model.openSetup = { [weak self] in self?.onboarding?.show() }
        hub = HubWindowController(model: model)
        hubWatch = state.$phase.combineLatest(state.$takingNotes).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateHubStatus()
        }
        updateHubStatus()
    }

    private func updateHubStatus() {
        guard let model = hub?.model else { return }
        if state.takingNotes { model.status = "Recording a call"; return }
        switch state.phase {
        case .listening: model.status = "Listening…"
        case .processing: model.status = "Polishing…"
        default:
            model.status = holdKey == .off ? "Ready · ⌃⌥D to dictate" : "Ready · hold \(holdKey.label)"
            if case .inserted = state.phase { model.reload() }
        }
    }

    private func hubValues() -> [String: String] {
        func flag(_ b: Bool) -> String { b ? "on" : "off" }
        return [
            "holdKey": holdKey.rawValue, "recognizer": session.speechBackend.rawValue, "language": session.languageSetting,
            "autoStop": String(session.autoStopSeconds), "streaming": flag(session.streamingEnabled),
            "keepMicReady": flag(session.keepMicReady), "keepClipboard": flag(session.keepOnClipboard),
            "screenNames": flag(session.screenNamesEnabled), "level": session.level.rawValue,
            "engine": session.cleanupEngine.rawValue, "idleUnload": String(session.idleUnloadMinutes),
            "autoRecord": autoRecord.rawValue, "pillPosition": pillPosition.rawValue, "showSprig": flag(state.showSprig),
            "sounds": flag(session.soundsEnabled), "pauseMusic": flag(session.pauseMediaEnabled),
        ]
    }

    /// The hub changes settings through the menu's own actions (same prompts, same logs).
    private func applyHubSetting(_ key: String, _ value: String) {
        let menuItem = NSMenuItem()
        menuItem.representedObject = value
        menuItem.tag = Int(value) ?? 0
        let current = hubValues()[key]
        switch key {
        case "holdKey": selectHoldKey(menuItem)
        case "recognizer": selectSpeechBackend(menuItem)
        case "language": selectLanguage(menuItem)
        case "autoStop": selectAutoStop(menuItem)
        case "level": selectLevel(menuItem)
        case "engine": selectEngine(menuItem)
        case "idleUnload": selectIdleUnload(menuItem)
        case "autoRecord": selectAutoRecord(menuItem)
        case "pillPosition": selectPillPosition(menuItem)
        case "streaming": if current != value { toggleStreaming() }
        case "keepMicReady": if current != value { togglePreroll() }
        case "keepClipboard": if current != value { toggleKeepClipboard() }
        case "screenNames": if current != value { toggleScreenNames() }
        case "showSprig": if current != value { toggleSprig() }
        case "sounds": if current != value { toggleSounds() }
        case "pauseMusic": if current != value { togglePauseMedia() }
        default: break
        }
        updateHubStatus()
    }

    private func updateStatusIcon() {
        let name = state.sprigState(icon: true)
        let sprig = state.showSprig ? MainActor.assumeIsolated { SprigIcon.image(state: name) } : nil
        if let image = sprig {
            statusItem.button?.image = image
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Saywell")
        }
    }

    @objc private func toggleSprig() {
        state.showSprig.toggle()
        store?.setSetting("sprig.show", state.showSprig ? "on" : "off")
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        session.languageSetting = id
        Log.write("language: set to \(id) → \(session.languageID)")
    }

    @objc private func selectHoldKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = HoldKey(rawValue: raw) else { return }
        holdKey = key
        hotkeys.holdKey = key
    }

    @objc private func selectAutoStop(_ sender: NSMenuItem) {
        session.autoStopSeconds = sender.tag
    }

    @objc private func openSettings() { openHub(page: .general) }
}
