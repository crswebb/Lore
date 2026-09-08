import SwiftUI
import LoreCore
import LoreDesignSystem

/// Middle column: the project's chat history. The "New Chat" control is a split
/// button — clicking it starts a new chat; only its caret opens the menu.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @State private var renamingChat: Chat?
    @State private var renameText = ""

    var body: some View {
        List(selection: Binding(
            get: { model.selectedChatID },
            set: { id in if let id { Task { await model.select(chat: id) } } }
        )) {
            ForEach(model.chats) { chat in
                ChatRow(chat: chat)
                    .tag(chat.id)
                    .contextMenu {
                        Button("Rename…") { startRename(chat) }
                        Button("Delete", role: .destructive) {
                            Task { await model.deleteChat(chat.id) }
                        }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem {
                Menu {
                    if let current = model.selectedChatID,
                       let chat = model.chats.first(where: { $0.id == current }) {
                        Button("Rename Chat…") { startRename(chat) }
                        Button("Delete Chat", role: .destructive) {
                            Task { await model.deleteChat(current) }
                        }
                    }
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                } primaryAction: {
                    Task { await model.newChat() }
                }
                .help("New chat (▾ for more)")
            }
        }
        .alert("Rename chat", isPresented: Binding(
            get: { renamingChat != nil },
            set: { if !$0 { renamingChat = nil } }
        )) {
            TextField("Chat name", text: $renameText)
            Button("Rename") {
                if let chat = renamingChat { Task { await model.renameChat(chat.id, to: renameText) } }
                renamingChat = nil
            }
            Button("Cancel", role: .cancel) { renamingChat = nil }
        }
    }

    private func startRename(_ chat: Chat) {
        renameText = chat.title
        renamingChat = chat
    }
}

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title).lineLimit(1)
                Text(chat.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
