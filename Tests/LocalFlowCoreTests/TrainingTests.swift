import XCTest
@testable import LocalFlowCore

final class TrainingTests: XCTestCase {
    private var url: URL!
    private var store: Store!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("lf-train-\(UUID()).sqlite")
        store = try Store(url: url)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func sample(rules: String = "Lets meet on tuesday.", llm: String? = "Let's meet on Tuesday.",
                        accepted: Bool? = true, inserted: String = "Let's meet on Tuesday.",
                        engine: String = "apple") -> Store.Sample {
        Store.Sample(app: "com.apple.mail", style: "formal", level: "light", engine: engine, model: "test",
                     promptVersion: CleanupPrompt.promptVersion, raw: "lets meet on tuesday", rules: rules,
                     preceding: "Hi team,", dictionary: ["Kubernetes"], llmOutput: llm, accepted: accepted,
                     rejectReason: accepted == false ? "ratio" : nil, inserted: inserted, latencyMs: 420)
    }

    // MARK: Store

    func testAddSampleRoundTrips() {
        let id = store.addSample(sample())
        XCTAssertGreaterThan(id, 0)
        let s = store.recentSamples().first
        XCTAssertEqual(s?.id, id)
        XCTAssertEqual(s?.dictionary, ["Kubernetes"])
        XCTAssertEqual(s?.accepted, true)
        XCTAssertEqual(s?.latencyMs, 420)
        XCTAssertEqual(s?.preceding, "Hi team,")
        XCTAssertNil(s?.finalText)
        XCTAssertEqual(s?.edited, false)
    }

    func testRulesOnlySampleHasNullAccepted() {
        store.addSample(sample(llm: nil, accepted: nil, engine: "rules"))
        XCTAssertNil(store.recentSamples().first?.accepted)
    }

    func testUpdateSampleFinalSetsEdited() {
        let same = store.addSample(sample())
        let changed = store.addSample(sample())
        store.updateSampleFinal(id: same, finalText: "Let's meet on Tuesday.")
        store.updateSampleFinal(id: changed, finalText: "Let's meet on Wednesday.")
        let byID = Dictionary(uniqueKeysWithValues: store.recentSamples().map { ($0.id, $0) })
        XCTAssertEqual(byID[same]?.edited, false)
        XCTAssertEqual(byID[same]?.finalText, "Let's meet on Tuesday.")
        XCTAssertEqual(byID[changed]?.edited, true)
    }

    func testTrainingFilterByLabelAndConfirmation() {
        let accepted = store.addSample(sample())
        let rejected = store.addSample(sample(accepted: false))
        let rejectedButEdited = store.addSample(sample(accepted: false))
        store.updateSampleFinal(id: rejectedButEdited, finalText: "Fixed by hand.")
        let bad = store.addSample(sample())
        store.setSampleLabel(id: bad, label: "bad")
        let excludedEdit = store.addSample(sample())
        store.updateSampleFinal(id: excludedEdit, finalText: "Private.")
        store.setSampleLabel(id: excludedEdit, label: "exclude")
        let goodRejected = store.addSample(sample(accepted: false))
        store.setSampleLabel(id: goodRejected, label: "good")
        let rulesOnly = store.addSample(sample(llm: nil, accepted: nil, engine: "rules"))

        let ids = Set(store.trainingSamples().map(\.id))
        XCTAssertEqual(ids, [accepted, rejectedButEdited, goodRejected])
        XCTAssertFalse(ids.contains(rejected))
        XCTAssertFalse(ids.contains(rulesOnly))
        XCTAssertEqual(store.trainingSampleCount(), 3)

        store.setSampleLabel(id: bad, label: nil)
        XCTAssertEqual(store.trainingSampleCount(), 4)

        XCTAssertEqual(Set(store.rejectedSamples().map(\.id)), [rejected, rejectedButEdited, goodRejected])
    }

    func testPruneRemovesOnlyOldSamples() {
        var old = sample()
        old.created = Date().addingTimeInterval(-40 * 86_400)
        store.addSample(old)
        let fresh = store.addSample(sample())
        XCTAssertEqual(store.pruneSamples(olderThanDays: 30), 1)
        XCTAssertEqual(store.recentSamples().map(\.id), [fresh])
    }

    // MARK: Export

    func testMessagesMatchRuntimePrompt() throws {
        let s = sample()
        let messages = try XCTUnwrap(TrainingExport.messages(for: s))
        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant"])
        XCTAssertEqual(messages[0].content, CleanupPrompt.instructions(level: .light, style: .formal))
        let request = CleanupRequest(transcript: s.rules, style: .formal, level: .light,
                                     dictionary: ["Kubernetes"], precedingText: "Hi team,")
        XCTAssertEqual(messages[1].content, CleanupPrompt.prompt(for: request))
        XCTAssertEqual(messages[2].content, "Let's meet on Tuesday.")
    }

    func testTargetPrefersFinalTextAndNormalizesModelOutput() {
        var s = sample(llm: "<dictation>Let's meet on Tuesday.</dictation>")
        XCTAssertEqual(TrainingExport.target(for: s), "Let's meet on Tuesday.")
        s.finalText = "Let's meet Wednesday."
        XCTAssertEqual(TrainingExport.target(for: s), "Let's meet Wednesday.")
    }

    func testSnippetTokensKeptIntact() throws {
        let s = sample(rules: "Email it to ⟦1⟧ today.", llm: "Email it to ⟦1⟧ today.",
                       inserted: "Email it to a@b.com today.")
        let messages = try XCTUnwrap(TrainingExport.messages(for: s))
        XCTAssertTrue(messages[1].content.contains("⟦1⟧"))
        XCTAssertEqual(messages[2].content, "Email it to ⟦1⟧ today.")

        // Edited text holds the expansion, not the token: skip rather than mistrain.
        var edited = s
        edited.finalText = "Email it to a@b.com tonight."
        XCTAssertNil(TrainingExport.messages(for: edited))
    }

    func testChatLineIsValidJSONL() throws {
        let line = try XCTUnwrap(TrainingExport.chatLine(for: sample()))
        XCTAssertFalse(line.contains("\n"))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let messages = object?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 3)
        XCTAssertEqual(messages?.last?["role"], "assistant")
    }

    func testPreferenceLinePairsRejectedWithInserted() throws {
        let line = try XCTUnwrap(TrainingExport.preferenceLine(for: sample(llm: "Sure! Here you go.", accepted: false)))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(object?["rejected"] as? String, "Sure! Here you go.")
        XCTAssertEqual(object?["chosen"] as? String, "Let's meet on Tuesday.")
        XCTAssertNil(TrainingExport.preferenceLine(for: sample()))
    }

    func testSplitIsDeterministicAndNonEmpty() {
        let (train, valid) = TrainingExport.split(Array(0..<20), validFraction: 0.1)
        XCTAssertEqual(valid.count, 2)
        XCTAssertEqual(train.count, 18)
        XCTAssertEqual(TrainingExport.split(Array(0..<20), validFraction: 0.1).valid, valid)
        XCTAssertEqual(TrainingExport.split([1, 2], validFraction: 0.1).valid.count, 1)
        XCTAssertEqual(TrainingExport.split([1], validFraction: 0.1).valid.count, 0)
    }
}
