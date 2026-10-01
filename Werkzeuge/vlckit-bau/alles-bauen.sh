#!/bin/sh
# Builds all three platforms in Release, then assembles the xcframework.
# usage: alles-bauen.sh <VLCKit-checkout> <logdir> <output.xcframework>
set -eu
[ $# -eq 3 ] || { sed -n 2,3p "$0" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$2"
for p in tvos ios macos; do
  echo "=== $p ==="
  "$HERE/bauen.sh" "$1" "$p" "$2/bau-$p.log"
done
"$HERE/xcframework-zusammenfuegen.sh" "$1" "$3"
