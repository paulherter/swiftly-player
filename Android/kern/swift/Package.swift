// swift-tools-version: 6.2
//
// **Die Bruecke von Kotlin zu JellyfinKit.**
//
// Hier liegt der einzige Swift-Code, der fuer Android geschrieben wird: eine
// duenne Fassade ueber dem Paket. jextract (swift-java, JNI-Modus) erzeugt
// daraus Java-Huellen, die die Android-App aus Kotlin aufruft. Regeln fuer den
// Zuschnitt: Notizen/Android/PLAN.md, „Regeln fuer die Fassade".
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiftlyKern",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwiftlyKern", type: .dynamic, targets: ["SwiftlyKern"])
    ],
    dependencies: [
        .package(path: "../../../Packages/JellyfinKit"),
        // Dieselbe Fassung wie das offizielle Beispiel, gegen das die
        // Werkzeugkette am 14.09.2026 geprueft wurde.
        .package(url: "https://github.com/swiftlang/swift-java", exact: "0.6.0"),
    ],
    targets: [
        .target(
            name: "SwiftlyKern",
            dependencies: [
                .product(name: "JellyfinKit", package: "JellyfinKit"),
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [.plugin(name: "JExtractSwiftPlugin", package: "swift-java")]
        )
    ]
)
