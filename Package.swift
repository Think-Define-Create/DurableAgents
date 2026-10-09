// swift-tools-version: 6.1

import PackageDescription

// DurableAgents (working name: PiSwift).
// DurableFoundationModels compiles on Linux as a stub. The Apple framework is
// wrapped in canImport(FoundationModels) and availability checks.

let package = Package(
    name: "DurableAgents",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "DurableCore", targets: ["DurableCore"]),
        .library(name: "DurableStore", targets: ["DurableStore"]),
        .library(name: "DurableKit", targets: ["DurableKit"]),
        .library(name: "DurableFoundationModels", targets: ["DurableFoundationModels"]),
        .library(name: "PiAI", targets: ["PiAI"]),
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
        .target(
            name: "DurableKit",
            dependencies: ["DurableCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DurableFoundationModels",
            dependencies: ["DurableCore"],
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
            dependencies: ["DurableCore", "DurableStore", "CrashProbe", "DurableFoundationModels"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "PiAI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "PiAITests",
            dependencies: ["PiAI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableKitTests",
            dependencies: ["DurableCore", "DurableStore", "DurableKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
