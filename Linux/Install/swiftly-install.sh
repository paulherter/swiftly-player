#!/usr/bin/env bash
#
# Swiftly Player: installation on Linux.
#
#     curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Installieren/swiftly-installieren.sh | bash
#
# **This registers a package source instead of just installing.** A manual
# build is a one-off: the package manager never learns the app exists, so
# it never gets updates. This script adds the source that apt, dnf, zypper
# or pacman pull the app from, so new versions arrive with normal system
# updates.
#
# To build from source anyway: `--aus-quelle`. Takes a few minutes and also
# works on distributions without a package.
#
# Everything lands under $HOME. The password is needed once, for the
# distribution packages, and the prompt comes from the package manager,
# not from this script.

set -euo pipefail

# Everything is wrapped in one function: if curl delivers only half the
# script, nothing runs instead of half of it.
main() {

BRANCH="${SWIFTLY_ZWEIG:-main}"
ORIGIN="${SWIFTLY_HERKUNFT:-https://github.com/paulherter/swiftly-player.git}"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/swiftly-jellyfin"
TARGET="$HOME/.local"
# **Not `NAME`.** `/etc/os-release` sets its own `NAME`, which is sourced
# right here. Using `NAME` would name the app "CachyOS Linux" and create a
# directory with a space in it.
PROGRAM="swiftly-jellyfin"
ID="de.paulherter.swiftly"
SOURCE_URL="${SWIFTLY_QUELLE:-https://paulherter.github.io/swiftly-player}"
# The fingerprint is pinned, not just the keyring: this verifies that the
# downloaded key is the expected one.
FINGERABDRUCK="5F31DEC1EAFF1AFFEA267E50B2ACD5E1D4945099"

red=''; green=''; bold=''; blass=''; reset=''
if [ -t 1 ]; then
    red=$'\033[31m'; green=$'\033[32m'; bold=$'\033[1m'; blass=$'\033[2m'; reset=$'\033[0m'
fi
say()   { printf '%s==>%s %s\n' "$green$bold" "$reset$bold" "$1$reset"; }
quiet()   { printf '    %s%s%s\n' "$blass" "$1" "$reset"; }
complain()  { printf '%sFehler:%s %s\n' "$red$bold" "$reset" "$1" >&2; exit 1; }

# ---------------------------------------------------------------- Cleanup

# **A version built from source lives under ~/.local.** It comes before
# /usr/bin in the search path and has its own menu entry. Without removing
# it, a later package-manager install would keep launching the old build.
own_version_remove() {
    rm -rf "$TARGET/share/$PROGRAM" "$TARGET/bin/$PROGRAM" \
           "$TARGET/share/applications/$ID.desktop" \
           "$TARGET/share/metainfo/$ID.metainfo.xml"
    find "$TARGET/share/icons/hicolor" -name "$ID.png" -delete 2>/dev/null || true
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$TARGET/share/applications" 2>/dev/null || true
}

from_source=0
[ "${1:-}" = "--aus-quelle" ] && from_source=1

if [ "${1:-}" = "--deinstallieren" ] || [ "${1:-}" = "--entfernen" ]; then
    say "Swiftly Player entfernen"
    own_version_remove
    rm -rf "$WORK"
    quiet "Die Einstellungen unter ~/.config/swiftly bleiben liegen."
    quiet "Weg damit: rm -rf ~/.config/swiftly"
    say "Entfernt."
    return 0
fi

# ---------------------------------------------------------- Distribution
#
# `ID_LIKE` keeps the list short: Mint says "ubuntu debian", Nobara says
# "fedora", CachyOS says "arch". Only if neither matches does someone have
# to step in by hand.

[ -r /etc/os-release ] || complain "/etc/os-release fehlt — welche Distribution ist das?"
# shellcheck disable=SC1091
. /etc/os-release
sippe=""
for candidate in $ID ${ID_LIKE:-}; do
    case "$candidate" in
        arch|archarm)                          sippe=arch;   break ;;
        debian|ubuntu)                         sippe=debian; break ;;
        fedora|rhel|centos)                    sippe=fedora; break ;;
        suse|opensuse|opensuse-tumbleweed)     sippe=suse;   break ;;
        alpine)                                sippe=alpine; break ;;
    esac
