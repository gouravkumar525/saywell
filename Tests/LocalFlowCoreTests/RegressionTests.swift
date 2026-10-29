import XCTest
@testable import LocalFlowCore

/// B16: edge cases across the rules, the guard, and the helpers. Each one is a
/// behavior a user would notice if it broke.
final class RulesRegressionTests: XCTestCase {
    let p = TextProcessor()

    func testFillerAtEndOfSentence() { XCTAssertEqual(p.process("that sounds good uh"), "That sounds good.") }
    func testQuestionKeepsQuestionMark() { XCTAssertEqual(p.process("can you send it?"), "Can you send it?") }
    func testScratchThatAtStartLeavesRest() { XCTAssertEqual(p.process("scratch that, hello team"), "Hello team.") }
    func testNewLineInsideSentence() { XCTAssertEqual(p.process("hi team new line see below"), "Hi team\nSee below.") }
    func testBulletListThreeItems() {
        XCTAssertEqual(p.process("bullet milk bullet eggs bullet bread"), "- Milk\n- Eggs\n- Bread")
    }
    func testNumberedListWithDigits() {
        XCTAssertEqual(p.process("number 1 call mom number 2 pay rent"), "1. Call mom\n2. Pay rent")
    }
    func testOnlyWhitespace() { XCTAssertEqual(p.process("   \n "), "") }
    func testUmbrellaIsNotFiller() { XCTAssertEqual(p.process("um the umbrella"), "The umbrella.") }
    func testListNumbersStayAsMarkers() {
        // "number one" must stay a list marker, not become "number 1" text.
        XCTAssertTrue(p.process("number one wake up number two code").hasPrefix("1. Wake up"))
    }
}

final class FormattingRegressionTests: XCTestCase {
    func testLargeNumbers() {
        XCTAssertEqual(SpokenFormatting.apply("twelve thousand five hundred users"), "12500 users")
        XCTAssertEqual(SpokenFormatting.apply("two million rows"), "2000000 rows")
    }
    func testTenBecomesDigits() { XCTAssertEqual(SpokenFormatting.apply("ten minutes"), "10 minutes") }
    func testDigitsWithPercentSign() { XCTAssertEqual(SpokenFormatting.apply("up 15 percent"), "up 15%") }
    func testDollarDigitsAlreadyFormatted() { XCTAssertEqual(SpokenFormatting.apply("$40"), "$40") }
    func testCents() { XCTAssertEqual(SpokenFormatting.apply("99 cents"), "99¢") }
    func testTimeWithoutMinutes() { XCTAssertEqual(SpokenFormatting.apply("at eleven am"), "at 11 AM") }
    func testTimeTwelveFifteen() { XCTAssertEqual(SpokenFormatting.apply("twelve fifteen pm"), "12:15 PM") }
    func testInvalidMinutesLeftAlone() { XCTAssertEqual(SpokenFormatting.apply("at five seventy pm").contains("5:70"), false) }
    func testEmailWithUnderscore() {
        XCTAssertEqual(SpokenFormatting.apply("john underscore doe at example dot org"), "john_doe@example.org")
    }
    func testEmailIOTld() { XCTAssertEqual(SpokenFormatting.apply("hi at acme dot io"), "hi@acme.io") }
    func testAtWithoutDomainIsNotEmail() { XCTAssertEqual(SpokenFormatting.apply("look at the dot"), "look at the dot") }
    func testHandleWithAtSign() { XCTAssertEqual(SpokenFormatting.apply("tag at sign gourav"), "tag @gourav") }
    func testWordsLikeOftenAreUntouched() { XCTAssertEqual(SpokenFormatting.apply("often someone"), "often someone") }
    func testHundredAloneUntouched() { XCTAssertEqual(SpokenFormatting.apply("a hundred people"), "a hundred people") }
}

final class GuardRegressionTests: XCTestCase {
    func testLightAcceptsPunctuationOnlyFix() {
        XCTAssertNotNil(CleanupPrompt.vet(output: "Hello, team. Ready?", input: "hello team ready", level: .light).text)
    }
    func testLightRejectsDroppedName() {
        let v = CleanupPrompt.vet(output: "Send the report.", input: "send the report to Priya", level: .light)
        XCTAssertNil(v.text)
    }
    func testFullAllowsSmallRephrase() {
        let r = Faithfulness.check(input: "so basically we need to like fix the build", output: "We need to fix the build.")
        XCTAssertTrue(Faithfulness.passes(r, level: .full))
    }
    func testPluralsMatch() {
        XCTAssertTrue(Faithfulness.check(input: "the reports", output: "The report.").missing.isEmpty)
    }
    func testOrdinalsMatch() {
        XCTAssertTrue(Faithfulness.check(input: "on the fifth floor", output: "On the 5th floor.").missing.isEmpty)
    }
    func testThousandsSeparator() {
        XCTAssertEqual(Faithfulness.normalizedWords("1,200 users"), ["1200", "users"])
    }
    func testCommandAcceptStripsFences() {
        XCTAssertEqual(CleanupPrompt.acceptCommand(output: "```\nHello there.\n```"), "Hello there.")
    }
    func testIsCommandNeedsAVerbAndObject() {
        XCTAssertTrue(CleanupPrompt.isCommand("make this shorter"))
        XCTAssertFalse(CleanupPrompt.isCommand("I will make dinner tonight for everyone at home"))
    }
    func testWordCount() { XCTAssertEqual(CleanupPrompt.wordCount("  one two\nthree "), 3) }
}

final class HelperRegressionTests: XCTestCase {
    func testPhoneticEditDistance() {
        XCTAssertEqual(Phonetic.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(Phonetic.editDistance("", "abc"), 3)
    }
    func testCompactDropsCaseAndSpaces() { XCTAssertEqual(Phonetic.compact("Git Hub"), Phonetic.compact("github")) }
    func testSmartSpacingAddsSpaceAfterWord() {
        XCTAssertEqual(SmartSpacing.adjust("Hello.", preceding: "Done.", following: nil), " Hello.")
        XCTAssertEqual(SmartSpacing.adjust("Hello.", preceding: "Done", following: nil), " hello.", "mid-sentence continues lowercase")
    }
    func testSmartSpacingNoSpaceAtLineStart() {
        XCTAssertEqual(SmartSpacing.adjust("Hello.", preceding: "Done\n", following: nil), "Hello.")
    }
    func testSentenceSplitKeepsTail() {
        let s = SentenceSplitter.split("One. Two? three")
        XCTAssertEqual(s.sentences, ["One.", "Two?"])
        XCTAssertEqual(s.tail, "three")
    }
    func testChunksNeverEmpty() {
        XCTAssertTrue(SentenceSplitter.chunks(String(repeating: "word ", count: 300)).allSatisfy { !$0.isEmpty })
    }
    func testEditDiffNoChange() { XCTAssertTrue(EditDiff.corrections(inserted: "Same text.", edited: "Same text.").isEmpty) }
    func testChangedFractionIdentical() { XCTAssertEqual(EditDiff.changedFraction("a b c", "a b c"), 0) }
    func testCodeDictationDots() { XCTAssertEqual(CodeDictation.apply("open index dot js"), "open index.js") }
    func testWritingModeEmptyTriggerIgnored() {
        XCTAssertNil(ModeMatcher.triggerMatch([WritingMode(name: "x", trigger: "  ")], transcript: "hello"))
    }
    func testInsightsEmpty() {
        let i = UsageInsights.compute([])
        XCTAssertEqual(i.wordsAllTime, 0)
        XCTAssertNil(i.wordsPerMinute)
    }
}
