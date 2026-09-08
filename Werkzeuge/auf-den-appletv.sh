#!/bin/bash
# Baut Swiftly und spielt es auf den angeschlossenen Apple TV.
#
# Gegenstueck zu `aufs-iphone.sh`, und mit denselben zwei Fallen: `devicectl`
# und `xcodebuild` fuehren dasselbe Geraet unter **verschiedenen** Kennungen
# (das eine eine eigene UUID, das andere die Hardware-UDID), und am Rechner
# haengt mehr als ein Geraet. Gesucht wird deshalb ausdruecklich nach
# `platform == tvOS`.
#
# Voraussetzung: der Apple TV ist mit Xcode gekoppelt (Fenster > Geraete),
# im selben Netz und eingeschaltet.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# **Release ist der ehrliche Vergleich.** Im Debug-Bau schreibt VLCs eigenes
# Protokoll waehrend der Wiedergabe mit — hunderte Zeilen je Sekunde, jede
# durch `print`, eine Sperre und einen Dateischreibvorgang. Wer damit misst,
# wie gleichmaessig Bilder ankommen, misst zum Teil das Messen. Swiftfin und
# unsere TestFlight-Fassung laufen beide als Release.
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

GERAETE=$(mktemp -t swiftly-geraete)
trap 'rm -f "$GERAETE"' EXIT
xcrun devicectl list devices --json-output "$GERAETE" >/dev/null 2>&1 || true
read -r KENNUNG UDID NAME <<<"$(python3 -c 'import json,sys
for g in json.load(open(sys.argv[1]))["result"]["devices"]:
    h = g.get("hardwareProperties", {})
    if h.get("platform") != "tvOS": continue
    print(g["identifier"], h.get("udid",""), g.get("deviceProperties",{}).get("name",""))
    break' "$GERAETE" 2>/dev/null || true)"

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
xcrun devicectl device install app --device "$KENNUNG" "$APP"

# **Nachmessen, nicht annehmen.** Am 08.09.2026 habe ich einen Stand von
# sieben Minuten vorher aufgespielt und als neu gemeldet, weil ich den Pfad
# aus `-showBuildSettings` genommen habe, ohne vorher zu bauen. Ein Zeitstempel
# beweist, dass uebersetzt wurde — nicht womit.
echo
echo "Gebaut: $(stat -f '%Sm' "$APP/Swiftly-tvOS") ($KONFIG)"
echo "Fertig. App auf dem Apple TV starten."
