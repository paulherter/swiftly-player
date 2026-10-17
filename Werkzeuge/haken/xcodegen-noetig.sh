#!/bin/bash
# PostToolUse hook: reports a new source file that the .xcodeproj does not
# know yet.
#
# The .xcodeproj is not checked in and is generated from project.yml. A new
# file under Sources/ is therefore invisible until the next `xcodegen
# generate` -- the build succeeds without compiling it, and the error later
# looks like a missing symbol.
#
# **Why not by file name.** Searching project.pbxproj for the base name gives
# false all-clears: at least ten base names occur in several targets --
# Style.swift lives in Shared, tvOS and macOS, MainView.swift likewise.
# Sharpening the match does not work either: the pbxproj only has
# `path = Style.swift`, not the path relative to the tree.
#
# So it uses two properties that need no name:
#   1. Git does not know the file yet  -> it really is new
#   2. It is newer than project.pbxproj -> the project was not regenerated
#      afterwards
#
# Exit code 2 blocks nothing here (the file is already written), it only
# sends the hint back to the session.

input=$(cat)
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
case "$target" in
    */Sources/*.swift) ;;
    *) exit 0 ;;
esac
[ -f "$target" ] || exit 0

tree=$(git -C "$(dirname "$target")" rev-parse --show-toplevel 2>/dev/null) || exit 0
pbx=$(ls -d "$tree"/*.xcodeproj/project.pbxproj 2>/dev/null | head -1)
[ -f "$pbx" ] || exit 0

git -C "$tree" ls-files --error-unmatch "$target" >/dev/null 2>&1 && exit 0   # already versioned
[ "$target" -nt "$pbx" ] || exit 0                                            # project is newer

echo "Neu und noch nicht im .xcodeproj: ${target#$tree/} — vor dem Bauen: xcodegen generate" >&2
exit 2
