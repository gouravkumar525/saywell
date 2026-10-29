import Foundation

/// Cleans up raw dictation transcripts: removes filler words, applies spoken
/// corrections ("no, change that to ..."), formats lists, and tidies punctuation.
public struct TextProcessor {

    /// C2: spoken commands, lists, numbers and repairs are English phrases;
    /// other languages get filler removal and tidying only.
    public var englishRules: Bool

    public init(englishRules: Bool = true) {
        self.englishRules = englishRules
    }

    public func process(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = removeFillers(text)
        guard englishRules else { return tidy(text) }
        text = applyCorrections(text)
        text = applyLayoutCommands(text)
        text = formatNumberedList(text)
        text = formatBulletList(text)
        text = SpokenFormatting.apply(text)
        // After number formatting, so "$25, sorry, no, $30" compares values.
        text = SpokenFormatting.repairs(text)
        text = tidy(text)
        return text
    }

    // MARK: - Fillers

    private static let fillerPattern =
        "(?i)(^|\\s)(um+|uh+|uhm|erm|hmm+|mhm|mm+)([,.!?]?)(?=\\s|$)"

    func removeFillers(_ text: String) -> String {
        var result = text
        // Repeat so overlapping matches ("um, uh,") are all caught.
        while let range = result.range(of: Self.fillerPattern, options: .regularExpression) {
            let match = String(result[range])
            // Keep the leading whitespace captured by the pattern.
            let leading = match.first == " " ? " " : ""
            result.replaceSubrange(range, with: leading)
        }
        return result
    }

    // MARK: - Spoken corrections

    private static let scratchPattern =
        "(?i)[,.!?]?\\s*(?:no[,.]?\\s+)?(?:scratch that|strike that|forget that|delete that)[,.!?]?\\s*"
    private static let changePattern =
        "(?i)[,.!?]?\\s*(?:no[,.!?]?\\s+)?(?:change (?:that|it) to|make (?:that|it)|replace (?:that|it) with|i meant to say|i meant|i mean)[,:]?\\s+"

    func applyCorrections(_ text: String) -> String {
        var result = text
        while let range = result.range(of: Self.scratchPattern, options: .regularExpression) {
            let before = String(result[..<range.lowerBound])
            let after = String(result[range.upperBound...])
            result = joinClauses(dropLastClause(from: before), after)
        }
        while let range = result.range(of: Self.changePattern, options: .regularExpression) {
            let before = String(result[..<range.lowerBound])
            let replacement = String(result[range.upperBound...])
            result = applyReplacement(before: before, replacement: replacement)
        }
        return result
    }

