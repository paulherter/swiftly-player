#!/usr/bin/env bash
# Bring sources from the host into the Windows VM, build there, inspect the result.
#
#     ./bridge.sh <repo-root>      pack, deliver, trigger the build
#
# **Why this is needed.** The VM has no shared folder, only CD-ROMs, and those
# work in one direction only. What remains is QEMU's user networking: the host
# is reachable from the guest at 10.0.2.2. So the host serves the sources and
# the VM fetches them.
#
# The result comes back via `virsh screenshot`. That is crude but sufficient:
# the scripts on the other side are terse and print only the relevant lines.
set -euo pipefail
root="${1:?Repo-Wurzel angeben}"
delivery="${HOME}/lieferung"
port="${PORT:-8099}"

rm -rf "$delivery"; mkdir -p "$delivery"
# `zip` may be missing on the host; bsdtar ships with libarchive and can do it
# too. `._*` are macOS companion files; they match `*.swift` and would end up
# in the build. `COPYFILE_DISABLE` stops bsdtar from creating new ones.
( cd "$root" && COPYFILE_DISABLE=1 bsdtar -a -cf "$delivery/quellen.zip" \
      --exclude '*/.build/*' --exclude '*/.git/*' --exclude '._*' \
      Linux/Sources Linux/Resources Windows Packages/JellyfinKit \
      LICENSES LICENSE THIRD-PARTY-NOTICES.md )
cp "$(dirname "${BASH_SOURCE[0]}")/fetch.ps1" "$delivery/fetch.ps1"
cp "$(dirname "${BASH_SOURCE[0]}")/release.ps1" "$delivery/release.ps1"

pkill -f "http.server ${port}" 2>/dev/null || true
# **Detach all three channels, not just two.** Without `< /dev/null` the server
# keeps stdin open; if `bridge.sh` is started via ssh, the remote session then
# waits until timeout although delivery finished long ago.
( cd "$delivery" && nohup python3 -m http.server "$port" --bind 0.0.0.0 \
      < /dev/null > /tmp/bruecke.log 2>&1 & )
sleep 1

"$(dirname "${BASH_SOURCE[0]}")/vm-command.sh" \
  'iwr http://10.0.2.2:'"${port}"'/fetch.ps1 -OutFile $env:USERPROFILE\fetch.ps1 -UseBasicParsing; powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\fetch.ps1'

echo "Getippt. Fortschritt: tail -f /tmp/bruecke.log"
echo "Ergebnis ansehen:  virsh -c qemu:///system screenshot swiftly-win /tmp/vm.ppm"
