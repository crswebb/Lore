import XCTest
@testable import LoreRAG

final class ChunkerTests: XCTestCase {
    func testEmptyInputProducesNoChunks() {
        let chunker = Chunker()
        XCTAssertTrue(chunker.chunk("").isEmpty)
        XCTAssertTrue(chunker.chunk("   \n  ").isEmpty)
    }

    func testShortInputFitsInSingleChunk() {
        let chunker = Chunker(configuration: .init(maxTokens: 10, overlapTokens: 2))
        let drafts = chunker.chunk("one two three")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "one two three")
        XCTAssertEqual(drafts[0].approximateTokenCount, 3)
        XCTAssertEqual(drafts[0].ordinal, 0)
    }

    func testWindowsOverlapByConfiguredAmount() {
        // maxTokens 3, overlap 1 -> step 2 over 7 words.
        let chunker = Chunker(configuration: .init(maxTokens: 3, overlapTokens: 1))
        let drafts = chunker.chunk("a b c d e f g")
        XCTAssertEqual(drafts.map(\.text), ["a b c", "c d e", "e f g"])
        XCTAssertEqual(drafts.map(\.ordinal), [0, 1, 2])
    }

    func testStartingOrdinalOffset() {
        let chunker = Chunker(configuration: .init(maxTokens: 2, overlapTokens: 0))
        let drafts = chunker.chunk("a b c d", page: 4, startingOrdinal: 10)
        XCTAssertEqual(drafts.map(\.ordinal), [10, 11])
        XCTAssertTrue(drafts.allSatisfy { $0.page == 4 })
    }

    func testEveryWordIsCovered() {
        let chunker = Chunker(configuration: .init(maxTokens: 4, overlapTokens: 1))
        let words = (0..<23).map { "w\($0)" }
        let drafts = chunker.chunk(words.joined(separator: " "))
        let covered = Set(drafts.flatMap { $0.text.split(separator: " ").map(String.init) })
        XCTAssertEqual(covered, Set(words))
    }
}
