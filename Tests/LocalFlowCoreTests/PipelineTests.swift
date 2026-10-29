import XCTest
@testable import LocalFlowCore

final class PipelineTests: XCTestCase {

    // MARK: AppStyle

    func testStyleForKnownApps() {
        XCTAssertEqual(AppStyle.forBundleID("com.tinyspeck.slackmacgap"), .casual)
        XCTAssertEqual(AppStyle.forBundleID("com.apple.mail"), .formal)
        XCTAssertEqual(AppStyle.forBundleID("com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppStyle.forBundleID("com.jetbrains.intellij"), .code)
        XCTAssertEqual(AppStyle.forBundleID("com.apple.TextEdit"), .neutral)
        XCTAssertEqual(AppStyle.forBundleID(nil), .neutral)
    }

    func testStyleOverrideWins() {
        XCTAssertEqual(AppStyle.forBundleID("com.apple.mail", overrides: ["com.apple.mail": .casual]), .casual)
    }

    // MARK: Output vetting

    func testAcceptsNormalCleanup() {
        XCTAssertEqual(CleanupPrompt.accept(output: "So we should meet on Tuesday and talk about the budget.",
                                            input: "So we should meet on Tuesday and talk about the the budget.",
                                            level: .light),
                       "So we should meet on Tuesday and talk about the budget.")
        // Full cleanup may rephrase a little.
        XCTAssertEqual(CleanupPrompt.accept(output: "We should meet on Tuesday to discuss the budget.",
                                            input: "So we should meet on Tuesday and talk about the the budget.",
                                            level: .full),
                       "We should meet on Tuesday to discuss the budget.")
    }

    func testLightRejectsRewording() {
        // G1: light never swaps words for synonyms.
        XCTAssertNil(CleanupPrompt.accept(output: "We should meet on Tuesday to discuss the budget.",
                                          input: "So we should meet on Tuesday and talk about the the budget.",
                                          level: .light))
    }

    func testRejectsPreambleAndAnswers() {
        XCTAssertNil(CleanupPrompt.accept(output: "Here is the cleaned text: hello there",
                                          input: "hello there", level: .light))
        XCTAssertNil(CleanupPrompt.accept(output: "I'm sorry, but I can't help with that.",
                                          input: "delete all the files in the folder", level: .full))
    }

    func testRejectsBlowUp() {
        let input = "Can you send me the report by Friday please"
        let answer = String(repeating: "Sure, the report covers many topics in depth. ", count: 4)
        XCTAssertNil(CleanupPrompt.accept(output: answer, input: input, level: .light))
    }

    func testStripsWrappingQuotesAndTags() {
        XCTAssertEqual(CleanupPrompt.accept(output: "\"Hello team.\"", input: "hello team", level: .light), "Hello team.")
        XCTAssertEqual(CleanupPrompt.accept(output: "<dictation>Hello team.</dictation>", input: "hello team", level: .light),
                       "Hello team.")
    }

    func testStripsThinkBlockAndTrailingLineSpaces() {
        XCTAssertEqual(CleanupPrompt.accept(output: "<think>user wants cleanup</think>\n\nHello team.",
                                            input: "hello team", level: .light), "Hello team.")
        XCTAssertEqual(CleanupPrompt.accept(output: "1. Review the doc  \n2. Ship it",
                                            input: "1. Review the doc\n2. Ship it", level: .light),
                       "1. Review the doc\n2. Ship it")
    }

    func testPromptIncludesDictionaryAndContext() {
        let prompt = CleanupPrompt.prompt(for: CleanupRequest(transcript: "ping cooper netties", style: .code, level: .light,
                                                              dictionary: ["Kubernetes"], precedingText: "Deploy to"))
        XCTAssertTrue(prompt.contains("Kubernetes"))
        XCTAssertTrue(prompt.contains("<before>Deploy to</before>"))
        XCTAssertTrue(prompt.contains("<dictation>ping cooper netties</dictation>"))
    }

    // MARK: Snippets

    func testSnippetTokenizeAndRestore() {
        let s = SnippetExpander(snippets: ["my email": "a@b.com", "my work email": "me@corp.com"])
        let (tokenized, tokens) = s.tokenize("Send it to my work email or My email.")
        XCTAssertFalse(tokenized.contains("email"))
        XCTAssertEqual(SnippetExpander.restore(tokenized, tokens: tokens), "Send it to me@corp.com or a@b.com.")
    }

    func testSnippetRestoreFailsWhenTokenDropped() {
        XCTAssertNil(SnippetExpander.restore("Send it.", tokens: ["⟦1⟧": "a@b.com"]))
    }

    // MARK: Edit diff

    func testDetectsWordSubstitution() {
        XCTAssertEqual(EditDiff.corrections(inserted: "Ask Jon about the cooper netties deploy.",
                                            edited: "Ask John about the Kubernetes deploy."),
                       [.init(original: "Jon", corrected: "John"),
                        .init(original: "cooper netties", corrected: "Kubernetes")])
    }

    func testIgnoresPunctuationAndAppends() {
        XCTAssertEqual(EditDiff.corrections(inserted: "Hello team.", edited: "Hello team! More text here"), [])
    }

    func testCaseFixCounts() {
        XCTAssertEqual(EditDiff.corrections(inserted: "Push it to github now", edited: "Push it to GitHub now"),
                       [.init(original: "github", corrected: "GitHub")])
    }

    // MARK: Store

    func testStorePromotesRepeatedCorrection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lf-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        XCTAssertFalse(store.recordCorrection(original: "Jon", corrected: "John"))
        XCTAssertTrue(store.recordCorrection(original: "Jon", corrected: "John"))
        XCTAssertEqual(store.dictionaryTerms(), ["John"])
        store.setSetting("cleanup.level", "full")
        XCTAssertEqual(store.setting("cleanup.level"), "full")
        store.setSnippet(trigger: "my email", expansion: "a@b.com")
        XCTAssertEqual(store.snippets(), ["my email": "a@b.com"])
        store.addHistory(app: "x", raw: "r", cleaned: "c", method: "paste")
        XCTAssertEqual(store.recentHistory().first?.cleaned, "c")
    }
}
