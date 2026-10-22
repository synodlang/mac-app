// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Synod",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Synod", targets: ["SynodApp"]),
        .library(name: "SynodCore", targets: ["SynodCore"]),
        .library(name: "SynodWeb", targets: ["SynodWeb"]),
        .executable(name: "synod-editor-mcp", targets: ["SynodEditorBridge"]),
        .executable(name: "fake-claude", targets: ["FakeClaude"]),
    ],
    targets: [
        .target(name: "SynodCore"),
        .target(name: "SynodWeb"),
        .executableTarget(
            name: "SynodApp",
            dependencies: ["SynodCore", "SynodWeb"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The stdio-to-socket bridge Claude Code launches as an MCP server. It must not depend on SynodApp.
        .executableTarget(name: "SynodEditorBridge"),
        // Test-support stand-in for the `claude` CLI. Never bundled.
        .executableTarget(name: "FakeClaude"),
        .testTarget(
            name: "SynodCoreTests",
            dependencies: ["SynodCore", "SynodEditorBridge", "FakeClaude"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SynodWebTests", dependencies: ["SynodWeb"]),
        .testTarget(name: "SynodAppTests", dependencies: ["SynodApp", "SynodCore", "SynodWeb"]),
    ]
)
