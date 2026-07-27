// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Shard",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Shard", targets: ["Shard"]),
        .library(name: "ShardCore", targets: ["ShardCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "ShardCore",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "Shard",
            dependencies: ["ShardCore"],
            path: "Sources/ShardApp",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "ShardCoreTests",
            dependencies: ["ShardCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
