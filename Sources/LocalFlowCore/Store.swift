import Foundation
import SQLite3

/// SQLite-backed persistence: settings, personal dictionary, learned
/// correction candidates, snippets, and dictation history.
public final class Store {

    public struct HistoryEntry: Identifiable {
        public let id: Int64
        public let created: Date
        public let app: String
        public let raw: String
        public let cleaned: String
        public let method: String
    }

    public struct Candidate: Identifiable {
        public var id: String { original + "→" + corrected }
        public let original: String
        public let corrected: String
        public let count: Int
    }

    /// One dictation captured for fine-tuning a cleanup model later. `rules` is
    /// the text sent to the model (snippets already swapped for ⟦n⟧ tokens).
    public struct Sample: Identifiable {
        public var id: Int64 = 0
        public var created = Date()
        public var app: String
        public var style: String
        public var level: String
        /// "apple", "mlx", or "rules" when no model ran.
        public var engine: String
        public var model: String?
        public var promptVersion: Int
        public var raw: String
        public var rules: String
        public var preceding: String?
        public var dictionary: [String]
        /// Raw model output, kept even when it was rejected.
        public var llmOutput: String?
        /// nil when no model ran.
        public var accepted: Bool?
        public var rejectReason: String?
        public var inserted: String
        public var finalText: String?
        public var edited = false
        public var latencyMs: Int?
        /// nil, "good", "bad", or "exclude".
        public var label: String?
        /// Name of the writing mode that applied (B9), nil for none.
        public var mode: String?
        /// How long the user spoke, for words-per-minute (B15).
        public var durationMs: Int?
        /// Speech recognizer: "sfspeech" or "parakeet" (B1).
        public var asr: String?

        public init(app: String, style: String, level: String, engine: String, model: String? = nil,
                    promptVersion: Int, raw: String, rules: String, preceding: String? = nil,
                    dictionary: [String] = [], llmOutput: String? = nil, accepted: Bool? = nil,
                    rejectReason: String? = nil, inserted: String, latencyMs: Int? = nil) {
            self.app = app
            self.style = style
            self.level = level
            self.engine = engine
            self.model = model
            self.promptVersion = promptVersion
            self.raw = raw
            self.rules = rules
            self.preceding = preceding
            self.dictionary = dictionary
            self.llmOutput = llmOutput
            self.accepted = accepted
            self.rejectReason = rejectReason
            self.inserted = inserted
            self.latencyMs = latencyMs
        }
    }

    public static let sampleLabels = ["good", "bad", "exclude"]

    /// Times the same correction must be seen before it joins the dictionary
    /// when it is made of ordinary words ("there" → "their" could be a one-off).
    public static let promotionThreshold = 2

