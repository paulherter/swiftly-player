#!/usr/bin/env bash
#
# Swiftly for Jellyfin — Installation auf Linux.
#
#     curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-for-jellyfin/main/Linux/Installieren/swiftly-installieren.sh | bash
#
# **Es wird eine Paketquelle eingetragen, nicht nur installiert.** Ein Bau
# von Hand ist einmalig — danach weiss kein Paketverwalter, dass es die App
# gibt, und es kommt nie wieder ein Update. Deshalb legt dieses Skript die
# Quelle an, aus der apt, dnf, zypper oder pacman die App holen. Ab da
# kommen neue Fassungen mit dem normalen Systemupdate, wie bei jedem
# anderen Programm.
#
# Wer trotzdem selbst bauen will: `--aus-quelle`. Das dauert ein paar
# Minuten und laeuft auch auf Distributionen, fuer die es kein Paket gibt.
#
# Alles landet unter $HOME. Das Passwort wird genau einmal gebraucht, fuer
# die Pakete der Distribution — und die Abfrage kommt vom Paketverwalter
# selbst, nicht von diesem Skript.

set -euo pipefail

# Alles in einer Funktion: laedt curl das Skript nur halb herunter, wird
# nichts ausgefuehrt statt der Haelfte.
main() {

ZWEIG="${SWIFTLY_ZWEIG:-main}"
HERKUNFT="${SWIFTLY_HERKUNFT:-https://github.com/paulherter/swiftly-for-jellyfin.git}"
ARBEIT="${XDG_CACHE_HOME:-$HOME/.cache}/swiftly-jellyfin"
ZIEL="$HOME/.local"
# **Nicht `NAME`.** `/etc/os-release` setzt selbst ein `NAME`, und das wird
# hier gleich eingelesen. Im ersten Testlauf hiess die App danach
# „CachyOS Linux" und landete in einem Verzeichnis mit Leerzeichen.
PROGRAMM="swiftly-jellyfin"
KENNUNG="de.paulherter.swiftly"
QUELLE_URL="${SWIFTLY_QUELLE:-https://paulherter.github.io/swiftly-for-jellyfin}"
# Der Fingerabdruck steht hier fest, nicht nur der Schluesselring: so wird
# geprueft, dass der heruntergeladene Schluessel auch der erwartete ist.
FINGERABDRUCK="705D676A71BF0121804A90BAC8589885A042FB8B"

rot=''; gruen=''; fett=''; blass=''; aus=''
if [ -t 1 ]; then
    rot=$'\033[31m'; gruen=$'\033[32m'; fett=$'\033[1m'; blass=$'\033[2m'; aus=$'\033[0m'
fi
sagen()   { printf '%s==>%s %s\n' "$gruen$fett" "$aus$fett" "$1$aus"; }
leise()   { printf '    %s%s%s\n' "$blass" "$1" "$aus"; }
klagen()  { printf '%sFehler:%s %s\n' "$rot$fett" "$aus" "$1" >&2; exit 1; }

# ---------------------------------------------------------------- Abbau

aus_quelle=0
[ "${1:-}" = "--aus-quelle" ] && aus_quelle=1

if [ "${1:-}" = "--deinstallieren" ] || [ "${1:-}" = "--entfernen" ]; then
    sagen "Swiftly for Jellyfin entfernen"
    rm -rf "$ZIEL/share/$PROGRAMM" "$ZIEL/bin/$PROGRAMM" \
           "$ZIEL/share/applications/$KENNUNG.desktop" \
           "$ZIEL/share/metainfo/$KENNUNG.metainfo.xml" "$ARBEIT"
    find "$ZIEL/share/icons/hicolor" -name "$KENNUNG.png" -delete 2>/dev/null || true
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$ZIEL/share/applications" 2>/dev/null || true
    leise "Die Einstellungen unter ~/.config/swiftly bleiben liegen."
    leise "Weg damit: rm -rf ~/.config/swiftly"
    sagen "Entfernt."
    return 0
fi

# ---------------------------------------------------------- Distribution
#
# `ID_LIKE` ist der Grund, warum die Liste kurz bleiben darf: Mint sagt
# „ubuntu debian", Nobara sagt „fedora", CachyOS sagt „arch". Erst wenn
# beides nichts trifft, muss jemand von Hand ran.

[ -r /etc/os-release ] || klagen "/etc/os-release fehlt — welche Distribution ist das?"
# shellcheck disable=SC1091
. /etc/os-release
sippe=""
for kandidat in $ID ${ID_LIKE:-}; do
    case "$kandidat" in
        arch|archarm)                          sippe=arch;   break ;;
        debian|ubuntu)                         sippe=debian; break ;;
        fedora|rhel|centos)                    sippe=fedora; break ;;
        suse|opensuse|opensuse-tumbleweed)     sippe=suse;   break ;;
        alpine)                                sippe=alpine; break ;;
    esac
