// swift-tools-version: 6.1
import PackageDescription

// **Why a wrapper.** AetherEngine's optional parts (TrueHD and DTS:X height channels,
// dual-layer Dolby Vision) are package traits, and XcodeGen cannot write traits into the
// project. The app depends on this package instead; the traits are set here, in one place.
// Pinned to one minor release: the engine is young and changes fast.
let package = Package(
    name: "SwiftlyAether",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SwiftlyAether", targets: ["SwiftlyAether"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            .upToNextMinor(from: "7.58.0"),
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio"]
        )
    ],
    targets: [
        .target(
            name: "SwiftlyAether",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        )
    ]
)
