#!/usr/bin/env bash
# RETIRED. This installer sets up the package source of the previous Linux app
# (Swift and GTK4, `Linux/`), which the Rust desktop app replaces. The current
# app is installed from the release: the AUR package `swiftly-player-bin` on
# Arch, the .deb or .rpm on Debian, Ubuntu and Fedora, or the tar.gz on any
# distribution (needs libmpv). See `Documentation/Building.md`.
#
# Forwarder. The installer moved to Linux/Install/swiftly-install.sh; this
# file stays so the command published earlier keeps working:
#
#     curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Installieren/swiftly-installieren.sh | bash
#
# Arguments are passed on.

set -euo pipefail

exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Install/swiftly-install.sh)" swiftly-install "$@"
