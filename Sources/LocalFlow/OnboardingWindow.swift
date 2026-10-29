import AppKit
import AVFoundation
import LocalFlowCore
import Speech
import SwiftUI

/// Two-minute setup (G9): each step checks its own permission live and turns
/// green. Same @Published pattern as SettingsModel (no SwiftUI property-wrapper macros).
final class OnboardingModel: ObservableObject {
    @Published var micAndSpeech = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var engine: CleanupEngine = .apple
    @Published var modelStatus = ""
    @Published var tryText = ""
    @Published var tried = false

    private weak var session: SessionController?
    private var timer: Timer?

    init(session: SessionController) {
        self.session = session
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    func stop() { timer?.invalidate() }

    func refresh() {
        micAndSpeech = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        guard let session else { return }
        engine = session.cleanupEngine
        if engine == .apple {
            modelStatus = "Apple's model: \(CleanupClient.availabilityDescription)"
        } else {
            modelStatus = session.mlx.engine == engine ? session.mlx.statusDescription
                : (MLXCleanupClient.isDownloaded(engine.modelSpec(store: session.store) ?? "") ? "downloaded" : "not downloaded")
        }
    }

    func requestMicAndSpeech() {
        DictationEngine.requestPermissions { [weak self] _ in self?.refresh() }
    }

    func openAccessibility() {
        _ = TextInserter.hasAccessibilityPermission(promptIfNeeded: true)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoring() {
        CGRequestListenEventAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openKeyboard() { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }

    func choose(_ engine: CleanupEngine) {
        session?.selectEngine(engine, allowDownload: true)
        refresh()
    }

    func received(_ text: String) {
        tryText += (tryText.isEmpty ? "" : " ") + text
        tried = true
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

final class OnboardingWindowController {
    private var window: NSWindow?
    private var model: OnboardingModel?
    private let session: SessionController
    private let store: Store?

    init(session: SessionController, store: Store?) {
        self.session = session
        self.store = store
    }

    var shouldShowAtLaunch: Bool { store?.setting("onboarding.done") != "yes" }

    func show() {
        if window == nil {
            let model = OnboardingModel(session: session)
            self.model = model
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Set Up Saywell"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in self?.finish() })
            window.center()
            self.window = window
            session.localInsertTarget = { [weak model] text in model?.received(text) }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        store?.setSetting("onboarding.done", "yes")
        session.localInsertTarget = nil
        model?.stop()
        window?.close()
        window = nil
        model = nil
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saywell runs speech recognition and AI cleanup entirely on this Mac.")
                .font(.headline)
            step(1, "Microphone & speech recognition", ok: model.micAndSpeech) {
                Button("Allow", action: model.requestMicAndSpeech)
            }
            step(2, "Accessibility (to type into apps)", ok: model.accessibility) {
                Button("Open Settings", action: model.openAccessibility)
            }
            step(3, "Input Monitoring (to hold Fn)", ok: model.inputMonitoring) {
                HStack {
                    Button("Open Settings", action: model.openInputMonitoring)
                    Button("Keyboard: set 🌐 to Do Nothing", action: model.openKeyboard)
                }
            }
            step(4, "Choose a cleanup model", ok: !model.modelStatus.isEmpty && (model.modelStatus.contains("available") || model.modelStatus == "ready")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Apple (instant)") { model.choose(.apple) }
                        Button("Qwen3 4B local (2.3 GB download)") { model.choose(.qwen3) }
                    }
                    Text(model.modelStatus).font(.caption).foregroundColor(.secondary)
                }
            }
            step(5, "Try it: click the box, hold Fn, say \"Hello, this is my first dictation.\"", ok: model.tried) {
                TextEditor(text: $model.tryText)
                    .font(.body)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            HStack {
                Spacer()
                Button(model.tried ? "Done" : "Skip for now", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func step<Content: View>(_ n: Int, _ title: String, ok: Bool,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundColor(ok ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).fontWeight(.medium)
                content()
            }
        }
    }
}