done
[ -n "$sippe" ] || klagen "Unbekannte Distribution: ${PRETTY_NAME:-$ID}
Gebraucht werden GTK 4, libVLC, git, ein C++-Uebersetzer und pkg-config.
Sind die da, laeuft der Rest dieses Skripts mit SWIFTLY_PAKETE_UEBERSPRINGEN=1."

sagen "Swiftly for Jellyfin — Installation"
leise "${PRETTY_NAME:-$ID}, erkannt als $sippe, $(uname -m)"

if [ "$(uname -m)" != "x86_64" ] && [ "$(uname -m)" != "aarch64" ]; then
    klagen "Swift gibt es fuer x86_64 und aarch64. Diese Kiste ist $(uname -m)."
fi

# --------------------------------------------------------------- Pakete
#
# Zwei Sorten in einer Liste: was die App zum Laufen braucht (GTK, VLC) und
# was Swift zum Uebersetzen braucht (curl, ncurses, sqlite ...). Getrennt
# haette es keinen Wert — wer baut, braucht beides.

sudo_ruf=""
if [ "$(id -u)" != "0" ]; then
    command -v sudo >/dev/null 2>&1 || klagen "sudo fehlt, und ich bin nicht root."
    sudo_ruf="sudo"
fi

# ---------------------------------------------------------- Paketquelle
#
# Der uebliche Weg. Eine Zeile in der Konfiguration des Paketverwalters,
# danach gehoert die App zum System wie jedes andere Paket — samt Updates.
#
# **Signatur, wenn es eine gibt.** Liegt in der Quelle ein oeffentlicher
# Schluessel, wird er eingetragen und geprueft. Liegt keiner da, wird die
# Quelle als vertrauenswuerdig eingetragen und das hier gesagt — lieber
# offen als eine Zeile, die niemand versteht.

signiert=0
if curl -fsI "$QUELLE_URL/swiftly.gpg" >/dev/null 2>&1; then signiert=1; fi

quelle_eintragen() {
    case "$sippe" in
        debian)
            if [ "$signiert" = "1" ]; then
                $sudo_ruf install -d -m755 /etc/apt/keyrings
                curl -fsSL "$QUELLE_URL/swiftly.gpg" |
                    $sudo_ruf tee /etc/apt/keyrings/swiftly.asc >/dev/null
                echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/swiftly.asc] $QUELLE_URL/deb ./" |
                    $sudo_ruf tee /etc/apt/sources.list.d/swiftly.list >/dev/null
            else
                echo "deb [arch=amd64 trusted=yes] $QUELLE_URL/deb ./" |
                    $sudo_ruf tee /etc/apt/sources.list.d/swiftly.list >/dev/null
            fi
            $sudo_ruf apt-get update
            $sudo_ruf apt-get install -y "$PROGRAMM"
            ;;
        fedora)
            $sudo_ruf tee /etc/yum.repos.d/swiftly.repo >/dev/null <<EOF
[swiftly]
name=Swiftly for Jellyfin
baseurl=$QUELLE_URL/rpm
enabled=1
gpgcheck=$signiert
$([ "$signiert" = "1" ] && echo "gpgkey=$QUELLE_URL/swiftly.gpg")
EOF
            $sudo_ruf dnf install -y "$PROGRAMM"
            ;;
        suse)
            $sudo_ruf zypper --non-interactive removerepo swiftly >/dev/null 2>&1 || true
            $sudo_ruf zypper --non-interactive addrepo -f "$QUELLE_URL/rpm" swiftly
            [ "$signiert" = "1" ] || $sudo_ruf zypper --non-interactive modifyrepo --no-gpgcheck swiftly
            $sudo_ruf zypper --non-interactive --gpg-auto-import-keys refresh swiftly
            $sudo_ruf zypper --non-interactive install "$PROGRAMM"
            ;;
        arch)
            local stufe="Optional TrustAll"
            if [ "$signiert" = "1" ]; then
                stufe="Required DatabaseOptional"
                # pacman fuehrt einen eigenen Schluesselbund. Ein Schluessel
                # darin reicht nicht — er muss oertlich unterschrieben sein,
                # sonst gilt er als unbekannt und die Installation bricht ab.
                curl -fsSL "$QUELLE_URL/swiftly.gpg" | $sudo_ruf pacman-key --add -
                $sudo_ruf pacman-key --lsign-key "$FINGERABDRUCK"
            fi
            if ! grep -q '^\[swiftly\]' /etc/pacman.conf; then
                printf '\n[swiftly]\nSigLevel = %s\nServer = %s/arch\n' \
                    "$stufe" "$QUELLE_URL" | $sudo_ruf tee -a /etc/pacman.conf >/dev/null
            fi
            $sudo_ruf pacman -Sy --noconfirm "$PROGRAMM"
            ;;
        *)  return 1 ;;
    esac
}

