// swift-tools-version: 6.1

import PackageDescription

// DurableAgents.
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
        .library(name: "ModelKit", targets: ["ModelKit"]),
        .library(name: "AgentLoop", targets: ["AgentLoop"]),
        .library(name: "DurableSecurity", targets: ["DurableSecurity"]),
        .library(name: "DurableDelivery", targets: ["DurableDelivery"]),
        .library(name: "DurableMCP", targets: ["DurableMCP"]),
        .library(name: "AgentAppCore", targets: ["AgentAppCore"]),
        .executable(name: "mcp-fixture", targets: ["MCPFixture"]),
        .library(name: "DurableObserve", targets: ["DurableObserve"]),
        .executable(name: "durable-audit", targets: ["DurableAudit"]),
        .library(name: "DurableImport", targets: ["DurableImport"]),
        .executable(name: "durable-import", targets: ["DurableImportCLI"]),
        .library(name: "DurableSchedule", targets: ["DurableSchedule"]),
        .library(name: "DurableIdentity", targets: ["DurableIdentity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"3.15.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
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
            dependencies: ["DurableCore", "ModelKit"],
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
            name: "DurableSecurity",
            dependencies: [
                "DurableCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "AgentLoop",
            dependencies: ["DurableCore", "ModelKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ModelKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableSecurityTests",
            dependencies: ["DurableSecurity", "DurableCore", "DurableStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AgentLoopTests",
            dependencies: ["AgentLoop", "ModelKit", "DurableCore", "DurableStore", "DurableFoundationModels"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ModelKitTests",
            dependencies: ["ModelKit"],
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
        .target(
            name: "DurableObserve",
            dependencies: [
                "DurableCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "DurableAudit",
            dependencies: [
                "DurableCore",
                "DurableStore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableObserveTests",
            dependencies: ["DurableObserve", "DurableCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DurableImport",
            dependencies: [
                "DurableCore",
                "DurableStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "DurableImportCLI",
            dependencies: [
                "DurableImport",
                "DurableCore",
                "DurableStore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableImportTests",
            dependencies: ["DurableImport", "DurableCore", "DurableStore", "DurableImportCLI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DurableDelivery",
            dependencies: [
                "DurableCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableDeliveryTests",
            dependencies: ["DurableDelivery", "DurableCore", "DurableStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DurableMCP",
            dependencies: [
                "DurableCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "MCPFixture",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableMCPTests",
            dependencies: [
                "DurableMCP",
                "DurableCore",
                "DurableStore",
                "MCPFixture",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "AgentAppCore",
            dependencies: [
                "DurableCore",
                "ModelKit",
                "AgentLoop",
                "DurableSecurity",
                "DurableMCP",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AgentAppCoreTests",
            dependencies: [
                "AgentAppCore",
                "DurableCore",
                "DurableStore",
                "DurableSecurity",
                "DurableMCP",
                "ModelKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableAuditTests",
            dependencies: ["DurableAudit", "DurableCore", "DurableStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DurableSchedule",
            dependencies: ["DurableCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableScheduleTests",
            dependencies: ["DurableSchedule", "DurableCore", "DurableStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DurableIdentity",
            dependencies: ["DurableCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DurableIdentityTests",
            dependencies: ["DurableIdentity", "DurableCore", "DurableStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
