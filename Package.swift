// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "agentctl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "agentctl", targets: ["agentctl"]),
        .library(name: "AgentCore", targets: ["AgentCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.29.0"),
        .package(url: "https://github.com/phranck/TUIkit.git", from: "0.6.0")
    ],
    targets: [
        .target(
            name: "AgentCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "agentctl",
            dependencies: [
                "AgentCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TUIkit", package: "TUIkit")
            ]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        )
    ]
)
