import Foundation

/// C2: the language Apple's recognizer listens for. Parakeet v3 detects the
/// language itself. English-only rules (spoken numbers, "scratch that",
/// the common-word guard) run only when the language is English.
public enum SpeechLanguage {
    public static let automatic = "auto"
    public static let fallback = "en_US"

    /// The 25 languages Parakeet TDT v3 recognizes (it detects which one by itself).
    public static let parakeetLanguages = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// Apple locales plus, with Parakeet, its languages that no Apple locale covers.
    public static func choices(appleOnDevice: [String], parakeet: Bool) -> [String] {
        guard parakeet else { return appleOnDevice }
        let covered = Set(appleOnDevice.map { baseCode($0) })
        return appleOnDevice + parakeetLanguages.filter { !covered.contains($0) }
    }

    /// The Apple recognizer locale for a language: itself when installed for
    /// offline use, else en_US (audio never goes to a server).
    public static func appleLocale(for language: String, onDevice: [String]) -> String {
        if let exact = onDevice.first(where: { key($0) == key(language) }) { return exact }
        if let same = onDevice.first(where: { baseCode($0) == baseCode(language) }) { return same }
        return onDevice.first(where: { key($0) == key(fallback) }) ?? fallback
    }

    public static func baseCode(_ identifier: String) -> String {
        key(identifier).split(separator: "_").first.map(String.init) ?? identifier
    }

    /// The recognizer locale for a setting: a fixed identifier when it is
    /// supported, else the first preferred language that is, else en_US.
    /// Identifiers are compared without regard to "-" vs "_" and case.
    public static func resolve(setting: String?, preferred: [String], supported: [String]) -> String {
        let byKey = Dictionary(supported.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        if let setting, setting != automatic, let match = byKey[key(setting)] { return match }
        for language in preferred {
            if let exact = byKey[key(language)] { return exact }
            // "fr" or "fr-CA" with only fr_FR available: same language.
            let base = key(language).split(separator: "_").first.map(String.init) ?? ""
            if let sameLanguage = supported.sorted().first(where: { key($0).hasPrefix(base + "_") || key($0) == base }) {
                return sameLanguage
            }
        }
        return byKey[key(fallback)] ?? supported.first ?? fallback
    }

    public static func isEnglish(_ identifier: String) -> Bool {
        key(identifier) == "en" || key(identifier).hasPrefix("en_")
    }

    /// "Français (France)" for menus, "French" for the model prompt.
    public static func displayName(_ identifier: String, in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    public static func englishName(_ identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? identifier
    }

    private static func key(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-", with: "_").lowercased()
    }
}
