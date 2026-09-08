import Foundation
import SwiftSoup

/// A candidate user manual found on the web.
public struct ManualCandidate: Identifiable, Sendable, Hashable {
    public var id: URL { url }
    public let title: String
    public let url: URL
    public let isPDF: Bool

    public init(title: String, url: URL, isPDF: Bool) {
        self.title = title
        self.url = url
        self.isPDF = isPDF
    }
}

/// Finds user manuals via a keyless web search (DuckDuckGo HTML endpoint),
/// parsed with SwiftSoup. Results are ranked with PDFs and manual-ish pages
/// first; the user always chooses which (if any) to add.
public struct ManualFinderService: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func search(query: String, limit: Int = 8) async throws -> [ManualCandidate] {
        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = "q=\(encoded)&kl=us-en".data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return try Self.parse(html: html, limit: limit)
    }

    static func parse(html: String, limit: Int) throws -> [ManualCandidate] {
        let doc = try SwiftSoup.parse(html)
        var seen = Set<URL>()
        var candidates: [ManualCandidate] = []

        for anchor in try doc.select("a.result__a") {
            let title = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
            var href = try anchor.attr("href")
            if let real = decodeRedirect(href) { href = real }
            guard let url = URL(string: href), url.scheme?.hasPrefix("http") == true else { continue }
            guard seen.insert(url).inserted else { continue }
            let isPDF = url.pathExtension.lowercased() == "pdf"
            candidates.append(ManualCandidate(title: title.isEmpty ? url.host ?? href : title, url: url, isPDF: isPDF))
        }

        // Rank: PDFs and URLs that look like manuals first.
        let ranked = candidates.sorted { lhs, rhs in
            score(lhs) > score(rhs)
        }
        return Array(ranked.prefix(limit))
    }

    private static func score(_ c: ManualCandidate) -> Int {
        var s = 0
        if c.isPDF { s += 3 }
        let haystack = (c.url.absoluteString + " " + c.title).lowercased()
        for kw in ["manual", "guide", "instruction", "handbook", "datasheet", "support"] where haystack.contains(kw) {
            s += 1
        }
        return s
    }

    /// DuckDuckGo wraps target URLs as `//duckduckgo.com/l/?uddg=<encoded>`.
    static func decodeRedirect(_ href: String) -> String? {
        let normalized = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: normalized),
              components.host?.contains("duckduckgo.com") == true,
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return nil }
        return uddg
    }
}
