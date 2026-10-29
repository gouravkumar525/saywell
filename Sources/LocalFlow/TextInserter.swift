import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text into the focused field. Order: 1) write the selection through
/// Accessibility (replaces a selection or inserts at the caret), 2) paste via
/// the pasteboard and a synthesized ⌘V, then restore the pasteboard,
/// 3) leave the text on the clipboard when neither is possible.
enum TextInserter {

    enum Method: String {
        case accessibility, paste, clipboard
    }

    /// Where the text landed, so EditWatcher can follow up on it.
    struct Result {
        let method: Method
        let element: AXUIElement?
        /// UTF-16 location of the inserted text in the element's value.
        let location: Int?
    }

    /// Apps where an AX write "succeeds" without the app noticing (web views,
    /// Electron, terminals). They always get the paste path.
    private static let pasteOnlyApps: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
    ]

    static func hasAccessibilityPermission(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Seconds before the pasteboard is restored after ⌘V (B8). Slow apps read
    /// it late; Electron apps latest.
    static let restoreDelay: TimeInterval = 0.5
    static let electronRestoreDelay: TimeInterval = 0.75

    /// `override` is the user's per-app choice ("paste" or "accessibility").
    /// `keepOnClipboard` leaves the dictation on the clipboard afterwards.
    static func insert(_ text: String, context: FocusContext?, override: Method? = nil,
                       keepOnClipboard: Bool = false,
                       completion: @escaping (Result) -> Void) {
        guard !text.isEmpty else { return }
        guard hasAccessibilityPermission() else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            completion(Result(method: .clipboard, element: nil, location: nil))
            return
        }
        if let context, shouldTryAccessibility(context, override: override),
           let element = context.element, let location = context.selection?.location,
           writeSelection(text, element: element, location: location) {
            if keepOnClipboard { copyToClipboard(text) }
            completion(Result(method: .accessibility, element: element, location: location))
            return
        }
        let delay = context?.isElectron == true ? electronRestoreDelay : restoreDelay
        paste(text, restoreAfter: keepOnClipboard ? nil : delay) {
            completion(Result(method: .paste, element: context?.element, location: context?.selection?.location))
        }
    }

    /// Replaces `length` UTF-16 units at `location` with `text` (undo to raw).
    /// Selects the range over AX, then writes the selection or pastes over it.
    static func replace(location: Int, length: Int, with text: String, element: AXUIElement,
                        allowAccessibilityWrite: Bool, completion: @escaping (Bool) -> Void) {
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
        else { completion(false); return }
        if allowAccessibilityWrite, writeSelection(text, element: element, location: location) {
            completion(true)
            return
        }
        paste(text, restoreAfter: electronRestoreDelay) { completion(true) }
    }

    /// ⌃⌘V: pastes text at the caret and restores the clipboard.
    static func pasteAgain(_ text: String) {
        paste(text, restoreAfter: electronRestoreDelay) {}
    }

    /// Puts text on the clipboard for the user to paste themselves.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func shouldTryAccessibility(_ context: FocusContext, override: Method?) -> Bool {
        if override == .paste { return false }
        guard context.isTextInput, !context.isSecure, context.selection != nil else { return false }
        if override == .accessibility { return true }
        if context.isElectron { return false }
        if let id = context.bundleID, pasteOnlyApps.contains(id) { return false }
        return true
    }

    /// Sets the selected text, then reads the value back to confirm the app
    /// actually took it.
    private static func writeSelection(_ text: String, element: AXUIElement, location: Int) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        guard let value: String = ContextProvider.attribute(element, kAXValueAttribute) else { return false }
        let ns = value as NSString
        let length = (text as NSString).length
        guard location + length <= ns.length else { return false }
        return ns.substring(with: NSRange(location: location, length: length)) == text
    }

    /// Marks our temporary pasteboard item so clipboard managers skip it
    /// (nspasteboard.org conventions).
    private static let transientTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// `restoreAfter` nil leaves `text` on the clipboard (as a normal, non-transient item).
    private static func paste(_ text: String, restoreAfter delay: TimeInterval?, completion: @escaping () -> Void) {
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)
        if delay != nil {
            for type in transientTypes { pb.setData(Data(), forType: type) }
        }
        let changeCount = pb.changeCount

        sendCmdV()

        guard let delay else {
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { completion() }
            return
        }

        // Give the paste time to land before restoring the clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Don't clobber something the user copied in the meantime.
            if pb.changeCount == changeCount {
                pb.clearContents()
                if !savedItems.isEmpty {
                    pb.writeObjects(savedItems)
                }
            }
            completion()
        }
    }

    private static func sendCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
