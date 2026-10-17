#!/bin/bash
# Build Swiftly for Linux.
#
#     ./Linux/build.sh            build
#     ./Linux/build.sh --starten  build and run
#
# **The build sets up its own environment.** It used to depend on variables
# nobody set and on sonames that a system update can rename; see `environment.sh`.
# Whoever fails here should read the cause in the first line instead of
# hunting a linker error.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${here}/environment.sh"

echo "── Umgebung ───────────────────────────────────────────"
if ! environment_check; then
    echo
    echo "Abgebrochen: erst das Fehlende herstellen, dann neu bauen."
    exit 1
fi

echo
echo "── Bauen ──────────────────────────────────────────────"
cd "$here" || exit 1
# The licenses come from `LICENSES/` (the single source) next to the program;
# `Resources/Licenses` is gitignored, never maintain it by hand.
rm -rf "${here}/Resources/Licenses"
mkdir -p "${here}/Resources/Licenses"
cp "${here}/../LICENSES/"* "${here}/Resources/Licenses/" || { echo "LICENSES/ fehlt"; exit 1; }
configuration="${CONFIGURATION:-debug}"
swift build -c "$configuration" || exit 1

binaer="${here}/.build/${configuration}/SwiftlyLinux"

# -- Bundle private libraries ----------------------------------------------
#
# **A built app must start without any environment set.** `librlottie.so`
# lives in `~/.local/lib`, which is not a system path, and was only found
# because `environment.sh` sets `LD_LIBRARY_PATH`. It worked via `build.sh` but
# not by double-click or from another session, with a message that looks like
# a broken build ("cannot open shared object file") but was not.
#
# The search path could not be built in: SwiftPM drops `-Wl,-rpath` as a
# `prohibited flag`, silently except for a warning in the build log. What
# remains is already in the runpath: `$ORIGIN`, the binary's directory. So the
# libraries go there.
#
# Only what the binary actually needs and what lies outside the system paths
# is copied; `ldd` tells both.
if [ -x "$binaer" ]; then
    target="$(dirname "$binaer")"
    count=0
    while read -r path; do
        case "$path" in
            "${env_local}/lib/"*|"${umg_flick}/"*)
                if [ ! -e "${target}/$(basename "$path")" ] \
                   || [ "$path" -nt "${target}/$(basename "$path")" ]; then
                    cp -L "$path" "$target/" && count=$((count + 1))
                fi
                ;;
        esac
    done < <(ldd "$binaer" 2>/dev/null | awk '{print $3}' | grep '^/')
    [ "$count" -gt 0 ] && echo "Mitgenommen: ${count} Bibliothek(en) neben die App."

    # And prove that it suffices: check with no variable set whether anything is
    # still missing. A warning here is the error above, caught before anyone
    # trips over it.
    absent="$(env -u LD_LIBRARY_PATH ldd "$binaer" 2>/dev/null | grep 'not found' || true)"
    if [ -n "$absent" ]; then
        echo
        echo "WARNUNG: ohne gesetzte Umgebung fehlt der App noch etwas:"
        echo "$absent" | sed 's/^/  /'
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
