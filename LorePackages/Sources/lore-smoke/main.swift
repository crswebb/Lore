import Foundation
import LoreCore
import LorePersistence
import LoreProviders
import LoreIngestion
import LoreRAG

// End-to-end smoke test: ingest a small document, then ask a question and
// confirm a grounded, cited answer comes back — all against live Ollama.
// Uses a temporary database so it never touches the app's real store.

func log(_ s: String) { print(s); fflush(stdout) }

let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("lore-smoke-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpDir) }

// A tiny "dishwasher manual + receipt" so we can reproduce the north-star story.
let manual = """
BrightWash 3000 Dishwasher — Troubleshooting

Error code F01: Water drainage fault. The appliance could not pump out water.
Steps: 1) Turn off the dishwasher. 2) Check the drain hose for kinks.
3) Remove and clean the filter at the bottom of the tub. 4) Restart the cycle.
If F01 persists, contact support.

Purchased from NordicHome Appliances on 2024-03-15. Warranty: 3 years.
"""
let manualURL = tmpDir.appendingPathComponent("brightwash-manual.txt")
try manual.write(to: manualURL, atomically: true, encoding: .utf8)

log("• Opening temp database…")
let db = try LoreDatabase(url: tmpDir.appendingPathComponent("smoke.sqlite"))
let projects = ProjectRepository(db)
let documents = DocumentRepository(db)
let chunks = ChunkRepository(db)

let embedder = OllamaEmbeddingProvider()
let llm = OllamaProvider()

log("• Checking Ollama…")
guard case .ready = await llm.availability() else {
    log("❌ Ollama not ready"); exit(1)
}

// 1. Project + document
let project = Project(name: "House", embeddingModel: embedder.model)
try await projects.save(project)
var doc = Document(projectID: project.id, kind: .text, title: "BrightWash Manual", sourceURL: manualURL)
try await documents.save(doc)

// 2. Ingest (extract → chunk → embed → store)
log("• Ingesting document…")
let content = try TextExtractor().extract(fileURL: manualURL)
let chunker = Chunker(configuration: .init(maxTokens: 80, overlapTokens: 15))
let drafts = chunker.chunk(content.fullText)
let vectors = try await embedder.embed(drafts.map(\.text))
for (draft, vector) in zip(drafts, vectors) {
    let chunk = Chunk(
        documentID: doc.id, ordinal: draft.ordinal, text: draft.text,
        page: draft.page, tokenCount: draft.approximateTokenCount,
        embeddingModel: embedder.model, embeddingDimensions: embedder.dimensions
    )
    try await chunks.insert(chunk, projectID: project.id, embedding: vector)
}
doc.status = .ready
try await documents.save(doc)
log("  indexed \(drafts.count) chunks, \(vectors.first?.count ?? 0)-dim embeddings")

// 3. Retrieve (hybrid: vector + keyword, fused)
let question = "My dishwasher shows F01. What should I do?"
log("\n• Question: \(question)")
let qVec = try await embedder.embed(question)
let embedded = try await chunks.embeddings(projectID: project.id)
let vectorIDs = VectorSearch.rank(query: qVec, candidates: embedded.map { ($0.id, $0.vector) }, topN: 12)
let keywordIDs = try await chunks.keywordSearch(projectID: project.id, query: question, limit: 12)
let fused = Array(ReciprocalRankFusion().fuse([vectorIDs, keywordIDs]).prefix(4))
let fetched = try await chunks.chunks(ids: fused)
let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
let ordered = fused.compactMap { byID[$0] }
log("  retrieved \(ordered.count) passages (keyword hits: \(keywordIDs.count), vector hits: \(vectorIDs.count))")

let passages = ordered.enumerated().map { idx, chunk in
    RetrievedPassage(index: idx + 1, sourceTitle: doc.title, page: chunk.page, text: chunk.text)
}

// 4. Ask the model
let messages = PromptBuilder().build(
    projectSystemPrompt: nil, passages: passages, metadata: [:], history: [], question: question
)
log("\n• Answer:")
var answer = ""
for try await token in llm.chat(ChatRequest(model: "llama3.1:8b", messages: messages)) {
    if token.isDone { break }
    answer += token.text
    print(token.text, terminator: ""); fflush(stdout)
}
print("\n")

// 5. Verdict
let lower = answer.lowercased()
let grounded = lower.contains("drain") || lower.contains("filter") || lower.contains("hose")
let cited = answer.contains("[1]") || answer.contains("[2]") || answer.contains("[3]") || answer.contains("[4]")
log("——")
log(grounded ? "✅ Answer is grounded in the manual (mentions drain/filter/hose)."
             : "⚠️ Answer did not mention expected grounded terms.")
log(cited ? "✅ Answer includes a citation marker." : "⚠️ No citation marker found.")
exit(grounded ? 0 : 2)
