#!/bin/bash
#
# Wer eine Ansicht von einer Plattform auf eine andere uebernimmt, muss
# wissen, ob die Vorlage juenger ist als das, was er anfasst. Genau das sagt
# dieses Skript — je Ansicht eine Zeile, je Plattform der letzte Commit, der
# ihre Datei angefasst hat.
#
#   Werkzeuge/gegenstuecke.sh              alle Ansichten
#   Werkzeuge/gegenstuecke.sh Serien       nur Zeilen, die "Serien" enthalten
#
# **Abgeleitet, nicht gefuehrt.** Die Staende kommen aus `git log`, nicht aus
# einer Tabelle, die jemand pflegen muesste — eine solche Tabelle hat dieselbe
# Halbwertzeit wie die Aenderungsliste, und die hat am 05.09.2026 eine
# Uebernahme achtmal in die Irre gefuehrt: sie sagt *dass* etwas behoben ist,
# nicht *wie*.
#
# Gefuehrt ist nur die Zuordnung darunter, und die ist winzig und stabil.
# Sie muss sein, weil ein reiner Namensabgleich vier von sechs Plattformen
# treffen wuerde und ausgerechnet die zwei auslaesst, um die es ging: Linux
# und Windows teilen sich einen Quelltext, und dort heisst `SerienView`
# `Serienseite`. Faellt eine Datei weg oder wird sie umbenannt, meldet das
# Skript es als `fehlt` — die Zuordnung kann also nicht stillschweigend
# veralten.
#
# Die iOS-Spalte zeigt oft nach `Sources/Shared`: die iPhone- und
# iPad-Ansichten liegen dort, weil sie geteilt sind.
#
# **Was es nicht sagt, und das ist wichtig:** der Stern heisst „diese Datei
# wurde zuletzt angefasst", nicht „dieses Verhalten ist das neuere". Eine
# Datei kann wegen eines Kommentars juenger sein. Und wo mehrere Ansichten in
# einer Datei liegen — auf Linux etwa Start, Bibliothek und Suche allesamt in
# `Bereich.swift` —, faerbt ein Griff an eine davon alle drei Zeilen ein. Das
# Skript sagt, **wo nachzusehen ist**, nicht, was dort steht. Genau die
# Verwechslung hat die Aenderungsliste ausgeloest.

set -u
cd "$(dirname "$0")/.." || exit 1

# Ansicht : iOS/iPad : tvOS : macOS : Linux+Windows
ZUORDNUNG=(
  "Start:Sources/Shared/HomeView.swift:Sources/tvOS/HomeView.swift:Sources/macOS/HomeView.swift:Linux/Sources/SwiftlyLinux/Bereich.swift"
  "Detailseite:Sources/Shared/BrowseViews.swift:Sources/tvOS/DetailView.swift:Sources/macOS/DetailView.swift:Linux/Sources/SwiftlyLinux/Detailseite.swift"
  "Serienseite:Sources/Shared/SeriesView.swift:Sources/tvOS/SerienView.swift:Sources/macOS/SerienView.swift:Linux/Sources/SwiftlyLinux/Serienseite.swift"
  "Bibliothek:Sources/Shared/BrowseViews.swift:Sources/tvOS/BibliothekView.swift:Sources/macOS/BibliothekView.swift:Linux/Sources/SwiftlyLinux/Bereich.swift"
  "Player:Sources/iOS/PlayerScreen.swift:Sources/tvOS/PlayerScreen.swift:Sources/macOS/PlayerScreen.swift:Linux/Sources/SwiftlyLinux/Spieler.swift"
  "Profil:Sources/Shared/ProfilView.swift:Sources/tvOS/ProfilView.swift:Sources/macOS/ProfilView.swift:Linux/Sources/SwiftlyLinux/Einstellungsseiten.swift"
  "Einstellungen:Sources/Shared/EinstellungenView.swift:Sources/tvOS/ProfilView.swift:Sources/macOS/EinstellungenView.swift:Linux/Sources/SwiftlyLinux/Einstellungsseiten.swift"
  "Wiedergabe:Sources/Shared/WiedergabeEinstellungenView.swift:Sources/tvOS/ProfilView.swift:Sources/macOS/WiedergabeEinstellungenView.swift:Linux/Sources/SwiftlyLinux/Wahlen.swift"
  "Suche:Sources/Shared/SucheView.swift:Sources/tvOS/SucheView.swift:Sources/macOS/SucheView.swift:Linux/Sources/SwiftlyLinux/Bereich.swift"
  "Merkliste:Sources/Shared/MerklisteView.swift:Sources/tvOS/MerklisteView.swift:Sources/macOS/MerklisteView.swift:-"
  "Downloads:Sources/Shared/DownloadsView.swift:-:Sources/macOS/Macdownloads.swift:Linux/Sources/SwiftlyLinux/Downloadseite.swift"
  "Seerr:Sources/Shared/SeerrDetailView.swift:Sources/tvOS/SeerrView.swift:Sources/macOS/SeerrKachelUndSeite.swift:Linux/Sources/SwiftlyLinux/Seerrseite.swift"
  "Rahmen:Sources/Shared/HauptView.swift:Sources/tvOS/HauptView.swift:Sources/macOS/HauptView.swift:Linux/Sources/SwiftlyLinux/App.swift"
  "Stil:Sources/Shared/Stil.swift:Sources/tvOS/Stil.swift:Sources/macOS/Stil.swift:Linux/Sources/SwiftlyLinux/Stil.swift"
  "Bildfarbe:-:-:Sources/macOS/Bildfarbe.swift:Linux/Sources/SwiftlyLinux/Bildfarbe.swift"
  "Technikschild:Sources/Shared/BrowseViews.swift:-:Sources/macOS/DetailView.swift:Linux/Sources/SwiftlyLinux/Technikschild.swift"
)

