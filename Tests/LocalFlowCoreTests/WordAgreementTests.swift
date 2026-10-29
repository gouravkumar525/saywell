import XCTest
@testable import LocalFlowCore

/// B2: live words for batch recognizers.
final class WordAgreementTests: XCTestCase {
    func w(_ s: String, step: Double = 0.4) -> [WordAgreement.Word] {
        s.split(separator: " ").enumerated().map { WordAgreement.Word(String($1), end: Double($0 + 1) * step) }
    }

    func testConfirmsOnlyWhatTwoPassesAgreeOn() {
        var a = WordAgreement(passes: 2)
        XCTAssertEqual(a.update(w("so we")), [])
        XCTAssertEqual(a.provisional, ["so", "we"])
        XCTAssertEqual(a.update(w("so we should met")), ["so", "we"])
        XCTAssertEqual(a.provisional, ["should", "met"])
        XCTAssertEqual(a.update(w("so we should meet on")), ["should"])
        XCTAssertEqual(a.text, "so we should meet on")
        XCTAssertEqual(a.update(w("So we should meet on Tuesday.")), ["meet", "on"], "case and punctuation don't block agreement")
        XCTAssertEqual(a.confirmedText, "so we should meet on")
    }

    func testConfirmedWordsNeverChange() {
        var a = WordAgreement(passes: 2)
        a.update(w("call the dentist"))
        a.update(w("call the dentist"))
        a.update(w("fall the dentist tomorrow"))
        XCTAssertEqual(a.confirmed, ["call", "the", "dentist"])
        XCTAssertEqual(a.provisional, ["tomorrow"])
    }

    func testCutAtSentenceEndRebasesTheWindow() {
        var a = WordAgreement(passes: 2)
        let first = w("Hello there. How are")
        a.update(first)
        a.update(first)
        XCTAssertNil(a.cut(minimum: 5), "too early to cut")
        let at = a.cut(minimum: 0.5)
        XCTAssertEqual(at ?? 0, 0.8, accuracy: 0.001, "after \"there.\"")
        XCTAssertEqual(a.committedBeforeWindow, ["Hello", "there."])
        // Next window starts at the cut: "How are" are still confirmed inside it.
        a.update(w("How are you doing"))
        XCTAssertEqual(a.update(w("How are you doing today")), ["you", "doing"])
        XCTAssertEqual(a.confirmedText, "Hello there. How are you doing")
        XCTAssertEqual(a.finalText(window: "How are you doing today?"), "Hello there. How are you doing today?")
    }

    func testHoldBackKeepsTheAudioEdgeProvisional() {
        var a = WordAgreement(passes: 2)
        let h = w("it has three.")   // ends at 0.4, 0.8, 1.2
        a.update(h, windowDuration: 1.5)
        XCTAssertEqual(a.update(h, windowDuration: 1.5), ["it"], "words in the last second wait for more audio")
        XCTAssertEqual(a.provisional, ["has", "three."])
    }

    func testCutInTheGapAndDropTheRepeatedBoundaryWord() {
        var a = WordAgreement(passes: 2)
        let h = [WordAgreement.Word("Done.", start: 0.1, end: 0.5), WordAgreement.Word("Next", start: 0.9, end: 1.2)]
        a.update(h); a.update(h)
        XCTAssertEqual(a.cut(minimum: 0) ?? 0, 0.7, accuracy: 0.001, "halfway between the words")
        // The next window starts with "Next"; a straddling "Done" is dropped.
        var b = WordAgreement(passes: 2)
        let first = [WordAgreement.Word("Sarah", end: 0.3), WordAgreement.Word("is.", start: 0.35, end: 0.5)]
        b.update(first); b.update(first)
        _ = b.cut(minimum: 0)
        let next = [WordAgreement.Word("is", end: 0.1), WordAgreement.Word("going", end: 0.5), WordAgreement.Word("home", end: 0.9)]
        b.update(next); b.update(next)
        XCTAssertEqual(b.confirmedText, "Sarah is. going home")
    }

    func testForcedCutWithoutSentenceEnd() {
        var a = WordAgreement(passes: 2)
        a.update(w("a long run on"))
        a.update(w("a long run on"))
        XCTAssertNil(a.cut(minimum: 0))
        XCTAssertEqual(a.cut(minimum: 0, force: true) ?? 0, 1.6, accuracy: 0.001)
        XCTAssertEqual(a.committedBeforeWindow.count, 4)
    }

    func testWordsFromSentencePieceTokens() {
        let tokens: [(token: String, start: Double, end: Double)] = [
            ("▁Ku", 0.1, 0.2), ("ber", 0.2, 0.3), ("netes", 0.3, 0.5), ("▁is", 0.6, 0.7), ("▁up", 0.8, 0.9), (".", 0.9, 1.0),
            ("▁", 1.1, 1.1), ("10", 1.1, 1.3),
        ]
        let words = WordAgreement.words(fromTokens: tokens)
        XCTAssertEqual(words.map(\.text), ["Kubernetes", "is", "up.", "10"], "a bare ▁ starts the next word")
        XCTAssertEqual(words[0].start, 0.1)
        XCTAssertEqual(words[2].end, 1.0)
    }
}

extension WordAgreementTests {
    func testRemainderMatchesWordsNotPunctuation() {
        XCTAssertEqual(SentenceSplitter.remainder(of: "So the project. We moved it, today.", afterWordsOf: "so the project we"),
                       "moved it, today.")
        XCTAssertEqual(SentenceSplitter.remainder(of: "Hello there.", afterWordsOf: "Hello there"), "")
        XCTAssertNil(SentenceSplitter.remainder(of: "Sarah is here", afterWordsOf: "Versera is"))
        XCTAssertNil(SentenceSplitter.remainder(of: "short", afterWordsOf: "short text"))
    }
}
