# Lore — Architecture Plan

> **Lore** · *Explore your lore.*
>
> A native macOS app for building private, local-LLM-powered knowledge "projects":
> collections of documents, links, and chat that let you *ask questions and get
> answers grounded in your own material* — 100% on-device.
>
> **Scope: this is a long-lived product.** Decisions below optimize for
> maintainability, testability, and extensibility over multiple years — not for
> the fastest possible first demo.

---

## 1. Goals & guiding principles

| Goal | How it shapes the design |
|---|---|
| **Private by default** | Nothing leaves the Mac. Model + embeddings run locally. |
| **Genuinely user-friendly** | First-run wizard that installs/checks the local LLM runtime and pulls models for you. No terminal required. |
| **Modern glass UI** | Native **Liquid Glass** (macOS 26 Tahoe) — real material, not a mimic. |
| **Built to last** | Modular Swift packages, protocol-driven services, migrations, tests, CI. No corner-cutting we'll regret. |
| **Not locked in** | LLM runtime, embedding model, and storage are behind abstractions so any one can be swapped without a rewrite. |
| **Grounded answers** | Hybrid RAG with citations back to the source document/page. |

North-star user story: *"My dishwasher shows F01. I ask my House Project what to
do — it answers from the manual, tells me where I bought it, and whether the
warranty is still valid."*

---

## 2. Tech stack & rationale

| Layer | Choice | Why |
|---|---|---|
| Language | **Swift 6**, strict concurrency | Long-term Apple platform alignment; async/await throughout. |
| UI | **SwiftUI** + **Liquid Glass** | `NavigationSplitView`, `glassEffect()`, `GlassEffectContainer`, `.buttonStyle(.glass)`. |
| Persistence | **GRDB (SQLite)** | Explicit schema + **versioned migrations**, `FTS5` full-text, and **sqlite-vec** vector index in one file. Far more control than SwiftData for a data-heavy, long-lived app. |
| Vector search | **sqlite-vec** extension | Persistent, indexed ANN search that scales with the corpus; no re-loading everything into memory. |
| Full-text search | **SQLite FTS5** | Powers the keyword half of hybrid retrieval. |
| PDF parsing | **PDFKit** (built-in) | Text + per-page extraction for citations. |
| Web ingest | **URLSession** + **SwiftSoup** | Real HTML parsing / readability extraction beats naive stripping. |
| LLM runtime | **Ollama** (default), behind a provider protocol | Scriptable API (detect/list/pull/chat/embed). Protocol allows LM Studio / llama.cpp / remote later. |
| Networking | **URLSession** (streaming) | Native; no HTTP client dependency. |
| Updates | **Sparkle** | Standard, well-maintained auto-update for non-App-Store Mac apps. |

**Dependency policy:** lean but not dogmatically zero. Each third-party lib
(GRDB, sqlite-vec, SwiftSoup, Sparkle) is mature, widely used, and replaces code
we'd otherwise own and maintain badly. Everything else stays first-party.

**Why Ollama as the default runtime:** clean REST API (`/api/tags`, `/api/pull`,
`/api/chat`, `/api/embeddings`) lets the app detect installs, pull models with a
progress bar, and stream responses from inside the UI. But we do **not** hardcode
it — see §3, `LLMProvider`.

**Recommended default models** — RAM-adaptive (wizard detects RAM, all swappable):
- **8 GB** → chat `llama3.2:3b` — the guaranteed-to-run baseline on any M-series Mac.
- **16 GB** → chat `llama3.1:8b` or `qwen2.5:7b`.
- **32 GB+** → a 14B-class chat model.
- Embeddings (all Macs): `nomic-embed-text` (768-dim, ~275 MB, purpose-built for RAG).

---

## 3. Provider abstraction (key long-lived decision)

The single most important anti-lock-in move: everything the app needs from a
local LLM sits behind protocols, with Ollama as the first concrete impl.

```swift
protocol LLMProvider {
    func availability() async -> ProviderHealth        // installed? running? which models?
    func pull(model: String) -> AsyncStream<PullProgress>
    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatToken, Error>
}

protocol EmbeddingProvider {
    var model: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
```

Concrete impls in v1: `OllamaProvider` (both protocols). Future impls
(`LMStudioProvider`, `LlamaCppProvider`, a remote gateway) drop in without
touching feature code. Embeddings carry their **model name + dimension** so we
can detect and handle a change of embedding model (see §5 re-embedding).

---

## 4. Data model (SQLite via GRDB)

