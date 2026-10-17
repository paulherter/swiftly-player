#!/bin/bash
#
# Anyone porting a view from one platform to another needs to know whether
# the source is newer than what they are touching. This script says so --
# one line per view, per platform the last commit that touched its file.
#
#   Werkzeuge/counterparts.sh              all views
#   Werkzeuge/counterparts.sh Serien       only rows containing "Serien"
#
# **Derived, not maintained.** The state comes from `git log`, not from a
# table somebody would have to keep up to date -- such a table decays as fast
# as a change list, which says *that* something is fixed, not *how*.
#
# Only the mapping below is maintained, and it is small and stable. It has to
# exist because matching by name alone would hit four of six platforms and
# miss exactly the two that matter: Linux and Windows share one source, where
# `SeriesView` is called `Serienseite`. If a file disappears or is renamed,
# the script reports it as `fehlt`, so the mapping cannot go stale silently.
#
# **A missing file is the strongest finding there can be.** It is therefore
# not skipped but listed separately at the end. Example: Linux had no library
# page at all, a click only switched the movies section -- and nobody asked
# why the column was empty.
#
# `?` means "does not exist there" -- and is reported below.
# `-` means "does not exist there, checked". Text after the dash is the
# reason; it appears under the table instead of in the column.
#
# Pointing at `App.swift` would have been wrong here even though the
# watchlist lives there: on Linux that file is 2900 lines and constantly
# changing, so the star would always sit there. A sentence that is written
# once is better than a line that claims something different every day.
#
# A `~` before the name means **rough**: the row compares files that do not
# cover the same ground. `App.swift` on Linux carries four Apple files at
# once and is constantly changing; a date comparison there almost always
# says "newer" without meaning anything.
#
# The iOS column often points to `Sources/Shared`: the iPhone and iPad views
# live there because they are shared.
#
# **What it does not say, and this matters:** the star means "this file was
# touched last", not "this behaviour is the newer one". A file can be newer
# because of a comment. And where several views share one file -- on Linux
# Home, Library and Search all live in `Region.swift` -- touching one of
# them marks all three rows. The script says **where to look**, not what is
# there.

set -u
cd "$(dirname "$0")/.." || exit 1

