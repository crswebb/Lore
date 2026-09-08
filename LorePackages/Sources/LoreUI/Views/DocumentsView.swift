import SwiftUI
import UniformTypeIdentifiers
import LoreCore
import LoreDesignSystem

/// The documents panel — shown in the right-hand inspector (hidden by default).
/// Kept lightweight since most time is spent chatting, not administrating docs.
struct DocumentsView: View {
    @Environment(AppModel.self) private var model

    @State private var showFileImporter = false
    @State private var showLinkSheet = false
    @State private var metadataDocument: Document?
    @State private var dropTargeted = false

    private var allowedTypes: [UTType] {
        [.pdf, .plainText, .text, UTType(filenameExtension: "md") ?? .plainText]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter { $0.isFileURL }
            guard !fileURLs.isEmpty else { return false }
            Task { await model.addFiles(fileURLs) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: LoreTheme.cornerRadius)
                    .strokeBorder(LoreTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(6)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { Task { await model.addFiles(urls) } }
        }
        .sheet(isPresented: $showLinkSheet) { AddLinkSheet().environment(model) }
        .sheet(item: $metadataDocument) { doc in MetadataSheet(document: doc).environment(model) }
    }

    private var header: some View {
        HStack {
            Text("Documents").font(.headline)
            Spacer()
            Menu {
                Button("Add Files…", systemImage: "doc.badge.plus") { showFileImporter = true }
                Button("Add Link…", systemImage: "link.badge.plus") { showLinkSheet = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            if model.documents.isEmpty {
                emptyState
            } else {
                ForEach(model.documents) { document in
                    DocumentRow(
                        document: document,
                        isIndexing: model.indexingDocumentIDs.contains(document.id)
                    )
                    .contextMenu {
                        Button("Edit facts…") { metadataDocument = document }
                        Button("Re-index") { Task { await model.reindex(document) } }
                        Divider()
                        Button("Delete", role: .destructive) {
                            Task { await model.deleteDocument(document.id) }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No documents yet").font(.headline)
            Text("Drag files here, or use ＋ above. Add a receipt and Lore can offer to fetch its manual.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .listRowSeparator(.hidden)
    }
}

struct DocumentRow: View {
    let document: Document
    let isIndexing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: document.kind))
                .font(.title3)
                .foregroundStyle(LoreTheme.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title).lineLimit(1)
                HStack(spacing: 6) {
                    if !document.metadata.isEmpty {
                        Image(systemName: "tag.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isIndexing || (document.status != .ready && document.status != .failed) {
                ProgressView().controlSize(.small)
            } else if document.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if document.status == .ready, let pages = document.pageCount {
            return "\(pages) page\(pages == 1 ? "" : "s")"
        }
        return statusLabel(for: document.status)
    }
}