done
[ -n "$sippe" ] || complain "Unbekannte Distribution: ${PRETTY_NAME:-$ID}
Gebraucht werden GTK 4, libVLC, git, ein C++-Uebersetzer und pkg-config.
Sind die da, laeuft der Rest dieses Skripts mit SWIFTLY_PAKETE_UEBERSPRINGEN=1."

say "Swiftly Player — Installation"
quiet "${PRETTY_NAME:-$ID}, erkannt als $sippe, $(uname -m)"

if [ "$(uname -m)" != "x86_64" ] && [ "$(uname -m)" != "aarch64" ]; then
    complain "Swift gibt es fuer x86_64 und aarch64. Diese Kiste ist $(uname -m)."
fi

# --------------------------------------------------------------- Packages
#
# Two kinds in one list: what the app needs to run (GTK, VLC) and what
# Swift needs to compile (curl, ncurses, sqlite ...). Splitting them gains
# nothing, since building needs both.

sudo_call=""
if [ "$(id -u)" != "0" ]; then
    command -v sudo >/dev/null 2>&1 || complain "sudo fehlt, und ich bin nicht root."
    sudo_call="sudo"
fi

# ---------------------------------------------------------- Package source
#
# The usual way. One line in the package manager's configuration, after
# which the app belongs to the system like any other package, updates
# included.
#
# **Signature, if there is one.** If the source ships a public key, it is
# registered and verified. If not, the source is registered as trusted and
# this is stated openly rather than leaving a line nobody understands.

signiert=0
if curl -fsI "$SOURCE_URL/swiftly.gpg" >/dev/null 2>&1; then signiert=1; fi

source_register() {
    case "$sippe" in
        debian)
            if [ "$signiert" = "1" ]; then
                $sudo_call install -d -m755 /etc/apt/keyrings
                curl -fsSL "$SOURCE_URL/swiftly.gpg" |
                    $sudo_call tee /etc/apt/keyrings/swiftly.asc >/dev/null
                echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/swiftly.asc] $SOURCE_URL/deb ./" |
                    $sudo_call tee /etc/apt/sources.list.d/swiftly.list >/dev/null
            else
                echo "deb [arch=amd64 trusted=yes] $SOURCE_URL/deb ./" |
                    $sudo_call tee /etc/apt/sources.list.d/swiftly.list >/dev/null
            fi
            $sudo_call apt-get update
            $sudo_call apt-get install -y "$PROGRAM"
            ;;
        fedora)
            $sudo_call tee /etc/yum.repos.d/swiftly.repo >/dev/null <<EOF
[swiftly]
name=Swiftly Player
baseurl=$SOURCE_URL/rpm
enabled=1
gpgcheck=$signiert
$([ "$signiert" = "1" ] && echo "gpgkey=$SOURCE_URL/swiftly.gpg")
EOF
            $sudo_call dnf install -y "$PROGRAM"
            ;;
        suse)
            $sudo_call zypper --non-interactive removerepo swiftly >/dev/null 2>&1 || true
            $sudo_call zypper --non-interactive addrepo -f "$SOURCE_URL/rpm" swiftly
            [ "$signiert" = "1" ] || $sudo_call zypper --non-interactive modifyrepo --no-gpgcheck swiftly
            $sudo_call zypper --non-interactive --gpg-auto-import-keys refresh swiftly
            $sudo_call zypper --non-interactive install "$PROGRAM"
            ;;
        arch)
            local level="Optional TrustAll"
            if [ "$signiert" = "1" ]; then
                level="Required DatabaseOptional"
                # pacman keeps its own keyring. A key in it is not enough: it must be
                # locally signed, otherwise it counts as unknown and the install aborts.
                curl -fsSL "$SOURCE_URL/swiftly.gpg" | $sudo_call pacman-key --add -
                $sudo_call pacman-key --lsign-key "$FINGERABDRUCK"
            fi
            if ! grep -q '^\[swiftly\]' /etc/pacman.conf; then
                printf '\n[swiftly]\nSigLevel = %s\nServer = %s/arch\n' \
                    "$level" "$SOURCE_URL" | $sudo_call tee -a /etc/pacman.conf >/dev/null
            fi
            $sudo_call pacman -Sy --noconfirm "$PROGRAM"
            ;;
        *)  return 1 ;;
    esac
}

