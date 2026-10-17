#!/bin/bash
# PreToolUse hook for Bash: the same rule, another door.
#
# The sister hook guards Write and Edit. But a line of shell reaches a foreign
# tree just as well -- `sed -i`, `>`, `git -C <tree> reset`. It is exactly
# reset/checkout/clean that have deleted unfinished work.
#
# Reading stays free: `git -C <tree> status --porcelain` is the recommended
# way to look. Only what writes is blocked.

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$command" ] && exit 0

own="${CLAUDE_PROJECT_DIR:-$PWD}"
eigenbaum=$(git -C "$own" rev-parse --show-toplevel 2>/dev/null) || exit 0
eigengit=$(git -C "$own" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

# Does the command write at all?
# "stash list" and "stash show" only read, but fall under the pattern below.
printf '%s' "$command" | grep -qE 'stash +(list|show)' && exit 0
printf '%s' "$command" | grep -qE '(git[^|;&]*\b(reset|checkout|clean|restore|switch|stash|apply|am)\b|sed +-i|>>?[^>]|\brm\b|\bmv\b|\bcp\b|\btee\b|\btruncate\b|xcodegen)' || exit 0

while IFS= read -r tree; do
    [ -z "$tree" ] && continue
    [ "$tree" = "$eigenbaum" ] && continue
    gemeinsam=$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [ "$gemeinsam" != "$eigengit" ] && continue
    case "$command" in *"$tree"*) ;; *) continue ;; esac

    branch=$(git -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null)
    lies=$(git -C "$tree" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    cat >&2 <<HINWEIS
Gesperrt: dieser Befehl schreibt in einen fremden Arbeitsbaum.

  Baum   $tree  (Zweig $branch, $lies geaenderte Dateien)
  Deiner $eigenbaum

Lesen ist erlaubt — "git -C <baum> status --porcelain" zum Beispiel.
Schreiben nicht: reset, checkout und clean haben dort schon einmal
unfertige Arbeit geloescht, die niemand gesehen hat.

Stattdessen: der Sitzung dieser Plattform Bescheid geben, sie zieht selbst nach.
HINWEIS
    exit 2
done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
exit 0
