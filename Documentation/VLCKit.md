# 🎬 VLCKit

Swiftly for Jellyfin ships a VLCKit built with its own patches. The official
build fetched by `Werkzeuge/vlckit-holen.sh` does not have them, and two of
the problems below are bad enough that the app is not usable without the fix.

Every patch lives in `Werkzeuge/vlckit-patches/` with a README of its own that
carries the measurements. The patches are being submitted upstream so that
official builds can be used again.

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

<br>

## License

Playback uses [VLCKit](https://code.videolan.org/videolan/VLCKit), which is
licensed under the **LGPL-2.1-or-later**. It is not distributed in this
repository; `Werkzeuge/vlckit-holen.sh` fetches VideoLAN's official build and
verifies its SHA-256. The full source of this application is published so that
anyone can rebuild it against their own build of that library.
