import Foundation

/// A user-defined writing mode (B9): extra instructions, a level, or a style
/// that applies in some apps, on some websites, or when the dictation starts
/// with a spoken trigger ("email mode, hi John …"). Every field except `name`
/// is optional; nil inherits the normal setting.
public struct WritingMode: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Bundle IDs.
    public var apps: [String]
    /// Host plus optional path prefix, e.g. "mail.google.com/mail" or "github.com".
    /// A host also matches its subdomains.
    public var websites: [String]
    /// Spoken words that switch this mode on when they start the dictation.
    public var trigger: String?
    public var level: CleanupLevel?
    public var style: AppStyle?
    /// Appended to the cleanup instructions (at most `maxInstructions` characters).
    public var instructions: String?

    public static let maxInstructions = 500

    public init(name: String, apps: [String] = [], websites: [String] = [], trigger: String? = nil,
                level: CleanupLevel? = nil, style: AppStyle? = nil, instructions: String? = nil) {
        self.name = name
        self.apps = apps
        self.websites = websites
        self.trigger = trigger
        self.level = level
        self.style = style
        self.instructions = instructions.map { String($0.prefix(Self.maxInstructions)) }
    }

    /// Instructions trimmed and capped; nil when empty.
    public var cleanInstructions: String? {
        guard let text = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(Self.maxInstructions))
    }

    // MARK: Persistence (one JSON setting)

    public static func decodeList(_ json: String?) -> [WritingMode] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WritingMode].self, from: data)) ?? []
    }

    public static func encodeList(_ modes: [WritingMode]) -> String {
        guard let data = try? JSONEncoder().encode(modes) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

extension CleanupLevel: Codable {}
extension AppStyle: Codable {}

/// Picks the mode for a dictation. Order: spoken trigger → website → app → none.
public enum ModeMatcher {

    public struct Match: Equatable {
        public var mode: WritingMode
        /// The transcript with the trigger words removed (unchanged otherwise).
        public var transcript: String
        public var reason: String

        public init(mode: WritingMode, transcript: String, reason: String) {
            self.mode = mode
            self.transcript = transcript
            self.reason = reason
        }
    }

    /// Whether any mode lists a website, so the browser URL is worth reading.
    public static func needsURL(_ modes: [WritingMode]) -> Bool {
        modes.contains { !$0.websites.isEmpty }
    }

    public static func match(_ modes: [WritingMode], transcript: String,
                             bundleID: String?, url: String?) -> Match? {
        if let (mode, stripped) = triggerMatch(modes, transcript: transcript) {
            return Match(mode: mode, transcript: stripped, reason: "trigger")
        }
        if let url, let mode = modes.first(where: { m in m.websites.contains { websiteMatches($0, url: url) } }) {
            return Match(mode: mode, transcript: transcript, reason: "website")
        }
        if let bundleID, let mode = modes.first(where: { $0.apps.contains(bundleID) }) {
            return Match(mode: mode, transcript: transcript, reason: "app")
        }
        return nil
    }

    /// The first mode whose trigger starts the transcript, with the trigger and
    /// the punctuation after it removed. The longest trigger wins.
    public static func triggerMatch(_ modes: [WritingMode], transcript: String) -> (WritingMode, String)? {
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let candidates = modes.compactMap { mode -> (WritingMode, [String])? in
            guard let trigger = mode.trigger else { return nil }
            let t = trigger.split(whereSeparator: { $0.isWhitespace }).map { norm(String($0)) }.filter { !$0.isEmpty }
            return t.isEmpty ? nil : (mode, t)
        }.sorted { $0.1.count > $1.1.count }
        for (mode, t) in candidates where words.count >= t.count {
            guard zip(words.prefix(t.count), t).allSatisfy({ norm($0) == $1 }) else { continue }
            var rest = words.dropFirst(t.count).joined(separator: " ")
            rest = rest.replacingOccurrences(of: "^[\\s,.:;!?-]+", with: "", options: .regularExpression)
            if let first = rest.first { rest = first.uppercased() + rest.dropFirst() }
            return (mode, rest)
        }
        return nil
    }

    /// "mail.google.com/mail" matches "https://mail.google.com/mail/u/0/#inbox";
    /// "google.com" matches any *.google.com page; paths match on segment boundaries.
    public static func websiteMatches(_ pattern: String, url: String) -> Bool {
        let p = pattern.lowercased()
            .replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !p.isEmpty else { return false }
        let patternHost = p.split(separator: "/", maxSplits: 1).first.map(String.init) ?? p
        let patternPath = p.dropFirst(patternHost.count)

        guard let components = URLComponents(string: url.contains("://") ? url : "https://" + url),
              var host = components.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host == patternHost || host.hasSuffix("." + patternHost) else { return false }
        guard !patternPath.isEmpty else { return true }
        let path = components.path.lowercased()
        return path == patternPath || path.hasPrefix(patternPath + "/")
    }
}
