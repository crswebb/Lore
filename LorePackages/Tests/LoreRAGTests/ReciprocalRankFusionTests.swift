import XCTest
@testable import LoreRAG

final class ReciprocalRankFusionTests: XCTestCase {
    func testAgreementWins() {
        let rrf = ReciprocalRankFusion()
        let vector = ["a", "b", "c"]
        let keyword = ["a", "d", "b"]
        // "a" is rank 1 in both -> clearly first.
        XCTAssertEqual(rrf.fuse([vector, keyword]).first, "a")
    }

    func testDeterministicTieBreak() {
        let rrf = ReciprocalRankFusion()
        let listA = ["x", "y", "z"]
        let listB = ["y", "x", "w"]
        // x and y tie; x seen first. z and w tie; z seen first.
        XCTAssertEqual(rrf.fuse([listA, listB]), ["x", "y", "z", "w"])
    }

    func testAdditiveScores() {
        let rrf = ReciprocalRankFusion(k: 60)
        let scores = rrf.fusedScores([["a", "b"], ["a"]])
        let a = try! XCTUnwrap(scores.first { $0.id == "a" })
        let b = try! XCTUnwrap(scores.first { $0.id == "b" })
        XCTAssertEqual(a.score, 1.0 / 61.0 + 1.0 / 61.0, accuracy: 1e-12)
        XCTAssertEqual(b.score, 1.0 / 62.0, accuracy: 1e-12)
        XCTAssertGreaterThan(a.score, b.score)
    }

    func testSingleListPreservesOrder() {
        let rrf = ReciprocalRankFusion()
        XCTAssertEqual(rrf.fuse([["a", "b", "c"]]), ["a", "b", "c"])
    }

    func testEmptyInput() {
        let rrf = ReciprocalRankFusion()
        XCTAssertTrue(rrf.fuse([[String]]()).isEmpty)
    }
}