```
project(id, name, icon, color_tint, created_at, system_prompt,
        chat_model, embedding_model)

document(id, project_id, kind, title, source_url, file_bookmark,
         added_at, status, page_count, content_hash)
   -- content_hash → skip re-ingest of unchanged files; detect changes

document_metadata(document_id, key, value)     -- vendor, purchase_date, warranty_until…

chunk(id, document_id, ordinal, text, page,
      token_count, embedding_model, embedding_dim)

vec_chunk(chunk_id, embedding)                 -- sqlite-vec virtual table
chunk_fts(text)                                -- FTS5 virtual table (keyword half)

chat(id, project_id, title, created_at)
message(id, chat_id, role, text, created_at)
citation(message_id, document_id, chunk_id, page)

schema_version(version)                        -- migration bookkeeping
```

- **Structured facts** (vendor, purchase date, warranty expiry) live in
  `document_metadata`. Filled by the user in a side panel *and* auto-extracted by
  a one-shot LLM pass on ingest. This is what makes *"is the warranty still
  valid?"* a deterministic date comparison rather than a model guess.
- **`content_hash`** lets us skip unchanged re-ingests and detect edited files.
- **Migrations**: GRDB `DatabaseMigrator`, each migration named & versioned;
  every schema change ships as an additive, tested migration. Never a destructive
  in-place change without a backup step.

---

## 5. RAG pipeline (hybrid)

**On ingest (per document):**
1. Extract text (PDFKit / SwiftSoup / raw), preserving page boundaries for PDFs.
2. Chunk: ~500-token windows, ~15% overlap, split on paragraph/sentence.
3. Embed chunks in batches via `EmbeddingProvider`.
4. Write `chunk` + `vec_chunk` (vector) + `chunk_fts` (keyword) rows, tagged with
   embedding model/dim.
5. One-shot LLM metadata extraction → `document_metadata`.
6. Flip `status` to `.ready`; progress streamed to UI.

**On question (hybrid retrieval):**
1. Embed the question.
2. **Vector** top-N via sqlite-vec **and** **keyword** top-N via FTS5.
3. Fuse with **Reciprocal Rank Fusion**, take top-K (≈6). Hybrid beats either
   alone — great for exact codes like "F01" *and* fuzzy phrasing.
4. Build prompt: system rules + delimited retrieved passages (source-labeled) +
   injected structured metadata + recent turns + question.
5. Stream the answer; render with **citation chips** → source doc/page.

**Grounding:** system prompt requires answering only from provided context, and
saying "I don't know from your documents" otherwise.

**Embedding-model changes:** because chunks store their embedding model+dim, if
the user (or an update) switches embedding models, the app detects the mismatch
and offers a background **re-embed** of affected documents rather than silently
returning garbage similarity scores.

---

## 6. Local LLM setup wizard

The "very user friendly / help configure the local LLM" requirement, first-class.

**Wizard flow (blocks the app only until healthy, then collapses to a status pill):**
1. **Detect** — is the runtime installed & reachable? Live ✅/❌ pill.
2. If missing → guidance + "Download Ollama" button (opens ollama.com) and a
   copyable Homebrew command. *We guide and confirm; we never silently install
   system software.*
3. **Recommend models** sized to detected RAM (offer a smaller 3B model on
   lighter Macs) → one-tap pull with streamed progress %.
4. **Verify** — test prompt + test embedding, green checks.
5. Collapse to a toolbar status indicator; Settings changes models later.

Graceful degradation: if the runtime dies mid-session the pill goes red with a
one-click retry; in-flight requests fail cleanly with a retry affordance.

---

## 7. UX & screens (Liquid Glass)

`NavigationSplitView`, three columns:

```
┌────────────┬───────────────────────┬────────────────────────┐
│  SIDEBAR   │   PROJECT / CONTENT   │        CHAT             │
│ (glass)    │                       │  (glass bubbles)        │
│ • House    │  Documents grid/list  │  Q: dishwasher F01      │
│ • Car      │  [+ PDF / Link / Txt] │  A: … [manual p.12] ↩   │
│ • Work     │  status: ● ready      │  ──────────────────     │
│ + New      │  Metadata panel       │  [ ask your project… ]  │
│ ⚙ status●  │  (vendor/warranty)    │                         │
└────────────┴───────────────────────┴────────────────────────┘
```

- **Sidebar**: translucent glass; projects with emoji/symbol + tint; "New
  Project"; runtime status pill pinned bottom.
- **Project detail**: document cards (drag-and-drop a PDF onto the window), per-doc
  status, editable metadata panel.
- **Chat**: glass bubbles inside a `GlassEffectContainer`, streaming tokens,
  citation chips that jump to source. Empty state suggests example questions.
- **Glass specifics**: `glassEffect(in:)` on floating panels & the composer;
  `.buttonStyle(.glass)` for primary actions; `GlassEffectContainer` to group
  controls so highlights blend. Respect **Reduce Transparency** / **Increase
  Contrast** and full Dynamic Type — accessibility is not optional in a long-lived
  app.

Drag-and-drop, ⌘N (new project), ⌘L (add link), full keyboard nav.

---

## 8. Storage, privacy & security

