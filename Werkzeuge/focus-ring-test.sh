#!/bin/bash
# Runs Tests/MacFocus (keyboard focus mark policy) in a throw-away package; nothing is launched.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
mkdir -p "$work/Sources/FocusKit" "$work/Tests/FocusTests"
cp "$root/Sources/macOS/KeyboardFocus.swift" "$work/Sources/FocusKit/"
cp "$root/Tests/MacFocus/KeyboardFocusTests.swift" "$work/Tests/FocusTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "FocusKit", platforms: [.macOS(.v15)],
    products: [.library(name: "FocusKit", targets: ["FocusKit"])],
    targets: [
        .target(name: "FocusKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FocusTests", dependencies: ["FocusKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
SWIFT
cd "$work"
xcodebuild test -scheme FocusKit -destination 'platform=macOS' -jobs 4 > "$work/log.txt" 2>&1 || true
grep -E "error:|Test run|Test Suite 'All|TEST |XCTAssert|failed" "$work/log.txt" | grep -v "failed with exit code 0" | head -20
