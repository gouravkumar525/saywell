import Foundation

/// Apps whose dictations are never written to history or training samples
/// (G5). Dictation still works there; nothing about it is stored.
public enum PrivacyPolicy {

    public static let defaultDenyApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop", "com.dashlane.Dashlane",
    ]

    /// Setting `privacy.deny.apps`: comma-separated bundle IDs; defaults above.
    public static func denyApps(in store: Store?) -> [String] {
        guard let raw = store?.setting("privacy.deny.apps") else { return defaultDenyApps }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func setDenyApps(_ apps: [String], in store: Store) {
        store.setSetting("privacy.deny.apps", apps.joined(separator: ","))
    }

    public static func shouldStore(bundleID: String?, store: Store?) -> Bool {
        guard let bundleID else { return true }
        return !denyApps(in: store).contains(bundleID)
    }
}
