// swift-tools-version: 6.1
import PackageDescription

// The playback bench (Wiedergabe-Pruefstand): the core's plan and player state machine drive the real AetherEngine
// without any screen, against real media files served by `cargo xtask fixture-server`. Tests only; run it with
// `Werkzeuge/wiedergabe-pruefstand.sh`.
let package = Package(
    name: "PlaybackBench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../SwiftlyCore"),
        .package(path: "../SwiftlyAether"),
        .package(path: "../JellyfinKit"),
        .package(url: "https://github.com/superuser404notfound/AetherEngine", .upToNextMinor(from: "7.58.0"),
                 traits: ["TrueHDObjectAudio", "DTSXObjectAudio"]),
    ],
    targets: [
        .testTarget(
            name: "PlaybackBenchTests",
            dependencies: [
                .product(name: "SwiftlyCore", package: "SwiftlyCore"),
                .product(name: "SwiftlyAether", package: "SwiftlyAether"),
                .product(name: "JellyfinKit", package: "JellyfinKit"),
                .product(name: "AetherEngine", package: "AetherEngine"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ],
    swiftLanguageModes: [.v6]
)
