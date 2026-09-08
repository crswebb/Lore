import Foundation
import Observation
import LoreCore
import LorePersistence
import LoreProviders
import LoreRAG

/// The app's single source of truth: owns the database, providers, and services,
/// and exposes the UI-facing state. `@MainActor` so all published mutations are
/// safe to bind from SwiftUI; the async service calls it makes hop off-main.
@MainActor
@Observable
public final class AppModel {
    // Composition
    @ObservationIgnored let database: LoreDatabase
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored var projectsRepo: ProjectRepository
    @ObservationIgnored var documentsRepo: DocumentRepository
    @ObservationIgnored var chatsRepo: ChatRepository
    @ObservationIgnored var chunksRepo: ChunkRepository
    @ObservationIgnored var setupService: OllamaSetupService
    @ObservationIgnored var embedder: OllamaEmbeddingProvider
    @ObservationIgnored var llm: OllamaProvider
    @ObservationIgnored var indexing: IndexingService
    @ObservationIgnored var chatService: ChatService

    // UI state
    public var projects: [Project] = []
    public var selectedProjectID: UUID?
    public var documents: [Document] = []
    public var chats: [Chat] = []
    public var selectedChatID: UUID?
    public var messages: [Message] = []

    public var health: ProviderHealth = .installedNotRunning
    public var showSetup = false
    public var isResponding = false
    public var errorMessage: String?
    public var indexingDocumentIDs: Set<UUID> = []

    public var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    public init() throws {
        let db = try LoreDatabase(url: try LoreDatabase.defaultURL())
        self.database = db
        let settings = SettingsStore()
        self.settings = settings

        self.projectsRepo = ProjectRepository(db)
        self.documentsRepo = DocumentRepository(db)
        self.chatsRepo = ChatRepository(db)
        self.chunksRepo = ChunkRepository(db)

        let base = settings.ollamaBaseURL
        let llm = OllamaProvider(baseURL: base)
        let embedder = OllamaEmbeddingProvider(
            baseURL: base,
            model: settings.embeddingModel,
            dimensions: OllamaModelCatalog.embeddingDimensions
        )
        self.llm = llm
        self.embedder = embedder
        self.setupService = OllamaSetupService(provider: llm)
        self.indexing = IndexingService(documents: documentsRepo, chunks: chunksRepo, embedder: embedder)
        let retrieval = RetrievalService(chunks: chunksRepo, documents: documentsRepo, embedder: embedder)
        self.chatService = ChatService(retrieval: retrieval, llm: llm)
    }

    // MARK: Bootstrap

    public func bootstrap() async {
        await refreshProjects()
        if let first = projects.first { await select(project: first.id) }
        await refreshHealth()
        showSetup = !settings.onboardingComplete || !modelsReady
    }

    public func refreshHealth() async {
        health = await setupService.health()
    }

    public var modelsReady: Bool {
        guard case let .ready(models) = health else { return false }
        return Self.modelPresent(settings.embeddingModel, in: models)
            && Self.modelPresent(settings.chatModel, in: models)
    }

    static func modelPresent(_ name: String, in list: [String]) -> Bool {
        list.contains { $0 == name || $0.hasPrefix(name + ":") || name.hasPrefix($0 + ":") }
    }

    // MARK: Projects

    public func refreshProjects() async {
        do { projects = try await projectsRepo.all() }
        catch { report(error) }
    }

    public func createProject(name: String, icon: String = "folder.fill", tint: String) async {
        let project = Project(name: name, icon: icon, colorTint: tint, embeddingModel: settings.embeddingModel)
        do {
            try await projectsRepo.save(project)
            await refreshProjects()
            await select(project: project.id)
        } catch { report(error) }
    }

    public func deleteProject(_ id: UUID) async {
        do {
            try await projectsRepo.delete(id: id)
            if selectedProjectID == id { selectedProjectID = nil; documents = []; chats = []; messages = [] }
            await refreshProjects()
            if let first = projects.first { await select(project: first.id) }
        } catch { report(error) }
    }

    public func updateProject(_ project: Project) async {
        do { try await projectsRepo.save(project); await refreshProjects() }
        catch { report(error) }
    }

    public func select(project id: UUID) async {
        selectedProjectID = id
        await refreshDocuments()
        await refreshChats()
        if let latest = chats.first {
            await select(chat: latest.id)
        } else {
            await newChat()
        }
    }

    // MARK: Documents

    public func refreshDocuments() async {
        guard let pid = selectedProjectID else { documents = []; return }
        do { documents = try await documentsRepo.documents(inProject: pid) }
        catch { report(error) }
    }

