#!/bin/bash
# Sucht Code, den niemand mehr ruft.
#
# **Das Skript sagt, WO nachzusehen ist — nicht, WAS dort steht.** Jeder
# Treffer ist ein Hinweis, kein Urteil. Wer die Ausgabe als Befund liest
# und danach handelt, ohne die Stellen aufzuschlagen, macht denselben
# Fehler wie beim Abhaken von Aenderungen.md: die Liste sagt *dass*
# etwas ist, nicht *wie*.
#
# **Wofuer genau.** Nicht zum Aufraeumen — dafuer waere es Kosmetik. Sondern
# fuer den Fall aus CLAUDE.md: `trefferauskunft` wurde nach `Titelangaben`
# gehoben, die alte Kopie blieb stehen, und ein als behoben gemeldeter Fehler
# war noch live, weil an einer Stelle weiter die alte Fassung lief. Solche
# Leichen meldet Periphery namentlich.
#
# **Dauert.** Periphery baut jedes Ziel einmal durch, ehe es indiziert —
# rechne mit einigen Minuten. Kein Kandidat fuer pruefen.sh, sondern etwas,
# das man nach einer groesseren Umstellung einmal laufen laesst.
#
#   Werkzeuge/totes-finden.sh            alle drei Apple-Ziele
#   Werkzeuge/totes-finden.sh Swiftly-iOS  nur eins

set -u
cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
command -v periphery >/dev/null || { echo "periphery fehlt: brew install peripheryapp/periphery/periphery"; exit 1; }

ziele="${1:-Swiftly-iOS,Swiftly-tvOS,Swiftly-macOS}"
xcodegen generate >/dev/null 2>&1

# **Periphery 2.21.2 nimmt keine Komma-Liste.** `--targets "A,B"` sucht ein
# Ziel, das woertlich so heisst, und bricht mit "does not exist" ab; die
# Voreinstellung dieses Skripts lief deshalb nie durch, nur der Aufruf mit
# einem einzelnen Ziel. Mehrfach genannte Flaggen gehen. (Gemeldet von
# swiftly-ef, nachgemessen am 09.09.2026.)
flaggen=()
IFS=',' read -ra einzeln <<< "$ziele"
for z in "${einzeln[@]}"; do flaggen+=(--schemes "$z" --targets "$z"); done

# --retain-public, weil JellyfinKit ein Paket ist: was es nach aussen anbietet,
# ruft die App, nicht das Paket selbst. Ohne das meldet Periphery die halbe
# oeffentliche Schnittstelle als tot.
periphery scan \
    --project Swiftly.xcodeproj \
    "${flaggen[@]}" \
    --retain-public \
    --retain-objc-accessible \
    --format xcode

echo
echo "Das sagt, wo nachzusehen ist — nicht, was dort steht. Was nur eine andere"
echo "Plattform ruft, sieht ein Lauf gegen ein Ziel nicht. Stellen aufschlagen."
