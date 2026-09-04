#!/usr/bin/env bash
#
# Baut aus einem fertigen Bau ein .deb, ein .rpm und einen Tarball.
#
#     paket-bauen.sh <Fassung> <Bauverzeichnis> <Ausgabeverzeichnis>
#
# Laeuft in der Baumaschine, nicht beim Nutzer. Was hier entsteht, landet in
# der Paketquelle — und von dort holt es der Paketverwalter des Nutzers beim
# naechsten `apt upgrade` von selbst.

set -euo pipefail

fassung="${1:?Fassung fehlt}"
bau="${2:?Bauverzeichnis fehlt}"
raus="${3:?Ausgabeverzeichnis fehlt}"
quelle="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROGRAMM="swiftly-jellyfin"
KENNUNG="de.paulherter.swiftly"
mkdir -p "$raus"

# ------------------------------------------------------------ Gemeinsames
#
# Programm und Ressourcenbuendel bleiben beisammen — Swift findet
# `Bundle.module` ueber den Pfad der laufenden Datei. Deshalb liegt beides
# in /usr/lib, und /usr/bin traegt nur einen Verweis.

baum_fuellen() {
    local w="$1"
    install -Dm755 "$bau/SwiftlyLinux" "$w/usr/lib/$PROGRAMM/$PROGRAMM"
    strip "$w/usr/lib/$PROGRAMM/$PROGRAMM" 2>/dev/null || true
    for buendel in "$bau"/*.resources; do
        [ -d "$buendel" ] && cp -r "$buendel" "$w/usr/lib/$PROGRAMM/"
    done
    install -d "$w/usr/bin"
    ln -sf "/usr/lib/$PROGRAMM/$PROGRAMM" "$w/usr/bin/$PROGRAMM"

    install -Dm644 "$quelle/Linux/Installieren/$KENNUNG.desktop" \
        "$w/usr/share/applications/$KENNUNG.desktop"
    install -Dm644 "$quelle/Linux/Installieren/$KENNUNG.metainfo.xml" \
        "$w/usr/share/metainfo/$KENNUNG.metainfo.xml"
    for grad in 32 64 128 256 512; do
        install -Dm644 \
            "$quelle/Linux/Ressourcen/icons/hicolor/${grad}x${grad}/apps/$KENNUNG.png" \
            "$w/usr/share/icons/hicolor/${grad}x${grad}/apps/$KENNUNG.png"
    done
    install -Dm644 "$quelle/LICENSE" "$w/usr/share/doc/$PROGRAMM/LICENSE"
}

# ------------------------------------------------------------------- .deb

sagen() { printf '==> %s\n' "$1"; }

sagen "deb"
deb="$(mktemp -d)"
baum_fuellen "$deb"
mkdir -p "$deb/DEBIAN"
groesse=$(du -sk "$deb" | cut -f1)
cat > "$deb/DEBIAN/control" <<EOF
Package: $PROGRAMM
Version: $fassung
Section: video
Priority: optional
Architecture: amd64
Depends: libgtk-4-1 (>= 4.14), libvlc5 | libvlc-bin, vlc-plugin-base, libc6 (>= 2.39)
Maintainer: Paul Herter <accounts@paulherter.de>
Installed-Size: $groesse
Homepage: https://github.com/paulherter/swiftly-for-jellyfin
Description: Jellyfin client that never transcodes
 Swiftly plays everything on your Jellyfin server as Direct Play or Direct
 Stream. The server never re-encodes, so the picture stays untouched and the
 machine stays quiet.
EOF
dpkg-deb --build --root-owner-group "$deb" "$raus/${PROGRAMM}_${fassung}_amd64.deb" >/dev/null
rm -rf "$deb"

# ------------------------------------------------------------------- .rpm

sagen "rpm"
rpmbaum="$(mktemp -d)"
mkdir -p "$rpmbaum"/{BUILD,RPMS,SOURCES,SPECS,BUILDROOT}
puffer="$rpmbaum/BUILDROOT/$PROGRAMM-$fassung-1.x86_64"
baum_fuellen "$puffer"
cat > "$rpmbaum/SPECS/$PROGRAMM.spec" <<EOF
Name:           $PROGRAMM
Version:        $fassung
Release:        1
Summary:        Jellyfin client that never transcodes
License:        MPL-2.0
URL:            https://github.com/paulherter/swiftly-for-jellyfin
BuildArch:      x86_64
Requires:       gtk4 >= 4.14
Requires:       vlc-libs
AutoReqProv:    no

%description
Swiftly plays everything on your Jellyfin server as Direct Play or Direct
Stream. The server never re-encodes, so the picture stays untouched and the
machine stays quiet.

%files
/usr/lib/$PROGRAMM
/usr/bin/$PROGRAMM
/usr/share/applications/$KENNUNG.desktop
/usr/share/metainfo/$KENNUNG.metainfo.xml
/usr/share/icons/hicolor/*/apps/$KENNUNG.png
/usr/share/doc/$PROGRAMM/LICENSE

%changelog
EOF
rpmbuild --define "_topdir $rpmbaum" --define "_build_id_links none" \
    -bb "$rpmbaum/SPECS/$PROGRAMM.spec" >/dev/null
cp "$rpmbaum"/RPMS/x86_64/*.rpm "$raus/"
rm -rf "$rpmbaum"

# ---------------------------------------------------------------- Tarball

sagen "tar.gz"
tarbaum="$(mktemp -d)/$PROGRAMM-$fassung"
mkdir -p "$tarbaum"
baum_fuellen "$tarbaum"
tar -czf "$raus/${PROGRAMM}-${fassung}-x86_64.tar.gz" -C "$(dirname "$tarbaum")" "$PROGRAMM-$fassung"
rm -rf "$(dirname "$tarbaum")"

sagen "fertig"
ls -1sh "$raus"
