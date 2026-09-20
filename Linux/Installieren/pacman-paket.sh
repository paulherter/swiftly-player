#!/usr/bin/env bash
#
# Schnuert aus einem fertigen Bau ein pacman-Paket.
#
#     pacman-paket.sh <Fassung> <Bauverzeichnis> <Ausgabeverzeichnis> [Paketstand]
#
# Der Paketstand (`pkgrel`) ist normalerweise 1. Er wird hochgezaehlt, wenn
# dieselbe Fassung neu geschnuert werden muss, weil am Paket etwas falsch war
# und nicht am Programm — pacman sieht 1.0.3-2 dann als Update zu 1.0.3-1.
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
stand="${4:-2}"
quelle="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROGRAMM="swiftly-jellyfin"
KENNUNG="de.paulherter.swiftly"
werk="$(mktemp -d)"
mkdir -p "$raus" "$werk/inhalt"

cp "$bau/SwiftlyLinux" "$werk/inhalt/$PROGRAMM"
strip "$werk/inhalt/$PROGRAMM" 2>/dev/null || true
# **Beide Namen, und ohne Buendel kein Paket.** Bis Swift 6.3 legt SwiftPM
# ein Buendel als `<Ziel>_<Ziel>.resources` ab, ab 6.4 als
# `<Ziel>_<Ziel>.bundle` — der erzeugte `Bundle.module`-Zugriff sucht
# genau den Namen, unter dem gebaut wurde. Hier stand `*.resources` fest,
# und `[ -d ] && cp` schwieg, wenn das Muster nichts traf: die
# Paketstrecke zog auf `swiftly install --use latest` eine 6.4, schnuerte
# ein Paket ganz ohne Buendel und meldete Erfolg. Die 1.0.3 starb beim
# Start an „unable to find bundle named SwiftlyLinux_SwiftlyLinux" —
# gemeldet am 20.09.2026 von einem Tester auf CachyOS.
anzahl=0
for buendel in "$bau"/*.resources "$bau"/*.bundle; do
    [ -d "$buendel" ] || continue
    cp -r "$buendel" "$werk/inhalt/"
    anzahl=$((anzahl + 1))
done
[ "$anzahl" -gt 0 ] || { echo "Kein Ressourcenbuendel in $bau" >&2; exit 1; }
# JellyfinKits Buendel traegt `de.lproj` und `en.lproj`, also die
# Uebersetzungen des Pakets; fehlt es, stirbt die App eine Ebene spaeter
# in `Textkatalog.bundle(bundle:sprache:)`.
for z in SwiftlyLinux JellyfinKit; do
    [ -d "$werk/inhalt/${z}_${z}.resources" ] || [ -d "$werk/inhalt/${z}_${z}.bundle" ] ||
        { echo "Ressourcenbuendel fehlt: ${z}_${z} — nachsehen in $bau" >&2; exit 1; }
done
cp "$quelle/Linux/Installieren/$KENNUNG.desktop" \
   "$quelle/Linux/Installieren/$KENNUNG.metainfo.xml" "$werk/inhalt/"
cp -r "$quelle/Linux/Ressourcen/icons" "$werk/inhalt/icons"
cp -r "$quelle/Linux/Ressourcen" "$werk/inhalt/Ressourcen"
cp "$quelle/LICENSE" "$werk/inhalt/LICENSE"

cat > "$werk/PKGBUILD" <<PKG
pkgname=$PROGRAMM
pkgver=$fassung
pkgrel=$stand
pkgdesc="Jellyfin client that never transcodes"
arch=('x86_64')
url="https://github.com/paulherter/swiftly-player"
license=('MPL-2.0')
depends=('gtk4' 'vlc' 'glibc' 'gcc-libs')
options=('!strip' '!debug')

package() {
    install -Dm755 "\$startdir/inhalt/$PROGRAMM" "\$pkgdir/usr/lib/$PROGRAMM/$PROGRAMM"
    for buendel in "\$startdir/inhalt"/*.resources "\$startdir/inhalt"/*.bundle; do
        [ -d "\$buendel" ] && cp -r "\$buendel" "\$pkgdir/usr/lib/$PROGRAMM/"
    done
    cp -r "\$startdir/inhalt/Ressourcen" "\$pkgdir/usr/lib/$PROGRAMM/Ressourcen"
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
