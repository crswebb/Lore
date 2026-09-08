import Foundation
import GRDB
import LoreCore

// Retroactive GRDB conformances for the domain models. Storing the shared
// value types directly (rather than duplicate record structs) keeps a single
// source of truth; GRDB maps each stored property to a column of the same name
// and encodes complex properties (metadata, citations) as JSON.

extension Project: TableRecord, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "project" }
}

extension Document: TableRecord, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "document" }
}

extension Chunk: TableRecord, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "chunk" }
}

extension Chat: TableRecord, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "chat" }
}

extension Message: TableRecord, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "message" }
}

/// Storage row for a chunk's embedding vector.
struct EmbeddingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chunk_embedding"
    var chunkID: String
    var projectID: String
    var model: String
    var dim: Int
    var vector: Data
}
