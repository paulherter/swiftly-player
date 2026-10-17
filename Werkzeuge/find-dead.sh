#!/bin/bash
# Finds code that nobody calls any more.
#
# **The script says WHERE to look, not WHAT is there.** Every hit is a hint,
# not a verdict. Reading the output as a finding and acting on it without
# opening the places is a mistake: the result says *that* something is
# unused, not *how*.
#
# **What it is for.** Not for tidying up -- that would be cosmetics. It is for
# this case: a function was moved to a shared place, the old copy stayed, and
# a bug reported as fixed was still live because one call site kept running
# the old version. Periphery names such leftovers.
#
# **Takes a while.** Periphery builds each target once before it indexes --
# expect a few minutes. Not a candidate for check.sh, but something to run
# once after a larger restructuring.
#
#   Werkzeuge/find-dead.sh            all three Apple targets
#   Werkzeuge/find-dead.sh Swiftly-iOS  just one

set -u
cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
command -v periphery >/dev/null || { echo "periphery fehlt: brew install peripheryapp/periphery/periphery"; exit 1; }

ziele="${1:-Swiftly-iOS,Swiftly-tvOS,Swiftly-macOS}"
xcodegen generate >/dev/null 2>&1

# **Periphery 2.21.2 takes no comma list.** `--targets "A,B"` looks for a
# target that is literally named that and aborts with "does not exist"; the
# default of this script therefore never ran through, only a call with a
# single target. Repeated flags work.
flaggen=()
IFS=',' read -ra single <<< "$ziele"
for z in "${single[@]}"; do flaggen+=(--schemes "$z" --targets "$z"); done

# --retain-public, because JellyfinKit is a package: what it offers to the
# outside is called by the app, not by the package itself. Without it,
# Periphery reports half the public interface as dead.
periphery scan \
    --project Swiftly.xcodeproj \
    "${flaggen[@]}" \
    --retain-public \
    --retain-objc-accessible \
    --format xcode

echo
echo "Das sagt, wo nachzusehen ist — nicht, was dort steht. Was nur eine andere"
echo "Plattform ruft, sieht ein Lauf gegen ein Ziel nicht. Stellen aufschlagen."
