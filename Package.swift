// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EyesOnYou",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "EyesOnYouCore", targets: ["EyesOnYouCore"]),
        .library(name: "EyesOnYouRuleEngine", targets: ["EyesOnYouRuleEngine"]),
        .library(name: "EyesOnYouStorage", targets: ["EyesOnYouStorage"]),
        .library(name: "EyesOnYouIPC", targets: ["EyesOnYouIPC"]),
        .library(name: "EyesOnYouProxyCore", targets: ["EyesOnYouProxyCore"]),
        .executable(name: "eyesonyou", targets: ["EyesOnYouCLI"]),
    ],
    targets: [
        .target(
            name: "EyesOnYouCore",
            path: "Packages/EyesOnYouCore/Sources/EyesOnYouCore"
        ),
        .testTarget(
            name: "EyesOnYouCoreTests",
            dependencies: ["EyesOnYouCore"],
            path: "Packages/EyesOnYouCore/Tests/EyesOnYouCoreTests"
        ),
        .target(
            name: "EyesOnYouRuleEngine",
            dependencies: ["EyesOnYouCore"],
            path: "Packages/EyesOnYouRuleEngine/Sources/EyesOnYouRuleEngine"
        ),
        .testTarget(
            name: "EyesOnYouRuleEngineTests",
            dependencies: ["EyesOnYouRuleEngine", "EyesOnYouCore"],
            path: "Packages/EyesOnYouRuleEngine/Tests/EyesOnYouRuleEngineTests"
        ),
        .target(
            name: "EyesOnYouStorage",
            dependencies: ["EyesOnYouCore"],
            path: "Packages/EyesOnYouStorage/Sources/EyesOnYouStorage"
        ),
        .testTarget(
            name: "EyesOnYouStorageTests",
            dependencies: ["EyesOnYouStorage", "EyesOnYouCore"],
            path: "Packages/EyesOnYouStorage/Tests/EyesOnYouStorageTests"
        ),
        .target(
            name: "EyesOnYouIPC",
            dependencies: ["EyesOnYouCore"],
            path: "Packages/EyesOnYouIPC/Sources/EyesOnYouIPC"
        ),
        .target(
            name: "EyesOnYouProxyCore",
            dependencies: ["EyesOnYouCore", "EyesOnYouRuleEngine"],
            path: "Packages/EyesOnYouProxyCore/Sources/EyesOnYouProxyCore"
        ),
        .testTarget(
            name: "EyesOnYouProxyCoreTests",
            dependencies: ["EyesOnYouProxyCore", "EyesOnYouCore", "EyesOnYouRuleEngine"],
            path: "Packages/EyesOnYouProxyCore/Tests/EyesOnYouProxyCoreTests"
        ),
        // Agent-oriented CLI (JSON stdout, no interactive prompts).
        .executableTarget(
            name: "EyesOnYouCLI",
            dependencies: [
                "EyesOnYouCore",
                "EyesOnYouRuleEngine",
                "EyesOnYouStorage",
                "EyesOnYouProxyCore",
                "EyesOnYouIPC",
            ],
            path: "Sources/EyesOnYouCLI"
        ),
    ]
)
