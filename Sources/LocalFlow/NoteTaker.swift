import AppKit
import AVFoundation
import CoreAudio
@preconcurrency import FluidAudio
import LocalFlowCore
import SwiftUI

// MARK: - System audio (what the Mac plays)

/// Captures everything the Mac plays through a Core Audio process tap
/// (macOS 14.2+, "System Audio Recording" permission). No bot joins the call;
/// the other people are heard the way you hear them.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "saywell.notes.systemtap", qos: .userInitiated)

    struct TapError: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) failed (\(status))" }
    }

    func start(_ sink: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError(step: "process tap", status: status) }
        tapID = tap

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw TapError(step: "tap format", status: status)
        }

        let outputUID = try Self.defaultOutputUID()
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Saywell Notetaker",
            kAudioAggregateDeviceUIDKey: "saywell-notes-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else {
            stop()
            throw TapError(step: "aggregate device", status: status)
        }
        aggregateID = aggregate

        let channels = Int(format.channelCount)
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, input, _, _, _ in
            // Copy out now: the buffers are only valid during this call. The tap's
            // buffers are the last ones in the list.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard list.count >= 1 else { return }
            let mine = Array(list.suffix(format.isInterleaved ? 1 : channels))
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            guard bytesPerFrame > 0, let first = mine.first else { return }
            let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
            guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            copy.frameLength = frames
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (i, buffer) in mine.enumerated() where i < target.count {
                guard let src = buffer.mData, let dst = target[i].mData else { continue }
                memcpy(dst, src, Int(min(buffer.mDataByteSize, target[i].mDataByteSize)))
            }
            sink(copy)
        }
        guard status == noErr, let procID else {
            stop()
            throw TapError(step: "IO proc", status: status)
        }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else {
            stop()
            throw TapError(step: "start", status: status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw TapError(step: "output device", status: status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else { throw TapError(step: "output UID", status: status) }
        return value as String
    }
}

// MARK: - Who is using the microphone

/// Bundle ids of the processes using an input device right now, from Core
/// Audio's process list (macOS 14+). Reads only process metadata, no audio.
enum MicUsers {
    static func current() -> [String] {
        guard #available(macOS 14.0, *) else { return [] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let mine = Bundle.main.bundleIdentifier
        return objects.compactMap { process in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &a, 0, nil, &runningSize, &running) == noErr, running != 0 else { return nil }
            a.mSelector = kAudioProcessPropertyBundleID
            var id: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &a, 0, nil, &idSize, &id) == noErr,
                  let bundle = id?.takeRetainedValue() as String?, bundle != mine else { return nil }
            return bundle
        }
    }
}

// MARK: - One channel to disk

/// Writes one side of the call (mic or Mac) as 16 kHz mono WAV, on a shared
/// clock so both files line up, and hands out finished stretches for the live
/// transcript.
final class ChannelRecorder {
    static let rate = 16_000.0
    let url: URL
    private let file: AVAudioFile
    private let origin: UInt64
    private let resampler = Resampler()
    private let queue: DispatchQueue
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private var written = 0
    private var pending: [Float] = []
    private var pendingStart = 0
    private var closed = false
    /// Recent loudness 0...1, for the pill while recording.
    private(set) var level: Float = 0

    init(url: URL, origin: UInt64, label: String) throws {
        self.url = url
        self.origin = origin
        queue = DispatchQueue(label: "saywell.notes.\(label)")
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Called on the audio thread; converts right away (the buffer is reused).
    func append(_ buffer: AVAudioPCMBuffer) {
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in self?.write(samples, now: now) }
    }

    private func write(_ samples: [Float], now: UInt64) {
        guard !closed else { return }
        // Silence until this buffer's place on the shared clock (the tap starts late,
        // and sends nothing while the Mac is silent on some devices).
        let expected = Int(Double(now - min(now, origin)) / 1e9 * Self.rate) - samples.count
        if expected - written > Int(Self.rate / 2) { put([Float](repeating: 0, count: expected - written)) }
        put(samples)
        var sum: Float = 0
        for s in samples { sum += s * s }
        level = min(1, sqrt(sum / Float(samples.count)) * 8)
    }

