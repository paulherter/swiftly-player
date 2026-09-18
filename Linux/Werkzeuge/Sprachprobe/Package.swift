// swift-tools-version: 6.0
import PackageDescription

// **Ein eigenes Paket, kein Ziel in `Linux/Package.swift`.** Die Probe soll
// nicht mit der App ausgeliefert werden und nicht bei jedem `swift build`
// mitlaufen; sie wird von Hand gestartet, wenn jemand wissen will, ob die
// Übersetzung greift. Was sie prüft, ist echte API des Pakets — nicht ein
// Nachbau davon, sonst prüfte sie sich selbst.
let package = Package(
    name: "Sprachprobe",
    dependencies: [.package(path: "../../../Packages/JellyfinKit")],
    targets: [
        .executableTarget(
            name: "Sprachprobe",
            dependencies: [.product(name: "JellyfinKit", package: "JellyfinKit")]
        )
    ]
)
