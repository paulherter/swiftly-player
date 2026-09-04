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
        // **Nicht GitHub.** Das Projekt liegt dort seit Oktober 2024 nur noch
        // archiviert; die gepflegte Fassung ist nach Codeberg umgezogen und
        // hat die Zaehlung bei 0.1.0 neu begonnen.
        .package(url: "https://codeberg.org/aparoksha/adwaita-swift", from: "0.1.0"),
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
