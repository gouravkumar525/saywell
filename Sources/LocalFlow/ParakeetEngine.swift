import AVFoundation
import FluidAudio
import LocalFlowCore

/// What SessionController dictates with: Apple's SFSpeech (`DictationEngine`)
/// or Parakeet (`ParakeetEngine`). Callbacks arrive on the main thread.
protocol SpeechEngine: AnyObject {
    var contextualStrings: [String] { get set }
    var secondsSinceVoice: TimeInterval { get }
    var onPartial: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    /// Text that won't change any more, for streaming cleanup (nil: use partials).
    var onStable: ((String) -> Void)? { get set }
    func start() throws
    func stop()
    func cancel()
}

/// Which recognizer turns speech into text (setting `asr.engine`).
enum SpeechBackend: String, CaseIterable {
    case apple, parakeet

    var label: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .parakeet: return "Parakeet v3 (on-device, more accurate)"
        }
    }
}

/// The shared Parakeet TDT v3 model (Core ML on the Neural Engine, ~460 MB on
/// disk), loaded once. Installed with the same pinned, verified flow as the
/// cleanup models (B3).
final class ParakeetService {
    static let shared = ParakeetService()
    static let repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let sampleRate = 16_000
    static var manifest: ModelManifest { ModelManifest.pinned(for: repo)! }

    enum Status: Equatable { case notLoaded, loading(String), ready, failed(String) }

    private(set) var status: Status = .notLoaded
    private var manager: AsrManager?
    var onStatusChange: (() -> Void)?

    var isReady: Bool { status == .ready && manager != nil }
    var isLoading: Bool { if case .loading = status { return true }; return false }

    static var isDownloaded: Bool { PinnedModels.source(manifest) != nil }

    var statusDescription: String {
        switch status {
        case .notLoaded: return Self.isDownloaded ? "not loaded" : "download ~460 MB"
        case .loading(let what): return what
        case .ready: return "ready"
        case .failed(let why): return "failed: \(why)"
        }
    }

    /// Verifies (or downloads, with consent) and loads the model, then runs a
    /// test transcription before writing the install marker.
    func load(allowDownload: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !isReady else { completion?(true); return }
        guard !isLoading else { return }
        if !allowDownload && !Self.isDownloaded {
            setStatus(.failed("not downloaded"))
            completion?(false)
            return
        }
        setStatus(.loading("loading…"))
        let started = Date()
        Task {
            do {
                let (dir, needsMarker) = try await PinnedModels.prepare(Self.manifest, allowDownload: allowDownload) { s in
                    DispatchQueue.main.async { self.setStatus(.loading(s)) }
                }
                let models = try AsrModels.loadLocal(from: dir, version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                _ = try await manager.transcribe([Float](repeating: 0, count: Self.sampleRate), decoderState: &state)
                if needsMarker { try Self.manifest.writeMarker(at: dir) }
                await MainActor.run {
                    self.manager = manager
                    self.setStatus(.ready)
                    Log.write("parakeet: loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    completion?(true)
                }
            } catch {
                await MainActor.run {
                    self.setStatus(.failed(error.localizedDescription))
                    Log.write("parakeet: load failed: \(error)")
                    completion?(false)
                }
            }
        }
    }

    func unload() {
        manager = nil
        setStatus(.notLoaded)
    }

    /// 16 kHz mono samples; short clips are padded to the model's 1 s minimum.
    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        guard let manager else { throw DictationEngine.EngineError.recognizerUnavailable }
        var audio = samples
        if audio.count < Self.sampleRate { audio += [Float](repeating: 0, count: Self.sampleRate - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state)
    }

    /// Whole-file transcription for the ASR bench.
    func transcribe(file url: URL) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DictationEngine.EngineError.recognizerUnavailable
        }
        try file.read(into: buffer)
        let resampler = Resampler()
        return try await transcribe(resampler.convert(buffer)).text
    }

    private func setStatus(_ s: Status) {
        status = s
        onStatusChange?()
    }
}

/// Converts mic buffers to 16 kHz mono Float32.
final class Resampler {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ParakeetService.sampleRate),
                                       channels: 1, interleaved: false)!

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}

/// Dictation with Parakeet (B1) and live words by agreement (B2): every 0.5 s
/// the audio window is re-transcribed; words two passes agree on are
/// confirmed. The window is cut at confirmed sentence ends so passes stay
/// short. At key-up one last pass over the window gives the final text.
final class ParakeetEngine: SpeechEngine {
    var contextualStrings: [String] = []   // Parakeet takes no hints; G6 post-correction covers vocabulary
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStable: ((String) -> Void)?

