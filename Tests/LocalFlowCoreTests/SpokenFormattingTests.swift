import XCTest
@testable import LocalFlowCore

/// B10: deterministic numbers, times, money, email, handles, and repairs.
final class SpokenFormattingTests: XCTestCase {
    let p = TextProcessor()

    func testCompoundNumbersBecomeDigits() {
        XCTAssertEqual(SpokenFormatting.apply("we have twenty five tickets"), "we have 25 tickets")
        XCTAssertEqual(SpokenFormatting.apply("about two hundred and four people"), "about 204 people")
        XCTAssertEqual(SpokenFormatting.apply("twenty-five items"), "25 items")
    }

    func testSmallCountsStayWordsInProse() {
        XCTAssertEqual(SpokenFormatting.apply("one of them has two options"), "one of them has two options")
    }

    func testDecimalsPercentAndMoney() {
        XCTAssertEqual(SpokenFormatting.apply("version three point five"), "version 3.5")
        XCTAssertEqual(SpokenFormatting.apply("a ten percent discount"), "a 10% discount")
        XCTAssertEqual(SpokenFormatting.apply("five percent"), "5%")
        XCTAssertEqual(SpokenFormatting.apply("it costs five dollars"), "it costs $5")
        XCTAssertEqual(SpokenFormatting.apply("it costs 5 dollars and 50 cents"), "it costs $5.50")
        XCTAssertEqual(SpokenFormatting.apply("one hundred percent"), "100%")
    }

    func testTimes() {
        XCTAssertEqual(SpokenFormatting.apply("meet at three thirty pm"), "meet at 3:30 PM")
        XCTAssertEqual(SpokenFormatting.apply("call at five p.m. today"), "call at 5 PM today")
        XCTAssertEqual(SpokenFormatting.apply("at nine oh five am"), "at 9:05 AM")
        XCTAssertEqual(SpokenFormatting.apply("at 10 30 am"), "at 10:30 AM")
    }

    func testYears() {
        XCTAssertEqual(SpokenFormatting.apply("back in nineteen ninety"), "back in 1990")
        XCTAssertEqual(SpokenFormatting.apply("in twenty twenty five"), "in 2025")
    }

    func testAmbiguousRunsAreLeftAlone() {
        XCTAssertEqual(SpokenFormatting.apply("three thirty"), "three thirty")
    }

    func testEmails() {
        XCTAssertEqual(SpokenFormatting.apply("send it to gourav at gmail dot com please"),
                       "send it to gourav@gmail.com please")
        XCTAssertEqual(SpokenFormatting.apply("john dot smith at acme dot co dot in"), "john.smith@acme.co.in")
    }

    func testEmailNeedsAKnownDomainAndNotAPronoun() {
        XCTAssertEqual(SpokenFormatting.apply("meet at noon"), "meet at noon")
        XCTAssertEqual(SpokenFormatting.apply("email me at gourav dot com"), "email me at gourav dot com")
    }

    func testHandles() {
        XCTAssertEqual(SpokenFormatting.apply("ping at the rate KV about it"), "ping @KV about it")
    }

    func testRepairReusingRecentWord() {
        XCTAssertEqual(SpokenFormatting.repairs("I'm flying to Pune, sorry, no, to Delhi tomorrow"),
                       "I'm flying to Delhi tomorrow")
    }

    func testRepairWithoutAnchorIsLeftAlone() {
        XCTAssertEqual(SpokenFormatting.repairs("there is no wait time today"), "there is no wait time today")
        XCTAssertEqual(SpokenFormatting.repairs("sorry, no, I can't"), "sorry, no, I can't")
    }

    func testRulesRunInTextProcessor() {
        XCTAssertEqual(p.process("um the meeting is at three thirty pm and costs twenty dollars"),
                       "The meeting is at 3:30 PM and costs $20.")
        XCTAssertEqual(p.process("book it for Monday, no wait, for Tuesday"), "Book it for Tuesday.")
    }

    func testRulesAgreeWithFaithfulness() {
        let raw = "it was two hundred and four dollars at three thirty pm"
        let out = SpokenFormatting.apply(raw)
        XCTAssertTrue(Faithfulness.check(input: raw, output: out).missing.isEmpty, out)
    }
}

extension SpokenFormattingTests {
    func testNoCapitalAfterADotInsideAWord() {
        XCTAssertEqual(p.process("email gourav at gmail dot com. thanks"), "Email gourav@gmail.com. Thanks.")
        XCTAssertEqual(p.process("open index.js now"), "Open index.js now.")
    }
}

extension SpokenFormattingTests {
    func testRepairSwapsAValueOfTheSameKind() {
        XCTAssertEqual(p.process("the invoice is twenty five dollars, sorry, no, thirty dollars due at five pm"),
                       "The invoice is $30 due at 5 PM.")
        XCTAssertEqual(p.process("send it to Pune, sorry, no, Delhi by Friday"), "Send it to Delhi by Friday.")
        XCTAssertEqual(p.process("I like it, sorry, no, I love it"), "I love it.")
        XCTAssertEqual(p.process("we were sorry, no one came"), "We were sorry, no one came.")
    }
}

extension SpokenFormattingTests {
    func testEmailWhenTheRecognizerAlreadyWroteTheDomain() {
        XCTAssertEqual(SpokenFormatting.apply("email gurava at gmail.com about it"), "email gurava@gmail.com about it")
    }
}

extension SpokenFormattingTests {
    func testWrittenDomainAfterAVerbIsNotAnAddress() {
        XCTAssertEqual(SpokenFormatting.apply("look at google.com for it"), "look at google.com for it")
        XCTAssertEqual(SpokenFormatting.apply("email at acme dot com"), "email at acme dot com")
    }
}

extension SpokenFormattingTests {
    func testJoinsAddressesSplitByAModel() {
        XCTAssertEqual(SpokenFormatting.joinAddresses("email Grava@ gmail.com now"), "email Grava@gmail.com now")
        XCTAssertEqual(SpokenFormatting.joinAddresses("email grava @gmail.com"), "email grava@gmail.com")
        XCTAssertEqual(SpokenFormatting.joinAddresses("ping @KV today"), "ping @KV today")
    }
}
