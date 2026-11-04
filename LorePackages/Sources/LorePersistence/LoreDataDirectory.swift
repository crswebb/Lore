import Foundation

/// Resolves the folder where Lore keeps its database and imported files.
///
/// By default this is `~/Library/Application Support/Lore/`. Setting the
/// `LORE_DATA_DIR` environment variable points Lore at another folder instead,
/// so a development build (or a demo, or a test run) can use scratch data
/// without touching the shelves of a Lore copy you use day to day:
///
///     LORE_DATA_DIR=/tmp/lore-dev ./run.sh
///     open --env LORE_DATA_DIR=/tmp/lore-dev Lore.app
///
/// A leading `~` is expanded. Empty or whitespace-only values are ignored.
public enum LoreDataDirectory {
    /// The environment variable that overrides the data folder.
    public static let environmentKey = "LORE_DATA_DIR"

    /// The data folder, created if it doesn't exist yet.
    public static func url(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let dir: URL
        if let override = overrideURL(environment: environment) {
            dir = override
        } else {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dir = base.appendingPathComponent("Lore", isDirectory: true)
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The override folder from `LORE_DATA_DIR`, or `nil` when it isn't set.
    public static func overrideURL(environment: [String: String]) -> URL? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
