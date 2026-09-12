import Foundation
import NaturalLanguage
import LoreCore

/// On-device embeddings via Apple's NaturalLanguage contextual embedding model.
/// Used as a fallback so Apple Intelligence mode can work with no Ollama at all.
/// Quality is below a dedicated model like nomic-embed-text, but it needs no
/// server and no download beyond the OS assets.
public final class AppleEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let model = "apple-nl-contextual"
    public let dimensions: Int

    private let embedding: NLContextualEmbedding
    private let lock = NSLock()
    private var loaded = false

    /// Fails if the contextual embedding model isn't offered for Latin-script
    /// languages (covers English/Swedish/most European languages).
    public init?() {
        guard let embedding = NLContextualEmbedding(script: .latin) else { return nil }
        self.embedding = embedding
        self.dimensions = embedding.dimension
    }

    /// Ensure assets are loaded; returns false if unavailable.
    public func preload() -> Bool {
        (try? ensureLoaded()) != nil
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try ensureLoaded()
        return try texts.map { try vector(for: $0) }
    }

    private func ensureLoaded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        try embedding.load()
        loaded = true
    }

    /// Mean-pool the per-token contextual vectors into one sentence vector.
    private func vector(for text: String) throws -> [Float] {
        let trimmed = text.isEmpty ? " " : text
        let result = try embedding.embeddingResult(for: trimmed, language: nil)
        var sum = [Double](repeating: 0, count: dimensions)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for i in 0..<min(dimensions, vector.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [Float](repeating: 0, count: dimensions) }
        return sum.map { Float($0 / Double(count)) }
    }
}