    /// B5: a correction to a word that isn't ordinary English (a name, jargon,
    /// a product) is learned after one fix; ordinary words still need two.
    /// `isCommonWord` receives a lowercased word.
    public static func threshold(for corrected: String, isCommonWord: (String) -> Bool) -> Int {
        let words = corrected.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return promotionThreshold }
        return words.allSatisfy(isCommonWord) ? promotionThreshold : 1
    }

    /// ~/Library/Application Support/Saywell
    public static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saywell", isDirectory: true)
    }

    public static var defaultURL: URL {
        migrateFromLocalFlow()
        let dir = appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("saywell.sqlite")
    }

    /// The app was called LocalFlow before 2026-10-20. Moves its folder (database,
    /// models) to the Saywell name once; a rename, so even GB-sized models move instantly.
    public static func migrateFromLocalFlow() {
        let fm = FileManager.default
        let old = appSupportDirectory.deletingLastPathComponent().appendingPathComponent("LocalFlow", isDirectory: true)
        let new = appSupportDirectory
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        guard (try? fm.moveItem(at: old, to: new)) != nil else { return }
        for suffix in ["", "-wal", "-shm"] {
            let from = new.appendingPathComponent("localflow.sqlite" + suffix)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: new.appendingPathComponent("saywell.sqlite" + suffix))
            }
        }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "saywell.store")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = Store.defaultURL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw NSError(domain: "Store", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS dictionary (
            term TEXT PRIMARY KEY COLLATE NOCASE, source TEXT NOT NULL, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS candidates (
            original TEXT NOT NULL, corrected TEXT NOT NULL, count INTEGER NOT NULL, last REAL NOT NULL,
            PRIMARY KEY (original, corrected));
        CREATE TABLE IF NOT EXISTS snippets (trigger TEXT PRIMARY KEY COLLATE NOCASE, expansion TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT, created REAL NOT NULL, app TEXT NOT NULL,
            raw TEXT NOT NULL, cleaned TEXT NOT NULL, method TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT, created REAL NOT NULL, app TEXT, style TEXT, level TEXT,
            engine TEXT, model TEXT, prompt_version INTEGER, raw TEXT NOT NULL, rules TEXT NOT NULL,
            preceding TEXT, dictionary TEXT, llm_output TEXT, accepted INTEGER, reject_reason TEXT,
            inserted TEXT NOT NULL, final_text TEXT, edited INTEGER DEFAULT 0, latency_ms INTEGER, label TEXT);
        CREATE TABLE IF NOT EXISTS usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT, created REAL NOT NULL, app TEXT NOT NULL,
            raw_words INTEGER NOT NULL, words INTEGER NOT NULL, duration_ms INTEGER, asr TEXT, language TEXT);
        CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, created REAL NOT NULL, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS term_usage (
            term TEXT NOT NULL COLLATE NOCASE, app TEXT NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY (term, app));
        """
        try queue.sync {
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "Store", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        // Columns added after the first release.
        let dictionaryColumns = query("PRAGMA table_info(dictionary)", []) { text($0, 1) }
        if !dictionaryColumns.contains("phonetic") {
            execute("ALTER TABLE dictionary ADD COLUMN phonetic TEXT", [])
        }
        if !dictionaryColumns.contains("uses") {
            execute("ALTER TABLE dictionary ADD COLUMN uses INTEGER NOT NULL DEFAULT 0", [])
        }
        let existingSampleColumns = query("PRAGMA table_info(samples)", []) { text($0, 1) }
        if !existingSampleColumns.contains("mode") {
            execute("ALTER TABLE samples ADD COLUMN mode TEXT", [])
        }
        if !existingSampleColumns.contains("duration_ms") {
            execute("ALTER TABLE samples ADD COLUMN duration_ms INTEGER", [])
        }
        if !existingSampleColumns.contains("asr") {
            execute("ALTER TABLE samples ADD COLUMN asr TEXT", [])
        }
        // Paths saved before the rename (e.g. a personal model folder).
        execute("UPDATE settings SET value = REPLACE(value, '/Application Support/LocalFlow/', '/Application Support/Saywell/') WHERE value LIKE '%/Application Support/LocalFlow/%'", [])
        backfillUsage()
        for term in query("SELECT term FROM dictionary WHERE phonetic IS NULL", [], { text($0, 0) }) {
            execute("UPDATE dictionary SET phonetic = ? WHERE term = ?", [Phonetic.key(term), term])
        }
    }

    // MARK: Settings

    public func setting(_ key: String) -> String? {
        query("SELECT value FROM settings WHERE key = ?", [key]) { text($0, 0) }.first
    }

    public func setSetting(_ key: String, _ value: String?) {
        if let value {
            execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [key, value])
        } else {
            execute("DELETE FROM settings WHERE key = ?", [key])
        }
    }

    // MARK: Dictionary

    public func dictionaryTerms() -> [String] {
        query("SELECT term FROM dictionary ORDER BY term COLLATE NOCASE", []) { text($0, 0) }
    }

    public func addTerm(_ term: String, source: String = "manual") {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        execute("INSERT OR IGNORE INTO dictionary (term, source, created, phonetic) VALUES (?, ?, ?, ?)",
                [term, source, Date().timeIntervalSince1970, Phonetic.key(term)])
    }

    /// Terms for speech-recognition hints, most useful first: used most in
    /// `app`, then used most overall, then newest (recognition takes ≤ 100).
    public func rankedTerms(app: String?, limit: Int = 100) -> [String] {
        query("""
            SELECT d.term FROM dictionary d
            LEFT JOIN term_usage u ON u.term = d.term AND u.app = ?
            ORDER BY COALESCE(u.count, 0) DESC, d.uses DESC, d.created DESC
            LIMIT ?
            """, [app ?? "", limit]) { text($0, 0) }
    }

    /// Counts the dictionary terms that appear in inserted text.
    public func recordTermUsage(in inserted: String, app: String) {
        let words = Set(inserted.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        let lowered = inserted.lowercased()
        for term in dictionaryTerms() {
            let t = term.lowercased()
            let found = t.contains(" ") ? lowered.contains(t) : words.contains(t)
            guard found else { continue }
            execute("UPDATE dictionary SET uses = uses + 1 WHERE term = ?", [term])
            execute("""
                INSERT INTO term_usage (term, app, count) VALUES (?, ?, 1)
                ON CONFLICT(term, app) DO UPDATE SET count = count + 1
                """, [term, app])
        }
    }

    public func removeTerm(_ term: String) {
        execute("DELETE FROM dictionary WHERE term = ?", [term])
    }

    /// Records a user edit of our output. Returns true when it was promoted
    /// into the dictionary on this call.
    @discardableResult
    public func recordCorrection(original: String, corrected: String,
                                 isCommonWord: (String) -> Bool = { _ in true }) -> Bool {
        execute("""
            INSERT INTO candidates (original, corrected, count, last) VALUES (?, ?, 1, ?)
            ON CONFLICT(original, corrected) DO UPDATE SET count = count + 1, last = excluded.last
            """, [original, corrected, Date().timeIntervalSince1970])
        let count = query("SELECT count FROM candidates WHERE original = ? AND corrected = ?",
                          [original, corrected]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        guard count == Store.threshold(for: corrected, isCommonWord: isCommonWord) else { return false }
        acceptCandidate(original: original, corrected: corrected)
        return true
    }

    /// Forgets a learned correction so it is never promoted.
    public func rejectCandidate(original: String, corrected: String) {
        execute("DELETE FROM candidates WHERE original = ? AND corrected = ?", [original, corrected])
    }

    /// Accepts a pending correction now instead of waiting for the threshold.
    public func acceptCandidate(original: String, corrected: String) {
        addTerm(corrected, source: "learned")
        execute("DELETE FROM candidates WHERE original = ? AND corrected = ?", [original, corrected])
    }

    public func candidates() -> [Candidate] {
        query("SELECT original, corrected, count FROM candidates ORDER BY count DESC, last DESC LIMIT 100", []) {
            Candidate(original: text($0, 0), corrected: text($0, 1), count: Int(sqlite3_column_int64($0, 2)))
        }
    }

    // MARK: Snippets

    public func snippets() -> [String: String] {
        var result: [String: String] = [:]
        for (k, v) in query("SELECT trigger, expansion FROM snippets", [], { (text($0, 0), text($0, 1)) }) {
            result[k] = v
        }
        return result
    }

    public func setSnippet(trigger: String, expansion: String) {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        execute("INSERT INTO snippets (trigger, expansion) VALUES (?, ?) ON CONFLICT(trigger) DO UPDATE SET expansion = excluded.expansion",
                [trigger, expansion])
    }

    public func removeSnippet(trigger: String) {
        execute("DELETE FROM snippets WHERE trigger = ?", [trigger])
    }

    // MARK: History

    public func addHistory(app: String, raw: String, cleaned: String, method: String) {
        execute("INSERT INTO history (created, app, raw, cleaned, method) VALUES (?, ?, ?, ?, ?)",
                [Date().timeIntervalSince1970, app, raw, cleaned, method])
    }

    public func recentHistory(limit: Int = 50) -> [HistoryEntry] {
        query("SELECT id, created, app, raw, cleaned, method FROM history ORDER BY id DESC LIMIT ?", [limit]) {
            HistoryEntry(id: sqlite3_column_int64($0, 0),
                         created: Date(timeIntervalSince1970: sqlite3_column_double($0, 1)),
                         app: text($0, 2), raw: text($0, 3), cleaned: text($0, 4), method: text($0, 5))
        }
    }

    /// Deletes one dictation from history (the hub's trash button).
    public func deleteHistory(id: Int64) {
        execute("DELETE FROM history WHERE id = ?", [Int(id)])
    }

    /// Deletes every dictation record: history, training samples, usage counts.
    public func deleteAllHistory() {
        execute("DELETE FROM history", [])
        execute("DELETE FROM samples", [])
        execute("DELETE FROM usage", [])
        execute("VACUUM", [])
    }

    // MARK: Metrics

    public struct Metrics: Equatable {
        /// Samples whose final text is known (the EditWatcher saw the field).
        public let watched: Int
        /// Of those, how many the user left untouched.
        public let unedited: Int
        public var noEditRate: Double? { watched > 0 ? Double(unedited) / Double(watched) : nil }
    }

    // MARK: Notes (C5)

    private static let noteEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let noteDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func saveNote(_ note: Note) {
        guard let data = try? Self.noteEncoder.encode(note), let json = String(data: data, encoding: .utf8) else { return }
        execute("INSERT INTO notes (id, created, json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                [note.id.uuidString, note.start.timeIntervalSince1970, json])
    }

    /// Newest first.
    public func notes() -> [Note] {
        query("SELECT json FROM notes ORDER BY created DESC", []) { text($0, 0) }
            .compactMap { try? Self.noteDecoder.decode(Note.self, from: Data($0.utf8)) }
    }

    public func deleteNote(id: UUID) {
        execute("DELETE FROM notes WHERE id = ?", [id.uuidString])
    }

    // MARK: Usage (C2)

    /// One row per dictation that reached the user: word counts only, never text.
    public func recordUsage(app: String, rawWords: Int, words: Int, durationMs: Int?, asr: String, language: String,
                            at date: Date = Date()) {
        execute("INSERT INTO usage (created, app, raw_words, words, duration_ms, asr, language) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [date.timeIntervalSince1970, app, rawWords, words, durationMs.map { $0 as Any } ?? NSNull(), asr, language])
    }

    /// Rows for the Insights tab.
    public func usageRows() -> [UsageInsights.Row] {
        query("SELECT created, app, raw_words, words, duration_ms FROM usage ORDER BY id", []) {
            UsageInsights.Row(created: Date(timeIntervalSince1970: sqlite3_column_double($0, 0)), app: text($0, 1),
                              rawWords: Int(sqlite3_column_int64($0, 2)), words: Int(sqlite3_column_int64($0, 3)),
                              durationMs: sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64($0, 4)))
        }
    }

    /// Before `usage` existed, Insights read the training samples; copy them once.
    private func backfillUsage() {
        guard setting("usage.backfilled") == nil else { return }
        let hasRows = query("SELECT COUNT(*) FROM usage", []) { sqlite3_column_int64($0, 0) }.first ?? 0
        if hasRows == 0 {
            for r in insightRows() {
                recordUsage(app: r.app, rawWords: r.rawWords, words: r.words, durationMs: r.durationMs,
                            asr: "", language: "", at: r.created)
            }
        }
        setSetting("usage.backfilled", "1")
    }

    /// The north-star metric: share of dictations nobody had to fix.
    /// Rows for the Insights tab (B15); samples labeled "exclude" (tests) are left out.
    public func insightRows() -> [UsageInsights.Row] {
        query("""
            SELECT created, app, raw, inserted, duration_ms, final_text IS NOT NULL, edited FROM samples
            WHERE label IS NULL OR label != 'exclude' ORDER BY id
            """, []) {
            UsageInsights.Row(created: Date(timeIntervalSince1970: sqlite3_column_double($0, 0)),
                              app: text($0, 1), raw: text($0, 2), inserted: text($0, 3),
                              durationMs: sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64($0, 4)),
                              edited: sqlite3_column_int64($0, 5) != 0 ? sqlite3_column_int64($0, 6) != 0 : nil)
        }
    }

    public func metrics(days: Int = 30, engine: String? = nil, asr: String? = nil) -> Metrics {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        var sql = "SELECT COUNT(*), COALESCE(SUM(edited = 0), 0) FROM samples WHERE final_text IS NOT NULL AND created >= ?"
        var binds: [Any] = [cutoff]
        if let engine { sql += " AND engine = ?"; binds.append(engine) }
        if let asr { sql += " AND COALESCE(asr, 'sfspeech') = ?"; binds.append(asr) }
        return query(sql, binds) {
            Metrics(watched: Int(sqlite3_column_int64($0, 0)), unedited: Int(sqlite3_column_int64($0, 1)))
        }.first ?? Metrics(watched: 0, unedited: 0)
    }

    /// Exportable samples with an id above `id` (new since the last fine-tune).
    public func trainingSampleCount(after id: Int64) -> Int {
        query("SELECT COUNT(*) FROM samples WHERE id > ? AND \(Store.trainingFilter)", [Int(id)]) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    public func latestSampleID() -> Int64 {
        query("SELECT COALESCE(MAX(id), 0) FROM samples", []) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    // MARK: Training samples

    private static let sampleColumns = """
        id, created, app, style, level, engine, model, prompt_version, raw, rules, preceding, dictionary,
        llm_output, accepted, reject_reason, inserted, final_text, edited, latency_ms, label, mode, duration_ms, asr
        """

    /// Exported for fine-tuning: not excluded or marked bad, and confirmed
    /// somehow (edited by the user, accepted from the model, or labelled good).
    /// Samples cleaned under a writing mode are left out: their custom
    /// instructions aren't stored, so the pair would teach the base prompt the wrong thing.
    private static let trainingFilter = """
        (label IS NULL OR label NOT IN ('exclude', 'bad')) AND mode IS NULL
        AND (edited = 1 OR accepted = 1 OR label = 'good')
        AND COALESCE(final_text, llm_output) IS NOT NULL
        """

    @discardableResult
    public func addSample(_ s: Sample) -> Int64 {
        let dictionary = (try? JSONSerialization.data(withJSONObject: s.dictionary))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let binds: [Any?] = [s.created.timeIntervalSince1970, s.app, s.style, s.level, s.engine, s.model,
                             s.promptVersion, s.raw, s.rules, s.preceding, dictionary, s.llmOutput,
                             s.accepted.map { $0 ? 1 : 0 }, s.rejectReason, s.inserted, s.latencyMs,
                             s.mode, s.durationMs, s.asr]
        return queue.sync {
            let sql = """
                INSERT INTO samples (created, app, style, level, engine, model, prompt_version, raw, rules,
                    preceding, dictionary, llm_output, accepted, reject_reason, inserted, latency_ms, mode, duration_ms, asr)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            guard let stmt = prepare(sql, binds.map { $0 ?? NSNull() }) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Records what the field contained once the user was done with it.
    public func updateSampleFinal(id: Int64, finalText: String) {
        execute("UPDATE samples SET final_text = ?, edited = (? != inserted) WHERE id = ?",
                [finalText, finalText, Int(id)])
    }

    /// `label` is nil (clear), "good", "bad", or "exclude".
    public func setSampleLabel(id: Int64, label: String?) {
        execute("UPDATE samples SET label = ? WHERE id = ?", [label ?? NSNull(), Int(id)])
    }

    public func recentSamples(limit: Int = 100) -> [Sample] {
        query("SELECT \(Store.sampleColumns) FROM samples ORDER BY id DESC LIMIT ?", [limit], Store.sample)
    }

    public func trainingSamples() -> [Sample] {
        query("SELECT \(Store.sampleColumns) FROM samples WHERE \(Store.trainingFilter) ORDER BY id", [], Store.sample)
    }

    public func trainingSampleCount() -> Int {
        query("SELECT COUNT(*) FROM samples WHERE \(Store.trainingFilter)", []) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    /// Model outputs that were rejected, for preference training later.
    public func rejectedSamples() -> [Sample] {
        query("""
            SELECT \(Store.sampleColumns) FROM samples
            WHERE accepted = 0 AND llm_output IS NOT NULL AND (label IS NULL OR label != 'exclude')
            ORDER BY id
            """, [], Store.sample)
    }

    /// Deletes samples older than `days`. Returns how many were removed.
    @discardableResult
    public func pruneSamples(olderThanDays days: Int) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        return queue.sync {
            guard let stmt = prepare("DELETE FROM samples WHERE created < ?", [cutoff]) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            _ = sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    private static func sample(_ stmt: OpaquePointer) -> Sample {
        func optText(_ c: Int32) -> String? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : text(stmt, c) }
        func optInt(_ c: Int32) -> Int? {
            sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, c))
        }
        let dictionary = optText(11).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        var s = Sample(app: text(stmt, 2), style: text(stmt, 3), level: text(stmt, 4), engine: text(stmt, 5),
                       model: optText(6), promptVersion: optInt(7) ?? 0, raw: text(stmt, 8), rules: text(stmt, 9),
                       preceding: optText(10), dictionary: dictionary, llmOutput: optText(12),
                       accepted: optInt(13).map { $0 != 0 }, rejectReason: optText(14), inserted: text(stmt, 15),
                       latencyMs: optInt(18))
        s.id = sqlite3_column_int64(stmt, 0)
        s.created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        s.finalText = optText(16)
        s.edited = sqlite3_column_int64(stmt, 17) != 0
        s.label = optText(19)
        s.mode = optText(20)
        s.durationMs = optInt(21)
        s.asr = optText(22)
        return s
    }

    // MARK: SQLite plumbing

    private func execute(_ sql: String, _ binds: [Any]) {
        queue.sync {
            guard let stmt = prepare(sql, binds) else { return }
            defer { sqlite3_finalize(stmt) }
            _ = sqlite3_step(stmt)
        }
    }

    private func query<T>(_ sql: String, _ binds: [Any], _ row: (OpaquePointer) -> T) -> [T] {
        queue.sync {
            guard let stmt = prepare(sql, binds) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(row(stmt)) }
            return rows
        }
    }

    private func prepare(_ sql: String, _ binds: [Any]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        for (i, value) in binds.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Store.transient)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }
}

private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
    guard let c = sqlite3_column_text(stmt, column) else { return "" }
    return String(cString: c)
}
