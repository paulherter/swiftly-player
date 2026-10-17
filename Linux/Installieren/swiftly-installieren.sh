#!/usr/bin/env bash
#
# Forwarder. The installer moved to Linux/Install/swiftly-install.sh; this
# file stays so the command published earlier keeps working:
#
#     curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Installieren/swiftly-installieren.sh | bash
#
# Arguments are passed on.

set -euo pipefail

exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Install/swiftly-install.sh)" swiftly-install "$@"
