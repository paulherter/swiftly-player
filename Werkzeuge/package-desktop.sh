#!/bin/bash
# Builds the Swiftly Player desktop packages on Linux. Output: target/desktop-dist
#   Linux:   .tar.gz, .deb, .rpm      (needs dpkg-deb, rpmbuild)
#            SWIFTLY_LINUX_ONLY=1 stops after these three
#   Windows: Setup.exe (NSIS, per user) and a portable .zip, both with libmpv-2.dll next to the exe; the exe is
#            cross-compiled with `cargo xwin` (needs makensis in $NSISDIR, default ~/.local/nsis, and zip)
# libmpv-2.dll is not in git: it is read from $SWIFTLY_LIBMPV_DLL (default ~/swiftly-vendor/libmpv-2.dll).
# MSIX is not produced: it needs the Windows SDK (makeappx) and a signing certificate.
set -euo pipefail
cd "$(dirname "$0")/.."
# One source of truth for the version: MARKETING_VERSION in project.yml (the Apple apps and these packages ship the same
# number). The desktop crate's Cargo version is what the app shows in Settings and sends to the update check; it must match.
V=$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*MARKETING_VERSION: *"?([0-9][0-9.]*)"?.*/\1/')
CV=$(grep -m1 '^version' crates/swiftly-desktop/Cargo.toml | cut -d'"' -f2)
[ -n "$V" ] && [ "$V" = "$CV" ] || { echo "version mismatch: project.yml MARKETING_VERSION='$V', crates/swiftly-desktop/Cargo.toml version='$CV'" >&2; exit 1; }
# The Linux packages keep the name of the released app's packages ("swiftly-jellyfin"), so apt/dnf treat them as the
# update of the installed 1.0.x and replace it; the new binary and launcher have their own names.
PKG=swiftly-jellyfin
OUT=target/desktop-dist
MPVDLL=${SWIFTLY_LIBMPV_DLL:-$HOME/swiftly-vendor/libmpv-2.dll}
export NSISDIR=${NSISDIR:-$HOME/.local/nsis}
A=Distribution/desktop
ICON=crates/swiftly-desktop/assets/app-icon-256.png
rm -rf "$OUT"; mkdir -p "$OUT"
README="Swiftly Player $V. Starts without installation. Linux needs libmpv (package mpv-libs / libmpv2). Windows: libmpv-2.dll stays next to the exe; to update libmpv replace that file."

echo "== Linux build"
# The binary needs the glibc of the machine that built it, so by default it is built in a podman container with an OLD
# glibc (ubuntu:22.04 = glibc 2.35: runs on Debian 12, Ubuntu 22.04 and everything newer). libmpv, Vulkan and the window
# libraries are loaded at run time, so the container only needs a C toolchain and rustup. Cargo home, rustup and the
# target folder live in $SWIFTLY_BUILD_CACHE (default ~/.cache/swiftly-linux-build), so only the first run is cold.
# SWIFTLY_NATIVE_LINUX_BUILD=1 builds on the host instead (the package then needs the host's glibc or newer).
if [ -z "${SWIFTLY_NATIVE_LINUX_BUILD:-}" ] && command -v podman >/dev/null; then
  IMAGE=${SWIFTLY_BUILD_IMAGE:-docker.io/library/ubuntu:22.04}
  CACHE=${SWIFTLY_BUILD_CACHE:-$HOME/.cache/swiftly-linux-build}
  mkdir -p "$CACHE/cargo" "$CACHE/rustup" "$CACHE/target"
  flock "$CACHE/lock" podman run --rm -v "$PWD":/src -v "$CACHE":/cache -w /src \
    -e CARGO_HOME=/cache/cargo -e RUSTUP_HOME=/cache/rustup -e CARGO_TARGET_DIR=/cache/target -e CARGO_TERM_COLOR=never \
    "$IMAGE" bash -c '
      set -e
      if ! command -v cc >/dev/null || ! dpkg -s libfontconfig1-dev >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null
        apt-get install -y -qq --no-install-recommends build-essential pkg-config curl ca-certificates git libfontconfig1-dev >/dev/null
      fi
      [ -x "$CARGO_HOME/bin/rustup" ] || curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none >/dev/null 2>&1
      export PATH="$CARGO_HOME/bin:$PATH"
      cargo build -q --release -p swiftly-desktop --features mpv
      echo "glibc needed by the binary: $(objdump -T /cache/target/release/swiftly-desktop | grep -o "GLIBC_[0-9.]*" | sort -Vu | tail -1)"'
  BIN=$CACHE/target/release/swiftly-desktop
else
  cargo build -q --release -p swiftly-desktop --features mpv
  BIN=${CARGO_TARGET_DIR:-target}/release/swiftly-desktop
fi
STRIPPED="$OUT/swiftly-player"; cp "$BIN" "$STRIPPED"; strip "$STRIPPED"

# tar.gz
T="$OUT/tar/swiftly-player-$V-linux-x64"; mkdir -p "$T"
cp "$STRIPPED" "$T/swiftly-player"; cp "$A/de.paulherter.swiftly.player.desktop" "$ICON" "$T/"
echo "$README" > "$T/README.txt"
tar -C "$OUT/tar" -czf "$OUT/swiftly-player-$V-linux-x64.tar.gz" "swiftly-player-$V-linux-x64"

