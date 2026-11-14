# Contributing to Swiftly Player

Thanks for helping. Swiftly is a Jellyfin client for iPhone, iPad, Apple TV, Mac,
Android, Android TV, Linux and Windows. The goal is simple: **never transcode**.
Every file plays as Direct Play or Direct Stream. A change that makes the server
transcode will not be merged.

Code, comments, file names and documentation are English. The user interface is
translated; the German wording is currently the key of the string catalogue
(see "Texts" below).

## Layout

| Path | What lives there |
|---|---|
| `crates/` | The shared Rust core (Jellyfin, Plex and Emby access, playback rules, view models, settings, downloads) and the Rust UI crates. |
| `crates/swiftly-desktop` | The Windows and Linux app: its own Rust UI in a winit window, video through libmpv. |
| `xtask/` | Cargo helpers: the Apple framework, desktop packaging, the fixture server. |
| `Packages/SwiftlyCore` | Swift wrapper around the Rust core, used by the Apple apps. |
| `Packages/JellyfinKit` | Swift logic and tests used by the Apple apps; parts of it are being replaced by the Rust core. |
| `Sources/Shared` | SwiftUI code shared by iOS, iPadOS, tvOS and macOS. |
| `Sources/iOS`, `tvOS`, `macOS`, `TopShelf` | Views and entry points per platform. |
| `Android/` | Kotlin app (`phone`, which also contains the Android TV screens, and `shared`) plus the bindings to the Rust core (`rustcore`). |
| `Linux/`, `Windows/` | Install scripts and packaging, and the earlier desktop app in Swift and GTK 4 (being retired). |
| `Werkzeuge/` | Build, check and release scripts. |

**One rule above all:** logic is shared, screens are per platform. If the same
logic exists twice, move it into the shared core (`crates/`) instead of copying it. Behaviour
that differs between platforms needs a reason from input method, distance or
window size.

## Building

The full steps are in [Documentation/Building.md](Documentation/Building.md). In short:

```bash
cargo test --workspace                                      # Rust core and desktop UI
cargo build -p swiftly-desktop --release --features mpv     # Windows and Linux app, needs libmpv to play
cargo xtask fixture-server --port 8096 --real-shapes        # a fake Jellyfin server for development
```

Apple platforms (Xcode 26 or newer): `Werkzeuge/rust-kern.sh` builds the core
framework and runs `xcodegen`; then open `Swiftly.xcodeproj` and build the scheme
for your platform. `Werkzeuge/check.sh` runs the package tests and the Apple
builds in one command.

Android: `Werkzeuge/rust-kern-android.sh`, then
`cd Android && ./gradlew :phone:assembleDirectDebug` (JDK, Android SDK and NDK;
`Werkzeuge/android-environment.sh` prepares the environment).

Desktop packages: `Werkzeuge/package-desktop.sh`.

## Rules for changes

- **One change per pull request,** with a short description of the problem and how
  you tested it. Screenshots help for visual changes.
- **Persisted data stays compatible.** Do not rename UserDefaults keys, Keychain
  accounts, JSON fields, file names in the app container or messages between
  devices (remote control, hand-over, SyncPlay). Rename the Swift or Kotlin name
  and keep the string.
- **Comments explain why,** not what. No history ("used to be", dates), no names.
- **Standard controls and the accent colour** come from the shared style
  (`Sources/Shared/Style.swift` on Apple, `crates/swiftly-design` in the Rust
  UI); do not hard-code colours or sizes.
- **No new dependency without its licence.** Add it to `LICENSES/components.json`
  and `THIRD-PARTY-NOTICES.md`. Swiftly is MPL-2.0; GPL-only code cannot go in.
  FFmpeg builds must be LGPL (no `--enable-gpl`, no `--enable-nonfree`).
- **Tests:** logic comes with a test. `cargo test --workspace` and, for Swift
  changes, `swift test` in `Packages/JellyfinKit` must stay green.
- **Texts:** a new user-visible text goes into the string catalogue in every
  language, the German wording being the key. `Werkzeuge/catalog-check.py` checks
  that none is missing.

## Reporting bugs

Open an issue with the platform, app version, what you did and what happened. For
playback problems, the shared log (Profile, then Share log) is the most useful
attachment.

## Licence

By contributing you agree that your contribution is licensed under the
Mozilla Public License 2.0, like the rest of the project, and you grant Paul
Herter a permanent, worldwide, free right to use, change and license your
contribution under other terms as well (for example a future license of the
project). You keep the copyright of your contribution.
