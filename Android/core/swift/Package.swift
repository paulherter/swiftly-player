// swift-tools-version: 6.2
//
// **Bridge from Kotlin to JellyfinKit.**
//
// The only Swift code written for Android: a thin facade over the package. jextract (swift-java,
// JNI mode) generates Java wrappers from it, which the Android app calls from Kotlin.
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiftlyCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwiftlyCore", type: .dynamic, targets: ["SwiftlyCore"])
    ],
    dependencies: [
        .package(path: "../../../Packages/JellyfinKit"),
        // Same version as the official example the toolchain was verified against.
        .package(url: "https://github.com/swiftlang/swift-java", exact: "0.6.0"),
    ],
    targets: [
        .target(
            name: "SwiftlyCore",
            dependencies: [
                .product(name: "JellyfinKit", package: "JellyfinKit"),
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [.plugin(name: "JExtractSwiftPlugin", package: "swift-java")]
        )
    ]
)
