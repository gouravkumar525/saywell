import Foundation

/// Finds word-level substitutions between text we inserted and what the user
/// edited it into. Small substitutions ("Jon" → "John") are dictionary candidates.
public enum EditDiff {

    public struct Correction: Equatable {
        public let original: String
        public let corrected: String
    }

    public static func corrections(inserted: String, edited: String, maxWords: Int = 3) -> [Correction] {
        let a = words(inserted), b = words(edited)
        guard !a.isEmpty, !b.isEmpty, a.count < 400, b.count < 400 else { return [] }

        // LCS table on exact words (so case fixes like "github" → "GitHub" count),
        // then walk it to collect replaced runs.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var result: [Correction] = []
        var i = 0, j = 0
        var delA: [String] = [], insB: [String] = []
        func flush() {
            defer { delA.removeAll(); insB.removeAll() }
            guard !delA.isEmpty, !insB.isEmpty, delA.count <= maxWords, insB.count <= maxWords else { return }
            let original = delA.joined(separator: " "), corrected = insB.joined(separator: " ")
            let o = strip(original), c = strip(corrected)
            // Punctuation-only edits aren't vocabulary.
            guard !o.isEmpty, !c.isEmpty, o != c else { return }
            result.append(Correction(original: o, corrected: c))
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                insB.append(b[j]); j += 1
            } else {
                delA.append(a[i]); i += 1
            }
        }
        flush()
        return result
    }

    /// Share of words that differ between two texts (0 = same, 1 = all changed),
    /// ignoring case and punctuation. Used to flag heavy LLM rewrites.
    public static func changedFraction(_ a: String, _ b: String) -> Double {
        let x = words(a).map { strip($0).lowercased() }.filter { !$0.isEmpty }
        let y = words(b).map { strip($0).lowercased() }.filter { !$0.isEmpty }
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        guard x.count < 2000, y.count < 2000 else { return 1 }
        var row = Array(repeating: 0, count: y.count + 1)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var previous = 0
            for j in 1...max(1, y.count) where !y.isEmpty {
                let current = row[j]
                row[j] = x[i - 1] == y[j - 1] ? previous + 1 : max(row[j], row[j - 1])
                previous = current
            }
        }
        let lcs = row[y.count]
        return 1 - Double(lcs) / Double(max(x.count, y.count))
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}
