import Foundation

/// Turns captured samples into mlx_lm.lora chat-format JSONL. Messages are
/// rebuilt with the live CleanupPrompt so training matches runtime exactly.
public enum TrainingExport {

    public struct Message: Codable, Equatable {
        public let role: String
        public let content: String
    }

    struct ChatLine: Codable {
        let messages: [Message]
    }

    struct PreferenceLine: Codable {
        let messages: [Message]
        let chosen: String
        let rejected: String
        let reason: String?
    }

    /// The request the model saw for this sample.
    public static func request(for s: Store.Sample) -> CleanupRequest {
        CleanupRequest(transcript: s.rules,
                       style: AppStyle(rawValue: s.style) ?? .neutral,
                       level: CleanupLevel(rawValue: s.level) ?? .light,
                       dictionary: s.dictionary,
                       precedingText: s.preceding)
    }

    /// System + user messages, exactly as the app builds them at runtime.
    public static func promptMessages(for s: Store.Sample) -> [Message] {
        let request = request(for: s)
        return [
            Message(role: "system", content: CleanupPrompt.instructions(level: request.level, style: request.style)),
            Message(role: "user", content: CleanupPrompt.prompt(for: request)),
        ]
    }

    /// What the model should have said: the user's final text if they edited
    /// it, otherwise the model's output (normalized the way the app uses it).
    public static func target(for s: Store.Sample) -> String? {
        // Smart spacing adds separators around the insert; they aren't model output.
        if let final = s.finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !final.isEmpty {
            return final
        }
        guard let output = s.llmOutput else { return nil }
        let level = CleanupLevel(rawValue: s.level) ?? .light
        return CleanupPrompt.accept(output: output, input: s.rules, level: level, dictionary: s.dictionary) ?? output
    }

    /// Full training conversation, or nil when there's no usable target or a
    /// snippet token from the prompt is missing from it (the user's edited
    /// text contains the expansion, not the token).
    public static func messages(for s: Store.Sample) -> [Message]? {
        guard let target = target(for: s) else { return nil }
        guard tokens(in: s.rules).allSatisfy(target.contains) else { return nil }
        return promptMessages(for: s) + [Message(role: "assistant", content: target)]
    }

    public static func chatLine(for s: Store.Sample) -> String? {
        messages(for: s).flatMap { encode(ChatLine(messages: $0)) }
    }

    /// A rejected model output paired with the text that was inserted instead.
    public static func preferenceLine(for s: Store.Sample) -> String? {
        guard let rejected = s.llmOutput, s.accepted == false else { return nil }
        let chosen = s.finalText ?? s.inserted
        return encode(PreferenceLine(messages: promptMessages(for: s), chosen: chosen,
                                     rejected: rejected, reason: s.rejectReason))
    }

    /// Deterministic split: every k-th line goes to validation, at least one
    /// when there are two or more lines (mlx_lm.lora wants a non-empty valid set).
    public static func split<T>(_ items: [T], validFraction: Double) -> (train: [T], valid: [T]) {
        guard items.count >= 2, validFraction > 0 else { return (items, []) }
        let validCount = max(1, min(items.count - 1, Int((Double(items.count) * validFraction).rounded())))
        let step = Double(items.count) / Double(validCount)
        let validIndices = Set((0..<validCount).map { Int(Double($0) * step + step / 2) })
        var train: [T] = [], valid: [T] = []
        for (i, item) in items.enumerated() {
            if validIndices.contains(i) { valid.append(item) } else { train.append(item) }
        }
        return (train, valid)
    }

    static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "⟦"), let close = rest.range(of: "⟧", range: open.upperBound..<rest.endIndex) {
            result.append(String(rest[open.lowerBound..<close.upperBound]))
            rest = rest[close.upperBound...]
        }
        return result
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
