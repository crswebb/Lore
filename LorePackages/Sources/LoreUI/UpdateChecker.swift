import Foundation

/// A published release worth updating to.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: String   // e.g. "0.2.0" (leading "v" stripped)
    public let url: URL          // the release page to send the user to
}

/// Checks GitHub Releases for a newer version of Lore.
///
/// This is the only place Lore reaches the network on its own behalf. It sends
/// no user data — a plain unauthenticated GET to the public GitHub API — and is
/// best-effort: offline, rate-limited, or malformed responses simply mean "no
/// update found". The user can turn it off (Settings › Advanced).
struct UpdateChecker {
    /// GitHub's "latest" endpoint excludes drafts and pre-releases.
    static let feedURL = URL(string: "https://api.github.com/repos/crswebb/Lore/releases/latest")!

    private struct LatestRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    /// Fetch the latest published release, or `nil` if there isn't one.
    func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: Self.feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil   // 404 = no releases yet; anything else = treat as "no update"
        }
        let release = try JSONDecoder().decode(LatestRelease.self, from: data)
        guard let url = URL(string: release.html_url) else { return nil }
        return ReleaseInfo(version: Self.normalize(release.tag_name), url: url)
    }

    /// Strip a leading "v" and surrounding whitespace: "v0.2.0" → "0.2.0".
    static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// True if `remote` is a strictly higher semantic version than `local`.
    /// Compares dot-separated numeric components; missing components count as 0,
    /// and any non-numeric component compares as 0 (best-effort, never throws).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote)
        let l = components(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
