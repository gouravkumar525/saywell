import Foundation

/// The key you hold to talk, chosen in the menu.
public enum HoldKey: String, CaseIterable {
    case fn
    case rightOption
    case rightCommand
    case rightControl
    case off

    public var label: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .off: return "Off"
        }
    }

    /// Virtual key code reported in flagsChanged events.
    public var keyCode: Int64? {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .off: return nil
        }
    }

    /// Device-dependent bit that is set only while this exact key is down
    /// (NX_DEVICERALTKEYMASK etc.), so the left-hand key never triggers.
    public var deviceMask: UInt64? {
        switch self {
        case .fn: return nil
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .off: return nil
        }
    }
}

/// The hold-to-talk key as a pure state machine (tested in HoldKeyLogicTests).
/// Adapted from Coucou's FlowKeyLogic (MIT, github.com/louis-cfm/coucou).
///
/// - Hold the key: listen; release: finish and insert.
/// - Two quick taps: hands-free until the next press.
/// - Esc, or another key while held or between taps: cancel (it was a shortcut).
///
/// Listening starts on the first press so no word is lost; a press too short
/// to be a hold waits for the second tap and is dropped if none comes.
public struct HoldKeyLogic: Equatable {
    public enum Phase: Equatable {
        case idle
        case holding(since: Double)
        case tapWait(until: Double)
        /// A short hold ended; a second press soon after still means double tap.
        case finishWait(until: Double)
        case locked
    }

    public enum Action: Equatable {
        case none
        /// Open the mic and show the pill.
        case start
        /// Hands-free: keep listening after the key is released.
        case lock
        /// Stop listening and insert.
        case finish
        /// Stop listening and insert nothing.
        case cancel
        /// The previous listen was dropped and a new one begins.
        case restart
    }

    /// A press shorter than this is a tap. Relaxed taps last 0.3–0.4 s
    /// (seen live), and a hold this short carries no words anyway.
    public static let holdThreshold = 0.45
    /// The second tap of a double tap must come within this.
    public static let doubleTapWindow = 0.50
    /// Holds up to this long may still be the first tap of a double tap: macOS
    /// delivers the 🌐/Fn release late (a 0.25 s tap logged as 0.6 s), so a
    /// short hold waits `finishGrace` for a second press before finishing.
    public static let shortHold = 1.0
    public static let finishGrace = 0.25

    public private(set) var phase: Phase = .idle

    public init() {}

    public var isActive: Bool { phase != .idle }

    public mutating func keyDown(at t: Double) -> Action {
        switch phase {
        case .idle:
            phase = .holding(since: t)
            return .start
        case .holding:
            return .none
        case .tapWait(let until), .finishWait(let until):
            if t <= until { phase = .locked; return .lock }
            if case .finishWait = phase {
                // The finish was due; the tick just hadn't run yet.
                phase = .holding(since: t)
                return .restart
            }
            phase = .holding(since: t)
            return .restart
        case .locked:
            phase = .idle
            return .finish
        }
    }

    public mutating func keyUp(at t: Double) -> Action {
        guard case .holding(let since) = phase else { return .none }
        let held = t - since
        if held >= Self.shortHold {
            phase = .idle
            return .finish
        }
        if held >= Self.holdThreshold {
            phase = .finishWait(until: t + Self.finishGrace)
            return .none
        }
        phase = .tapWait(until: t + Self.doubleTapWindow)
        return .none
    }

    /// Another key while held or between the taps: a shortcut, not dictation.
    public mutating func otherKey() -> Action {
        switch phase {
        case .holding, .tapWait:
            phase = .idle
            return .cancel
        case .finishWait:
            // Typing right after a short hold: keep what was said.
            phase = .idle
            return .finish
        case .idle, .locked:
            return .none
        }
    }

    public mutating func escape() -> Action {
        guard phase != .idle else { return .none }
        phase = .idle
        return .cancel
    }

    /// Called periodically: a lone tap is dropped, a short hold finishes.
    public mutating func tick(at t: Double) -> Action {
        switch phase {
        case .tapWait(let until) where t > until:
            phase = .idle
            return .cancel
        case .finishWait(let until) where t > until:
            phase = .idle
            return .finish
        default:
            return .none
        }
    }

    /// Whether `tick` needs to be called.
    public var isWaiting: Bool {
        switch phase {
        case .tapWait, .finishWait: return true
        default: return false
        }
    }

    /// The session ended on its own (auto-stop, error, menu).
    public mutating func reset() { phase = .idle }
}