    private func put(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, samples.count * 4) }
        try? file.write(from: buffer)
        if pending.isEmpty { pendingStart = written }
        pending += samples
        written += samples.count
    }

    /// A stretch of 4–18 s that ends on a pause (or anything left, when
    /// `flush`), with its start time in seconds.
    func takeChunk(flush: Bool = false) -> (start: Double, samples: [Float])? {
        queue.sync {
            let n = pending.count
            guard n > 0 else { return nil }
            let seconds = Double(n) / Self.rate
            if !flush {
                guard seconds >= 4 else { return nil }
                let tail = pending.suffix(Int(Self.rate / 2))
                let rms = sqrt(tail.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, tail.count)))
                guard rms < 0.012 || seconds >= 18 else { return nil }
            }
            let chunk = (Double(pendingStart) / Self.rate, pending)
            pending = []
            return chunk
        }
    }

    var seconds: Double { queue.sync { Double(written) / Self.rate } }

    func close() {
        queue.sync { closed = true }
    }

    /// Reads a recording back as 16 kHz mono samples, `slice` seconds at a time.
    static func read(_ url: URL, slice: Double = 300, _ body: (Double, [Float]) async throws -> Void) async throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(slice * rate)
        var offset = 0.0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            try await body(offset, Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
            offset += Double(buffer.frameLength) / rate
        }
    }
}

// MARK: - Speaker separation model

/// FluidAudio's offline diarizer (pyannote Community-1, CC-BY-4.0, ~22 MB),
/// installed pinned and verified like the other models. FluidAudio is kept
/// offline: it loads from our folder and never downloads by itself.
final class DiarizerService {
    static let shared = DiarizerService()
    static let repo = "FluidInference/speaker-diarization-coreml"
    static var manifest: ModelManifest { ModelManifest.pinned(for: repo)! }
    static var isDownloaded: Bool { PinnedModels.source(manifest) != nil }

    private var models: OfflineDiarizerModels?

    var isReady: Bool { models != nil }

    func load(allowDownload: Bool) async throws {
        guard models == nil else { return }
        ModelHub.offlineMode = true
        let (dir, needsMarker) = try await PinnedModels.prepare(Self.manifest, allowDownload: allowDownload) { _ in }
        try await load(verified: dir, root: PinnedModels.directory.appendingPathComponent(".fluidaudio", isDirectory: true))
        if needsMarker { try Self.manifest.writeMarker(at: dir) }
    }

    /// Loads from a folder already verified against the manifest. FluidAudio
    /// looks for <root>/speaker-diarization with a revision marker.
    func load(verified dir: URL, root: URL) async throws {
        ModelHub.offlineMode = true
        let link = root.appendingPathComponent("speaker-diarization")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != dir.path {
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        }
        try Self.manifest.revision.write(to: dir.appendingPathComponent(".fluidaudio-revision"), atomically: true, encoding: .utf8)
        let started = Date()
        models = try await OfflineDiarizerModels.load(from: root)
        Log.write("diarizer: loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    /// Speaker turns in a 16 kHz recording.
    func turns(in url: URL) async throws -> [SpeakerTurn] {
        guard let models else { return [] }
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        let result = try await manager.process(url)
        return result.segments.map { SpeakerTurn($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds)) }
    }
}

// MARK: - Notetaker

/// C5: records a call (your mic and what the Mac plays), shows a live
/// transcript, then writes the transcript by speaker with Parakeet and the
/// diarizer, and a summary with key points and to-dos with the on-device
/// model. Notes live in the database; the audio is deleted once the transcript
/// is written. Nothing leaves the Mac. Tell the other people you're recording.
final class NoteTaker: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var recording: Note?
    /// Notes whose transcript or summary is being written.
    @Published private(set) var working: Set<UUID> = []
    /// What the notetaker is doing, for the Notes tab and the pill.
    @Published private(set) var status = ""

    /// Called on the main thread when recording starts or stops.
    var onRecordingChanged: ((Bool) -> Void)?

    private let store: Store
    private let mic: MicCapture
    /// Free-form generation with the selected on-device model (instructions, prompt, max tokens).
    private let generate: (String, String, Int) async -> String?
    /// Cleans one transcript line (rules + local model, vetted like dictation); nil keeps it as heard.
    var cleanLine: ((String) async -> String?)?
    /// Recording started for a detected meeting; stops when the meeting ends.
    private(set) var meetingApp: String?
    /// A SystemAudioTap (macOS 14.2+).
    private var tap: AnyObject?
    private var micChannel: ChannelRecorder?
    private var systemChannel: ChannelRecorder?
    private var liveTimer: Timer?
    private var liveBusy = false

