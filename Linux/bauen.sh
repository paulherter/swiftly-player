#!/bin/bash
# Swiftly fuer Linux bauen.
#
#     ./Linux/bauen.sh            bauen
#     ./Linux/bauen.sh --starten  bauen und starten
#
# **Der Bau richtet seine Umgebung selbst ein.** Vorher hing er an
# Variablen, die niemand setzte, und an Sonamen, die ein Systemupdate
# umbenennen kann — siehe `umgebung.sh`. Wer hier scheitert, soll in der
# ersten Zeile lesen, woran, statt in einem Bindefehler zu suchen.
set -uo pipefail
hier="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${hier}/umgebung.sh"

echo "── Umgebung ───────────────────────────────────────────"
if ! umgebung_pruefen; then
    echo
    echo "Abgebrochen: erst das Fehlende herstellen, dann neu bauen."
    exit 1
fi

echo
echo "── Bauen ──────────────────────────────────────────────"
cd "$hier" || exit 1
konfiguration="${KONFIGURATION:-debug}"
swift build -c "$konfiguration" || exit 1

binaer="${hier}/.build/${konfiguration}/SwiftlyLinux"
echo
echo "Fertig: ${binaer}"
echo "Gebaut: $(date -r "$binaer" '+%d.%m.%Y %H:%M:%S' 2>/dev/null || echo '?')"

if [ "${1:-}" = "--starten" ]; then
    echo
    echo "── Starten ────────────────────────────────────────────"
    exec "$binaer"
fi
