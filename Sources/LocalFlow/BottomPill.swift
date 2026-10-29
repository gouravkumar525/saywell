import AppKit
import LocalFlowCore
import SwiftUI

/// C4: where the pill lives. The notch is the default; the others suit
/// external displays and Macs without a notch.
enum PillPosition: String, CaseIterable {
    case notch, bottom, left, right

    var label: String {
        switch self {
        case .notch: return "Notch"
        case .bottom: return "Bottom of Screen"
        case .left: return "Left Edge"
        case .right: return "Right Edge"
        }
    }
}

/// Hover state for the bottom pill (no @State in this codebase).
final class PillHover: ObservableObject {
    @Published var hovered = false
}

/// A small see-through pill at the bottom (or an edge) of the screen under the
/// pointer. At rest it's a slim capsule; hover it for Dictate, Record Call and
/// Settings; while dictating it shows Sprig, the voice dots and the live text.
/// The window is click-through except over the capsule itself.
final class BottomPill: NSPanel {
    private let state: AppState
    private let hover = PillHover()
    private var monitors: [Any] = []
    private var leaveWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    var position: PillPosition = .bottom {
        didSet { place() }
    }

    static let windowSize = CGSize(width: 560, height: 130)

    init(state: AppState, dictate: @escaping () -> Void, record: @escaping () -> Void, settings: @escaping () -> Void) {
        self.state = state
        super.init(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = NSHostingView(rootView: BottomPillView(state: state, hover: hover, edge: { [weak self] in self?.position ?? .bottom },
                                                             dictate: dictate, record: record, settings: settings))
        let move: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: move) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { move($0); return $0 }) {
            monitors.append(local)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.place() })
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        place()
        orderFrontRegardless()
    }

    /// The screen under the pointer, so the pill follows you across displays.
    func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = Self.windowSize
        let origin: CGPoint
        switch position {
        case .bottom, .notch: origin = CGPoint(x: v.midX - size.width / 2, y: v.minY + 4)
        case .left: origin = CGPoint(x: v.minX + 4, y: v.midY - size.height / 2)
        case .right: origin = CGPoint(x: v.maxX - size.width - 4, y: v.midY - size.height / 2)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The capsule's rectangle in screen coordinates; only it takes clicks.
    private var hotRect: NSRect {
        let size = BottomPillView.capsuleSize(state: state, hovered: hover.hovered)
        let x: CGFloat
        switch position {
        case .bottom, .notch: x = frame.midX - size.width / 2
        case .left: x = frame.minX
        case .right: x = frame.maxX - size.width
        }
        let y = position == .bottom || position == .notch ? frame.minY : frame.midY - size.height / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height).insetBy(dx: -6, dy: -6)
    }

    private func pointerMoved() {
        guard isVisible else { return }
        let inside = hotRect.contains(NSEvent.mouseLocation)
        ignoresMouseEvents = !inside
        if inside {
            leaveWork?.cancel()
            leaveWork = nil
            if !hover.hovered { hover.hovered = true }
        } else if hover.hovered, leaveWork == nil {
            // A short grace period so moving onto a button doesn't flicker.
            let work = DispatchWorkItem { [weak self] in
                self?.hover.hovered = false
                self?.leaveWork = nil
            }
            leaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

struct BottomPillView: View {
    @ObservedObject var state: AppState
    @ObservedObject var hover: PillHover
    var edge: () -> PillPosition
    var dictate: () -> Void
    var record: () -> Void
    var settings: () -> Void

    static func capsuleSize(state: AppState, hovered: Bool) -> CGSize {
        if state.agentCard != nil, !state.isListening { return CGSize(width: 540, height: 92) }
        if state.meetingPrompt != nil, !state.takingNotes { return CGSize(width: 480, height: 60) }
        if state.isExpanded { return CGSize(width: 380, height: 60) }
        if state.takingNotes { return CGSize(width: 230, height: 48) }
        return hovered ? CGSize(width: 220, height: 48) : CGSize(width: 64, height: 16)
    }

    var body: some View {
        let size = Self.capsuleSize(state: state, hovered: hover.hovered)
        let alignment: Alignment = {
            switch edge() {
            case .bottom, .notch: return .bottom
            case .left: return .leading
            case .right: return .trailing
            }
        }()
        ZStack {
            Capsule()
                .fill(Color.black.opacity(state.isExpanded || hover.hovered || state.takingNotes ? 0.86 : 0.55))
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            content
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hover.hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.isExpanded)
    }

    private var sprig: some View {
        SprigView(engine: state.sprig, scale: 0.24, ground: 0.88, level: { [state] in Double(state.level) })
            .frame(width: 52, height: 52)
    }

    @ViewBuilder
    private var content: some View {
        if let app = state.meetingPrompt, !state.takingNotes, case .idle = state.phase {
            HStack(spacing: 10) {
                if state.showSprig { sprig }
                Text("\(app) meeting started. Take notes?")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CardButton(title: "Record Notes", tint: .red, prominent: true, action: state.recordMeeting)
                CardButton(title: "Not Now", tint: .gray, action: state.dismissMeeting)
            }
            .padding(.horizontal, 14)
        } else if state.agentCard != nil, !state.isListening, case .idle = state.phase, let agents = state.agents {
            HStack(spacing: 10) {
                if state.showSprig { sprig }
                AgentCardView(center: agents).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
        } else if state.isExpanded {
            HStack(spacing: 10) {
                if state.showSprig { sprig }
                if state.isListening {
                    VoiceDotsView(state: state, smoother: state.pillDots).frame(width: 60, height: 22)
                }
                Text(line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
        } else if hover.hovered || state.takingNotes {
            HStack(spacing: 12) {
                if state.showSprig { sprig.frame(width: 44, height: 44) }
                PillButton(symbol: "mic.fill", help: "Dictate hands-free (tap the hold key twice)", action: dictate)
                PillButton(symbol: state.takingNotes ? "stop.circle.fill" : "record.circle",
                           help: state.takingNotes ? "Stop recording the call" : "Record a call",
                           tint: state.takingNotes ? .red : .white, action: record)
                PillButton(symbol: "gearshape.fill", help: "Saywell settings", action: settings)
            }
            .padding(.horizontal, 10)
        } else {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in Circle().fill(Color.white.opacity(0.55)).frame(width: 3, height: 3) }
            }
        }
    }

    private var line: String {
        switch state.phase {
        case .listening: return state.transcript.isEmpty ? "Listening…" : String(state.transcript.suffix(120))
        case .processing: return state.polished.isEmpty ? "Polishing for \(state.target)…" : String(state.polished.suffix(120))
        case .inserted: return state.note.isEmpty ? "Inserted" : state.note
        case .error(let message): return message
        case .idle: return state.sprig.stateConfig.label
        }
    }
}

struct PillButton: View {
    var symbol: String
    var help: String
    var tint: Color = .white
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint.opacity(0.92))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
