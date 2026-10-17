#!/bin/bash
# One command instead of five: package tests, all Apple targets, and the
# question whether any work is lying around somewhere.
#
# **Why the branch check belongs here.** Once a platform branch carried
# several commits that never reached main, including two fixes for reported
# bugs, and a test build went out without them. No build and no test would have
# shown it: both check what is there, not what is missing.
#
#   Werkzeuge/check.sh          everything
#   Werkzeuge/check.sh schnell  only tests and branches, no simulator build
#
# Exit code 0 means: everything green and nothing left behind.

set -u
cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

fast=false
[ "${1:-}" = "schnell" ] && fast=true
error=0
green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; reset=$'\033[0m'

report() { printf '%-34s %s\n' "$1" "$2"; }

echo "── Pakettests ─────────────────────────────────────────"
if output=$(cd Packages/JellyfinKit && xcrun swift test 2>&1); then
    report "JellyfinKit" "${green}$(echo "$output" | grep -oE 'Test run with [0-9]+ tests' | tail -1)${reset}"
    # SwiftPM drops linker flags silently and says so in exactly one line among
    # two hundred others. On Linux the app then only failed when started
    # through its build script, aborting at librlottie.so with a message that
    # looked like a broken build.
    if discarded=$(echo "$output" | grep -i "prohibited flag" | head -3) && [ -n "$discarded" ]; then
        report "Verworfene Flaggen" "${red}SwiftPM hat etwas weggeworfen${reset}"
        echo "$discarded" | sed 's/^/      /'
        error=1
    fi
else
    report "JellyfinKit" "${red}FEHLGESCHLAGEN${reset}"
    echo "$output" | grep -E "error:|failed" | head -10
    error=1
fi