- Data in `~/Library/Application Support/Lore/` (single SQLite DB + imported
  file copies / security-scoped bookmarks).
- **No network egress** except (a) `localhost` runtime and (b) web links the user
  explicitly adds (shown before fetch).
- **Prompt-injection defense (critical for RAG):** documents and fetched web
  pages are *untrusted data*, never instructions. Retrieved text goes in a clearly
  delimited block; the system prompt forbids treating it as commands. When tools
  land (post-v1) retrieved content can never trigger actions without user
  confirmation.
- **App Sandbox** on; user-selected file access via security-scoped bookmarks.
- **Backups & integrity**: periodic DB checkpoint; export/import of a project as
  a portable bundle (docs + metadata) for backup and machine migration.

---

## 9. Module structure (Swift Packages)

Modularized from day one so features stay isolated and testable:

```
LoreApp/                 // thin app target: wiring, entry point
Packages/
  LoreCore/              // domain models, protocols (LLMProvider, EmbeddingProvider), errors
  LorePersistence/       // GRDB stack, migrations, repositories, sqlite-vec/FTS5
  LoreProviders/         // OllamaProvider (+ future providers)
  LoreIngestion/         // PDF/Web/Text extractors, Chunker, MetadataExtractor
  LoreRAG/               // Embedder, HybridSearch (RRF), PromptBuilder
  LoreDesignSystem/      // Glass components, tints, spacing, symbols
  LoreUI/                // SwiftUI features (Sidebar, Project, Chat, Setup)
```

- **MVVM** with `@Observable` view models.
- **Repository pattern** over GRDB so UI never touches SQL.
- Services are protocol-backed → mockable in previews and tests.

---

## 10. Testing, CI & quality

- **Unit tests**: chunker, RRF fusion, prompt builder, migrations (round-trip),
  metadata extraction parsing, repositories against an in-memory DB.
- **Provider tests**: `OllamaProvider` against a stubbed URLProtocol (no live
  daemon needed in CI).
- **UI tests / snapshot tests** for key screens incl. Reduce-Transparency variant.
- **CI** (GitHub Actions, macOS runner): build all packages, run tests, SwiftLint
  + swift-format on PRs.
- **Migration safety net**: a test that opens a fixture DB from each prior schema
  version and migrates it forward.

---

## 11. Distribution & updates

- Signed & **notarized** Developer-ID build (outside the App Store initially — the
  App Store sandbox complicates talking to a locally-installed Ollama).
- **Sparkle** appcast for auto-updates.
- Versioned release notes; crash reporting is **opt-in** and local-first (no
  silent telemetry — consistent with the privacy promise).

---

## 12. Roadmap

| Phase | Milestone | Outcome |
|---|---|---|
| **M0** | Package skeleton + glass app shell | Modules compile; three-column glass layout; verifies Liquid Glass APIs against the real SDK. |
| **M1** | Persistence + Projects CRUD | GRDB stack, first migration, create/rename/delete projects. |
| **M2** | Provider layer + setup wizard | Detect Ollama, pull models w/ progress, health pill. |
| **M3** | Ingestion (PDF/text/link) | Add docs → extract → chunk, with status + content-hash dedupe. |
| **M4** | Embeddings + hybrid search | sqlite-vec + FTS5 + RRF fusion working. |
| **M5** | Chat with RAG + citations | Dishwasher story end-to-end. |
| **M6** | Metadata extraction (vendor/warranty) | "Is my warranty valid?" answered deterministically. |
| **M7** | Hardening | Accessibility, errors, DnD, export/import, notarization + Sparkle. |
| **Later** | docx/Office ingest, multiple providers, tools/actions, warranty reminders, iCloud-free sync options. | Extensions enabled by the abstractions above. |

---

## 13. Open decisions

- ✅ **App name** — **Lore**, tagline *"Explore your lore."*
- ✅ **Default chat model** — RAM-adaptive; `llama3.2:3b` baseline (see §2).
- ✅ **Scope** — long-lived product (not a throwaway hackathon build).

Still open:

1. **Distribution** — Developer-ID + Sparkle as planned (recommended), or do you
   want App Store as a hard requirement (changes the Ollama integration story)?
2. **Warranty behavior** — proactive expiry reminders eventually, or answer-when-
   asked only? (v1 = answer when asked; reminders in "Later".)
3. **Tooling** — Xcode 26 + Ollama not yet installed; installing in parallel.
   Non-UI packages can be built/tested with the Swift toolchain meanwhile.

---

## 14. Risks

- **Liquid Glass is new** — verify APIs against the installed SDK at M0.
- **sqlite-vec packaging** — needs to be built/linked into the app; validated at M4
  (fallback: brute-force cosine in SQL if the extension is problematic).
- **Model performance varies by Mac** — wizard recommends sizes from detected RAM.
- **Web extraction quality** — SwiftSoup readability is heuristic; acceptable for
  v1, improvable later.
