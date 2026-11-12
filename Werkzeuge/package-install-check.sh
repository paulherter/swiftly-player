#!/bin/bash
# Installs the Linux packages of `Werkzeuge/package-desktop.sh` into throwaway podman containers and starts the app once
# under Xvfb (`--demo home --quit-after 4`, exit code 0 = started, drew, closed). Runs ON the Linux PC:
#   Werkzeuge/auf-pc.sh <name> 'Werkzeuge/package-install-check.sh [dist-dir]'
# deb: debian:12 and ubuntu:22.04 · rpm: fedora · tar.gz: debian:12 (unpacked, libmpv from apt). Containers are --rm;
# the images it pulls are only removed with SWIFTLY_CHECK_RM_IMAGES=1.
set -u
cd "$(dirname "$0")/.."
D=$(cd "${1:-target/desktop-dist}" && pwd)
V=$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)
DEB=/dist/swiftly-player_${V}_amd64.deb; RPM=/dist/swiftly-player-${V}-1.x86_64.rpm; TGZ=/dist/swiftly-player-$V-linux-x64.tar.gz
APT='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null'
RUN='cd /tmp && XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p -m700 $XDG_RUNTIME_DIR; export XDG_RUNTIME_DIR; xvfb-run -a -s "-screen 0 1280x800x24" "$BIN" --demo home --quit-after 4; echo "exit code $?"'
fail=0
run() { # <label> <image> <script>
  out=$(podman run --rm --network=host -v "$D":/dist:ro "$2" bash -c "$3" 2>&1); rc=$?
  last=$(echo "$out" | tail -1)
  if [ $rc -eq 0 ] && [ "$last" = "exit code 0" ]; then echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: $(echo "$out" | tail -6 | tr '\n' ' ' | cut -c1-400)"; fi
}
GL='mesa-vulkan-drivers libgl1-mesa-dri'
# With SWIFTLY_CHECK_FIXTURE=http://127.0.0.1:<port> (a running `xtask fixture-server` with the bench media on THIS machine) the deb
# containers also PLAY a title through the installed libmpv (--network=host, no audio): ubuntu:22.04 has libmpv1 (libmpv.so.1).
PLAY=""; [ -n "${SWIFTLY_CHECK_FIXTURE:-}" ] && PLAY="cd /tmp; SWIFTLY_SMOKE_ITEM=bm-h264-aac-mp4 SWIFTLY_MPV_OPTS=ao=null SWIFTLY_CONFIG_DIR=/tmp/cfg SWIFTLY_CACHE_DIR=/tmp/cache XDG_RUNTIME_DIR=/tmp/xdg \$BIN --smoke-play $SWIFTLY_CHECK_FIXTURE demo demo --quit-after 6 2>&1 | tail -4; echo \"exit code \${PIPESTATUS[0]}\""
run "deb on debian:12" docker.io/library/debian:12 "$APT; apt-get install -y -qq --no-install-recommends xvfb xauth $GL $DEB >/dev/null 2>&1 || { apt-get install -y --no-install-recommends xvfb xauth $GL $DEB 2>&1 | tail -5; exit 1; }; BIN=/usr/bin/swiftly-player; $RUN"
run "deb on ubuntu:22.04" docker.io/library/ubuntu:22.04 "$APT; apt-get install -y -qq --no-install-recommends xvfb xauth $GL $DEB >/dev/null 2>&1 || { apt-get install -y --no-install-recommends xvfb xauth $GL $DEB 2>&1 | tail -5; exit 1; }; BIN=/usr/bin/swiftly-player; $RUN"
if [ -n "$PLAY" ]; then
  run "deb PLAYS a title on debian:12" docker.io/library/debian:12 "$APT; apt-get install -y -qq --no-install-recommends $GL $DEB >/dev/null 2>&1 || exit 1; BIN=/usr/bin/swiftly-player; mkdir -p -m700 /tmp/xdg; $PLAY"
  run "deb PLAYS a title on ubuntu:22.04" docker.io/library/ubuntu:22.04 "$APT; apt-get install -y -qq --no-install-recommends $GL $DEB >/dev/null 2>&1 || exit 1; BIN=/usr/bin/swiftly-player; mkdir -p -m700 /tmp/xdg; $PLAY"
fi
run "tar.gz on debian:12" docker.io/library/debian:12 "$APT; apt-get install -y -qq --no-install-recommends xvfb xauth $GL libmpv2 libxkbcommon-x11-0 libwayland-client0 libvulkan1 libfontconfig1 >/dev/null 2>&1 || exit 1; mkdir /opt/sp && tar -C /opt/sp -xzf $TGZ; BIN=/opt/sp/swiftly-player-$V-linux-x64/swiftly-player; $RUN"
run "rpm on fedora" registry.fedoraproject.org/fedora:latest "dnf -y -q install xorg-x11-server-Xvfb xauth mesa-vulkan-drivers mesa-dri-drivers $RPM >/dev/null 2>&1 || { dnf -y install $RPM 2>&1 | tail -5; exit 1; }; BIN=/usr/bin/swiftly-player; $RUN"
[ -n "${SWIFTLY_CHECK_RM_IMAGES:-}" ] && podman rmi docker.io/library/debian:12 docker.io/library/ubuntu:22.04 registry.fedoraproject.org/fedora:latest >/dev/null 2>&1
echo "install check: $fail failed"; [ $fail -eq 0 ]
