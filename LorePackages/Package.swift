// swift-tools-version: 6.2
import PackageDescription

// Lore — modular packages.
//
// One package, several library targets, so features stay isolated and testable
// while the app links a single local package.
//
// Vector search note: v1 uses brute-force cosine over embeddings stored as
// BLOBs (dependency-free, correct, fine for personal-scale corpora). sqlite-vec
// is the documented scale-up path and can replace VectorIndex without touching
// callers. Keyword search uses SQLite FTS5 (built in, via GRDB).
let package = Package(
    name: "LorePackages",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "LoreCore", targets: ["LoreCore"]),
        .library(name: "LorePersistence", targets: ["LorePersistence"]),
        .library(name: "LoreProviders", targets: ["LoreProviders"]),
        .library(name: "LoreIngestion", targets: ["LoreIngestion"]),
        .library(name: "LoreRAG", targets: ["LoreRAG"]),
        .library(name: "LoreDesignSystem", targets: ["LoreDesignSystem"]),
        .library(name: "LoreUI", targets: ["LoreUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
    ],
    targets: [
        .target(name: "LoreCore"),

        .target(
            name: "LorePersistence",
            dependencies: [
                "LoreCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        .target(
            name: "LoreProviders",
            dependencies: ["LoreCore"]
        ),

        .target(
            name: "LoreIngestion",
            dependencies: [
                "LoreCore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),

        .target(
            name: "LoreRAG",
            dependencies: ["LoreCore"]
        ),

        .target(
            name: "LoreDesignSystem"
        ),

        .target(
            name: "LoreUI",
            dependencies: [
                "LoreCore",
                "LorePersistence",
                "LoreProviders",
                "LoreIngestion",
                "LoreRAG",
                "LoreDesignSystem",
            ]
        ),

        .testTarget(
            name: "LoreRAGTests",
            dependencies: ["LoreRAG"]
        ),
        .testTarget(
            name: "LorePersistenceTests",
            dependencies: ["LorePersistence"]
        ),
        .testTarget(
            name: "LoreProvidersTests",
            dependencies: ["LoreProviders"]
        ),
    ]
)
