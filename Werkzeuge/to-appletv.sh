#!/bin/bash
# Builds Swiftly and installs it on the connected Apple TV.
#
# Counterpart to `to-iphone.sh`, with the same two pitfalls: `devicectl`
# and `xcodebuild` know the same device under **different** identifiers (one
# a UUID of its own, the other the hardware UDID), and more than one device
# is usually attached. The lookup therefore asks explicitly for
# `platform == tvOS`.
#
# Prerequisite: the Apple TV is paired with Xcode (Window > Devices), on the
# same network and switched on.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# **Release is the honest comparison.** A Debug build makes VLC write its own
# log during playback -- hundreds of lines per second, each through `print`, a
# lock and a file write. Measuring how evenly frames arrive with that on
# partly measures the measuring. Other players and App Store builds run as
# Release.
KONFIG=Debug
ARGS=()
for a in "$@"; do
  case "$a" in
    --release) KONFIG=Release ;;
    --debug)   KONFIG=Debug ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
echo "Konfiguration: $KONFIG"

TEAM="${1:-}"
[ -z "$TEAM" ] && TEAM=$(grep -m1 "DEVELOPMENT_TEAM:" project.yml | awk '{print $2}')
[ -z "$TEAM" ] && { echo "Kein Team gefunden. In Xcode > Einstellungen > Accounts anmelden."; exit 1; }
echo "Team: $TEAM"

DEVICES=$(mktemp -t swiftly-geraete)
trap 'rm -f "$DEVICES"' EXIT
xcrun devicectl list devices --json-output "$DEVICES" >/dev/null 2>&1 || true
read -r ID UDID NAME <<<"$(python3 -c 'import json,sys
for g in json.load(open(sys.argv[1]))["result"]["devices"]:
    h = g.get("hardwareProperties", {})
    if h.get("platform") != "tvOS": continue
    print(g["identifier"], h.get("udid",""), g.get("deviceProperties",{}).get("name",""))
    break' "$DEVICES" 2>/dev/null || true)"

if [ -z "${UDID:-}" ]; then
  echo "Kein Apple TV gefunden. Ist er im selben WLAN, an und mit Xcode gekoppelt?" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Geraet: ${NAME:-Apple TV} ($UDID)"

xcodebuild -project Swiftly.xcodeproj -scheme Swiftly-tvOS \
  -destination "id=$UDID" -derivedDataPath build/DD-tv \
  -configuration "$KONFIG" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build

APP=$(find "build/DD-tv/Build/Products/$KONFIG-appletvos" -name "Swiftly-tvOS.app" -maxdepth 1 | head -1)
echo "Installiere $APP"
xcrun devicectl device install app --device "$ID" "$APP"

# **Check, don't assume.** A path taken from `-showBuildSettings` without
# building first can point at an older build. A timestamp proves that
# something was compiled, not which build it is.
echo
echo "Gebaut: $(stat -f '%Sm' "$APP/Swiftly-tvOS") ($KONFIG)"
echo "Fertig. App auf dem Apple TV starten."
