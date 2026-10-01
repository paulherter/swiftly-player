# 🎬 VLCKit

Swiftly Player ships a VLCKit built with its own patches. The official
build fetched by `Werkzeuge/vlckit-holen.sh` does not have them, and two of
the problems below are bad enough that the app is not usable without the fix.

Every patch lives in `Werkzeuge/vlckit-patches/` with a README of its own that
carries the measurements. The patches are being submitted upstream so that
official builds can be used again.

**How to rebuild it:** `Werkzeuge/vlckit-bau/README.md` lists the upstream
commits, the order of the patches, the exact build and `xcodebuild
-create-xcframework` commands and how to put the result into Swiftly.

<br>

## Seeking in Matroska over HTTP

VLC 4 discards the seek index of Matroska files served over HTTP: every seek
reads from the beginning of the file and takes 30 to 90 seconds. VLC 3 does
not have this restriction, which is why other clients seek instantly.

## The clock resets on files with sparse timestamps

VLC 4 lowered the threshold for "this is a stream discontinuity" from 60
seconds to 300 ms. That comparison only holds when the source runs at its own
pace; for a plain file over HTTP the demuxer reads faster than realtime, so
every timestamp gap larger than 300 ms is treated as a break and the clock
resets its reference.

Measured on an Apple TV: **5276 clock resets in 72 seconds** on one episode,
35 to 70 new clock contexts per second, until tvOS killed the app for burning
the CPU. The same file plays fine on VLC 3.

## Pause took up to 125 ms to take effect

Three to four frames at 120 Hz. Three causes, three patches; it is about one
frame now.

## MPEG-1, MPEG-2 and MPEG-4 Part 2 could crash in the decoder

`0033-avcodec-pad-direct-rendered-MPEG-pictures-for-motion-compensation.patch`

When FFmpeg decodes straight into picture buffers that libVLC allocates, its
SIMD motion compensation for these codecs can read one byte past the edge of
the luma plane. If that plane ends at a memory-region boundary, the app
crashes. SD MPEG-2 files such as DVD rips are the typical case. The patch
adds 32 pixels of horizontal padding to those pictures. Direct rendering stays
on, and hardware decoding is not affected.

## Resuming while buffering could still pause

`0034-input-cancel-a-deferred-pause-when-a-resume-arrives.patch`

A pause sent while the player is buffering is held back until buffering ends.
A resume sent in that window was ignored, so playback paused anyway once the
buffer was full. Swiftly starts media paused (`:start-paused`) and resumes
it, which runs straight into that window. With the patch, the resume cancels
the held-back pause.

Both patches come from [SwiftVLC](https://github.com/harflabs/SwiftVLC) by
harflabs and are taken over unchanged. The SwiftVLC project is MIT-licensed.
The patches modify VLC and are therefore under VLC's LGPL-2.1-or-later.

<br>

## VLCKit / libVLC — Source and your rights

Swiftly Player uses VLCKit and libVLC by VideoLAN, licensed under the
**LGPL-2.1-or-later**. Copyright VideoLAN and VLC authors. The license text
is in [LICENSES/LGPL-2.1-or-later.txt](../LICENSES/LGPL-2.1-or-later.txt), and
every bundled library with its version and license is listed in
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md). The same pages are in the
apps under Profile → About → Open-source licenses.

**What is shipped.** The apps for iPhone, iPad, Mac and Apple TV embed
`VLCKit.framework` (version 4.0.0-a23) built from VideoLAN's sources plus the
patches in `Werkzeuge/vlckit-patches/`. The iPhone/iPad and Apple TV slices
were built on 28 Sep 2026, the Mac slice on 16 Sep 2026 (it does not contain
the patches that came later; `0036` to `0038` only affect the audio output of
iOS and tvOS). VLC is built with `--disable-gpl`, and FFmpeg without
`--enable-gpl`.

**Upstream source.**

| | |
|---|---|
| VLCKit | <https://code.videolan.org/videolan/VLCKit>, tag `4.0.0-a23`, commit `e3774eb2` |
| libVLC | <https://code.videolan.org/videolan/vlc>, commit `2cd8705589` (VLCKit's `TESTEDHASH`) |
| Libraries inside | the tarballs of VLC's contrib system (`libvlc/vlc/contrib/src/*`) in the versions given in `THIRD-PARTY-NOTICES.md` |

**Swiftly's changes.** Public in this repository, in `Werkzeuge/vlckit-patches/`:

- against libVLC, as `libvlc/patches/` entries: `0028`, `0030`, `0031`,
  `0032`, `0033`, `0034`, `0036`, `0037`, `0038`
- against VLCKit itself: `VLCKit-pause-ohne-warteschlange.patch`
  (`Sources/Playback/VLCMediaPlayer.m`; it is not applied by VLCKit's build
  script and has to be applied by hand)
- `0035` lies in the directory but is in no shipped build

**Rebuilding and replacing the library.**

```sh
git clone https://code.videolan.org/videolan/VLCKit.git && cd VLCKit
git checkout 4.0.0-a23
cp <swiftly>/Werkzeuge/vlckit-patches/00*.patch libvlc/patches/   # without 0035
git apply <swiftly>/Werkzeuge/vlckit-patches/VLCKit-pause-ohne-warteschlange.patch
./compileAndBuildVLCKit.sh -r -f      # iPhone/iPad (device and simulator)
./compileAndBuildVLCKit.sh -r -t -f   # Apple TV
./compileAndBuildVLCKit.sh -r -x      # Mac
```

The script needs Xcode and a path without spaces. The first run is long (it
builds the contrib libraries); later runs took 4 to 7 minutes per platform. Each run leaves one `VLCKit-*.xcarchive`
per slice under `build/`. Assemble them into one `Vendor/VLCKit-gepatcht.xcframework`
with `xcodebuild -create-xcframework -framework <slice>/VLCKit.framework ...`
(one `-framework` per slice) and build Swiftly as described in
[Building.md](Building.md). You may change the library and use your own build
with Swiftly Player; that is what the LGPL asks us to make possible.

**Written offer.** On request we provide the complete corresponding source
code of VLCKit, libVLC (including the VLC 3.0.21 runtime and plugins shipped
for Windows) and the bundled libraries of every version of Swiftly
Player that we distribute, including the patches and build scripts, as a
download or on a data medium, for at least three years after the release of
that version. Ask at info@swiftlyplayer.com and name the version and platform.
We may charge no more than the cost of the delivery.

**Is the shipped binary reproducible from these sources?** Almost, and not
bit for bit. The iPhone/iPad and Apple TV device slices in `Vendor/` are
byte-identical to the output of the local build tree, which is upstream
`4.0.0-a23` plus exactly the files in `Werkzeuge/vlckit-patches/` (compared
with `cmp`, and by SHA-256 for the binaries). What is not in the repository:
the small wrapper scripts that run the build (they check that `0028` is in
place), and the exact command that merged the per-platform archives into the
single XCFramework. A rebuild with another Xcode gives different bytes.
For the Mac slice (built on 16 Sep) it is not established which of the later
patches (`0033`, `0034`) it contains; it should be rebuilt before the next
release so that slice and sources match again.

<br>

## License

Playback uses [VLCKit](https://code.videolan.org/videolan/VLCKit), which is
licensed under the **LGPL-2.1-or-later**. It is not stored in this repository
(2 GB); `Werkzeuge/vlckit-holen.sh` fetches VideoLAN's official build and
verifies its SHA-256, and the section above says how to build the patched
version the apps ship. The full source of this application is published so
that anyone can rebuild it against their own build of that library.
