#!/bin/zsh
# Asserts the Play core carries no supporter-key symbol (feature `supporter-key` off) and the direct one does.
set -e
export PATH=$HOME/.cargo/bin:$PATH CARGO_INCREMENTAL=0
cd "$(dirname "$0")/.."
t=${TMPDIR:-/tmp}/play-key-check
cargo build -q -p swiftly-uniffi --target-dir $t/play
cargo build -q -p swiftly-uniffi --features supporter-key --target-dir $t/direct
play=$(nm $t/play/debug/libswiftly_uniffi.a 2>/dev/null | grep -c legacy_support_key_status || true)
direct=$(nm $t/direct/debug/libswiftly_uniffi.a 2>/dev/null | grep -c legacy_support_key_status || true)
[ "$play" = 0 ] && [ "$direct" -gt 0 ] && echo "OK: Play 0, direct $direct" || { echo "FAIL: Play $play, direct $direct"; exit 1; }
