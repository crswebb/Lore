# Lore — Architecture

> **Lore** · *Explore your lore.*
>
> A native macOS app for building private, local-LLM-powered knowledge
> **shelves**: collections of documents, links, and chat that let you *ask
> questions and get answers grounded in your own material* — 100% on-device.
>
> **Scope: this is a long-lived product.** Decisions below optimize for
> maintainability, testability, and extensibility over multiple years — not for
> the fastest possible first demo.

> **Status.** This document describes the implemented system, and notes where
> reality differs from the original plan (⚙️ *implementation note*) and what is
> still on the roadmap (see §12). Two intentional simplifications from the first
> plan: vector search is **brute-force cosine over stored embeddings** (not
> `sqlite-vec` yet), and the app currently ships **unsandboxed** as a
> local/dev build (App Sandbox is M7 hardening). Beyond Ollama, chat also runs on
> **Apple Intelligence** (the default) and any **OpenAI-compatible API**.

> **Terminology.** What the UI calls a **Shelf** is modelled in code and the
> database as a `project` / `Project`. The rename was user-facing only; the
> schema and type names still say "project".

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
| Persistence | **GRDB (SQLite)** | Explicit schema + **versioned migrations** and `FTS5` full-text in one file. Far more control than SwiftData for a data-heavy, long-lived app. |
| Vector search | **Brute-force cosine** over `Float32` BLOBs | ⚙️ Dependency-free, correct, and fast enough for personal-scale corpora. `sqlite-vec` is the documented scale-up path and can replace it behind the same call sites. |
| Full-text search | **SQLite FTS5** | Powers the keyword half of hybrid retrieval. |
| PDF parsing | **PDFKit** + **Vision OCR** | Text + per-page extraction for citations; ⚙️ Vision `VNRecognizeTextRequest` fallback recovers text from scanned/image PDFs. |
| Web ingest | **URLSession** + **SwiftSoup** | Real HTML parsing / readability extraction beats naive stripping. Also powers on-request manual/spec search. |
| Chat runtime | **Apple Intelligence** (default), **Ollama**, or **OpenAI-compatible API** | ⚙️ All three sit behind `LLMProvider`. Apple = zero-setup on-device; Ollama = local models via a setup wizard; External = bring-your-own cloud endpoint (chat only; embeddings stay local). |
| Embeddings | **Apple `NLContextualEmbedding`** (512-dim) or **Ollama `nomic-embed-text`** (768-dim) | ⚙️ On-device either way; chosen automatically based on the active runtime. |
| Localization | **App-bundle `.lproj`** + a small `L()` helper | ⚙️ en/de/es/fr/sv UI, switchable live at runtime (see §7). |
| Networking | **URLSession** (streaming) | Native; no HTTP client dependency. |
| Updates | **Sparkle** *(planned, M7)* | Standard auto-update for non-App-Store Mac apps. |

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

Concrete implementations that ship today:

- **`OllamaProvider`** — chat (NDJSON stream) and embeddings against a local
  Ollama daemon; also drives the setup wizard (detect / list / pull with progress).
- **`AppleFoundationModelProvider`** — chat via `FoundationModels`
  (`SystemLanguageModel` / `LanguageModelSession`). The zero-setup default.
- **`OpenAICompatibleProvider`** — chat via any OpenAI-compatible `/chat/completions`
  SSE endpoint (bring-your-own key, stored in the Keychain).
- **`OllamaEmbeddingProvider`** and **`AppleEmbeddingProvider`**
  (`NLContextualEmbedding`, mean-pooled, 512-dim) for the embedding side.

`AppModel.reconfigureProviders()` selects the chat provider from the user’s
"Chat runs on" setting and the embedder from whichever local runtime is
available. Future impls (LM Studio, llama.cpp, a remote gateway) drop in without
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
      token_count, embedding_model, embedding_dim,
      embedding)                               -- Float32 vector as a BLOB (VectorCodec)
chunk_fts(text)                                -- FTS5 virtual table (keyword half)

chat(id, project_id, title, created_at)
message(id, chat_id, role, text, created_at)
citation(message_id, document_id, chunk_id, page)

memory(id, project_id, role, text, embedding)  -- schema v2: embedded chat turns,
                                               -- so past conversation is retrievable

