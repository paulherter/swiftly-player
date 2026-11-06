# Players

Each system plays with one engine. If it cannot open a file, the app shows an
error and writes a log entry; it does not switch to another engine.

| System | Engine | Audio and video decoding |
|---|---|---|
| iPhone, iPad, Mac, Apple TV | [AetherEngine](https://github.com/superuser404notfound/AetherEngine) 7.58.0 | FFmpeg n8.1.3 from [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) 3.13.0, plus VideoToolbox |
| Android, Android TV | Media3 / ExoPlayer 1.9.4 | the device's decoders, plus an FFmpeg 6.0.1 audio decoder built by `Werkzeuge/media3-ffmpeg-bauen.sh` |
| Windows | libmpv | `libmpv-2.dll` from [zhongfly/mpv-winbuild](https://github.com/zhongfly/mpv-winbuild/releases/tag/2026-11-05-3138fc8eea), release 2026-11-05-3138fc8eea |
| Linux | libmpv | the libmpv of the system, loaded dynamically; needs GTK 4.14 or newer |

## Apple

AetherEngine is a Swift package. `Packages/SwiftlyAether` wraps it so the
package traits `TrueHDObjectAudio` and `DTSXObjectAudio` are set in one place;
both are on. The package pins are in `Packages/SwiftlyAether/Package.resolved`:
AetherEngine 7.58.0, FFmpegBuild 3.13.0, LibDovi 2.1.0 and LibTrueHD 3.2.0.

- AetherEngine: LGPL-3.0 with the project's App Store exception, linked
  statically and unmodified.
- FFmpeg: LGPL-2.1-or-later, delivered as dynamic frameworks that sit in the
  app's Frameworks folder, so they can be replaced by your own build.
  FFmpegBuild applies its own patches; they are in its repository.
- libdovi: MIT (the crate is MIT or Apache-2.0).
- LibTrueHD: MIT, containing the Apache-2.0 `truehd` and `oamd` crates.

## Android

Media3 is Apache-2.0. Its FFmpeg audio extension is built from the official
FFmpeg 6.0.1 release without patches, as separate shared libraries
(`libavcodec.so`, `libavutil.so`, `libswresample.so`), without `--enable-gpl`,
`--enable-version3` and `--enable-nonfree`. The script and the exact
configuration are `Werkzeuge/media3-ffmpeg-bauen.sh` in this repository.

## Windows and Linux

Both use libmpv through one C bridge (`Linux/Sources/CMPVBridge`). The Windows
installer contains the unmodified LGPL build of `libmpv-2.dll`; the Linux
packages depend on the system libmpv.

## Licenses and source

The license list and the source offer are in
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md); the license texts are in
[LICENSES/](../LICENSES/). The data behind both is `LICENSES/components.json`.
