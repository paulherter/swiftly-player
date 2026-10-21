#!/bin/bash
# Builds Swiftly and installs it on the connected iPhone.
#
# Prerequisite: an Apple ID is set up in Xcode under Settings > Accounts. A
# free "Personal Team" is enough -- the app then runs for seven days and has
# to be installed again afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# The team is in project.yml -- do not guess it from the certificate name,
# which carries the personal identifier, not the team ID.
TEAM="${1:-}"
[ -z "$TEAM" ] && TEAM=$(grep -m1 "DEVELOPMENT_TEAM:" project.yml | awk '{print $2}')
[ -z "$TEAM" ] && { echo "Kein Team gefunden. In Xcode > Einstellungen > Accounts anmelden."; exit 1; }
echo "Team: $TEAM"

# **Two identifiers, and they are not the same.** `devicectl` knows each
# device under its own `identifier` UUID; `xcodebuild -destination` wants the
# hardware UDID (`00008130-...`). Passing the first on gives "Unable to find
# a destination matching the provided destination specifier".
#
# **And more than one device is attached.** The first entry can be an Apple
# TV, so the build would target that or fail. The lookup therefore asks
# explicitly for `platform == iOS`.
#
# --json-output must go to a file: on /dev/stdout the table output mixes in
# and the JSON is no longer readable.
DEVICES=$(mktemp -t swiftly-geraete)
trap 'rm -f "$DEVICES"' EXIT
xcrun devicectl list devices --json-output "$DEVICES" >/dev/null 2>&1 || true
read -r ID UDID NAME <<<"$(python3 -c 'import json,sys
for g in json.load(open(sys.argv[1]))["result"]["devices"]:
    h = g.get("hardwareProperties", {})
    if h.get("platform") != "iOS": continue
    print(g["identifier"], h.get("udid",""), g.get("deviceProperties",{}).get("name",""))
    break' "$DEVICES" 2>/dev/null || true)"

if [ -z "${UDID:-}" ]; then
  echo "Kein iPhone gefunden. Ist es im selben WLAN, entsperrt und gekoppelt?" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Geraet: ${NAME:-iPhone} ($UDID)"

xcodebuild -project Swiftly.xcodeproj -scheme Swiftly-iOS \
  -destination "id=$UDID" -derivedDataPath build/DD \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build

APP=$(find build/DD/Build/Products/Debug-iphoneos -name "Swiftly-iOS.app" -maxdepth 1 | head -1)
echo "Installiere $APP"
xcrun devicectl device install app --device "$ID" "$APP"
echo "Fertig. App auf dem iPhone starten."
