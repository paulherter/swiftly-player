#!/bin/bash
# Builds the Rust core for the Apple targets and regenerates the Xcode project.
#
# The project links `Packages/SwiftlyCore`, whose binary framework (`SwiftlyCoreFFI.xcframework`) is
# git-ignored and must exist before `xcodegen generate` and any build. `cargo run -p xtask -- apple`
# makes it (and refreshes `Generated.swift`); it takes a few minutes the first time.
#
#   Werkzeuge/rust-kern.sh              framework if missing, then xcodegen
#   Werkzeuge/rust-kern.sh --rebuild    framework always (after a change in crates/), then xcodegen
#   Werkzeuge/rust-kern.sh --framework  framework only, no xcodegen
#   Werkzeuge/rust-kern.sh --ui         comparison apps "Swiftly Rust" (iOS + tvOS, unsigned build, no install)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ "${1:-}" = "--ui" ]; then
  cargo run -q -p xtask -- apple-ui
  exit 0
fi

FRAMEWORK=Packages/SwiftlyCore/SwiftlyCoreFFI.xcframework
if [ "${1:-}" = "--rebuild" ] || [ ! -d "$FRAMEWORK" ]; then
  cargo run -q -p xtask -- apple
fi
[ "${1:-}" = "--framework" ] || xcodegen generate
