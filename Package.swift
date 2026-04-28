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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "AgentCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "agentctl",
            dependencies: [
                "AgentCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        )
    ]
)
