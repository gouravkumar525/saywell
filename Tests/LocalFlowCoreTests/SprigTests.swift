import XCTest
@testable import LocalFlowCore

/// C3: Sprig's pose, tweens, states and actions, driven by a fake clock.
final class SprigTests: XCTestCase {
    func engine(_ state: String = "idle") -> SprigEngine {
        let e = SprigEngine(state: state, random: { 0.5 })
        e.update(now: 100)
        return e
    }

    func run(_ e: SprigEngine, from: Double = 100, seconds: Double, step: Double = 1.0 / 60) {
        var t = from
        while t < from + seconds { t += step; e.update(now: t) }
    }

    func testEasingEndpoints() {
        for f in [SprigEase.out, SprigEase.inOut, SprigEase.back, SprigEase.easeIn, SprigEase.lin] {
            XCTAssertEqual(f(0), 0, accuracy: 1e-9)
            XCTAssertEqual(f(1), 1, accuracy: 1e-9)
        }
        XCTAssertGreaterThan(SprigEase.back(0.8), 1, "back overshoots")
    }

    func testTweenRunsKeyframesThenFinishes() {
        let e = engine()
        var finished = false
        e.anim(.oy, [SprigKey(-1, 100, SprigEase.lin), SprigKey(0, 100, SprigEase.lin)]) { finished = true }
        e.update(now: 100.05)
        XCTAssertEqual(e.pose.oy, -0.5, accuracy: 0.01)
        e.update(now: 100.11)
        XCTAssertEqual(e.pose.oy, -1, accuracy: 0.01, "first keyframe reached; the second starts now")
        e.update(now: 100.16)
        XCTAssertEqual(e.pose.oy, -0.5, accuracy: 0.01)
        e.update(now: 100.3)
        XCTAssertEqual(e.pose.oy, 0, accuracy: 0.01)
        XCTAssertTrue(finished)
        XCTAssertFalse(e.isAnimating(.oy))
    }

    func testJumpLandsAndSquishes() {
        let e = engine()
        e.play("jump")
        run(e, seconds: 0.4)
        XCTAssertLessThan(e.pose.oy, -0.3, "in the air")
        run(e, from: 100.4, seconds: 1.2)
        XCTAssertEqual(e.pose.oy, 0, accuracy: 0.001)
        XCTAssertEqual(e.pose.sy, 1, accuracy: 0.001)
    }

    func testStateChangeSetsBadgeAndColor() {
        let e = engine()
        XCTAssertTrue(e.setState("approval"))
        XCTAssertFalse(e.setState("approval"), "same state is a no-op")
        run(e, seconds: 1.5)
        XCTAssertEqual(e.badge, .bang)
        XCTAssertEqual(e.pose.badgeS, 1, accuracy: 0.01)
        XCTAssertEqual(e.color.r, 0xF0, accuracy: 2)
        XCTAssertFalse(e.setState("nope"))
    }

    func testDoneBurstsSparksLater() {
        let e = engine()
        e.setState("done")
        XCTAssertTrue(e.particles.isEmpty)
        run(e, seconds: 0.5)
        XCTAssertEqual(e.particles.filter { $0.kind == .spark }.count, 7)
        XCTAssertEqual(e.eye, .happy)
    }

    func testThreePokesMakeDizzyThenReturn() {
        let e = engine("listening")
        e.poke(); e.update(now: 100.2)
        XCTAssertEqual(e.eye, .flat, "a poke annoys")
        e.poke(); e.update(now: 100.4)
        e.poke()
        XCTAssertEqual(e.state, "dizzy")
        run(e, from: 100.4, seconds: 3)
        XCTAssertEqual(e.state, "listening")
    }

    func testExplicitStateCancelsDizzyReturn() {
        let e = engine()
        e.poke(); e.poke(); e.poke()
        e.setState("thinking")
        run(e, seconds: 3)
        XCTAssertEqual(e.state, "thinking")
    }

    func testListeningEyesFollowTheVoice() {
        let e = engine()
        e.setState("listening")
        run(e, seconds: 0.6)
        e.targetLevel = 1
        run(e, from: 100.6, seconds: 0.5)
        XCTAssertGreaterThan(e.level, 0.9)
        XCTAssertEqual(e.pose.es, 1 + e.level * 0.18, accuracy: 0.01)
        XCTAssertTrue(e.particles.contains { $0.kind == .note }, "music notes fly in while talking")
        XCTAssertEqual(e.stateConfig.prop, .listening)
    }

    func testWritingLooksAtThePad() {
        let e = engine()
        e.setState("writing")
        run(e, seconds: 1)
        XCTAssertGreaterThan(e.pose.pitch, 0.3, "eyes down on the notepad")
        XCTAssertEqual(e.stateConfig.prop, .writing)
    }

    func testFallsAsleepWhenIdle() {
        let e = SprigEngine(sleepAfter: 2, random: { 0.5 })
        e.update(now: 0)
        run(e, from: 0, seconds: 2.5)
        XCTAssertEqual(e.state, "sleeping")
        run(e, from: 2.5, seconds: 1.2)
        XCTAssertTrue(e.particles.contains { $0.kind == .z })
    }

    func testEveryStateAndActionRuns() {
        let e = engine()
        var t = 100.0
        for s in e.stateNames {
            XCTAssertTrue(e.setState(s, force: true), s)
            for _ in 0..<30 { t += 1.0 / 60; e.update(now: t) }
        }
        for a in e.actionNames {
            XCTAssertTrue(e.play(a), a)
            for _ in 0..<30 { t += 1.0 / 60; e.update(now: t) }
        }
        XCTAssertEqual(Set(e.stateNames), ["idle", "thinking", "working", "approval", "question", "error", "done",
                                           "sleeping", "dizzy", "listening", "writing"])
    }
}