# View : iOS/iPad : tvOS : macOS : Linux+Windows : Android : Android TV
# Android TV lives in the same app module (`.../tv/`); where it has no page of
# its own, the column points to the phone page that runs there.
MAPPING=(
  "Start:Sources/Shared/HomeView.swift:Sources/tvOS/HomeView.swift:Sources/macOS/HomeView.swift:Linux/Sources/SwiftlyLinux/App.swift:Android/phone/src/main/java/de/paulherter/swiftly/StartPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStart.kt"
  "Detailseite:Sources/Shared/BrowseViews.swift:Sources/tvOS/DetailView.swift:Sources/macOS/DetailView.swift:Linux/Sources/SwiftlyLinux/DetailPage.swift:Android/phone/src/main/java/de/paulherter/swiftly/TitlePage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPages.kt"
  "Serienseite:Sources/Shared/SeriesView.swift:Sources/tvOS/SeriesView.swift:Sources/macOS/SeriesView.swift:Linux/Sources/SwiftlyLinux/SeriesPage.swift:Android/phone/src/main/java/de/paulherter/swiftly/SeriesPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvSeries.kt"
  # On Linux it lives in `App.swift` -- `Bereich.bibliothek` with
  # `offeneBibliothek`, `bibliotheksrubrik` and `rasterseiteBauen(.bibliothek)`.
  # A `?` here reported "KEINE" as for a missing view, which misled a
  # comparison: the page exists, the finding said the opposite.
  "Bibliotheksseite:Sources/Shared/BrowseViews.swift:Sources/tvOS/LibraryView.swift:Sources/macOS/Bibliotheksseite.swift:Linux/Sources/SwiftlyLinux/App.swift:Android/phone/src/main/java/de/paulherter/swiftly/LibraryPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPages.kt"
  "Bibliotheksliste:Sources/Shared/BrowseViews.swift:Sources/tvOS/LibraryView.swift:Sources/macOS/LibraryView.swift:Linux/Sources/SwiftlyLinux/App.swift:Android/phone/src/main/java/de/paulherter/swiftly/LibraryPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPages.kt"
  "Player:Sources/iOS/PlayerScreen.swift:Sources/tvOS/PlayerScreen.swift:Sources/macOS/PlayerScreen.swift:Linux/Sources/SwiftlyLinux/PlayerPage.swift:Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt"
  "VLC-Anbindung:Sources/Shared/VLCPlayer.swift:Sources/Shared/VLCPlayer.swift:Sources/Shared/VLCPlayer.swift:Linux/Sources/SwiftlyLinux/Player.swift:Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt"
  "Profil:Sources/Shared/ProfileView.swift:Sources/tvOS/ProfileView.swift:Sources/macOS/ProfileView.swift:Linux/Sources/SwiftlyLinux/SettingsPages.swift:Android/phone/src/main/java/de/paulherter/swiftly/ProfilePage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvProfile.kt"
  "Einstellungen:Sources/Shared/SettingsView.swift:Sources/tvOS/ProfileView.swift:Sources/macOS/SettingsView.swift:Linux/Sources/SwiftlyLinux/SettingsPages.swift:Android/phone/src/main/java/de/paulherter/swiftly/ProfilePage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvProfile.kt"
  "Wiedergabe:Sources/Shared/PlaybackSettingsView.swift:Sources/tvOS/ProfileView.swift:Sources/macOS/PlaybackSettingsView.swift:Linux/Sources/SwiftlyLinux/SettingsPages.swift:Android/phone/src/main/java/de/paulherter/swiftly/ProfilePage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvProfile.kt"
  "Suche:Sources/Shared/SearchView.swift:Sources/tvOS/SearchView.swift:Sources/macOS/SearchView.swift:Linux/Sources/SwiftlyLinux/App.swift:Android/phone/src/main/java/de/paulherter/swiftly/SearchPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPages.kt"
  "Merkliste:Sources/Shared/WatchlistView.swift:Sources/tvOS/WatchlistView.swift:Sources/macOS/WatchlistView.swift:-kein eigenes Gegenstueck, liegt als Bereich-Fall in App.swift (E21):Android/phone/src/main/java/de/paulherter/swiftly/WatchlistPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPages.kt"
  "Downloads:Sources/Shared/DownloadsView.swift:-:Sources/macOS/MacDownloads.swift:Linux/Sources/SwiftlyLinux/DownloadsPage.swift:Android/phone/src/main/java/de/paulherter/swiftly/DownloadsPage.kt:-keine Downloads auf dem Fernseher, wie tvOS"
  "Downloadverwaltung:Sources/Shared/DownloadManager.swift:-:Sources/Shared/DownloadManager.swift:Linux/Sources/SwiftlyLinux/DownloadManager.swift:Android/phone/src/main/java/de/paulherter/swiftly/Downloads.kt:-keine Downloads auf dem Fernseher, wie tvOS"
  "Seerr-Seite:Sources/Shared/SeerrDetailView.swift:Sources/tvOS/SeerrView.swift:Sources/macOS/SeerrTileAndPage.swift:Linux/Sources/SwiftlyLinux/SeerrPage.swift:Android/phone/src/main/java/de/paulherter/swiftly/SeerrPages.kt:Android/phone/src/main/java/de/paulherter/swiftly/SeerrPages.kt"
  "Seerr-Zugang:Sources/Shared/SeerrSettingsView.swift:-:Sources/macOS/SeerrSettingsView.swift:Linux/Sources/SwiftlyLinux/Seerr.swift:Android/phone/src/main/java/de/paulherter/swiftly/SeerrPages.kt:Android/phone/src/main/java/de/paulherter/swiftly/SeerrPages.kt"
  "~Rahmen:Sources/Shared/MainView.swift:Sources/tvOS/MainView.swift:Sources/macOS/MainView.swift:Linux/Sources/SwiftlyLinux/App.swift:Android/phone/src/main/java/de/paulherter/swiftly/MainView.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvMain.kt"
  "Bereiche:Sources/Shared/MainView.swift:Sources/tvOS/MainView.swift:Sources/macOS/MainView.swift:Linux/Sources/SwiftlyLinux/Region.swift:Android/phone/src/main/java/de/paulherter/swiftly/MainView.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvMain.kt"
  "Stil:Sources/Shared/Style.swift:Sources/tvOS/Style.swift:Sources/macOS/Style.swift:Linux/Sources/SwiftlyLinux/Style.swift:Android/shared/src/main/java/de/paulherter/swiftly/shared/Style.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt"
  "Bausteine:Sources/Shared/Components.swift:Sources/tvOS/TVComponents.swift:Sources/macOS/MacComponents.swift:Linux/Sources/SwiftlyLinux/Components.swift:Android/phone/src/main/java/de/paulherter/swiftly/PageComponents.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt"
  "Bildlader:Sources/Shared/NetworkImage.swift:Sources/Shared/NetworkImage.swift:Sources/Shared/NetworkImage.swift:Linux/Sources/SwiftlyLinux/Images.swift:-Coil, kein eigener Code:-Coil, kein eigener Code"
  "Bildfarbe:-:-:Sources/macOS/ImageColor.swift:Linux/Sources/SwiftlyLinux/ImageColor.swift:-:-"
  "Technikschild:Sources/Shared/TechBadge.swift:-:Sources/macOS/DetailView.swift:Linux/Sources/SwiftlyLinux/TechBadge.swift:Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt:Android/phone/src/main/java/de/paulherter/swiftly/PlayerPage.kt"
  "Schluesselbund:Sources/Shared/Keychain.swift:Sources/Shared/Keychain.swift:Sources/Shared/Keychain.swift:Linux/Sources/SwiftlyLinux/Cache.swift:Android/phone/src/main/java/de/paulherter/swiftly/SwiftlyApplication.kt:Android/phone/src/main/java/de/paulherter/swiftly/SwiftlyApplication.kt"
  "Medienleiste:Sources/Shared/PlaybackHub.swift:Sources/Shared/PlaybackHub.swift:Sources/Shared/PlaybackHub.swift:Linux/Sources/SwiftlyLinux/MediaBar.swift:Android/phone/src/main/java/de/paulherter/swiftly/PlaybackService.kt:Android/phone/src/main/java/de/paulherter/swiftly/PlaybackService.kt"
  "Fassung:Sources/Shared/Components.swift:Sources/Shared/Components.swift:Sources/Shared/Components.swift:Linux/Sources/SwiftlyLinux/Version.swift:Android/phone/src/main/java/de/paulherter/swiftly/SwiftlyApplication.kt:Android/phone/src/main/java/de/paulherter/swiftly/SwiftlyApplication.kt"
  "Startanimation:Sources/Shared/StartAnimation.swift:Sources/Shared/StartAnimation.swift:Sources/Shared/StartAnimation.swift:Linux/Sources/SwiftlyLinux/StartAnimation.swift:Android/phone/src/main/java/de/paulherter/swiftly/StartCurtain.kt:Android/phone/src/main/java/de/paulherter/swiftly/StartCurtain.kt"
  "Kulisse:Sources/Shared/HeroHeader.swift:Sources/tvOS/TitleRails.swift:Sources/macOS/Backdrop.swift:Linux/Sources/SwiftlyLinux/Backdrop.swift:Android/phone/src/main/java/de/paulherter/swiftly/TitlePage.kt:Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStart.kt"
)

