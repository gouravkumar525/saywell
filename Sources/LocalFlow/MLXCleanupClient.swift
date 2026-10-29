import Foundation
import HuggingFace
import LocalFlowCore
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Which model cleans up dictation. Local engines run in-process on the GPU via MLX.
enum CleanupEngine: String, CaseIterable {
    case apple, qwen3

    var label: String {
        switch self {
        case .apple: return "Apple Foundation Model"
        case .qwen3: return "Qwen3 4B (local)"
        }
    }

    var isLocal: Bool { self != .apple }

    /// Hugging Face repo, or an absolute path to a local (e.g. fine-tuned) model
    /// directory set via the `mlx.model.<engine>` setting.
    func modelSpec(store: Store?) -> String? {
        if let custom = store?.setting("mlx.model.\(rawValue)"), !custom.isEmpty { return custom }
        switch self {
        case .apple: return nil
        case .qwen3: return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        }
    }
}

/// Cleanup on an open-weight model running in-process via MLX. One model is
/// resident at a time; switching engines unloads the previous one. Every
/// failure completes with (nil, reason) so the caller falls back.
final class MLXCleanupClient {
    enum Status: Equatable {
        case notLoaded
        case loading(String)
        case ready
        case failed(String)
    }

    private(set) var engine: CleanupEngine?
    private(set) var modelSpec: String?
    private(set) var status: Status = .notLoaded
    private var container: ModelContainer?
    /// Bumped on every load/unload so a slow load can't install a stale model.
    private var loadGeneration = 0
    var onStatusChange: (() -> Void)?
    /// Last load or cleanup, for unloading when idle (G8).
    private(set) var lastUsed = Date()

    func isReady(_ engine: CleanupEngine) -> Bool {
        self.engine == engine && status == .ready && container != nil
    }

    var statusDescription: String {
        switch status {
        case .notLoaded: return "not loaded"
        case .loading(let what): return what
        case .ready: return "ready"
        case .failed(let error): return "failed: \(error)"
        }
    }

    var isLoaded: Bool { container != nil }

    var isLoading: Bool {
        if case .loading = status { return true }
        return false
    }

    /// Whether the model is on disk, so loading needs no network. A pinned
    /// model that is on disk but not yet verified counts; loading verifies it.
    static func isDownloaded(_ spec: String) -> Bool {
        if let manifest = ModelManifest.pinned(for: spec) { return PinnedModels.source(manifest) != nil }
        return localDirectory(for: spec) != nil
    }

    /// Loads `engine`'s model from disk and runs a tiny warm-up so the first
    /// dictation is fast. Downloading (the app's only network use) happens only
    /// with `allowDownload`, which the UI sets after asking the user.
    func load(_ engine: CleanupEngine, spec: String, allowDownload: Bool = true,
              completion: ((Bool) -> Void)? = nil) {
        if self.engine == engine, modelSpec == spec {
            switch status {
            case .ready: completion?(true); return
            case .loading: return
            default: break
            }
        }
        unload()
        self.engine = engine
        modelSpec = spec
        lastUsed = Date()
        if !allowDownload && !Self.isDownloaded(spec) {
            setStatus(.failed("not downloaded"))
            Log.write("mlx: \(spec) is not downloaded; not fetching without consent")
            completion?(false)
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        setStatus(.loading("loading…"))
        Memory.cacheLimit = 256 * 1024 * 1024
        let started = Date()

        Task {
            do {
                let factory: any ModelFactory = LLMModelFactory.shared
                let container: ModelContainer
                // B3: pinned models are verified (and downloaded if needed) into
                // our models folder; the marker is written after a test generation.
                var unmarked: (ModelManifest, URL)?
                if let manifest = ModelManifest.pinned(for: spec) {
                    let (directory, needsMarker) = try await PinnedModels.prepare(manifest, allowDownload: allowDownload) { status in
                        DispatchQueue.main.async {
                            guard self.loadGeneration == generation else { return }
                            self.setStatus(.loading(status))
                        }
                    }
                    if needsMarker { unmarked = (manifest, directory) }
                    do {
                        container = try await factory.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
                    } catch {
                        if needsMarker { try? ModelManifest.remove(directory: directory) }
                        throw error
                    }
                } else if let directory = Self.localDirectory(for: spec) {
                    container = try await factory.loadContainer(
                        from: directory, using: #huggingFaceTokenizerLoader())
                } else {
                    Log.write("network: downloading \(spec) from huggingface.co (user approved)")
                    container = try await factory.loadContainer(
                        from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                        configuration: ModelConfiguration(id: spec)
                    ) { progress in
                        let percent = Int(progress.fractionCompleted * 100)
                        DispatchQueue.main.async {
                            guard self.loadGeneration == generation else { return }
                            self.setStatus(.loading("downloading \(percent)%"))
                        }
                    }
                }
                let warmup = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 2, temperature: 0))
                if let (manifest, directory) = unmarked {
                    // The test generation must succeed before the model counts as installed.
                    do {
                        _ = try await warmup.respond(to: "Hi")
                        try manifest.writeMarker(at: directory)
                        Log.write("mlx: installed \(manifest.repo)@\(manifest.revision.prefix(8)) (verified, marker written)")
                    } catch {
                        try? ModelManifest.remove(directory: directory)
                        throw error
                    }
                } else {
                    _ = try? await warmup.respond(to: "Hi")
                }
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.container = container
                    self.setStatus(.ready)
                    Log.write("mlx: loaded \(spec) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    completion?(true)
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.setStatus(.failed(error.localizedDescription))
                    Log.write("mlx: load failed for \(spec): \(error)")
                    completion?(false)
                }
            }
        }
    }

