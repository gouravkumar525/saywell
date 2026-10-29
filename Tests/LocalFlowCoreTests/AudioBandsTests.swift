import XCTest
@testable import LocalFlowCore

/// C4: voice dots.
final class AudioBandsTests: XCTestCase {
    func testEdgesAreLogSpaced() {
        let e = AudioBands.edges()
        XCTAssertEqual(e.count, 10)
        XCTAssertEqual(e.first!, 90, accuracy: 1e-9)
        XCTAssertEqual(e.last!, 7000, accuracy: 1e-6)
        let ratios = zip(e.dropFirst(), e).map { $0 / $1 }
        XCTAssertTrue(ratios.allSatisfy { abs($0 - ratios[0]) < 1e-9 }, "same ratio between every edge")
    }

    func testBinsCoverEachBandWithoutOverlap() {
        for rate in [16_000.0, 44_100, 48_000] {
            let r = AudioBands.binRanges(fftSize: 1024, sampleRate: rate)
            XCTAssertEqual(r.count, 9)
            XCTAssertTrue(r.allSatisfy { !$0.isEmpty }, "every band has a bin at \(rate)")
            XCTAssertTrue(zip(r.dropFirst(), r).allSatisfy { $0.lowerBound >= $1.upperBound }, "no overlap")
            XCTAssertLessThanOrEqual(r.last!.upperBound, 512)
            XCTAssertGreaterThanOrEqual(r.first!.lowerBound, 1, "DC is skipped")
        }
    }

    func testLevelMapsDecibels() {
        XCTAssertEqual(AudioBands.level(db: -100), 0)
        XCTAssertEqual(AudioBands.level(db: -20), 1)
        XCTAssertEqual(AudioBands.level(db: -54), 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(AudioBands.level(db: -60, index: 8), AudioBands.level(db: -60, index: 0), "treble lift")
    }

    func testSmoothingRisesFasterThanItFalls() {
        let up = AudioBands.smooth(0, toward: 1, dt: 0.05)
        let down = 1 - AudioBands.smooth(1, toward: 0, dt: 0.05)
        XCTAssertGreaterThan(up, down)
        XCTAssertEqual(AudioBands.smooth(0.4, toward: 0.4, dt: 1), 0.4)
    }
}
