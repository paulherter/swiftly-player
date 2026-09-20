#!/bin/zsh
# Den aktuellen Stand oeffentlich auf GitHub stellen - als EIN neutraler Schnappschuss.
#
#     Werkzeuge/veroeffentlichen.sh "Swiftly 1.0.4"
#
# **Warum nicht einfach `git push`.** Das Repo ist oeffentlich. Unsere Commits
# tragen ausfuehrliche Begruendungen mit Namen, Geraeten und Server; die
# gehoeren nicht dorthin. Oeffentlich steht deshalb je Veroeffentlichung ein
# Commit mit kurzem Titel, dessen Inhalt genau dem lokalen Stand entspricht.
# Die volle Historie bleibt lokal (Sicherung: NAS, /volume1/docker/git-sicherung).
#
# Ein normales `git push origin` ist absichtlich gesperrt (pushurl).
set -e
titel="${1:?Titel angeben, z. B. \"Swiftly 1.0.4\"}"
cd "${0:A:h}/.."
url=https://github.com/paulherter/swiftly-player.git

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Arbeitsbaum ist nicht sauber - erst committen."; exit 1
fi
git fetch -q "$url" +main:refs/oeffentlich/main
basis=$(git rev-parse refs/oeffentlich/main)
baum=$(git rev-parse 'HEAD^{tree}')
if [ "$(git rev-parse "$basis^{tree}")" = "$baum" ]; then
  echo "Oeffentlich steht schon genau dieser Stand."; exit 0
fi
neu=$(git commit-tree "$baum" -p "$basis" -m "$titel")
echo "Oeffentlich wird: $titel"
git diff --stat "$basis" "$neu" | tail -1
git push "$url" "${neu}:refs/heads/main"
git update-ref refs/oeffentlich/main "$neu"
echo "Veroeffentlicht: $neu"
