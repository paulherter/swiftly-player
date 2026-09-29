#!/usr/bin/env bash
#
# Welcher Paketstand gilt — fuer deb, rpm und pacman derselbe.
#
#     paketstand.sh [ausdruecklich]
#
# **Warum aus dem PKGBUILD.** Geht dieselbe Fassung mit einer Behebung noch
# einmal hinaus, muss der Paketstand steigen, sonst sehen apt, dnf und pacman
# kein Update. Stand er nur als Eingabe am Arbeitsablauf (Vorgabe 1), lief
# jeder Lauf ueber ein Tag mit 1 — ein neuer Bau derselben Fassung waere bei
# keinem Nutzer angekommen. `pkgrel` im PKGBUILD wird ohnehin mit der
# Baunummer hochgezaehlt; von dort kommt der Wert jetzt, solange niemand
# ausdruecklich einen anderen angibt.
set -euo pipefail
if [ -n "${1:-}" ]; then echo "$1"; exit 0; fi
stand=$(sed -n 's/^pkgrel=\([0-9][0-9]*\)$/\1/p' "$(dirname "${BASH_SOURCE[0]}")/PKGBUILD")
echo "${stand:-1}"
