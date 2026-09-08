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
# **Eine fehlende Datei ist der staerkste Befund, den es hier geben kann.**
# Deshalb wird sie nicht uebersprungen, sondern unten eigens aufgefuehrt. Am
# 08.09.2026 war genau das der Fall, der einen Tag gekostet hat: auf Linux gab
# es die Bibliotheksseite gar nicht, ein Klick schaltete nur den Filme-Bereich
# um — und niemand hat gefragt, warum die Spalte leer ist.
#
# `?` heisst „gibt es dort nicht" — und das wird unten gemeldet.
# `-` heisst „gibt es dort nicht, geprueft". Steht hinter dem Bindestrich noch
# Text, ist das der Grund; er erscheint unter der Tabelle statt in der Spalte.
#
# Auf `App.swift` zu zeigen waere hier falsch gewesen, obwohl die Merkliste
# dort liegt: die Datei ist auf Linux 2900 Zeilen und staendig in Bewegung,
# der Stern staende immer dort. Ein Satz, der einmal dasteht, ist besser als
# eine Zeile, die jeden Tag etwas anderes behauptet.
#
# Ein `~` vor dem Namen heisst **grob**: die Zeile stellt Dateien
# gegenueber, die nicht dasselbe zuschneiden. `App.swift` auf Linux traegt
# vier Apple-Dateien auf einmal und ist dort staendig in Bewegung; ein
# Datumsvergleich sagt da fast immer „juenger", ohne dass es etwas bedeutet.
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
  "Start:Sources/Shared/HomeView.swift:Sources/tvOS/HomeView.swift:Sources/macOS/HomeView.swift:Linux/Sources/SwiftlyLinux/App.swift"
  "Detailseite:Sources/Shared/BrowseViews.swift:Sources/tvOS/DetailView.swift:Sources/macOS/DetailView.swift:Linux/Sources/SwiftlyLinux/Detailseite.swift"
  "Serienseite:Sources/Shared/SeriesView.swift:Sources/tvOS/SerienView.swift:Sources/macOS/SerienView.swift:Linux/Sources/SwiftlyLinux/Serienseite.swift"
  "Bibliotheksseite:Sources/Shared/BrowseViews.swift:Sources/tvOS/BibliothekView.swift:Sources/macOS/Bibliotheksseite.swift:?"
  "Bibliotheksliste:Sources/Shared/BrowseViews.swift:Sources/tvOS/BibliothekView.swift:Sources/macOS/BibliothekView.swift:Linux/Sources/SwiftlyLinux/App.swift"
  "Player:Sources/iOS/PlayerScreen.swift:Sources/tvOS/PlayerScreen.swift:Sources/macOS/PlayerScreen.swift:Linux/Sources/SwiftlyLinux/Spieler.swift"
  "VLC-Anbindung:Sources/Shared/VLCPlayer.swift:Sources/Shared/VLCPlayer.swift:Sources/Shared/VLCPlayer.swift:Linux/Sources/SwiftlyLinux/Abspieler.swift"
  "Profil:Sources/Shared/ProfilView.swift:Sources/tvOS/ProfilView.swift:Sources/macOS/ProfilView.swift:Linux/Sources/SwiftlyLinux/Einstellungsseiten.swift"
  "Einstellungen:Sources/Shared/EinstellungenView.swift:Sources/tvOS/ProfilView.swift:Sources/macOS/EinstellungenView.swift:Linux/Sources/SwiftlyLinux/Einstellungsseiten.swift"
  "Wiedergabe:Sources/Shared/WiedergabeEinstellungenView.swift:Sources/tvOS/ProfilView.swift:Sources/macOS/WiedergabeEinstellungenView.swift:Linux/Sources/SwiftlyLinux/Einstellungsseiten.swift"
  "Suche:Sources/Shared/SucheView.swift:Sources/tvOS/SucheView.swift:Sources/macOS/SucheView.swift:Linux/Sources/SwiftlyLinux/App.swift"
  "Merkliste:Sources/Shared/MerklisteView.swift:Sources/tvOS/MerklisteView.swift:Sources/macOS/MerklisteView.swift:-kein eigenes Gegenstueck, liegt als Bereich-Fall in App.swift (E21)"
  "Downloads:Sources/Shared/DownloadsView.swift:-:Sources/macOS/Macdownloads.swift:Linux/Sources/SwiftlyLinux/Downloadseite.swift"
  "Downloadverwaltung:Sources/Shared/Downloadverwaltung.swift:-:Sources/Shared/Downloadverwaltung.swift:Linux/Sources/SwiftlyLinux/Downloadverwaltung.swift"
  "Seerr-Seite:Sources/Shared/SeerrDetailView.swift:Sources/tvOS/SeerrView.swift:Sources/macOS/SeerrKachelUndSeite.swift:Linux/Sources/SwiftlyLinux/Seerrseite.swift"
  "Seerr-Zugang:Sources/Shared/SeerrEinstellungenView.swift:-:Sources/macOS/SeerrEinstellungenView.swift:Linux/Sources/SwiftlyLinux/Seerr.swift"
  "~Rahmen:Sources/Shared/HauptView.swift:Sources/tvOS/HauptView.swift:Sources/macOS/HauptView.swift:Linux/Sources/SwiftlyLinux/App.swift"
  "Bereiche:Sources/Shared/HauptView.swift:Sources/tvOS/HauptView.swift:Sources/macOS/HauptView.swift:Linux/Sources/SwiftlyLinux/Bereich.swift"
  "Stil:Sources/Shared/Stil.swift:Sources/tvOS/Stil.swift:Sources/macOS/Stil.swift:Linux/Sources/SwiftlyLinux/Stil.swift"
  "Bausteine:Sources/Shared/Bausteine.swift:Sources/tvOS/TVBausteine.swift:Sources/macOS/Macbausteine.swift:Linux/Sources/SwiftlyLinux/Bausteine.swift"
  "Bildlader:Sources/Shared/Netzbild.swift:Sources/Shared/Netzbild.swift:Sources/Shared/Netzbild.swift:Linux/Sources/SwiftlyLinux/Bilder.swift"
  "Bildfarbe:-:-:Sources/macOS/Bildfarbe.swift:Linux/Sources/SwiftlyLinux/Bildfarbe.swift"
  "Technikschild:Sources/Shared/Technikschild.swift:-:Sources/macOS/DetailView.swift:Linux/Sources/SwiftlyLinux/Technikschild.swift"
  "Schluesselbund:Sources/Shared/Keychain.swift:Sources/Shared/Keychain.swift:Sources/Shared/Keychain.swift:Linux/Sources/SwiftlyLinux/Speicher.swift"
  "Medienleiste:Sources/Shared/Wiedergabezentrale.swift:Sources/Shared/Wiedergabezentrale.swift:Sources/Shared/Wiedergabezentrale.swift:Linux/Sources/SwiftlyLinux/Medienleiste.swift"
  "Fassung:Sources/Shared/Bausteine.swift:Sources/Shared/Bausteine.swift:Sources/Shared/Bausteine.swift:Linux/Sources/SwiftlyLinux/Fassung.swift"
  "Startanimation:Sources/Shared/Startanimation.swift:Sources/Shared/Startanimation.swift:Sources/Shared/Startanimation.swift:Linux/Sources/SwiftlyLinux/Startanimation.swift"
  "Kulisse:Sources/Shared/Heldkopf.swift:Sources/tvOS/Titelreihen.swift:Sources/macOS/Kulisse.swift:Linux/Sources/SwiftlyLinux/Kulisse.swift"
)