    /// Removes the last clause (text after the final . ! ? or ,) from `text`.
    private func dropLastClause(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if let boundary = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,;"), options: .backwards) {
            return String(trimmed[..<boundary.upperBound])
        }
        return ""
    }

    private func lastClause(of text: String) -> (head: String, clause: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let boundary = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,;"), options: .backwards) {
            let head = String(trimmed[..<boundary.upperBound])
            let clause = String(trimmed[boundary.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (head, clause)
        }
        return ("", trimmed)
    }

    private func joinClauses(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespaces)
        var right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty {
            // New sentence start: drop a leading connector comma artifact.
            if right.hasPrefix(",") { right = String(right.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return right
        }
        if right.isEmpty { return left }
        return left + " " + right
    }

    /// "meet on Monday" + "Tuesday" -> "meet on Tuesday".
    /// Strips the words shared at the start/end of the last clause and the
    /// replacement, then swaps the differing middle.
    private func applyReplacement(before: String, replacement: String) -> String {
        let (head, clause) = lastClause(of: before)
        let repTrimmed = replacement.trimmingCharacters(in: .whitespaces)
        guard !clause.isEmpty else { return joinClauses(head, repTrimmed) }

        // Split the replacement into the correction clause and any continuation.
        var correction = repTrimmed
        var continuation = ""
        if let boundary = repTrimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
            correction = String(repTrimmed[..<boundary.lowerBound])
            continuation = String(repTrimmed[boundary.lowerBound...])
        }

        var prevWords = clause.split(separator: " ").map(String.init)
        var newWords = correction.split(separator: " ").map(String.init)

        func norm(_ w: String) -> String {
            w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        // Strip common prefix.
        var prefix: [String] = []
        while let p = prevWords.first, let n = newWords.first, norm(p) == norm(n) {
            prefix.append(n)
            prevWords.removeFirst()
            newWords.removeFirst()
        }
        // Strip common suffix.
        var suffix: [String] = []
        while let p = prevWords.last, let n = newWords.last, norm(p) == norm(n) {
            suffix.insert(n, at: 0)
            prevWords.removeLast()
            newWords.removeLast()
        }

        var kept = prevWords
        if !newWords.isEmpty, !kept.isEmpty {
            // Anchor on the correction's first word: "the design team" ->
            // "the platform team" re-speaks from "the", so replace from there.
            // No anchor -> assume the correction targets only the last word
            // ("Monday" -> "Tuesday at noon" keeps "Send it").
            if let first = newWords.first,
               let anchor = kept.lastIndex(where: { norm($0) == norm(first) }) {
                kept.removeSubrange(anchor...)
            } else {
                kept.removeLast()
            }
        }

        var rebuilt = (prefix + kept + newWords + suffix).joined(separator: " ")
        rebuilt = joinClauses(head, rebuilt)
        if !continuation.isEmpty { rebuilt += continuation }
        return rebuilt
    }

    // MARK: - Layout commands

    func applyLayoutCommands(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: "(?i)[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*",
            with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(?i)[,.]?\\s*\\bnew line\\b[,.]?\\s*",
            with: "\n", options: .regularExpression)
        return result
    }

    // MARK: - Lists

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5,
        "6": 6, "7": 7, "8": 8, "9": 9, "10": 10,
    ]

    /// "number one buy milk, number two call mom" -> "1. Buy milk\n2. Call mom"
    func formatNumberedList(_ text: String) -> String {
        let pattern = "(?i)[,.!?]?\\s*\\bnumber (one|two|three|four|five|six|seven|eight|nine|ten|10|[1-9])[,.:]?\\s+"
        return formatList(text, markerPattern: pattern) { match in
            let word = match.lowercased()
                .replacingOccurrences(of: "(?i)[,.!?]?\\s*\\bnumber ", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.: "))
            let n = Self.numberWords[word] ?? 0
            return "\(n). "
        }
    }

    /// "bullet point buy milk bullet point call mom" -> "- Buy milk\n- Call mom"
    func formatBulletList(_ text: String) -> String {
        let pattern = "(?i)[,.!?]?\\s*\\bbullet(?: point)?[,.:]?\\s+"
        return formatList(text, markerPattern: pattern) { _ in "- " }
    }

    private func formatList(_ text: String, markerPattern: String,
                            marker: (String) -> String) -> String {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return text }

        var output = ""
        var cursor = 0
        for m in matches {
            let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let trimmedChunk = chunk.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if !trimmedChunk.isEmpty {
                output += trimmedChunk + "\n"
            }
            output += marker(ns.substring(with: m.range))
            cursor = m.range.location + m.range.length
        }
        let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
        output += tail
        // Clean separators left between items ("Buy milk, 2. ..." handled above;
        // trailing commas at line ends removed in tidy()).
        return output
    }

    // MARK: - Tidy

    func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            // Collapse runs of spaces.
            l = l.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            // No space before closing punctuation.
            l = l.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
            // Collapse duplicate punctuation like ",." or ",,".
            l = l.replacingOccurrences(of: "([,.!?;:])[,;:]+", with: "$1", options: .regularExpression)
            l = l.trimmingCharacters(in: .whitespaces)
            // Drop a dangling separator at line end ("Buy milk," in a list).
            if l.hasSuffix(",") || l.hasSuffix(";") { l = String(l.dropLast()) }
            return capitalizeSentences(l)
        }
        // Remove empty artifacts but keep intentional paragraph breaks.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var result = lines.joined(separator: "\n")
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // Ensure terminal punctuation unless the text ends in a list item.
        if let lastLine = lines.last,
           !lastLine.isEmpty,
           lastLine.range(of: "^(\\d+\\.|-)\\s", options: .regularExpression) == nil,
           let last = result.last, last.isLetter || last.isNumber {
            result += "."
        }
        return result
    }

    private func capitalizeSentences(_ line: String) -> String {
        guard !line.isEmpty else { return line }
        var chars = Array(line)
        var capitalizeNext = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                // Skip capitalization right after a list marker ("1." handled here too,
                // but list items read better capitalized, so capitalize anyway).
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if ".!?".contains(c) {
                // Only a sentence end, not "gmail.com" or "v2.5".
                capitalizeNext = i + 1 >= chars.count || chars[i + 1].isWhitespace
            } else if c.isLetter || c.isNumber {
                capitalizeNext = capitalizeNext && false
            }
            i += 1
        }
        return String(chars)
    }
}