if [ "$fast" = false ]; then
    echo
    echo "── Apple-Ziele ────────────────────────────────────────"
    # A single target's own build only checks its own half: many lines in
    # project.yml appear verbatim in several target blocks, and a search and
    # replace hits all of them. Hence always all three.
    xcodegen generate >/dev/null 2>&1
    # The log goes completely into a file and only through xcbeautify to the
    # screen. Otherwise a failure would show only the word FEHLGESCHLAGEN and
    # the build would have to be repeated by hand to see why. This way the
    # error lines appear right below.
    log=$(mktemp -t pruefen)
    for target in Swiftly-iOS:"generic/platform=iOS Simulator" \
                Swiftly-tvOS:"generic/platform=tvOS Simulator" \
                Swiftly-macOS:"platform=macOS"; do
        name=${target%%:*}; destination=${target#*:}
        xcodebuild -project Swiftly.xcodeproj -scheme "$name" \
            -destination "$destination" build >"$log" 2>&1
        if grep -q "BUILD SUCCEEDED" "$log"; then
            warnungen=$(xcbeautify --disable-logging <"$log" 2>/dev/null | grep -c "warning:")
            if [ "$warnungen" -gt 0 ]; then
                report "$name" "${green}gebaut${reset} (${yellow}$warnungen Warnungen${reset})"
            else
                report "$name" "${green}gebaut${reset}"
            fi
        else
            report "$name" "${red}FEHLGESCHLAGEN${reset}"
            xcbeautify --disable-logging <"$log" 2>/dev/null \
                | grep -E "error:|Undefined symbol|Multiple commands" | head -12 | sed 's/^/      /'
            echo "      ganzes Protokoll: $log"
            error=1
            log=$(mktemp -t pruefen)   # do not overwrite, the next target needs its own
        fi
    done
fi

echo
echo "── Liegt noch etwas auf einem Zweig? ──────────────────"
# Remote branches too. linux and windows exist ONLY there; a loop over local
# branches alone would skip both silently -- exactly the two platforms that
# lag furthest behind.
for branch in ios ipad mac tvos linux windows; do
    # Full ref names, otherwise a bare "linux" resolves to the HEAD of the
    # remote of the same name instead of the branch linux/linux -- and reports
    # the numbers of a completely different branch as green.
    ref=""
    for candidate in "refs/heads/$branch" "refs/remotes/linux/$branch" "refs/remotes/origin/$branch"; do
        git rev-parse --verify -q "$candidate" >/dev/null 2>&1 && { ref="$candidate"; break; }
    done
    [ -n "$ref" ] || continue
    # Without a common root, "ahead" and "behind" are meaningless: a repo that
    # was freshly created instead of cloned reports hundreds of commits "not in
    # main" that are not a backlog but a second history of the same code.
    # Compare content, do not count commits.
    if ! git merge-base "$ref" main >/dev/null 2>&1; then
        different=$(git diff --name-only main "$ref" | wc -l | tr -d ' ')
        report "${ref#refs/*/}" "${yellow}eigene Wurzel${reset} — $different Dateien anders, git diff statt Zaehlung"
        continue
    fi
    own=$(git rev-list --count "main..$ref")
    behind=$(git rev-list --count "$ref..main")
    if [ "$own" -gt 0 ]; then
        report "${ref#refs/*/}" "${yellow}$own Commits nicht in main${reset} ($behind hinterher)"
        git log --oneline "main..$ref" | head -10 | sed 's/^/      /'
        error=1
    else
        report "${ref#refs/*/}" "${green}nichts offen${reset} ($behind hinterher)"
    fi
done

echo
echo "── Verdrahtung ────────────────────────────────────────"
# Skills and agents are linked into ~/.claude, and a link pointing at a path
# with a literal backslash breaks silently. No build or test notices: the
# session keeps running, only without that knowledge. Hence here.
# The private links in the repository root are optional: a clone without them
# passes; only a link that exists and points nowhere counts as an error.
tot=0
for l in CLAUDE.md VERHALTEN.md GESTALTUNG.md Erfahrungen.md Fallen; do
    [ -L "$l" ] && [ ! -e "$l" ] && { report "$l" "${red}zeigt ins Leere${reset}"; tot=$((tot+1)); }
done
for l in ~/.claude/skills/* ~/.claude/agents/*; do
    [ -L "$l" ] && [ ! -e "$l" ] && { report "$(basename "$l")" "${red}zeigt ins Leere${reset}"; tot=$((tot+1)); }
done
if [ "$tot" -eq 0 ]; then
    report "Symlinks" "${green}alle loesen auf${reset}"
else
    report "Symlinks" "${red}$tot tot${reset}"
    error=1
fi

echo
echo "── Katalog ────────────────────────────────────────────"
python3 "$(dirname "$0")/catalog-check.py" || error=1
echo

# **The license list has one source** (`LICENSES/components.json`); the readable
# version is generated from it. If it goes stale, the file says something
# different from the app.
echo "── Lizenzen ───────────────────────────────────────────"
python3 "$(dirname "$0")/licenses-generate.py" --pruefen || error=1
echo

# **Android reads the same catalog** (`Texts.kt` pulls in the `.xcstrings` at
# build time). A key missing there shows as German text on an English device --
# no build fails because of it. Hence here, instead of only on the device.
echo "── Android-Texte ──────────────────────────────────────"
if [ -d Android/phone ]; then
    absent=$(grep -rhoE 'uebersetzt\("[^"]+"' Android/phone/src/main/java Android/shared/src/main/java 2>/dev/null \
        | sed 's/uebersetzt("//; s/"$//' | sort -u \
        | while IFS= read -r k; do
            # Kotlin writes %d/%s, the catalog %lld/%@ -- texts-to-android.py
            # converts that when generating. Both spellings count.
            swift=$(printf '%s' "$k" | sed -E 's/%([0-9]+\$)?d/%\1lld/g; s/%([0-9]+\$)?s/%\1@/g')
            grep -qF "\"$k\"" Sources/Shared/Localizable.xcstrings \
                || grep -qF "\"$swift\"" Sources/Shared/Localizable.xcstrings \
                || printf '%s\n' "$k"
        done)
    if [ -z "$absent" ]; then
        report "Android-Schluessel im Katalog" "${green}alle da${reset}"
    else
        report "Android-Schluessel im Katalog" "${red}$(printf '%s\n' "$absent" | wc -l | tr -d ' ') fehlen${reset}"
        printf '%s\n' "$absent" | sed 's/^/    /'
        error=1
    fi
else
    report "Android" "${yellow}kein Ordner${reset}"
fi
echo

echo "── Offene Spalten in der Aenderungsliste ──────────────"
# Optional: only checked when the change list exists next to the repository.
list="${SWIFTLY_AENDERUNGSLISTE:-../Notizen/AppStore/Aenderungen.md}"
if [ -f "$list" ]; then
    opened=$(grep -cE '^\| [0-9]+ \|.*\| · \|' "$list" 2>/dev/null || echo 0)
    report "Zeilen mit einem ·" "$opened"
fi

echo
if [ "$error" -eq 0 ]; then
    echo "${green}Alles gruen, nichts liegengeblieben.${reset}"
else
    echo "${red}Es gibt etwas zu tun — siehe oben.${reset}"
fi
exit $error
