#!/bin/bash
# Plex next-episode switch inside one player, ON the Linux PC: episode 1 (9003, external subtitles only) plays, the player moves
# to episode 2 (9001, embedded subtitles whose Plex stream ids differ from their place in the file), the ASS track is picked and
# subtitle pixels must show at the cue times. Needs the bench media with the Plex shape (pruefstand-medien.py, pruefstand-plex.py).
#   Werkzeuge/desktop-next-episode-check.sh <bench-media-dir>
set -u
cd "$(dirname "$0")/.."
export PATH=$HOME/.cargo/bin:$PATH
DIR=$(cd "$1" && pwd)
TGT=${CARGO_TARGET_DIR:-$PWD/target}
cargo build -q --release -p swiftly-desktop --features mpv 2>&1 | tail -3
cargo build -q -p xtask 2>&1 | tail -3
R=$(mktemp -d); chmod 700 "$R"
SWIFTLY_FIXTURE_MEDIA_DIR=$DIR $TGT/debug/xtask fixture-server --port 18197 >"$R/fx.log" 2>&1 & FIX=$!
for i in $(seq 50); do grep -q listening "$R/fx.log" && break; sleep 0.1; done
SWIFTLY_SMOKE_SERVER=plex SWIFTLY_SMOKE_NEXT_AT=4 SWIFTLY_SMOKE_SUBTITLE=${SUB:-ass} SWIFTLY_SMOKE_CUES=${CUES:-1-3,4-6,7-9} SWIFTLY_SMOKE_ITEM=9003 \
  SWIFTLY_CONFIG_DIR=$R/c SWIFTLY_CACHE_DIR=$R/k XDG_RUNTIME_DIR=$R SWIFTLY_MPV_OPTS=ao=null \
  timeout 60 $TGT/release/swiftly-desktop --smoke-play http://127.0.0.1:18197 1 fixture-token --quit-after 16 2>&1 | grep -v WARNING | cut -c1-400
rc=${PIPESTATUS[0]}
kill $FIX 2>/dev/null; wait $FIX 2>/dev/null; rm -rf "$R"
echo "next-episode check rc $rc"; exit $rc
