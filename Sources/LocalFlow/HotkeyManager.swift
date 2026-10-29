import AppKit
import Carbon.HIToolbox
import LocalFlowCore

/// Triggers:
/// - ⌃⌥D toggles dictation (Carbon hotkey, needs no permissions).
/// - ⌃⌥Z replaces the last insertion with the raw (rules-only) text.
/// - ⌃⌘V pastes the last dictation again.
/// - Holding the hold key (Fn, right ⌥, right ⌘ or right ⌃) is push-to-talk;
///   two quick taps go hands-free until the next press; Esc cancels
///   (CGEventTap on flagsChanged/keyDown, which needs Input Monitoring).
///   The key + another key cancels, so shortcuts still work. See HoldKeyLogic.
final class HotkeyManager {
    var onToggle: (() -> Void)?
    var onUndoToRaw: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onPushStart: (() -> Void)?
    var onPushEnd: (() -> Void)?
    /// The key was combined with another key, tapped once, or Esc was pressed; discard the session.
    var onPushCancel: (() -> Void)?
    /// Double tap: keep listening after the key is released.
    var onPushLock: (() -> Void)?
    /// Esc while no hold-key session is active (e.g. a ⌃⌥D dictation).
    var onEscape: (() -> Void)?

    var holdKey: HoldKey = .fn {
        didSet { if oldValue != holdKey { reset() } }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var undoHotKeyRef: EventHotKeyRef?
    private var pasteHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private var tickTimer: Timer?
    private var logic = HoldKeyLogic()
    private var keyDown = false
    private var loggedFirstKey = false

    init() {
        registerToggle()
        installTap()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let undoHotKeyRef { UnregisterEventHotKey(undoHotKeyRef) }
        if let pasteHotKeyRef { UnregisterEventHotKey(pasteHotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        retryTimer?.invalidate()
        tickTimer?.invalidate()
    }

    /// The session ended on its own (auto-stop, menu, error): forget the key state.
    func reset() {
        logic.reset()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    var isKeyTapInstalled: Bool { tap != nil }

    /// A listen-only tap is created fine without permission but receives no
    /// events. Accessibility alone isn't enough on macOS 27 (seen: ax=true,
    /// listen=false → deaf tap), so require Input Monitoring itself.
    static var canListen: Bool { CGPreflightListenEventAccess() }

    // MARK: ⌃⌥D

    private func registerToggle() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                switch id.id {
                case 2: manager.onUndoToRaw?()
                case 3: manager.onPasteLast?()
                default: manager.onToggle?()
                }
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C464C57), id: 1) // 'LFLW'
        RegisterEventHotKey(UInt32(kVK_ANSI_D),
                            UInt32(controlKey | optionKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_Z),
                            UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x4C464C57), id: 2),
                            GetApplicationEventTarget(),
                            0,
                            &undoHotKeyRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_V),
                            UInt32(controlKey | cmdKey),
                            EventHotKeyID(signature: OSType(0x4C464C57), id: 3),
                            GetApplicationEventTarget(),
                            0,
                            &pasteHotKeyRef)
    }

    // MARK: Hold key

    /// A tap created before permission is granted stays deaf even after the
    /// grant, so wait for permission (prompting once) before creating it.
    private func installTap() {
        guard tap == nil else { return }
        guard Self.canListen else {
            if retryTimer == nil {
                Log.write("hotkey: no Input Monitoring yet; requesting and waiting")
                CGRequestListenEventAccess()
                retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.installTap()
                }
            }
            return
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: selfPtr)

        guard let tap else {
            if retryTimer == nil {
                Log.write("hotkey: key tap unavailable (needs Accessibility); retrying")
                retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    self?.installTap()
                }
            }
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("hotkey: key tap installed (hold \(holdKey.rawValue))")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // The 🌐 key posts its own keyDown (179) when Fn is released; not a shortcut.
            if code == Self.globeKeyCode { return }
            if code == Int64(kVK_Escape) {
                if logic.isActive { perform(logic.escape()) } else { DispatchQueue.main.async { self.onEscape?() } }
            } else {
                perform(logic.otherKey())
            }
        case .flagsChanged:
            guard let keyCode = holdKey.keyCode else { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let now = ProcessInfo.processInfo.systemUptime
            guard code == keyCode else {
                // Another modifier joined the key: it's a shortcut, not dictation.
                if keyDown { perform(logic.otherKey()) }
                return
            }
            if !loggedFirstKey {
                loggedFirstKey = true
                Log.write("hotkey: first \(holdKey.rawValue) event received")
            }
            let down = isDown(event)
            if down && !keyDown {
                keyDown = true
                // The key alone; ignore when other modifiers are held (e.g. ⌃Fn).
                guard event.flags.intersection(otherModifiers).isEmpty || logic.isActive else { return }
                perform(logic.keyDown(at: now))
            } else if !down && keyDown {
                keyDown = false
                let held: Double? = { if case .holding(let since) = logic.phase { return now - since }; return nil }()
                let action = logic.keyUp(at: now)
                if let held { Log.write("hotkey: released after \(Int(held * 1000))ms → \(action)") }
                perform(action)
            }
        default:
            break
        }
    }

    private static let globeKeyCode: Int64 = 179

    private func isDown(_ event: CGEvent) -> Bool {
        if let mask = holdKey.deviceMask { return event.flags.rawValue & mask != 0 }
        return event.flags.contains(.maskSecondaryFn)
    }

    /// Modifiers that make the press a shortcut; the hold key's own flag is excluded.
    private var otherModifiers: CGEventFlags {
        var flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        switch holdKey {
        case .rightOption: flags.remove(.maskAlternate)
        case .rightCommand: flags.remove(.maskCommand)
        case .rightControl: flags.remove(.maskControl)
        case .fn, .off: break
        }
        return flags
    }

    private func perform(_ action: HoldKeyLogic.Action) {
        guard action != .none else {
            updateTickTimer()
            return
        }
        DispatchQueue.main.async {
            switch action {
            case .none: break
            case .start: self.onPushStart?()
            case .lock: self.onPushLock?()
            case .finish: self.onPushEnd?()
            case .cancel: self.onPushCancel?()
            case .restart:
                self.onPushCancel?()
                self.onPushStart?()
            }
            self.updateTickTimer()
        }
    }

    /// Ends a single tap that never got its second tap.
    private func updateTickTimer() {
        guard logic.isWaiting else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.perform(self.logic.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }
}
