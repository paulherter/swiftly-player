#!/bin/bash
# Resource governor for every heavy job (cargo, xcodebuild, swift test, fuzz, soak): `source` this first.
# Why: on 09.11. up to 20 parallel jobs pushed the load of this 10-core Mac above 150, starved the user-space
# Wi-Fi driver and WindowServer and forced a hard reboot. Heavy work never gets more than a quarter of the cores,
# runs at low priority, and waits while the machine is busy.
mkdir -p "$(dirname "$BASH_SOURCE")/../target" "$(dirname "$BASH_SOURCE")/../build" 2>/dev/null; touch "$(dirname "$BASH_SOURCE")/../target/.metadata_never_index" "$(dirname "$BASH_SOURCE")/../build/.metadata_never_index" 2>/dev/null
export CARGO_BUILD_JOBS=4
export RUST_TEST_THREADS=4
export RAYON_NUM_THREADS=4
export TOKIO_WORKER_THREADS=4
export MAKEFLAGS="-j4"
export SWIFTLY_XCODE_JOBS=4          # use as: xcodebuild -jobs $SWIFTLY_XCODE_JOBS
export CARGO_PROFILE_RELEASE_LTO=thin # fat LTO links of the staticlib need many GB; thin is enough for tests
# Full use of the machines is fine as long as they stay responsive: up to 8 heavy jobs (shared with Sequence Studio, first come first served; slot directories are shared in /tmp) and a load guard (no new job while the 1-minute load is above 60).
# At most 8 heavy jobs at the same time on this machine (slot directories), independent of what macOS itself
# (Spotlight, iCloud, Adobe) is doing: waiting on the system load average starved everyone.
SLOTS=/tmp/lastgrenze-slots
schwer() {   # usage: schwer <command...>
  mkdir -p "$SLOTS"
  # 11.11.: parallel builds filled the disk to 0 bytes and stopped every session; refuse new heavy work below 15 GB free.
  local free_gb; free_gb=$(df -g /System/Volumes/Data | awk 'NR==2{print $4}')
  if [ "${free_gb:-99}" -lt 15 ]; then
    echo "lastgrenze: only ${free_gb} GB free on the Mac, heavy job refused (free own build folders first)" >&2
    return 28
  fi
  local got=""
  while [ -z "$got" ]; do
    local load; load=$(sysctl -n vm.loadavg | awk '{print int($2)}')
    if [ "${load:-0}" -gt 60 ]; then sleep 10; continue; fi
    for i in 1 2 3 4 5 6 7 8; do
      if mkdir "$SLOTS/$i" 2>/dev/null; then got=$i; echo $$ > "$SLOTS/$i/pid"; break; fi
      # free a slot whose owner died
      if [ -f "$SLOTS/$i/pid" ] && ! kill -0 "$(cat "$SLOTS/$i/pid")" 2>/dev/null; then rm -rf "$SLOTS/$i"; fi
    done
    [ -z "$got" ] && sleep 5
  done
  nice -n 8 "$@"; local rc=$?
  rm -rf "$SLOTS/$got"
  return $rc
}
