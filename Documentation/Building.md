# 🛠️ Building

```bash
git clone https://github.com/paulherter/swiftly-player.git
cd swiftly-player

# The .xcodeproj is generated, not checked in.
brew install xcodegen && xcodegen generate

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Swiftly.xcodeproj -scheme Swiftly-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The Apple player, AetherEngine, and its FFmpeg frameworks come in as Swift
packages (`Packages/SwiftlyAether`) and are resolved by Xcode on the first
build; nothing has to be fetched by hand. Windows and Linux need libmpv, and
Linux needs GTK 4.14 or newer. Android uses Media3 with an FFmpeg audio
decoder that `Werkzeuge/media3-ffmpeg-bauen.sh` builds. Which engine plays on
which system is in [Players](Players.md).

Logic lives in `Packages/JellyfinKit` and is testable without a simulator:

```bash
cd Packages/JellyfinKit && swift test
```

The Jellyfin OpenAPI description is not included; fetch it from any server at
`/openapi.json` if you need it.

<br>

## Where the code lives

```
Packages/JellyfinKit/   Server access, playback rules, no UI — with tests
Sources/Shared/         SwiftUI shared by the Apple platforms
Sources/iOS/            iPhone and iPad, player with Picture in Picture
Sources/tvOS/           Apple TV
Sources/macOS/          Mac
Linux/                  GTK4 build, in development
```

Anything that decides *behaviour* belongs in `JellyfinKit`, not in a view —
including rules that look like presentation. `Zeitannahme`, `Wiedergabetakt`
and `Folgenende` decide what every player does on every platform, so they live
in the package where they can be tested without a simulator.
