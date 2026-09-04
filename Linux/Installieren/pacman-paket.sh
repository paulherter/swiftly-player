#!/usr/bin/env bash
#
# Schnuert aus einem fertigen Bau ein pacman-Paket.
#
#     pacman-paket.sh <Fassung> <Bauverzeichnis> <Ausgabeverzeichnis>
#
# **Warum nicht das PKGBUILD daneben.** Das PKGBUILD in diesem Verzeichnis
# baut aus der Quelle — fuer Leute, die `makepkg -si` tippen wollen. Hier
# geht es um das fertige Paket fuer die Paketquelle: der Bau ist schon
# gelaufen, es wird nur noch eingepackt.
#
# makepkg weigert sich als root, deshalb der Umweg ueber einen eigenen
# Nutzer. In der Baumaschine ist der angelegt; auf einem normalen Rechner
# laeuft das Skript ohnehin als normaler Nutzer.

set -euo pipefail

fassung="${1:?Fassung fehlt}"
bau="${2:?Bauverzeichnis fehlt}"
raus="${3:?Ausgabeverzeichnis fehlt}"
quelle="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROGRAMM="swiftly-jellyfin"
KENNUNG="de.paulherter.swiftly"
werk="$(mktemp -d)"
mkdir -p "$raus" "$werk/inhalt"

cp "$bau/SwiftlyLinux" "$werk/inhalt/$PROGRAMM"
strip "$werk/inhalt/$PROGRAMM" 2>/dev/null || true
for buendel in "$bau"/*.resources; do
    [ -d "$buendel" ] && cp -r "$buendel" "$werk/inhalt/"
done
cp "$quelle/Linux/Installieren/$KENNUNG.desktop" \
   "$quelle/Linux/Installieren/$KENNUNG.metainfo.xml" "$werk/inhalt/"
cp -r "$quelle/Linux/Ressourcen/icons" "$werk/inhalt/icons"
cp "$quelle/LICENSE" "$werk/inhalt/LICENSE"

cat > "$werk/PKGBUILD" <<PKG
pkgname=$PROGRAMM
pkgver=$fassung
pkgrel=1
pkgdesc="Jellyfin client that never transcodes"
arch=('x86_64')
url="https://github.com/paulherter/swiftly-for-jellyfin"
license=('MPL-2.0')
depends=('gtk4' 'vlc' 'glibc' 'gcc-libs')
options=('!strip' '!debug')

package() {
    install -Dm755 "\$startdir/inhalt/$PROGRAMM" "\$pkgdir/usr/lib/$PROGRAMM/$PROGRAMM"
    for buendel in "\$startdir/inhalt"/*.resources; do
        [ -d "\$buendel" ] && cp -r "\$buendel" "\$pkgdir/usr/lib/$PROGRAMM/"
    done
    install -d "\$pkgdir/usr/bin"
    ln -s "/usr/lib/$PROGRAMM/$PROGRAMM" "\$pkgdir/usr/bin/$PROGRAMM"

    install -Dm644 "\$startdir/inhalt/$KENNUNG.desktop" \\
        "\$pkgdir/usr/share/applications/$KENNUNG.desktop"
    install -Dm644 "\$startdir/inhalt/$KENNUNG.metainfo.xml" \\
        "\$pkgdir/usr/share/metainfo/$KENNUNG.metainfo.xml"
    for grad in 32 64 128 256 512; do
        install -Dm644 "\$startdir/inhalt/icons/hicolor/\${grad}x\${grad}/apps/$KENNUNG.png" \\
            "\$pkgdir/usr/share/icons/hicolor/\${grad}x\${grad}/apps/$KENNUNG.png"
    done
    install -Dm644 "\$startdir/inhalt/LICENSE" "\$pkgdir/usr/share/licenses/$PROGRAMM/LICENSE"
}
PKG

if [ "$(id -u)" = "0" ]; then
    id bauer >/dev/null 2>&1 || useradd -m bauer
    chown -R bauer "$werk"
    su bauer -c "cd '$werk' && makepkg -f --nodeps --noconfirm"
else
    ( cd "$werk" && makepkg -f --nodeps --noconfirm )
fi

cp "$werk"/*.pkg.tar.zst "$raus/"
rm -rf "$werk"
ls -1sh "$raus"
