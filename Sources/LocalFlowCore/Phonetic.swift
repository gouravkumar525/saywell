import Foundation

/// Coarse sound-alike keys for vocabulary matching. Simpler than Double
/// Metaphone, but tuned so ASR mishearings of names and jargon collide:
/// "Kubernetes" and "cooper netties" both become "KPRNTS".
public enum Phonetic {

    public static func key(_ s: String) -> String {
        let chars = Array(s.lowercased().filter { $0.isASCII && $0.isLetter })
        var out: [Character] = []
        var i = 0
        func emit(_ c: Character) {
            if out.last != c { out.append(c) }
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "a", "e", "i", "o", "u", "y":
                // Only a leading vowel counts; it still breaks runs ("tt" vs "t-t").
                if out.isEmpty { emit("A") } else if out.last != "_" { out.append("_") }
            case "h", "w":
                break
            case "b", "p":
                if c == "p", next == "h" { emit("F"); i += 1 } else { emit("P") }
            case "c":
                if next == "h" { emit("X"); i += 1 }
                else if let n = next, "eiy".contains(n) { emit("S") }
                else { emit("K") }
            case "k", "q", "g":
                emit("K")
            case "j":
                emit("J")
            case "x":
                emit("K"); emit("S")
            case "s", "z":
                if next == "h" { emit("X"); i += 1 } else { emit("S") }
            case "d", "t":
                if c == "t", next == "h" { i += 1 }
                emit("T")
            case "f", "v":
                emit("F")
            case "l", "m", "n", "r":
                emit(Character(c.uppercased()))
            default:
                break
            }
            i += 1
        }
        // Vowel markers only separate repeated consonants; drop them.
        return String(out.filter { $0 != "_" })
    }

    /// Lowercased letters and digits only: "Local Flow" → "localflow".
    public static func compact(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[b.count]
    }
}

/// Deterministic respelling of dictionary terms after the LLM pass (G6):
/// a word or 2–3 word run that sounds like a term becomes that term. Common
/// English words are never touched, so boosting can't distort ordinary text.
public struct VocabularyCorrector {
    public struct Term {
        public let text: String
        let key: String
        let compact: String
    }

    public let terms: [Term]
    private let isCommonWord: (String) -> Bool

    /// `isCommonWord` receives a lowercased word.
    public init(terms: [String], isCommonWord: @escaping (String) -> Bool) {
        self.terms = terms.compactMap { t in
            let compact = Phonetic.compact(t)
            guard compact.count >= 3 else { return nil }
            return Term(text: t, key: Phonetic.key(t), compact: compact)
        }
        self.isCommonWord = isCommonWord
    }

    public struct Replacement: Equatable {
        public let heard: String
        public let term: String
    }

    public func correct(_ text: String) -> (text: String, replacements: [Replacement]) {
        guard !terms.isEmpty else { return (text, []) }
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9][A-Za-z0-9'’]*") else { return (text, []) }
        let words = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)

        var output = ""
        var cursor = 0
        var replacements: [Replacement] = []
        var i = 0
        while i < words.count {
            var matched: (count: Int, term: Term)?
            for n in stride(from: min(3, words.count - i), through: 1, by: -1) {
                let span = words[i..<(i + n)]
                // Words in a run must be separated by single spaces only.
                guard zip(span, span.dropFirst()).allSatisfy({ a, b in
                    ns.substring(with: NSRange(location: a.upperBound, length: b.location - a.upperBound)) == " "
                }) else { continue }
                let range = NSRange(location: span.first!.location, length: span.last!.upperBound - span.first!.location)
                let heard = ns.substring(with: range)
                let parts = span.map { ns.substring(with: $0).lowercased() }
                if let term = match(heard: heard, parts: parts) {
                    matched = (n, term)
                    break
                }
            }
            if let (n, term) = matched {
                let start = words[i].location, end = words[i + n - 1].upperBound
                let heard = ns.substring(with: NSRange(location: start, length: end - start))
                output += ns.substring(with: NSRange(location: cursor, length: start - cursor)) + term.text
                cursor = end
                replacements.append(Replacement(heard: heard, term: term.text))
                i += n
            } else {
                i += 1
            }
        }
        output += ns.substring(from: cursor)
        return (output, replacements)
    }

    private func match(heard: String, parts: [String]) -> Term? {
        let compact = Phonetic.compact(heard)
        guard compact.count >= 3 else { return nil }
        let key = Phonetic.key(heard)
        let allCommon = parts.allSatisfy(isCommonWord)
        for term in terms where heard != term.text {
            if compact == term.compact {
                // Spelling/case fix ("github" → "GitHub", "local flow" → "LocalFlow"),
                // but a single common word ("will" vs a name "Will") stays as it is.
                if parts.count == 1 && allCommon { continue }
                return term
            }
            // Sound-alike: never for runs made only of ordinary words.
            guard !allCommon, key == term.key, key.count >= 3 else { continue }
            let ratio = Double(compact.count) / Double(term.compact.count)
            guard (0.6...1.6).contains(ratio) else { continue }
            return term
        }
        return nil
    }
}
