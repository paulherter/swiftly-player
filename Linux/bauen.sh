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

# ── Private Bibliotheken mitnehmen ─────────────────────────────────────
#
# **Eine gebaute App muss ohne gesetzte Umgebung starten.** Sie tat es
# nicht: `librlottie.so` liegt in `~/.local/lib`, das kein Systempfad ist,
# und gefunden wurde sie nur, weil `umgebung.sh` `LD_LIBRARY_PATH` setzt.
# Ueber `bauen.sh` lief sie deshalb, per Doppelklick oder aus einer
# fremden Sitzung nicht — mit einer Meldung, die nach einem kaputten Bau
# aussieht („cannot open shared object file"), es aber nicht war.
#
# Der Suchpfad liess sich nicht einbauen: SwiftPM verwirft `-Wl,-rpath`
# als `prohibited flag`, wortlos bis auf eine Warnung im Bauprotokoll.
# Was uebrig bleibt, steht ohnehin schon im Runpath — `$ORIGIN`, das
# Verzeichnis der Binaerdatei. Also kommen die Bibliotheken dorthin.
#
# Kopiert wird nur, was die Binaerdatei wirklich braucht und was
# ausserhalb der Systempfade liegt; `ldd` sagt beides.
if [ -x "$binaer" ]; then
    ziel="$(dirname "$binaer")"
    anzahl=0
    while read -r pfad; do
        case "$pfad" in
            "${umg_lokal}/lib/"*|"${umg_flick}/"*)
                if [ ! -e "${ziel}/$(basename "$pfad")" ] \
                   || [ "$pfad" -nt "${ziel}/$(basename "$pfad")" ]; then
                    cp -L "$pfad" "$ziel/" && anzahl=$((anzahl + 1))
                fi
                ;;
        esac
    done < <(ldd "$binaer" 2>/dev/null | awk '{print $3}' | grep '^/')
    [ "$anzahl" -gt 0 ] && echo "Mitgenommen: ${anzahl} Bibliothek(en) neben die App."

    # Und beweisen, dass es reicht: ohne jede gesetzte Variable nachsehen,
    # ob noch etwas fehlt. Eine Warnung hier ist der Fehler von oben,
    # nur bevor jemand darueber stolpert.
    fehlend="$(env -u LD_LIBRARY_PATH ldd "$binaer" 2>/dev/null | grep 'not found' || true)"
    if [ -n "$fehlend" ]; then
        echo
        echo "WARNUNG: ohne gesetzte Umgebung fehlt der App noch etwas:"
        echo "$fehlend" | sed 's/^/  /'
    fi
fi

echo
echo "Fertig: ${binaer}"
echo "Gebaut: $(date -r "$binaer" '+%d.%m.%Y %H:%M:%S' 2>/dev/null || echo '?')"

if [ "${1:-}" = "--starten" ]; then
    echo
    echo "── Starten ────────────────────────────────────────────"
    exec "$binaer"
fi
