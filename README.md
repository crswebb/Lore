<div align="center">

# Lore

**Explore your lore.**

A native macOS app for private, local‑LLM knowledge assistants. Group your
documents, links, and chats into **shelves**, then ask questions and get answers
grounded in *your own material* — with citations, 100% on‑device.

[![Platform: macOS 26](https://img.shields.io/badge/platform-macOS%2026%20Tahoe-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

---

## What is Lore?

Lore is a knowledge assistant that runs entirely on your Mac. You create a
**shelf** for a topic — your home, your car, a product you own, a project at work
— and drop in the relevant PDFs, web links, and notes. Lore reads and indexes
them locally, and you can then chat with the shelf: it answers from your material
and cites the exact document and page it used.

> **North‑star story:** *My dishwasher shows error F01. I ask my “House” shelf
> what to do — it answers from the manual, tells me where I bought it, and
> whether the warranty is still valid.*

Nothing is sent to the cloud unless you explicitly choose an external chat
provider. Your documents, embeddings, and search index never leave the machine.

## Features

- **Shelves** — group documents, links, and chat history by topic, each with its
  own icon and colour.
- **Grounded answers with citations** — hybrid retrieval (dense embeddings +
  keyword FTS, fused with Reciprocal Rank Fusion). Every answer links back to the
  source document and page; tap a citation to read the exact passage or open the
  PDF at that page.
- **Three chat back‑ends, one abstraction:**
  - **Apple Intelligence** (default) — Apple’s on‑device model. Zero setup, fully private.
  - **Ollama** — any local model (`llama3.2`, `qwen2.5`, larger 14B‑class models…), with a built‑in setup wizard that detects Ollama, recommends models for your RAM, and pulls them with a progress bar. No terminal required.
  - **External** — any OpenAI‑compatible API, if you want a bigger cloud model. Chat leaves the Mac; **documents and search always stay local**.
- **Local embeddings** — Apple’s `NLContextualEmbedding` (on‑device, 512‑dim) or
  Ollama’s `nomic-embed-text` (768‑dim).
- **Rich ingestion** — PDFs (with **Vision OCR fallback** for scanned/image
  PDFs), web pages, plain text, and Markdown. Drag‑and‑drop onto the window.
- **Structured facts** — vendor, purchase date, warranty expiry, model, serial
  number. This makes *“is the warranty still valid?”* a real date comparison, not
  a guess.
- **On‑request web fetch** — ask Lore to find a product’s user manual or
  technical specs; it searches the web and lets you add the results to the shelf.
  Nothing is downloaded without your tap.
- **Scope guardrail** — Lore stays on topic, answering about your shelf’s
  documents and products rather than wandering off into general chit‑chat.
- **Liquid Glass UI** — native macOS 26 material with an adjustable
  transparency setting.
- **Multilingual UI** — English, German, Spanish, French, and Swedish
  (Settings › Appearance › Language). Your content and the model’s answers stay in
  whatever language you use.

## Privacy

- **On‑device by default.** The model and embeddings run locally; the database and
  imported files live in `~/Library/Application Support/Lore/`.
- **The only network egress** is (a) your local runtime (`localhost` Ollama),
  (b) web links or manuals you explicitly add, and (c) an external chat provider
  **only if you deliberately choose one** (shown with a persistent banner while active).
- **Untrusted content stays data, never instructions.** Retrieved document and
  web text is delimited in the prompt and never treated as commands — a
  prompt‑injection defence that matters for RAG.
- **No telemetry.** Lore phones no home.

## Requirements

- **macOS 26 (Tahoe)** or later — Lore uses the Liquid Glass and Apple
  Intelligence / Foundation Models APIs.
- **Xcode 26** (to build) and [**XcodeGen**](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`) — the Xcode project is generated from
  [`project.yml`](project.yml), which is the source of truth.
- **Optional:** [**Ollama**](https://ollama.com) — only needed if you want to run
  chat on a local Ollama model instead of Apple Intelligence. The in‑app setup
  wizard walks you through installing it and pulling models.

## Getting started

```bash
git clone https://github.com/crswebb/Lore.git
cd Lore
./run.sh
```

[`run.sh`](run.sh) regenerates the Xcode project, builds the app, and launches
it. To work in Xcode instead:

```bash
xcodegen generate
open Lore.xcodeproj
```

On first launch Lore defaults to **Apple Intelligence**, so there’s nothing else
to configure. To use a local Ollama model, open the setup wizard from the status
pill in the sidebar.

> **Note:** `Lore.xcodeproj` is generated and git‑ignored. Always edit
> [`project.yml`](project.yml) and re‑run `xcodegen generate` rather than
> changing the project in Xcode.

## How it works

Lore is a modular Swift package (`LorePackages`) linked by a thin app target:

| Module | Responsibility |
|---|---|
| `LoreCore` | Domain models and the `LLMProvider` / `EmbeddingProvider` protocols. |
| `LorePersistence` | GRDB (SQLite) stack, versioned migrations, repositories, FTS5, vector storage. |
| `LoreProviders` | Ollama, Apple Foundation Models, and OpenAI‑compatible chat; Ollama + Apple embeddings. |
| `LoreIngestion` | PDF (+ Vision OCR), web, and text extraction; chunking; metadata extraction. |
| `LoreRAG` | Hybrid retrieval (vector + keyword, RRF) and prompt building. |
| `LoreDesignSystem` | Liquid Glass components, tints, window effects. |
| `LoreUI` | SwiftUI features, the `AppModel` composition root, localization. |

The full design — data model, RAG pipeline, provider abstraction, storage and
security model, and roadmap — is documented in **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Contributing

Contributions are welcome. Lore uses the standard fork‑and‑pull‑request model:
anyone can fork the repo and open a PR; the maintainer reviews and merges.
See **[CONTRIBUTING.md](CONTRIBUTING.md)** for how to build, test, and structure
a change.

## License

Lore is released under the [MIT License](LICENSE).
