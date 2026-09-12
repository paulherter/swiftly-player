#!/bin/bash
# PostToolUse-Haken: meldet eine neue Quelldatei, die das .xcodeproj noch
# nicht kennt.
#
# Das .xcodeproj ist nicht eingecheckt und wird aus project.yml erzeugt. Eine
# neue Datei unter Sources/ ist deshalb bis zum naechsten `xcodegen generate`
# unsichtbar — der Bau laeuft durch, ohne sie zu uebersetzen, und der Fehler
# sieht spaeter aus wie ein fehlendes Symbol.
#
# **Warum nicht ueber den Dateinamen.** Erste Fassung suchte den Basisnamen im
# project.pbxproj. Das gibt falsche Entwarnung: mindestens zehn Basisnamen
# kommen in mehreren Zielen vor — Stil.swift liegt in Shared, tvOS und macOS,
# HauptView.swift ebenso. Nachschaerfen geht auch nicht, im pbxproj steht nur
# `path = Stil.swift`, der Pfad relativ zum Baum gar nicht. (Aufgefallen der
# Sitzung swiftly-ef beim Gegenlesen, 08.09.2026.)
#
# Deshalb ueber zwei Eigenschaften, die keinen Namen brauchen:
#   1. Git kennt die Datei noch nicht  -> sie ist wirklich neu
#   2. Sie ist juenger als project.pbxproj -> das Projekt ist danach nicht
#      neu erzeugt worden
#
# Rueckgabe 2 blockt hier nichts (die Datei ist ja schon geschrieben), sie
# schickt den Hinweis nur an die Sitzung zurueck.

eingabe=$(cat)
ziel=$(printf '%s' "$eingabe" | jq -r '.tool_input.file_path // empty')
case "$ziel" in
    */Sources/*.swift) ;;
    *) exit 0 ;;
esac
[ -f "$ziel" ] || exit 0

baum=$(git -C "$(dirname "$ziel")" rev-parse --show-toplevel 2>/dev/null) || exit 0
pbx=$(ls -d "$baum"/*.xcodeproj/project.pbxproj 2>/dev/null | head -1)
[ -f "$pbx" ] || exit 0

git -C "$baum" ls-files --error-unmatch "$ziel" >/dev/null 2>&1 && exit 0   # schon versioniert
[ "$ziel" -nt "$pbx" ] || exit 0                                            # Projekt ist juenger

echo "Neu und noch nicht im .xcodeproj: ${ziel#$baum/} — vor dem Bauen: xcodegen generate" >&2
exit 2
