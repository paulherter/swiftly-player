#!/bin/zsh
# Reads Apple's dark system colors and the type scale from the iOS SDK.
#
# Do not copy them, do not recompute them: `UIColor` and `UIFont` report them
# in the simulator itself. The values in `Sources/Shared/Colors.swift` come
# from here -- whoever doubts them runs this.
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
here=${0:a:h}
build=$(mktemp -d)
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator \
      -sdk "$sdk" "$here/systemcolors.swift" -o "$build/systemfarben"
device=$(xcrun simctl list devices available | grep -m1 "iPhone" | sed 's/.*(\([0-9A-F-]*\)).*/\1/')
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl spawn "$device" "$build/systemfarben"
rm -rf "$build"