filter="${1:-}"

# Kuerzel, Alter, Zeitstempel — der Zeitstempel entscheidet, wer die juengste
# Fassung hat.
zeitstempel() {
  local pfad="$1"
  { [ "$pfad" = "-" ] || [ ! -f "$pfad" ]; } && { echo 0; return; }
  git log -1 --format=%ct -- "$pfad" 2>/dev/null || echo 0
}

text() {
  local pfad="$1"
  [ "$pfad" = "-" ] && { echo "-"; return; }
  [ ! -f "$pfad" ] && { echo "FEHLT"; return; }
  local kurz alter
  kurz=$(git log -1 --format=%h -- "$pfad" 2>/dev/null)
  [ -z "$kurz" ] && { echo "nicht eingecheckt"; return; }
  alter=$(git log -1 --format=%cr -- "$pfad" 2>/dev/null | sed 's/ ago//; s/minutes/min/; s/hours/h/; s/days/T/; s/weeks/W/')
  echo "$kurz $alter"
}

printf '%-15s%-21s%-21s%-21s%-21s\n' "Ansicht" "iOS/iPad" "tvOS" "macOS" "Linux/Windows"
printf '%s\n' "--------------------------------------------------------------------------------------------"

fehlend=0
for zeile in "${ZUORDNUNG[@]}"; do
  IFS=':' read -r name ios tv mac linux <<< "$zeile"
  [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue

  t1=$(zeitstempel "$ios"); t2=$(zeitstempel "$tv")
  t3=$(zeitstempel "$mac"); t4=$(zeitstempel "$linux")
  hoechst=$t1
  for t in $t2 $t3 $t4; do [ "$t" -gt "$hoechst" ] && hoechst=$t; done

  printf '%-15s' "$name"
  for paar in "$ios:$t1" "$tv:$t2" "$mac:$t3" "$linux:$t4"; do
    pfad="${paar%:*}"; t="${paar##*:}"
    [ "$pfad" != "-" ] && [ ! -f "$pfad" ] && fehlend=1
    marke=" "
    # Die juengste Fassung bekommt den Stern — sie ist die Vorlage, und wer
    # eine andere Spalte anfasst, arbeitet gegen einen aelteren Stand.
    [ "$t" != 0 ] && [ "$t" = "$hoechst" ] && marke="*"
    printf '%s%-20s' "$marke" "$(text "$pfad")"
  done
  printf '\n'
done

printf '\n%s\n' "* = juengste Fassung dieser Ansicht. Wer eine andere Spalte uebernimmt,"
printf '%s\n'   "  arbeitet gegen einen aelteren Stand — dann erst dort nachlesen."

if [ "$fehlend" = 1 ]; then
  printf '\n%s\n' "FEHLT heisst: die Zuordnung in diesem Skript zeigt auf eine Datei, die es"
  printf '%s\n'   "nicht mehr gibt — umbenannt oder verschoben. Bitte hier nachziehen."
fi
