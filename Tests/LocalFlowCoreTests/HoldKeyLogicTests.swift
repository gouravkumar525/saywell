import XCTest
@testable import LocalFlowCore

/// C1: hold key, double-tap hands-free, Esc.
final class HoldKeyLogicTests: XCTestCase {
    func testHoldThenReleaseFinishes() {
        var k = HoldKeyLogic()
        XCTAssertEqual(k.keyDown(at: 0), .start)
        XCTAssertEqual(k.keyDown(at: 0.1), .none, "key repeat is ignored")
        XCTAssertEqual(k.keyUp(at: 1.2), .finish)
        XCTAssertFalse(k.isActive)
    }

    func testSingleTapIsDroppedWhenNoSecondTap() {
        var k = HoldKeyLogic()
        XCTAssertEqual(k.keyDown(at: 0), .start)
        XCTAssertEqual(k.keyUp(at: 0.1), .none, "waits for a second tap")
        XCTAssertEqual(k.tick(at: 0.5), .none)
        XCTAssertEqual(k.tick(at: 0.7), .cancel)
        XCTAssertFalse(k.isActive)
    }

    func testDoubleTapLocksUntilNextPress() {
        var k = HoldKeyLogic()
        XCTAssertEqual(k.keyDown(at: 0), .start)
        XCTAssertEqual(k.keyUp(at: 0.1), .none)
        XCTAssertEqual(k.keyDown(at: 0.3), .lock)
        XCTAssertEqual(k.keyUp(at: 0.4), .none, "release after locking keeps listening")
        XCTAssertEqual(k.tick(at: 5), .none)
        XCTAssertEqual(k.keyDown(at: 9), .finish)
        XCTAssertEqual(k.keyUp(at: 9.1), .none)
        XCTAssertFalse(k.isActive)
    }

    func testLateSecondPressRestarts() {
        var k = HoldKeyLogic()
        _ = k.keyDown(at: 0)
        _ = k.keyUp(at: 0.1)
        XCTAssertEqual(k.keyDown(at: 0.9), .restart, "the wait ran out before the tick noticed")
        XCTAssertEqual(k.keyUp(at: 2), .finish)
    }

    func testRelaxedDoubleTapStillLocks() {
        var k = HoldKeyLogic()
        _ = k.keyDown(at: 0)
        XCTAssertEqual(k.keyUp(at: 0.38), .none, "a 380 ms press is still a tap")
        XCTAssertEqual(k.keyDown(at: 0.75), .lock)
    }

    func testLateFnReleaseStillDoubleTaps() {
        // Seen live: tap logged as 602 ms, second tap delivered as a 0 ms pair 21 ms later.
        var k = HoldKeyLogic()
        _ = k.keyDown(at: 0)
        XCTAssertEqual(k.keyUp(at: 0.602), .none)
        XCTAssertEqual(k.keyDown(at: 0.623), .lock)
        XCTAssertEqual(k.keyUp(at: 0.623), .none)
        XCTAssertEqual(k.phase, .locked)
    }

    func testShortHoldFinishesAfterGrace() {
        var k = HoldKeyLogic()
        _ = k.keyDown(at: 0)
        XCTAssertEqual(k.keyUp(at: 0.7), .none)
        XCTAssertTrue(k.isWaiting)
        XCTAssertEqual(k.tick(at: 0.9), .none)
        XCTAssertEqual(k.tick(at: 1.0), .finish, "not cancelled: a short hold keeps its words")
    }

    func testTypingAfterShortHoldFinishes() {
        var k = HoldKeyLogic()
        _ = k.keyDown(at: 0)
        _ = k.keyUp(at: 0.7)
        XCTAssertEqual(k.otherKey(), .finish)
    }

    func testOtherKeyCancelsShortcut() {
        var k = HoldKeyLogic()
        _ = k.keyDown(at: 0)
        XCTAssertEqual(k.otherKey(), .cancel)
        XCTAssertEqual(k.keyUp(at: 0.5), .none)
        XCTAssertFalse(k.isActive)
    }

    func testOtherKeyWhileLockedIsTyping() {
        var k = HoldKeyLogic()
        _ = k.keyDown(at: 0); _ = k.keyUp(at: 0.1); _ = k.keyDown(at: 0.2)
        XCTAssertEqual(k.otherKey(), .none)
        XCTAssertEqual(k.phase, .locked)
    }

    func testEscapeCancelsAnyActivePhase() {
        var k = HoldKeyLogic()
        XCTAssertEqual(k.escape(), .none)
        _ = k.keyDown(at: 0)
        XCTAssertEqual(k.escape(), .cancel)
        _ = k.keyDown(at: 1); _ = k.keyUp(at: 1.1); _ = k.keyDown(at: 1.2)
        XCTAssertEqual(k.escape(), .cancel)
        XCTAssertFalse(k.isActive)
    }

    func testRightModifierMasks() {
        XCTAssertEqual(HoldKey.rightOption.keyCode, 61)
        XCTAssertEqual(HoldKey.rightCommand.deviceMask, 0x10)
        XCTAssertNil(HoldKey.off.keyCode)
        XCTAssertEqual(HoldKey(rawValue: "rightControl"), .rightControl)
    }
}
