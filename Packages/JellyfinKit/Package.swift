// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    // Deutsch ist die Ausgangssprache: die Texte stehen im Code auf Deutsch
    // und dienen zugleich als Schlüssel. Englisch kommt aus dem Katalog.
    // **Die Rueckfallsprache des Paketbuendels, nicht die Ausgangssprache.**
    // Die Schluessel sind weiter deutsch (`de.lproj` bildet sie auf sich ab).
    // Wer aber ein Geraet auf Niederlaendisch oder Russisch hat, bekommt
    // genau diesen Wert — auf "de" sah er deutsche Fehlermeldungen in einer
    // englischen App. Dieselbe Zeile wie CFBundleDevelopmentRegion in den
    // vier Info.plists.
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
