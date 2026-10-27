#!/usr/bin/env bash
# One-time setup of the Linux build inside WSL2 (Ubuntu 24.04) on the Windows PC.
# Run it inside WSL as root:  wsl -d Ubuntu-24.04 -u root -- bash wsl-einrichten.sh
# Puts Swift and rlottie under /root/.local; nothing runs in the background.
set -euo pipefail
swift_version="6.3.3"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential git curl pkg-config binutils gnupg2 unzip tzdata \
    libgtk-4-dev libvlc-dev vlc libcurl4-openssl-dev libxml2-dev libncurses-dev \
    libsqlite3-dev libedit-dev libpython3-dev zlib1g-dev libstdc++-13-dev libz3-dev

if [ ! -x "$HOME/.local/swift/usr/bin/swift" ]; then
    mkdir -p "$HOME/.local/swift"
    curl -fsSL "https://download.swift.org/swift-${swift_version}-release/ubuntu2404/swift-${swift_version}-RELEASE/swift-${swift_version}-RELEASE-ubuntu24.04.tar.gz" \
        | tar xz -C "$HOME/.local/swift" --strip-components=1
fi
grep -q 'local/swift/usr/bin' "$HOME/.profile" 2>/dev/null || \
    echo 'export PATH="$HOME/.local/swift/usr/bin:$PATH"' >> "$HOME/.profile"
export PATH="$HOME/.local/swift/usr/bin:$PATH"
swift --version

# rlottie is built from source into ~/.local, as on every Linux machine.
if ! PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig" pkg-config --exists rlottie; then
    bash "$(dirname "$0")/rlottie-build.sh"
fi
echo "FERTIG-WSL"
