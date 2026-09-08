import SwiftUI
import PDFKit
import AppKit
import LoreCore
import LoreDesignSystem

/// Shown when a citation chip is tapped: the exact passage Lore retrieved, plus
/// a way to open the original source (PDF at the cited page, web link, or file).
/// This is what lets you verify an answer when two models disagree.
struct SourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let citation: Citation

    @State private var details: AppModel.SourceDetails?
    @State private var showPDF = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let details {
                header(details)
                Divider()
                passage(details)
                Spacer()
                actions(details)
            } else {
                ProgressView("Loading source…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
        .task { details = await model.sourceDetails(for: citation) }
        .sheet(isPresented: $showPDF) {
            if let details, let url = resolvedURL(details.document) {
                PDFViewerSheet(url: url, page: citation.page)
            }
        }
    }

    private func header(_ details: AppModel.SourceDetails) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: details.document.kind))
                .font(.largeTitle)
                .foregroundStyle(LoreTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(details.document.title).font(.title2.bold())
                if let page = citation.page {
                    Text("Page \(page)").foregroundStyle(.secondary)
                } else if let host = details.document.sourceURL?.host {
                    Text(host).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func passage(_ details: AppModel.SourceDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Passage Lore used", systemImage: "quote.opening")
                .font(.headline).foregroundStyle(.secondary)
            ScrollView {
                Text(details.passage.isEmpty ? "(passage unavailable)" : details.passage)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .loreGlass(cornerRadius: LoreTheme.smallCornerRadius)
        }
    }

    @ViewBuilder
    private func actions(_ details: AppModel.SourceDetails) -> some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
            switch details.document.kind {
            case .pdf:
                Button {
                    showPDF = true
                } label: {
                    Label(citation.page.map { "Open PDF at page \($0)" } ?? "Open PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.glassProminent)
            case .webLink:
                if let url = details.document.sourceURL {
                    Button {
                        openURL(url)
                    } label: { Label("Open link", systemImage: "safari") }
                        .buttonStyle(.glassProminent)
                }
            case .text, .markdown:
                if let url = resolvedURL(details.document) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: { Label("Open file", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func resolvedURL(_ document: Document) -> URL? {
        FileAccess.resolve(bookmark: document.fileBookmark, fallback: document.sourceURL)?.url
    }
}

/// A minimal in-app PDF reader that opens at a specific page.
struct PDFViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let page: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            PDFKitView(url: url, page: page)
        }
        .frame(width: 800, height: 700)
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    let page: Int?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        if let document = PDFDocument(url: url) {
            view.document = document
            if let page, page >= 1, let pdfPage = document.page(at: page - 1) {
                DispatchQueue.main.async { view.go(to: pdfPage) }
            }
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}