    /// Frees the model's memory.
    func unload() {
        guard engine != nil else { return }
        loadGeneration += 1
        container = nil
        engine = nil
        modelSpec = nil
        Memory.clearCache()
        setStatus(.notLoaded)
    }

    func clean(_ request: CleanupRequest, timeout: TimeInterval,
               onPartial: @escaping (String) -> Void,
               completion: @escaping (String?, String) -> Void) {
        guard request.level != .off else { completion(nil, "off"); return }
        guard let container, status == .ready else { completion(nil, "local model \(statusDescription)"); return }

        lastUsed = Date()
        let instructions = CleanupPrompt.instructions(for: request)
        let prompt = CleanupPrompt.userPrompt(for: request)
        // Output can't legitimately be much longer than the input (accept() caps it).
        // Commands rewrite the selection, so budget for that instead.
        let basis = request.selectedText ?? request.transcript
        let maxTokens = max(48, CleanupPrompt.wordCount(basis) * (request.isCommand ? 4 : 3) + 24)

        var finished = false
        let finish: (String?, String) -> Void = { text, reason in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(text, reason)
            }
        }
        let task = Task {
            do {
                // Fresh session per request: no transcript carries over.
                let session = ChatSession(container, instructions: instructions,
                                          generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
                var output = ""
                for try await chunk in session.streamResponse(to: prompt) {
                    try Task.checkCancellation()
                    output += chunk
                    let partial = output
                    DispatchQueue.main.async { if !finished { onPartial(partial) } }
                }
                self.lastUsed = Date()
                finish(output, "ok")
            } catch is CancellationError {
                finish(nil, "cancelled")
            } catch {
                finish(nil, "error: \(error.localizedDescription)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !finished else { return }
            task.cancel()
            finish(nil, "timeout")
        }
    }

    /// Free-form generation (C5 call summaries). nil when the model isn't ready.
    func generate(instructions: String, prompt: String, maxTokens: Int) async -> String? {
        guard let container, status == .ready else { return nil }
        lastUsed = Date()
        let session = ChatSession(container, instructions: instructions,
                                  generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
        var output = ""
        do {
            for try await chunk in session.streamResponse(to: prompt) { output += chunk }
        } catch {
            Log.write("mlx: generate failed: \(error.localizedDescription)")
            return nil
        }
        lastUsed = Date()
        return output
    }

    private func setStatus(_ status: Status) {
        self.status = status
        onStatusChange?()
    }

    /// Remove Model: marker first, then unload, then the files (B3). The shared
    /// Hugging Face cache is left alone.
    func removeModel(spec: String) {
        guard let m = ModelManifest.pinned(for: spec) else { return }
        let dir = PinnedModels.directory.appendingPathComponent(m.folderName)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(ModelManifest.markerName))
        if modelSpec == spec { unload() }
        try? ModelManifest.remove(directory: dir)
        Log.write("mlx: removed \(m.repo) from the models folder")
    }

    static var hubCache: URL {
        let env = ProcessInfo.processInfo.environment
        return env["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? env["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    /// Fine-tuned and packaged models live here.
    static var modelsDirectory: URL { PinnedModels.directory }

    /// An absolute path; a copy installed under Application Support/Saywell/models
    /// (offline installs from the package); or the snapshot of a repo already in
    /// the Hugging Face cache (shared with the Python mlx-lm tools in ~/lf-mlx).
    static func localDirectory(for spec: String) -> URL? {
        let fm = FileManager.default
        if spec.hasPrefix("/") || spec.hasPrefix("~") {
            let url = URL(fileURLWithPath: (spec as NSString).expandingTildeInPath)
            return fm.fileExists(atPath: url.appendingPathComponent("config.json").path) ? url : nil
        }
        let installed = modelsDirectory.appendingPathComponent(spec.replacingOccurrences(of: "/", with: "--"))
        if fm.fileExists(atPath: installed.appendingPathComponent("config.json").path) { return installed }
        let repo = hubCache.appendingPathComponent("models--" + spec.replacingOccurrences(of: "/", with: "--"))
        let snapshots = repo.appendingPathComponent("snapshots")
        var candidates: [URL] = []
        if let ref = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8) {
            candidates.append(snapshots.appendingPathComponent(ref.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        candidates += (try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
    }
}