if [ "${aus_quelle:-0}" = "0" ]; then
    sagen "Paketquelle eintragen"
    [ "$signiert" = "1" ] ||
        leise "Die Quelle ist noch nicht signiert — sie wird als vertrauenswuerdig eingetragen."
    leise "Dafuer fragt der Paketverwalter gleich nach deinem Passwort."
    if quelle_eintragen; then
        sagen "Fertig."
        echo
        leise "Im Anwendungsmenue steht jetzt „Swiftly\"."
        leise "Aus der Konsole: $PROGRAMM"
        leise "Updates kommen ab jetzt mit dem normalen Systemupdate."
        echo
        leise "Entfernen: ueber den Paketverwalter, wie jedes andere Paket."
        return 0
    fi
    leise "Kein Paket fuer diese Distribution — es wird aus der Quelle gebaut."
fi

pakete_setzen() {
    case "$sippe" in
        arch)
            $sudo_ruf pacman -S --needed --noconfirm \
                gtk4 vlc git gcc pkgconf curl unzip which
            ;;
        debian)
            $sudo_ruf apt-get update
            $sudo_ruf apt-get install -y --no-install-recommends \
                libgtk-4-dev libvlc-dev vlc-plugin-base \
                git g++ pkg-config curl ca-certificates \
                binutils libcurl4-openssl-dev libedit2 libncurses-dev \
                libpython3-dev libsqlite3-0 libxml2-dev libz3-dev zlib1g-dev tzdata
            ;;
        fedora)
            # VLC liegt bei Fedora nicht in den eigenen Quellen, sondern bei
            # RPM Fusion. Ohne das schlaegt die Installation an genau einem
            # Paket fehl — deshalb wird es vorher angeboten.
            if ! $sudo_ruf dnf list --available vlc-devel >/dev/null 2>&1 &&
               ! rpm -q vlc-devel >/dev/null 2>&1; then
                leise "libVLC liegt bei Fedora in RPM Fusion. Wird jetzt eingerichtet."
                $sudo_ruf dnf install -y --nogpgcheck \
                    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" || true
            fi
            $sudo_ruf dnf install -y \
                gtk4-devel vlc-devel git gcc-c++ pkgconf-pkg-config curl \
                libcurl-devel libedit-devel libicu-devel libuuid-devel \
                libxml2-devel python3-devel sqlite ncurses-devel
            ;;
        suse)
            $sudo_ruf zypper --non-interactive install \
                gtk4-devel vlc-devel git gcc-c++ pkg-config curl \
                libcurl-devel libxml2-devel sqlite3 ncurses-devel || {
                    klagen "Bei openSUSE liegt VLC im Packman-Verzeichnis.
Einmal einrichten, dann das Skript nochmal:
  sudo zypper ar -cfp 90 https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/ packman
  sudo zypper dup --from packman --allow-vendor-change"
                }
            ;;
        alpine)
            klagen "Alpine nutzt musl, Swift braucht glibc. Das geht (noch) nicht."
            ;;
    esac
}

if [ "${SWIFTLY_PAKETE_UEBERSPRINGEN:-0}" = "1" ]; then
    leise "Pakete uebersprungen (SWIFTLY_PAKETE_UEBERSPRINGEN=1)."
else
    sagen "Pakete der Distribution"
    leise "Dafuer fragt der Paketverwalter gleich nach deinem Passwort."
    pakete_setzen
fi

# ---------------------------------------------------------------- Swift

sagen "Swift"
export PATH="$HOME/.local/share/swiftly/bin:$PATH"
brauche_swift=1
if command -v swift >/dev/null 2>&1; then
    fassung=$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -1 | awk '{print $3}' || true)
    haupt=${fassung%%.*}
    if [ -n "$fassung" ] && [ "${haupt:-0}" -ge 6 ]; then
        leise "Swift $fassung ist da."
        brauche_swift=0
    fi
fi

if [ "$brauche_swift" = "1" ]; then
    leise "Wird ueber swiftly von swift.org geholt — komplett unter \$HOME, ohne Passwort."
    mkdir -p "$ARBEIT"
    ( cd "$ARBEIT"
      curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
      tar -xzf "swiftly-$(uname -m).tar.gz" )
    "$ARBEIT/swiftly" init --quiet-shell-followup --assume-yes --skip-install
    # Nicht ueber env.sh: die Datei legt swiftly je nach Fassung woanders
    # oder gar nicht an, und ein `.` auf eine fehlende Datei bricht mit
    # `set -e` den ganzen Lauf ab. Der Pfad reicht.
    export PATH="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/bin:$PATH"
    swiftly install --use latest
    command -v swift >/dev/null 2>&1 || klagen "Swift ist nach der Installation nicht im PATH."
