// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    // The texts in the code are German and double as lookup keys; English comes
    // from the catalog.
    // **This is the fallback language of the package bundle, not the source language.**
    // The keys stay German (`de.lproj` maps them to themselves). A device set to
    // Dutch or Russian gets exactly this value; with "de" it would show German
    // error messages in an English app. Same value as CFBundleDevelopmentRegion
    // in the four Info.plists.
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"])
    ],
    targets: [
        .target(name: "JellyfinKit",
                resources: [.process("Resources")]),
        .testTarget(name: "JellyfinKitTests", dependencies: ["JellyfinKit"])
    ]
)
