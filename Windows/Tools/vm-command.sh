#!/usr/bin/env bash
# Type a command into the Windows VM, into a FRESH window.
#
#     ./vm-command.sh "Get-ChildItem C:\"
#
# **Why a fresh window.** `virsh send-key` types wherever the keyboard
# currently points, and that is not visible from outside. Twice a command
# landed in some front window and silently vanished; it only showed when a
# `Test-Path` revealed that nothing had arrived. Win+R always leads to the same
# known state, and costs six seconds.
#
# Meant for **one** line: the VM fetches everything else itself via
# `bridge.sh`. Typing whole scripts character by character invites typos that
# nobody sees.
set -uo pipefail
. "$HOME/windows/tippen.sh"

taste KEY_LEFTMETA KEY_R
sleep 1.5
tippe "powershell"
taste KEY_ENTER
sleep 6

tippe "$1"
taste KEY_ENTER
