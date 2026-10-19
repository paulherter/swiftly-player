// swift-tools-version: 6.0
import PackageDescription

// **No third-party Swift package for the UI; this is a deliberate decision.**
//
// "Adwaita for Swift" (declarative, close to SwiftUI) was the obvious
// choice but proved a dead end: the project is archived on GitHub and moved
// to Codeberg, where the server intermittently answers 504, and SwiftPM
// fails to find the main branch although `git ls-remote` lists it. Six
// attempts, no build.
//
// GTK4 is a C library present on every Linux machine that runs the app. A
// module map makes it directly usable, with no network, no version
// resolution and no third-party maintenance. The price is imperative code
// instead of a declarative tree, a fair trade for a UI that is meant to be
// platform-native anyway.
let package = Package(
    name: "SwiftlyLinux",
    // **German is the source language** and also the key of every text. Without
    // this line SwiftPM refuses as soon as a target ships localized resources: it
    // needs to know what applies when the machine's language is in no catalog.
    defaultLocalization: "de",
    dependencies: [
        // The same files that iOS, tvOS and macOS use. No copy.
        .package(path: "../Packages/JellyfinKit")
    ],
    targets: [
        .systemLibrary(
            name: "CGtk",
            pkgConfig: "gtk4",
            providers: [.apt(["libgtk-4-dev"])]
        ),
        // **System libVLC, not VLCKit.** On Apple, VLCKit ships as an XCFramework;
        // on Linux libVLC is a system library. Whether to transcode is decided by the
        // DeviceProfile in the package, which is the same on all platforms.
        .systemLibrary(
            name: "CVLC",
            pkgConfig: "libvlc",
            providers: [.apt(["libvlc-dev"])]
        ),
        // The thread-critical part in C: VLC's callbacks run on the decoder thread
        // and share a buffer with GTK's main thread. Rationale in imagebridge.h.
        // libepoxy for the HDR shader (`hdrimage.c`); GTK ships it anyway.
        .target(name: "CImageBridge", dependencies: ["CVLC"],
                linkerSettings: [.linkedLibrary("epoxy")]),
        // Keyboard media keys. Empty on Linux (MPRIS handles them there); on Windows
        // a custom window procedure is needed.
        .target(name: "CMediaKeys"),
        // Registers the bundled font with fontconfig. It is shipped because SF Pro
        // only exists on the Mac and all platforms should look the same.
        .target(name: "CFonts",
                linkerSettings: [.linkedLibrary("fontconfig")]),
        // **rlottie for the startup animation.** The source is a Lottie file from
        // After Effects in `Sources/Shared/Medium`, the same file iOS, tvOS and macOS
        // play. Rebuilding it by hand is not an option: every keyframe has its own
        // Bezier easing, and hand-made motion ends up *almost* right, which is more
        // noticeable than none.
        //
        // rlottie is not packaged on Arch. `Werkzeuge/rlottie-build.sh` compiles the
        // sources without cmake into `~/.local` and adds the pkg-config file.
        .systemLibrary(
            name: "CRlottie",
            pkgConfig: "rlottie",
            providers: [.apt(["librlottie-dev"])]
        ),
        .executableTarget(
            name: "SwiftlyLinux",
            dependencies: [
                "CGtk",
                "CVLC",
                "CImageBridge",
                "CMediaKeys",
                "CFonts",
                "CRlottie",
                .product(name: "JellyfinKit", package: "JellyfinKit"),
                // Direct builds only: the supporter key check and the website address. Store
                // builds never link this module.
                .product(name: "SupportKeyKit", package: "JellyfinKit")
            ],
            // **The UI ships its own texts.** The package has its own catalog, and a
            // bundle only finds what is inside it. Without this line the UI would be in
            // German while runtimes and error messages are translated, and a mix is
            // worse than one language.
            resources: [.process("Resources")]
        )
    ]
)
