import Foundation

/// Deterministic formatting that used to depend on the LLM (B10): spoken
/// numbers, times, money, percentages, email addresses, @handles, and
/// "sorry, no" repairs. Runs inside `TextProcessor`, so the Off level and the
/// rules-only fallback get it too. Number parsing reuses
/// `Faithfulness.normalizedWords`, so the rules and the faithfulness check agree.
public enum SpokenFormatting {

    public static func apply(_ text: String) -> String {
        var t = text
        t = emails(t)
        t = handles(t)
        t = times(t)
        t = numbers(t)
        t = money(t)
        t = percents(t)
        return t
    }

    // MARK: - Numbers

    private static let cardinalWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million",
    ]
    private static let numberWord = "(?:" + cardinalWords.joined(separator: "|") + ")"
    /// A run of number words, joined by spaces, hyphens, or "and" (only before another number word).
    private static let runPattern =
        "(?i)\\b\(numberWord)(?:(?:[\\s-]+and)?[\\s-]+\(numberWord))*\\b"

    /// Whole runs of spoken numbers → digits. Small counts stay words in prose
    /// ("one of them", "two options") unless a unit follows (percent, dollars,
    /// point, am/pm). A run that isn't one number ("three thirty") is left alone,
    /// except year-like pairs ("twenty twenty five" → 2025).
    static func numbers(_ text: String) -> String {
        replaceMatches(in: text, pattern: runPattern + "(?:\\s+point\\s+((?:\(numberWord)|\\d)(?:\\s+(?:\(numberWord)|\\d))*))?") { m, ns in
            let run = ns.substring(with: m.range(at: 0))
            let hasDecimal = m.range(at: 1).location != NSNotFound
            let wholeRange = hasDecimal
                ? ns.substring(with: m.range(at: 0)).components(separatedBy: " point ").first ?? run
                : run
            let groups = Faithfulness.normalizedWords(wholeRange.replacingOccurrences(of: "-", with: " "))
            guard groups.allSatisfy({ Int($0) != nil }), !groups.isEmpty else { return nil }
            let value: String
            if groups.count == 1 {
                value = groups[0]
            } else if groups.count == 2, let a = Int(groups[0]), let b = Int(groups[1]),
                      (10...29).contains(a), (10...99).contains(b) || b == 0 {
                value = "\(a)\(String(format: "%02d", b))"   // nineteen ninety → 1990
            } else {
                return nil
            }
            var out = value
            if hasDecimal {
                let digits = Faithfulness.normalizedWords(ns.substring(with: m.range(at: 1)))
                guard digits.allSatisfy({ $0.count == 1 && Int($0) != nil }) else { return nil }
                out += "." + digits.joined()
            }
            // Keep small counts as words unless a unit makes them a quantity.
            if !hasDecimal, let n = Int(value), n < 10 {
                let after = ns.substring(from: m.range.location + m.range.length)
                let unitFollows = after.range(of: "^\\s+(?i:percent|per cent|dollars?|bucks|cents?|am|pm|a\\.m\\.|p\\.m\\.)\\b",
                                              options: .regularExpression) != nil
                if !unitFollows { return nil }
            }
            return out
        }
    }

    // MARK: - Times, money, percent

    private static let hourWords = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|1[0-2]|[1-9])"
    private static let minuteWords =
        "(?:(?:o\\s|oh\\s)?(?:one|two|three|four|five|six|seven|eight|nine)|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|"
        + "(?:twenty|thirty|forty|fifty)(?:[\\s-](?:one|two|three|four|five|six|seven|eight|nine))?|[0-5]\\d)"

    /// "three thirty pm" → "3:30 PM", "five p.m." → "5 PM", "seven o'clock" stays.
    static func times(_ text: String) -> String {
        let pattern = "(?i)\\b(\(hourWords))(?:[\\s:](\(minuteWords)))?\\s*(a\\.?\\s?m\\.?|p\\.?\\s?m\\.?)(?=[\\s,.!?;:]|$)"
        return replaceMatches(in: text, pattern: pattern) { m, ns in
            guard let hour = Int(Faithfulness.normalizedWords(ns.substring(with: m.range(at: 1))).first ?? "") else { return nil }
            var out = "\(hour)"
            if m.range(at: 2).location != NSNotFound {
                let minuteText = ns.substring(with: m.range(at: 2))
                    .replacingOccurrences(of: "(?i)^(o|oh)\\s", with: "zero ", options: .regularExpression)
                let parts = Faithfulness.normalizedWords(minuteText.replacingOccurrences(of: "-", with: " ")).compactMap(Int.init)
                let minutes = parts.count == 2 && parts[0] == 0 ? parts[1] : parts.reduce(0, +)
                guard (0...59).contains(minutes) else { return nil }
                out += String(format: ":%02d", minutes)
            }
            let suffix = ns.substring(with: m.range(at: 3)).lowercased().hasPrefix("a") ? "AM" : "PM"
            return out + " " + suffix
        }
    }

    /// "5 dollars" → "$5", "5 dollars and 50 cents" → "$5.50", "$5 dollars" → "$5".
    static func money(_ text: String) -> String {
        var t = replaceMatches(in: text, pattern: "(?i)\\$?\\b(\\d[\\d,]*(?:\\.\\d+)?)\\s+(?:dollars?|bucks)(?:\\s+and\\s+(\\d{1,2})\\s+cents?)?\\b") { m, ns in
            var out = "$" + ns.substring(with: m.range(at: 1))
            if m.range(at: 2).location != NSNotFound {
                guard !out.contains(".") else { return nil }
                out += String(format: ".%02d", Int(ns.substring(with: m.range(at: 2))) ?? 0)
            }
            return out
        }
        t = t.replacingOccurrences(of: "(?i)\\b(\\d+)\\s+cents\\b", with: "$1¢", options: .regularExpression)
        return t
    }

    /// "10 percent" → "10%".
    static func percents(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)\\b(\\d+(?:\\.\\d+)?)\\s*(?:percent|per cent)\\b", with: "$1%", options: .regularExpression)
    }

    // MARK: - Email and handles

    private static let label = "[A-Za-z0-9][A-Za-z0-9_-]*"
    private static let tlds = "com|org|net|io|co|in|ai|dev|edu|gov|uk|us|me|app|info|de|fr|ca|au"

    /// "gourav at gmail dot com" → "gourav@gmail.com", also "first dot last at
    /// company dot co dot in". Requires a known top-level domain at the end so
    /// "meet at noon" is never touched.
    static func emails(_ text: String) -> String {
        let local = "\(label)(?:\\s+(?:dot|underscore|dash)\\s+\(label))*"
        // Spoken ("gmail dot com") or already written by the recognizer ("gmail.com").
        let domain = "\(label)(?:(?:\\s+dot\\s+|\\.)\(label))*(?:\\s+dot\\s+|\\.)(?:\(tlds))"
        let pattern = "(?i)\\b(\(local))\\s+(?:at|at the rate(?: of)?)\\s+(\(domain))\\b"
        return replaceMatches(in: text, pattern: pattern) { m, ns in
            func squash(_ s: String) -> String {
                s.replacingOccurrences(of: "(?i)\\s+dot\\s+", with: ".", options: .regularExpression)
                    .replacingOccurrences(of: "(?i)\\s+underscore\\s+", with: "_", options: .regularExpression)
                    .replacingOccurrences(of: "(?i)\\s+dash\\s+", with: "-", options: .regularExpression)
                    .lowercased()
            }
            let localPart = ns.substring(with: m.range(at: 1))
            // "email me at x dot com": a pronoun isn't an address.
            if !localPart.contains(" "), Faithfulness.stopwords.contains(localPart.lowercased())
                || notAnAddress.contains(localPart.lowercased()) { return nil }
            return squash(localPart) + "@" + squash(ns.substring(with: m.range(at: 2)))
        }
    }

    /// Words that come before "at <site>" in ordinary speech ("look at google.com").
    private static let notAnAddress: Set<String> = [
        "look", "looking", "looked", "visit", "visiting", "check", "checking", "see", "go", "went", "find", "found",
        "available", "online", "posted", "hosted", "live", "published", "listed", "meet", "apply", "signup", "login",
        "download", "read", "stay", "work", "works", "working", "email", "write", "reach", "contact", "ping", "message",
    ]

    /// Joins an address a model split around "@" ("grava@ gmail.com", "grava @gmail.com").
    /// Applied to model output, since the rules never produce the split form.
    public static func joinAddresses(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)\\b([A-Za-z0-9._-]+)\\s*@\\s+([A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.(?:\(tlds)))\\b",
                                  with: "$1@$2", options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\b([A-Za-z0-9._-]+)\\s+@([A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.(?:\(tlds)))\\b",
                                  with: "$1@$2", options: .regularExpression)
    }

    /// "at the rate KV" → "@KV", "at sign john" → "@john".
    static func handles(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)\\bat (?:the rate(?: of)?|sign)\\s+([A-Za-z0-9_]+)",
                                  with: "@$1", options: .regularExpression)
    }

    // MARK: - Repairs

    private static let repairMarker =
        "(?i)[,.]?\\s*\\b(?:sorry,?\\s+no|no,?\\s+sorry|no\\s+wait|wait,?\\s+no|sorry,?\\s+i\\s+mean|oops,?\\s+no)\\b[,.]?\\s+"

    /// "to Pune, sorry, no, to Delhi" → "to Delhi". Only when the restart reuses
    /// one of the last six words before the marker; anything else is left for the
    /// model, because guessing restarts drops real content.
    public static func repairs(_ text: String) -> String {
        var result = text
        var guardCount = 0
        while guardCount < 5, let r = result.range(of: repairMarker, options: .regularExpression) {
            guardCount += 1
            let before = String(result[..<r.lowerBound])
            let after = String(result[r.upperBound...])
            guard let restart = after.split(separator: " ").first.map({ norm(String($0)) }), !restart.isEmpty else { break }
            let words = before.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let window = max(0, words.count - 6)
            let anchor: Int
            if let reused = words[window...].lastIndex(where: { norm($0) == restart }) {
                anchor = reused
            } else if let last = words.last, let next = after.split(separator: " ").first.map(String.init),
                      isValue(last, like: next) {
                // A value swapped for one of its kind: "$25, sorry, no, $30", "Pune, sorry, no, Delhi".
                anchor = words.count - 1
            } else {
                break
            }
            let kept = words[..<anchor].joined(separator: " ")
            result = kept.isEmpty ? after : kept + " " + after
        }
        return result
    }

    /// Both numbers ("$25"/"30", "3:30"), or both capitalized names mid-sentence.
    private static func isValue(_ a: String, like b: String) -> Bool {
        let a = a.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "$%")))
        let b = b.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "$%")))
        let digits = CharacterSet.decimalDigits
        if a.rangeOfCharacter(from: digits) != nil, b.rangeOfCharacter(from: digits) != nil { return true }
        guard let fa = a.first, let fb = b.first, fa.isUppercase, fb.isUppercase, a.count > 1, b.count > 1 else { return false }
        return a != "I" && b != "I"
    }

    private static func norm(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - Helpers

    /// Replaces each regex match with the closure's result (nil keeps the match),
    /// working backwards so ranges stay valid.
    private static func replaceMatches(in text: String, pattern: String,
                                       _ transform: (NSTextCheckingResult, NSString) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let replacement = transform(m, ns) {
                result.replaceCharacters(in: m.range, with: replacement)
            }
        }
        return result as String
    }
}
