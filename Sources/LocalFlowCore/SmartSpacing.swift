import Foundation

/// Deterministic spacing and capitalization at the insertion point (G4), so
/// back-to-back dictations don't produce "Thursday?Hold on" or a stray
/// capital mid-sentence. Runs after the LLM.
public enum SmartSpacing {

    /// - preceding/following: text just before and after the caret (nil if unknown).
    /// - keepCapitalized: words that must keep their case (dictionary terms).
    /// - isCommonWord: lowercased word → true for ordinary lowercase English
    ///   words; only those are lowercased mid-sentence, so names keep capitals.
    public static func adjust(_ text: String, preceding: String?, following: String?,
                              keepCapitalized: [String] = [],
                              isCommonWord: (String) -> Bool = { _ in true }) -> String {
        var result = text
        guard !result.isEmpty else { return result }

        if let preceding, let last = preceding.last {
            let opening = "([{\"'“‘/-#@$"
            // After an opening bracket or quote the case is the speaker's choice.
            let boundary = ".?!:" + opening
            let midSentence = !last.isNewline && !boundary.contains(trimmedLast(preceding) ?? ".")
            if midSentence { result = lowercaseFirstWord(result, keep: keepCapitalized, isCommonWord: isCommonWord) }
            let startsWithClosing = result.first.map { ",.;:!?)]}”’".contains($0) } ?? false
            if !last.isWhitespace, !opening.contains(last), !startsWithClosing {
                result = " " + result
            }
        }

        if let following, let next = following.first {
            if next.isLetter || next.isNumber {
                // Continuing an existing sentence: our sentence-ending period is wrong.
                if next.isLowercase, result.hasSuffix("."), !result.hasSuffix("..") {
                    result.removeLast()
                }
                result += " "
            }
        }
        return result
    }

    private static func trimmedLast(_ s: String) -> Character? {
        s.trimmingCharacters(in: .whitespaces).last
    }

    private static func lowercaseFirstWord(_ text: String, keep: [String],
                                           isCommonWord: (String) -> Bool) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        guard !word.isEmpty else { return text }
        // "I", "I'm"; acronyms like "API"; names and dictionary terms.
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return text }
        if word.count > 1, word == word.uppercased() { return text }
        if keep.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { return text }
        guard isCommonWord(word.lowercased()) else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// Spoken symbols and identifier casing for code style (G10): "dash dash help"
/// → "--help", "index dot js" → "index.js", "camel case user name" → "userName".
public enum CodeDictation {

