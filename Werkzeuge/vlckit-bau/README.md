# Rebuilding the patched VLCKit

Swiftly Player links `Vendor/VLCKit-gepatcht.xcframework`, a VLCKit built from
VideoLAN's sources plus the patches in `../vlckit-patches/`. This directory
holds the scripts that turn those sources into that file. Everything below is
what the shipped binaries were built with.

## Sources

| | |
|---|---|
| VLCKit | https://code.videolan.org/videolan/VLCKit, tag `4.0.0-a23`, commit `e3774eb25c62c902e9066ba267e6416d82e83382` |
| VLC (libVLC) | https://code.videolan.org/videolan/vlc, commit `2cd8705589` (the `TESTEDHASH` in VLCKit's `compileAndBuildVLCKit.sh`); VLCKit clones it into `libvlc/vlc` by itself |
| Contrib libraries | downloaded by VLC's contrib system into `libvlc/vlc/contrib/tarballs/` (base URL `https://downloads.videolan.org/pub/contrib` plus the upstream URLs named in `libvlc/vlc/contrib/src/<package>/rules.mak`). Names and versions of the shipped ones: `LICENSES/bausteine.json` |

## Patches

Applied in this order (file name order). All in `../vlckit-patches/`.

libVLC, applied by `git am` on top of `2cd8705589` after VLCKit's own patches
0001-0027:

1. `0028-mkv-allow-index_range-without-fastseek-and-never-cla.patch`
2. `0030-vout-clock-make-pause-take-effect-immediately.patch`
3. `0031-ios-keep-drawing-while-the-app-is-merely-inactive.patch` (iOS/tvOS only: it touches the OpenGL ES view)
4. `0032-input_clock-raise-CR_MAX_GAP-back-to-60-seconds.patch`
5. `0033-avcodec-pad-direct-rendered-MPEG-pictures-for-motion-compensation.patch`
6. `0034-input-cancel-a-deferred-pause-when-a-resume-arrives.patch`
7. `0036-avsamplebuffer-honour-pause-at-start-and-report-timing.patch`
8. `0037-avsamplebuffer-start-when-the-first-sample-is-due.patch`
9. `0038-avsamplebuffer-report-only-from-a-running-timebase.patch`

VLCKit itself, applied with `git apply` to the VLCKit checkout:

10. `VLCKit-pause-ohne-warteschlange.patch` (`Sources/Playback/VLCMediaPlayer.m`)

**`0035-demux-mkv-fix-the-Display-Aspect-Ratio-to-Sample-Asp.patch` is not part
of any shipped build.** It is kept in the directory for reference only;
`bauen.sh` deliberately does not copy it.

The patches must sit in VLCKit's `libvlc/patches/`. The build script resets
`libvlc/vlc` to the pinned commit and re-runs `git am libvlc/patches/*.patch`
on every run, so a patch applied by hand to `libvlc/vlc` is lost.

## Toolchain

The binaries were built on macOS with Xcode installed at
`/Applications/Xcode.app` and the SDKs `iphoneos26.5`, `appletvos26.5`,
`macosx26.5` (the contrib directories are named `*-26.5`). The build host's
current Xcode (`xcodebuild -version`) is `Xcode 26.6, Build version 17F113`;
the Xcode build number used for the iOS/tvOS slices of 28 Sep 2026 was not
recorded at the time, only the SDK version is certain. Other tools VLC's
bootstrap needs (autoconf, automake, libtool, pkg-config, cmake, meson,
ninja, nasm, python3, cargo) come from Homebrew or VLC's own
`extras/tools` build.

## Build

```sh
git clone https://code.videolan.org/videolan/VLCKit.git ~/vlckit-build   # no spaces in the path
cd ~/vlckit-build && git checkout 4.0.0-a23

# one platform, Release (-r = Release and --disable-debug for libVLC):
Werkzeuge/vlckit-bau/bauen.sh ~/vlckit-build ios   build-ios.log      # -f -r
Werkzeuge/vlckit-bau/bauen.sh ~/vlckit-build tvos  build-tvos.log     # -t -f -r
Werkzeuge/vlckit-bau/bauen.sh ~/vlckit-build macos build-macos.log    # -x -r
```

