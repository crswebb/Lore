import Foundation

// MARK: - Provider abstractions
//
// The single most important anti-lock-in decision: everything the app needs
// from a local LLM runtime sits behind these protocols. Ollama is the first
// concrete implementation (in LoreProviders); LM Studio / llama.cpp / a remote
// gateway can be added later without touching feature code.

/// Health of the local LLM runtime, surfaced by the setup wizard and status pill.
public enum ProviderHealth: Sendable, Equatable {
    case notInstalled
    case installedNotRunning
    /// Running and reachable; `models` are the locally available model names.
    case ready(models: [String])
    case error(String)
}

/// Progress of a model download (`ollama pull`).
public struct PullProgress: Sendable, Equatable {
    public var status: String
    public var completedBytes: Int64
    public var totalBytes: Int64

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    public init(status: String, completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.status = status
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// One turn in a chat request sent to the model.
public struct ChatTurn: Sendable, Equatable, Codable {
    public var role: MessageRole
    public var content: String

    public init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatTurn]
    public var temperature: Double

    public init(model: String, messages: [ChatTurn], temperature: Double = 0.2) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
    }
}

/// An incremental token (or fragment) streamed back from the model.
public struct ChatToken: Sendable, Equatable {
    public var text: String
    public var isDone: Bool

    public init(text: String, isDone: Bool = false) {
        self.text = text
        self.isDone = isDone
    }
}

/// A local LLM chat runtime.
public protocol LLMProvider: Sendable {
    /// Detect installation / running state and list available models.
    func availability() async -> ProviderHealth
    /// Pull (download) a model, streaming progress.
    func pull(model: String) -> AsyncThrowingStream<PullProgress, Error>
    /// Stream a chat completion token-by-token.
    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatToken, Error>
}

/// A local embedding runtime used to vectorize chunks and queries.
public protocol EmbeddingProvider: Sendable {
    /// The embedding model name (recorded on each chunk for re-embed detection).
    var model: String { get }
    /// Vector dimensionality produced by `model`.
    var dimensions: Int { get }
    /// Embed a batch of texts, preserving order.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingProvider {
    /// Convenience for a single string.
    func embed(_ text: String) async throws -> [Float] {
        let result = try await embed([text])
        return result.first ?? []
    }
}
