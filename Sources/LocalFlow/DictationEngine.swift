import Accelerate
import AVFoundation
import Foundation
import LocalFlowCore
import Speech

/// One long-lived AVAudioEngine shared by every dictation (G3). Prepared at
/// launch so Fn-down only has to start it. With `keepReady` the mic runs
/// all the time into a 0.5 s in-memory ring (pre-roll) that is never stored,
/// so the first word is captured even before the engine would have started.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var consumer: ((AVAudioPCMBuffer) -> Void)?
    private var ring: [AVAudioPCMBuffer] = []
    private var ringFrames: AVAudioFrameCount = 0
    private var tapInstalled = false
    private(set) var isRunning = false
    private var configObserver: NSObjectProtocol?
    /// C4: nine band levels (0...1, low → high) while a consumer is attached; called off the main thread.
    var onBands: (([Float]) -> Void)?
    private let spectrum = SpectrumAnalyzer()

    /// Pre-roll mode: the mic stays on (orange dot) while dictation is idle.
    var keepReady = false {
        didSet {
            guard keepReady != oldValue else { return }
            if keepReady { try? startEngine() } else if consumerIsNil { stopEngine() }
        }
    }

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // Input device changed (e.g. AirPods): the tap's format is stale.
            guard let self else { return }
            Log.write("mic: audio configuration changed; reinstalling tap")
            let wasRunning = self.isRunning
            self.stopEngine()
            if wasRunning { try? self.startEngine() }
        }
    }

    /// Allocates the input node and engine resources without turning the mic on.
    func prepare() {
        _ = engine.inputNode
        engine.prepare()
    }

    /// Starts delivering buffers to `consumer`; returns the pre-roll captured
    /// before this call (empty unless `keepReady`).
    func begin(_ consumer: @escaping (AVAudioPCMBuffer) -> Void) throws -> [AVAudioPCMBuffer] {
        lock.lock()
        let preroll = ring
        ring = []
        ringFrames = 0
        self.consumer = consumer
        lock.unlock()
        if !isRunning { try startEngine() }
        return preroll
    }

    func end() {
        lock.lock()
        consumer = nil
        lock.unlock()
        if !keepReady { stopEngine() }
    }

    private var consumerIsNil: Bool {
        lock.lock(); defer { lock.unlock() }
        return consumer == nil
    }

    private func startEngine() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Log.write("engine: input format \(format.sampleRate)Hz ch=\(format.channelCount)")
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.deliver(buffer)
            }
            tapInstalled = true
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
        isRunning = true
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        isRunning = false
        lock.lock()
        ring = []
        ringFrames = 0
        lock.unlock()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let consumer = self.consumer
        if consumer == nil, keepReady, let copy = buffer.copy() as? AVAudioPCMBuffer {
            ring.append(copy)
            ringFrames += copy.frameLength
            let limit = AVAudioFrameCount(buffer.format.sampleRate * 0.5)
            while ringFrames > limit, let first = ring.first {
                ringFrames -= first.frameLength
                ring.removeFirst()
            }
        }
        lock.unlock()
        consumer?(buffer)
        if consumer != nil, let onBands, let bands = spectrum.bands(buffer) { onBands(bands) }
    }
}

/// 1024-point FFT of the latest mic samples → AudioBands levels (vDSP).
final class SpectrumAnalyzer {
    private let fftSize = 1024
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]
    private var ranges: [Range<Int>] = []
    private var rangesRate = 0.0

    init() {
        fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
    }

    func bands(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let fft, let data = buffer.floatChannelData, Int(buffer.frameLength) >= fftSize else { return nil }
        let rate = buffer.format.sampleRate
        if rate != rangesRate {
            ranges = AudioBands.binRanges(fftSize: fftSize, sampleRate: rate)
            rangesRate = rate
        }
        let start = Int(buffer.frameLength) - fftSize
        var samples = [Float](UnsafeBufferPointer(start: data[0] + start, count: fftSize))
        vDSP.multiply(samples, window, result: &samples)
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                samples.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        let norm = 1 / Float(fftSize * fftSize)
        return ranges.enumerated().map { i, r in
            let sum = r.reduce(Float(0)) { $0 + power[min($1, half - 1)] } * norm
            return Float(AudioBands.level(db: 10 * log10(Double(max(sum, 1e-12))), index: i))
        }
    }
}