schema_version(version)                        -- migration bookkeeping
```

⚙️ *Implementation note:* embeddings are stored inline as a `Float32` BLOB
(encoded by `VectorCodec`) rather than in a `sqlite-vec` virtual table; search is
brute-force cosine (`VectorSearch`). Same call sites, simpler dependency
footprint — swap in `sqlite-vec` when corpus size demands it.

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
1. **Scope guardrail** — a fast, deterministic classifier call first decides
   whether the question is about this shelf’s documents/products (or a fetch/manage
   request). Off-topic questions are declined rather than answered from general
   model knowledge.
2. If the question is a **web-fetch intent** ("find the manual/specs for X"), run
   a web search instead of RAG and offer the results for the user to add.
3. Otherwise embed the question, then run **vector** top-N (brute-force cosine
   over stored embeddings) **and** **keyword** top-N (FTS5).
4. Fuse with **Reciprocal Rank Fusion**, take top-K (≈6). Hybrid beats either
   alone — great for exact codes like "F01" *and* fuzzy phrasing.
5. Pull relevant snippets from **chat memory** (embedded past turns) for
   continuity.
6. Build prompt: system rules + shelf inventory + delimited retrieved passages
   (source-labeled) + injected structured metadata + memory notes + recent turns
   + question.
7. Stream the answer; render with **citation chips** → source doc/page.

**Compact mode.** Apple’s on-device model has a small context window, so when the
chat runtime is Apple, retrieval returns fewer/shorter passages, a capped
inventory, and no memory notes, and the prompt uses a trimmed system prompt with
a hard character cap.

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
│  SIDEBAR   │    CHAT HISTORY       │        CHAT             │
│ (glass)    │                       │  (glass bubbles)        │
│ • House    │  • Summarize this…    │  Q: dishwasher F01      │
│ • Car      │  • Warranty valid?    │  A: … [manual p.12] ↩   │
│ • Work     │  + New Chat           │  ──────────────────     │
│ + New Shelf│                       │  [ ask your shelf…   ]  │
│ ⚙ status●  │            Documents ▸ (right-hand inspector)    │
└────────────┴───────────────────────┴────────────────────────┘
```

The layout is a three-column `NavigationSplitView` — **Shelves** · **Chat
history** · **Chat** — with **Documents** in a right-hand inspector that’s hidden
by default (chatting is the primary activity; document admin is secondary).

- **Sidebar**: translucent glass; shelves with emoji/symbol + tint; "New Shelf";
  chat runtime status pill(s) pinned bottom.
- **Documents inspector**: document rows (drag-and-drop a PDF onto the window),
  per-doc status, editable facts (metadata) sheet, click-through to the source.
- **Chat**: glass bubbles, streaming tokens, collapsible citation chips that jump
  to source. Empty state suggests example questions. Composer is a growing
  text editor (Enter sends, Shift+Enter for a newline).
- **Settings** (⌘,): tabbed — **Models**, **Appearance** (glass transparency +
  **UI language**), **Advanced** (chat provider + external API).
- **Glass specifics**: `glassEffect(in:)` on floating panels & the composer;
  `.buttonStyle(.glass)` for primary actions; `GlassEffectContainer` to group
  controls so highlights blend. An adjustable transparency slider drives an
  `AdaptiveBackground`.

**Localization.** UI strings resolve through an `L()` helper that reads the
selected language’s `.lproj` from the app bundle (en/de/es/fr/sv), so switching
language in Settings applies **live** without a relaunch. User content and model
answers are never translated.

---

## 8. Storage, privacy & security

- Data in `~/Library/Application Support/Lore/` (single SQLite DB + imported
  file copies / security-scoped bookmarks).
- **No network egress** except (a) the `localhost` Ollama runtime, (b) web links
  or manuals the user explicitly adds, (c) an **external chat provider only if the
  user deliberately selects one** — shown with a persistent banner while active,
  and (d) an **update check** — an unauthenticated GET to the GitHub Releases API
  on launch (`UpdateChecker`), sending no user data and toggleable in Settings.
  Documents, embeddings, and the search index never leave the Mac.
- **Prompt-injection defense (critical for RAG):** documents and fetched web
  pages are *untrusted data*, never instructions. Retrieved text goes in a clearly
  delimited block; the system prompt forbids treating it as commands. When tools
  land (post-v1) retrieved content can never trigger actions without user
  confirmation.
- **App Sandbox**: ⚙️ the current build ships **unsandboxed** and ad-hoc signed
  for smooth local/dev first-run (talking to a locally-installed Ollama is simpler
  without the sandbox). Enabling App Sandbox + entitlements with security-scoped
  bookmarks is part of M7 hardening before Developer-ID distribution. File access
  already resolves via security-scoped bookmarks where present (see `FileAccess`).