filter="${1:-}"
PLATTFORMEN=("iOS/iPad" "tvOS" "macOS" "Linux/Win")

zeitstempel() {
  local pfad="$1"
  case "$pfad" in -*|\?) echo 0; return;; esac
  [ ! -f "$pfad" ] && { echo 0; return; }
  git log -1 --format=%ct -- "$pfad" 2>/dev/null || echo 0
}

text() {
  local pfad="$1"
  case "$pfad" in -*) echo "keine (geprueft)"; return;; esac
  [ "$pfad" = "?" ] && { echo "KEINE"; return; }
  [ ! -f "$pfad" ] && { echo "PFAD FEHLT"; return; }
  local kurz alter
  kurz=$(git log -1 --format=%h -- "$pfad" 2>/dev/null)
  [ -z "$kurz" ] && { echo "nicht eingecheckt"; return; }
  alter=$(git log -1 --format=%cr -- "$pfad" 2>/dev/null \
          | sed 's/ ago//; s/minutes*/min/; s/hours*/h/; s/days*/T/; s/weeks*/W/; s/months*/M/')
  echo "$kurz $alter"
}

printf '%-19s%-21s%-21s%-21s%-21s\n' "Ansicht" "iOS/iPad" "tvOS" "macOS" "Linux/Win"
printf '%s\n' "------------------------------------------------------------------------------------------------"

