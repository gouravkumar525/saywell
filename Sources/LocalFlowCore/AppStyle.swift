import Foundation

/// Writing style applied by the LLM cleanup, chosen from the frontmost app.
public enum AppStyle: String, CaseIterable {
    case formal, casual, code, neutral

    public var label: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .code: return "Code"
        case .neutral: return "Neutral"
        }
    }

    private static let formalApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.apple.iWork.Pages",
        "com.microsoft.Word", "com.readdle.smartemail-Mac", "com.superhuman.electron",
    ]
    private static let casualApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram",
        "com.microsoft.teams2", "org.whispersystems.signal-desktop",
    ]
    private static let codeApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.sublimetext.4", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
    ]

    /// `overrides` maps bundle IDs to a user-chosen style and wins over the defaults.
    public static func forBundleID(_ bundleID: String?, overrides: [String: AppStyle] = [:]) -> AppStyle {
        guard let bundleID else { return .neutral }
        if let style = overrides[bundleID] { return style }
        if formalApps.contains(bundleID) { return .formal }
        if casualApps.contains(bundleID) { return .casual }
        if codeApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .code }
        return .neutral
    }
}
