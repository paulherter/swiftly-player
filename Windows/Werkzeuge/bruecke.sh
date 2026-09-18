#!/usr/bin/env bash
# Quellen vom Wirt in die Windows-VM bringen, dort bauen, Ergebnis ansehen.
#
#     ./bruecke.sh <repo-wurzel>      packen, ausliefern, bauen lassen
#
# **Warum es das braucht.** Die VM hat keinen geteilten Ordner — nur
# CD-ROMs, und die gehen nur in eine Richtung. Uebrig bleibt QEMUs
# Nutzernetz: der Wirt ist im Gast unter 10.0.2.2 erreichbar. Also stellt
# der Wirt die Quellen hin, und die VM holt sie sich.
#
# Zurueck kommt das Ergebnis ueber `virsh screenshot`. Das ist grob, reicht
# aber: die Skripte drueben fassen sich kurz und geben nur die Zeilen aus,
# auf die es ankommt.
set -euo pipefail
wurzel="${1:?Repo-Wurzel angeben}"
lieferung="${HOME}/lieferung"
port="${PORT:-8099}"

rm -rf "$lieferung"; mkdir -p "$lieferung"
# `zip` fehlt auf CachyOS; bsdtar kommt mit libarchive und kann es auch.
# `._*` sind macOS-Beidateien; sie passen auf `*.swift` und landen sonst im
# Bau. `COPYFILE_DISABLE` verhindert, dass bsdtar neue erzeugt.
( cd "$wurzel" && COPYFILE_DISABLE=1 bsdtar -a -cf "$lieferung/quellen.zip" \
      --exclude '*/.build/*' --exclude '*/.git/*' --exclude '._*' \
      Linux/Sources Linux/Ressourcen Windows Packages/JellyfinKit )
cp "$(dirname "${BASH_SOURCE[0]}")/hol.ps1" "$lieferung/hol.ps1"

pkill -f "http.server ${port}" 2>/dev/null || true
# **Alle drei Kanaele abklemmen, nicht nur zwei.** Ohne `< /dev/null` haelt
# der Server die Standardeingabe offen; wird `bruecke.sh` ueber ssh
# gestartet, wartet die Fernsitzung dann bis zum Zeitablauf, obwohl die
# Auslieferung laengst durch ist. Beim ersten Lauf genau so passiert.
( cd "$lieferung" && nohup python3 -m http.server "$port" --bind 0.0.0.0 \
      < /dev/null > /tmp/bruecke.log 2>&1 & )
sleep 1

"$(dirname "${BASH_SOURCE[0]}")/vm-befehl.sh" \
  'iwr http://10.0.2.2:'"${port}"'/hol.ps1 -OutFile $env:USERPROFILE\hol.ps1 -UseBasicParsing; powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\hol.ps1'

echo "Getippt. Fortschritt: tail -f /tmp/bruecke.log"
echo "Ergebnis ansehen:  virsh -c qemu:///system screenshot swiftly-win /tmp/vm.ppm"
