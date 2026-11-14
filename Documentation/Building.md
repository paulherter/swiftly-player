# 🛠️ Building

```bash
git clone https://github.com/paulherter/swiftly-player.git
cd swiftly-player
```

The shared core and the Windows and Linux app are Rust. The Apple apps are
SwiftUI on top of the Rust core, and the Android app is Kotlin on top of it.
Rust 1.99.0 is pinned in `rust-toolchain.toml`; `rustup` installs it on the
first `cargo` call.

<br>

## Rust: tests and checks

```bash
cargo test --workspace        # the whole core and both desktop UIs, no device needed
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
```

On Linux, `pkg-config` and the fontconfig development headers
(`libfontconfig1-dev` on Debian and Ubuntu) must be installed; the text engine
links fontconfig.

<br>

## Desktop (Windows and Linux)

The app is `crates/swiftly-desktop`: its own Rust UI in a winit window, drawn
with wgpu, and video through libmpv. libmpv is loaded at run time, so it is not
needed to build, only to play. Without the `mpv` feature the app builds but has
no video.

```bash
cargo build -p swiftly-desktop --release --features mpv
```

The binary is `target/release/swiftly-desktop`.

- **Linux:** install libmpv (`libmpv2` on Debian and Ubuntu, `mpv-libs` on
  Fedora, `mpv` on Arch). The app looks for `libmpv.so.2`; set `SWIFTLY_LIBMPV`
  to a full path to use another one.
- **Windows:** put `libmpv-2.dll` next to the `.exe`. The build used for the
  releases is named in [Players](Players.md). Build on Windows with the command
  above, or cross-compile from Linux with
  [`cargo-xwin`](https://github.com/rust-cross/cargo-xwin):

  ```bash
  cargo xwin build --release --target x86_64-pc-windows-msvc -p swiftly-desktop --features mpv
  ```

### Packages

```bash
Werkzeuge/package-desktop.sh
```

Run on Linux, it writes to `target/desktop-dist`:

- `.tar.gz`, `.deb` and `.rpm` for Linux (needs `dpkg-deb` and `rpmbuild`). With
  Podman installed, the binary is built in an Ubuntu 22.04 container so it runs
  on older glibc; `SWIFTLY_NATIVE_LINUX_BUILD=1` builds on the host instead.
  `SWIFTLY_LINUX_ONLY=1` stops after these three.
- A Windows `Setup.exe` (NSIS) and a portable `.zip`, cross-compiled with
  `cargo xwin` (needs `makensis` and `zip`). `libmpv-2.dll` is read from
  `SWIFTLY_LIBMPV_DLL` (default `~/swiftly-vendor/libmpv-2.dll`); without it the
  Windows packages are skipped.

The script stops if `MARKETING_VERSION` in `project.yml` and the version in
`crates/swiftly-desktop/Cargo.toml` differ.

### A server for development

```bash
cargo xtask fixture-server --port 8096 --real-shapes
```

starts a small Jellyfin-shaped server (user `demo`, password `demo`) with libraries, films, series, pictures and a short playable
clip. Sign in to it from any build. `--real-shapes` adds the odd cases a real
server has, such as a missing film or two libraries with the same titles. The
other switches (`--big`, `--mode`, `--latency-ms`) are listed at the top of
`xtask/src/fixture_server.rs`.

<br>

## Apple (iPhone, iPad, Apple TV, Mac)

Xcode 26 or newer, and `xcodegen` (`brew install xcodegen`). The `.xcodeproj` is
generated, not checked in. The apps link the Rust core as a binary framework
(`Packages/SwiftlyCore/SwiftlyCoreFFI.xcframework`), which is not checked in
either:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Werkzeuge/rust-kern.sh            # builds the xcframework if missing, then runs xcodegen
Werkzeuge/rust-kern.sh --rebuild  # after a change under crates/
xcodebuild -project Swiftly.xcodeproj -scheme Swiftly-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The Apple player, AetherEngine, and its FFmpeg frameworks come in as Swift
packages (`Packages/SwiftlyAether`) and are resolved by Xcode on the first
build. The Swift package tests run with `cd Packages/JellyfinKit && swift test`,
and `Werkzeuge/check.sh` runs them together with the Apple builds.

<br>

## Android

JDK, the Android SDK and NDK 27 are needed; `Werkzeuge/android-environment.sh`
sets them up for the shell (the scripts below are written for a Mac). The Rust core is built first, as
`libswiftly_uniffi.so` for each ABI plus the Kotlin bindings, into
`build/android-core`:

```bash
Werkzeuge/rust-kern-android.sh          # needs cargo-ndk and the Android Rust targets
cd Android && ./gradlew :phone:assembleDirectDebug
```

Android uses Media3 with an FFmpeg audio decoder that
`Werkzeuge/media3-ffmpeg-bauen.sh` builds. Which engine plays on which system
is in [Players](Players.md).

<br>

## Where the code lives

```
crates/                 The Rust core (server access, playback rules, view models) and the UI crates
crates/swiftly-desktop/ Windows and Linux app
xtask/                  Build helpers: Apple framework, packaging, the fixture server
Packages/SwiftlyCore/   Swift wrapper around the Rust core
Packages/JellyfinKit/   Swift logic and tests used by the Apple apps
Sources/Shared/         SwiftUI shared by the Apple platforms
Sources/iOS/, tvOS/, macOS/  Entry points and views per platform
Android/                Kotlin app and the bindings to the core
Linux/, Windows/        Install scripts and the earlier desktop app (being retired)
```

Anything that decides *behaviour* belongs in the shared core, not in a view,
including rules that look like presentation: what a player does at the end of an
episode, how a resume position is chosen, which file counts as played. The core
has tests that run without a simulator or a device.

The Jellyfin OpenAPI description is not included; fetch it from any server at
`/openapi.json` if you need it.
