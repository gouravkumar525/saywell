import AppKit
import ApplicationServices
import LocalFlowCore

/// Snapshot of where the user is typing, captured when dictation starts
/// (the notch panel never takes focus, so the target app is still focused).
struct FocusContext {
    var bundleID: String?
    var appName: String
    var pid: pid_t?
    var element: AXUIElement?
    var role: String?
    var isSecure = false
    var isElectron = false
    /// UTF-16 range of the selection / caret in the element's value.
    var selection: CFRange?
    var selectedText: String?
    var precedingText: String?
    /// A few characters after the caret/selection, for smart spacing.
    var followingText: String?

    var isTextInput: Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
}

enum ContextProvider {

    static func capture() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var ctx = FocusContext(bundleID: app?.bundleIdentifier,
                               appName: app?.localizedName ?? "Unknown",
                               pid: app?.processIdentifier)
        if let url = app?.bundleURL {
            ctx.isElectron = FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        }
        guard AXIsProcessTrusted(), let pid = ctx.pid else { return ctx }

        let appElement = AXUIElementCreateApplication(pid)
        // Electron apps only build their AX tree when asked to.
        if ctx.isElectron {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return ctx }
        AXUIElementSetMessagingTimeout(element, 0.25)
        ctx.element = element
        ctx.role = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        ctx.isSecure = subrole == (kAXSecureTextFieldSubrole as String)
        guard !ctx.isSecure else { return ctx }

        ctx.selectedText = attribute(element, kAXSelectedTextAttribute)
        if let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                ctx.selection = range
                ctx.precedingText = text(in: element, endingAt: range.location, length: 400)
                ctx.followingText = text(in: element, startingAt: range.location + range.length, length: 20)
            }
        }
        return ctx
    }

    /// B11: visible text of the focused window (static text, fields, titles),
    /// skipping secure fields. Capped at `maxChars` and `budget` seconds.
    static func windowText(for ctx: FocusContext, maxChars: Int = 2000, budget: TimeInterval = 0.15) -> String {
        guard let pid = ctx.pid else { return "" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return "" }
        let deadline = Date().addingTimeInterval(budget)
        var queue: [AXUIElement] = [window]
        var text = ""
        var visited = 0
        while !queue.isEmpty, text.count < maxChars, visited < 1500, Date() < deadline {
            let node = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.05)
            let subrole: String? = attribute(node, kAXSubroleAttribute)
            if subrole == (kAXSecureTextFieldSubrole as String) { continue }
            let role: String? = attribute(node, kAXRoleAttribute)
            if ["AXStaticText", "AXTextField", "AXTextArea", "AXHeading", "AXLink", "AXCell"].contains(role ?? "") {
                if let value: String = attribute(node, kAXValueAttribute), !value.isEmpty {
                    text += String(value.prefix(maxChars - text.count)) + "\n"
                }
            }
            if let title: String = attribute(node, kAXTitleAttribute), !title.isEmpty, text.count < maxChars {
                text += String(title.prefix(maxChars - text.count)) + "\n"
            }
            if let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) { queue += children.prefix(200) }
        }
        return String(text.prefix(maxChars))
    }

    /// The page URL when the focused element is inside a browser's web area (B9).
    /// Walks up from the focused element to the AXWebArea and reads AXURL,
    /// falling back to the window's AXDocument. Only called when a mode lists a website.
    static func browserURL(for ctx: FocusContext) -> String? {
        guard let element = ctx.element else { return nil }
        var current: AXUIElement? = element
        var window: AXUIElement?
        for _ in 0..<60 {
            guard let node = current else { break }
            let role: String? = attribute(node, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url: URL = attribute(node, "AXURL") { return url.absoluteString }
                if let url: String = attribute(node, "AXURL") { return url }
            }
            if role == (kAXWindowRole as String) { window = node; break }
            current = attribute(node, kAXParentAttribute)
        }
        if let window, let doc: String = attribute(window, kAXDocumentAttribute) { return doc }
        return nil
    }

    /// Reads up to `length` UTF-16 units before `location` without pulling the
    /// whole document over AX.
    static func text(in element: AXUIElement, endingAt location: Int, length: Int) -> String? {
        let start = max(0, location - length)
        var range = CFRange(location: start, length: location - start)
        guard range.length > 0, let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      axRange, &result) == .success,
           let s = result as? String {
            return s
        }
        guard let value: String = attribute(element, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        guard location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: location - start))
    }

    /// Reads up to `length` UTF-16 units starting at `location`.
    static func text(in element: AXUIElement, startingAt location: Int, length: Int) -> String? {
        guard let total: Int = attribute(element, kAXNumberOfCharactersAttribute), location < total else { return nil }
        var range = CFRange(location: location, length: min(length, total - location))
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      axRange, &result) == .success,
           let s = result as? String {
            return s
        }
        guard let value: String = attribute(element, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        guard location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: location, length: min(length, ns.length - location)))
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // Casts to CF types always succeed in Swift, so check the CF type ID first.
        if T.self == AXUIElement.self { return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil }
        if T.self == AXValue.self { return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil }
        return value as? T
    }
}
