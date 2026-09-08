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
                  approxDownloadGB: 9.0, minRecommendedRAMGB: 24,
                  blurb: "High quality; great on 24 GB or more."),
        ChatModel(name: "qwen2.5:32b", label: "Qwen 2.5 32B",
                  approxDownloadGB: 20.0, minRecommendedRAMGB: 48,
                  blurb: "Excellent quality; needs roughly 48 GB."),
        ChatModel(name: "gemma2:27b", label: "Gemma 2 27B",
                  approxDownloadGB: 16.0, minRecommendedRAMGB: 48,
                  blurb: "Strong all-rounder; needs roughly 48 GB."),
        ChatModel(name: "llama3.1:70b", label: "Llama 3.1 70B",
                  approxDownloadGB: 43.0, minRecommendedRAMGB: 64,
                  blurb: "Top-tier quality; needs 64 GB or more."),
        ChatModel(name: "qwen2.5:72b", label: "Qwen 2.5 72B",
                  approxDownloadGB: 47.0, minRecommendedRAMGB: 64,
                  blurb: "Largest option; needs 64 GB or more."),
    ]

    /// Pick a sensible default chat model for the given physical RAM, by name so
    /// it stays correct as the catalog grows.
    public static func recommendedChatModel(physicalMemoryBytes: UInt64) -> ChatModel {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824.0
        let preferred: String
        switch gb {
        case 64...: preferred = "llama3.1:70b"
        case 48..<64: preferred = "qwen2.5:32b"
        case 24..<48: preferred = "qwen2.5:14b"
        case 16..<24: preferred = "llama3.1:8b"
        default: preferred = "llama3.2:3b"
        }
        return chatModels.first { $0.name == preferred } ?? chatModels[0]
    }
}
