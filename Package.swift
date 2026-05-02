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
        .package(url: "https://github.com/phranck/TUIkit.git", from: "0.6.0"),
        .package(url: "https://github.com/wiedymi/swift-acp.git", branch: "main")
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
        .target(
            name: "ACPServer",
            dependencies: [
                "AgentCore",
                .product(name: "ACP", package: "swift-acp"),
                .product(name: "ACPModel", package: "swift-acp")
            ]
        ),
        .executableTarget(
            name: "agentctl",
            dependencies: [
                "AgentCore",
                "ACPServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TUIkit", package: "TUIkit"),
                .product(name: "ACP", package: "swift-acp"),
                .product(name: "ACPModel", package: "swift-acp")
            ]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        ),
        .testTarget(
            name: "AgentctlTests",
            dependencies: [
                "agentctl",
                .product(name: "TUIkit", package: "TUIkit")
            ]
        )
    ]
)
