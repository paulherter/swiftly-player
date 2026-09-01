// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    // Deutsch ist die Ausgangssprache: die Texte stehen im Code auf Deutsch
    // und dienen zugleich als Schlüssel. Englisch kommt aus dem Katalog.
    defaultLocalization: "de",
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
