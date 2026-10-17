// swift-tools-version: 6.0
import PackageDescription

// **A package of its own, not a target in `Linux/Package.swift`.** The probe
// should not ship with the app or run on every `swift build`; it is started
// by hand when someone wants to know whether translation works. What it
// checks is the package's real API, not a replica of it; otherwise it would
// test itself.
let package = Package(
    name: "LanguageProbe",
    dependencies: [.package(path: "../../../Packages/JellyfinKit")],
    targets: [
        .executableTarget(
            name: "LanguageProbe",
            dependencies: [.product(name: "JellyfinKit", package: "JellyfinKit")]
        )
    ]
)
