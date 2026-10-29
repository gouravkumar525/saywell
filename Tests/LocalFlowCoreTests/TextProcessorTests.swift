import XCTest
@testable import LocalFlowCore

final class TextProcessorTests: XCTestCase {
    let p = TextProcessor()

    // MARK: Fillers

    func testRemovesFillerWords() {
        XCTAssertEqual(p.process("um, hello there, uh, how are you"),
                       "Hello there, how are you.")
    }

    func testRemovesRepeatedFillers() {
        XCTAssertEqual(p.process("Umm so uhh let's start"), "So let's start.")
    }

    func testKeepsRealWordsContainingFillerLetters() {
        // "umbrella", "error" must survive.
        XCTAssertEqual(p.process("the umbrella caused an error"),
                       "The umbrella caused an error.")
    }

    // MARK: Corrections

    func testChangeThatToSimpleSwap() {
        XCTAssertEqual(p.process("Let's meet on Monday, no, change that to Tuesday"),
                       "Let's meet on Tuesday.")
    }

    func testChangeThatToLongerReplacement() {
        XCTAssertEqual(p.process("Send it Monday, change that to Tuesday at noon"),
                       "Send it Tuesday at noon.")
    }

    func testChangeWithSharedSuffix() {
        XCTAssertEqual(p.process("The meeting is at 4 pm, no, change that to 5 pm"),
                       "The meeting is at 5 PM.")
    }

    func testScratchThatDropsLastClause() {
        XCTAssertEqual(p.process("Hello world, scratch that, good morning team"),
                       "Good morning team.")
    }

    func testIMeant() {
        XCTAssertEqual(p.process("Ping the design team, I meant the platform team"),
                       "Ping the platform team.")
    }

    // MARK: Layout

    func testNewLineAndParagraph() {
        XCTAssertEqual(p.process("Hi Sam new paragraph thanks for the update new line talk soon"),
                       "Hi Sam\n\nThanks for the update\nTalk soon.")
    }

    func testNumberedList() {
        XCTAssertEqual(p.process("Things to do number one buy milk number two call mom number three ship the app"),
                       "Things to do\n1. Buy milk\n2. Call mom\n3. Ship the app")
    }

    func testBulletList() {
        XCTAssertEqual(p.process("bullet point apples bullet point oranges"),
                       "- Apples\n- Oranges")
    }

    func testSingleNumberMentionIsNotAList() {
        XCTAssertEqual(p.process("call number one on the list"),
                       "Call number one on the list.")
    }

    // MARK: Punctuation & capitalization

    func testCapitalizesAndTerminates() {
        XCTAssertEqual(p.process("this is a test"), "This is a test.")
    }

    func testKeepsExistingPunctuation() {
        XCTAssertEqual(p.process("Is this working? yes it is!"), "Is this working? Yes it is!")
    }

    func testCollapsesSpacesAndStrayCommas() {
        XCTAssertEqual(p.process("hello ,  world , ,"), "Hello, world.")
    }

    func testEmptyInput() {
        XCTAssertEqual(p.process("   "), "")
    }
}
