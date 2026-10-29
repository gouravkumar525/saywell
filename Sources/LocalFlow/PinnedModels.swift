import Foundation
import LocalFlowCore

/// Pinned, verified model installs (B3), shared by the MLX cleanup models and
/// Parakeet. A model loads from our models folder only after its files match
/// the manifest; the caller writes the marker after a successful test run.
enum PinnedModels {

    /// ~/Library/Application Support/Saywell/models
    static var directory: URL {
        Store.migrateFromLocalFlow()
        return Store.appSupportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    enum InstallError: LocalizedError {
        case notDownloaded, verification(String), download(String)
        var errorDescription: String? {
            switch self {
            case .notDownloaded: return "not downloaded"
            case .verification(let why): return "verification failed: \(why)"
            case .download(let why): return "download failed: \(why)"
            }
        }
    }

    /// Where a pinned model can be loaded from without the network: our models
    /// folder (installed, or copied there by the package installer) or the
    /// Hugging Face cache at exactly the pinned revision.
    static func source(_ m: ModelManifest) -> URL? {
        let fm = FileManager.default
        let installed = directory.appendingPathComponent(m.folderName)
        if fm.fileExists(atPath: installed.appendingPathComponent(m.sentinelFile).path) { return installed }
        let snapshot = MLXCleanupClient.hubCache.appendingPathComponent("models--\(m.folderName)/snapshots/\(m.revision)")
        if fm.fileExists(atPath: snapshot.appendingPathComponent(m.sentinelFile).path) { return snapshot }
        return nil
    }

    /// Returns a verified folder in our models directory, and whether it still
    /// needs its marker (written after the test generation).
    static func prepare(_ m: ModelManifest, allowDownload: Bool,
                        status: @escaping (String) -> Void) async throws -> (URL, Bool) {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(m.folderName)
        if m.isInstalled(at: target) { return (target, false) }

        if let source = source(m) {
            status("verifying…")
            let started = Date()
            let errors = m.verify(directory: source) { fraction in status("verifying \(Int(fraction * 100))%") }
            if errors.isEmpty {
                Log.write("models: verified \(m.repo) in \(source.path.hasPrefix(directory.path) ? "models folder" : "HF cache") (\(Int(Date().timeIntervalSince(started)))s)")
                if source == target { return (target, true) }
                // Copy out of the shared cache (APFS clones, so no extra space).
                let partial = target.appendingPathExtension("partial")
                try? fm.removeItem(at: partial)
                try fm.createDirectory(at: partial, withIntermediateDirectories: true)
                for f in m.files {
                    try fm.createDirectory(at: partial.appendingPathComponent(f.name).deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.copyItem(at: source.appendingPathComponent(f.name).resolvingSymlinksInPath(),
                                    to: partial.appendingPathComponent(f.name))
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: partial, to: target)
                return (target, true)
            }
            Log.write("models: \(m.repo) failed verification: \(errors.map(\.description).joined(separator: "; "))")
            if source == target { try? ModelManifest.remove(directory: target) }
            guard allowDownload else { throw InstallError.verification(errors.first?.description ?? "") }
        }
        guard allowDownload else { throw InstallError.notDownloaded }
        return (try await download(m, to: target, status: status), true)
    }

    /// Downloads every pinned file into `<target>.partial`, verifies sizes and
    /// hashes, then moves it into place. Deletes the download on any failure.
    private static func download(_ m: ModelManifest, to target: URL, status: @escaping (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let partial = target.appendingPathExtension("partial")
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        Log.write("network: downloading \(m.repo)@\(m.revision.prefix(8)) from huggingface.co (user approved)")
        var done: Int64 = 0
        do {
            for f in m.files {
                let dest = partial.appendingPathComponent(f.name)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Resume across launches: keep files that already have the right size.
                if let size = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber, size.int64Value == f.size {
                    done += f.size
                    continue
                }
                let base = done
                let tracker = DownloadProgress { written in
                    status("downloading \(Int(Double(base + written) / Double(m.totalBytes) * 100))%")
                }
                let (tmp, response) = try await URLSession.shared.download(from: m.url(for: f), delegate: tracker)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw InstallError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(f.name)")
                }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
                done += f.size
            }
            status("verifying…")
            let errors = m.verify(directory: partial) { status("verifying \(Int($0 * 100))%") }
            guard errors.isEmpty else { throw InstallError.verification(errors.map(\.description).joined(separator: "; ")) }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: partial, to: target)
            return target
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }
}

/// Per-file download progress for `URLSession.download(from:delegate:)`.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    private let onBytes: (Int64) -> Void
    private var lastReport = Date.distantPast

    init(_ onBytes: @escaping (Int64) -> Void) { self.onBytes = onBytes }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard Date().timeIntervalSince(lastReport) > 0.5 else { return }
        lastReport = Date()
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
