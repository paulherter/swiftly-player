#!/bin/bash
# Runs the language probe under several language settings, on the Linux machine.
#
# **Why the script and not just the program.** The interesting cases are the
# ones nobody thinks of when calling it by hand: `LANGUAGE` as a
# colon-separated list, `LC_ALL`, which overrides everything, and a language
# without a catalog. Trying only `LANG=en_US.UTF-8` makes the bug look fixed
# when it is not.
#
#     bash check.sh [tree-path]     (default: $HOME/swiftly)
set -uo pipefail
source "$HOME/.swift-env.sh"
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

TREE=${1:-$HOME/swiftly}
cd "$TREE/Linux/Tools/LanguageProbe" || exit 1
if ! swift build 2>&1 | grep -q "Compiling\|Build complete"; then
  swift build 2>&1 | grep "error:" && exit 1
fi
BIN=$(swift build --show-bin-path)/LanguageProbe
RES="$TREE/Linux/.build/debug/SwiftlyLinux_SwiftlyLinux.resources"
[ -d "$RES" ] || echo "  (Bündel der Oberfläche fehlt — erst 'swift build' in $TREE/Linux)"

run() {
  echo "════ $1 ════"
  shift
  env -u LANGUAGE -u LC_ALL -u LC_MESSAGES -u LANG "$@" "$BIN" "$RES" 2>&1
  echo
}

run "deutsches System"                 LANG=de_DE.UTF-8
run "englisches System"                LANG=en_US.UTF-8
run "französisch — kein Katalog, muss auf Englisch fallen" LANG=fr_FR.UTF-8
run "LANGUAGE schlägt LANG"            LANG=de_DE.UTF-8 LANGUAGE=en_GB:en
run "LC_ALL schlägt LANG"              LANG=de_DE.UTF-8 LC_ALL=en_US.UTF-8
run "gar nichts gesetzt — muss auf Englisch fallen"
