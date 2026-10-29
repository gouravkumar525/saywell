import Foundation

/// Content-word comparison between what was said and what the model wrote
/// (G1). Catches dropped words, synonyms ("doc" → "document"), answers, and
/// invented content that the length-ratio check lets through.
public enum Faithfulness {

    public struct Report: Equatable {
        /// Content words of the input that the output lost.
        public var missing: [String]
        /// Content words of the output found in neither the input nor the dictionary.
        public var invented: [String]
        /// Number of content words in the input.
        public var inputCount: Int
    }

    public static func check(input: String, output: String, dictionary: [String] = []) -> Report {
        let inWords = contentWords(input)
        let outWords = contentWords(output)
        let inSet = Set(inWords.map(stem))
        let outSet = Set(outWords.map(stem))
        let dictionaryWords = Set(dictionary.flatMap(contentWords).map(stem))

        var missing = inWords.filter { !outSet.contains(stem($0)) }
        // Words respelled into a dictionary term ("cooper netties" → "Kubernetes").
        let addedTerms = dictionary.filter { term in
            let c = Phonetic.compact(term)
            return outWords.contains { Phonetic.compact($0) == c } || Phonetic.compact(output).contains(c)
        }
        if !addedTerms.isEmpty, !missing.isEmpty {
            missing = forgiveRespellings(missing, inWords: inWords, terms: addedTerms)
        }
        var seen = Set<String>()
        let invented = outWords.filter { w in
            let s = stem(w)
            guard !inSet.contains(s), !dictionaryWords.contains(s), seen.insert(s).inserted else { return false }
            return true
        }
        var uniqueMissing: [String] = []
        for w in missing where !uniqueMissing.contains(w) { uniqueMissing.append(w) }
        return Report(missing: uniqueMissing, invented: invented, inputCount: Set(inWords).count)
    }

    /// Whether a report is within the limits for `level`. Light cleanup may not
    /// drop anything; full cleanup may rephrase a little.
    public static func passes(_ report: Report, level: CleanupLevel) -> Bool {
        let n = Double(report.inputCount)
        switch level {
        case .off, .light:
            return report.missing.isEmpty && report.invented.count <= Int(n * 0.05)
        case .full:
            return report.missing.count <= max(1, Int(n * 0.1)) && report.invented.count <= max(2, Int(n * 0.25))
        }
    }

    /// Lowercased words with stopwords, fillers, and punctuation removed.
    /// Number words become digits so "three" and "3" match.
    public static func contentWords(_ s: String) -> [String] {
        normalizedWords(s).filter { !stopwords.contains($0) }
    }

