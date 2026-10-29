import XCTest
@testable import LocalFlowCore

/// B5: names and jargon are learned after one fix; ordinary words need two.
final class LearningTests: XCTestCase {
    let common: Set<String> = ["there", "their", "meeting", "team"]
    func isCommon(_ w: String) -> Bool { common.contains(w) }

    func testThresholdByWordKind() {
        XCTAssertEqual(Store.threshold(for: "Kubernetes", isCommonWord: isCommon), 1)
        XCTAssertEqual(Store.threshold(for: "their", isCommonWord: isCommon), 2)
        XCTAssertEqual(Store.threshold(for: "Gourav's team", isCommonWord: isCommon), 1)
        XCTAssertEqual(Store.threshold(for: "", isCommonWord: isCommon), 2)
    }

    func testUncommonWordLearnedAfterOneFix() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lf-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        XCTAssertTrue(store.recordCorrection(original: "cooper netties", corrected: "Kubernetes", isCommonWord: isCommon))
        XCTAssertTrue(store.dictionaryTerms().contains("Kubernetes"))
        XCTAssertTrue(store.candidates().isEmpty, "a promoted correction leaves the pending list")
        XCTAssertFalse(store.recordCorrection(original: "there", corrected: "their", isCommonWord: isCommon))
        XCTAssertEqual(store.candidates().count, 1)
        XCTAssertTrue(store.recordCorrection(original: "there", corrected: "their", isCommonWord: isCommon))
    }
}

/// B11: on-screen spelling hints.
final class ScreenNamesTests: XCTestCase {
    func testExtractsNamesAndMixedCase() {
        let common: Set<String> = ["the", "meeting", "with", "about", "hello", "release"]
        let text = "Hello Gourav, the meeting with Priyanka about the GitHub release. Gourav: iPhone build. ALLCAPS ok"
        let names = ScreenNames.extract(text, isCommonWord: { common.contains($0) })
        XCTAssertEqual(names.first, "Gourav", "most frequent first")
        XCTAssertTrue(names.contains("Priyanka"))
        XCTAssertTrue(names.contains("GitHub"))
        XCTAssertTrue(names.contains("iPhone"))
        XCTAssertFalse(names.contains("Hello"), "a capitalized common word is not a name")
        XCTAssertFalse(names.contains("ALLCAPS"))
        XCTAssertFalse(names.contains("ok"))
    }

    func testLimit() {
        let text = (0..<60).map { "Name\(Character(UnicodeScalar(65 + $0 % 26)!))x\($0)" }.joined(separator: " ")
        XCTAssertLessThanOrEqual(ScreenNames.extract(text, isCommonWord: { _ in false }, limit: 10).count, 10)
    }
}