if [ "${from_source:-0}" = "0" ]; then
    say "Paketquelle eintragen"
    [ "$signiert" = "1" ] ||
        quiet "Die Quelle ist noch nicht signiert — sie wird als vertrauenswuerdig eingetragen."
    quiet "Dafuer fragt der Paketverwalter gleich nach deinem Passwort."
    if source_register; then
        if [ -e "$TARGET/share/$PROGRAM/$PROGRAM" ] || [ -L "$TARGET/bin/$PROGRAM" ]; then
            quiet "Eine aeltere, selbst gebaute Fassung unter $TARGET wird entfernt."
            own_version_remove
        fi
        # **A still-running old copy would hold the name on D-Bus.** A click on
        # the icon would then raise it instead of the freshly installed version.
        # Only processes running from a Swiftly directory are ended; settings are
        # kept.
        if pkill -f '/swiftly-jellyfin/swiftly-jellyfin( |$)' 2>/dev/null; then
            quiet "Eine laufende aeltere Swiftly-Kopie wurde beendet — jetzt neu starten."
        fi
        say "Fertig."
        echo
        quiet "Im Anwendungsmenue steht jetzt „Swiftly\"."
        quiet "Aus der Konsole: $PROGRAM"
        quiet "Updates kommen ab jetzt mit dem normalen Systemupdate."
        echo
        quiet "Entfernen: ueber den Paketverwalter, wie jedes andere Paket."
        return 0
    fi
    quiet "Kein Paket fuer diese Distribution — es wird aus der Quelle gebaut."
fi

packages_set() {
    case "$sippe" in
        arch)
            $sudo_call pacman -S --needed --noconfirm \
                gtk4 vlc git gcc pkgconf curl unzip which
            ;;
        debian)
            $sudo_call apt-get update
            $sudo_call apt-get install -y --no-install-recommends \
                libgtk-4-dev libvlc-dev vlc-plugin-base \
                git g++ pkg-config curl ca-certificates \
                binutils libcurl4-openssl-dev libedit2 libncurses-dev \
                libpython3-dev libsqlite3-0 libxml2-dev libz3-dev zlib1g-dev tzdata
            ;;
        fedora)
            # On Fedora, VLC is not in the distribution's own repos but in RPM Fusion.
            # Without it the install fails on exactly one package, so it is offered
            # first.
            if ! $sudo_call dnf list --available vlc-devel >/dev/null 2>&1 &&
               ! rpm -q vlc-devel >/dev/null 2>&1; then
                quiet "libVLC liegt bei Fedora in RPM Fusion. Wird jetzt eingerichtet."
                $sudo_call dnf install -y --nogpgcheck \
                    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" || true
            fi
            $sudo_call dnf install -y \
                gtk4-devel vlc-devel git gcc-c++ pkgconf-pkg-config curl \
                libcurl-devel libedit-devel libicu-devel libuuid-devel \
                libxml2-devel python3-devel sqlite ncurses-devel
            ;;
        suse)
            $sudo_call zypper --non-interactive install \
                gtk4-devel vlc-devel git gcc-c++ pkg-config curl \
                libcurl-devel libxml2-devel sqlite3 ncurses-devel || {
                    complain "Bei openSUSE liegt VLC im Packman-Verzeichnis.
Einmal einrichten, dann das Skript nochmal:
  sudo zypper ar -cfp 90 https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/ packman
  sudo zypper dup --from packman --allow-vendor-change"
                }
            ;;
        alpine)
            complain "Alpine nutzt musl, Swift braucht glibc. Das geht (noch) nicht."
            ;;
    esac
}

if [ "${SWIFTLY_PAKETE_UEBERSPRINGEN:-0}" = "1" ]; then
    quiet "Pakete uebersprungen (SWIFTLY_PAKETE_UEBERSPRINGEN=1)."
else
    say "Pakete der Distribution"
    quiet "Dafuer fragt der Paketverwalter gleich nach deinem Passwort."
    packages_set
fi

# --------------------------------------------------------------- Source

say "Quelltext"
if [ -f "$PWD/Linux/Package.swift" ]; then
    source="$PWD"
    quiet "Aus dem Verzeichnis, in dem du stehst."
