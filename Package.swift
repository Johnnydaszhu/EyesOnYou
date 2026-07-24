// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlowLens",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FlowLensCore", targets: ["FlowLensCore"]),
        .library(name: "FlowLensRuleEngine", targets: ["FlowLensRuleEngine"]),
        .library(name: "FlowLensStorage", targets: ["FlowLensStorage"]),
        .library(name: "FlowLensIPC", targets: ["FlowLensIPC"]),
        .library(name: "FlowLensProxyCore", targets: ["FlowLensProxyCore"]),
        .executable(name: "flowlens", targets: ["FlowLensCLI"]),
    ],
    targets: [
        .target(
            name: "FlowLensCore",
            path: "Packages/FlowLensCore/Sources/FlowLensCore"
        ),
        .testTarget(
            name: "FlowLensCoreTests",
            dependencies: ["FlowLensCore"],
            path: "Packages/FlowLensCore/Tests/FlowLensCoreTests"
        ),
        .target(
            name: "FlowLensRuleEngine",
            dependencies: ["FlowLensCore"],
            path: "Packages/FlowLensRuleEngine/Sources/FlowLensRuleEngine"
        ),
        .testTarget(
            name: "FlowLensRuleEngineTests",
            dependencies: ["FlowLensRuleEngine", "FlowLensCore"],
            path: "Packages/FlowLensRuleEngine/Tests/FlowLensRuleEngineTests"
        ),
        .target(
            name: "FlowLensStorage",
            dependencies: ["FlowLensCore"],
            path: "Packages/FlowLensStorage/Sources/FlowLensStorage"
        ),
        .testTarget(
            name: "FlowLensStorageTests",
            dependencies: ["FlowLensStorage", "FlowLensCore"],
            path: "Packages/FlowLensStorage/Tests/FlowLensStorageTests"
        ),
        .target(
            name: "FlowLensIPC",
            dependencies: ["FlowLensCore"],
            path: "Packages/FlowLensIPC/Sources/FlowLensIPC"
        ),
        .target(
            name: "FlowLensProxyCore",
            dependencies: ["FlowLensCore", "FlowLensRuleEngine"],
            path: "Packages/FlowLensProxyCore/Sources/FlowLensProxyCore"
        ),
        .testTarget(
            name: "FlowLensProxyCoreTests",
            dependencies: ["FlowLensProxyCore", "FlowLensCore", "FlowLensRuleEngine"],
            path: "Packages/FlowLensProxyCore/Tests/FlowLensProxyCoreTests"
        ),
        // Agent-oriented CLI (JSON stdout, no interactive prompts).
        .executableTarget(
            name: "FlowLensCLI",
            dependencies: [
                "FlowLensCore",
                "FlowLensRuleEngine",
                "FlowLensStorage",
                "FlowLensProxyCore",
                "FlowLensIPC",
            ],
            path: "Sources/FlowLensCLI"
        ),
    ]
)
