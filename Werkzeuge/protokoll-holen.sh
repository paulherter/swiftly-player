#!/bin/bash
# Holt swiftly.log aus dem App-Container vom iPhone.
#
# Noetig, weil beim Test mit ausgeschaltetem WLAN die Protokollverbindung
# zum Mac mit abreisst — genau waehrend der interessanten Sekunden.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

GERAETE=$(mktemp -t swiftly-geraete)
trap 'rm -f "$GERAETE"' EXIT
xcrun devicectl list devices --json-output "$GERAETE" >/dev/null 2>&1 || true
UDID=$(python3 -c 'import json,sys
for g in json.load(open(sys.argv[1]))["result"]["devices"]:
    if g.get("connectionProperties",{}).get("tunnelState") != "unavailable":
        print(g["identifier"]); break' "$GERAETE" 2>/dev/null || true)
[ -z "${UDID:-}" ] && { echo "Kein erreichbares Geraet." >&2; exit 1; }

ZIEL="${1:-swiftly.log}"
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier de.paulherter.swiftly \
  --source Documents/swiftly.log --destination "$ZIEL"
echo "Geholt nach $ZIEL ($(wc -l < "$ZIEL") Zeilen)"
