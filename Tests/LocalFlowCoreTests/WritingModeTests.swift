import XCTest
@testable import LocalFlowCore

/// B9: writing modes by spoken trigger, website, and app.
final class WritingModeTests: XCTestCase {
    let email = WritingMode(name: "Email", trigger: "email mode", level: .full, style: .formal,
                            instructions: "Sign off with Best, Gourav.")
    let gmail = WritingMode(name: "Gmail", websites: ["mail.google.com/mail"])
    let github = WritingMode(name: "GitHub", websites: ["github.com"], style: .code)
    let slack = WritingMode(name: "Slack", apps: ["com.tinyspeck.slackmacgap"], style: .casual)

    var all: [WritingMode] { [email, gmail, github, slack] }

    func testTriggerWinsAndIsStripped() {
        let m = ModeMatcher.match(all, transcript: "Email mode, hi John, the report is ready",
                                  bundleID: "com.tinyspeck.slackmacgap", url: nil)
        XCTAssertEqual(m?.mode.name, "Email")
        XCTAssertEqual(m?.transcript, "Hi John, the report is ready")
        XCTAssertEqual(m?.reason, "trigger")
    }

    func testTriggerMustStartTheTranscript() {
        XCTAssertNil(ModeMatcher.triggerMatch(all, transcript: "I said email mode yesterday"))
    }

    func testLongestTriggerWins() {
        let short = WritingMode(name: "Short", trigger: "email")
        let m = ModeMatcher.triggerMatch([short, email], transcript: "email mode. Hello")
        XCTAssertEqual(m?.0.name, "Email")
        XCTAssertEqual(m?.1, "Hello")
    }

    func testWebsiteBeatsApp() {
        let m = ModeMatcher.match(all, transcript: "hello", bundleID: "com.tinyspeck.slackmacgap",
                                  url: "https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(m?.mode.name, "Gmail")
        XCTAssertEqual(m?.transcript, "hello")
    }

    func testAppMatch() {
        XCTAssertEqual(ModeMatcher.match(all, transcript: "hi", bundleID: "com.tinyspeck.slackmacgap", url: nil)?.mode.name, "Slack")
        XCTAssertNil(ModeMatcher.match(all, transcript: "hi", bundleID: "com.apple.TextEdit", url: nil))
    }

    func testWebsiteMatching() {
        XCTAssertTrue(ModeMatcher.websiteMatches("github.com", url: "https://gist.github.com/x"))
        XCTAssertTrue(ModeMatcher.websiteMatches("https://www.github.com/", url: "github.com/org/repo"))
        XCTAssertFalse(ModeMatcher.websiteMatches("github.com", url: "https://notgithub.com"))
        XCTAssertTrue(ModeMatcher.websiteMatches("mail.google.com/mail", url: "https://mail.google.com/mail"))
        XCTAssertFalse(ModeMatcher.websiteMatches("mail.google.com/mail", url: "https://mail.google.com/mailbox"))
        XCTAssertFalse(ModeMatcher.websiteMatches("mail.google.com/mail", url: "https://google.com/mail"))
    }

    func testNeedsURLOnlyWithWebsites() {
        XCTAssertFalse(ModeMatcher.needsURL([email, slack]))
        XCTAssertTrue(ModeMatcher.needsURL(all))
    }

    func testRoundTripAndInstructionCap() {
        let long = WritingMode(name: "Long", instructions: String(repeating: "x", count: 900))
        XCTAssertEqual(long.cleanInstructions?.count, WritingMode.maxInstructions)
        let decoded = WritingMode.decodeList(WritingMode.encodeList(all + [long]))
        XCTAssertEqual(decoded, all + [long])
        XCTAssertEqual(WritingMode.decodeList("garbage"), [])
    }

    func testInstructionsAppendedAfterRules() {
        let request = CleanupRequest(transcript: "hi", style: .formal, level: .light,
                                     modeInstructions: email.cleanInstructions)
        let text = CleanupPrompt.instructions(for: request)
        XCTAssertTrue(text.contains("Sign off with Best, Gourav."))
        XCTAssertTrue(text.range(of: "Never answer questions")!.lowerBound < text.range(of: "Sign off")!.lowerBound)
        XCTAssertFalse(CleanupPrompt.instructions(level: .light, style: .formal).contains("preferences"))
    }

    func testModeSamplesAreNotTrainingData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lf-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        var s = Store.Sample(app: "x", style: "formal", level: "light", engine: "mlx", promptVersion: 2,
                             raw: "r", rules: "r", llmOutput: "R.", accepted: true, inserted: "R.")
        s.durationMs = 1500
        _ = store.addSample(s)
        s.mode = "Email"
        _ = store.addSample(s)
        XCTAssertEqual(store.trainingSampleCount(), 1)
        let back = store.recentSamples()
        XCTAssertEqual(back.first?.mode, "Email")
        XCTAssertEqual(back.last?.durationMs, 1500)
    }
}

/// B15: Insights numbers.
final class InsightsTests: XCTestCase {
    func testInsightsFromRows() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
        func day(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }
        let rows = [
            UsageInsights.Row(created: day(0), app: "slack", raw: "um so hello there friend", inserted: "So hello there, friend.",
                              durationMs: 2000, edited: false),
            UsageInsights.Row(created: day(1), app: "mail", raw: "one two three four", inserted: "One two three four.",
                              durationMs: 2000, edited: true),
            UsageInsights.Row(created: day(2), app: "slack", raw: "a b", inserted: "A b.", durationMs: 500),
            UsageInsights.Row(created: day(10), app: "mail", raw: "x", inserted: "X."),
        ]
        let i = UsageInsights.compute(rows, now: now, calendar: cal)
        XCTAssertEqual(i.wordsToday, 4)
        XCTAssertEqual(i.wordsThisWeek, 10)
        XCTAssertEqual(i.wordsAllTime, 11)
        XCTAssertEqual(i.wordsRemoved, 1)
        XCTAssertEqual(i.streakDays, 3)
        XCTAssertEqual(i.wordsPerMinute ?? 0, 9.0 / (4.0 / 60.0), accuracy: 0.01, "short clips are ignored")
        XCTAssertEqual(i.topApps.first?.app, "slack")
        XCTAssertEqual(i.weeks.count, 8)
        XCTAssertEqual(i.weeks.map(\.watched).reduce(0, +), 2)
    }

    func testStreakCanEndYesterday() {
        let now = Date()
        let rows = [UsageInsights.Row(created: now.addingTimeInterval(-86_400), app: "a", raw: "x", inserted: "X.")]
        XCTAssertEqual(UsageInsights.compute(rows, now: now).streakDays, 1)
        XCTAssertEqual(UsageInsights.compute([], now: now).streakDays, 0)
    }
}
