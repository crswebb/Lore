import Foundation

/// A draft chunk produced by the `Chunker`, before it is embedded and persisted.
public struct ChunkDraft: Equatable, Sendable {
    public var ordinal: Int
    public var text: String
    public var page: Int?
    /// Approximate token count (word-based heuristic for now; a real tokenizer
    /// can replace `approximateTokenCount(of:)` without changing callers).
    public var approximateTokenCount: Int

    public init(ordinal: Int, text: String, page: Int? = nil, approximateTokenCount: Int) {
        self.ordinal = ordinal
        self.text = text
        self.page = page
        self.approximateTokenCount = approximateTokenCount
    }
}

/// Splits document text into overlapping windows suitable for embedding.
///
/// v1 uses a deterministic word-window with overlap. Overlap preserves context
/// across boundaries so a passage split mid-thought is still retrievable. A
/// paragraph/sentence-aware splitter and a real tokenizer are planned upgrades
/// that won't change this type's public surface.
public struct Chunker: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Target maximum tokens per chunk.
        public var maxTokens: Int
        /// Tokens of overlap carried between consecutive chunks.
        public var overlapTokens: Int

        public init(maxTokens: Int = 500, overlapTokens: Int = 75) {
            precondition(maxTokens > 0, "maxTokens must be positive")
            precondition(overlapTokens >= 0 && overlapTokens < maxTokens,
                         "overlapTokens must be in 0..<maxTokens")
            self.maxTokens = maxTokens
            self.overlapTokens = overlapTokens
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Approximate token count. Word-based for now — good enough to size windows.
    public static func approximateTokenCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Break `text` into overlapping chunks. `page` is propagated onto each draft
    /// (used for PDF citations where one page is chunked at a time).
    public func chunk(_ text: String, page: Int? = nil, startingOrdinal: Int = 0) -> [ChunkDraft] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        let maxTokens = configuration.maxTokens
        let step = max(1, maxTokens - configuration.overlapTokens)

        var drafts: [ChunkDraft] = []
        var ordinal = startingOrdinal
        var start = 0

        while start < words.count {
            let end = min(start + maxTokens, words.count)
            let slice = words[start..<end]
            let chunkText = slice.joined(separator: " ")
            drafts.append(
                ChunkDraft(
                    ordinal: ordinal,
                    text: chunkText,
                    page: page,
                    approximateTokenCount: slice.count
                )
            )
            ordinal += 1
            if end == words.count { break }
            start += step
        }

        return drafts
    }
}
