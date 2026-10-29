import Foundation
import LocalFlowCore

/// "Improve My Model…" (G7): runs improve_model.sh in the background (export →
/// LoRA → fuse → bench gate) and switches the Qwen3 engine to the personal
/// model only when it scores at least as well as the current one.
final class ModelTrainer {
    private let store: Store
    private var process: Process?
    private(set) var status = ""
    var onFinish: ((_ newModel: String?, _ message: String) -> Void)?

    init(store: Store) { self.store = store }

    var isRunning: Bool { process?.isRunning == true }

    /// New exportable samples needed before a fine-tune is worth it (setting `personal.minSamples`).
    var minimumNewSamples: Int { Int(store.setting("personal.minSamples") ?? "") ?? 200 }

    private var lastTrainedSampleID: Int64 { Int64(store.setting("personal.lastSampleID") ?? "") ?? 0 }

    var newSampleCount: Int { store.trainingSampleCount(after: lastTrainedSampleID) }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Saywell-train.log")
    }

    /// The bundled script, or the repo copy when running from a dev build.
    private static var scriptURL: URL? {
        let fm = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("improve_model.sh")
        if let bundled, fm.fileExists(atPath: bundled.path) { return bundled }
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/improve_model.sh")
        return fm.fileExists(atPath: repo.path) ? repo : nil
    }

    func start(baseModel: String) {
        guard !isRunning else { return }
        guard let script = Self.scriptURL, let app = Bundle.main.executableURL else {
            onFinish?(nil, "improve_model.sh is missing from the app bundle")
            return
        }
        let startID = store.latestSampleID()
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: Self.logURL) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "--app", app.path, "--base", baseModel,
                       "--out", MLXCleanupClient.modelsDirectory.path]
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] _ in
            try? log.close()
            let output = (try? String(contentsOf: Self.logURL, encoding: .utf8)) ?? ""
            let result = output.split(separator: "\n").last(where: { $0.hasPrefix("RESULT ") }).map(String.init) ?? "RESULT error no result"
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                let parts = result.split(separator: " ", maxSplits: 2).map(String.init)
                let kind = parts.count > 1 ? parts[1] : "error"
                let detail = parts.count > 2 ? parts[2] : ""
                Log.write("train: \(result)")
                if kind == "switch" {
                    self.store.setSetting("personal.lastSampleID", String(startID))
                    self.status = "Switched to your personal model"
                    self.onFinish?(detail, "Your personal model scored at least as well and is now in use.")
                } else if kind == "keep" {
                    self.store.setSetting("personal.lastSampleID", String(startID))
                    self.status = "Kept the current model"
                    self.onFinish?(nil, "Kept the current model: \(detail).")
                } else {
                    self.status = "Training failed"
                    self.onFinish?(nil, "Training failed: \(detail). Log: \(Self.logURL.path)")
                }
            }
        }
        do {
            try p.run()
            process = p
            status = "Training…"
            Log.write("train: started \(script.path) base=\(baseModel)")
        } catch {
            onFinish?(nil, "Couldn't start training: \(error.localizedDescription)")
        }
    }
}
