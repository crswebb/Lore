import Foundation

/// Brute-force dense vector search over an in-memory candidate set.
///
/// Correct and fast enough for personal-scale corpora. When corpora grow, this
/// type is the single place to swap in an ANN index (e.g. sqlite-vec) without
/// changing callers.
public enum VectorSearch {
    /// Cosine similarity in [-1, 1]. Returns 0 if either vector is empty/zero or
    /// dimensions mismatch (so a bad row can't crash retrieval).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Rank candidates by similarity to `query`, returning ids best-first.
    public static func rank<ID>(
        query: [Float],
        candidates: [(id: ID, vector: [Float])],
        topN: Int
    ) -> [ID] {
        guard !query.isEmpty, topN > 0 else { return [] }
        return candidates
            .map { (id: $0.id, score: cosineSimilarity(query, $0.vector)) }
            .sorted { $0.score > $1.score }
            .prefix(topN)
            .map(\.id)
    }
}
