#!/bin/bash
# Offscreen render of the real SubtitleOverlay (before = saved look only, after = file style) into PNGs.
# Builds a throw-away package in a temp dir (overlay + SubtitleScript + a stub of SubtitleStyle, JellyfinKit
# by path) and runs Tests/SubtitleRender with xcodebuild (plain swiftc breaks with Xcode 27.1). Nothing is launched.
# Usage: [SUBTITLE_PLATFORM=catalyst] Werkzeuge/subtitle-render.sh <absolute out-dir>
# catalyst = the UIKit code path of iOS (Mac Catalyst runs it natively, no simulator).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?absolute out dir}"
work="$(mktemp -d)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
mkdir -p "$work/Sources/RenderKit" "$work/Tests/RenderTests"
cp "$root/Sources/Shared/SubtitleOverlay.swift" "$root/Sources/Shared/SubtitleScript.swift" "$work/Sources/RenderKit/"
cp "$root/Tests/SubtitleRender/SubtitleRenderTests.swift" "$work/Tests/RenderTests/"
cat > "$work/Sources/RenderKit/Stub.swift" <<'SWIFT'
import Foundation
import JellyfinKit
enum SubtitleStyle {
    static let fontName = "Inter18pt-SemiBold"
    static var look: SubtitleLook { SubtitleLook.read(UserDefaults.standard.data(forKey: "utAussehen")) }
    @MainActor static func size(for look: SubtitleLook) -> Float { Float(SubtitleLook.textScalePercent(look: look, baseScale: 0.78)) / 100 }
}
SWIFT
cat > "$work/Package.swift" <<SWIFT
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "RenderKit", platforms: [.macOS(.v15), .macCatalyst(.v18)],
    products: [.library(name: "RenderKit", targets: ["RenderKit"])],
    dependencies: [.package(path: "$root/Packages/JellyfinKit")],
    targets: [
        .target(name: "RenderKit", dependencies: [.product(name: "JellyfinKit", package: "JellyfinKit")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RenderTests", dependencies: ["RenderKit", .product(name: "JellyfinKit", package: "JellyfinKit")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
SWIFT
# The test host cannot register a font from outside its own folder (CoreText error 103): hand it a copy.
cp "$root/Sources/Shared/Assets/Inter-SemiBold.ttf" "$work/Inter-SemiBold.ttf"
cd "$work"
DEST="platform=macOS"; [ "$SUBTITLE_PLATFORM" = catalyst ] && DEST="platform=macOS,variant=Mac Catalyst"
TEST_RUNNER_SUBTITLE_OUT="$out" TEST_RUNNER_SUBTITLE_FONT="$work/Inter-SemiBold.ttf" \
  xcodebuild test -scheme RenderKit -destination "${DEST:-platform=macOS}" -jobs 4 > "$work/log.txt" 2>&1 || true
grep -E "error:|Test run|TEST |XCTAssert|failed" "$work/log.txt" | grep -v "failed with exit code 0" | head -20
cat "$out/numbers.txt" 2>/dev/null
rm -rf "$work"