    /// Recordings in progress (`--note-test` points it elsewhere).
    static var folder = Store.appSupportDirectory.appendingPathComponent("Notes", isDirectory: true)
    static func folder(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }

    init(store: Store, mic: MicCapture, generate: @escaping (String, String, Int) async -> String?) {
        self.store = store
        self.mic = mic
        self.generate = generate
        notes = store.notes()
    }

    var isRecording: Bool { recording != nil }

    /// Loudness of the call (either side), for Sprig while recording.
    var level: Float { max(micChannel?.level ?? 0, systemChannel?.level ?? 0) }

    // MARK: Recording

    /// Starts recording. Returns an error message when it can't. `meeting` marks
    /// a recording started for a detected Zoom/Teams meeting (stopped when it ends).
    func start(app: String?, meeting: String? = nil) -> String? {
        guard recording == nil else { return nil }
        meetingApp = meeting
        guard ParakeetService.shared.isReady else { return "Parakeet isn't loaded yet" }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        var note = Note(title: "Call, \(formatter.string(from: now))", start: now, app: app)
        let dir = Self.folder(for: note.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let origin = DispatchTime.now().uptimeNanoseconds
            let micChannel = try ChannelRecorder(url: dir.appendingPathComponent("mic.wav"), origin: origin, label: "mic")
            _ = try mic.begin { micChannel.append($0) }
            self.micChannel = micChannel
            let systemChannel = try ChannelRecorder(url: dir.appendingPathComponent("system.wav"), origin: origin, label: "system")
            do {
                guard #available(macOS 14.2, *) else { throw NSError(domain: "Notes", code: 2) }
                let tap = SystemAudioTap()
                try tap.start { systemChannel.append($0) }
                self.tap = tap
                self.systemChannel = systemChannel
            } catch {
                // Without the System Audio Recording permission, note from the mic alone.
                Log.write("notes: system audio unavailable (\(error.localizedDescription)); recording the mic only")
                systemChannel.close()
                try? FileManager.default.removeItem(at: systemChannel.url)
            }
        } catch {
            mic.end()
            micChannel = nil
            Log.write("notes: could not start: \(error.localizedDescription)")
            return "Couldn't start recording: \(error.localizedDescription)"
        }
        note.status = .recording
        store.saveNote(note)
        recording = note
        status = systemChannel == nil ? "Recording your mic only (allow System Audio Recording for the call)" : "Recording"
        reloadNotes()
        Log.write("notes: recording \(note.id) (system audio: \(systemChannel != nil))")
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.liveTick(flush: false) }
        onRecordingChanged?(true)
        return nil
    }

    func stop() {
        guard var note = recording else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        mic.end()
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
        micChannel?.close()
        systemChannel?.close()
        micChannel = nil
        systemChannel = nil
        note.end = Date()
        note.status = .processing
        recording = nil
        meetingApp = nil
        store.saveNote(note)
        reloadNotes()
        Log.write("notes: stopped after \(Int(note.duration))s")
        onRecordingChanged?(false)
        Task { await process(note.id) }
    }

    /// Every second: stretches that end on a pause go to Parakeet for the live view.
    private func liveTick(flush: Bool) {
        guard !liveBusy, recording != nil else { return }
        let chunks = [(NoteBuilder.meID, micChannel?.takeChunk(flush: flush)),
                      ("p2", systemChannel?.takeChunk(flush: flush))].compactMap { id, c in c.map { (id, $0) } }
        guard !chunks.isEmpty else { return }
        liveBusy = true
        Task {
            var lines: [NoteLine] = []
            for (speaker, chunk) in chunks {
                guard let text = try? await ParakeetService.shared.transcribe(chunk.samples).text,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                lines.append(NoteLine(speaker: speaker, start: chunk.start,
                                      end: chunk.start + Double(chunk.samples.count) / ChannelRecorder.rate, text: text))
            }
            await MainActor.run {
                self.liveBusy = false
                guard var note = self.recording, !lines.isEmpty else { return }
                note.liveLines = (note.liveLines + lines).sorted { $0.start < $1.start }
                if note.speakers.isEmpty {
                    note.speakers = [NoteSpeaker(id: NoteBuilder.meID, name: "Me", isMe: true), NoteSpeaker(id: "p2", name: "Others")]
                }
                self.recording = note
            }
        }
    }

    // MARK: Processing

    /// Writes the transcript from the recordings, deletes the audio, then the summary.
    func process(_ id: UUID) async {
        guard var note = store.notes().first(where: { $0.id == id }) else { return }
        await MainActor.run {
            working.insert(id)
            status = "Writing the transcript…"
        }
        defer { Task { @MainActor in self.working.remove(id); self.status = "" } }
        let dir = Self.folder(for: id)
        let micURL = dir.appendingPathComponent("mic.wav"), systemURL = dir.appendingPathComponent("system.wav")
        let fm = FileManager.default
        do {
            if !ParakeetService.shared.isReady {
                let ok = await withCheckedContinuation { c in
                    DispatchQueue.main.async { ParakeetService.shared.load { c.resume(returning: $0) } }
                }
                guard ok else { throw NSError(domain: "Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Parakeet isn't available"]) }
            }
            let started = Date()
            let micWords = fm.fileExists(atPath: micURL.path) ? try await Self.words(in: micURL) : []
            let systemWords = fm.fileExists(atPath: systemURL.path) ? try await Self.words(in: systemURL) : []
            Log.write("notes: transcribed \(micWords.count) mic + \(systemWords.count) call words in \(Int(Date().timeIntervalSince(started)))s")

            var systemTurns: [SpeakerTurn] = [], micTurns: [SpeakerTurn] = []
            do {
                if !DiarizerService.shared.isReady { try await DiarizerService.shared.load(allowDownload: false) }
                if !systemWords.isEmpty {
                    systemTurns = try await DiarizerService.shared.turns(in: systemURL)
                } else if !micWords.isEmpty {
                    micTurns = try await DiarizerService.shared.turns(in: micURL)
                }
                Log.write("notes: \(Set((systemTurns + micTurns).map(\.speaker)).count) voices: "
                          + (systemTurns + micTurns).map { "\($0.speaker) \(String(format: "%.1f-%.1f", $0.start, $0.end))" }.joined(separator: ", "))
            } catch {
                Log.write("notes: no speaker separation (\(error.localizedDescription)); everyone else is one speaker")
            }
            let built = NoteBuilder.build(mic: micWords, system: systemWords, systemTurns: systemTurns, micTurns: micTurns)
            note.speakers = built.speakers
            note.lines = built.lines
            note.liveLines = []
            note.status = .ready
            note.error = nil
            store.saveNote(note)
            // The transcript is written: the audio goes.
            try? fm.removeItem(at: dir)
            Log.write("notes: transcript written (\(note.lines.count) lines); audio deleted")
            await MainActor.run { reloadNotes() }
            await clean(id)
            await summarize(id)
        } catch {
            note.status = .failed
            note.error = error.localizedDescription
            store.saveNote(note)
            Log.write("notes: processing failed: \(error.localizedDescription) (audio kept to try again)")
            await MainActor.run { reloadNotes() }
        }
    }

    /// Parakeet over the recording in 5-minute slices, with word times.
    private static func words(in url: URL) async throws -> [TimedWord] {
        var out: [TimedWord] = []
        try await ChannelRecorder.read(url) { offset, samples in
            // Skip silent slices (the Mac played nothing, or the mic was muted).
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            guard peak > 0.003 else { return }
            let result = try await ParakeetService.shared.transcribe(samples)
            let tokens = (result.tokenTimings ?? []).map { ($0.token, $0.startTime + offset, $0.endTime + offset) }
            out += WordAgreement.words(fromTokens: tokens).map {
                TimedWord($0.text, $0.start ?? offset, $0.end ?? offset)
            }
        }
        return out
    }

    /// Cleans every line with the local model (fillers, punctuation, repeated
    /// words; the same faithfulness check as dictation). Originals stay in `raw`.
    func clean(_ id: UUID) async {
        guard let cleanLine, var note = store.notes().first(where: { $0.id == id }), note.cleaned != true else { return }
        await MainActor.run { working.insert(id) }
        defer { Task { @MainActor in self.working.remove(id); self.status = "" } }
        let started = Date()
        var changed = 0
        for i in note.lines.indices {
            let total = note.lines.count
            await MainActor.run { status = "Cleaning up the transcript (\(i + 1)/\(total))…" }
            let heard = note.lines[i].raw ?? note.lines[i].text
            guard let tidy = await cleanLine(heard), !tidy.isEmpty else { continue }
            if tidy != heard { changed += 1 }
            note.lines[i].raw = heard
            note.lines[i].text = tidy
        }
        note.cleaned = true
        store.saveNote(note)
        Log.write("notes: cleaned \(changed) of \(note.lines.count) lines in \(Int(Date().timeIntervalSince(started)))s")
        await MainActor.run { reloadNotes() }
    }

    /// Cleans again (if never cleaned) and rewrites the summary.
    func refresh(_ id: UUID) async {
        await clean(id)
        await summarize(id)
    }

    /// Summary, key points and to-dos from the selected on-device model.
    func summarize(_ id: UUID) async {
        guard var note = store.notes().first(where: { $0.id == id }), !note.lines.isEmpty else { return }
        await MainActor.run {
            working.insert(id)
            status = "Writing the summary…"
        }
        defer { Task { @MainActor in self.working.remove(id); self.status = "" } }
        let transcript = NoteBuilder.transcript(note)
        let parts = NoteBuilder.parts(transcript)
        var prompt = NoteSummary.prompt(transcript)
        if parts.count > 1 {
            var partNotes: [String] = []
            for part in parts {
                if let n = await generate(NoteSummary.partInstructions, NoteSummary.prompt(part), 400) { partNotes.append(n) }
            }
            prompt = NoteSummary.promptFromParts(partNotes)
        }
        guard let output = await generate(NoteSummary.instructions, prompt, 900),
              let result = NoteSummary.parse(output) else {
            Log.write("notes: no summary (model unavailable or unreadable output)")
            return
        }
        note.summary = result.summary
        note.keyPoints = result.keyPoints
        note.todos = result.todos
        note.decisions = result.decisions
        note.openQuestions = result.openQuestions
        if !note.titleEdited, let title = result.title { note.title = title }
        store.saveNote(note)
        Log.write("notes: summary written (\(note.keyPoints.count) points, \(result.decisions.count) decisions, \(note.todos.count) action items, \(result.openQuestions.count) open questions)")
        await MainActor.run { reloadNotes() }
    }

    /// Notes interrupted by a quit are finished at the next launch.
    func resumeUnfinished() {
        for note in notes where note.status == .recording || note.status == .processing {
            var n = note
            n.status = .processing
            if n.end == nil { n.end = Date() }
            store.saveNote(n)
            Task { await process(n.id) }
        }
    }

    // MARK: Editing

    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard var note = store.notes().first(where: { $0.id == id }) else { return }
        change(&note)
        store.saveNote(note)
        reloadNotes()
    }

    func rename(_ id: UUID, title: String) {
        update(id) { $0.title = title; $0.titleEdited = true }
    }

    func renameSpeaker(_ id: UUID, speaker: String, to name: String) {
        update(id) { NoteBuilder.rename(&$0, speaker: speaker, to: name) }
    }

    func toggleTodo(_ id: UUID, todo: UUID) {
        update(id) { note in
            if let i = note.todos.firstIndex(where: { $0.id == todo }) { note.todos[i].done.toggle() }
        }
    }

    func delete(_ id: UUID) {
        store.deleteNote(id: id)
        try? FileManager.default.removeItem(at: Self.folder(for: id))
        reloadNotes()
    }

    func export(_ note: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? NoteBuilder.markdown(note).write(to: url, atomically: true, encoding: .utf8)
    }

    func reloadNotes() {
        let load = { self.notes = self.store.notes() }
        Thread.isMainThread ? load() : DispatchQueue.main.async(execute: load)
    }
}

