#!/bin/zsh
# Publish the current state to GitHub as ONE neutral snapshot.
#
#     Werkzeuge/publish.sh "Swiftly 1.0.4"
#
# Why not a plain `git push`: the repo is public, and the local commits carry
# detailed rationales that do not belong there. Each release is therefore
# published as a single commit with a short title whose tree matches the local
# state exactly. The full history stays local.
#
# A plain `git push origin` is blocked on purpose (pushurl).
set -e
title="${1:?Titel angeben, z. B. \"Swiftly 1.0.4\"}"
cd "${0:A:h}/.."
url=https://github.com/paulherter/swiftly-player.git

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Arbeitsbaum ist nicht sauber - erst committen."; exit 1
fi
git fetch -q "$url" +main:refs/oeffentlich/main
base=$(git rev-parse refs/oeffentlich/main)
tree=$(git rev-parse 'HEAD^{tree}')
if [ "$(git rev-parse "$base^{tree}")" = "$tree" ]; then
  echo "Oeffentlich steht schon genau dieser Stand."; exit 0
fi
new=$(git commit-tree "$tree" -p "$base" -m "$title")
echo "Oeffentlich wird: $title"
git diff --stat "$base" "$new" | tail -1
git push "$url" "${new}:refs/heads/main"
git update-ref refs/oeffentlich/main "$new"
echo "Veroeffentlicht: $new"
