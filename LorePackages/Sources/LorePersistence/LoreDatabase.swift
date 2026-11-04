import Foundation
import GRDB

/// Owns the SQLite connection and schema migrations for Lore.
///
/// A single `DatabaseQueue` serializes writes (fine for a single-user desktop
/// app) while allowing concurrent reads. All schema changes ship as ordered,
/// named migrations so existing stores upgrade forward safely.
public final class LoreDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    /// Opens (creating if needed) the on-disk store at `url`.
    public init(url: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory store for tests.
    public init(inMemory: Bool) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// The default on-disk location: `lore.sqlite` in the data folder, which is
    /// ~/Library/Application Support/Lore/ unless `LORE_DATA_DIR` overrides it
    /// (see `LoreDataDirectory`).
    public static func defaultURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        try LoreDataDirectory.url(fileManager: fileManager, environment: environment)
            .appendingPathComponent("lore.sqlite")
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // During development, wipe & rebuild if a migration definition changes.
        // Removed before shipping migrations to real users.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1-initial") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull()
                t.column("colorTint", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("systemPrompt", .text)
                t.column("chatModel", .text)
                t.column("embeddingModel", .text)
            }

            try db.create(table: "document") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("projectID", .blob).notNull()
                    .references("project", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("sourceURL", .text)
                t.column("fileBookmark", .blob)
                t.column("addedAt", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("pageCount", .integer)
                t.column("contentHash", .text)
                t.column("metadata", .text).notNull().defaults(to: "{}")
            }
            try db.create(index: "document_projectID", on: "document", columns: ["projectID"])

            try db.create(table: "chunk") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("documentID", .blob).notNull()
                    .references("document", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("page", .integer)
                t.column("tokenCount", .integer).notNull()
                t.column("embeddingModel", .text)
                t.column("embeddingDimensions", .integer)
            }
            try db.create(index: "chunk_documentID", on: "chunk", columns: ["documentID"])

            // Embeddings kept in their own table (keeps the chunk row light, and
            // makes a future swap to sqlite-vec a localized change). projectID is
            // denormalized here so vector candidates can be scoped without a join.
            try db.create(table: "chunk_embedding") { t in
                t.primaryKey("chunkID", .text).notNull()
                t.column("projectID", .text).notNull()
                t.column("model", .text).notNull()
                t.column("dim", .integer).notNull()
                t.column("vector", .blob).notNull()
            }
            try db.create(index: "chunk_embedding_projectID", on: "chunk_embedding", columns: ["projectID"])

            // FTS5 keyword index. Standalone (not external-content) so it is not
            // coupled to integer rowids; chunkID/projectID are stored UNINDEXED.
            try db.create(virtualTable: "chunk_fts", using: FTS5()) { t in
                t.column("chunkID").notIndexed()
                t.column("projectID").notIndexed()
                t.column("text")
            }

            try db.create(table: "chat") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("projectID", .blob).notNull()
                    .references("project", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "chat_projectID", on: "chat", columns: ["projectID"])

            try db.create(table: "message") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("chatID", .blob).notNull()
                    .references("chat", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("citations", .text).notNull().defaults(to: "[]")
            }
            try db.create(index: "message_chatID", on: "message", columns: ["chatID"])
        }

        migrator.registerMigration("v2-chat-memory") { db in
            // Past chat messages, embedded, so earlier conversations become
            // retrievable project knowledge. Vector stored inline (small volume).
            try db.create(table: "memory") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("projectID", .blob).notNull()
                    .references("project", onDelete: .cascade)
                t.column("chatID", .blob)
                    .references("chat", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("vector", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "memory_projectID", on: "memory", columns: ["projectID"])
        }

        return migrator
    }
}

// MARK: - Vector <-> BLOB codec

public enum VectorCodec {
    /// Encode a float vector as a little-endian Float32 BLOB.
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decode a Float32 BLOB back into a vector.
    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