// MARK: - Notes tab

/// Selection and edit drafts for the Notes tab (no @State in this codebase).
final class NotesViewModel: ObservableObject {
    let taker: NoteTaker
    @Published var selected: UUID?
    @Published var titleDraft = ""
    @Published var speakerDrafts: [String: String] = [:]
    /// Show the transcript as heard instead of cleaned up.
    @Published var showOriginal = false

    init(taker: NoteTaker) { self.taker = taker }

    func select(_ note: Note) {
        selected = note.id
        titleDraft = note.title
        speakerDrafts = Dictionary(uniqueKeysWithValues: note.speakers.map { ($0.id, $0.name) })
    }
}

struct NotesTab: View {
    @ObservedObject var model: NotesViewModel
    @ObservedObject var taker: NoteTaker
    var record: () -> Void

    private static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Button(taker.isRecording ? "Stop Recording" : "Record a Call", action: record)
                if !taker.status.isEmpty { Text(taker.status).font(.caption).foregroundColor(.secondary) }
                List(taker.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).font(.body).lineLimit(1)
                        Text("\(Self.dates.string(from: note.start)) · \(statusText(note))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(note) }
                    .listRowBackground(model.selected == note.id ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .scrollContentBackground(.hidden)
                Text("Recorded on this Mac. The audio is deleted once the transcript is written. Tell people you're recording.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .frame(width: 220)
            .onAppear {
                // Open the newest note right away.
                if model.selected == nil, let first = taker.recording ?? taker.notes.first { model.select(first) }
            }
            Divider()
            detail
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func statusText(_ note: Note) -> String {
        if taker.recording?.id == note.id { return "recording" }
        if taker.working.contains(note.id) { return "writing…" }
        switch note.status {
        case .ready: return "\(max(1, Int(note.duration / 60))) min"
        case .failed: return "failed"
        case .processing: return "waiting"
        case .recording: return "interrupted"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selected, let note = taker.recording?.id == id ? taker.recording : taker.notes.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Title", text: $model.titleDraft, onCommit: { taker.rename(id, title: model.titleDraft) })
                            .font(.title3)
                        Button("Export…") { taker.export(note) }.disabled(note.lines.isEmpty)
                        Button("Delete") {
                            taker.delete(id)
                            model.selected = nil
                        }
                        .disabled(taker.recording?.id == id)
                    }
                    if let error = note.error { Text("Failed: \(error)").foregroundColor(.red).font(.caption) }
                    if !note.speakers.isEmpty, note.status == .ready {
                        Text("People (rename someone to another's name to merge them)").font(.headline)
                        ForEach(note.speakers, id: \.id) { s in
                            TextField(s.name, text: Binding(get: { model.speakerDrafts[s.id] ?? s.name },
                                                            set: { model.speakerDrafts[s.id] = $0 }),
                                      onCommit: {
                                taker.renameSpeaker(id, speaker: s.id, to: model.speakerDrafts[s.id] ?? s.name)
                                if let fresh = taker.notes.first(where: { $0.id == id }) { model.select(fresh) }
                            })
                            .frame(maxWidth: 220)
                        }
                    }
                    if let summary = note.summary {
                        Text("Summary").font(.headline)
                        Text(summary).textSelection(.enabled)
                    }
                    if note.status == .ready, !note.lines.isEmpty {
                        Button(note.summary == nil ? "Clean Up & Summarize" : "Summarize Again") { Task { await taker.refresh(id) } }
                            .disabled(taker.working.contains(id))
                    }
                    if !note.keyPoints.isEmpty {
                        Text("Key points").font(.headline)
                        ForEach(note.keyPoints, id: \.self) { Text("• \($0)").textSelection(.enabled) }
                    }
                    if let decisions = note.decisions, !decisions.isEmpty {
                        Text("Decisions").font(.headline)
                        ForEach(decisions, id: \.self) { Text("✓ \($0)").textSelection(.enabled) }
                    }
                    if !note.todos.isEmpty {
                        Text("Action items").font(.headline)
                        ForEach(note.todos) { todo in
                            Toggle(isOn: Binding(get: { todo.done }, set: { _ in taker.toggleTodo(id, todo: todo.id) })) {
                                Text(todo.text + ([todo.owner, todo.due].compactMap { $0 }.isEmpty ? ""
                                     : " (\([todo.owner, todo.due].compactMap { $0 }.joined(separator: ", ")))"))
                            }
                        }
                    }
                    if let questions = note.openQuestions, !questions.isEmpty {
                        Text("Open questions").font(.headline)
                        ForEach(questions, id: \.self) { Text("? \($0)").textSelection(.enabled) }
                    }
                    let lines = note.lines.isEmpty ? note.liveLines : note.lines
                    if !lines.isEmpty {
                        HStack {
                            Text(note.lines.isEmpty ? "Live transcript" : (note.cleaned == true ? "Transcript (cleaned up)" : "Transcript"))
                                .font(.headline)
                            Spacer()
                            if note.cleaned == true { Toggle("Show what was heard", isOn: $model.showOriginal).font(.caption) }
                        }
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(note.speaker(line.speaker)?.name ?? "Someone").bold().frame(width: 80, alignment: .leading)
                                Text(model.showOriginal ? (line.raw ?? line.text) : line.text).textSelection(.enabled)
                            }
                            .font(.callout)
                        }
                    }
                    if note.status == .failed {
                        Button("Try Again") { Task { await taker.process(id) } }
                    }
                }
                .padding(.trailing, 8)
            }
        } else {
            Text("Record a call from the menu, the bottom pill or here. Your notes appear on the left.")
                .foregroundColor(.secondary)
        }
    }
}
