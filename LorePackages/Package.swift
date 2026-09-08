// swift-tools-version: 6.2
import PackageDescription

// Lore — modular packages.
//
// One package, several library targets, so features stay isolated and testable
// while the app links a single local package. External dependencies (GRDB,
// sqlite-vec, SwiftSoup, Sparkle) are introduced per-milestone as the matching
// modules land; the pure-logic core builds and tests with zero dependencies.
let package = Package(
    name: "LorePackages",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "LoreCore", targets: ["LoreCore"]),
        .library(name: "LoreRAG", targets: ["LoreRAG"]),
    ],
    targets: [
        // Domain models + provider protocols. No dependencies.
        .target(
            name: "LoreCore"
        ),
        // Retrieval logic: chunking + rank fusion. Pure, deterministic, testable.
        .target(
            name: "LoreRAG",
            dependencies: ["LoreCore"]
        ),
        .testTarget(
            name: "LoreRAGTests",
            dependencies: ["LoreRAG"]
        ),
    ]
)
