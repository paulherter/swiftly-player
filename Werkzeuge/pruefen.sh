#!/bin/bash
# Ein Befehl statt fünf: Pakettests, alle Apple-Ziele, und die Frage, ob
# irgendwo noch Arbeit liegt.
#
# **Warum die Zweigprüfung dazugehört.** Am 05.09.2026 trug der tvos-Zweig
# sieben Commits, die nie in main ankamen — darunter zwei Behebungen von
# Fehlern, die Der Build, der an dem Tag zu den Testern ging, hatte sie nicht.
# Kein Bau und kein Test hätte das gezeigt: beide prüfen, was da ist, nicht was
# fehlt.
#
# Werkzeuge/pruefen.sh          alles Werkzeuge/pruefen.sh schnell  nur Tests
# und Zweige, ohne Simulatorbau
#
# Rückgabe 0 heisst: alles grün und nichts liegengeblieben.

set -u
cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

schnell=false
[ "${1:-}" = "schnell" ] && schnell=true
fehler=0
gruen=$'\033[32m'; rot=$'\033[31m'; gelb=$'\033[33m'; aus=$'\033[0m'

melden() { printf '%-34s %s\n' "$1" "$2"; }

echo "── Pakettests ─────────────────────────────────────────"
if ausgabe=$(cd Packages/JellyfinKit && xcrun swift test 2>&1); then
    melden "JellyfinKit" "${gruen}$(echo "$ausgabe" | grep -oE 'Test run with [0-9]+ tests' | tail -1)${aus}"
else
    melden "JellyfinKit" "${rot}FEHLGESCHLAGEN${aus}"
    echo "$ausgabe" | grep -E "error:|failed" | head -10
    fehler=1
fi

if [ "$schnell" = false ]; then
    echo
    echo "── Apple-Ziele ────────────────────────────────────────"
    # Der eigene Bau prueft nur die eigene Haelfte: viele Zeilen in
    # project.yml stehen wortgleich in mehreren Zielbloecken, und ein
    # Suchen-und-Ersetzen trifft alle. Deshalb immer alle drei.
    xcodegen generate >/dev/null 2>&1
    for ziel in Swiftly-iOS:"platform=iOS Simulator,name=iPhone 17 Pro" \
                Swiftly-tvOS:"platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" \
                Swiftly-macOS:"platform=macOS"; do
        name=${ziel%%:*}; wohin=${ziel#*:}
        if xcodebuild -project Swiftly.xcodeproj -scheme "$name" \
               -destination "$wohin" build 2>&1 | grep -q "BUILD SUCCEEDED"; then
            melden "$name" "${gruen}gebaut${aus}"
        else
            melden "$name" "${rot}FEHLGESCHLAGEN${aus}"
            fehler=1
        fi
    done
fi

echo
echo "── Liegt noch etwas auf einem Zweig? ──────────────────"
for zweig in ios ipad mac tvos linux windows; do
    git rev-parse --verify -q "$zweig" >/dev/null 2>&1 || continue
    eigene=$(git rev-list --count "main..$zweig")
    hinter=$(git rev-list --count "$zweig..main")
    if [ "$eigene" -gt 0 ]; then
        melden "$zweig" "${gelb}$eigene Commits nicht in main${aus} ($hinter hinterher)"
        git log --oneline "main..$zweig" | sed 's/^/      /'
        fehler=1
    else
        melden "$zweig" "${gruen}nichts offen${aus} ($hinter hinterher)"
    fi
done

echo
echo "── Katalog ────────────────────────────────────────────"
python3 "$(dirname "$0")/katalogpruefen.py" || fehler=1
echo

echo "── Offene Spalten in der Aenderungsliste ──────────────"
liste="../Swiftly-Notizen/AppStore/Aenderungen.md"
if [ -f "$liste" ]; then
    offen=$(grep -cE '^\| [0-9]+ \|.*\| · \|' "$liste" 2>/dev/null || echo 0)
    melden "Zeilen mit einem ·" "$offen"
else
    melden "Aenderungsliste" "${gelb}nicht gefunden${aus}"
fi

echo
if [ "$fehler" -eq 0 ]; then
    echo "${gruen}Alles gruen, nichts liegengeblieben.${aus}"
else
    echo "${rot}Es gibt etwas zu tun — siehe oben.${aus}"
fi
exit $fehler
