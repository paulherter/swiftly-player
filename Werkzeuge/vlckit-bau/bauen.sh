#!/bin/sh
# Builds VLCKit with the Swiftly patches for ONE platform.
#
# usage: bauen.sh <VLCKit-checkout> <platform> [logfile]
#   platform: ios | tvos | macos
#
# <VLCKit-checkout> is a clone of https://code.videolan.org/videolan/VLCKit
# at tag 4.0.0-a23 (commit e3774eb25c62c902e9066ba267e6416d82e83382).
# The path must not contain spaces.
#
# What it does:
#  1. copies the libVLC patches from ../vlckit-patches/ into
#     <checkout>/libvlc/patches/ (0028, 0030-0034, 0036-0038; NOT 0035),
#  2. applies VLCKit-pause-ohne-warteschlange.patch to the VLCKit sources,
#  3. runs VLCKit's own compileAndBuildVLCKit.sh in Release mode.
#
# compileAndBuildVLCKit.sh resets libvlc/vlc to the pinned VLC commit and runs
# `git am libvlc/patches/*.patch` on EVERY run, so patches must live in
# libvlc/patches/ - a patch applied by hand to libvlc/vlc is silently lost.
# `-r` means Release AND --disable-debug for libvlc; without the second half
# VLC's assertions are compiled in.
set -eu
[ $# -ge 2 ] || { sed -n 2,5p "$0" >&2; exit 2; }
CHECKOUT=$1; PLATFORM=$2
HERE=$(cd "$(dirname "$0")" && pwd)
PATCHES=$HERE/../vlckit-patches
LOG=${3:-}

case "$PLATFORM" in
  ios)   FLAGS="-f -r" ;;
  tvos)  FLAGS="-t -f -r" ;;
  macos) FLAGS="-x -r" ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac
case "$CHECKOUT" in *" "*) echo "no spaces in the path" >&2; exit 2 ;; esac

# The Xcode used for the shipped binaries is recorded in README.md.
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

cd "$CHECKOUT"
test "$(git rev-parse HEAD)" = e3774eb25c62c902e9066ba267e6416d82e83382 \
  || { echo "checkout is not VLCKit 4.0.0-a23 (e3774eb2)" >&2; exit 1; }

mkdir -p libvlc/patches
for p in "$PATCHES"/00*.patch; do
  case "$(basename "$p")" in 0035-*) continue ;; esac   # not part of any shipped build
  cp "$p" libvlc/patches/
done

PAUSE=$PATCHES/VLCKit-pause-ohne-warteschlange.patch
if git apply --check "$PAUSE" 2>/dev/null; then
  git apply "$PAUSE"
elif git apply --check -R "$PAUSE" 2>/dev/null; then
  echo "VLCKit pause patch already applied"
else
  echo "VLCKit pause patch neither applies nor is applied" >&2; exit 1
fi

if [ -n "$LOG" ]; then
  # shellcheck disable=SC2086
  ./compileAndBuildVLCKit.sh $FLAGS > "$LOG" 2>&1
else
  # shellcheck disable=SC2086
  ./compileAndBuildVLCKit.sh $FLAGS
fi
