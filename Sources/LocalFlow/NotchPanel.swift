import AppKit
import LocalFlowCore
import SwiftUI

// MARK: - Shared UI state

final class AppState: ObservableObject {
    enum Phase {
        case idle          // slim strip hugging the notch
        case listening     // expanded pill: waveform + live transcript
        case processing    // finalizing / cleaning text
        case inserted      // brief confirmation
        case error(String)
    }

    @Published var phase: Phase = .idle {
        didSet { updateSprig() }
    }
    @Published var transcript: String = ""
    @Published var level: Float = 0
    /// C4: voice band levels (0...1, low → high) for the dots; not published (read every frame).
    var bands = [Float](repeating: 0, count: AudioBands.count)
    /// Smoothing for the notch's and the bottom pill's dots.
    let notchDots = DotSmoother()
    let pillDots = DotSmoother()
    /// Streaming LLM output while polishing.
    @Published var polished: String = ""
    /// Target app and style, e.g. "Slack · Casual".
    @Published var target: String = ""
    /// Shown with the inserted check, e.g. "Polished ✓ · Raw ⌃⌥Z".
    @Published var note: String = ""
    /// Sentences already cleaned in the background while talking.
    @Published var streamed: Int = 0
    /// Seconds left before the recording cap, shown in the last 30 s (B12).
    @Published var secondsLeft: Int?

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    // MARK: Sprig (C3)

    /// The companion drawn in the pill; falls asleep after 5 idle minutes.
    let sprig = SprigEngine(reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, sleepAfter: 300)
    /// Menu ▸ Show Sprig.
    @Published var showSprig = true
    /// Test control / settings preview: shows Sprig in this state with the pill open.
    @Published var sprigPreview: String? {
        didSet { updateSprig() }
    }
    /// Set while a call is being noted (Phase 5): Sprig writes instead of listening.
    @Published var takingNotes = false {
        didSet { updateSprig() }
    }
    /// While a call records: when it started, and the latest live line.
    @Published var noteStarted: Date?
    /// C6: Claude Code's request in front ("approval" or "question"), and activity.
    @Published var agentCard: String? {
        didSet { updateSprig() }
    }
    @Published var agentWorking = false
    /// Briefly true after a Claude Code session finishes (menu-bar Sprig cheers).
    @Published var agentDone = false
    var agents: AgentCenter?
    @Published var noteLine = ""
    var stopRecording: () -> Void = {}
    /// A meeting app just started a meeting: offer to record it (C5 auto-record).
    @Published var meetingPrompt: String? {
        didSet { updateSprig() }
    }
    var recordMeeting: () -> Void = {}
    var dismissMeeting: () -> Void = {}

    var isExpanded: Bool {
        if sprigPreview != nil || takingNotes || agentCard != nil || meetingPrompt != nil { return true }
        if case .idle = phase { return false }
        return true
    }

    private func updateSprig() {
        sprig.setState(sprigState(icon: false))
    }

    /// What Sprig does now. Dictation comes first, then Claude Code's requests,
    /// then note-taking. The menu-bar icon also shows agent activity.
    func sprigState(icon: Bool) -> String {
        if let preview = sprigPreview { return preview }
        switch phase {
        case .listening: return takingNotes ? "writing" : "listening"
        case .processing: return "thinking"
        case .inserted: return "done"
        case .error: return "error"
        case .idle: break
        }
        if let card = agentCard { return card }
        if meetingPrompt != nil { return "question" }
        if takingNotes { return "writing" }
        if icon && agentDone { return "done" }
        if icon && agentWorking { return "working" }
        return "idle"
    }
}

// MARK: - Notch pill view

struct NotchPillView: View {
    @ObservedObject var state: AppState
    /// Height hidden by the camera housing; expanded content sits below it.
    var topInset: CGFloat
    var toggle: () -> Void
    var undo: () -> Void = {}
    /// Pointer direction relative to Sprig, for its eyes.
    var pointer: () -> (Double, Double) = { (0, 0) }

