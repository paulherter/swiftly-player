#!/usr/bin/env bash
#
# Packages a finished build into a pacman package.
#
#     pacman-package.sh <version> <build dir> <output dir> [pkgrel]
#
# `pkgrel` is normally 1. Raise it when the same version has to be repackaged
# because the package was wrong, not the program; pacman then sees 1.0.3-2
# as an update to 1.0.3-1.
#
# **Why not the PKGBUILD next to it:** that one builds from source, for people
# who run `makepkg -si`. This script only packs an already finished build for
# the package repository.
#
# makepkg refuses to run as root, hence the detour via a dedicated user. The
# build machine has one; on a normal machine the script runs as a normal user.

set -euo pipefail

version="${1:?Fassung fehlt}"
build="${2:?Bauverzeichnis fehlt}"
out="${3:?Ausgabeverzeichnis fehlt}"
state="${4:-1}"
source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROGRAM="swiftly-jellyfin"
ID="de.paulherter.swiftly"
work="$(mktemp -d)"
mkdir -p "$out" "$work/inhalt"

cp "$build/SwiftlyLinux" "$work/inhalt/$PROGRAM"
strip "$work/inhalt/$PROGRAM" 2>/dev/null || true
# **Accept both bundle names, and fail without a bundle.** Up to Swift 6.3,
# SwiftPM names a resource bundle `<target>_<target>.resources`, from 6.4 on
# `<target>_<target>.bundle`; the generated `Bundle.module` accessor looks for
# exactly the name it was built with. A hard-coded `*.resources` pattern plus
# `[ -d ] && cp` silently matched nothing on 6.4 and produced a package without
# any bundle, which then crashed at startup ("unable to find bundle named
# SwiftlyLinux_SwiftlyLinux").
count=0
for bundle in "$build"/*.resources "$build"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -r "$bundle" "$work/inhalt/"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "Kein Ressourcenbuendel in $build" >&2; exit 1; }
# The JellyfinKit bundle carries `de.lproj` and `en.lproj`, the package's
# translations; without it the app dies later in
# `Textkatalog.bundle(bundle:sprache:)`.
for z in SwiftlyLinux JellyfinKit; do
    [ -d "$work/inhalt/${z}_${z}.resources" ] || [ -d "$work/inhalt/${z}_${z}.bundle" ] ||
        { echo "Ressourcenbuendel fehlt: ${z}_${z} — nachsehen in $build" >&2; exit 1; }
done
cp "$source/Linux/Install/$ID.desktop" \
   "$source/Linux/Install/$ID.metainfo.xml" "$work/inhalt/"
cp -r "$source/Linux/Resources/icons" "$work/inhalt/icons"
cp -r "$source/Linux/Resources" "$work/inhalt/Resources"
cp "$source/LICENSE" "$work/inhalt/LICENSE"
# **Licenses from a single source.** `LICENSES/` holds the full texts and
# `components.json`; `THIRD-PARTY-NOTICES.md` holds the written offer for
# libVLC (LGPL-2.1-or-later). If either is missing, no package is built.
[ -f "$source/LICENSES/components.json" ] && [ -f "$source/THIRD-PARTY-NOTICES.md" ] ||
    { echo "LICENSES/ oder THIRD-PARTY-NOTICES.md fehlt in $source" >&2; exit 1; }
cp -r "$source/LICENSES" "$work/inhalt/LICENSES"
cp "$source/THIRD-PARTY-NOTICES.md" "$work/inhalt/THIRD-PARTY-NOTICES.md"

cat > "$work/PKGBUILD" <<PKG
pkgname=$PROGRAM
pkgver=$version
pkgrel=$state
pkgdesc="Jellyfin client that never transcodes"
arch=('x86_64')
url="https://github.com/paulherter/swiftly-player"
license=('MPL-2.0')
depends=('gtk4' 'vlc' 'glibc' 'gcc-libs')
options=('!strip' '!debug')

package() {
    install -Dm755 "\$startdir/inhalt/$PROGRAM" "\$pkgdir/usr/lib/$PROGRAM/$PROGRAM"
    for bundle in "\$startdir/inhalt"/*.resources "\$startdir/inhalt"/*.bundle; do
        [ -d "\$buendel" ] && cp -r "\$buendel" "\$pkgdir/usr/lib/$PROGRAM/"
    done
    cp -r "\$startdir/inhalt/Resources" "\$pkgdir/usr/lib/$PROGRAM/Resources"
    install -d "\$pkgdir/usr/bin"
    ln -s "/usr/lib/$PROGRAM/$PROGRAM" "\$pkgdir/usr/bin/$PROGRAM"

    install -Dm644 "\$startdir/inhalt/$ID.desktop" \\
        "\$pkgdir/usr/share/applications/$ID.desktop"
    install -Dm644 "\$startdir/inhalt/$ID.metainfo.xml" \\
        "\$pkgdir/usr/share/metainfo/$ID.metainfo.xml"
    for grad in 32 64 128 256 512; do
        install -Dm644 "\$startdir/inhalt/icons/hicolor/\${grad}x\${grad}/apps/$ID.png" \\
            "\$pkgdir/usr/share/icons/hicolor/\${grad}x\${grad}/apps/$ID.png"
    done
    install -Dm644 "\$startdir/inhalt/LICENSE" "\$pkgdir/usr/share/licenses/$PROGRAM/LICENSE"
    install -Dm644 "\$startdir/inhalt/THIRD-PARTY-NOTICES.md" \\
        "\$pkgdir/usr/share/licenses/$PROGRAM/THIRD-PARTY-NOTICES.md"
    # All full texts, including LGPL-2.1-or-later.txt; the app reads the same
    # files from Resources/Licenses.
    for t in "\$startdir/inhalt/LICENSES"/*; do
        install -Dm644 "\$t" "\$pkgdir/usr/share/licenses/$PROGRAM/LICENSES/\$(basename "\$t")"
        install -Dm644 "\$t" "\$pkgdir/usr/lib/$PROGRAM/Resources/Licenses/\$(basename "\$t")"
    done
}
PKG

if [ "$(id -u)" = "0" ]; then
    id bauer >/dev/null 2>&1 || useradd -m bauer
    chown -R bauer "$work"
    su bauer -c "cd '$work' && makepkg -f --nodeps --noconfirm"
else
    ( cd "$work" && makepkg -f --nodeps --noconfirm )
fi

cp "$work"/*.pkg.tar.zst "$out/"
rm -rf "$work"
ls -1sh "$out"
