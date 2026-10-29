import Foundation

/// B11: names and jargon visible in the focused window, used as spelling
/// hints for one dictation only (never stored). Off by default.
public enum ScreenNames {

    /// Mixed-case words ("GitHub", "iPhone") and capitalized words that aren't
    /// ordinary English ("Gourav", "Kubernetes"), most frequent first.
    /// `isCommonWord` receives a lowercased word.
    public static func extract(_ text: String, isCommonWord: (String) -> Bool, limit: Int = 40) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
        for raw in tokens {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            guard word.count >= 3, word.count <= 30, word.rangeOfCharacter(from: .letters) != nil,
                  word.unicodeScalars.allSatisfy({ $0.isASCII }) else { continue }
            let letters = word.filter(\.isLetter)
            let uppers = letters.filter(\.isUppercase).count
            let mixedCase = uppers >= 1 && uppers < letters.count && !(uppers == 1 && word.first!.isUppercase)
            let capitalized = word.first!.isUppercase && uppers == 1
            guard mixedCase || (capitalized && !isCommonWord(word.lowercased())) else { continue }
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }
        return order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .prefix(limit).map(\.element)
    }
}
