import Foundation
import LoreCore

/// Talks to a local Ollama daemon over its HTTP API.
///
/// Implements the chat side of `LLMProvider`. Streaming endpoints return
/// newline-delimited JSON, which we consume line-by-line for low-latency tokens.
public struct OllamaProvider: LLMProvider {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://localhost:11434")!,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: LLMProvider

    public func availability() async -> ProviderHealth {
        do {
            let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .error("Unexpected response from Ollama")
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return .ready(models: decoded.models.map(\.name))
        } catch {
            // Connection refused / cannot connect -> daemon not running (or not
            // installed). The setup layer disambiguates via a CLI presence check.
            return .installedNotRunning
        }
    }

    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        let request = makeRequest(path: "api/pull", body: ["model": model, "stream": true])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.checkStatus(response)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !line.isEmpty else { continue }
                        if let p = try? JSONDecoder().decode(PullResponse.self, from: data) {
                            continuation.yield(PullProgress(
                                status: p.status,
                                completedBytes: p.completed ?? 0,
                                totalBytes: p.total ?? 0
                            ))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatToken, Error> {
        let body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "options": ["temperature": request.temperature],
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        let urlRequest = makeRequest(path: "api/chat", body: body)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try Self.checkStatus(response)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !line.isEmpty else { continue }
                        let chunk = try JSONDecoder().decode(ChatResponse.self, from: data)
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(ChatToken(text: content, isDone: false))
                        }
                        if chunk.done {
                            continuation.yield(ChatToken(text: "", isDone: true))
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    private func makeRequest(path: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaError.http(status: http.statusCode)
        }
    }
}

/// Embedding side of Ollama, using the batch `/api/embed` endpoint.
public struct OllamaEmbeddingProvider: EmbeddingProvider {
    public let baseURL: URL
    public let model: String
    public let dimensions: Int
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        model: String = OllamaModelCatalog.defaultEmbeddingModel,
        dimensions: Int = 768,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.dimensions = dimensions
        self.session = session
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts,
        ])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OllamaError.http(status: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        return decoded.embeddings
    }
}

public enum OllamaError: Error, LocalizedError {
    case http(status: Int)

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "Ollama returned HTTP \(status)."
        }
    }
}

// MARK: - Wire DTOs

private struct TagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct PullResponse: Decodable {
    let status: String
    let total: Int64?
    let completed: Int64?
}

private struct ChatResponse: Decodable {
    struct Msg: Decodable { let role: String?; let content: String? }
    let message: Msg?
    let done: Bool
}

private struct EmbedResponse: Decodable {
    let embeddings: [[Float]]
}