    public static func apply(_ text: String) -> String {
        var s = text
        s = casing(s)
        let rules: [(String, String)] = [
            ("(?i)\\bdash dash ([A-Za-z0-9])", "--$1"),
            ("(?i)(^|\\s)dash ([A-Za-z0-9])", "$1-$2"),
            ("(?i)\\s*\\bunderscore\\b\\s*", "_"),
            ("(?i)(?<=[A-Za-z0-9_])\\s+dot\\s+(?=[A-Za-z0-9_])", "."),
            ("(?i)(^|\\s)dot\\s+(?=[A-Za-z0-9_])", "$1."),
            ("(?i)\\s*\\bforward slash\\b\\s*", "/"),
            ("(?i)(?<=[A-Za-z0-9_.~])\\s+slash\\s+(?=[A-Za-z0-9_.~])", "/"),
            ("(?i)\\btilde slash\\b\\s*", "~/"),
            ("(?i)\\s*\\bdouble colon\\b\\s*", "::"),
            ("(?i)\\bopen paren\\b\\s*", "("),
            ("(?i)\\s*\\bclose paren\\b", ")"),
            ("(?i)\\s*\\bequals equals\\b\\s*", " == "),
            ("(?i)\\bat sign\\s*", "@"),
            ("(?i)\\bhash sign\\s*", "#"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    private static let stopAt: Set<String> = ["and", "then", "to", "in", "with", "for", "from", "into", "or", "on", "is", "as"]

    /// "camel case user name" → "userName"; also snake, kebab, pascal, constant case.
    private static func casing(_ text: String) -> String {
        let pattern = "(?i)\\b(camel|snake|kebab|pascal|constant) case\\s+"
        var result = text
        while let range = result.range(of: pattern, options: .regularExpression) {
            let kind = result[range].lowercased().components(separatedBy: " ").first ?? "camel"
            var words: [String] = []
            var end = range.upperBound
            var scan = result[range.upperBound...]
            while words.count < 5, let match = scan.range(of: "^[A-Za-z0-9]+", options: .regularExpression) {
                let word = String(scan[match])
                if stopAt.contains(word.lowercased()) { break }
                words.append(word.lowercased())
                end = match.upperBound
                scan = result[end...]
                guard let space = scan.range(of: "^ ", options: .regularExpression) else { break }
                scan = result[space.upperBound...]
            }
            guard !words.isEmpty else {
                result.replaceSubrange(range, with: "")
                continue
            }
            let identifier: String
            switch kind {
            case "snake": identifier = words.joined(separator: "_")
            case "kebab": identifier = words.joined(separator: "-")
            case "constant": identifier = words.joined(separator: "_").uppercased()
            case "pascal": identifier = words.map(\.capitalized).joined()
            default: identifier = words[0] + words.dropFirst().map(\.capitalized).joined()
            }
            result.replaceSubrange(range.lowerBound..<end, with: identifier)
        }
        return result
    }
}

/// Splits a transcript into finished sentences for streaming cleanup (G2).
public enum SentenceSplitter {

    /// Sentences ending in . ? or ! (followed by space or end) plus the unfinished tail.
    public static func split(_ text: String) -> (sentences: [String], tail: String) {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            guard ".?!".contains(c) else { continue }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            // "3.5", "e.g." and "..." aren't sentence ends.
            if let next, !next.isWhitespace { continue }
            if c == ".", isAbbreviation(current) { continue }
            // A list marker ("1.") isn't a sentence.
            if c == ".", current.trimmingCharacters(in: .whitespacesAndNewlines).dropLast().allSatisfy(\.isNumber) { continue }
            let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            current = ""
        }
        return (sentences, current.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Splits long text into pieces of at most about `maxWords` words for
    /// cleanup, keeping the separator that followed each piece ("\n", " ")
    /// so joining `text + separator` rebuilds the layout. Lines are kept whole
    /// where possible, so lists and paragraphs survive.
    public static func segments(_ text: String, maxWords: Int = 70) -> [(text: String, separator: String)] {
        guard CleanupPrompt.wordCount(text) > maxWords else { return [(text, "")] }
        var pieces: [(text: String, separator: String)] = []
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let lineSeparator = i < lines.count - 1 ? "\n" : ""
            if CleanupPrompt.wordCount(line) > maxWords {
                let parts = chunks(line, maxWords: maxWords)
                for (j, part) in parts.enumerated() {
                    pieces.append((part, j < parts.count - 1 ? " " : lineSeparator))
                }
            } else {
                pieces.append((line, lineSeparator))
            }
        }
        // Merge short neighbouring lines back up to the budget.
        var merged: [(text: String, separator: String)] = []
        for piece in pieces {
            if var last = merged.last, !last.text.isEmpty,
               CleanupPrompt.wordCount(last.text) + CleanupPrompt.wordCount(piece.text) <= maxWords {
                last.text += last.separator + piece.text
                last.separator = piece.separator
                merged[merged.count - 1] = last
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    /// Groups sentences into chunks of at most about `maxWords` words.
    public static func chunks(_ text: String, maxWords: Int = 60) -> [String] {
        let (sentences, tail) = split(text)
        var all = sentences
        if !tail.isEmpty { all.append(tail) }
        var result: [String] = []
        var current: [String] = []
        var count = 0
        for s in all {
            let n = CleanupPrompt.wordCount(s)
            if count > 0, count + n > maxWords {
                result.append(current.joined(separator: " "))
                current = []
                count = 0
            }
            current.append(s)
            count += n
        }
        if !current.isEmpty { result.append(current.joined(separator: " ")) }
        return result
    }

    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "eg", "ie", "jr", "sr"]

    private static func isAbbreviation(_ sentence: String) -> Bool {
        let lastWord = sentence.dropLast().split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        return abbreviations.contains(lastWord.lowercased().replacingOccurrences(of: ".", with: ""))
    }

    /// The rest of `text` after the words of `prefix`, compared without case or
    /// punctuation ("project we moved" matches "project. We moved"). nil when
    /// the words differ. Lets streamed chunks survive a final pass that only
    /// re-punctuates.
    public static func remainder(of text: String, afterWordsOf prefix: String) -> String? {
        func norm(_ w: Substring) -> String {
            String(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let wanted = prefix.split(whereSeparator: { $0.isWhitespace }).map(norm).filter { !$0.isEmpty }
        var index = text.startIndex
        var matched = 0
        while matched < wanted.count {
            guard let range = text.range(of: "\\S+", options: .regularExpression, range: index..<text.endIndex) else { return nil }
            index = range.upperBound
            let word = norm(text[range])
            if word.isEmpty { continue }
            guard word == wanted[matched] else { return nil }
            matched += 1
        }
        return String(text[index...]).trimmingCharacters(in: .whitespaces)
    }
}
