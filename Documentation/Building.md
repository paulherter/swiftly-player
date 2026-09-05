# 🛠️ Building

```bash
git clone https://github.com/paulherter/swiftly-for-jellyfin.git
cd swiftly-for-jellyfin

# VLCKit is 2.7 GB and not in this repository.
# NOTE: this fetches VideoLAN's official build, which has a known bug —
# seeking inside MKV files served over HTTP reads from the start of the file.
# The fix is in Werkzeuge/vlckit-patches/ and must be applied to a VLCKit
# build for seeking to work. See Documentation/VLCKit.md.
Werkzeuge/vlckit-holen.sh

# The .xcodeproj is generated, not checked in.
brew install xcodegen && xcodegen generate

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Swiftly.xcodeproj -scheme Swiftly-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

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
