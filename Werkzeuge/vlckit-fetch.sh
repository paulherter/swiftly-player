#!/bin/bash
# Fetches the VLCKit XCFramework into Vendor/. Not in git, because it is 2 GB.
#
# Version 4.0.0-a23. Only available from VideoLAN (the GitHub mirror ends at
# a21), and VideoLAN throttles to ~40 KB/s per connection. A single download
# would take hours, so fetching in parallel pieces is advisable.
set -euo pipefail
cd "$(dirname "$0")/.."
# **WARNING: this version has a known bug.**
#
# VLC 4 discards the index of MKV files over HTTP in
# `matroska_segment_seeker.cpp` -- seeks then read from the start of the file
# and take 30 to 90 seconds. VLC 3 does not have that restriction.
#
# The patch is in `Werkzeuge/vlckit-patches/`. Building the app with working
# seeking needs a patched VLCKit -- this script fetches the **unpatched**
# official version.
#
# See the README, section "Building".

URL="https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260805-1123.zip"
SHA="c0c3ae1665053db5898581efc8ee920f526643526297f7fc643599532dc2ccf5"

[ -d Vendor/VLCKit.xcframework ] && { echo "Schon da."; exit 0; }
mkdir -p Vendor
echo "Lade VLCKit (861 MB)…"
curl -sSL --retry 3 -o /tmp/vlckit.zip "$URL"
echo "Pruefsumme…"
ACTUAL=$(shasum -a 256 /tmp/vlckit.zip | cut -d' ' -f1)
[ "$ACTUAL" = "$SHA" ] || { echo "PRUEFSUMME FALSCH: $ACTUAL"; exit 1; }
unzip -q -o /tmp/vlckit.zip -d /tmp/vlckit-entpackt
mv /tmp/vlckit-entpackt/VLCKit.xcframework Vendor/
rm -rf /tmp/vlckit.zip /tmp/vlckit-entpackt
echo "Fertig: Vendor/VLCKit.xcframework"