/// Streams microphone audio into SFSpeechRecognizer and reports partial
/// transcripts, audio levels, and the final transcript.
final class DictationEngine: NSObject {

    enum EngineError: LocalizedError {
        case recognizerUnavailable
        case speechDenied
        case micDenied

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognizer unavailable for \(SpeechLanguage.displayName(DictationEngine.localeIdentifier))."
            case .speechDenied: return "Speech recognition permission denied."
            case .micDenied: return "Microphone permission denied."
            }
        }
    }

    private let mic: MicCapture
    /// Audio that arrived before the recognition request existed.
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()
    private var startedAt = Date()
    private var sawFirstBuffer = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// C2: the language to listen for (menu ▸ Language); read when a dictation starts.
    static var localeIdentifier = SpeechLanguage.fallback
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: DictationEngine.localeIdentifier))

    private(set) var isRunning = false
    private var latestTranscript = ""
    private var committedTranscript = ""
    private var lastPartial = ""
    private var finalDelivered = false
    private var lastTaskStart = Date.distantPast
    private var rapidFailures = 0
    private var levelBufferCount = 0
    private var peakLevel: Float = 0
    private var lastVoiceAt = Date()

    /// Dictionary terms passed to the recognizer as vocabulary hints.
    var contextualStrings: [String] = []

    /// Seconds since the input level last crossed the voice threshold (a
    /// simple energy VAD, used for auto-stop in toggle mode).
    var secondsSinceVoice: TimeInterval { Date().timeIntervalSince(lastVoiceAt) }

    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(mic: MicCapture = MicCapture()) {
        self.mic = mic
        super.init()
    }

    /// B12: runs half a second of silence through the on-device recognizer at
    /// launch, so the first real dictation doesn't pay for loading the model.
    static func warmUp() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) else { return }
        buffer.frameLength = 8_000   // zeros = silence
        let request = SFSpeechAudioBufferRecognitionRequest()
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.append(buffer)
        request.endAudio()
        let started = Date()
        var task: SFSpeechRecognitionTask?
        task = recognizer.recognitionTask(with: request) { result, error in
            guard error != nil || result?.isFinal == true, task != nil else { return }
            _ = recognizer   // keep the recognizer alive until the task ends
            Log.write("engine: warm-up \(Int(Date().timeIntervalSince(started) * 1000))ms")
            task = nil
        }
    }

    static func requestPermissions(_ completion: @escaping (Result<Void, EngineError>) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { completion(.failure(.speechDenied)) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted ? .success(()) : .failure(.micDenied))
                }
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw EngineError.recognizerUnavailable
        }

        latestTranscript = ""
        committedTranscript = ""
        lastPartial = ""
        finalDelivered = false
        lastTaskStart = Date.distantPast
        rapidFailures = 0
        lastVoiceAt = Date()

        startedAt = Date()
        sawFirstBuffer = false
        bufferLock.lock()
        pendingBuffers = []
        bufferLock.unlock()
        // Capture first, then build the recognizer: buffers that arrive in
        // between are queued and fed in, so the first word isn't lost.
        let preroll = try mic.begin { [weak self] buffer in self?.receive(buffer) }
        if !preroll.isEmpty { Log.write("engine: pre-roll \(preroll.count) buffers") }
        bufferLock.lock()
        pendingBuffers = preroll + pendingBuffers
        bufferLock.unlock()
        isRunning = true
        startRecognitionTask()
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        if !sawFirstBuffer {
            sawFirstBuffer = true
            Log.write("engine: first buffer \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
        }
        bufferLock.lock()
        if let request {
            bufferLock.unlock()
            request.append(buffer)
        } else {
            pendingBuffers.append(buffer)
            bufferLock.unlock()
        }
        reportLevel(buffer)
    }

    /// Feeds pre-recorded audio as if it came from the mic (`--simulate`).
    func startSimulated() throws {
        guard let recognizer, recognizer.isAvailable else { throw EngineError.recognizerUnavailable }
        latestTranscript = ""; committedTranscript = ""; lastPartial = ""
        finalDelivered = false; lastTaskStart = Date.distantPast; rapidFailures = 0
        isRunning = true
        startRecognitionTask()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        bufferLock.lock()
        let request = self.request
        bufferLock.unlock()
        request?.append(buffer)
    }

    private func startRecognitionTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Array(contextualStrings.prefix(100))
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        bufferLock.lock()
        let queued = pendingBuffers
        pendingBuffers = []
        self.request = request
        bufferLock.unlock()
        queued.forEach(request.append)
        lastTaskStart = Date()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if self.lastPartial.isEmpty && !text.isEmpty {
                    Log.write("engine: first partial \"\(text)\"")
                }
                // After a pause the recognizer restarts with a fresh, short
                // hypothesis. Bank the finished segment so it isn't lost.
                if text.count < self.lastPartial.count / 2, !self.lastPartial.hasPrefix(text) {
                    self.committedTranscript = self.joined(self.committedTranscript, self.lastPartial)
                }
                self.lastPartial = text
                self.latestTranscript = self.joined(self.committedTranscript, text)
                DispatchQueue.main.async { self.onPartial?(self.latestTranscript) }
                if result.isFinal {
                    self.handleTaskEnd(error: nil)
                }
            }
            if let error {
                self.handleTaskEnd(error: error)
            }
        }
    }

    /// The recognizer ends its task after ~10s of silence ("no speech
    /// detected") or when a segment finalizes. While the user is still
    /// dictating, bank what we have and start a fresh task on the same tap.
    private func handleTaskEnd(error: Error?) {
        if let error {
            let ns = error as NSError
            Log.write("engine: task ended \(ns.domain)#\(ns.code) \(ns.localizedDescription)")
        }
        guard isRunning else {
            deliverFinal()
            return
        }
        if !lastPartial.isEmpty {
            committedTranscript = joined(committedTranscript, lastPartial)
            lastPartial = ""
        }
        latestTranscript = committedTranscript
        // Repeated instant failures mean something is genuinely broken.
        if Date().timeIntervalSince(lastTaskStart) < 1.0 {
            rapidFailures += 1
            if rapidFailures >= 3 {
                Log.write("engine: giving up after repeated task failures")
                isRunning = false
                deliverFinal()
                return
            }
        } else {
            rapidFailures = 0
        }
        Log.write("engine: restarting recognition task (banked \(committedTranscript.count) chars)")
        startRecognitionTask()
    }

    /// Stops capturing; the final transcript arrives via onFinal.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        mic.end()
        request?.endAudio()
        // Safety net: if the recognizer never sends a final result, deliver
        // the best partial after a short grace period. Holds self strongly so
        // the engine survives until the final transcript is delivered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.deliverFinal()
        }
    }

    func cancel() {
        isRunning = false
        finalDelivered = true
        mic.end()
        task?.cancel()
        task = nil
        request = nil
    }

    private func deliverFinal() {
        DispatchQueue.main.async {
            guard !self.finalDelivered else { return }
            self.finalDelivered = true
            self.task?.cancel()
            self.task = nil
            self.bufferLock.lock()
            self.request = nil
            self.bufferLock.unlock()
            self.onFinal?(self.latestTranscript)
        }
    }

    private func joined(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in 0..<frames { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(frames))
        // Map roughly to 0...1 for the waveform UI.
        let level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 50) / 50))
        peakLevel = max(peakLevel, level)
        if level > 0.4 { lastVoiceAt = Date() }
        levelBufferCount += 1
        if levelBufferCount % 200 == 0 {
            Log.write("engine: audio flowing, peak level \(String(format: "%.2f", peakLevel)) over last \(200) buffers")
            peakLevel = 0
        }
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}

/// One-shot file transcription used by the CLI test mode.
enum FileTranscriber {
    static func transcribe(url: URL, onDevice: Bool = true,
                           completion: @escaping (Result<String, Error>) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
              recognizer.isAvailable else {
            completion(.failure(DictationEngine.EngineError.recognizerUnavailable))
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        if onDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                completion(.success(result.bestTranscription.formattedString))
            } else if let error {
                completion(.failure(error))
            }
        }
    }
}