elif [ -d "$WORK/quelle/.git" ]; then
    source="$WORK/quelle"
    git -C "$source" fetch --depth 1 origin "$BRANCH"
    git -C "$source" reset --hard "origin/$BRANCH"
    quiet "Vorhandenen Auscheck nachgezogen."
else
    source="$WORK/quelle"
    mkdir -p "$WORK"
    git clone --depth 1 --branch "$BRANCH" "$ORIGIN" "$source"
fi

# **The swift.org toolchain is linked against Ubuntu's sonames.** On Arch
# and CachyOS the same library is named differently: `libncursesw.so.6`
# instead of `libncurses.so.6`, and `libxml2.so.16` instead of
# `libxml2.so.2`. The compiler then fails to start with "error while
# loading shared libraries", and the build looks like a code error.
# `environment.sh` creates the missing links under `~/.swift-compat` and sets
# the search paths, with no password and no change to the system.
if [ -f "$source/Linux/environment.sh" ]; then
    # shellcheck source=/dev/null
    . "$source/Linux/environment.sh"
fi


# ---------------------------------------------------------------- Swift

# **After the source, not before.** The check below runs `swift --version`,
# which fails on Arch because of a soname that `environment.sh` fixes in the
# previous step. In the other order, an existing compiler looked missing and
# the script downloaded a second toolchain that would fail on the same
# library.
say "Swift"
export PATH="$HOME/.local/share/swiftly/bin:$PATH"
needs_swift=1
if command -v swift >/dev/null 2>&1; then
    version=$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -1 | awk '{print $3}' || true)
    main=${version%%.*}
    if [ -n "$version" ] && [ "${main:-0}" -ge 6 ]; then
        quiet "Swift $version ist da."
        needs_swift=0
    fi
fi

if [ "$needs_swift" = "1" ]; then
    quiet "Wird ueber swiftly von swift.org geholt — komplett unter \$HOME, ohne Passwort."
    mkdir -p "$WORK"
    ( cd "$WORK"
      curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
      tar -xzf "swiftly-$(uname -m).tar.gz" )
    # swiftly does not know every distribution: on Arch it aborts with
    # "Unsupported Linux platform". The Ubuntu 24.04 toolchain still runs there
    # because glibc is newer.
    "$WORK/swiftly" init --quiet-shell-followup --assume-yes --skip-install ||
    "$WORK/swiftly" init --quiet-shell-followup --assume-yes --skip-install \
        --overwrite --platform ubuntu24.04
    # Not via env.sh: swiftly creates that file in different places or not at
    # all depending on version, and sourcing a missing file aborts the whole run
    # under `set -e`. The path is enough.
    export PATH="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/bin:$PATH"
    swiftly install --use latest
    command -v swift >/dev/null 2>&1 || complain "Swift ist nach der Installation nicht im PATH."
fi

# -------------------------------------------------------------- rlottie
#
# The startup animation. Not available in any package source, but needs no
# cmake either: one compiler call is enough, and it is linked statically.

say "rlottie (Startanimation)"
export SWIFTLY_RLOTTIE_ZIEL="$WORK/rlottie-praefix"
if [ -f "$SWIFTLY_RLOTTIE_ZIEL/lib/librlottie.a" ]; then
    quiet "Liegt schon gebaut da."
else
    bash "$source/Werkzeuge/rlottie-build.sh" "$WORK/rlottie-quelle" >/dev/null
    quiet "Gebaut."
fi
export PKG_CONFIG_PATH="$SWIFTLY_RLOTTIE_ZIEL/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ----------------------------------------------------------------- Build
#
# `-static-stdlib` links Swift's own runtime into the program. Without it,
# half the toolchain would have to stay installed for the app to start.

say "Swiftly bauen"
quiet "Das dauert beim ersten Mal ein paar Minuten."

( cd "$source/Linux" && swift build -c release -Xswiftc -static-stdlib )

# **Ask for the build directory, do not guess.** `.build/release` is a
# symlink that SwiftPM may repoint; the same call with `--show-bin-path`
# reports where this build actually put its output.
bauordner="$( cd "$source/Linux" && swift build -c release -Xswiftc -static-stdlib --show-bin-path )"
[ -n "$bauordner" ] && [ -d "$bauordner" ] || complain "Der Bau hat keinen Bauordner gemeldet."

