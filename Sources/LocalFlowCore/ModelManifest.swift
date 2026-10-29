import CryptoKit
import Foundation

/// A model pinned to one revision with every file's size and SHA-256 (B3).
/// A model folder counts as installed only when its marker file matches the
/// manifest; the marker is written after verification and a test generation.
public struct ModelManifest: Equatable {
    public struct File: Equatable {
        public var name: String
        public var size: Int64
        public var sha256: String

        public init(name: String, size: Int64, sha256: String) {
            self.name = name
            self.size = size
            self.sha256 = sha256
        }
    }

    public var repo: String
    public var revision: String
    public var files: [File]

    public init(repo: String, revision: String, files: [File]) {
        self.repo = repo
        self.revision = revision
        self.files = files
    }

    public static let markerName = ".saywell-installed"

    public static func pinned(for repo: String) -> ModelManifest? {
        pinned.first { $0.repo == repo }
    }

    /// A file whose presence means a copy of the model is there (config.json
    /// for LLMs and Parakeet; the first file otherwise, e.g. the diarizer).
    public var sentinelFile: String {
        files.contains { $0.name == "config.json" } ? "config.json" : (files.first?.name ?? "config.json")
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Folder name under the models directory.
    public var folderName: String { repo.replacingOccurrences(of: "/", with: "--") }

    /// Where Hugging Face serves a file at the pinned revision.
    public func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.name)")!
    }

    /// Marker text: the revision plus every file's hash, so a different
    /// revision or a changed file never counts as installed.
    public var markerContents: String {
        ([repo, revision] + files.map { "\($0.name) \($0.size) \($0.sha256)" }).joined(separator: "\n") + "\n"
    }

    public func isInstalled(at directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(Self.markerName)
        return (try? String(contentsOf: marker, encoding: .utf8)) == markerContents
    }

    public func writeMarker(at directory: URL) throws {
        try markerContents.write(to: directory.appendingPathComponent(Self.markerName), atomically: true, encoding: .utf8)
    }

    public enum VerifyError: Error, CustomStringConvertible, Equatable {
        case missing(String)
        case size(String, expected: Int64, actual: Int64)
        case hash(String)

        public var description: String {
            switch self {
            case .missing(let f): return "\(f) is missing"
            case .size(let f, let e, let a): return "\(f) is \(a) bytes, expected \(e)"
            case .hash(let f): return "\(f) failed its SHA-256 check"
            }
        }
    }

    /// Checks sizes first (cheap), then hashes. Follows symlinks (Hugging Face cache).
    /// `progress` gets the fraction of bytes hashed.
    public func verify(directory: URL, progress: ((Double) -> Void)? = nil) -> [VerifyError] {
        var errors: [VerifyError] = []
        for f in files {
            let path = directory.appendingPathComponent(f.name).resolvingSymlinksInPath().path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { errors.append(.missing(f.name)); continue }
            if size != f.size { errors.append(.size(f.name, expected: f.size, actual: size)) }
        }
        guard errors.isEmpty else { return errors }
        var done: Int64 = 0
        for f in files {
            let url = directory.appendingPathComponent(f.name).resolvingSymlinksInPath()
            guard Self.sha256(of: url, progress: { bytes in progress?(Double(done + bytes) / Double(max(1, totalBytes))) }) == f.sha256
            else { errors.append(.hash(f.name)); continue }
            done += f.size
        }
        return errors
    }

    public static func sha256(of url: URL, progress: ((Int64) -> Void)? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        while true {
            let data: Data
            do { data = try handle.read(upToCount: 8 << 20) ?? Data() } catch { return nil }
            if data.isEmpty { break }
            hasher.update(data: data)
            read += Int64(data.count)
            progress?(read)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Removal order: marker first (so a half-deleted folder never counts as
    /// installed), then the files.
    public static func remove(directory: URL) throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(markerName))
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
