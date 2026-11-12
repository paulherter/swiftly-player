// swift-tools-version: 6.1
import PackageDescription

// The Swiftly Rust core. `Sources/SwiftlyCore/Generated.swift` and `SwiftlyCoreFFI.xcframework`
// come from `cargo run -p xtask -- apple`; the xcframework is git-ignored.
let package = Package(
    name: "SwiftlyCore",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SwiftlyCore", targets: ["SwiftlyCore"])
    ],
    dependencies: [
        // Tests only: the old Swift rules run next to the core on the same fixtures.
        .package(path: "../JellyfinKit")
    ],
    targets: [
        .binaryTarget(name: "SwiftlyCoreFFI", path: "SwiftlyCoreFFI.xcframework"),
        .target(
            name: "SwiftlyCore", dependencies: ["SwiftlyCoreFFI"],
            // Security: the Keychain store. HTTP is URLSession (no TLS stack in the core).
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .testTarget(
            name: "SwiftlyCoreTests",
            dependencies: [
                "SwiftlyCore",
                .product(name: "JellyfinKit", package: "JellyfinKit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