ohne=()
geprueft=()
kaputt=0
for zeile in "${ZUORDNUNG[@]}"; do
  IFS=':' read -r name ios tv mac linux <<< "$zeile"
  grob=0
  case "$name" in "~"*) grob=1; name="${name#\~}";; esac
  [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue

  pfade=("$ios" "$tv" "$mac" "$linux")
  hoechst=0
  for p in "${pfade[@]}"; do
    t=$(zeitstempel "$p"); [ "$t" -gt "$hoechst" ] && hoechst=$t
  done

  printf '%-19s' "$name$([ $grob = 1 ] && echo ' ~')"
  for i in 0 1 2 3; do
    p="${pfade[$i]}"
    t=$(zeitstempel "$p")
    [ "$p" = "?" ] && ohne+=("$name — ${PLATTFORMEN[$i]}")
    case "$p" in
      -?*) geprueft+=("$name — ${PLATTFORMEN[$i]}: ${p#-}") ;;
      -|\?) : ;;
      *) [ ! -f "$p" ] && kaputt=1 ;;
    esac
    marke=" "
    # Der Stern nur, wo der Vergleich etwas bedeutet: eine grobe Zeile
    # vergleicht Dateien mit verschiedenem Zuschnitt.
    [ "$grob" = 0 ] && [ "$t" != 0 ] && [ "$t" = "$hoechst" ] && marke="*"
    printf '%s%-20s' "$marke" "$(text "$p")"
  done
  printf '\n'
done

printf '\n%s\n' "* juengste Fassung. Wer eine andere Spalte uebernimmt, arbeitet gegen einen"
printf '%s\n'   "  aelteren Stand — dann erst dort nachlesen. ~ heisst grob: die Dateien"
printf '%s\n'   "  schneiden nicht dasselbe zu, das Datum sagt dort wenig."

if [ ${#ohne[@]} -gt 0 ]; then
  printf '\n%s\n' "OHNE GEGENSTUECK — der staerkste Befund, den es hier gibt:"
  for e in "${ohne[@]}"; do printf '  %s\n' "$e"; done
  printf '%s\n' "  Entweder fehlt die Ansicht dort wirklich, oder sie steckt in einer"
  printf '%s\n' "  fremden Datei und niemand weiss es. Am 08.09.2026 war es das erste:"
  printf '%s\n' "  auf Linux gab es keine Bibliotheksseite, ein Klick schaltete nur den"
  printf '%s\n' "  Filme-Bereich um. Ist es geprueft und Absicht, Bindestrich statt"
  printf '%s\n' "  Fragezeichen in die Zuordnung eintragen."
fi

if [ ${#geprueft[@]} -gt 0 ]; then
  printf '\n%s\n' "Ohne eigene Datei, aber geprueft:"
  for e in "${geprueft[@]}"; do printf '  %s\n' "$e"; done
fi

if [ "$kaputt" = 1 ]; then
  printf '\n%s\n' "PFAD FEHLT heisst: die Zuordnung zeigt auf eine Datei, die es nicht mehr"
  printf '%s\n'   "gibt — umbenannt oder verschoben. Hier im Skript nachziehen."
fi
