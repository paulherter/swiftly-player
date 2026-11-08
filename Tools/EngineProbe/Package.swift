// swift-tools-version: 6.1
import PackageDescription

// Headless macOS probe for the Aether engine. Separate package: the app targets never see it.
let package = Package(
    name: "EngineProbe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/SwiftlyAether")],
    targets: [
        .executableTarget(
            name: "aether-probe",
            dependencies: [.product(name: "SwiftlyAether", package: "SwiftlyAether")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