filter="${1:-}"
PLATFORM=("iOS/iPad" "tvOS" "macOS" "Linux/Win" "Android" "Android TV")

timestamp() {
  local path="$1"
  case "$path" in -*|\?) echo 0; return;; esac
  [ ! -f "$path" ] && { echo 0; return; }
  git log -1 --format=%ct -- "$path" 2>/dev/null || echo 0
}

text() {
  local path="$1"
  case "$path" in -*) echo "keine (geprueft)"; return;; esac
  [ "$path" = "?" ] && { echo "KEINE"; return; }
  [ ! -f "$path" ] && { echo "PFAD FEHLT"; return; }
  local short old
  short=$(git log -1 --format=%h -- "$path" 2>/dev/null)
  [ -z "$short" ] && { echo "nicht eingecheckt"; return; }
  old=$(git log -1 --format=%cr -- "$path" 2>/dev/null \
          | sed 's/ ago//; s/minutes*/min/; s/hours*/h/; s/days*/T/; s/weeks*/W/; s/months*/M/')
  echo "$short $old"
}

printf '%-19s%-17s%-17s%-17s%-17s%-17s%-17s\n' "Ansicht" "iOS/iPad" "tvOS" "macOS" "Linux/Win" "Android" "Android TV"
printf '%s\n' "-------------------------------------------------------------------------------------------------------------------------"

