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

# devicectl meldet je nach Kopplung "connected" oder "available" — beides
# heisst erreichbar. Nur auf eines zu filtern hat das Skript still abbrechen
# lassen (leere UDID + pipefail), ohne eine Zeile Erklaerung.
# --json-output muss in eine Datei: auf /dev/stdout mischt sich die
# Tabellenausgabe darunter und das JSON ist nicht mehr lesbar.
GERAETE=$(mktemp -t swiftly-geraete)
trap 'rm -f "$GERAETE"' EXIT
xcrun devicectl list devices --json-output "$GERAETE" >/dev/null 2>&1 || true
UDID=$(python3 -c 'import json,sys
for g in json.load(open(sys.argv[1]))["result"]["devices"]:
    if g.get("connectionProperties",{}).get("tunnelState") != "unavailable":
        print(g["identifier"]); break' "$GERAETE" 2>/dev/null || true)

if [ -z "${UDID:-}" ]; then
  echo "Kein erreichbares Geraet. Ist das iPhone im selben WLAN und entsperrt?" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Geraet: $UDID"

xcodebuild -project Swiftly.xcodeproj -scheme Swiftly-iOS \
  -destination "id=$UDID" -derivedDataPath build/DD \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build

APP=$(find build/DD/Build/Products/Debug-iphoneos -name "Swiftly-iOS.app" -maxdepth 1 | head -1)
echo "Installiere $APP"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "Fertig. App auf dem iPhone starten."