    private let mic: MicCapture?
    private let service: ParakeetService
    private let resampler = Resampler()
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Index into `samples` where the current window starts.
    private var windowStart = 0
    private var agreement = WordAgreement(passes: 2)
    private var timer: Timer?
    private var passRunning = false
    private var stopping = false
    private var finished = false
    private var lastVoiceAt = Date()
    private var startedAt = Date()
    private var passes = 0
    private var passMs = 0

    var secondsSinceVoice: TimeInterval { Date().timeIntervalSince(lastVoiceAt) }

    /// `mic` nil = simulated input through `feed` (`--simulate --asr parakeet`).
    init(mic: MicCapture?, service: ParakeetService = .shared) {
        self.mic = mic
        self.service = service
    }

    func start() throws {
        guard service.isReady else { throw DictationEngine.EngineError.recognizerUnavailable }
        startedAt = Date()
        lastVoiceAt = Date()
        if let mic {
            let preroll = try mic.begin { [weak self] buffer in self?.receive(buffer) }
            preroll.forEach(receive)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func feed(_ buffer: AVAudioPCMBuffer) { receive(buffer) }

    func stop() {
        guard !stopping, !finished else { return }
        stopping = true
        mic?.end()
        timer?.invalidate()
        timer = nil
        if !passRunning { finalPass() }
    }

    func cancel() {
        finished = true
        mic?.end()
        timer?.invalidate()
        timer = nil
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        reportLevel(buffer)
        let converted = resampler.convert(buffer)
        lock.lock()
        samples += converted
        lock.unlock()
    }

    private func window() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return windowStart < samples.count ? Array(samples[windowStart...]) : []
    }

    private func tick() {
        guard !passRunning, !stopping, !finished else { return }
        let audio = window()
        guard audio.count >= ParakeetService.sampleRate / 2 else { return }
        passRunning = true
        let started = Date()
        Task {
            let result = try? await service.transcribe(audio)
            await MainActor.run {
                self.passRunning = false
                self.passes += 1
                self.passMs += Int(Date().timeIntervalSince(started) * 1000)
                if let result, !self.finished { self.handle(result, windowSeconds: Double(audio.count) / Double(ParakeetService.sampleRate)) }
                if self.stopping { self.finalPass() }
            }
        }
    }

    private func handle(_ result: ASRResult, windowSeconds: Double) {
        let words: [WordAgreement.Word]
        if let timings = result.tokenTimings, !timings.isEmpty {
            words = WordAgreement.words(fromTokens: timings.map { ($0.token, $0.startTime, $0.endTime) })
        } else {
            words = result.text.split(separator: " ").map { WordAgreement.Word(String($0)) }
        }
        let before = agreement.confirmed.count
        agreement.update(words, windowDuration: windowSeconds)
        // Keep passes short: cut at a confirmed sentence end once the window passes
        // 12 s, or after any confirmed word past 24 s.
        if windowSeconds > 12, let cut = agreement.cut(minimum: 2, force: windowSeconds > 24) {
            lock.lock()
            windowStart = min(samples.count, windowStart + Int(cut * Double(ParakeetService.sampleRate)))
            lock.unlock()
        }
        onPartial?(agreement.text)
        if agreement.confirmed.count != before { onStable?(agreement.confirmedText) }
    }

    /// Up to this much audio, the final pass covers the whole recording (~0.2 s
    /// per minute on the Neural Engine) for the best text; longer dictations
    /// keep the confirmed words and re-run only the current window.
    static let fullFinalPassSeconds = 120.0

    private func finalPass() {
        guard !finished else { return }
        finished = true
        lock.lock()
        let full = Double(samples.count) / Double(ParakeetService.sampleRate) <= Self.fullFinalPassSeconds
        let audio = full ? samples : (windowStart < samples.count ? Array(samples[windowStart...]) : [])
        lock.unlock()
        let keyUp = Date()
        Task {
            let text = audio.count >= ParakeetService.sampleRate / 4 ? ((try? await service.transcribe(audio))?.text ?? "") : ""
            await MainActor.run {
                let final = text.isEmpty ? self.agreement.text : (full ? text : self.agreement.finalText(window: text))
                Log.write("parakeet: \(self.passes) live passes (avg \(self.passMs / max(self.passes, 1))ms), final pass \(Int(Date().timeIntervalSince(keyUp) * 1000))ms, \(self.agreement.confirmed.count) words confirmed live")
                self.onFinal?(final)
            }
        }
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(frames))
        let level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 50) / 50))
        if level > 0.4 { lastVoiceAt = Date() }
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}

extension DictationEngine: SpeechEngine {
    var onStable: ((String) -> Void)? {
        get { nil }
        set {}
    }
}
