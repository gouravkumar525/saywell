import XCTest
@testable import LocalFlowCore

/// C2: language choice, English-only rules, usage counts and time saved.
final class LanguageAndUsageTests: XCTestCase {
    let supported = ["en_US", "en_GB", "fr_FR", "de_DE", "es_ES", "es_MX", "hi_IN"]

    func testFixedSettingWins() {
        XCTAssertEqual(SpeechLanguage.resolve(setting: "fr-FR", preferred: ["en-US"], supported: supported), "fr_FR")
    }

    func testAutomaticUsesPreferredLanguages() {
        XCTAssertEqual(SpeechLanguage.resolve(setting: "auto", preferred: ["de-DE", "en-US"], supported: supported), "de_DE")
        XCTAssertEqual(SpeechLanguage.resolve(setting: nil, preferred: ["en-GB"], supported: supported), "en_GB")
    }

    func testRegionFallsBackToSameLanguage() {
        XCTAssertEqual(SpeechLanguage.resolve(setting: "auto", preferred: ["fr-CA"], supported: supported), "fr_FR")
        XCTAssertEqual(SpeechLanguage.resolve(setting: "auto", preferred: ["es"], supported: supported), "es_ES")
    }

    func testUnsupportedFallsBackToEnglish() {
        XCTAssertEqual(SpeechLanguage.resolve(setting: "auto", preferred: ["xx-YY"], supported: supported), "en_US")
        XCTAssertEqual(SpeechLanguage.resolve(setting: "zz_ZZ", preferred: ["xx"], supported: supported), "en_US")
    }

    func testEnglishDetection() {
        XCTAssertTrue(SpeechLanguage.isEnglish("en_GB"))
        XCTAssertTrue(SpeechLanguage.isEnglish("en-US"))
        XCTAssertFalse(SpeechLanguage.isEnglish("es_ES"))
        XCTAssertEqual(SpeechLanguage.englishName("fr_FR"), "French")
    }

    func testNonEnglishSkipsEnglishRules() {
        let french = TextProcessor(englishRules: false)
        XCTAssertEqual(french.process("um on se voit à cinq heures sorry no six heures"),
                       "On se voit à cinq heures sorry no six heures.")
        XCTAssertEqual(TextProcessor().process("the invoice is twenty five dollars"), "The invoice is $25.")
    }

    func testPromptKeepsLanguage() {
        let fr = CleanupPrompt.instructions(level: .light, style: .neutral, language: "French")
        XCTAssertTrue(fr.contains("Keep it in French"))
        XCTAssertFalse(CleanupPrompt.instructions(level: .light, style: .neutral).contains("translate it"))
    }

    func testTimeSavedAndCounts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            // 90 words in 30 s: 2 min typing − 0.5 min talking = 1.5 min saved.
            UsageInsights.Row(created: now, app: "mail", rawWords: 95, words: 90, durationMs: 30_000),
            // No duration: 45 words typed (1 min) vs. 45/150 min talking = 0.7 min.
            UsageInsights.Row(created: now, app: "slack", rawWords: 45, words: 45),
        ]
        let i = UsageInsights.compute(rows, watched: [], now: now)
        XCTAssertEqual(i.wordsAllTime, 135)
        XCTAssertEqual(i.wordsRemoved, 5)
        XCTAssertEqual(i.minutesSaved, 2.2, accuracy: 0.001)
        XCTAssertEqual(i.wordsPerMinute ?? 0, 190, accuracy: 0.001)
        XCTAssertTrue(i.weeks.allSatisfy { $0.watched == 0 }, "no-edit rate comes from `watched` only")
    }

    func testUsageTableRoundTripAndBackfill() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var store: Store? = try Store(url: url)
        XCTAssertEqual(store?.usageRows().count, 0)
        store?.recordUsage(app: "com.apple.mail", rawWords: 12, words: 10, durationMs: 4000, asr: "parakeet", language: "en_US")
        XCTAssertEqual(store?.usageRows().first?.words, 10)
        XCTAssertEqual(store?.usageRows().first?.durationMs, 4000)
        store = nil
        // Reopening never backfills twice.
        let reopened = try Store(url: url)
        XCTAssertEqual(reopened.usageRows().count, 1)
        reopened.deleteAllHistory()
        XCTAssertEqual(reopened.usageRows().count, 0)
    }
}

final class LanguageChoiceTests: XCTestCase {
    func testParakeetAddsItsLanguages() {
        let apple = ["en-US"]
        XCTAssertEqual(SpeechLanguage.choices(appleOnDevice: apple, parakeet: false), ["en-US"])
        let both = SpeechLanguage.choices(appleOnDevice: apple, parakeet: true)
        XCTAssertTrue(both.contains("fr"))
        XCTAssertFalse(both.contains("en"), "English is already covered by en-US")
        XCTAssertEqual(SpeechLanguage.resolve(setting: "fr", preferred: [], supported: both), "fr")
    }

    func testAppleNeverGetsAnUninstalledLocale() {
        XCTAssertEqual(SpeechLanguage.appleLocale(for: "fr", onDevice: ["en-US"]), "en-US")
        XCTAssertEqual(SpeechLanguage.appleLocale(for: "fr", onDevice: ["en-US", "fr-FR"]), "fr-FR")
        XCTAssertEqual(SpeechLanguage.appleLocale(for: "en_GB", onDevice: ["en-US"]), "en-US")
    }
}
