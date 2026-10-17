#!/bin/bash
# Fetches swiftly.log from the app container on the iPhone.
#
# Needed because with Wi-Fi switched off the live log connection to the Mac
# drops, exactly during the interesting seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVICES=$(mktemp -t swiftly-geraete)
trap 'rm -f "$GERAETE"' EXIT
xcrun devicectl list devices --json-output "$DEVICES" >/dev/null 2>&1 || true
UDID=$(python3 -c 'import json,sys
for g in json.load(open(sys.argv[1]))["result"]["devices"]:
    if g.get("connectionProperties",{}).get("tunnelState") != "unavailable":
        print(g["identifier"]); break' "$DEVICES" 2>/dev/null || true)
[ -z "${UDID:-}" ] && { echo "Kein erreichbares Geraet." >&2; exit 1; }

TARGET="${1:-swiftly.log}"
# `--user mobile` is required, otherwise the copy fails. Without it devicectl
# reports "Failed to retrieve the file node ... error 7000", the same wording
# it uses for a file that does not exist. The file is there;
# `devicectl device info files --subdirectory Documents` lists it.
xcrun devicectl device copy from --device "$UDID" --user mobile \
  --domain-type appDataContainer --domain-identifier de.paulherter.swiftly \
  --source Documents/swiftly.log --destination "$TARGET"
echo "Geholt nach $TARGET ($(wc -l < "$TARGET") Zeilen)"