binaer="$bauordner/SwiftlyLinux"
[ -x "$binaer" ] || complain "Der Bau hat kein Programm hinterlassen."

# ------------------------------------------------------------ Installing
#
# The program and the resource bundles must sit next to each other: Swift
# finds `Bundle.module` via its own path. Both therefore go to share/, and
# bin/ only holds a symlink.

say "Einraeumen"
mkdir -p "$TARGET/bin" "$TARGET/share/$PROGRAM" "$TARGET/share/applications" "$TARGET/share/metainfo"
install -m755 "$binaer" "$TARGET/share/$PROGRAM/$PROGRAM"
strip "$TARGET/share/$PROGRAM/$PROGRAM" 2>/dev/null || true

# **Bundle names depend on the toolchain.** Up to Swift 6.3, SwiftPM names
# them `<target>_<target>.resources`, from 6.4 on `<target>_<target>.bundle`,
# and the generated `Bundle.module` accessor looks for exactly the name used
# at build time. A hardcoded `*.resources` with `|| true` matched nothing
# on 6.4, the install still reported "Fertig", and the app died at startup
# with "unable to find bundle named SwiftlyLinux_SwiftlyLinux". So both
# names are handled, and without bundles there is no "Fertig".
rm -rf "$TARGET/share/$PROGRAM"/*.resources "$TARGET/share/$PROGRAM"/*.bundle
bundle=0
for b in "$bauordner"/*.resources "$bauordner"/*.bundle; do
    [ -d "$b" ] || continue
    cp -r "$b" "$TARGET/share/$PROGRAM/" || complain "Ressourcenbuendel liess sich nicht kopieren: $b"
    quiet "Buendel: $(basename "$b")"
    bundle=$((bundle + 1))
done
[ "$bundle" -gt 0 ] || complain "Der Bau hat kein Ressourcenbuendel hinterlassen ($bauordner)."

# **The count alone is not enough.** JellyfinKit ships its own bundle,
# containing `de.lproj` and `en.lproj` (the translations). Without it the
# app dies one level later, in `Textkatalog.bundle(bundle:sprache:)`.
for z in SwiftlyLinux JellyfinKit; do
    if [ ! -d "$TARGET/share/$PROGRAM/${z}_${z}.resources" ] &&
       [ ! -d "$TARGET/share/$PROGRAM/${z}_${z}.bundle" ]; then
        complain "Ressourcenbuendel fehlt: ${z}_${z} — nachsehen in $bauordner."
    fi
done

rm -rf "$TARGET/share/$PROGRAM/Resources"
cp -r "$source/Linux/Resources" "$TARGET/share/$PROGRAM/Resources"
ln -sf "$TARGET/share/$PROGRAM/$PROGRAM" "$TARGET/bin/$PROGRAM"

for grad in 32 64 128 256 512; do
    image="$source/Linux/Resources/icons/hicolor/${grad}x${grad}/apps/$ID.png"
    [ -f "$image" ] || continue
    mkdir -p "$TARGET/share/icons/hicolor/${grad}x${grad}/apps"
    install -m644 "$image" "$TARGET/share/icons/hicolor/${grad}x${grad}/apps/$ID.png"
done

install -m644 "$source/Linux/Install/$ID.desktop" "$TARGET/share/applications/"
[ -f "$source/Linux/Install/$ID.metainfo.xml" ] &&
    install -m644 "$source/Linux/Install/$ID.metainfo.xml" "$TARGET/share/metainfo/"

command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$TARGET/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -qtf "$TARGET/share/icons/hicolor" 2>/dev/null || true

say "Fertig."
echo
quiet "Im Anwendungsmenue steht jetzt „Swiftly\"."
quiet "Aus der Konsole: $PROGRAM"
case ":$PATH:" in
    *":$TARGET/bin:"*) ;;
    *) echo
       printf '    %s~/.local/bin liegt nicht in deinem PATH. Einmal:%s\n' "$bold" "$reset"
       printf '    echo '"'"'export PATH="$HOME/.local/bin:$PATH"'"'"' >> ~/.bashrc\n' ;;
esac
echo
quiet "Entfernen: dieses Skript nochmal aufrufen, mit --deinstallieren."

}

main "$@"
