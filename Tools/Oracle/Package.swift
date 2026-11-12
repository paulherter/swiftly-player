// swift-tools-version: 6.0
import PackageDescription

// Differential oracle: runs the REAL Swift logic (JellyfinKit) on the inputs recorded in
// crates/swiftly-hardening/oracle/<domain>.in.json and writes <domain>.swift.json.
// Build with Xcode's toolchain (the swiftly toolchain cannot link here):
//   cargo xtask hardening --regen-oracle
let package = Package(
    name: "Oracle",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/JellyfinKit")],
    targets: [
        .executableTarget(
            name: "oracle",
            dependencies: [.product(name: "JellyfinKit", package: "JellyfinKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "bench",
            dependencies: [.product(name: "JellyfinKit", package: "JellyfinKit")],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
