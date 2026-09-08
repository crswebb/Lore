import Foundation
import GRDB
import LoreCore

// Concrete repositories over the GRDB store. The UI talks to these; SQL never
// leaks past this module. Providers stay protocol-based (the real swap point);
// repositories are concrete on purpose to avoid protocol boilerplate for the
// one storage backend we ship.

public struct ProjectRepository: Sendable {
    let db: LoreDatabase
    public init(_ db: LoreDatabase) { self.db = db }

    public func all() async throws -> [Project] {
        try await db.dbQueue.read { db in
            try Project.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    public func project(id: UUID) async throws -> Project? {
        try await db.dbQueue.read { db in try Project.fetchOne(db, key: id) }
    }

    public func save(_ project: Project) async throws {
        try await db.dbQueue.write { db in try project.save(db) }
    }

    public func delete(id: UUID) async throws {
        _ = try await db.dbQueue.write { db in try Project.deleteOne(db, key: id) }
    }
}

public struct DocumentRepository: Sendable {
    let db: LoreDatabase
    public init(_ db: LoreDatabase) { self.db = db }

    public func documents(inProject projectID: UUID) async throws -> [Document] {
        try await db.dbQueue.read { db in
            try Document
                .filter(Column("projectID") == projectID)
                .order(Column("addedAt").desc)
                .fetchAll(db)
        }
    }

    public func document(id: UUID) async throws -> Document? {
        try await db.dbQueue.read { db in try Document.fetchOne(db, key: id) }
    }

    public func save(_ document: Document) async throws {
        try await db.dbQueue.write { db in try document.save(db) }
    }

    public func delete(id: UUID) async throws {
        _ = try await db.dbQueue.write { db in try Document.deleteOne(db, key: id) }
    }
}

public struct ChatRepository: Sendable {
    let db: LoreDatabase
    public init(_ db: LoreDatabase) { self.db = db }

    public func chats(inProject projectID: UUID) async throws -> [Chat] {
        try await db.dbQueue.read { db in
            try Chat
                .filter(Column("projectID") == projectID)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    public func save(_ chat: Chat) async throws {
        try await db.dbQueue.write { db in try chat.save(db) }
    }

    public func delete(id: UUID) async throws {
        _ = try await db.dbQueue.write { db in try Chat.deleteOne(db, key: id) }
    }

    public func messages(inChat chatID: UUID) async throws -> [Message] {
        try await db.dbQueue.read { db in
            try Message
                .filter(Column("chatID") == chatID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func add(_ message: Message) async throws {
        try await db.dbQueue.write { db in try message.save(db) }
    }
}

// MARK: - Chat memory

struct MemoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory"
    var id: UUID
    var projectID: UUID
    var chatID: UUID?
    var role: String
    var text: String
    var vector: Data
    var createdAt: Date
}

/// A retrievable snippet of earlier conversation.
public struct MemoryItem: Sendable {
    public let id: UUID
    public let role: String
    public let text: String
    public let vector: [Float]
}

public struct MemoryRepository: Sendable {
    let db: LoreDatabase
    public init(_ db: LoreDatabase) { self.db = db }

    public func insert(projectID: UUID, chatID: UUID?, role: String, text: String, embedding: [Float]) async throws {
        let record = MemoryRecord(
            id: UUID(), projectID: projectID, chatID: chatID, role: role, text: text,
            vector: VectorCodec.encode(embedding), createdAt: Date()
        )
        try await db.dbQueue.write { db in try record.insert(db) }
    }

    /// All memory items for a project (small volume → ranked in memory).
    public func all(projectID: UUID) async throws -> [MemoryItem] {
        try await db.dbQueue.read { db in
            try MemoryRecord
                .filter(Column("projectID") == projectID)
                .fetchAll(db)
                .map { MemoryItem(id: $0.id, role: $0.role, text: $0.text, vector: VectorCodec.decode($0.vector)) }
        }
    }
}

/// A chunk retrieved for RAG, paired with its embedding vector.
public struct EmbeddedChunk: Sendable {
    public let id: UUID
    public let vector: [Float]
    public init(id: UUID, vector: [Float]) {
        self.id = id
        self.vector = vector
    }
}

public struct ChunkRepository: Sendable {
    let db: LoreDatabase
    public init(_ db: LoreDatabase) { self.db = db }

    /// Insert a chunk together with its embedding + keyword index entry, atomically.
    public func insert(_ chunk: Chunk, projectID: UUID, embedding: [Float]) async throws {
        try await db.dbQueue.write { db in
            try chunk.insert(db)
            let row = EmbeddingRow(
                chunkID: chunk.id.uuidString,
                projectID: projectID.uuidString,
                model: chunk.embeddingModel ?? "",
                dim: chunk.embeddingDimensions ?? embedding.count,
                vector: VectorCodec.encode(embedding)
            )
            try row.insert(db)
            try db.execute(
                sql: "INSERT INTO chunk_fts (chunkID, projectID, text) VALUES (?, ?, ?)",
                arguments: [chunk.id.uuidString, projectID.uuidString, chunk.text]
            )
        }
    }

    /// Remove all chunks (and their embeddings / keyword entries) for a document.
    public func deleteChunks(documentID: UUID) async throws {
        try await db.dbQueue.write { db in
            let ids = try UUID.fetchAll(
                db,
                sql: "SELECT id FROM chunk WHERE documentID = ?",
                arguments: [documentID]
            )
            let uuidStrings = ids.map(\.uuidString)
            try Chunk.filter(Column("documentID") == documentID).deleteAll(db)
            for s in uuidStrings {
                try db.execute(sql: "DELETE FROM chunk_embedding WHERE chunkID = ?", arguments: [s])
                try db.execute(sql: "DELETE FROM chunk_fts WHERE chunkID = ?", arguments: [s])
            }
        }
    }

    public func chunks(ids: [UUID]) async throws -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        return try await db.dbQueue.read { db in
            try Chunk.filter(keys: ids).fetchAll(db)
        }
    }

    public func chunkCount(projectID: UUID) async throws -> Int {
        try await db.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chunk_embedding WHERE projectID = ?",
                arguments: [projectID.uuidString]
            ) ?? 0
        }
    }

    // MARK: - Retrieval

    /// All embeddings for a project (brute-force vector search candidate set).
    public func embeddings(projectID: UUID) async throws -> [EmbeddedChunk] {
        try await db.dbQueue.read { db in
            let rows = try EmbeddingRow
                .filter(Column("projectID") == projectID.uuidString)
                .fetchAll(db)
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row.chunkID) else { return nil }
                return EmbeddedChunk(id: id, vector: VectorCodec.decode(row.vector))
            }
        }
    }

    /// Keyword (FTS5) search within a project. Returns chunk ids best-first.
    public func keywordSearch(projectID: UUID, query: String, limit: Int) async throws -> [UUID] {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty else { return [] }
        return try await db.dbQueue.read { db in
            let strings = try String.fetchAll(
                db,
                sql: """
                SELECT chunkID FROM chunk_fts
                WHERE projectID = ? AND chunk_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                arguments: [projectID.uuidString, match, limit]
            )
            return strings.compactMap(UUID.init(uuidString:))
        }
    }

    /// Turn free text into a safe FTS5 MATCH expression: quote each term and OR
    /// them together, so punctuation in the user's question can't break parsing.
    static func ftsQuery(from text: String) -> String {
        let terms = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !terms.isEmpty else { return "" }
        return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}