- **Backups & integrity**: periodic DB checkpoint; export/import of a project as
  a portable bundle (docs + metadata) for backup and machine migration.

---

## 9. Module structure (Swift Packages)

Modularized from day one so features stay isolated and testable:

```
App/                     // thin app target: entry point, Assets, *.lproj strings
project.yml              // XcodeGen spec — source of truth for Lore.xcodeproj (generated)
LorePackages/            // one Swift package, several library targets:
  LoreCore/              // domain models, protocols (LLMProvider, EmbeddingProvider), errors
  LorePersistence/       // GRDB stack, migrations, repositories, VectorCodec/VectorSearch, FTS5
  LoreProviders/         // Ollama, Apple Foundation Models, OpenAI-compatible; Ollama/Apple embeddings
  LoreIngestion/         // PDF (+Vision OCR)/Web/Text extractors, Chunker, MetadataExtractor, manual finder
  LoreRAG/               // RetrievalService (RRF), PromptBuilder
  LoreDesignSystem/      // Glass components, tints, window effects
  LoreUI/                // SwiftUI features, AppModel composition root, L() localization
  lore-smoke/            // headless end-to-end smoke test executable
```

- The app target is generated from `project.yml` via **XcodeGen** (the
  `.xcodeproj` is not committed).
- **`@Observable` `AppModel`** is the `@MainActor` composition root wiring
  providers, repositories, and services together.
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

| Phase | Milestone | Status |
|---|---|---|
| **M0** | Package skeleton + glass app shell | ✅ Done — modules compile; three-column glass layout on the real SDK. |
| **M1** | Persistence + Shelves CRUD | ✅ Done — GRDB stack, migrations, create/edit/delete shelves. |
| **M2** | Provider layer + setup wizard | ✅ Done — Ollama detect/pull/health; **plus Apple Intelligence & external API providers**. |
| **M3** | Ingestion (PDF/text/link) | ✅ Done — extract → chunk with status + content-hash dedupe; **+ Vision OCR fallback**. |
| **M4** | Embeddings + hybrid search | ✅ Done — brute-force cosine + FTS5 + RRF (Apple or Ollama embeddings). |
| **M5** | Chat with RAG + citations | ✅ Done — dishwasher story end-to-end; **+ chat memory, scope guardrail, on-request web fetch**. |
| **M6** | Metadata extraction (vendor/warranty) | ✅ Done — auto + manual facts; deterministic warranty answers. |
| **—** | Localization | ✅ Done — en/de/es/fr/sv UI, live switching. |
| **M7** | Hardening | ◻︎ In progress — App Sandbox + entitlements, notarization, Sparkle auto-update; accessibility & export/import. |
| **Later** | docx/Office ingest, more providers, tools/actions, warranty reminders, `sqlite-vec` at scale, sync options. | Enabled by the abstractions above. |

---

## 13. Open decisions

- ✅ **App name** — **Lore**, tagline *"Explore your lore."*
- ✅ **Default chat model** — RAM-adaptive; `llama3.2:3b` baseline (see §2).
- ✅ **Scope** — long-lived product (not a throwaway hackathon build).

- ✅ **Chat runtime** — Apple Intelligence is the zero-setup default; Ollama and an
  external OpenAI-compatible API are both supported.
- ✅ **Localization** — en/de/es/fr/sv UI, live-switchable.

Still open:

1. **Distribution** — Developer-ID + Sparkle as planned (recommended), or App
   Store as a hard requirement (changes the Ollama integration story)? Ties into
   the M7 App Sandbox work.
2. **Warranty behavior** — proactive expiry reminders eventually, or answer-when-
   asked only? (Today = answer when asked; reminders in "Later".)

---

## 14. Risks

- **Liquid Glass is new** — ✅ verified against the installed SDK.
- **sqlite-vec packaging** — ✅ sidestepped for v1 by using brute-force cosine over
  stored `Float32` BLOBs; revisit `sqlite-vec` only when corpus size demands it.
- **Small context windows (Apple Intelligence)** — handled via compact retrieval +
  a trimmed prompt with a hard character cap (see §5).
- **Model performance varies by Mac** — wizard recommends sizes from detected RAM.
- **Web extraction quality** — SwiftSoup readability is heuristic; acceptable for
  v1, improvable later.
