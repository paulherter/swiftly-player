#!/bin/bash
# Holt das VLCKit-XCFramework nach Vendor/. Nicht im Git, weil 2 GB.
#
# Fassung 4.0.0-a23. Nur bei VideoLAN verfuegbar (der GitHub-Spiegel endet bei
# a21), und VideoLAN drosselt auf ~40 KB/s je Verbindung. Fuer einen einzelnen
# Abruf waeren das Stunden — build/vlckit/holen-a23.sh laedt deshalb in
# parallelen Stuecken.
set -euo pipefail
cd "$(dirname "$0")/.."
# **ACHTUNG: Diese Fassung hat einen bekannten Fehler.**
#
# VLC 4 verwirft in `matroska_segment_seeker.cpp` den Index von MKV-Dateien
# ueber HTTP — Spruenge lesen dann ab Dateianfang und brauchen 30 bis 90
# Sekunden. VLC 3 hat den Vorbehalt nicht; deshalb springt Swiftfin.
#
# Der Patch liegt in `Werkzeuge/vlckit-patches/`. Wer die App mit
# funktionierendem Springen bauen will, braucht ein gepatchtes VLCKit —
# dieses Skript holt die **ungepatchte** offizielle Fassung.
#
# Siehe README, Abschnitt „Building".

URL="https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260805-1123.zip"
SHA="c0c3ae1665053db5898581efc8ee920f526643526297f7fc643599532dc2ccf5"

[ -d Vendor/VLCKit.xcframework ] && { echo "Schon da."; exit 0; }
mkdir -p Vendor
echo "Lade VLCKit (861 MB)…"
curl -sSL --retry 3 -o /tmp/vlckit.zip "$URL"
echo "Pruefsumme…"
IST=$(shasum -a 256 /tmp/vlckit.zip | cut -d' ' -f1)
[ "$IST" = "$SHA" ] || { echo "PRUEFSUMME FALSCH: $IST"; exit 1; }
unzip -q -o /tmp/vlckit.zip -d /tmp/vlckit-entpackt
mv /tmp/vlckit-entpackt/VLCKit.xcframework Vendor/
rm -rf /tmp/vlckit.zip /tmp/vlckit-entpackt
echo "Fertig: Vendor/VLCKit.xcframework"
