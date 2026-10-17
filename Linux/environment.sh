#!/bin/bash
# The environment for a build, and repair of what is missing.
#
# **Why this exists.** The Linux version once stopped starting, and it was not
# a code bug. Three things had disappeared, all outside the repo, each with a
# message that pointed somewhere else:
#
#   1. `libncurses.so.6`: CachyOS ships only the wide-character version
#      `libncursesw.so.6` in ncurses 6.6. The symlink Arch used to provide is
#      gone. The Swift toolchain depends on it and would not start at all:
#      "error while loading shared libraries".
#   2. `PKG_CONFIG_PATH` was empty: rlottie lives entirely in `~/.local`
#      (library, headers, `.pc`), but pkg-config does not look there by itself.
#      The build failed with `cannot find -lrlottie` as if the library were
#      missing. It was there all along.
#   3. `LD_LIBRARY_PATH` was empty: same location, same problem.
#
# Windows has had its `environment.ps1` for a long time; Linux had no
# counterpart, which is why every system update broke things here. This file
# is that counterpart, with one difference: it also **repairs** what can be
# repaired by itself instead of only setting variables.
#
# Source it with:  . Linux/environment.sh
#
# `set -e` is deliberately **not** set: the file is sourced, and an abort
# would take the calling session down with it.

env_local="${HOME}/.local"
# **The same store the start script already uses.**
#
# The `libncursesw` symlink lives in `~/.swift-compat`, and `starten.sh` sets
# `LD_LIBRARY_PATH` to it. The *build* did not know about it, so the same
# error showed up a second time at the other place. One store, both paths.
umg_flick="${HOME}/.swift-compat"

# --- 1. Own paths first, system paths after ---------------------------
export PATH="${env_local}/bin:${PATH}"
export LD_LIBRARY_PATH="${umg_flick}:${env_local}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PKG_CONFIG_PATH="${env_local}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

# --- 2. Sonames that disappeared on Arch ------------------------------
#
# A symlink in the user's own directory, no change to the system: needs no
# password and is undone with one `rm`. The wide-character version is the
# same library with the same ABI; Arch itself shipped it under both names
# for years.
environment_soname_patch() {
    local searched="$1" available="$2"
    [ -e "${umg_flick}/${searched}" ] && return 0
    # **Only if the wanted name is really missing.** Otherwise the symlink
    # shadows the real library, because `~/.swift-compat` is first in
    # `LD_LIBRARY_PATH`. For ncurses that would not matter, the wide-character
    # version has the same ABI; for libxml2 it would: 2.16 carries a new soname
    # *because* something changed. If both are installed, a symlink would let the
    # wrong one win.
    for place in /usr/lib /usr/lib64 /lib/x86_64-linux-gnu; do
        [ -e "${place}/${searched}" ] && return 0
    done
    for place in /usr/lib /usr/lib64 /lib/x86_64-linux-gnu; do
        if [ -e "${place}/${available}" ]; then
            mkdir -p "${umg_flick}"
            ln -sf "${place}/${available}" "${umg_flick}/${searched}"
            echo "  geflickt: ${searched} → ${place}/${available}"
            return 0
        fi
    done
    return 1
}

# **`|| true` after it because this file is sourced.** Where a soname is not
# missing at all (Ubuntu, for example), the function returns 1; in a caller
# with `set -e` that would abort the whole run. A symlink not being needed is
# not an error here but the normal case.
environment_soname_patch libncurses.so.6   libncursesw.so.6   || true
environment_soname_patch libncurses++.so.6 libncurses++w.so.6 || true
# **libxml2 only as a last resort.** Arch moves to libxml2 2.16; where 2.13 is
# already gone, the swift.org toolchain lacks its `libxml2.so.2` and does not
# start at all. The new soname means an ABI break, so this is no equivalent
# replacement but a choice between a translator that may stumble and none.
# Users have done this by hand with `sudo ln -sf` into /usr/lib; here it
# works without a password and only if `libxml2.so.2` is really nowhere.
environment_soname_patch libxml2.so.2      libxml2.so.16      || true

# --- 3. Check before building -----------------------------------------
#
# **A build that fails with a linker error after two hundred lines does not
# say what is missing.** This check says it in one line, up front, along
# with the script that fixes it.
environment_check() {
    local error=0

    if ! command -v swift >/dev/null 2>&1; then
        echo "FEHLT: swift ist nicht im Pfad. → swiftly install 6.3.3"
        error=1
    elif ! swift --version >/dev/null 2>&1; then
        echo "FEHLT: swift ist da, startet aber nicht. Meist eine Bibliothek,"
        echo "       die das System umbenannt hat:"
        ldd "$(command -v swift)" 2>/dev/null | grep "not found" | sed 's/^/       /'
        error=1
    fi

    for piece in gtk4 rlottie libvlc; do
        if ! pkg-config --exists "$piece" 2>/dev/null; then
            case "$piece" in
                rlottie) echo "FEHLT: rlottie. → Werkzeuge/rlottie-build.sh" ;;
                gtk4)    echo "FEHLT: gtk4. → pacman -S gtk4  (bzw. libgtk-4-dev)" ;;
                libvlc)  echo "FEHLT: libvlc. → pacman -S vlc  (bzw. libvlc-dev)" ;;
            esac
            error=1
        fi
    done

    [ "$error" -eq 0 ] && echo "Umgebung vollstaendig."
    return "$error"
}
