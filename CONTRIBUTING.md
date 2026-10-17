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
| `Packages/JellyfinKit` | Shared logic and tests: Jellyfin API, playback decisions, models. Platform-neutral Swift. |
| `Sources/Shared` | SwiftUI code shared by iOS, iPadOS, tvOS and macOS. |
| `Sources/iOS`, `tvOS`, `macOS`, `TopShelf` | Views and entry points per platform. |
| `Android/` | Kotlin app (`phone`, which also contains the Android TV screens, and `shared`) plus the Swift core (`core`) used through swift-java. |
| `Linux/`, `Windows/` | GTK 4 app in Swift, installers and packaging. |
| `Werkzeuge/` | Build, check and release scripts. |

**One rule above all:** logic is shared, screens are per platform. If the same
logic exists twice, move it into `JellyfinKit` instead of copying it. Behaviour
that differs between platforms needs a reason from input method, distance or
window size.

## Building

Apple platforms (Xcode 26 or newer):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate            # after any change to project.yml
cd Packages/JellyfinKit && swift test
```

Then open `Swiftly.xcodeproj` and build the scheme for your platform. VLCKit is
fetched with `Werkzeuge/vlckit-fetch.sh`.

Everything Apple plus the package tests in one command:

```bash
Werkzeuge/check.sh
```

Android: `cd Android && ./gradlew :phone:compileDebugKotlin` (JDK 17, Android SDK;
`Werkzeuge/android-environment.sh` prepares the environment).

Linux: `Linux/build.sh` (Swift 6, GTK 4.14, libVLC). Windows: `Windows/build.ps1`.

## Rules for changes

- **One change per pull request,** with a short description of the problem and how
  you tested it. Screenshots help for visual changes.
- **Persisted data stays compatible.** Do not rename UserDefaults keys, Keychain
  accounts, JSON fields, file names in the app container or messages between
  devices (remote control, hand-over, SyncPlay). Rename the Swift or Kotlin name
  and keep the string.
- **Comments explain why,** not what. No history ("used to be", dates), no names.
- **Standard controls and the accent colour** come from the shared style
  (`Sources/Shared/Style.swift`); do not hard-code colours or sizes.
- **No new dependency without its licence.** Add it to `LICENSES/components.json`
  and `THIRD-PARTY-NOTICES.md`. Swiftly is MPL-2.0; GPL-only code cannot go in.
  FFmpeg builds must be LGPL (no `--enable-gpl`, no `--enable-nonfree`).
- **Tests:** logic in `JellyfinKit` comes with a test. `swift test` must stay green.
- **Texts:** a new user-visible text goes into the string catalogue in every
  language, the German wording being the key. `Werkzeuge/catalog-check.py` checks
  that none is missing.

## Reporting bugs

Open an issue with the platform, app version, what you did and what happened. For
playback problems, the shared log (Profile, then Share log) is the most useful
attachment.

## Licence

By contributing you agree that your contribution is licensed under the
Mozilla Public License 2.0, like the rest of the project.
