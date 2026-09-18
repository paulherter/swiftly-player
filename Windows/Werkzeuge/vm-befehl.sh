#!/usr/bin/env bash
# Einen Befehl in die Windows-VM tippen — in ein FRISCHES Fenster.
#
#     ./vm-befehl.sh "Get-ChildItem C:\"
#
# **Warum ein frisches Fenster.** `virsh send-key` tippt dorthin, wo die
# Tastatur gerade hinzeigt, und das sieht man von aussen nicht. Zweimal ist
# so ein Befehl in irgendeinem vorderen Fenster gelandet und dort
# stillschweigend verschwunden; gemerkt haben wir es erst, als ein
# `Test-Path` zeigte, dass nie etwas angekommen war. Win+R fuehrt immer zu
# demselben bekannten Zustand, und das kostet sechs Sekunden.
#
# Gedacht ist es fuer **eine** Zeile: die VM holt sich alles Weitere selbst
# ueber `bruecke.sh`. Zeichenweises Tippen ganzer Skripte ist der Weg, auf
# dem sich Tippfehler einschleichen, die niemand sieht.
set -uo pipefail
. "$HOME/windows/tippen.sh"

taste KEY_LEFTMETA KEY_R
sleep 1.5
tippe "powershell"
taste KEY_ENTER
sleep 6

tippe "$1"
taste KEY_ENTER
