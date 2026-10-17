#!/bin/bash
# PreToolUse hook: prevents writes into a foreign working tree.
#
# A rule that is only written down gets overlooked sooner or later; one that
# the hook enforces does not. A port once went missing because a session wrote
# into another platform's tree.
#
# Exactly one case is blocked: the target lies in **another checkout of the
# same Git directory**. Everything else stays open -- a separate repo, or a
# scratch folder that belongs to none, are both free.
#
# Exit code 2 blocks and sends stderr back to the session.

input=$(cat)
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -z "$target" ] && exit 0

# New files do not exist yet -- walk up to the nearest existing folder.
folder=$(dirname "$target")
while [ ! -d "$folder" ] && [ "$folder" != "/" ]; do folder=$(dirname "$folder"); done

zielbaum=$(git -C "$folder" rev-parse --show-toplevel 2>/dev/null) || exit 0
zielgit=$(git -C "$folder" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

own="${CLAUDE_PROJECT_DIR:-$PWD}"
eigenbaum=$(git -C "$own" rev-parse --show-toplevel 2>/dev/null) || exit 0
eigengit=$(git -C "$own" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

# Foreign repo (separate notes repo, elsewhere) -- not our concern.
[ "$zielgit" != "$eigengit" ] && exit 0
# Own tree -- all good.
[ "$zielbaum" = "$eigenbaum" ] && exit 0

branch=$(git -C "$zielbaum" rev-parse --abbrev-ref HEAD 2>/dev/null)
lies=$(git -C "$zielbaum" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

cat >&2 <<HINWEIS
Gesperrt: das ist ein fremder Arbeitsbaum.

  Ziel   $target
  Baum   $zielbaum  (Zweig $branch, $lies geaenderte Dateien)
  Deiner $eigenbaum

In einen fremden Arbeitsbaum wird nicht geschrieben — auch nicht gutgemeint,
auch nicht zum Nachziehen. Dort steckt womoeglich jemand mitten in einer
Aenderung, die noch niemand sieht.

Stattdessen: die Aenderung im eigenen Baum committen und der Sitzung dieser
Plattform Bescheid geben, damit sie sie selbst zieht.
HINWEIS
exit 2
