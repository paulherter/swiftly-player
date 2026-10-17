# Enabling the hooks

The three scripts in this folder do nothing on their own. Claude Code only calls them once they are listed in a `settings.json`.

**Put them in `~/.claude/settings.json`, not in the project.** `.claude/` is in `.gitignore`, so every working tree would have its own copy, and only the session that owns that tree could create it. Setting them once at user level covers all trees.

The scripts themselves are checked in and so exist in every tree; the path below resolves per session to its own tree. Outside this project the wrappers find nothing and stay silent.

**The `hooks` block goes *inside* the outer braces**, not after them, with a comma after the last existing entry. Two JSON objects in a row are not valid JSON, and Claude Code then loads nothing from the file.

The finished version sits next to this file as `settings-fertig.json`. If `~/.claude/settings.json` has other entries by now, merge instead of copying:

```
jq -s '.[0] * .[1]' ~/.claude/settings.json \
   Werkzeuge/haken/settings-fertig.json > /tmp/s.json && \
   mv /tmp/s.json ~/.claude/settings.json
```

The part that gets added:

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

**Restart the session afterwards.** Hooks are read at startup; a running session does not notice the change.

## What the three do

| Script | When | What |
|---|---|---|
| `fremder-baum.sh` | before Write/Edit | blocks writes into another checkout of the same Git directory |
| `fremder-baum-bash.sh` | before Bash | same for `sed -i`, `>`, `git reset/checkout/clean`; reading stays free |
| `xcodegen-noetig.sh` | after Write | reports a new file under `Sources/` that the `.xcodeproj` does not know yet |

## Checking that they work

```
printf '%s' '{"tool_input":{"file_path":"../Swiftly-tvOS/x.swift"}}' \
  | Werkzeuge/haken/fremder-baum.sh; echo "exit $?"
```

Exit code 2 and a message mean the hook does its job.
