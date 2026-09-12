import SwiftUI
import LoreCore
import LoreDesignSystem

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var inspecting: Citation?

    private var projectTint: Color {
        LoreTheme.color(hex: model.selectedProject?.colorTint ?? "#4F8EF7")
    }

    private var examples: [String] {
        [
            L("Summarize what's in this shelf."),
            L("What should I do about error code F01?"),
            L("Is the warranty still valid?"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.externalActive {
                externalBar
            }
            if !model.modelsReady {
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
                        MessageBubble(message: message, documents: model.documents, tint: projectTint) { citation in
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
            Text(L("Ask your shelf"))
                .font(.title2.bold())
            Text(L("Answers are grounded in this shelf's documents, with citations."))
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
            GrowingTextEditor(text: $draft, placeholder: L("Ask your shelf…"), onSubmit: send)
                .padding(.leading, 16)
                .padding(.vertical, 11)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canSend ? projectTint : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.trailing, 8)
            .padding(.bottom, 7)
        }
        .loreGlass(cornerRadius: 22)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
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
            Button {
                model.showDocuments.toggle()
            } label: {
                Label(L("Documents"), systemImage: "sidebar.right")
            }
            .help(L("Show or hide documents"))
        }
    }

    private var currentChatTitle: String {
        model.chats.first { $0.id == model.selectedChatID }?.title ?? L("Chat")
    }

    /// Persistent privacy indicator: chat is being sent to an external service.
    private var externalBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud")
            Text(L("Chat is sent to %@ using %@. Your documents stay on this Mac.", model.externalHost, model.settings.externalChatModel))
                .lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LoreTheme.accent.opacity(0.14))
    }

    private var setupBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(bannerMessage)
            Spacer()
            if bannerNeedsSettings {
                SettingsLink { Text(L("Open Settings")) }
                    .buttonStyle(.glass)
            } else {
                Button(L("Set up")) { model.showSetup = true }
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }

    private var bannerNeedsSettings: Bool {
        switch model.settings.chatSource {
        case .external: return !model.settings.externalConfigured
        case .apple: return !model.appleAvailable
        case .ollama: return false
        }
    }

    private var bannerMessage: String {
        switch model.settings.chatSource {
        case .external where !model.settings.externalConfigured:
            return L("Your external chat API isn't fully configured yet.")
        case .apple where !model.appleAvailable:
            return L("Apple Intelligence isn't available yet — enable it in System Settings.")
        case .ollama:
            return L("Local model isn't ready yet.")
        default:
            return L("Ollama is needed for document search (embeddings).")
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let documents: [Document]
    var tint: Color = LoreTheme.accent
    var onOpenCitation: (Citation) -> Void = { _ in }

    @State private var showSources = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.citations.isEmpty {
                    sourcesSection
                }
            }
            .padding(14)
            .background(
                isUser ? AnyShapeStyle(tint.opacity(0.28)) : AnyShapeStyle(.regularMaterial),
                in: .rect(cornerRadius: LoreTheme.cornerRadius)
            )
            .frame(maxWidth: 620, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var sourcesSection: some View {
        let count = dedupedCitations.count
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSources.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showSources ? 90 : 0))
                        .font(.caption2)
                    Text("\(count) " + (count == 1 ? L("source") : L("sources")))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSources {
                citationChips
            }
        }
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
