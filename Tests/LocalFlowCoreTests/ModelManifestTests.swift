import XCTest
@testable import LocalFlowCore

/// B3: pinned revision + SHA-256 + marker.
final class ModelManifestTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lf-model-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"a\":1}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 7, count: 100_000).write(to: dir.appendingPathComponent("model.safetensors"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func manifest(revision: String = "abc123") -> ModelManifest {
        let files = ["config.json", "model.safetensors"].map { name -> ModelManifest.File in
            let url = dir.appendingPathComponent(name)
            let size = (try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
            return .init(name: name, size: size, sha256: ModelManifest.sha256(of: url)!)
        }
        return ModelManifest(repo: "org/model", revision: revision, files: files)
    }

    func testKnownHash() throws {
        let url = dir.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(ModelManifest.sha256(of: url), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testVerifyPassesAndMarkerControlsInstalled() throws {
        let m = manifest()
        XCTAssertEqual(m.verify(directory: dir), [])
        XCTAssertFalse(m.isInstalled(at: dir), "no marker until the test generation succeeded")
        try m.writeMarker(at: dir)
        XCTAssertTrue(m.isInstalled(at: dir))
        XCTAssertFalse(manifest(revision: "def456").isInstalled(at: dir), "another revision is not installed")
    }

    func testVerifyCatchesSizeHashAndMissing() throws {
        let m = manifest()
        try Data(repeating: 8, count: 100_000).write(to: dir.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(m.verify(directory: dir), [.hash("model.safetensors")])
        try Data("x".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(m.verify(directory: dir).first, .size("config.json", expected: 7, actual: 1))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(m.verify(directory: dir).first, .missing("config.json"))
    }

    func testRemoveDeletesMarkerAndFiles() throws {
        let m = manifest()
        try m.writeMarker(at: dir)
        try ModelManifest.remove(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testPinnedManifestsLookSane() {
        for m in ModelManifest.pinned {
            XCTAssertEqual(m.revision.count, 40, m.repo)
            XCTAssertTrue(m.files.contains { $0.name == m.sentinelFile }, m.repo)
            if !m.repo.contains("diarization") { XCTAssertEqual(m.sentinelFile, "config.json", m.repo) }
            if m.repo.hasPrefix("mlx-community/") {
                XCTAssertTrue(m.files.contains { $0.name == "model.safetensors" }, m.repo)
            }
            XCTAssertTrue(m.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 }, m.repo)
            XCTAssertTrue(m.url(for: m.files[0]).absoluteString.contains("/resolve/\(m.revision)/"))
        }
        XCTAssertNotNil(ModelManifest.pinned(for: "mlx-community/Qwen3-4B-Instruct-2507-4bit"))
        XCTAssertTrue(ModelManifest.pinned(for: "FluidInference/parakeet-tdt-0.6b-v3-coreml")!.files
            .contains { $0.name == "Encoder.mlmodelc/weights/weight.bin" })
    }
}