fi

# --------------------------------------------------------------- Quelle

sagen "Quelltext"
if [ -f "$PWD/Linux/Package.swift" ]; then
    quelle="$PWD"
    leise "Aus dem Verzeichnis, in dem du stehst."
elif [ -d "$ARBEIT/quelle/.git" ]; then
    quelle="$ARBEIT/quelle"
    git -C "$quelle" fetch --depth 1 origin "$ZWEIG"
    git -C "$quelle" reset --hard "origin/$ZWEIG"
    leise "Vorhandenen Auscheck nachgezogen."
else
    quelle="$ARBEIT/quelle"
    mkdir -p "$ARBEIT"
    git clone --depth 1 --branch "$ZWEIG" "$HERKUNFT" "$quelle"
fi

# -------------------------------------------------------------- rlottie
#
# Die Startanimation. Gibt es in keiner Paketquelle, braucht aber auch kein
# cmake — ein Uebersetzeraufruf reicht, und gebunden wird sie statisch.

sagen "rlottie (Startanimation)"
export SWIFTLY_RLOTTIE_ZIEL="$ARBEIT/rlottie-praefix"
if [ -f "$SWIFTLY_RLOTTIE_ZIEL/lib/librlottie.a" ]; then
    leise "Liegt schon gebaut da."
else
    bash "$quelle/Werkzeuge/rlottie-bauen.sh" "$ARBEIT/rlottie-quelle" >/dev/null
    leise "Gebaut."
fi
export PKG_CONFIG_PATH="$SWIFTLY_RLOTTIE_ZIEL/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ----------------------------------------------------------------- Bauen
#
# `-static-stdlib` bindet Swifts eigene Laufzeit mit ins Programm. Ohne das
# muesste die halbe Toolchain mitinstalliert bleiben, damit die App startet.

sagen "Swiftly bauen"
leise "Das dauert beim ersten Mal ein paar Minuten."
( cd "$quelle/Linux" && swift build -c release -Xswiftc -static-stdlib )
binaer="$quelle/Linux/.build/release/SwiftlyLinux"
[ -x "$binaer" ] || klagen "Der Bau hat kein Programm hinterlassen."

# ------------------------------------------------------------ Einraeumen
#
# Programm und Ressourcenbuendel muessen nebeneinander liegen — Swift findet
# `Bundle.module` ueber den eigenen Pfad. Deshalb wandert beides nach
# share/, und in bin/ steht nur ein Verweis.

sagen "Einraeumen"
mkdir -p "$ZIEL/bin" "$ZIEL/share/$PROGRAMM" "$ZIEL/share/applications" "$ZIEL/share/metainfo"
install -m755 "$binaer" "$ZIEL/share/$PROGRAMM/$PROGRAMM"
strip "$ZIEL/share/$PROGRAMM/$PROGRAMM" 2>/dev/null || true
rm -rf "$ZIEL/share/$PROGRAMM"/*.resources
cp -r "$quelle/Linux/.build/release"/*.resources "$ZIEL/share/$PROGRAMM/" 2>/dev/null || true
ln -sf "$ZIEL/share/$PROGRAMM/$PROGRAMM" "$ZIEL/bin/$PROGRAMM"

for grad in 32 64 128 256 512; do
    bild="$quelle/Linux/Ressourcen/icons/hicolor/${grad}x${grad}/apps/$KENNUNG.png"
    [ -f "$bild" ] || continue
    mkdir -p "$ZIEL/share/icons/hicolor/${grad}x${grad}/apps"
    install -m644 "$bild" "$ZIEL/share/icons/hicolor/${grad}x${grad}/apps/$KENNUNG.png"
done

install -m644 "$quelle/Linux/Installieren/$KENNUNG.desktop" "$ZIEL/share/applications/"
[ -f "$quelle/Linux/Installieren/$KENNUNG.metainfo.xml" ] &&
    install -m644 "$quelle/Linux/Installieren/$KENNUNG.metainfo.xml" "$ZIEL/share/metainfo/"

command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$ZIEL/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -qtf "$ZIEL/share/icons/hicolor" 2>/dev/null || true

sagen "Fertig."
echo
leise "Im Anwendungsmenue steht jetzt „Swiftly\"."
leise "Aus der Konsole: $PROGRAMM"
case ":$PATH:" in
    *":$ZIEL/bin:"*) ;;
    *) echo
       printf '    %s~/.local/bin liegt nicht in deinem PATH. Einmal:%s\n' "$fett" "$aus"
       printf '    echo '"'"'export PATH="$HOME/.local/bin:$PATH"'"'"' >> ~/.bashrc\n' ;;
esac
echo
leise "Entfernen: dieses Skript nochmal aufrufen, mit --deinstallieren."

}

main "$@"
