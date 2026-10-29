import FluidAudio
import Foundation

// Usage: ParakeetBench <clips dir> [<models dir>]
// Prints one "<file>\t<ms>\t<text>" line per clip; LocalFlow --score-asr scores them.
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: ParakeetBench <clips dir> [models dir]"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let modelsDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

let done = DispatchSemaphore(value: 0)
Task {
    do {
        let loadStart = Date()
        let models = try await AsrModels.downloadAndLoad(to: modelsDir, version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        FileHandle.standardError.write("loaded Parakeet v3 in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s\n".data(using: .utf8)!)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["aiff", "wav", "m4a", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let start = Date()
            let result = try await asr.transcribe(file, decoderState: &state)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("\(file.lastPathComponent)\t\(ms)\t\(result.text)")
        }
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    done.signal()
}
done.wait()
