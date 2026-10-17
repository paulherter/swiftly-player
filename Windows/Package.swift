// swift-tools-version: 6.0
import PackageDescription

// **The same UI as on Linux, not a second one.**
//
// GTK4 exists for Windows as an MSVC build (gvsbuild), with `pkg-config.exe`
// and the `.pc` files. The Windows build therefore uses the same C interface as
// the Linux build, and there is **no second copy of the source**. `build.ps1`
// mirrors the shared files from `../Linux/Sources/SwiftlyLinux` to
// `Sources/SwiftlyWindows` (gitignored there) before every build; whatever
// differs between platforms is an `#if os(Windows)` in exactly these shared
// files.
//
// Mirroring is needed because SwiftPM does not allow targets outside the
// package directory (error: "target ... is outside the package root"). A
// package for the shared part would be cleaner.
let package = Package(
    name: "SwiftlyWindows",
    defaultLocalization: "de",
    dependencies: [
        .package(path: "../Packages/JellyfinKit")
    ],
    targets: [
        // **No `pkgConfig`, although gvsbuild ships a `pkg-config.exe`.** The include
        // and link paths are in `build.ps1` and passed as `-Xcc -I...`. That is one more
        // line in the script but one less thing that can behave differently on another
        // machine.
        .systemLibrary(name: "CGtk"),
        .systemLibrary(name: "CVLC"),
        // rlottie for the start animation. `Werkzeuge/rlottie-build.ps1` compiles the
        // same sources as on Linux, only with MSVC and as a static library.
        .systemLibrary(name: "CRlottie"),
        // libepoxy for the HDR shader (`hdrimage.c`); GTK brings it anyway.
        .target(name: "CImageBridge", dependencies: ["CVLC"],
                linkerSettings: [.linkedLibrary("epoxy")]),
        // The keyboard's media keys. Empty on Linux, where MPRIS handles this; on
        // Windows it needs its own window procedure.
        .target(name: "CMediaKeys"),
        // Registers the bundled font with fontconfig. It ships with the app because SF
        // Pro exists only on the Mac and all platforms should look the same.
        .target(name: "CFonts",
                linkerSettings: [.linkedLibrary("fontconfig")]),
        .executableTarget(
            name: "SwiftlyWindows",
            dependencies: [
                "CGtk",
                "CVLC",
                "CImageBridge",
                "CMediaKeys",
                "CFonts",
                "CRlottie",
                .product(name: "JellyfinKit", package: "JellyfinKit")
            ],
            resources: [.process("Resources")]
        )
    ]
)