without=()
checked=()
broken=0
for row in "${MAPPING[@]}"; do
  IFS=':' read -r name ios tv mac linux handy tv <<< "$row"
  coarse=0
  case "$name" in "~"*) coarse=1; name="${name#\~}";; esac
  [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue

  paths=("$ios" "$tv" "$mac" "$linux" "$handy" "$tv")
  max=0
  for p in "${paths[@]}"; do
    t=$(timestamp "$p"); [ "$t" -gt "$max" ] && max=$t
  done

  printf '%-19s' "$name$([ $coarse = 1 ] && echo ' ~')"
  for i in 0 1 2 3 4 5; do
    p="${paths[$i]}"
    t=$(timestamp "$p")
    [ "$p" = "?" ] && without+=("$name — ${PLATFORM[$i]}")
    case "$p" in
      -?*) checked+=("$name — ${PLATFORM[$i]}: ${p#-}") ;;
      -|\?) : ;;
      *) [ ! -f "$p" ] && broken=1 ;;
    esac
    mark=" "
    # The star only where the comparison means something: a rough row
    # compares files with different scope.
    [ "$coarse" = 0 ] && [ "$t" != 0 ] && [ "$t" = "$max" ] && mark="*"
    printf '%s%-16s' "$mark" "$(text "$p")"
  done
  printf '\n'
done

printf '\n%s\n' "* juengste Fassung. Wer eine andere Spalte uebernimmt, arbeitet gegen einen"
printf '%s\n'   "  aelteren Stand — dann erst dort nachlesen. ~ heisst grob: die Dateien"
printf '%s\n'   "  schneiden nicht dasselbe zu, das Datum sagt dort wenig."

if [ ${#without[@]} -gt 0 ]; then
  printf '\n%s\n' "OHNE GEGENSTUECK — der staerkste Befund, den es hier gibt:"
  for e in "${without[@]}"; do printf '  %s\n' "$e"; done
  printf '%s\n' "  Entweder fehlt die Ansicht dort wirklich, oder sie steckt in einer"
  printf '%s\n' "  fremden Datei und niemand weiss es. Am 08.09.2026 war es das erste:"
  printf '%s\n' "  auf Linux gab es keine Bibliotheksseite, ein Klick schaltete nur den"
  printf '%s\n' "  Filme-Bereich um. Ist es geprueft und Absicht, Bindestrich statt"
  printf '%s\n' "  Fragezeichen in die Zuordnung eintragen."
fi

if [ ${#checked[@]} -gt 0 ]; then
  printf '\n%s\n' "Ohne eigene Datei, aber geprueft:"
  for e in "${checked[@]}"; do printf '  %s\n' "$e"; done
fi

if [ "$broken" = 1 ]; then
  printf '\n%s\n' "PFAD FEHLT heisst: die Zuordnung zeigt auf eine Datei, die es nicht mehr"
  printf '%s\n'   "gibt — umbenannt oder verschoben. Hier im Skript nachziehen."
fi
