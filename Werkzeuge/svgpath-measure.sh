#!/bin/sh
# Measures how much CPU time `SVGPfad` costs on an Apple TV.
#
# Background: `SVGPfad` used to re-parse on **every** layout, i.e. once per
# frame of every animation. The TV animates more and the hardware is weaker,
# so the cost shows more clearly there.
#
# Usage: Werkzeuge/svgpath-measure.sh
# Afterwards: open the .trace file in Instruments, or evaluate it here.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVICE="${SWIFTLY_TV_DEVICE:?set SWIFTLY_TV_DEVICE to the Apple TV UDID from \`xcrun xctrace list devices\`}"
APP=de.paulherter.swiftly
TARGET="${TMPDIR:-/tmp}/svgpfad-$(date +%H%M%S).trace"

echo "Nimmt 20 Sekunden auf. Auf dem Fernseher bitte scrollen, damit sich"
echo "etwas bewegt — die Startseite mit den Reihen ist der richtige Ort."
echo

xcrun xctrace record \
    --template "Time Profiler" \
    --device "$DEVICE" \
    --attach "$APP" \
    --time-limit 20s \
    --output "$TARGET"

echo
echo "Aufnahme: $TARGET"
echo
echo "Stichproben mit SVGPfad im Stapel:"
xcrun xctrace export --input "$TARGET" --xpath \
    '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' 2>/dev/null \
  | grep -c "SVGPfad" || echo "  (Auswertung von Hand in Instruments)"
