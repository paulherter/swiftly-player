#!/bin/sh
# Misst, wie viel Rechenzeit `SVGPfad` auf dem Apple TV kostet.
#
# Hintergrund: `SVGPfad` parste bis zum Fix bei **jedem** Auslegen neu, also
# einmal je Einzelbild jeder Bewegung. Auf dem Mac waren das 75 von 439
# Stichproben; nach dem Fix 3 von 439. Auf dem Fernseher wird mehr animiert
# und die Maschine ist schwaecher — die Zahl duerfte deutlicher ausfallen.
#
# Aufruf: Werkzeuge/svgpfad-messen.sh
# Danach: die .trace-Datei in Instruments oeffnen, oder gleich hier auswerten.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

GERAET=00008110-0018142C0189401E     # Paul's TV, aus `xctrace list devices`
APP=de.paulherter.swiftly
ZIEL="${TMPDIR:-/tmp}/svgpfad-$(date +%H%M%S).trace"

echo "Nimmt 20 Sekunden auf. Auf dem Fernseher bitte scrollen, damit sich"
echo "etwas bewegt — die Startseite mit den Reihen ist der richtige Ort."
echo

xcrun xctrace record \
    --template "Time Profiler" \
    --device "$GERAET" \
    --attach "$APP" \
    --time-limit 20s \
    --output "$ZIEL"

echo
echo "Aufnahme: $ZIEL"
echo
echo "Stichproben mit SVGPfad im Stapel:"
xcrun xctrace export --input "$ZIEL" --xpath \
    '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' 2>/dev/null \
  | grep -c "SVGPfad" || echo "  (Auswertung von Hand in Instruments)"
