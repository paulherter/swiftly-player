// swift-tools-version: 6.0
import PackageDescription

// **Ein eigenes Paket, kein Ziel im Xcode-Projekt.** Auf Linux gibt es kein
// Xcode und keine `.xcodeproj`; gebaut wird mit SwiftPM. Die geteilte Logik
// kommt ueber einen Pfadverweis auf `Packages/JellyfinKit` herein — dieselben
// Dateien, die iOS, tvOS und macOS benutzen, ohne Kopie.
let package = Package(
    name: "SwiftlyLinux",
    dependencies: [
        .package(path: "../Packages/JellyfinKit"),
        .package(url: "https://github.com/AparokshaUI/adwaita-swift", from: "0.2.6"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftlyLinux",
            dependencies: [
                .product(name: "JellyfinKit", package: "JellyfinKit"),
                .product(name: "Adwaita", package: "adwaita-swift"),
            ]
        )
    ]
)