# root tree shared by deb and rpm
R="$OUT/root"
install -Dm755 "$STRIPPED" "$R/usr/bin/swiftly-player"
install -Dm644 "$A/de.paulherter.swiftly.player.desktop" "$R/usr/share/applications/de.paulherter.swiftly.player.desktop"
install -Dm644 "$ICON" "$R/usr/share/icons/hicolor/256x256/apps/swiftly-player.png"
install -Dm644 crates/swiftly-desktop/assets/app-icon-64.png "$R/usr/share/icons/hicolor/64x64/apps/swiftly-player.png"

# deb
D="$OUT/deb"; mkdir -p "$D/DEBIAN"; cp -a "$R/usr" "$D/"
SIZE=$(du -sk "$R/usr" | cut -f1)
cat > "$D/DEBIAN/control" <<EOT
Package: $PKG
Provides: swiftly-player
Version: $V
Section: video
Priority: optional
Architecture: amd64
Depends: libmpv2 | libmpv1, libc6 (>= 2.35), ca-certificates, libfontconfig1, libfreetype6, libgcc-s1, libxkbcommon0, libxkbcommon-x11-0, libwayland-client0, libvulkan1 | libgl1-mesa-dri
Installed-Size: $SIZE
Maintainer: Paul Herter <kontakt@paulherter.de>
Description: Swiftly Player, Jellyfin client
 Plays movies and shows from your own Jellyfin server without transcoding.
EOT
dpkg-deb --root-owner-group --build "$D" "$OUT/${PKG}_${V}_amd64.deb" >/dev/null

# rpm (binary is prebuilt: no build step, no debuginfo)
RB="$PWD/$OUT/rpmbuild"; mkdir -p "$RB"/{BUILD,RPMS,SPECS,SOURCES,SRPMS}
cat > "$RB/SPECS/$PKG.spec" <<EOT
Name: $PKG
Provides: swiftly-player
Version: $V
Release: 1
Summary: Swiftly Player, Jellyfin client
License: MPL-2.0
BuildArch: x86_64
Requires: libmpv.so.2()(64bit)
Requires: libxkbcommon-x11
Requires: libxkbcommon
Requires: libwayland-client
Requires: vulkan-loader
Requires: fontconfig
Requires: ca-certificates
Requires: freetype
AutoReqProv: no
%global debug_package %{nil}
%global _build_id_links none
%define __os_install_post %{nil}
%description
Plays movies and shows from your own Jellyfin server without transcoding.
%install
mkdir -p %{buildroot}
cp -a $PWD/$R/usr %{buildroot}/usr
%files
/usr/bin/swiftly-player
/usr/share/applications/de.paulherter.swiftly.player.desktop
/usr/share/icons/hicolor/256x256/apps/swiftly-player.png
/usr/share/icons/hicolor/64x64/apps/swiftly-player.png
EOT
rpmbuild -bb --define "_topdir $RB" "$RB/SPECS/$PKG.spec" >/dev/null 2>"$OUT/rpm.log" || { tail -20 "$OUT/rpm.log"; exit 1; }
cp "$RB"/RPMS/*/*.rpm "$OUT/"

if [ -n "${SWIFTLY_LINUX_ONLY:-}" ]; then   # SWIFTLY_LINUX_ONLY=1: tar.gz, deb and rpm only
  rm -rf "$OUT/tar" "$OUT/root" "$OUT/deb" "$OUT/rpmbuild" "$STRIPPED"; ls -la "$OUT" | tail -n +2; exit 0
fi
echo "== Windows build (cargo xwin)"
cargo xwin build -q --release --target x86_64-pc-windows-msvc -p swiftly-desktop --features mpv
EXE=${CARGO_TARGET_DIR:-target}/x86_64-pc-windows-msvc/release/swiftly-desktop.exe
S="$OUT/win/Swiftly Player"; mkdir -p "$S"
cp "$EXE" "$S/Swiftly Player.exe"; echo "$README" > "$S/README.txt"
if [ -f "$MPVDLL" ]; then
  cp "$MPVDLL" "$S/libmpv-2.dll"
  (cd "$OUT/win" && zip -q -r "../Swiftly-Player-$V-win-x64-portable.zip" "Swiftly Player")
  "$NSISDIR/bin/makensis" -V1 -DVERSION="$V" -DSTAGE="$PWD/$S" -DOUTFILE="$PWD/$OUT/Swiftly-Player-$V-win-x64-Setup.exe" \
    -DICON="$PWD/crates/swiftly-desktop/assets/swiftly-player.ico" "$A/swiftly-player.nsi"
else
  echo "libmpv-2.dll missing at $MPVDLL: Windows Setup and portable zip skipped"
fi
rm -rf "$OUT/tar" "$OUT/root" "$OUT/deb" "$OUT/rpmbuild" "$OUT/win" "$STRIPPED"
ls -la "$OUT" | tail -n +2
