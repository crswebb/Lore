import Foundation

// MARK: - Domain models
//
// These are transport/value types shared across modules. The persistence layer
// (GRDB) will map these to/from SQLite; the UI reads them via repositories.
// They deliberately carry no framework dependencies so every module can use them.

/// A knowledge project: a named collection of documents and chats.
public struct Project: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    /// SF Symbol name or emoji used as the project glyph.
    public var icon: String
    /// Hex tint (e.g. "#4F8EF7") applied to the project in the sidebar.
    public var colorTint: String
    public var createdAt: Date
    /// Optional per-project override of the assistant's system prompt.
    public var systemPrompt: String?
    /// Optional per-project chat model override (else the app default is used).
    public var chatModel: String?
    /// Embedding model used for this project's chunks (drives re-embed detection).
    public var embeddingModel: String?

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder",
        colorTint: String = "#4F8EF7",
        createdAt: Date = Date(),
        systemPrompt: String? = nil,
        chatModel: String? = nil,
        embeddingModel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorTint = colorTint
        self.createdAt = createdAt
        self.systemPrompt = systemPrompt
        self.chatModel = chatModel
        self.embeddingModel = embeddingModel
    }
}

/// The kind of source a document was ingested from.
public enum DocumentKind: String, Hashable, Sendable, Codable, CaseIterable {
    case pdf
    case webLink
    case text
    case markdown
}

/// Ingestion lifecycle of a document.
public enum DocumentStatus: String, Hashable, Sendable, Codable {
    case pending      // added, not yet processed
    case extracting   // pulling text out of the source
    case chunking
    case embedding
    case ready
    case failed
}

/// A source document within a project.
public struct Document: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var projectID: UUID
    public var kind: DocumentKind
    public var title: String
    /// Present for `.webLink`.
    public var sourceURL: URL?
    /// Security-scoped bookmark data for user-selected files (`.pdf`/`.text`/`.markdown`).
    public var fileBookmark: Data?
    public var addedAt: Date
    public var status: DocumentStatus
    public var pageCount: Int?
    /// Hash of the extracted content, used to skip unchanged re-ingests.
    public var contentHash: String?
    /// Structured facts (vendor, purchaseDate, warrantyUntil, …).
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        kind: DocumentKind,
        title: String,
        sourceURL: URL? = nil,
        fileBookmark: Data? = nil,
        addedAt: Date = Date(),
        status: DocumentStatus = .pending,
        pageCount: Int? = nil,
        contentHash: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.title = title
        self.sourceURL = sourceURL
        self.fileBookmark = fileBookmark
        self.addedAt = addedAt
        self.status = status
        self.pageCount = pageCount
        self.contentHash = contentHash
        self.metadata = metadata
    }
}

/// A retrievable chunk of a document, with its embedding metadata.
public struct Chunk: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var documentID: UUID
    public var ordinal: Int
    public var text: String
    /// Source page for citations (PDFs).
    public var page: Int?
    public var tokenCount: Int
    /// Name of the embedding model that produced `embedding` (for re-embed detection).
    public var embeddingModel: String?
    public var embeddingDimensions: Int?

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        ordinal: Int,
        text: String,
        page: Int? = nil,
        tokenCount: Int,
        embeddingModel: String? = nil,
        embeddingDimensions: Int? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.text = text
        self.page = page
        self.tokenCount = tokenCount
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
    }
}

// MARK: - Chat

public enum MessageRole: String, Hashable, Sendable, Codable {
    case system
    case user
    case assistant
}

/// A pointer from an assistant message back to the source it was grounded in.
public struct Citation: Hashable, Sendable, Codable, Identifiable {
    public var documentID: UUID
    public var chunkID: UUID
    public var page: Int?

    /// Stable identity for SwiftUI (the chunk a citation points at is unique).
    public var id: UUID { chunkID }

    public init(documentID: UUID, chunkID: UUID, page: Int? = nil) {
        self.documentID = documentID
        self.chunkID = chunkID
        self.page = page
    }
}

public struct Message: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var chatID: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var citations: [Citation]

    public init(
        id: UUID = UUID(),
        chatID: UUID,
        role: MessageRole,
        text: String,
        createdAt: Date = Date(),
        citations: [Citation] = []
    ) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.citations = citations
    }
}

public struct Chat: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String = "New Chat",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
    }
}
