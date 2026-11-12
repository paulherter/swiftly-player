#!/bin/bash
# Media matrix through the real desktop player path (libmpv, the player screen, session reports), no window, ON the Linux PC:
#   Werkzeuge/auf-pc.sh <name> 'Werkzeuge/desktop-matrix.sh <bench-media-dir> [seconds] [id ...]'
# Bench media: `python3 -I Werkzeuge/pruefstand-medien.py <dir>`. Each `bm-*` title is planned and played by `swiftly-desktop
# --smoke-play` against the fixture server; a title passes when frames arrived, the picture is neither black nor green, and
# start/progress/stop were reported. Prints one line per title.
# An id may carry a subtitle check: `id@track@cues`, e.g. `bm-pgs-mkv@pgs@124-126,134-136` picks the subtitle track whose label
# holds "pgs" and asserts subtitle pixels in the played frames inside those cue windows (seconds on the title's clock).
# SWIFTLY_MATRIX_PLEX=1 runs the Plex shape instead (titles 9001 bm-multi-mkv, 9002 bm-pgs-mkv, 9003 bm-ext-subs; signs in with a token).
set -u
cd "$(dirname "$0")/.."
export PATH=$HOME/.cargo/bin:$PATH
TGT=${CARGO_TARGET_DIR:-$PWD/target}
DIR=$(cd "$1" && pwd); SECS=${2:-6}; shift 2 2>/dev/null
cargo build -q --release -p swiftly-desktop --features mpv 2>&1 | tail -3
cargo build -q -p xtask 2>&1 | tail -3
IDS=("$@"); [ ${#IDS[@]} -eq 0 ] && [ -n "${SWIFTLY_MATRIX_PLEX:-}" ] && IDS=(9001 9002 9003)
[ ${#IDS[@]} -eq 0 ] && IDS=($(ls "$DIR" | sed -n 's/^\(bm-[a-z0-9-]*\)\.item\.json$/\1/p' | grep -v -E '^bm-(resume|pgs-mkv|series)$'))
PORT=18197
R=$(mktemp -d); chmod 700 "$R"
SWIFTLY_FIXTURE_MEDIA_DIR=$DIR $TGT/debug/xtask fixture-server --port $PORT >"$R/fx.log" 2>&1 & FIX=$!
for i in $(seq 50); do grep -q listening "$R/fx.log" && break; sleep 0.1; done
pass=0; fail=0
AUTH=(demo demo); PLEXENV=""; [ -n "${SWIFTLY_MATRIX_PLEX:-}" ] && { AUTH=(1 fixture-token); PLEXENV=plex; }
for spec in "${IDS[@]}"; do
  IFS=@ read -r id track cues <<<"$spec"
  t0=$SECONDS
  out=$(SWIFTLY_SMOKE_SERVER=$PLEXENV SWIFTLY_SMOKE_SUBTITLE=$track SWIFTLY_SMOKE_CUES=$cues SWIFTLY_SMOKE_ITEM=$id SWIFTLY_CONFIG_DIR=$R/cfg-$id SWIFTLY_CACHE_DIR=$R/cache-$id XDG_RUNTIME_DIR=$R SWIFTLY_MPV_OPTS=${SWIFTLY_MATRIX_MPV_OPTS-ao=null} timeout 60 $TGT/release/swiftly-desktop --smoke-play http://127.0.0.1:$PORT "${AUTH[@]}" --quit-after "$SECS" 2>&1)
  rc=$?; took=$((SECONDS - t0))
  pic=$(echo "$out" | grep -E "^picture:" | cut -c1-80); fr=$(echo "$out" | grep -o "frames delivered [0-9]*"); pl=$(echo "$out" | grep -o "plan [0-9]* ms: [A-Za-z]*"); sp=$(echo "$out" | grep -E "^(subtitle(-off)? (pixels|rows|picked|samples|pass)|player log)" | cut -c1-3000 | tr "\n" " ")
  if [ $rc -eq 0 ]; then pass=$((pass+1)); echo "PASS $spec | $pl | $fr | $pic | $sp"; else fail=$((fail+1)); echo "FAIL $spec (rc $rc, ${took}s) | $pl | $fr | $pic | $sp | $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-160)"; fi
done
kill $FIX 2>/dev/null; wait $FIX 2>/dev/null; rm -rf "$R"
echo "matrix: $pass passed, $fail failed"
