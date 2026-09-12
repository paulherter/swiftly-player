#!/bin/bash
# PreToolUse-Haken: verhindert Schreibzugriffe in einen fremden Arbeitsbaum.
#
# CLAUDE.md sagt es dreimal, und trotzdem ist der tvOS-Sitzung am 05.09.2026
# eine Uebernahme abhandengekommen. Eine Regel, die nur dasteht, wird
# irgendwann uebersehen; eine, die der Haken durchsetzt, nicht.
#
# Gesperrt wird genau ein Fall: das Ziel liegt in einem **anderen Auscheck
# desselben Git-Verzeichnisses**. Alles andere bleibt offen — Swiftly-Notizen
# ist ein eigenes Repo, der Kritzelordner gehoert zu keinem, beide sind frei.
#
# Rueckgabe 2 blockt und schickt stderr an die Sitzung zurueck.

eingabe=$(cat)
ziel=$(printf '%s' "$eingabe" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -z "$ziel" ] && exit 0

# Neue Dateien gibt es noch nicht — bis zum naechsten vorhandenen Ordner hoch.
ordner=$(dirname "$ziel")
while [ ! -d "$ordner" ] && [ "$ordner" != "/" ]; do ordner=$(dirname "$ordner"); done

zielbaum=$(git -C "$ordner" rev-parse --show-toplevel 2>/dev/null) || exit 0
zielgit=$(git -C "$ordner" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

eigen="${CLAUDE_PROJECT_DIR:-$PWD}"
eigenbaum=$(git -C "$eigen" rev-parse --show-toplevel 2>/dev/null) || exit 0
eigengit=$(git -C "$eigen" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

# Fremdes Repo (Notizen, anderswo) — nicht meine Zustaendigkeit.
[ "$zielgit" != "$eigengit" ] && exit 0
# Eigener Baum — alles gut.
[ "$zielbaum" = "$eigenbaum" ] && exit 0

zweig=$(git -C "$zielbaum" rev-parse --abbrev-ref HEAD 2>/dev/null)
liegt=$(git -C "$zielbaum" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

cat >&2 <<HINWEIS
Gesperrt: das ist ein fremder Arbeitsbaum.

  Ziel   $ziel
  Baum   $zielbaum  (Zweig $zweig, $liegt geaenderte Dateien)
  Deiner $eigenbaum

In einen fremden Arbeitsbaum wird nicht geschrieben — auch nicht gutgemeint,
auch nicht zum Nachziehen. Dort steckt womoeglich jemand mitten in einer
Aenderung, die noch niemand sieht.

Stattdessen: die Aenderung im eigenen Baum committen und der Sitzung dieser
Plattform Bescheid geben, damit sie sie selbst zieht.
HINWEIS
exit 2
