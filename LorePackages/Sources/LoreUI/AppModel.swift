import Foundation
import Observation
import LoreCore
import LorePersistence
import LoreProviders
import LoreIngestion
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
    @ObservationIgnored var memoryRepo: MemoryRepository
    @ObservationIgnored var setupService: OllamaSetupService
    @ObservationIgnored var embedder: OllamaEmbeddingProvider
    @ObservationIgnored var llm: OllamaProvider
    @ObservationIgnored var indexing: IndexingService
    @ObservationIgnored var chatService: ChatService
    @ObservationIgnored var metadataExtractor: MetadataExtractor

    // UI state
    public var projects: [Project] = []
    public var selectedProjectID: UUID?
    public var documents: [Document] = []
    public var chats: [Chat] = []
    public var selectedChatID: UUID?
    public var messages: [Message] = []

    public var health: ProviderHealth = .installedNotRunning
    public var showSetup = false
    public var showDocuments = false          // documents inspector, hidden by default
    public var isResponding = false
    public var errorMessage: String?
    public var indexingDocumentIDs: Set<UUID> = []

    // Manual-fetch flow
    @ObservationIgnored let manualFinder = ManualFinderService()
    public var manualPrompt: ManualPrompt?
    public var showManualResults = false
    public var webResultsHeading = "User manuals"
    public var manualSearching = false
    public var manualCandidates: [ManualCandidate] = []
    public var addedManualURLs: Set<URL> = []
    @ObservationIgnored private var manualQuery = ""

    public struct ManualPrompt: Identifiable, Sendable {
        public let id = UUID()
        public let productLabel: String
        public let query: String
    }

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
        self.memoryRepo = MemoryRepository(db)

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
        let retrieval = RetrievalService(chunks: chunksRepo, documents: documentsRepo, memory: memoryRepo, embedder: embedder)
        self.chatService = ChatService(retrieval: retrieval, llm: llm)
        self.metadataExtractor = MetadataExtractor(llm: llm)
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

    public func renameProject(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var project = projects.first(where: { $0.id == id }) else { return }
        project.name = trimmed
        await updateProject(project)
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

    public func addWebLink(_ url: URL, title: String? = nil) async {
        guard let pid = selectedProjectID else { return }
        let doc = Document(projectID: pid, kind: .webLink, title: title ?? url.host ?? url.absoluteString, sourceURL: url)
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
            let text = try await indexing.index(document)
            await extractFacts(for: document.id, text: text)
        } catch {
            report(error)
        }
        await refreshDocuments()
    }

    /// Best-effort: fill in structured facts the user hasn't already set.
    private func extractFacts(for documentID: UUID, text: String) async {
        guard !text.isEmpty else { return }
        do {
            let facts = try await metadataExtractor.extract(text: text, model: settings.chatModel)
            guard !facts.isEmpty, var doc = try await documentsRepo.document(id: documentID) else { return }
            var merged = doc.metadata
            for (key, value) in facts where merged[key] == nil { merged[key] = value }
            if merged != doc.metadata {
                doc.metadata = merged
                try await documentsRepo.save(doc)
            }

            // If we identified a product, offer to fetch its user manual.
            // (Not for web links, which may themselves already be a manual.)
            if doc.kind != .webLink {
                let vendor = merged["vendor"] ?? ""
                let modelName = merged["model"] ?? ""
                let label = [vendor, modelName].filter { !$0.isEmpty }.joined(separator: " ")
                if !modelName.isEmpty {
                    manualPrompt = ManualPrompt(productLabel: label, query: "\(label) user manual")
                }
            }
        } catch {
            // Fact extraction is a bonus; never surface its failures.
        }
    }

    // MARK: Citation sources

    /// Keep only the citations the answer referenced via `[n]` markers (which
    /// map to CONTEXT passage labels 1…N), preserving citation order. Handles
    /// `[1]`, `[2][3]`, and `[1, 2, 4]`. If nothing is cited, returns [].
    static func citedCitations(in text: String, from all: [Citation]) -> [Citation] {
        guard !all.isEmpty else { return [] }
        var ordered: [Int] = []
        var seen = Set<Int>()
        let ns = text as NSString
        if let regex = try? NSRegularExpression(pattern: #"\[([0-9][0-9,\s]*)\]"#) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let group = ns.substring(with: match.range(at: 1))
                for part in group.components(separatedBy: CharacterSet(charactersIn: ", ")) {
                    if let n = Int(part), n >= 1, n <= all.count, seen.insert(n).inserted {
                        ordered.append(n)
                    }
                }
            }
        }
        return ordered.map { all[$0 - 1] }
    }

    public struct SourceDetails: Sendable, Identifiable {
        public var id: UUID { citation.chunkID }
        public let citation: Citation
        public let document: Document
        public let passage: String
    }

    /// Resolve a citation to the document + the exact passage that was retrieved.
    public func sourceDetails(for citation: Citation) async -> SourceDetails? {
        do {
            guard let document = try await documentsRepo.document(id: citation.documentID) else { return nil }
            let chunk = try await chunksRepo.chunks(ids: [citation.chunkID]).first
            return SourceDetails(citation: citation, document: document, passage: chunk?.text ?? "")
        } catch {
            return nil
        }
    }

    // MARK: Manual fetching

    /// User accepted the "look for the manual?" offer → run the web search.
    public func confirmManualSearch() {
        guard let prompt = manualPrompt else { return }
        manualQuery = prompt.query
        manualPrompt = nil
        webResultsHeading = "User manuals"
        manualCandidates = []
        addedManualURLs = []
        showManualResults = true
        Task { await runManualSearch() }
    }

    public func runManualSearch() async {
        manualSearching = true
        defer { manualSearching = false }
        do {
            manualCandidates = try await manualFinder.search(query: manualQuery)
        } catch {
            manualCandidates = []
            report(error)
        }
    }

    /// Add a chosen manual to the project. PDFs are downloaded and stored as a
    /// local PDF document; everything else is added as a web link.
    public func addManual(_ candidate: ManualCandidate) async {
        guard let pid = selectedProjectID else { return }
        addedManualURLs.insert(candidate.url)
        if candidate.isPDF {
            do {
                let (data, _) = try await URLSession.shared.data(from: candidate.url)
                let dir = try Self.manualsDirectory()
                let fileURL = dir.appendingPathComponent("\(UUID().uuidString).pdf")
                try data.write(to: fileURL)
                let doc = Document(
                    projectID: pid, kind: .pdf, title: candidate.title,
                    sourceURL: fileURL, fileBookmark: FileAccess.makeBookmark(for: fileURL)
                )
                await add(doc)
            } catch {
                report(error)
            }
        } else {
            await addWebLink(candidate.url, title: candidate.title)
        }
    }

    enum WebFetchKind {
        case manual, specs, web
        var querySuffix: String {
            switch self {
            case .manual: return "user manual"
            case .specs: return "technical specifications"
            case .web: return ""
            }
        }
        var heading: String {
            switch self {
            case .manual: return "User manuals"
            case .specs: return "Technical specifications"
            case .web: return "Web results"
            }
        }
        var ackNoun: String {
            switch self {
            case .manual: return "a user manual"
            case .specs: return "the technical specifications"
            case .web: return "information"
            }
        }
    }

    /// Detect a request to fetch something from the web — a manual, technical
    /// specs, or a general search — and return the target product + kind.
    /// Returns nil for content questions (what/how/…) and for requests that
    /// refer to the existing documents ("find X in the manual").
    static func webFetchIntent(from text: String) -> (rawProduct: String, kind: WebFetchKind)? {
        let lower = text.lowercased()
        let fetchVerbs = ["hämta", "ladda ner", "ladda", "fetch", "download", "skaffa",
                          "hitta", "find", "sök", "search", "leta", "look up", "slå upp", "google"]
        let manualNouns = ["manual", "bruksanvisning", "handbok", "user guide", "instruktionsbok", "instruction"]
        let specNouns = ["specifikation", "teknisk", "tekniska", "specs", "datablad", "datasheet", "specification"]
        let webNouns = ["internet", "webben", "nätet", "online", "web"]
        let questionWords = ["vad ", "what ", "hur ", "how ", "var ", "where ", "när ", "when ", "varför ", "why "]
        // Phrases that mean "look inside my existing docs", not fetch new ones.
        let inDocsPhrases = ["i manualen", "i dokument", "i texten", "in the manual", "in the document", "in the docs", "i mina dokument"]

        guard fetchVerbs.contains(where: { lower.contains($0) }),
              !questionWords.contains(where: { lower.contains($0) }),
              !inDocsPhrases.contains(where: { lower.contains($0) })
        else { return nil }

        let kind: WebFetchKind
        if specNouns.contains(where: { lower.contains($0) }) { kind = .specs }
        else if manualNouns.contains(where: { lower.contains($0) }) { kind = .manual }
        else if webNouns.contains(where: { lower.contains($0) }) { kind = .web }
        else { return nil }

        var product = text
        if let range = lower.range(of: "för ") { product = String(text[range.upperBound...]) }
        else if let range = lower.range(of: "for ") { product = String(text[range.upperBound...]) }
        else if let range = lower.range(of: "efter ") { product = String(text[range.upperBound...]) }
        else {
            var cleaned = lower
            for word in fetchVerbs + manualNouns + specNouns + webNouns + ["på ", "den ", "the ", "du ", "kan ", "please", "en ", "ett ", "a ", "an "] {
                cleaned = cleaned.replacingOccurrences(of: word, with: " ")
            }
            product = cleaned
        }
        product = product.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,:;\"'"))
        return product.isEmpty ? nil : (product, kind)
    }

    /// Resolve a possibly-generic product reference ("min dator", "my screen")
    /// to a concrete product named in the project's documents, when possible.
    func resolveProductName(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let genericComputer = ["min dator", "datorn", "dator", "my computer", "the computer", "computer",
                               "min laptop", "laptop", "min bärbara", "macen", "min mac"]
        let genericScreen = ["min skärm", "skärmen", "skärm", "my screen", "the screen", "screen",
                            "min monitor", "monitorn", "monitor", "display", "min bildskärm", "bildskärmen", "bildskärm"]

        func inventoryProducts() -> [String] {
            var out: [String] = []
            for doc in documents {
                if let products = doc.metadata["products"] {
                    out += products.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                if let model = doc.metadata["model"] { out.append(model) }
            }
            return out.filter { !$0.isEmpty }
        }
        func firstMatch(_ keywords: [String]) -> String? {
            inventoryProducts().first { product in
                keywords.contains { product.lowercased().contains($0) }
            }
        }

        if genericComputer.contains(where: { lower == $0 }) {
            if let match = firstMatch(["macbook", "laptop", "notebook", "imac", " pc", "dator"]) { return match }
        }
        if genericScreen.contains(where: { lower == $0 }) {
            if let match = firstMatch(["monitor", "skärm", "display", "curved"]) { return match }
        }
        return raw
    }

    private static func manualsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Lore/manuals", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func deleteDocument(_ id: UUID) async {
        do {
            let document = try await documentsRepo.document(id: id)
            try await chunksRepo.deleteChunks(documentID: id)
            try await documentsRepo.delete(id: id)
            if let document { Self.removeManagedFile(for: document) }
            await refreshDocuments()
        } catch { report(error) }
    }

    /// Delete the on-disk copy ONLY for files Lore downloaded into its own
    /// manuals folder. Files the user added from their own folders are
    /// referenced (never copied), so their originals are never touched.
    static func removeManagedFile(for document: Document) {
        guard let url = document.sourceURL, url.isFileURL,
              let manualsDir = try? manualsDirectory() else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if parent == manualsDir.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
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

    public func renameChat(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var chat = chats.first(where: { $0.id == id }) else { return }
        chat.title = trimmed
        do { try await chatsRepo.save(chat); await refreshChats() }
        catch { report(error) }
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

        // Chat-triggered web fetch: if the user asks to fetch a manual, specs,
        // or to search the web for something, run the search instead of a RAG
        // answer and let them add results to the project.
        if let intent = Self.webFetchIntent(from: trimmed) {
            let product = resolveProductName(intent.rawProduct)
            let query = intent.kind == .web ? product : "\(product) \(intent.kind.querySuffix)"
            let ack = Message(
                chatID: chatID, role: .assistant,
                text: "Searching the web for \(intent.kind.ackNoun) for “\(product)”. I'll show the results in a panel — pick any to add to this project."
            )
            messages.append(ack)
            try? await chatsRepo.add(ack)
            webResultsHeading = intent.kind.heading
            manualQuery = query
            manualCandidates = []
            addedManualURLs = []
            showManualResults = true
            await runManualSearch()
            return
        }

        // Guardrail: only handle questions about this project's products /
        // documents (and fetching/managing them). Decline anything off-topic.
        if await scopeAllows(trimmed) == false {
            let decline = Message(
                chatID: chatID, role: .assistant,
                text: "I can only help with the documents and products in this project. Ask me about your products, or ask me to fetch a manual or technical specs for one of them."
            )
            messages.append(decline)
            try? await chatsRepo.add(decline)
            return
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
            for try await token in handle.stream {
                if token.isDone { break }
                assistant.text += token.text
                messages[assistantIndex].text = assistant.text
            }
            // Show only the sources the answer actually cited ([1], [2], …), so
            // an inventory answer drawn from the library doesn't list unrelated
            // retrieved passages as its sources.
            let cited = Self.citedCitations(in: assistant.text, from: handle.citations)
            assistant.citations = cited
            messages[assistantIndex].citations = cited
            try? await chatsRepo.add(assistant)

            // Fold this exchange into the project's chat memory so future
            // questions can recall it. Best-effort, off the critical path.
            let answerText = assistant.text
            Task {
                await indexMemory(chatID: chatID, role: .user, text: trimmed)
                await indexMemory(chatID: chatID, role: .assistant, text: answerText)
            }
        } catch {
            messages[assistantIndex].text = "⚠️ \(error.localizedDescription)"
            report(error)
        }
    }

    /// Deterministic scope gate: a tight one-word classifier decides whether a
    /// message is about the user's own products/documents (RELATED) or off-topic
    /// (OFFTOPIC). Fails OPEN (allows) on error/ambiguity so it never blocks a
    /// legitimate product question; only a clear OFFTOPIC verdict declines.
    private func scopeAllows(_ question: String) async -> Bool {
        var products: [String] = []
        for doc in documents {
            products.append(doc.title)
            if let p = doc.metadata["products"] { products += p.components(separatedBy: ";") }
            if let m = doc.metadata["model"] { products.append(m) }
        }
        let list = products
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(24)
            .joined(separator: ", ")

        let system = """
        You are a strict router for a personal product-knowledge assistant. The \
        user's project is about their OWN products and documents. Classify the \
        user's message as:
        - RELATED: about their products/documents, using or troubleshooting them, \
        their specs/warranty/purchase, or a request to find/fetch info or \
        documentation for them, or to add/remove/update their products.
        - OFFTOPIC: general knowledge, coding, math, trivia, world facts, news, \
        creative writing, or anything not about the user's own items.
        Answer with exactly one word: RELATED or OFFTOPIC.
        """
        let user = "Products/documents in the project: \(list.isEmpty ? "(none yet)" : list).\n\nUser message: \"\(question)\""
        let request = ChatRequest(
            model: settings.chatModel,
            messages: [ChatTurn(role: .system, content: system), ChatTurn(role: .user, content: user)],
            temperature: 0
        )
        var output = ""
        do {
            for try await token in llm.chat(request) {
                if token.isDone { break }
                output += token.text
                if output.count > 40 { break }
            }
        } catch {
            return true // fail open
        }
        let upper = output.uppercased()
        return !(upper.contains("OFFTOPIC") && !upper.contains("RELATED"))
    }

    /// Embed a message and store it as retrievable chat memory. Best-effort.
    private func indexMemory(chatID: UUID, role: MessageRole, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, let pid = selectedProjectID else { return }
        do {
            let vector = try await embedder.embed(String(trimmed.prefix(2000)))
            try await memoryRepo.insert(projectID: pid, chatID: chatID, role: role.rawValue, text: trimmed, embedding: vector)
        } catch {
            // Memory is a bonus; never surface its failures.
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