    public func addFiles(_ urls: [URL]) async {
        guard let pid = selectedProjectID else { return }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let kind: DocumentKind = ext == "pdf" ? .pdf : (ext == "md" || ext == "markdown" ? .markdown : .text)
            let doc = Document(
                projectID: pid,
                kind: kind,
                title: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                fileBookmark: FileAccess.makeBookmark(for: url)
            )
            await add(doc)
        }
    }

    public func addWebLink(_ url: URL) async {
        guard let pid = selectedProjectID else { return }
        let doc = Document(projectID: pid, kind: .webLink, title: url.host ?? url.absoluteString, sourceURL: url)
        await add(doc)
    }

    private func add(_ document: Document) async {
        do {
            try await documentsRepo.save(document)
            await refreshDocuments()
            await runIndexing(document)
        } catch { report(error) }
    }

    public func reindex(_ document: Document) async {
        await runIndexing(document)
    }

    private func runIndexing(_ document: Document) async {
        indexingDocumentIDs.insert(document.id)
        defer { indexingDocumentIDs.remove(document.id) }
        do {
            try await indexing.index(document)
        } catch {
            report(error)
        }
        await refreshDocuments()
    }

    public func deleteDocument(_ id: UUID) async {
        do {
            try await chunksRepo.deleteChunks(documentID: id)
            try await documentsRepo.delete(id: id)
            await refreshDocuments()
        } catch { report(error) }
    }

    public func setMetadata(_ metadata: [String: String], for document: Document) async {
        var doc = document
        doc.metadata = metadata
        do { try await documentsRepo.save(doc); await refreshDocuments() }
        catch { report(error) }
    }

    // MARK: Chats

    public func refreshChats() async {
        guard let pid = selectedProjectID else { chats = []; return }
        do { chats = try await chatsRepo.chats(inProject: pid) }
        catch { report(error) }
    }

    public func newChat() async {
        guard let pid = selectedProjectID else { return }
        let chat = Chat(projectID: pid)
        do {
            try await chatsRepo.save(chat)
            await refreshChats()
            await select(chat: chat.id)
        } catch { report(error) }
    }

    public func select(chat id: UUID) async {
        selectedChatID = id
        await refreshMessages()
    }

    public func deleteChat(_ id: UUID) async {
        do {
            try await chatsRepo.delete(id: id)
            if selectedChatID == id { selectedChatID = nil; messages = [] }
            await refreshChats()
            if let first = chats.first { await select(chat: first.id) } else { await newChat() }
        } catch { report(error) }
    }

    public func refreshMessages() async {
        guard let cid = selectedChatID else { messages = []; return }
        do { messages = try await chatsRepo.messages(inChat: cid) }
        catch { report(error) }
    }

    // MARK: Ask

    public func send(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let project = selectedProject, let chatID = selectedChatID, !isResponding else { return }
        isResponding = true
        defer { isResponding = false }

        let userMessage = Message(chatID: chatID, role: .user, text: trimmed)
        messages.append(userMessage)
        try? await chatsRepo.add(userMessage)

        // Rename a fresh chat after its first question.
        if messages.filter({ $0.role == .user }).count == 1 {
            await renameChatFromFirstQuestion(chatID: chatID, question: trimmed)
        }

        let history = Array(messages.dropLast())
            .suffix(6)
            .map { ChatTurn(role: $0.role, content: $0.text) }

        var assistant = Message(chatID: chatID, role: .assistant, text: "")
        messages.append(assistant)
        let assistantIndex = messages.count - 1

        do {
            let handle = try await chatService.prepareAnswer(
                project: project,
                model: settings.chatModel,
                history: history,
                question: trimmed
            )
            assistant.citations = handle.citations
            messages[assistantIndex].citations = handle.citations

            for try await token in handle.stream {
                if token.isDone { break }
                assistant.text += token.text
                messages[assistantIndex].text = assistant.text
            }
            try? await chatsRepo.add(assistant)
        } catch {
            messages[assistantIndex].text = "⚠️ \(error.localizedDescription)"
            report(error)
        }
    }

    private func renameChatFromFirstQuestion(chatID: UUID, question: String) async {
        guard var chat = chats.first(where: { $0.id == chatID }) else { return }
        chat.title = String(question.prefix(40))
        try? await chatsRepo.save(chat)
        await refreshChats()
    }

    // MARK: Setup

    public func completeSetup() {
        settings.onboardingComplete = true
        showSetup = false
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
