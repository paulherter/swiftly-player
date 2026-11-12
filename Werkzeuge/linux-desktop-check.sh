#!/bin/bash
# Real-app check of the Linux desktop build, run ON the Linux PC from the repo root (Werkzeuge/auf-pc.sh <name> 'Werkzeuge/linux-desktop-check.sh').
# Everything runs inside a private headless weston compositor and a private dbus session, with a temporary config
# folder: a real desktop session is never touched. Results (text + PNGs) land in target/linux-check.
set -u
cd "$(dirname "$0")/.."
export PATH=$HOME/.cargo/bin:$PATH
TGT=${CARGO_TARGET_DIR:-$PWD/target}
EXE=$TGT/release/swiftly-desktop
OUT=$PWD/target/linux-check; mkdir -p "$OUT"
cargo build -q --release -p swiftly-desktop --features mpv 2>&1 | tail -3
cargo build -q -p xtask 2>&1 | tail -3
R=$(mktemp -d); chmod 700 "$R"
export XDG_RUNTIME_DIR=$R SWIFTLY_CONFIG_DIR=$R/cfg SWIFTLY_CACHE_DIR=$R/cache
mkdir -p "$SWIFTLY_CONFIG_DIR" "$SWIFTLY_CACHE_DIR"
PORT=18096
$TGT/debug/xtask fixture-server --port $PORT >"$R/fixture.log" 2>&1 & FIX=$!
for i in $(seq 50); do grep -q listening "$R/fixture.log" && break; sleep 0.1; done
echo "fixture: $(head -1 "$R/fixture.log")"
# the old GTK app's sign-in file, to prove the Linux import path
printf '%s' '{"konten":[{"accessToken":"fixture-token","userID":"u1","userName":"demo","serverURL":"http://127.0.0.1:'$PORT'"}],"aktiveKennung":"u1"}' > "$SWIFTLY_CONFIG_DIR/konten.json"
cat > "$R/inner.sh" <<'INNER'
weston --backend=headless --socket=wl-swiftly-check --no-config >"$XDG_RUNTIME_DIR/weston.log" 2>&1 & W=$!
for i in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wl-swiftly-check" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY=wl-swiftly-check
echo "weston: $(grep -m1 -i 'backend\|headless' $XDG_RUNTIME_DIR/weston.log | cut -c1-80)"
# 1. the real app (stored account taken over from the old app's file) against the fixture
$EXE --app --size 1280x800 --quit-after 22 >"$OUT/app.log" 2>&1 & A=$!
sleep 9
echo "mpris on the session bus: $(busctl --user list 2>/dev/null | grep -i mpris | awk '{print $1}' | tr '\n' ' ')"
wait $A; echo "app exit: $?"
echo "import marker: $(cat $SWIFTLY_CONFIG_DIR/legacy-import.done 2>&1 | head -1)"
grep -i -E "took over|panick|error|libmpv" "$OUT/app.log" | head -5 | cut -c1-160
# 1b. screenshot: weston headless has no screen-capture protocol, so the same app runs in a headless wlroots compositor
# (cage, pixman renderer, its own socket) and grim takes the picture from the compositor.
( sleep 9; WAYLAND_DISPLAY=wayland-0 grim "$OUT/app-cage.png" 2>"$OUT/grim.log" ) & G=$!
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 cage -s -- $EXE --app --quit-after 14 >"$OUT/cage-app.log" 2>&1
wait $G; echo "cage+grim: $(ls -la $OUT/app-cage.png 2>&1 | awk '{print $5, $NF}') $(head -c 120 $OUT/grim.log)"
# 2. other window sizes, real swapchain frame dump (no blank strips: sizes and edge rows are checked on the Mac)
for s in 800x600 1920x1080; do $EXE --demo app --size $s --dump-frame "$OUT/frame-$s.png" --exit-after-dump --quit-after 20 2>&1 | grep -E "dump-frame" | cut -c1-120; done
# 3. scripted scrolling and navigation in a real window, with frame statistics
$EXE --demo app --stats --autoplay --quit-after 14 2>&1 | grep p50 | tail -1 | cut -c1-200
# 4. playback through libmpv, no window
SWIFTLY_CONFIG_DIR=$R/cfg2 $EXE --smoke-play http://127.0.0.1:$PORT demo demo --quit-after 11.5 2>&1 | tail -4 | cut -c1-200
kill $W 2>/dev/null; wait $W 2>/dev/null
INNER
# inner.sh is a quoted heredoc: everything it uses besides the exports below is empty there (PORT was, which made
# smoke-play ask "http://127.0.0.1:" and fail with "no Jellyfin at this address").
export EXE OUT PORT R
dbus-run-session -- bash "$R/inner.sh" 2>&1
kill $FIX 2>/dev/null; wait $FIX 2>/dev/null
echo "files: $(ls $OUT | tr '\n' ' ')"
