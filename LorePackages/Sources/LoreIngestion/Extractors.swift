import Foundation
import PDFKit
import SwiftSoup
import LoreCore

/// Text extracted from a source, split into pages where the format has them.
public struct ExtractedContent: Sendable {
    public struct Page: Sendable {
        public let pageNumber: Int?
        public let text: String
        public init(pageNumber: Int?, text: String) {
            self.pageNumber = pageNumber
            self.text = text
        }
    }

    public var title: String
    public var pages: [Page]
    public var pageCount: Int?

    public init(title: String, pages: [Page], pageCount: Int? = nil) {
        self.title = title
        self.pages = pages
        self.pageCount = pageCount
    }

    public var fullText: String {
        pages.map(\.text).joined(separator: "\n\n")
    }
}

public enum IngestionError: Error, LocalizedError {
    case unreadableFile(URL)
    case unsupportedPDF(URL)
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let url): return "Couldn't read the file at \(url.lastPathComponent)."
        case .unsupportedPDF(let url): return "Couldn't open the PDF \(url.lastPathComponent)."
        case .emptyContent: return "No readable text was found."
        }
    }
}

/// Plain text / Markdown files.
public struct TextExtractor: Sendable {
    public init() {}

    public func extract(fileURL: URL) throws -> ExtractedContent {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw IngestionError.unreadableFile(fileURL) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IngestionError.emptyContent }

        return ExtractedContent(
            title: fileURL.deletingPathExtension().lastPathComponent,
            pages: [ExtractedContent.Page(pageNumber: nil, text: trimmed)]
        )
    }
}

/// PDF files, one `Page` per PDF page so citations can point at page numbers.
public struct PDFExtractor: Sendable {
    public init() {}

    public func extract(fileURL: URL) throws -> ExtractedContent {
        guard let doc = PDFDocument(url: fileURL) else {
            throw IngestionError.unsupportedPDF(fileURL)
        }
        var pages: [ExtractedContent.Page] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            pages.append(ExtractedContent.Page(pageNumber: index + 1, text: text))
        }
        guard !pages.isEmpty else { throw IngestionError.emptyContent }

        let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return ExtractedContent(
            title: (title?.isEmpty == false ? title! : fileURL.deletingPathExtension().lastPathComponent),
            pages: pages,
            pageCount: doc.pageCount
        )
    }
}

/// Web links: fetch, then extract a readable title + body text with SwiftSoup.
public struct WebExtractor: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func extract(url: URL) async throws -> ExtractedContent {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Lore/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, _) = try await session.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestionError.unreadableFile(url)
        }
        return try Self.parse(html: html, url: url)
    }

    /// Split out so it is unit-testable without a network fetch.
    public static func parse(html: String, url: URL) throws -> ExtractedContent {
        let doc = try SwiftSoup.parse(html, url.absoluteString)

        // Prefer a meaningful title.
        let ogTitle = try doc.select("meta[property=og:title]").first()?.attr("content")
        let docTitle = try? doc.title()
        let title = [ogTitle, docTitle].compactMap { $0 }.first { !$0.isEmpty } ?? url.host ?? url.absoluteString

        // Strip chrome that never carries the real content.
        try doc.select("script, style, noscript, nav, header, footer, form, aside, iframe").remove()

        let root = (try? doc.select("article").first()) ?? doc.body()
        let text = (try root?.text() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IngestionError.emptyContent }

        return ExtractedContent(
            title: title,
            pages: [ExtractedContent.Page(pageNumber: nil, text: text)]
        )
    }
}
