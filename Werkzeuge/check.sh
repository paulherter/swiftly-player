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

# One picture view for every Apple platform: `Picture` and `BlurFill` live in `Sources/Shared/Picture.swift` only
# (tvOS used to carry its own copy of `Picture`, so its detail pages never got the tile picture or the BlurHash).
if copies=$(git grep -n -E "^(struct|final class|class) (Picture|BlurFill)\b" -- 'Sources/*.swift' ':!Sources/Shared/Picture.swift' 2>/dev/null | head -3) && [ -n "$copies" ]; then
    report "Eine Picture-Ansicht" "${red}KOPIE GEFUNDEN${reset}"; echo "$copies" | cut -c1-120 | sed 's/^/      /'; error=1
fi

# Every TV text field is `TvField` (TvStyle.kt): it keeps the system keyboard closed until OK and lets the arrows leave the
# field. A raw `BasicTextField` on a TV page opens the keyboard on focus, which then takes every D-pad key, so the remote
# could not leave the field (address / e-mail / password). Only `TvField` itself and the PIN field (`TvPlexSignIn.kt`, whose
# page is nothing but the keyboard) may use it.
if rawFields=$(git grep -n "BasicTextField(" -- 'Android/phone/src/main/java/de/paulherter/swiftly/tv/*.kt' ':!Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt' ':!Android/phone/src/main/java/de/paulherter/swiftly/tv/TvPlexSignIn.kt' 2>/dev/null | head -3) && [ -n "$rawFields" ]; then
    report "TV-Textfeld nur ueber TvField" "${red}BasicTextField GEFUNDEN${reset}"; echo "$rawFields" | cut -c1-140 | sed 's/^/      /'; error=1
fi

# **No focus ring on tvOS** (Paul, 17.11.): focus is lift + growth + the picture brightening (`View.pictureFocus`, TVComponents.swift),
# never an outline that appears with focus. A stroke within six lines of `if focus` / `focus ? 1` / `on ? 1 : 0` is such a ring.
if rings=$(python3 -I - <<'PY'
import glob, re
hit = re.compile(r"if\s+(focus|isFocused)\b|\b(focus|isFocused|on)\s*\?\s*1\s*:\s*0")
for f in sorted(glob.glob("Sources/tvOS/*.swift")):
    if f.endswith(("PlayerLayers.swift", "PlayerScreen.swift")): continue
    lines = open(f).read().splitlines()
    for i, l in enumerate(lines):
        if re.search(r"\.strokeBorder\(|\.stroke\(|\.border\(", l) and any(hit.search(x) for x in lines[max(0, i - 6):i + 7]):
            print(f"{f}:{i + 1}: {l.strip()[:90]}")
PY
) && [ -n "$rings" ]; then
    report "tvOS ohne Fokusrand" "${red}FOKUS-RING GEFUNDEN${reset}"; echo "$rings" | sed 's/^/      /' | head -8; error=1
else
    report "tvOS ohne Fokusrand" "${green}ok${reset}"
fi

# The live harness' panel notification (`LiveRun.openLayer`: the chapters/menu scenarios) must be observed by every phone/TV player; tvOS did not
# observe it and the chapter-list proof silently showed no list.
for player in Sources/iOS/PlayerScreen.swift Sources/tvOS/PlayerScreen.swift; do
    if ! grep -q "LiveRun.openLayer" "$player"; then
        report "Live-Hook openLayer" "${red}fehlt in $player${reset}"; error=1
    fi
done

# The repository is public: nothing that issues supporter keys or talks to the
# shop may ever land in it (public verification key only).
if leaked=$(git grep -n -I -E "sk_live|rk_live|whsec_|BEGIN ([A-Z]+ )?PRIVATE KEY|KASSE_SS2_SEED" -- . ':!Werkzeuge/check.sh' 2>/dev/null | head -3) && [ -n "$leaked" ]; then
    report "Geheimnisse im Repo" "${red}GEFUNDEN${reset}"; echo "$leaked" | cut -c1-120 | sed 's/^/      /'; error=1
fi
# One source for the TV measures: the generated Swift and Kotlin files must match
# Werkzeuge/tv-spec.json, and the guarded views may not repeat its numbers.
if tvspec=$(Werkzeuge/gen-tv-spec.sh --check 2>&1); then
    report "TV-Maße" "${green}ok${reset}"
else
    report "TV-Maße" "${red}weichen ab${reset}"; echo "$tvspec" | head -8 | sed 's/^/      /'; error=1
fi
# A closure kept inside a generic lock is re-wrapped in two reabstraction thunks on every `withLock`, so the call
# chain grows by two frames per call and the main stack overflows after a few thousand calls (the build 48 crash,
# `PlayerEngineDriver`). Keep closures in a main-actor class property, or in a final class that holds them.
# Caught: the closure type in the generics (also over several lines) and a typealias of a closure type.
if closures=$(git ls-files -z '*.swift' | xargs -0 perl Werkzeuge/lock-closures.pl 2>&1 | head -3) && [ -n "$closures" ]; then
    report "Closure im generischen Lock" "${red}GEFUNDEN${reset}"; echo "$closures" | cut -c1-140 | sed 's/^/      /'; error=1
