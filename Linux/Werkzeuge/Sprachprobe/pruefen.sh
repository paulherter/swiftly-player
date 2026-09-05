#!/bin/bash
# Die Sprachprobe unter mehreren Spracheinstellungen — auf dem Linux-Rechner.
#
# **Warum es das Skript gibt und nicht nur das Programm.** Die interessanten
# Fälle sind die, an die man beim Aufruf von Hand nicht denkt: `LANGUAGE` als
# Doppelpunktliste, `LC_ALL`, das alles übersteuert, und eine Sprache ohne
# Katalog. Wer nur `LANG=en_US.UTF-8` probiert, hält den Fehler für behoben,
# den er gerade gesucht hat.
#
#     bash pruefen.sh [Baumpfad]     (Vorgabe: $HOME/swiftly)
set -uo pipefail
source "$HOME/.swift-env.sh"
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

BAUM=${1:-$HOME/swiftly}
cd "$BAUM/Linux/Werkzeuge/Sprachprobe" || exit 1
if ! swift build 2>&1 | grep -q "Compiling\|Build complete"; then
  swift build 2>&1 | grep "error:" && exit 1
fi
BIN=$(swift build --show-bin-path)/Sprachprobe
RES="$BAUM/Linux/.build/debug/SwiftlyLinux_SwiftlyLinux.resources"
[ -d "$RES" ] || echo "  (Bündel der Oberfläche fehlt — erst 'swift build' in $BAUM/Linux)"

lauf() {
  echo "════ $1 ════"
  shift
  env -u LANGUAGE -u LC_ALL -u LC_MESSAGES -u LANG "$@" "$BIN" "$RES" 2>&1
  echo
}

lauf "deutsches System"                 LANG=de_DE.UTF-8
lauf "englisches System"                LANG=en_US.UTF-8
lauf "französisch — kein Katalog, muss auf Englisch fallen" LANG=fr_FR.UTF-8
lauf "LANGUAGE schlägt LANG"            LANG=de_DE.UTF-8 LANGUAGE=en_GB:en
lauf "LC_ALL schlägt LANG"              LANG=de_DE.UTF-8 LC_ALL=en_US.UTF-8
lauf "gar nichts gesetzt — muss auf Englisch fallen"
