#!/bin/bash
# The next-episode card in the REAL Linux window: plays bm-ep1 (10 s, outro 6 s to the end: see fixture_server.rs) in the real app
# inside a private headless wlroots compositor (cage, pixman renderer) and takes grim screenshots once a second. Run ON the
# Linux PC from the repo root:
#   Werkzeuge/auf-pc.sh <name> 'Werkzeuge/desktop-next-card-check.sh <bench-media-dir>'
# Output: target/next-card-check/shot-<second>.png (the card for "Bench Episode 2" is in the shots after the card time).
# Needs cage, grim and the bench media (`python3 -I Werkzeuge/pruefstand-medien.py <dir>`). A real desktop session is never touched.
set -u
cd "$(dirname "$0")/.."
export PATH=$HOME/.cargo/bin:$PATH
TGT=${CARGO_TARGET_DIR:-$PWD/target}; EXE=$TGT/release/swiftly-desktop
DIR=$(cd "$1" && pwd); OUT=$PWD/target/next-card-check; rm -rf "$OUT"; mkdir -p "$OUT"
cargo build -q --release -p swiftly-desktop --features mpv 2>&1 | tail -3
cargo build -q -p xtask 2>&1 | tail -3
R=$(mktemp -d); chmod 700 "$R"
export XDG_RUNTIME_DIR=$R SWIFTLY_CONFIG_DIR=$R/cfg SWIFTLY_CACHE_DIR=$R/cache SWIFTLY_MPV_OPTS=${SWIFTLY_MATRIX_MPV_OPTS-ao=null}
mkdir -p "$SWIFTLY_CONFIG_DIR" "$SWIFTLY_CACHE_DIR"
PORT=18097
SWIFTLY_FIXTURE_MEDIA_DIR=$DIR $TGT/debug/xtask fixture-server --port $PORT >"$R/fixture.log" 2>&1 & FIX=$!
for i in $(seq 50); do grep -q listening "$R/fixture.log" && break; sleep 0.1; done
printf '%s' '{"konten":[{"accessToken":"fixture-token","userID":"u1","userName":"demo","serverURL":"http://127.0.0.1:'$PORT'"}],"aktiveKennung":"u1"}' > "$SWIFTLY_CONFIG_DIR/konten.json"
( for t in $(seq 2 ${SWIFTLY_CARD_SECONDS:-16}); do sleep 1; WAYLAND_DISPLAY=wayland-0 grim "$OUT/shot-$(printf %02d $t).png" 2>>"$OUT/grim.log"; done ) & G=$!
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 cage -s -- $EXE --app --size 1280x800 --quit-after $((${SWIFTLY_CARD_SECONDS:-16}+1)) "swiftly://abspielen/${SWIFTLY_CARD_ITEM:-bm-ep1}" >"$OUT/app.log" 2>&1
wait $G; kill $FIX 2>/dev/null; wait $FIX 2>/dev/null
echo "reports at the server: $(grep -c . "$OUT/app.log") log lines; shots: $(ls "$OUT" | grep -c png)"
grep -i -E "panick|error|libmpv|play" "$OUT/app.log" | head -8 | cut -c1-200
rm -rf "$R"
