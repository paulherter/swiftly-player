// swift-tools-version: 6.0
import PackageDescription

// **Kein fremdes Swift-Paket fuer die Oberflaeche, und das ist eine
// Entscheidung, keine Verlegenheit.**
//
// Der naheliegende Weg waere „Adwaita for Swift" gewesen — deklarativ, nah an
// SwiftUI. Am 04.09.2026 hat sich das als Sackgasse erwiesen: das Projekt ist
// auf GitHub archiviert, nach Codeberg umgezogen, dort antwortet der Server
// unregelmaessig mit 504, und SwiftPM findet den Hauptzweig nicht, obwohl
// `git ls-remote` ihn daneben anzeigt. Sechs Anlaeufe, kein Bau.
//
// GTK4 selbst liegt als C-Bibliothek auf jedem Linux-Rechner, der die App
// ausfuehren soll. Ueber eine Modulzuordnung ist sie direkt ansprechbar, ohne
// Netz, ohne Fassungsaufloesung, ohne fremde Wartung. Der Preis ist
// imperativer Code statt eines deklarativen Baums — fuer eine Oberflaeche,
// die ohnehin plattformeigen sein soll, ein guter Tausch.
let package = Package(
    name: "SwiftlyLinux",
    dependencies: [
        // Dieselben Dateien, die iOS, tvOS und macOS benutzen. Keine Kopie.
        .package(path: "../Packages/JellyfinKit")
    ],
    targets: [
        .systemLibrary(
            name: "CGtk",
            pkgConfig: "gtk4",
            providers: [.apt(["libgtk-4-dev"])]
        ),
        // **libVLC des Systems, nicht VLCKit.** Auf Apple liegt VLCKit als
        // XCFramework bei; auf Linux ist libVLC eine Systembibliothek. Was
        // entscheidet, ob transkodiert wird, ist ohnehin das DeviceProfile im
        // Paket — das ist auf allen Plattformen dasselbe.
        .systemLibrary(
            name: "CVLC",
            pkgConfig: "libvlc",
            providers: [.apt(["libvlc-dev"])]
        ),
        // Der fadenkritische Teil in C: VLCs Rueckrufe laufen auf dem
        // Dekoderfaden und teilen sich einen Puffer mit GTKs Hauptfaden.
        // Begruendung in bildbruecke.h.
        .target(name: "CBildbruecke", dependencies: ["CVLC"]),
        .executableTarget(
            name: "SwiftlyLinux",
            dependencies: [
                "CGtk",
                "CVLC",
                "CBildbruecke",
                .product(name: "JellyfinKit", package: "JellyfinKit")
            ]
        )
    ]
)
