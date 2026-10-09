// swift-tools-version: 6.1

import PackageDescription

// DurableAgents (working name: PiSwift).
// Later milestones can add PiAI, PiAgent, and DurableKit beside these targets.
// They are intentionally absent until there is a real provider and agent loop.

let package = Package(
    name: "DurableAgents",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "DurableCore", targets: ["DurableCore"]),
        .library(name: "DurableStore", targets: ["DurableStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "DurableCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DurableStore",
            dependencies: [
                "DurableCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CrashProbe",
            dependencies: ["DurableCore", "DurableStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableAgentsTests",
            dependencies: ["DurableCore", "DurableStore", "CrashProbe"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
