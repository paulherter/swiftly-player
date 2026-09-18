#!/bin/bash
# Baut Swiftly und spielt es auf das angeschlossene iPhone.
#
# Voraussetzung: in Xcode unter Einstellungen > Accounts ist eine Apple-ID
# hinterlegt. Eine normale reicht (kostenloses "Personal Team") -- die App
# laeuft dann sieben Tage, danach neu draufspielen.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Team steht in project.yml -- nicht aus dem Zertifikatsnamen raten, dort
# steht die persoenliche Kennung, nicht die Team-ID.
TEAM="${1:-}"
[ -z "$TEAM" ] && TEAM=$(grep -m1 "DEVELOPMENT_TEAM:" project.yml | awk '{print $2}')
[ -z "$TEAM" ] && { echo "Kein Team gefunden. In Xcode > Einstellungen > Accounts anmelden."; exit 1; }
echo "Team: $TEAM"

# **Zwei Kennungen, und sie sind nicht dieselbe.** `devicectl` fuehrt jedes
# Geraet unter einer eigenen `identifier`-UUID; `xcodebuild -destination`
# will die Hardware-UDID (`00008130-…`). Wer die erste weiterreicht, bekommt
# „Unable to find a destination matching the provided destination specifier".
#
# **Und es haengt nicht nur ein Geraet dran.** Der erste Eintrag war hier der
# Apple TV — gebaut wurde dann fuer den, oder eben gar nicht. Gesucht wird
# deshalb ausdruecklich nach `platform == iOS`.
#
# --json-output muss in eine Datei: auf /dev/stdout mischt sich die
# Tabellenausgabe darunter und das JSON ist nicht mehr lesbar.
GERAETE=$(mktemp -t swiftly-geraete)
trap 'rm -f "$GERAETE"' EXIT
xcrun devicectl list devices --json-output "$GERAETE" >/dev/null 2>&1 || true
read -r KENNUNG UDID NAME <<<"$(python3 -c 'import json,sys
for g in json.load(open(sys.argv[1]))["result"]["devices"]:
    h = g.get("hardwareProperties", {})
    if h.get("platform") != "iOS": continue
    print(g["identifier"], h.get("udid",""), g.get("deviceProperties",{}).get("name",""))
    break' "$GERAETE" 2>/dev/null || true)"

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
xcrun devicectl device install app --device "$KENNUNG" "$APP"
echo "Fertig. App auf dem iPhone starten."
