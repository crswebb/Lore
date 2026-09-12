import Foundation
import FoundationModels
import LoreCore

/// Chat via Apple's on-device Foundation Models (Apple Intelligence). Fully
/// local, no download, no server. Requires a supported Mac with Apple
/// Intelligence enabled. Embeddings are handled elsewhere (Ollama), since the
/// framework doesn't expose an embeddings API.
public struct AppleFoundationModelProvider: LLMProvider {
    public init() {}

    public func availability() async -> ProviderHealth {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready(models: ["Apple Intelligence"])
        case .unavailable(let reason):
            return .error(Self.describe(reason))
        @unknown default:
            return .error("Apple Intelligence is unavailable.")
        }
    }

    /// Built in — nothing to download.
    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatToken, Error> {
        let instructions = request.messages.first { $0.role == .system }?.content
        let prompt = Self.buildPrompt(request.messages)
        let temperature = request.temperature

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = instructions.map { LanguageModelSession(instructions: $0) }
                        ?? LanguageModelSession()
                    let options = GenerationOptions(temperature: temperature)
                    var previous = ""
                    for try await partial in session.streamResponse(to: prompt, options: options) {
                        let text = partial.content
                        let delta = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : text
                        if !delta.isEmpty { continuation.yield(ChatToken(text: delta)) }
                        previous = text
                    }
                    continuation.yield(ChatToken(text: "", isDone: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fold the non-system turns into a single prompt (a fresh session per
    /// request is stateless, so prior turns are included inline).
    static func buildPrompt(_ messages: [ChatTurn]) -> String {
        var out = ""
        for message in messages where message.role != .system {
            switch message.role {
            case .assistant: out += "Assistant: \(message.content)\n\n"
            default: out += "\(message.content)\n\n"
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use it here."
        case .modelNotReady:
            return "Apple Intelligence is still preparing its model. Try again shortly."
        @unknown default:
            return "Apple Intelligence is unavailable."
        }
    }
}
