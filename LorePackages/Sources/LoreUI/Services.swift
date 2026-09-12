import Foundation
import CryptoKit
import LoreCore
import LorePersistence
import LoreProviders
import LoreIngestion
import LoreRAG

// MARK: - Settings

/// User preferences, backed by UserDefaults.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var chatModel: String {
        didSet { defaults.set(chatModel, forKey: "chatModel") }
    }
    public var embeddingModel: String {
        didSet { defaults.set(embeddingModel, forKey: "embeddingModel") }
    }
    public var ollamaBaseURLString: String {
        didSet { defaults.set(ollamaBaseURLString, forKey: "ollamaBaseURL") }
    }
    public var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") }
    }
    /// 0 = solid window, 1 = maximally translucent (desktop shows through).
    public var windowTranslucency: Double {
        didSet { defaults.set(windowTranslucency, forKey: "windowTranslucency") }
    }

    /// Where chat generation runs. Embeddings always run locally via Ollama.
    public enum ChatSource: String, CaseIterable, Sendable {
        case ollama    // local Ollama model
        case apple     // Apple Intelligence (on-device)
        case external  // OpenAI-compatible API
    }
    public var chatSource: ChatSource {
        didSet { defaults.set(chatSource.rawValue, forKey: "chatSource") }
    }
    public var externalBaseURLString: String {
        didSet { defaults.set(externalBaseURLString, forKey: "externalBaseURL") }
    }
    public var externalChatModel: String {
        didSet { defaults.set(externalChatModel, forKey: "externalChatModel") }
    }
    /// API key, stored in the Keychain (not UserDefaults).
    public var externalAPIKey: String {
        get { Keychain.get("externalAPIKey") ?? "" }
        set { Keychain.set(newValue, account: "externalAPIKey") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.chatModel = defaults.string(forKey: "chatModel") ?? OllamaModelCatalog.chatModels[0].name
        self.embeddingModel = defaults.string(forKey: "embeddingModel") ?? OllamaModelCatalog.defaultEmbeddingModel
        self.ollamaBaseURLString = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self.onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        self.windowTranslucency = (defaults.object(forKey: "windowTranslucency") as? Double) ?? 0.25
        self.externalBaseURLString = defaults.string(forKey: "externalBaseURL") ?? "https://api.openai.com/v1"
        self.externalChatModel = defaults.string(forKey: "externalChatModel") ?? "gpt-4o-mini"
        if let raw = defaults.string(forKey: "chatSource"), let source = ChatSource(rawValue: raw) {
            self.chatSource = source
        } else {
            // Migrate the old boolean.
            self.chatSource = defaults.bool(forKey: "useExternalAPI") ? .external : .ollama
        }
    }

    /// The external API is fully filled in (used only when chatSource == .external).
    public var externalConfigured: Bool {
        URL(string: externalBaseURLString) != nil
            && !externalAPIKey.isEmpty
            && !externalChatModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var ollamaBaseURL: URL {
        URL(string: ollamaBaseURLString) ?? URL(string: "http://localhost:11434")!
    }
}

// MARK: - Helpers

enum ContentHash {
    static func of(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Resolves a document back to a readable file URL, handling security-scoped
/// bookmarks (sandboxed) and falling back to a stored path (dev / unsandboxed).
struct FileAccess {
    static func resolve(bookmark: Data?, fallback: URL?) -> (url: URL, stopAccess: () -> Void)? {
        if let bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let didAccess = url.startAccessingSecurityScopedResource()
                return (url, { if didAccess { url.stopAccessingSecurityScopedResource() } })
            }
        }
        if let fallback { return (fallback, {}) }
        return nil
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

// MARK: - Indexing

/// Extracts, chunks, embeds, and stores a document's content.
public struct IndexingService: Sendable {
    let documents: DocumentRepository
    let chunks: ChunkRepository
    let embedder: any EmbeddingProvider
    let chunker: Chunker

    public init(documents: DocumentRepository, chunks: ChunkRepository, embedder: any EmbeddingProvider) {
        self.documents = documents
        self.chunks = chunks
        self.embedder = embedder
        self.chunker = Chunker()
    }

    /// Index (or re-index) a document. Progress is reflected in `document.status`.
    /// Returns the extracted full text (so callers can run fact extraction on it).
    @discardableResult
    public func index(_ document: Document) async throws -> String {
        var doc = document
        do {
            // 1. Extract.
            doc.status = .extracting
            try await documents.save(doc)
            let content = try await extract(doc)

            // 2. Chunk (per page so PDF citations carry a page number).
            doc.status = .chunking
            try await documents.save(doc)
            var drafts: [ChunkDraft] = []
            var ordinal = 0
            for page in content.pages {
                let pageDrafts = chunker.chunk(page.text, page: page.pageNumber, startingOrdinal: ordinal)
                drafts.append(contentsOf: pageDrafts)
                ordinal += pageDrafts.count
            }
            guard !drafts.isEmpty else { throw IngestionError.emptyContent }

            // 3. Embed + store. Clear any prior chunks first (re-index safety).
            doc.status = .embedding
            try await documents.save(doc)
            try await chunks.deleteChunks(documentID: doc.id)

            let vectors = try await embedder.embed(drafts.map(\.text))
            guard vectors.count == drafts.count else {
                throw IndexingError.embeddingCountMismatch
            }
            for (draft, vector) in zip(drafts, vectors) {
                let chunk = Chunk(
                    documentID: doc.id,
                    ordinal: draft.ordinal,
                    text: draft.text,
                    page: draft.page,
                    tokenCount: draft.approximateTokenCount,
                    embeddingModel: embedder.model,
                    embeddingDimensions: embedder.dimensions
                )
                try await chunks.insert(chunk, projectID: doc.projectID, embedding: vector)
            }

            // 4. Finalize.
            doc.title = doc.title.isEmpty ? content.title : doc.title
            doc.pageCount = content.pageCount
            doc.contentHash = ContentHash.of(content.fullText)
            doc.status = .ready
            try await documents.save(doc)
            return content.fullText
        } catch {
            doc.status = .failed
            try? await documents.save(doc)
            throw error
        }
    }

    private func extract(_ doc: Document) async throws -> ExtractedContent {
        switch doc.kind {
        case .webLink:
            guard let url = doc.sourceURL else { throw IngestionError.emptyContent }
            return try await WebExtractor().extract(url: url)
        case .pdf:
            guard let access = FileAccess.resolve(bookmark: doc.fileBookmark, fallback: doc.sourceURL) else {
                throw IngestionError.emptyContent
            }
            defer { access.stopAccess() }
            return try PDFExtractor().extract(fileURL: access.url)
        case .text, .markdown:
            guard let access = FileAccess.resolve(bookmark: doc.fileBookmark, fallback: doc.sourceURL) else {
                throw IngestionError.emptyContent
            }
            defer { access.stopAccess() }
            return try TextExtractor().extract(fileURL: access.url)
        }
    }
}

public enum IndexingError: Error, LocalizedError {
    case embeddingCountMismatch

    public var errorDescription: String? {
        switch self {
        case .embeddingCountMismatch: return "The embedding model returned an unexpected number of vectors."
        }
    }
}

// MARK: - Retrieval

public struct RetrievalResult: Sendable {
    public let passages: [RetrievedPassage]
    public let citations: [Citation]
    public let metadata: [String: String]
    /// Every document in the project (title + facts) so aggregate questions like
    /// "what do I have?" see the full picture, not just the top passages.
    public let library: [LibraryItem]
    /// Relevant snippets from earlier conversations in this project.
    public let memoryNotes: [String]
}

/// Hybrid retrieval: dense vector + keyword FTS, fused with RRF.
public struct RetrievalService: Sendable {
    let chunks: ChunkRepository
    let documents: DocumentRepository
    let memory: MemoryRepository?
    let embedder: any EmbeddingProvider
    let topK: Int
    let candidatePool: Int

    public init(
        chunks: ChunkRepository,
        documents: DocumentRepository,
        memory: MemoryRepository? = nil,
        embedder: any EmbeddingProvider,
        topK: Int = 6
    ) {
        self.chunks = chunks
        self.documents = documents
        self.memory = memory
        self.embedder = embedder
        self.topK = topK
        self.candidatePool = topK * 4
    }

    public func retrieve(projectID: UUID, question: String) async throws -> RetrievalResult {
        // Full project inventory — always provided to the model.
        let allDocuments = try await documents.documents(inProject: projectID)
        let library = allDocuments.map { LibraryItem(title: $0.title, facts: $0.metadata) }

        let queryVector = try await embedder.embed(question)

        // Relevant snippets from earlier conversations (best-effort).
        var memoryNotes: [String] = []
        if let memory, let items = try? await memory.all(projectID: projectID), !items.isEmpty {
            memoryNotes = items
                .map { (item: $0, score: VectorSearch.cosineSimilarity(queryVector, $0.vector)) }
                .filter { $0.score > 0.4 }
                .sorted { $0.score > $1.score }
                .prefix(3)
                .map { entry in
                    let who = entry.item.role == "user" ? "You said" : "Earlier answer"
                    return "\(who): \(entry.item.text.prefix(300))"
                }
        }

        async let embeddingsTask = chunks.embeddings(projectID: projectID)
        async let keywordTask = chunks.keywordSearch(projectID: projectID, query: question, limit: candidatePool)
        let (embedded, keywordIDs) = try await (embeddingsTask, keywordTask)

        let vectorIDs = VectorSearch.rank(
            query: queryVector,
            candidates: embedded.map { (id: $0.id, vector: $0.vector) },
            topN: candidatePool
        )

        let fused = ReciprocalRankFusion().fuse([vectorIDs, keywordIDs])
        let selected = Array(fused.prefix(topK))
        guard !selected.isEmpty else {
            return RetrievalResult(passages: [], citations: [], metadata: [:], library: library, memoryNotes: memoryNotes)
        }

        // Fetch chunk rows and restore fused order.
        let fetched = try await chunks.chunks(ids: selected)
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        let orderedChunks = selected.compactMap { byID[$0] }

        // Resolve document titles + metadata for citations.
        let docIDs = Set(orderedChunks.map(\.documentID))
        var docs: [UUID: Document] = [:]
        for id in docIDs {
            if let doc = try await documents.document(id: id) { docs[id] = doc }
        }

        var passages: [RetrievedPassage] = []
        var citations: [Citation] = []
        var metadata: [String: String] = [:]
        for (offset, chunk) in orderedChunks.enumerated() {
            let doc = docs[chunk.documentID]
            passages.append(RetrievedPassage(
                index: offset + 1,
                sourceTitle: doc?.title ?? "Document",
                page: chunk.page,
                text: chunk.text
            ))
            citations.append(Citation(documentID: chunk.documentID, chunkID: chunk.id, page: chunk.page))
            if let docMeta = doc?.metadata {
                metadata.merge(docMeta) { _, new in new }
            }
        }

        return RetrievalResult(passages: passages, citations: citations, metadata: metadata, library: library, memoryNotes: memoryNotes)
    }
}

// MARK: - Chat

public struct AnswerHandle: Sendable {
    public let citations: [Citation]
    public let passages: [RetrievedPassage]
    public let stream: AsyncThrowingStream<ChatToken, Error>
}

/// Ties retrieval + prompt building + the model together for one answer.
public struct ChatService: Sendable {
    let retrieval: RetrievalService
    let llm: any LLMProvider
    let promptBuilder = PromptBuilder()

    public init(retrieval: RetrievalService, llm: any LLMProvider) {
        self.retrieval = retrieval
        self.llm = llm
    }

    public func prepareAnswer(
        project: Project,
        model: String,
        history: [ChatTurn],
        question: String
    ) async throws -> AnswerHandle {
        let result = try await retrieval.retrieve(projectID: project.id, question: question)
        let messages = promptBuilder.build(
            projectSystemPrompt: project.systemPrompt,
            library: result.library,
            passages: result.passages,
            metadata: result.metadata,
            memories: result.memoryNotes,
            history: history,
            question: question
        )
        let stream = llm.chat(ChatRequest(model: model, messages: messages))
        return AnswerHandle(citations: result.citations, passages: result.passages, stream: stream)
    }
}

// MARK: - Metadata extraction (M6)

/// Best-effort structured-fact extraction: asks the chat model to pull vendor /
/// purchase date / warranty etc. out of a document, as JSON. Failures are
/// swallowed by the caller — this only ever *adds* facts, never blocks ingest.
public struct MetadataExtractor: Sendable {
    let llm: any LLMProvider

    public init(llm: any LLMProvider) { self.llm = llm }

    /// Fields we try to populate. Kept small and practical.
    public static let fields = ["vendor", "purchaseDate", "warrantyUntil", "model", "serialNumber", "products"]

    public func extract(text: String, model: String) async throws -> [String: String] {
        let snippet = String(text.prefix(4000))
        let system = "You extract structured facts from documents. Output ONLY a minified JSON object, no prose, no code fences."
        let prompt = """
        From the document below, extract any of these fields that are clearly present:
        - vendor (store or seller name)
        - purchaseDate (ISO 8601 yyyy-mm-dd)
        - warrantyUntil (ISO 8601 yyyy-mm-dd; if the document gives a purchase date and a warranty length, compute the end date)
        - model (model name/number of the MAIN product, if there is a single clear one)
        - serialNumber
        - products (a JSON array of EVERY distinct product or line item the document lists — for an invoice or receipt with several items, include them ALL, by their product names)
        Return a JSON object containing ONLY the fields you actually found. If none, return {}.

        Document:
        \(snippet)
        """
        let request = ChatRequest(
            model: model,
            messages: [ChatTurn(role: .system, content: system), ChatTurn(role: .user, content: prompt)],
            temperature: 0
        )
        var raw = ""
        for try await token in llm.chat(request) {
            if token.isDone { break }
            raw += token.text
        }
        return Self.parse(raw)
    }

    /// Pull the first JSON object out of the model's reply and flatten it to strings.
    static func parse(_ raw: String) -> [String: String] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return [:]
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var result: [String: String] = [:]
        for (key, value) in object {
            let string: String
            switch value {
            case let s as String: string = s
            case let n as NSNumber: string = n.stringValue
            case let array as [Any]:
                // e.g. `products`: join line items into one readable string.
                string = array.compactMap { element -> String? in
                    if let s = element as? String { return s }
                    if let n = element as? NSNumber { return n.stringValue }
                    return nil
                }.joined(separator: "; ")
            default: continue
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.lowercased() != "null", fields.contains(key) {
                result[key] = trimmed
            }
        }
        return result
    }
}

// MARK: - Ollama setup

/// Health + model management for the setup wizard.
public struct OllamaSetupService: Sendable {
    let provider: OllamaProvider

    public init(provider: OllamaProvider) {
        self.provider = provider
    }

    /// Known Homebrew / installer locations for the `ollama` binary.
    private static let binaryPaths = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]

    public func health() async -> ProviderHealth {
        let health = await provider.availability()
        if case .installedNotRunning = health {
            let installed = Self.binaryPaths.contains { FileManager.default.fileExists(atPath: $0) }
            return installed ? .installedNotRunning : .notInstalled
        }
        return health
    }

    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        provider.pull(model: model)
    }
}
