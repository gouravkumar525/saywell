import Foundation

/// Local usage stats for the Insights tab (B15), computed from the `usage`
/// table (word counts per dictation) and, for the no-edit rate, `samples`.
/// Nothing leaves the Mac.
public struct UsageInsights: Equatable {

    /// One dictation, as much as the stats need.
    public struct Row: Equatable {
        public var created: Date
        public var app: String
        /// Words recognized (before cleanup).
        public var rawWords: Int
        /// Words inserted.
        public var words: Int
        public var durationMs: Int?
        /// nil until the edit watcher has finished with it.
        public var edited: Bool?

        public init(created: Date, app: String, rawWords: Int, words: Int, durationMs: Int? = nil, edited: Bool? = nil) {
            self.created = created
            self.app = app
            self.rawWords = rawWords
            self.words = words
            self.durationMs = durationMs
            self.edited = edited
        }

        public init(created: Date, app: String, raw: String, inserted: String, durationMs: Int? = nil, edited: Bool? = nil) {
            self.init(created: created, app: app, rawWords: CleanupPrompt.wordCount(raw),
                      words: CleanupPrompt.wordCount(inserted), durationMs: durationMs, edited: edited)
        }
    }

    public struct Week: Equatable {
        public var start: Date
        public var watched: Int
        public var noEditRate: Double?
    }

    public var wordsToday = 0
    public var wordsThisWeek = 0
    public var wordsAllTime = 0
    public var dictations = 0
    /// Spoken words per minute of talking, from dictations with a duration.
    public var wordsPerMinute: Double?
    /// Typing time saved: words at 45 wpm typing minus the time spent talking
    /// (from Coucou's formula). Dictations without a duration count at 150 wpm.
    public var minutesSaved: Double = 0
    public static let typingWordsPerMinute = 45.0
    public static let assumedSpeakingWordsPerMinute = 150.0
    /// Words cleanup removed (fillers, repeats, false starts), all time.
    public var wordsRemoved = 0
    public var topApps: [(app: String, words: Int)] = []
    /// Consecutive days with a dictation, ending today (or yesterday).
    public var streakDays = 0
    /// No-edit rate per week, oldest first, for the last `weeks` weeks.
    public var weeks: [Week] = []

    public static func == (a: UsageInsights, b: UsageInsights) -> Bool {
        a.wordsToday == b.wordsToday && a.wordsThisWeek == b.wordsThisWeek && a.wordsAllTime == b.wordsAllTime
            && a.dictations == b.dictations && a.wordsPerMinute == b.wordsPerMinute && a.wordsRemoved == b.wordsRemoved
            && a.topApps.map(\.app) == b.topApps.map(\.app) && a.topApps.map(\.words) == b.topApps.map(\.words)
            && a.streakDays == b.streakDays && a.weeks == b.weeks && a.minutesSaved == b.minutesSaved
    }

    public init() {}

    /// `watched` feeds the weekly no-edit rate (samples the edit watcher
    /// followed); it defaults to `rows`.
    public static func compute(_ rows: [Row], watched: [Row]? = nil, now: Date = Date(),
                               calendar: Calendar = .current, weeks: Int = 8) -> UsageInsights {
        var out = UsageInsights()
        out.dictations = rows.count
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var appWords: [String: Int] = [:]
        var spokenWords = 0, spokenMs = 0
        var talkingMinutes = 0.0
        var days = Set<Date>()
        for r in rows {
            let words = r.words
            out.wordsAllTime += words
            if r.created >= today { out.wordsToday += words }
            if r.created >= weekAgo { out.wordsThisWeek += words }
            out.wordsRemoved += max(0, r.rawWords - words)
            appWords[r.app, default: 0] += words
            if let ms = r.durationMs, ms >= 1000 {
                spokenWords += r.rawWords
                spokenMs += ms
            }
            talkingMinutes += r.durationMs.map { Double($0) / 60_000 }
                ?? Double(r.rawWords) / assumedSpeakingWordsPerMinute
            days.insert(calendar.startOfDay(for: r.created))
        }
        if spokenMs > 0 { out.wordsPerMinute = Double(spokenWords) / (Double(spokenMs) / 60_000) }
        out.minutesSaved = max(0, Double(out.wordsAllTime) / typingWordsPerMinute - talkingMinutes)
        out.topApps = appWords.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5).map { (app: $0.key, words: $0.value) }

        // Streak: today counts if dictated; otherwise it may end yesterday.
        var day = days.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while days.contains(day) {
            out.streakDays += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }

        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        for i in stride(from: weeks - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -i, to: thisWeek),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { continue }
            let watched = (watched ?? rows).filter { $0.created >= start && $0.created < end && $0.edited != nil }
            let unedited = watched.filter { $0.edited == false }.count
            out.weeks.append(Week(start: start, watched: watched.count,
                                  noEditRate: watched.isEmpty ? nil : Double(unedited) / Double(watched.count)))
        }
        return out
    }
}
