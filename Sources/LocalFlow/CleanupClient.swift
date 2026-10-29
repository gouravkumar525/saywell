import Foundation
import LocalFlowCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// LLM polish pass on Apple's on-device Foundation Model. Every failure mode
/// (unavailable, timeout, guardrail, odd output) returns nil so the caller
/// inserts the rule-based text instead.
final class CleanupClient {

    /// Human-readable availability, for the menu and logs.
    static var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "device not eligible"
                case .appleIntelligenceNotEnabled: return "Apple Intelligence is off"
                case .modelNotReady: return "model still downloading"
                @unknown default: return "unavailable"
                }
            }
        }
        #endif
        return "requires macOS 26"
    }

    static var isAvailable: Bool { availabilityDescription == "available" }

    /// Recorded with training samples.
    static let engineName = "apple"
    static let modelName = "SystemLanguageModel.default"

    private var session: AnyObject?
    private var preparedKey: String?

    /// Builds and prewarms a session when dictation starts, so the model is
    /// loaded by the time the user stops talking.
    func prepare(level: CleanupLevel, style: AppStyle, command: Bool = false, mode: String? = nil,
                 language: String? = nil) {
        guard level != .off, Self.isAvailable else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let key = Self.key(level: level, style: style, command: command, mode: mode, language: language)
            let instructions = command ? CleanupPrompt.commandInstructions
                                       : CleanupPrompt.instructions(level: level, style: style, mode: mode,
                                                                    language: language)
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            self.session = session
            preparedKey = key
        }
        #endif
    }

    private static func key(level: CleanupLevel, style: AppStyle, command: Bool, mode: String?,
                            language: String?) -> String {
        command ? "command" : level.rawValue + style.rawValue + (mode ?? "") + "|" + (language ?? "")
    }

    /// Streams the cleanup; `onPartial` gets growing snapshots for the UI.
    func clean(_ request: CleanupRequest, timeout: TimeInterval = 4,
               onPartial: @escaping (String) -> Void,
               completion: @escaping (String?, String) -> Void) {
        guard request.level != .off else { completion(nil, "off"); return }
        guard Self.isAvailable else { completion(nil, Self.availabilityDescription); return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if preparedKey != Self.key(level: request.level, style: request.style, command: request.isCommand,
                                       mode: request.modeInstructions, language: request.language)
                || session == nil {
                prepare(level: request.level, style: request.style, command: request.isCommand,
                        mode: request.modeInstructions, language: request.language)
            }
            guard let session = session as? LanguageModelSession else { completion(nil, "no session"); return }
            // Sessions keep a transcript; use each one for a single request.
            self.session = nil
            preparedKey = nil

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
                    var latest = ""
                    let stream = session.streamResponse(to: CleanupPrompt.userPrompt(for: request),
                                                        options: GenerationOptions(sampling: .greedy))
                    for try await snapshot in stream {
                        latest = snapshot.content
                        let partial = latest
                        DispatchQueue.main.async { if !finished { onPartial(partial) } }
                    }
                    finish(latest, "ok")
                } catch let error as LanguageModelSession.GenerationError {
                    switch error {
                    case .guardrailViolation: finish(nil, "guardrail")
                    case .exceededContextWindowSize: finish(nil, "context window")
                    default: finish(nil, "generation error: \(error.localizedDescription)")
                    }
                } catch {
                    finish(nil, "error: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !finished else { return }
                task.cancel()
                finish(nil, "timeout")
            }
            return
        }
        #endif
        completion(nil, "requires macOS 26")
    }

    /// Free-form generation with Apple's on-device model (C5 call summaries).
    static func generate(instructions: String, prompt: String, maxTokens: Int) async -> String? {
        guard isAvailable else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            do {
                return try await session.respond(to: prompt,
                                                 options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)).content
            } catch {
                Log.write("apple: generate failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
