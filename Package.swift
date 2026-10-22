// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Synod",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Synod", targets: ["SynodApp"]),
        .library(name: "SynodCore", targets: ["SynodCore"]),
        .library(name: "SynodWeb", targets: ["SynodWeb"]),
    ],
    targets: [
        .target(name: "SynodCore"),
        .target(name: "SynodWeb"),
        .executableTarget(
            name: "SynodApp",
            dependencies: ["SynodCore", "SynodWeb"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "SynodCoreTests",
            dependencies: ["SynodCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SynodWebTests", dependencies: ["SynodWeb"]),
        .testTarget(name: "SynodAppTests", dependencies: ["SynodApp", "SynodCore", "SynodWeb"]),
    ]
)