    /// Every word, lowercased, without punctuation; spelled-out numbers as
    /// digits ("two hundred and four" → "204", "fifth"/"5th" → "5", "1,200" → "1200").
    /// Also the tokenization for word error rate in the ASR bench.
    public static func normalizedWords(_ s: String) -> [String] {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'s\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "(?<=\\d),(?=\\d{3})", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?<=\\d)(st|nd|rd|th)\\b", with: "", options: .regularExpression)
        let tokens = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return combineNumbers(tokens)
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fifteenth": 15, "twentieth": 20,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "thirtieth": 30,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000]

    /// Spoken numbers to digits, combining only grammatical runs: "twenty five"
    /// → 25 and "twelve hundred" → 1200, but "three thirty" stays "3", "30".
    private static func combineNumbers(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var total = 0, current = 0, active = false
        var last: Int?            // last value added to `current`, for "twenty" + "five"
        var lastScale = Int.max   // last scale applied, for "hundred" + "four"
        func flush() {
            if active { out.append(String(total + current)) }
            total = 0; current = 0; active = false; last = nil; lastScale = Int.max
        }
        for (i, t) in tokens.enumerated() {
            if let v = units[t] ?? tens[t] {
                let isTens = tens[t] != nil
                let joins: Bool
                if !active { joins = false }
                else if let l = last, l >= 20, l % 10 == 0, l < 100, !isTens, v < 10 { joins = true }   // twenty five
                else if lastScale != Int.max, last == nil { joins = true }                             // hundred four
                else { joins = false }
                if !joins { flush() }
                current += v
                last = v
                active = true
            } else if let scale = scales[t], active {
                if scale > lastScale || lastScale == Int.max && scale >= 1000 {
                    total = (total + max(current, 1)) * scale
                    current = 0
                } else if scale >= 1000 {
                    total += max(current, 1) * scale
                    current = 0
                } else {
                    current = max(current, 1) * scale
                }
                lastScale = scale
                last = nil
            } else if t == "and", active, last == nil, i + 1 < tokens.count, units[tokens[i + 1]] != nil || tens[tokens[i + 1]] != nil {
                continue   // "two hundred and four"
            } else {
                flush()
                out.append(t)
            }
        }
        flush()
        return out
    }

    /// Light plural/possessive folding so "reports" matches "report".
    static func stem(_ w: String) -> String {
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    /// Drops runs of 1–3 consecutive missing words that sound like a dictionary
    /// term the output gained.
    private static func forgiveRespellings(_ missing: [String], inWords: [String], terms: [String]) -> [String] {
        var forgiven = Set<Int>()
        let keys = Set(terms.map(Phonetic.key).filter { $0.count >= 3 })
        for start in inWords.indices {
            for n in 1...3 where start + n <= inWords.count {
                let run = inWords[start..<(start + n)]
                if keys.contains(Phonetic.key(run.joined())) { forgiven.formUnion(start..<(start + n)) }
            }
        }
        let forgivenWords = Set(forgiven.map { inWords[$0] })
        return missing.filter { !forgivenWords.contains($0) }
    }

    static let stopwords: Set<String> = [
        // articles, pronouns, determiners
        "a", "an", "the", "i", "me", "my", "mine", "we", "us", "our", "you", "your", "he", "him", "his",
        "she", "her", "it", "its", "they", "them", "their", "this", "that", "these", "those", "there",
        "here", "what", "which", "who", "whom", "whose", "some", "any", "all", "each", "every", "both",
        // auxiliaries and very common verbs
        "am", "is", "are", "was", "were", "be", "been", "being", "do", "does", "did", "done", "have",
        "has", "had", "will", "would", "shall", "should", "can", "could", "may", "might", "must",
        "going", "gonna", "wanna", "gotta", "get", "got", "let", "lets",
        // contractions with apostrophes removed
        "im", "ive", "id", "ill", "youre", "youve", "youll", "youd", "hes", "shes", "were", "weve",
        "well", "wed", "theyre", "theyve", "theyll", "dont", "doesnt", "didnt", "cant", "couldnt",
        "wont", "wouldnt", "shouldnt", "isnt", "arent", "wasnt", "werent", "havent", "hasnt",
        "hadnt", "thats", "theres", "whats", "heres", "wheres", "hows", "whos",
        // prepositions and conjunctions
        "of", "to", "in", "on", "at", "by", "for", "with", "from", "about", "into", "onto", "over",
        "under", "up", "down", "out", "off", "as", "than", "then", "and", "or", "but", "nor", "if",
        "so", "because", "since", "while", "when", "where", "how", "why", "also", "too", "very",
        "not", "no", "yes", "just", "only", "even", "still", "already", "again", "now",
        // fillers the cleanup is supposed to remove
        "um", "uh", "uhm", "erm", "hmm", "like", "basically", "actually", "literally", "really",
        "know", "mean", "kind", "sort", "stuff", "thing", "things", "whatever", "okay", "ok", "oh",
        "yeah", "hey", "please", "maybe",
        // spoken symbols that become punctuation ("dot com" → ".com", "15 percent" → "15%")
        "dot", "dash", "hyphen", "slash", "underscore", "comma", "period", "colon", "percent",
        "dollar", "dollars", "sign",
    ]
}
