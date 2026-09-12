import Foundation
import LoreCore

/// Chat via any OpenAI-compatible API (OpenAI, OpenRouter, Together, a remote
/// Ollama's /v1 endpoint, LM Studio, vLLM, …). Streams over SSE.
///
/// `baseURL` should include the version path, e.g. https://api.openai.com/v1.
public struct OpenAICompatibleProvider: LLMProvider {
    public let baseURL: URL
    public let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func availability() async -> ProviderHealth {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .error("No response") }
            guard http.statusCode == 200 else {
                return .error("API returned HTTP \(http.statusCode)")
            }
            if let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
                return .ready(models: decoded.data.map(\.id))
            }
            return .ready(models: [])
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// External APIs don't "pull" models — no-op stream.
    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatToken, Error> {
        let body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "temperature": request.temperature,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        var mutableRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        mutableRequest.httpMethod = "POST"
        mutableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mutableRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        mutableRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let request = mutableRequest

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OpenAIError.http(status: http.statusCode)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            continuation.yield(ChatToken(text: "", isDone: true))
                            break
                        }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
                              let delta = chunk.choices.first?.delta.content, !delta.isEmpty
                        else { continue }
                        continuation.yield(ChatToken(text: delta, isDone: false))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum OpenAIError: Error, LocalizedError {
    case http(status: Int)
    public var errorDescription: String? {
        switch self {
        case .http(let status): return "The external API returned HTTP \(status)."
        }
    }
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct ChatChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}
