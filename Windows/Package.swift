// swift-tools-version: 6.0
import PackageDescription

// **Dieselbe Oberflaeche wie auf Linux, nicht eine zweite.**
//
// GTK4 gibt es fuer Windows als MSVC-Bau (gvsbuild), samt `pkg-config.exe`
// und den `.pc`-Dateien. Damit spricht der Windows-Bau dieselbe C-Schnittstelle
// an wie der Linux-Bau — und deshalb gibt es hier **keine zweite Fassung des
// Quelltextes**. `bauen.ps1` spiegelt die geteilten Dateien aus
// `../Linux/Sources/SwiftlyLinux` vor jedem Bau nach `Sources/SwiftlyWindows`
// (dort gitignoriert); was sich zwischen den Plattformen unterscheidet, steht
// als `#if os(Windows)` in genau diesen geteilten Dateien.
//
// Der Umweg ueber das Spiegeln ist noetig, weil SwiftPM keine Ziele ausserhalb
// des Paketverzeichnisses erlaubt — nachgemessen, die Fehlermeldung lautet
// „target ... is outside the package root". Ein Paket fuer den geteilten Teil
// waere sauberer; das ist der naechste Schritt, sobald die Linux-Fassung nicht
// mehr taeglich angefasst wird.
let package = Package(
    name: "SwiftlyWindows",
    defaultLocalization: "de",
    dependencies: [
        .package(path: "../Packages/JellyfinKit")
    ],
    targets: [
        // **Ohne `pkgConfig`, obwohl gvsbuild eine `pkg-config.exe` mitbringt.**
        // Die Include- und Bindepfade stehen in `bauen.ps1` und werden als
        // `-Xcc -I…` uebergeben. Das ist eine Zeile mehr im Skript und dafuer
        // ein Weg weniger, der auf einem fremden Rechner anders ausfallen kann.
        .systemLibrary(name: "CGtk"),
        .systemLibrary(name: "CVLC"),
        .target(name: "CBildbruecke", dependencies: ["CVLC"]),
        .executableTarget(
            name: "SwiftlyWindows",
            dependencies: [
                "CGtk",
                "CVLC",
                "CBildbruecke",
                .product(name: "JellyfinKit", package: "JellyfinKit")
            ],
            resources: [.process("Resources")]
        )
    ]
)
