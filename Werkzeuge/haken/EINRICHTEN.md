# Die Haken scharfschalten

Die drei Skripte in diesem Ordner tun von sich aus nichts. Claude Code ruft
sie erst, wenn sie in einer `settings.json` stehen.

**Nach `~/.claude/settings.json`, nicht ins Projekt.** `.claude/` steht in
`.gitignore`, jeder Arbeitsbaum haette also seine eigene Fassung — und
angelegt werden koennte sie dort nur von der Sitzung, der dieser Baum
gehoert. Einmal auf Benutzerebene deckt alle sieben ab.

Die Skripte selbst sind eingecheckt und liegen damit in jedem Baum; der
Pfad unten loest sich je Sitzung auf ihren eigenen auf. Ausserhalb von
Swiftly finden die Wrapper nichts und schweigen.

**Der `hooks`-Block gehoert *in* die aeussere Klammer**, nicht dahinter — mit
Komma nach dem letzten vorhandenen Eintrag. Zwei JSON-Objekte hintereinander
sind kein gueltiges JSON, und Claude Code laedt die Datei dann gar nicht.

Die fertige Fassung liegt daneben als `settings-fertig.json`; falls
`~/.claude/settings.json` inzwischen andere Eintraege hat, statt Kopieren
lieber zusammenfuehren:

```
jq -s '.[0] * .[1]' ~/.claude/settings.json \
   Werkzeuge/haken/settings-fertig.json > /tmp/s.json && \
   mv /tmp/s.json ~/.claude/settings.json
```

So sieht der Teil aus, der dazukommt:

```json
  "theme": "dark",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [{ "type": "command",
          "command": "sh -c 'h=\"$CLAUDE_PROJECT_DIR/Werkzeuge/haken/fremder-baum.sh\"; [ -x \"$h\" ] && exec \"$h\"; cat >/dev/null'" }] },
      { "matcher": "Bash",
        "hooks": [{ "type": "command",
          "command": "sh -c 'h=\"$CLAUDE_PROJECT_DIR/Werkzeuge/haken/fremder-baum-bash.sh\"; [ -x \"$h\" ] && exec \"$h\"; cat >/dev/null'" }] }
    ],
    "PostToolUse": [
      { "matcher": "Write",
        "hooks": [{ "type": "command",
          "command": "sh -c 'h=\"$CLAUDE_PROJECT_DIR/Werkzeuge/haken/xcodegen-noetig.sh\"; [ -x \"$h\" ] && exec \"$h\"; cat >/dev/null'" }] }
    ]
  }
```

**Danach die Sitzung neu starten.** Haken werden beim Start gelesen; eine
laufende Sitzung merkt von der Aenderung nichts.

## Was die drei tun

| Skript | Wann | Was |
|---|---|---|
| `fremder-baum.sh` | vor Write/Edit | sperrt Schreibzugriffe in einen anderen Auscheck desselben Git-Verzeichnisses |
| `fremder-baum-bash.sh` | vor Bash | dasselbe fuer `sed -i`, `>`, `git reset/checkout/clean`. Lesen bleibt frei |
| `xcodegen-noetig.sh` | nach Write | meldet eine neue Datei unter `Sources/`, die das `.xcodeproj` noch nicht kennt |

Nicht gesperrt wird `Notizen` — eigenes Repo, dort schreibt `main`
die Aenderungsliste.

## Nachpruefen, dass sie greifen

```
printf '%s' '{"tool_input":{"file_path":"../Swiftly-tvOS/x.swift"}}' \
  | Werkzeuge/haken/fremder-baum.sh; echo "Rueckgabe $?"
```

Rueckgabe 2 und ein Hinweistext heisst: der Haken tut, was er soll.