    var body: some View {
        VStack(spacing: 0) {
            if !state.isExpanded {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.frame(height: topInset)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 4)
            }
        }
        .background(
            NotchShape(bottomRadius: 18)
                .fill(Color.black)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.isListening)
    }

    static let sprigSize: CGFloat = 70

    private var sprigView: some View {
        SprigView(engine: state.sprig, scale: 0.24, ground: 0.88, pointer: pointer,
                  level: { [state] in Double(state.level) })
            .frame(width: Self.sprigSize, height: Self.sprigSize)
    }

    @ViewBuilder
    private var content: some View {
        if let preview = state.sprigPreview {
            HStack(spacing: 10) {
                sprigView
                Text(state.sprig.stateConfig.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(preview).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
        } else {
            phaseContent
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .idle where state.meetingPrompt != nil && !state.takingNotes:
            HStack(spacing: 10) {
                if state.showSprig { sprigView }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(state.meetingPrompt ?? "") meeting started")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Text("Take notes? Saywell records it on this Mac and writes a summary and action items.")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.7)).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CardButton(title: "Record Notes", tint: .red, prominent: true, action: state.recordMeeting)
                CardButton(title: "Not Now", tint: .gray, action: state.dismissMeeting)
            }
            .padding(.horizontal, 16)
        case .idle where state.agentCard != nil:
            if let agents = state.agents {
                HStack(alignment: .center, spacing: 10) {
                    if state.showSprig { sprigView }
                    AgentCardView(center: agents)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
            }
        case .idle where state.takingNotes:
            HStack(spacing: 10) {
                if state.showSprig { sprigView }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("Recording call")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        if let started = state.noteStarted {
                            Text(started, style: .timer)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    Text(state.noteLine.isEmpty ? "Taking notes…" : String(state.noteLine.suffix(110)))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: state.stopRecording) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop recording the call")
            }
            .padding(.horizontal, 16)
        case .idle:
            HStack {
                Spacer()
                if state.showSprig, let sprig = SprigIcon.image(state: "idle", points: 14) {
                    Image(nsImage: sprig)
                        .opacity(0.85)
                        .padding(.bottom, 2)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.bottom, 4)
                }
                Spacer()
            }
        case .listening:
            HStack(spacing: 10) {
                if state.showSprig {
                    sprigView
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .opacity(0.6 + 0.4 * Double(state.level))
                }
                VoiceDotsView(state: state, smoother: state.notchDots)
                    .frame(width: 66, height: 24)
                Text(state.transcript.isEmpty ? "Listening…" : String(state.transcript.suffix(140)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let left = state.secondsLeft {
                    Text(String(format: "0:%02d", left))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(.orange)
                        .fixedSize()
                }
                if state.streamed > 0 {
                    Text("\(state.streamed) polished")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green.opacity(0.85))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 16)
        case .processing:
            HStack(spacing: 8) {
                if state.showSprig {
                    sprigView
                } else {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                }
                Text(state.polished.isEmpty ? "Polishing for \(state.target)…" : String(state.polished.suffix(140)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 16)
        case .inserted:
            HStack(spacing: 6) {
                if state.showSprig {
                    sprigView
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                Text(state.note.isEmpty ? "Inserted" : state.note)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                if state.note.hasPrefix("Polished") {
                    Button("Raw", action: undo)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
        case .error(let message):
            HStack(spacing: 6) {
                if state.showSprig {
                    sprigView
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                }
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
        }
    }
}

/// Black shape that extends the notch: square top corners, rounded bottom.
struct NotchShape: Shape {
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// C4: nine dots that follow the voice, low pitch on the left, high on the right.
/// While polishing, a wave runs through them instead.
struct VoiceDotsView: View {
    @ObservedObject var state: AppState
    /// Kept by the owner (AppState), not the view: SwiftUI rebuilds views on every
    /// level update, and a fresh smoother each time made the dots flicker.
    let smoother: DotSmoother
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let levels = smoother.step(state.bands, thinking: !state.isListening, now: t)
                let n = levels.count
                let width = 3.4, gap = (Double(size.width) - width * Double(n)) / Double(max(1, n - 1))
                for (i, level) in levels.enumerated() {
                    let h = width + (Double(size.height) - width) * level
                    let rect = CGRect(x: Double(i) * (width + gap), y: (Double(size.height) - h) / 2, width: width, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color.opacity(0.9)))
                }
            }
        }
    }
}

/// Smoothing state for VoiceDotsView, kept outside the view (no @State).
final class DotSmoother {
    private var levels = [Double](repeating: 0, count: AudioBands.count)
    private var last = 0.0

    func step(_ target: [Float], thinking: Bool, now: Double) -> [Double] {
        let dt = last == 0 ? 0 : min(0.1, now - last)
        last = now
        for i in levels.indices {
            var goal: Double
            if thinking {
                goal = 0.10 + 0.22 * max(0, sin(now * 7.5 - Double(i) * 0.75))
            } else {
                goal = i < target.count ? Double(target[i]) : 0
                // A little wobble so a steady sound doesn't freeze the dots.
                goal *= 1 + 0.05 * sin(now * 4 + Double(i))
            }
            levels[i] = AudioBands.smooth(levels[i], toward: goal, dt: dt)
        }
        return levels
    }
}

struct WaveformView: View {
    var level: Float
    private let barCount = 7

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base: CGFloat = 4
        let center = Double(barCount - 1) / 2
        let falloff = 1.0 - abs(Double(index) - center) / (center + 1)
        let jitter = 0.6 + 0.4 * sin(Double(index) * 1.7 + Double(level) * 12)
        return base + CGFloat(Double(level) * 18 * falloff * jitter)
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    private let state: AppState
    private let idleHeight: CGFloat
    private let idleWidth: CGFloat
    private let topInset: CGFloat
    /// Sprig plus two lines of 13pt text, below the notch.
    private var activeHeight: CGFloat { topInset + NotchPillView.sprigSize + 4 }
    private let activeWidth: CGFloat = 480
    private weak var targetScreen: NSScreen?

    init(state: AppState, toggle: @escaping () -> Void, undo: @escaping () -> Void = {}) {
        self.state = state

        // Prefer the built-in display with a notch.
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        self.targetScreen = screen

        let notchHeight = screen.safeAreaInsets.top
        let hasNotch = notchHeight > 0
        // Width of the physical notch (distance between the auxiliary top areas).
        var notchWidth: CGFloat = 200
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        self.idleHeight = hasNotch ? notchHeight + 6 : 34
        self.idleWidth = notchWidth + 24
        self.topInset = hasNotch ? notchHeight : 0

        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: NotchPillView(state: state, topInset: topInset, toggle: toggle, undo: undo,
                                                         pointer: { [weak self] in self?.sprigPointer() ?? (0, 0) }))
        contentView = host

        layout(expanded: false, animated: false)
        orderFrontRegardless()
    }

    /// Where the pointer is relative to Sprig (left of the open pill), squashed
    /// to -1...1 like Coucou's eyes: tanh(dx / 260), tanh(dy / 200), y down.
    private func sprigPointer() -> (Double, Double) {
        let mouse = NSEvent.mouseLocation
        let center = CGPoint(x: frame.minX + 16 + NotchPillView.sprigSize / 2,
                             y: frame.maxY - topInset - NotchPillView.sprigSize / 2)
        return (tanh((mouse.x - center.x) / 260), tanh(-(mouse.y - center.y) / 200))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// False when the pill lives at the bottom or an edge of the screen instead (C4).
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                layout(expanded: state.isExpanded, animated: false)
                orderFrontRegardless()
            } else {
                orderOut(nil)
            }
        }
    }

    func layout(expanded: Bool, animated: Bool) {
        guard isEnabled else { return }
        guard let screen = targetScreen ?? NSScreen.main else { return }
        let expanded = expanded || state.isExpanded
        let w = expanded ? max(activeWidth + (state.agentCard != nil ? 60 : 0), idleWidth) : idleWidth
        let h = expanded ? activeHeight + (state.agentCard != nil ? 24 : 0) : idleHeight
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        let frame = NSRect(x: x, y: y, width: w, height: h)
        setFrame(frame, display: true, animate: animated)
    }
}
