#!/bin/sh
# Assembles the five slices (ios, ios-sim, macos, tvos, tvos-sim) into ONE
# xcframework - the file Swiftly links as Vendor/VLCKit-gepatcht.xcframework.
# usage: xcframework-zusammenfuegen.sh <VLCKit-checkout> <output.xcframework>
#
# Takes the archives left behind by bauen.sh. Never run this after a failed
# build without looking at the log: the old archive stays in build/ and would
# be assembled without any warning.
set -eu
[ $# -eq 2 ] || { sed -n 2,3p "$0" >&2; exit 2; }
B=$1/build
OUT=$2
args=""
for a in iphoneos iphonesimulator macosx appletvos appletvsimulator; do
  x=$B/VLCKit-$a.xcarchive
  test -d "$x/Products/Library/Frameworks/VLCKit.framework" \
    || { echo "missing archive: $x" >&2; exit 1; }
  args="$args -framework $x/Products/Library/Frameworks/VLCKit.framework -debug-symbols $x/dSYMs/VLCKit.framework.dSYM"
done
rm -rf "$OUT"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $args -output "$OUT"
for f in "$OUT"/*/VLCKit.framework/VLCKit "$OUT"/*/VLCKit.framework/Versions/A/VLCKit; do
  [ -f "$f" ] && shasum -a 256 "$f"
done
