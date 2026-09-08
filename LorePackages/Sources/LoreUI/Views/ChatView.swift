import SwiftUI
import LoreCore
import LoreDesignSystem

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var inspecting: Citation?

    private let examples = [
        "Summarize what's in this project.",
        "What should I do about error code F01?",
        "Is the warranty still valid?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if case .ready = model.health, model.modelsReady {
                EmptyView()
            } else {
                setupBanner
            }

            messagesList

            composer
        }
        .navigationTitle(currentChatTitle)
        .toolbar { chatToolbar }
        .sheet(item: $inspecting) { citation in
            SourceView(citation: citation).environment(model)
        }
    }

    // MARK: Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message, documents: model.documents) { citation in
                            inspecting = citation
                        }
                        .id(message.id)
                    }
                }
                .padding(20)
            }
            .onChange(of: model.messages.last?.text) {
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask your project")
                .font(.title2.bold())
            Text("Answers are grounded in this project's documents, with citations.")
                .foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { example in
                Button {
                    draft = example
                } label: {
                    HStack {
                        Image(systemName: "text.bubble")
                        Text(example)
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .loreGlass(cornerRadius: LoreTheme.smallCornerRadius)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.top, 30)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask your project…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(12)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canSend ? LoreTheme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        .loreGlass()
        .padding(16)
        .overlay(alignment: .top) {
            if model.isResponding {
                ProgressView().controlSize(.small).padding(.top, 2)
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isResponding && model.modelsReady
    }

    private func send() {
        guard canSend else { return }
        let question = draft
        draft = ""
        Task { await model.send(question) }
    }

    // MARK: Toolbar & banner

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("New Chat", systemImage: "plus") { Task { await model.newChat() } }
                if !model.chats.isEmpty {
                    Divider()
                    ForEach(model.chats) { chat in
                        Button {
                            Task { await model.select(chat: chat.id) }
                        } label: {
                            Label(chat.title, systemImage: chat.id == model.selectedChatID ? "checkmark" : "bubble.left")
                        }
                    }
                    Divider()
                    if let current = model.selectedChatID {
                        Button("Delete This Chat", systemImage: "trash", role: .destructive) {
                            Task { await model.deleteChat(current) }
                        }
                    }
                }
            } label: {
                Label("Chats", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    private var currentChatTitle: String {
        model.chats.first { $0.id == model.selectedChatID }?.title ?? "Chat"
    }

    private var setupBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text("Local model isn't ready yet.")
            Spacer()
            Button("Set up") { model.showSetup = true }
                .buttonStyle(.glass)
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}

struct MessageBubble: View {
    let message: Message
    let documents: [Document]
    var onOpenCitation: (Citation) -> Void = { _ in }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.citations.isEmpty {
                    citationChips
                }
            }
            .padding(14)
            .background(
                isUser ? AnyShapeStyle(LoreTheme.accent.opacity(0.22)) : AnyShapeStyle(.regularMaterial),
                in: .rect(cornerRadius: LoreTheme.cornerRadius)
            )
            .frame(maxWidth: 620, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var citationChips: some View {
        let refs = dedupedCitations
        return FlowLayout(spacing: 6) {
            ForEach(refs, id: \.label) { ref in
                Button {
                    onOpenCitation(ref.citation)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.caption2)
                        Text(ref.label).font(.caption2)
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: .capsule)
                }
                .buttonStyle(.plain)
                .help("View source")
            }
        }
    }

    private var dedupedCitations: [(label: String, citation: Citation)] {
        var seen = Set<String>()
        var result: [(label: String, citation: Citation)] = []
        for citation in message.citations {
            let title = documents.first { $0.id == citation.documentID }?.title ?? "Source"
            let label = citation.page.map { "\(title) p.\($0)" } ?? title
            if seen.insert(label).inserted { result.append((label, citation)) }
        }
        return result
    }
}