(`bauen.sh` does the patch copying described above and then calls
`./compileAndBuildVLCKit.sh` with the flags in the comments.) Each platform
takes from about 15 minutes to over an hour. The iOS run produces the
`iphoneos` and `iphonesimulator` archives, the tvOS run `appletvos` and
`appletvsimulator`, the macOS run `macosx`, all as
`build/VLCKit-<sdk>.xcarchive`. `alles-bauen.sh <checkout> <logdir> <out>` does
all three and the assembly below.

## Assembling the xcframework

`xcframework-zusammenfuegen.sh` runs exactly this, from the checkout's `build/`
directory:

```sh
xcodebuild -create-xcframework \
  -framework VLCKit-iphoneos.xcarchive/Products/Library/Frameworks/VLCKit.framework \
  -debug-symbols $PWD/VLCKit-iphoneos.xcarchive/dSYMs/VLCKit.framework.dSYM \
  -framework VLCKit-iphonesimulator.xcarchive/Products/Library/Frameworks/VLCKit.framework \
  -debug-symbols $PWD/VLCKit-iphonesimulator.xcarchive/dSYMs/VLCKit.framework.dSYM \
  -framework VLCKit-macosx.xcarchive/Products/Library/Frameworks/VLCKit.framework \
  -debug-symbols $PWD/VLCKit-macosx.xcarchive/dSYMs/VLCKit.framework.dSYM \
  -framework VLCKit-appletvos.xcarchive/Products/Library/Frameworks/VLCKit.framework \
  -debug-symbols $PWD/VLCKit-appletvos.xcarchive/dSYMs/VLCKit.framework.dSYM \
  -framework VLCKit-appletvsimulator.xcarchive/Products/Library/Frameworks/VLCKit.framework \
  -debug-symbols $PWD/VLCKit-appletvsimulator.xcarchive/dSYMs/VLCKit.framework.dSYM \
  -output VLCKit-gepatcht.xcframework
```

This gives the five slices `ios-arm64`, `ios-arm64_x86_64-simulator`,
`macos-arm64_x86_64`, `tvos-arm64`, `tvos-arm64_x86_64-simulator`. (This
command is reconstructed: the assembly was originally done by hand and not
logged. The slices it takes are the archives of the build tree, whose iOS and
tvOS device binaries are bit-identical to the shipped ones.)

## Using the result in Swiftly

```sh
rm -rf Vendor/VLCKit-gepatcht.xcframework
cp -R /path/to/VLCKit-gepatcht.xcframework Vendor/
xcodegen generate
xcodebuild -scheme Swiftly-macOS build        # or Swiftly-iOS, Swiftly-tvOS
```

`Vendor/` is not in the git repository (2.7 GB); see `Documentation/Building.md`.

## Checking what is inside a binary

A build date does not prove which patches a binary contains. Strings that only
exist with a patch:

```sh
strings -a VLCKit | grep -c 'cues parsed but empty'        # 0028
strings -a VLCKit | grep -c 'sample renderer started'      # 0037 (iOS/tvOS/macOS avsamplebuffer)
strings -a VLCKit | grep -c 'watchTimebaseLocked'          # 0038
strings -a VLCKit | grep -c 'GL_INVALID_ENUM'              # Release: 1 per architecture, Debug: 2
nm -u VLCKit | grep UIApplicationWillResignActive          # 0031: must be empty (iOS/tvOS)
```

Patches 0030, 0032, 0033, 0034 and 0035 and the VLCKit pause patch change code
but introduce no string; for those only the build log (`Applying: ...` lines
and the clean working tree state) is evidence.
