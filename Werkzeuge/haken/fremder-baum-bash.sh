#!/bin/bash
# PreToolUse-Haken fuer Bash: dieselbe Regel, andere Tuer.
#
# Der Schwesterhaken sichert Write und Edit. Eine Zeile Shell kommt aber
# genauso in einen fremden Baum — `sed -i`, `>`, `git -C <baum> reset`. Genau
# reset/checkout/clean nennt CLAUDE.md als das, was unfertige Arbeit
# geloescht hat.
#
# Lesen bleibt frei: `git -C <baum> status --porcelain` empfiehlt CLAUDE.md
# ausdruecklich. Gesperrt wird nur, was schreibt.

eingabe=$(cat)
befehl=$(printf '%s' "$eingabe" | jq -r '.tool_input.command // empty')
[ -z "$befehl" ] && exit 0

eigen="${CLAUDE_PROJECT_DIR:-$PWD}"
eigenbaum=$(git -C "$eigen" rev-parse --show-toplevel 2>/dev/null) || exit 0
eigengit=$(git -C "$eigen" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

# Schreibt der Befehl ueberhaupt?
# "stash list" und "stash show" lesen nur, faellt aber unter das Muster unten.
printf '%s' "$befehl" | grep -qE 'stash +(list|show)' && exit 0
printf '%s' "$befehl" | grep -qE '(git[^|;&]*\b(reset|checkout|clean|restore|switch|stash|apply|am)\b|sed +-i|>>?[^>]|\brm\b|\bmv\b|\bcp\b|\btee\b|\btruncate\b|xcodegen)' || exit 0

while IFS= read -r baum; do
    [ -z "$baum" ] && continue
    [ "$baum" = "$eigenbaum" ] && continue
    gemeinsam=$(git -C "$baum" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [ "$gemeinsam" != "$eigengit" ] && continue
    case "$befehl" in *"$baum"*) ;; *) continue ;; esac

    zweig=$(git -C "$baum" rev-parse --abbrev-ref HEAD 2>/dev/null)
    liegt=$(git -C "$baum" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    cat >&2 <<HINWEIS
Gesperrt: dieser Befehl schreibt in einen fremden Arbeitsbaum.

  Baum   $baum  (Zweig $zweig, $liegt geaenderte Dateien)
  Deiner $eigenbaum

Lesen ist erlaubt — "git -C <baum> status --porcelain" zum Beispiel.
Schreiben nicht: reset, checkout und clean haben dort schon einmal
unfertige Arbeit geloescht, die niemand gesehen hat.

Stattdessen: der Sitzung dieser Plattform Bescheid geben, sie zieht selbst nach.
HINWEIS
    exit 2
done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
exit 0
