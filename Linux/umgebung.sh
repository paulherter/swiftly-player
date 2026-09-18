#!/bin/bash
# Die Umgebung fuer einen Bau — und die Reparatur dessen, was fehlt.
#
# **Warum es das gibt.** Am 08.09.2026 startete die Linux-Fassung nicht mehr,
# und es war kein Fehler im Code. Drei Sachen waren weggefallen, alle
# ausserhalb des Repos, jede mit einer Meldung, die nach etwas anderem aussah:
#
#   1. `libncurses.so.6` — CachyOS liefert in ncurses 6.6 nur noch die
#      Breitzeichen-Fassung `libncursesw.so.6`. Den Verweis, den Arch frueher
#      mitlieferte, gibt es nicht mehr. Die Swift-Toolchain haengt daran und
#      startete gar nicht: „error while loading shared libraries".
#   2. `PKG_CONFIG_PATH` war leer — rlottie liegt vollstaendig in
#      `~/.local` (Bibliothek, Kopfdateien, `.pc`), aber pkg-config sieht
#      dort nicht von selbst nach. Der Bau brach mit `cannot find -lrlottie`
#      ab, als waere die Bibliothek nicht da. Sie war die ganze Zeit da.
#   3. `LD_LIBRARY_PATH` war leer — dieselbe Stelle, dasselbe Problem.
#
# Windows hat sein `umgebung.ps1` seit Langem; Linux hatte kein Gegenstueck,
# und genau deshalb brach hier jedes Systemupdate durch. Diese Datei ist das
# Gegenstueck, mit einem Unterschied: sie **repariert** auch, was sich von
# selbst reparieren laesst, statt nur zu setzen.
#
# Punktweise einbinden:  . Linux/umgebung.sh
#
# `set -e` steht hier ausdruecklich **nicht**: die Datei wird eingebunden, und
# ein Abbruch riss sonst die aufrufende Sitzung mit.

umg_lokal="${HOME}/.local"
# **Dieselbe Ablage, die das Startskript schon benutzt.**
#
# Der Verweis auf `libncursesw` lag seit dem 04.09.2026 in `~/.swift-compat`,
# und `starten.sh` setzt `LD_LIBRARY_PATH` darauf. Der *Bau* wusste davon
# nichts — deshalb ist derselbe Fehler ein zweites Mal aufgeschlagen, nur an
# der anderen Stelle. Eine Ablage, beide Wege.
umg_flick="${HOME}/.swift-compat"

# --- 1. Eigene Pfade zuerst, Systempfade danach -------------------------
export PATH="${umg_lokal}/bin:${PATH}"
export LD_LIBRARY_PATH="${umg_flick}:${umg_lokal}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PKG_CONFIG_PATH="${umg_lokal}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

# --- 2. Sonamen, die auf Arch weggefallen sind --------------------------
#
# Ein Verweis im eigenen Verzeichnis, kein Eingriff ins System: das braucht
# kein Passwort und ist mit einem `rm` rueckgaengig. Die Breitzeichen-Fassung
# ist dieselbe Bibliothek mit demselben ABI — Arch selbst hat sie jahrelang
# unter beiden Namen ausgeliefert.
umgebung_soname_flicken() {
    local gesucht="$1" vorhanden="$2"
    [ -e "${umg_flick}/${gesucht}" ] && return 0
    for ort in /usr/lib /usr/lib64 /lib/x86_64-linux-gnu; do
        if [ -e "${ort}/${vorhanden}" ]; then
            mkdir -p "${umg_flick}"
            ln -sf "${ort}/${vorhanden}" "${umg_flick}/${gesucht}"
            echo "  geflickt: ${gesucht} → ${ort}/${vorhanden}"
            return 0
        fi
    done
    return 1
}

umgebung_soname_flicken libncurses.so.6  libncursesw.so.6
umgebung_soname_flicken libncurses++.so.6 libncurses++w.so.6

# --- 3. Nachsehen, bevor gebaut wird ------------------------------------
#
# **Ein Bau, der nach zweihundert Zeilen an einem Bindefehler scheitert,
# sagt nicht, was fehlt.** Diese Pruefung sagt es in einer Zeile, und zwar
# vorher — samt dem Skript, das die Sache herstellt.
umgebung_pruefen() {
    local fehler=0

    if ! command -v swift >/dev/null 2>&1; then
        echo "FEHLT: swift ist nicht im Pfad. → swiftly install 6.3.3"
        fehler=1
    elif ! swift --version >/dev/null 2>&1; then
        echo "FEHLT: swift ist da, startet aber nicht. Meist eine Bibliothek,"
        echo "       die das System umbenannt hat:"
        ldd "$(command -v swift)" 2>/dev/null | grep "not found" | sed 's/^/       /'
        fehler=1
    fi

    for stueck in gtk4 rlottie libvlc; do
        if ! pkg-config --exists "$stueck" 2>/dev/null; then
            case "$stueck" in
                rlottie) echo "FEHLT: rlottie. → Werkzeuge/rlottie-bauen.sh" ;;
                gtk4)    echo "FEHLT: gtk4. → pacman -S gtk4  (bzw. libgtk-4-dev)" ;;
                libvlc)  echo "FEHLT: libvlc. → pacman -S vlc  (bzw. libvlc-dev)" ;;
            esac
            fehler=1
        fi
    done

    [ "$fehler" -eq 0 ] && echo "Umgebung vollstaendig."
    return "$fehler"
}