fi
# A closed player reports nothing more: a tick loop that runs one more tick after `VLCPlayerView.stop()` found no core
# and sent a Start for the closed title. Each of the three screens' tick loops must end on `finallyStopped`, and the final
# stop must tell the core first (`close()` before the engine goes).
closeGuard=""
for screen in Sources/iOS/PlayerScreen.swift Sources/macOS/PlayerScreen.swift Sources/tvOS/PlayerScreen.swift; do
    grep -qE "guard !(surface|area)\.finallyStopped else \{ break \}" "$screen" || closeGuard="$closeGuard $screen"
done
grep -q "as? CorePlaybackBackend)?.close()" Sources/Shared/VLCPlayer.swift || closeGuard="$closeGuard Sources/Shared/VLCPlayer.swift"
if [ -n "$closeGuard" ]; then
    report "Start nach Stopp" "${red}Schutz fehlt:$closeGuard${reset}"; error=1
fi
# **No UUID- or random-named `UserDefaults` suites in tests** (21.11.): every suite a test writes becomes a persistent domain file in
# ~/Library/Preferences with a directory handle held by `cfprefsd`. 531 UUID-named domains from repeated runs pushed `cfprefsd` past its
# file-handle limit ("Too many open files"), and then every app on the Mac stopped reading its settings. A test gets its suite only from
# `TestDefaults.make(for: Self.self)` (TestDefaults.swift in the test target: one fixed, wiped name per test class), so a test file may not
# call `UserDefaults(suiteName:)` itself; the helper may not build a name from a UUID or a random number.
if suites=$( (git ls-files -z --cached --others --exclude-standard -- 'Packages/*/Tests/*.swift' 'Tests/*.swift' 'LiveTests/*.swift' 'LiveTests-tvOS/*.swift') | python3 -I -c '
import re, sys
risk = re.compile(r"UUID|random|Date\(\)|CFAbsoluteTime|timeIntervalSince")
call = re.compile(r"UserDefaults(?:\.init)?\s*\(\s*suiteName:\s*([^\n]*)")
for path in sys.stdin.read().split("\0"):
    if not path: continue
    helper = path.endswith("/TestDefaults.swift")
    text = open(path, encoding="utf-8", errors="replace").read()
    if helper:
        for i, l in enumerate(text.splitlines(), 1):
            if not l.lstrip().startswith("//") and risk.search(l):
                print(f"{path}:{i}: the helper must not build a suite name from a UUID, a random number or the time")
    for m in call.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        if not helper:
            print(f"{path}:{line}: UserDefaults(suiteName:) in a test: use TestDefaults.make(for: Self.self) (one fixed, wiped name per test class)")
            continue
        arg = m.group(1)
        ident = re.match(r"\s*([A-Za-z_]\w*)\s*\)", arg)
        traced = [l for l in text.splitlines() if ident and re.search(r"\b(?:let|var)\s+" + ident.group(1) + r"\b", l)]
        if risk.search(arg) or any(risk.search(l) for l in traced):
            print(f"{path}:{line}: the suite name must be fixed, not a UUID or random")
' 2>&1 | head -8) && [ -n "$suites" ]; then
    report "Tests: feste Defaults-Namen" "${red}UUID-/Zufallsname oder eigener Suite-Aufruf${reset}"; echo "$suites" | sed 's/^/      /'; error=1
else
    report "Tests: feste Defaults-Namen" "${green}ok${reset}"
fi

echo "── Pakettests ─────────────────────────────────────────"
# GitHub builds the package on Linux, where Apple-only modules do not exist.
# An unguarded import there failed the public check once (StoreKitTest).
for apple in $(grep -rlE "^import (StoreKit|StoreKitTest|UIKit|AppKit|SwiftUI|AVKit)$" Packages/JellyfinKit/Sources Packages/JellyfinKit/Tests 2>/dev/null); do
    head -1 "$apple" | grep -q "^#if" || { report "Linux-Import" "${red}ungeschützt: $apple${reset}"; error=1; }
done
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

# The committed Swift bindings (`Generated.swift`) must equal a fresh generation from the Rust exports. A merge once
# left the regenerated file out: the Rust side had `SeerrEpisodeInfo`, the shared Swift views used it, and the tip did
# not compile for Apple while every Rust gate was green. (The Kotlin bindings are not committed; Android generates them
# at build time. `Tokens.swift` has its own `gen_tokens --check`, the TV measures their check above.)
if bindings=$(CARGO_BUILD_JOBS=6 cargo run -q -p xtask -- apple --check-bindings 2>&1); then
    report "Swift-Bindings" "${green}aktuell${reset}"
else
    report "Swift-Bindings" "${red}VERALTET${reset}"; echo "$bindings" | grep -E "stale|error" | head -3 | cut -c1-200 | sed 's/^/      /'; error=1
fi
# The core's Swift tests read the records generated from `crates/swiftly-uniffi` (`Generated.swift`). A record change
# (`PlayButton.enabled` became `ready: PlayReadiness`) leaves them uncompilable, and no Rust gate builds Swift, so the
# SwiftlyCore test target sat broken for a day. Compile and run it here: the macOS slice of the framework is enough.
[ -d Packages/SwiftlyCore/SwiftlyCoreFFI.xcframework ] || Werkzeuge/rust-kern.sh --framework >/dev/null 2>&1
if output=$(cd Packages/SwiftlyCore && xcrun swift test 2>&1); then
    report "SwiftlyCore" "${green}$(echo "$output" | grep -oE 'Test run with [0-9]+ tests' | tail -1)${reset}"
else
    report "SwiftlyCore" "${red}FEHLGESCHLAGEN${reset}"
    echo "$output" | grep -E "error:|recorded an issue" | sort -u | head -10 | cut -c1-200
    error=1
fi

if [ "$fast" = false ]; then
    echo
    echo "── Apple-Ziele ────────────────────────────────────────"
    # A single target's own build only checks its own half: many lines in
    # project.yml appear verbatim in several target blocks, and a search and
    # replace hits all of them. Hence always all three.
    # The Rust core's binary framework is git-ignored; the project cannot be generated without it.
    [ -d Packages/SwiftlyCore/SwiftlyCoreFFI.xcframework ] || Werkzeuge/rust-kern.sh --framework >/dev/null 2>&1
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

    echo
    echo "── Store-Waechter ─────────────────────────────────────"
    # Store builds take tips through the App Store only. A link, a word or the
    # supporter-key module in the bundle is a rejection waiting to happen, and no
    # build notices it. Reads the bundles just built.
    python3 "$(dirname "$0")/store-guard.py" || error=1
fi

echo
echo "── Blatt-Waechter ─────────────────────────────────────"
# Apple's sheet floats above the bottom edge on iOS 26 unless it is full height; the
# strip under it is the "bottom gap" that came back five times. Static, so it runs in
# the fast mode too.
if python3 "$(dirname "$0")/sheet-guard.py"; then
    report "Blaetter" "${green}alle buendig${reset}"
else
    report "Blaetter" "${red}schwebendes Blatt${reset}"
    error=1
fi

echo
echo "── Detailseiten-Waechter ──────────────────────────────"
# Inside a detail page nothing animates in (chips, Play label, rails, images); only the page itself slides in.
if python3 "$(dirname "$0")/detail-still-guard.py"; then
    report "Detailseiten" "${green}nichts blendet ein${reset}"
else
    report "Detailseiten" "${red}Inhalt animiert ein${reset}"
    error=1
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
echo "── Katalog ────────────────────────────────────────────"
python3 "$(dirname "$0")/catalog-check.py" || error=1
echo

echo "── Async-Exporte des Kerns ────────────────────────────"
# An exported `async fn` without `async_runtime = "tokio"` runs outside the runtime: its tokio timers/sockets panic and the host sees a thrown error.
python3 "$(dirname "$0")/uniffi-async-check.py" || error=1
echo

echo "── Gespeicherte Schluessel ────────────────────────────"
# A renamed property renames its JSON key, a renamed enum case its raw value.
# Nothing else notices: builds and tests stay green while devices lose their
# stored data. See the script for what it compares.
python3 "$(dirname "$0")/codable-keys-check.py" || error=1
bash "$(dirname "$0")/page-arrival-check.sh" || error=1
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
    # The call is `translated("…")` (it was `uebersetzt(` once; grepping the old name matched nothing and the check
    # passed on an empty list). All source sets count: main, tv, the direct flavor, shared. The thorough version
    # (en + ru present, `if`/`when` branches inside the call) is the Rust guard
    # `crates/swiftly-vm/tests/catalog_guard.rs`; this is the quick check for the key itself.
    absent=$(grep -rhoE 'translated\("[^"]+"' --include='*.kt' --exclude-dir=build --exclude-dir=test \
            Android/phone/src Android/shared/src 2>/dev/null \
        | sed 's/translated("//; s/"$//' | sort -u \
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

# **The Play build must carry nothing of the direct build** (website link, supporter key): Google
# refused other apps for a donation link alone. The guard reads the newest built play bundle/APK
# and direct APK; building them is not this script's job (slow, needs the signing key), so without
# a play release build it only says so.
echo "── Android-Waechter (play/direct) ─────────────────────"
if ls Android/phone/build/outputs/bundle/playRelease/*.aab Android/phone/build/outputs/apk/play/release/*.apk >/dev/null 2>&1; then
    if guard=$(python3 Werkzeuge/store-guard-android.py 2>&1); then
        report "Play-Bau sauber" "${green}nichts aus direct${reset}"
    else
        report "Play-Bau" "${red}Fund${reset}"
        echo "$guard" | sed 's/^/    /' | head -20
        error=1
    fi
else
    report "Play-Bau" "${yellow}keiner gebaut${reset} (store-guard-android.py --build)"
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
