import Foundation

/// Fuses several ranked result lists into one, using Reciprocal Rank Fusion.
///
/// Lore retrieves candidates two ways — dense vector similarity (sqlite-vec) and
/// keyword full-text (FTS5) — then fuses them here. RRF is robust because it
/// needs only the *rank* of each item in each list, not comparable scores across
/// systems, so it combines heterogeneous rankers cleanly.
///
/// Score for an item = Σ 1 / (k + rank), summed over the lists it appears in,
/// where `rank` is 1-based. Higher is better. `k` damps the influence of very
/// top ranks; 60 is the value from the original RRF paper.
public struct ReciprocalRankFusion: Sendable {
    public let k: Double

    public init(k: Double = 60) {
        precondition(k > 0, "k must be positive")
        self.k = k
    }

    /// Fused items with scores, best first. Ties break by first appearance across
    /// the input lists (stable and deterministic).
    public func fusedScores<ID: Hashable>(_ rankedLists: [[ID]]) -> [(id: ID, score: Double)] {
        var scores: [ID: Double] = [:]
        var firstSeen: [ID: Int] = [:]
        var seq = 0

        for list in rankedLists {
            for (index, id) in list.enumerated() {
                let rank = index + 1
                scores[id, default: 0] += 1.0 / (k + Double(rank))
                if firstSeen[id] == nil {
                    firstSeen[id] = seq
                    seq += 1
                }
            }
        }

        return scores
            .map { (id: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (firstSeen[lhs.id] ?? 0) < (firstSeen[rhs.id] ?? 0)
            }
    }

    /// Convenience: just the fused ids, best first.
    public func fuse<ID: Hashable>(_ rankedLists: [[ID]]) -> [ID] {
        fusedScores(rankedLists).map(\.id)
    }
}
