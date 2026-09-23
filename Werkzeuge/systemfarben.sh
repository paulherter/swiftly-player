#!/bin/zsh
# Liest Apples dunkle Systemfarben und die Schriftleiter aus dem iOS-SDK.
#
# Nicht abschreiben, nicht nachrechnen: `UIColor` und `UIFont` geben sie im
# Simulator selbst heraus. Die Werte in `Sources/Shared/Farben.swift` stammen
# von hier — wer sie anzweifelt, ruft das hier auf.
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
hier=${0:a:h}
bau=$(mktemp -d)
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator \
      -sdk "$sdk" "$hier/systemfarben.swift" -o "$bau/systemfarben"
geraet=$(xcrun simctl list devices available | grep -m1 "iPhone" | sed 's/.*(\([0-9A-F-]*\)).*/\1/')
xcrun simctl boot "$geraet" 2>/dev/null || true
xcrun simctl spawn "$geraet" "$bau/systemfarben"
rm -rf "$bau"
