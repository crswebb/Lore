import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LoreCore
import LoreDesignSystem

/// The documents panel — shown in the right-hand inspector (hidden by default).
/// Kept lightweight since most time is spent chatting, not administrating docs.
struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var showFileImporter = false
    @State private var showLinkSheet = false
    @State private var metadataDocument: Document?
    @State private var pdfTarget: PDFTarget?
    @State private var dropTargeted = false

    struct PDFTarget: Identifiable { let id = UUID(); let url: URL }

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
        .sheet(item: $pdfTarget) { target in PDFViewerSheet(url: target.url, page: nil) }
    }

    /// Open a document's original source.
    private func open(_ document: Document) {
        switch document.kind {
        case .webLink:
            if let url = document.sourceURL { openURL(url) }
        case .pdf:
            if let url = FileAccess.resolve(bookmark: document.fileBookmark, fallback: document.sourceURL)?.url {
                pdfTarget = PDFTarget(url: url)
            } else {
                model.errorMessage = L("Couldn't locate the file for “%@”.", document.title)
            }
        case .text, .markdown:
            if let url = FileAccess.resolve(bookmark: document.fileBookmark, fallback: document.sourceURL)?.url {
                NSWorkspace.shared.open(url)
            } else {
                model.errorMessage = L("Couldn't locate the file for “%@”.", document.title)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L("Documents")).font(.headline)
            Spacer()
            Menu {
                Button(L("Add Files…"), systemImage: "doc.badge.plus") { showFileImporter = true }
                Button(L("Add Link…"), systemImage: "link.badge.plus") { showLinkSheet = true }
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
                    Button {
                        open(document)
                    } label: {
                        DocumentRow(
                            document: document,
                            isIndexing: model.indexingDocumentIDs.contains(document.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help(L("Open %@", document.title))
                    .contextMenu {
                        Button(L("Open")) { open(document) }
                        Button(L("Edit facts…")) { metadataDocument = document }
                        Button(L("Re-index")) { Task { await model.reindex(document) } }
                        Divider()
                        Button(L("Delete"), role: .destructive) {
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
            Text(L("No documents yet")).font(.headline)
            Text(L("Drag files here, or use ＋ above. Add a receipt and Lore can offer to fetch its manual."))
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
                Text(document.title)
                    .foregroundStyle(LoreTheme.accent)
                    .lineLimit(1)
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
            return "\(pages) " + (pages == 1 ? L("page") : L("pages"))
        }
        return statusLabel(for: document.status)
    }
}
