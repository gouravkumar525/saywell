import Foundation

/// Live words for batch recognizers (B2). The recognizer re-transcribes the
/// audio window every ~0.5 s; a word is confirmed once `passes` consecutive
/// hypotheses agree on it (lowercased letters and digits). Confirmed words
/// never change; the rest are provisional. When the window grows, the caller
/// cuts the audio at a confirmed sentence end (`cut`) and keeps going.
public struct WordAgreement {

    public struct Word: Equatable {
        public var text: String
        /// Start and end in seconds from the start of the current window, if known.
        public var start: Double?
        public var end: Double?

        public init(_ text: String, start: Double? = nil, end: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public let passes: Int
    /// Every confirmed word so far, across windows.
    public private(set) var confirmed: [String] = []
    /// The latest hypothesis after the confirmed words.
    public private(set) var provisional: [String] = []
    /// Confirmed words inside the current audio window (with their end times).
    private var windowConfirmed: [Word] = []
    /// Unconfirmed tails of the latest passes, newest last.
    private var recent: [[Word]] = []

    public init(passes: Int = 2) {
        self.passes = max(1, passes)
    }

    public var confirmedText: String { confirmed.joined(separator: " ") }
    public var text: String { (confirmed + provisional).joined(separator: " ") }

    /// Words confirmed before the current window started.
    public var committedBeforeWindow: [String] { Array(confirmed.prefix(confirmed.count - windowConfirmed.count)) }

    static func norm(_ w: String) -> String {
        String(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Feeds one hypothesis for the whole current window. Returns the newly
    /// confirmed words. With `windowDuration`, words ending in the last
    /// `holdBack` seconds stay provisional: at the edge of the audio the model
    /// guesses punctuation ("it has three." before "databases" is heard).
    @discardableResult
    public mutating func update(_ hypothesis: [Word], windowDuration: Double? = nil, holdBack: Double = 1.0) -> [String] {
        var hypothesis = hypothesis
        // Right after a cut, a word straddling the cut can be heard twice.
        if windowConfirmed.isEmpty, let last = committedBeforeWindow.last, let first = hypothesis.first,
           Self.norm(first.text) == Self.norm(last), (first.end ?? 0) < 0.6 {
            hypothesis.removeFirst()
        }
        // Already-confirmed words of this window are fixed; compare what follows.
        let tail = Array(hypothesis.dropFirst(windowConfirmed.count))
        recent.append(tail)
        if recent.count > passes { recent.removeFirst(recent.count - passes) }
        var newly: [Word] = []
        if recent.count == passes {
            var k = 0
            while recent.allSatisfy({ k < $0.count }) {
                let first = Self.norm(recent[0][k].text)
                guard recent.allSatisfy({ Self.norm($0[k].text) == first }) else { break }
                if let duration = windowDuration, let end = tail[k].end, end > duration - holdBack { break }
                k += 1
            }
            newly = Array(tail.prefix(k))
            recent = recent.map { Array($0.dropFirst(k)) }
        }
        confirmed += newly.map(\.text)
        windowConfirmed += newly
        provisional = Array(tail.dropFirst(newly.count)).map(\.text)
        return newly.map(\.text)
    }

    /// Where to cut the window: just after the last confirmed word that ends a
    /// sentence at least `minimum` seconds in, or (with `force`) after the last
    /// confirmed word with a time. Rebases the remaining words and returns the
    /// cut in seconds from the window start; nil when there is no safe cut.
    public mutating func cut(minimum: Double, force: Bool = false) -> Double? {
        let sentenceEnd = windowConfirmed.lastIndex { w in
            guard let end = w.end, end >= minimum, let last = w.text.last else { return false }
            return ".?!".contains(last)
        }
        guard let index = sentenceEnd ?? (force ? windowConfirmed.lastIndex { $0.end != nil } : nil),
              let end = windowConfirmed[index].end else { return nil }
        // Cut in the gap before the next word, so neither word is split.
        var at = end
        if index + 1 < windowConfirmed.count, let next = windowConfirmed[index + 1].start, next > end {
            at = (end + next) / 2
        }
        windowConfirmed = windowConfirmed.dropFirst(index + 1).map {
            Word($0.text, start: $0.start.map { max(0, $0 - at) }, end: $0.end.map { $0 - at })
        }
        recent = []
        return at
    }

    /// Final pass over the current window at key-up: everything before the
    /// window plus this text.
    public func finalText(window: String) -> String {
        (committedBeforeWindow + [window.trimmingCharacters(in: .whitespacesAndNewlines)])
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Groups recognizer tokens into words. A token starting with a space or
    /// "▁" (or following a bare "▁") begins a new word; a word spans its first
    /// token's start to its last token's end.
    public static func words(fromTokens tokens: [(token: String, start: Double, end: Double)]) -> [Word] {
        var words: [Word] = []
        var pendingStart = false
        for t in tokens {
            let startsWord = pendingStart || t.token.hasPrefix(" ") || t.token.hasPrefix("▁")
            let piece = t.token.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { pendingStart = pendingStart || startsWord; continue }
            pendingStart = false
            if startsWord || words.isEmpty {
                words.append(Word(piece, start: t.start, end: t.end))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = t.end
            }
        }
        return words
    }
}
