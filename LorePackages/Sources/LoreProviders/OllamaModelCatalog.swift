import Foundation

/// Recommended local models, and a RAM-aware default so the setup wizard can
/// suggest something that will actually run on the user's Mac.
public enum OllamaModelCatalog {
    public static let defaultEmbeddingModel = "nomic-embed-text"
    public static let embeddingDimensions = 768

    public struct ChatModel: Sendable, Hashable {
        public let name: String
        public let label: String
        public let approxDownloadGB: Double
        public let minRecommendedRAMGB: Int
        public let blurb: String
    }

    /// Ordered smallest→largest.
    public static let chatModels: [ChatModel] = [
        ChatModel(name: "llama3.2:3b", label: "Llama 3.2 3B",
                  approxDownloadGB: 2.0, minRecommendedRAMGB: 8,
                  blurb: "Runs on any Apple-silicon Mac. Great starting point."),
        ChatModel(name: "qwen2.5:7b", label: "Qwen 2.5 7B",
                  approxDownloadGB: 4.7, minRecommendedRAMGB: 16,
                  blurb: "Stronger reasoning; recommended with 16 GB or more."),
        ChatModel(name: "llama3.1:8b", label: "Llama 3.1 8B",
                  approxDownloadGB: 4.9, minRecommendedRAMGB: 16,
                  blurb: "Well-rounded 8B model for richer answers."),
        ChatModel(name: "qwen2.5:14b", label: "Qwen 2.5 14B",
                  approxDownloadGB: 9.0, minRecommendedRAMGB: 32,
                  blurb: "High quality; best with 32 GB or more."),
    ]

    /// Pick a sensible default chat model for the given physical RAM.
    public static func recommendedChatModel(physicalMemoryBytes: UInt64) -> ChatModel {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824.0
        if gb >= 32 { return chatModels[3] }
        if gb >= 16 { return chatModels[2] }
        return chatModels[0]
    }
}
