#!/usr/bin/env bash
#
# Builds a .deb, a .rpm and a tarball from a finished build.
#
#     build-package.sh <version> <build-dir> <output-dir> [package-revision]
#
# The package revision is normally 1. If the same version is released again
# with a fix (build number in `Version.swift`), increase it; otherwise apt and
# dnf see no update: 1.0.4-2 is newer than 1.0.4, and for rpm `Release`
# counts. Same as `pacman-package.sh`.
#
# Runs on the build machine, not on the user's. The output goes into the
# package repository, from where the user's package manager fetches it on the
# next `apt upgrade`.

set -euo pipefail

version="${1:?Fassung fehlt}"
build="${2:?Bauverzeichnis fehlt}"
out="${3:?Ausgabeverzeichnis fehlt}"
state="${4:-1}"
# For the first revision the deb stays unchanged.
if [ "$state" = "1" ]; then debVersion="$version"; else debVersion="$version-$state"; fi
source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROGRAM="swiftly-jellyfin"
ID="de.paulherter.swiftly"
mkdir -p "$out"

# **Only a build with the Swift runtime inside.** The user has no Swift
# installed. A plain `swift build` (instead of `-Xswiftc -static-stdlib`)
# links against libswiftCore.so with a RUNPATH into the build machine's
# toolchain; the package installs fine and the program does not start.
if readelf -d "$build/SwiftlyLinux" | grep -q 'libswiftCore\.so'; then
    echo "SwiftlyLinux needs libswiftCore.so: build with -Xswiftc -static-stdlib" >&2
    exit 1
fi

# ------------------------------------------------------------ Common
#
# Binary and resource bundle stay together: Swift locates `Bundle.module`
# via the path of the running executable. So both live in /usr/lib, and
# /usr/bin only holds a symlink.

tree_fill() {
    local w="$1"
    install -Dm755 "$build/SwiftlyLinux" "$w/usr/lib/$PROGRAM/$PROGRAM"
    strip "$w/usr/lib/$PROGRAM/$PROGRAM" 2>/dev/null || true
    # **Both names; no bundle, no package.** Up to Swift 6.3 SwiftPM names a
    # bundle `<Target>_<Target>.resources`, from 6.4 on
    # `<Target>_<Target>.bundle`; the generated `Bundle.module` accessor looks
    # for the exact name used at build time. A hardcoded `*.resources` plus
    # `[ -d ] && cp` stayed silent when the pattern matched nothing: with a 6.4
    # toolchain the script built a package without any bundle and reported
    # success. That package failed at startup with "unable to find bundle
    # named SwiftlyLinux_SwiftlyLinux".
    local count=0 z
    for bundle in "$build"/*.resources "$build"/*.bundle; do
        [ -d "$bundle" ] || continue
        cp -r "$bundle" "$w/usr/lib/$PROGRAM/"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || { echo "Kein Ressourcenbuendel in $build" >&2; return 1; }
    # JellyfinKit's bundle carries `de.lproj` and `en.lproj`, i.e. the package's
    # translations; without it the app fails one step later in
    # `Textkatalog.bundle(bundle:sprache:)`.
    for z in SwiftlyLinux JellyfinKit; do
        [ -d "$w/usr/lib/$PROGRAM/${z}_${z}.resources" ] ||
        [ -d "$w/usr/lib/$PROGRAM/${z}_${z}.bundle" ] ||
            { echo "Ressourcenbuendel fehlt: ${z}_${z} — nachsehen in $build" >&2; return 1; }
    done
    # **Private libraries go next to the binary.**
    #
    # `librlottie.so` lives in `~/.local/lib` and is not a system package; the
    # build places it next to the executable so that `$ORIGIN` in the runpath
    # finds it. Without it the package is complete except for the one file the
    # app cannot start without, which only shows on a user's machine, not on
    # the build machine where it is on the path anyway.
    for lib in "$build"/*.so; do
        [ -f "$lib" ] && install -Dm755 "$lib" "$w/usr/lib/$PROGRAM/$(basename "$lib")"
    done
    # Startup animation and bundled font. `Plattform.mitgeliefert` looks for
    # them next to the executable.
    cp -r "$source/Linux/Resources" "$w/usr/lib/$PROGRAM/Resources"
    install -d "$w/usr/bin"
    ln -sf "/usr/lib/$PROGRAM/$PROGRAM" "$w/usr/bin/$PROGRAM"

    install -Dm644 "$source/Linux/Install/$ID.desktop" \
        "$w/usr/share/applications/$ID.desktop"
    install -Dm644 "$source/Linux/Install/$ID.metainfo.xml" \
        "$w/usr/share/metainfo/$ID.metainfo.xml"
    for grad in 32 64 128 256 512; do
        install -Dm644 \
            "$source/Linux/Resources/icons/hicolor/${grad}x${grad}/apps/$ID.png" \
            "$w/usr/share/icons/hicolor/${grad}x${grad}/apps/$ID.png"
    done
    licenses_put "$w"
}

# **Licenses: texts, authors, source, and the offer.**
#
# libVLC is LGPL-2.1-or-later, which requires shipping the license text and
# a pointer to the source. Three things are installed:
#   - `/usr/share/doc/$PROGRAMM/`: LICENSE (the app, MPL-2.0),
#     THIRD-PARTY-NOTICES.md (with the written offer) and the LICENSES
#     folder with all full texts;
#   - `Resources/Licenses`: the same files, which the app reads for its
#     "Open-Source-Lizenzen" page.
# Everything comes from `LICENSES/`; there is no second copy in the repo.
licenses_put() {
    local w="$1" d="$1/usr/share/doc/$PROGRAM" f
    [ -f "$source/LICENSES/components.json" ] && [ -f "$source/THIRD-PARTY-NOTICES.md" ] ||
        { echo "LICENSES/ oder THIRD-PARTY-NOTICES.md fehlt in $source" >&2; return 1; }
    install -Dm644 "$source/LICENSE" "$d/LICENSE"
    install -Dm644 "$source/THIRD-PARTY-NOTICES.md" "$d/THIRD-PARTY-NOTICES.md"
    for f in "$source"/LICENSES/*; do
        install -Dm644 "$f" "$d/LICENSES/$(basename "$f")"
        install -Dm644 "$f" "$w/usr/lib/$PROGRAM/Resources/Licenses/$(basename "$f")"
    done
}

# The `copyright` file in Debian style (machine-readable, format 1.0).
debian_copyright() {
    cat > "$1" <<'CR'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Swiftly Player
Source: https://github.com/paulherter/swiftly-player
Comment: libVLC and
 GTK 4 are not part of this package; they come from the system (packages
 vlc and gtk4) and keep their own licenses (LGPL-2.1-or-later). The source
 code of libVLC is available from VideoLAN, https://www.videolan.org/vlc/,
 and the written offer is in THIRD-PARTY-NOTICES.md. The full license
 texts are in /usr/share/doc/swiftly-jellyfin/LICENSES/.

Files: *
Copyright: Paul Herter
License: MPL-2.0
 This Source Code Form is subject to the terms of the Mozilla Public
 License, v. 2.0. The full text is in /usr/share/common-licenses/MPL-2.0
 and in /usr/share/doc/swiftly-jellyfin/LICENSE.

Files: usr/lib/swiftly-jellyfin/Resources/Fonts/*
Copyright: 2020 The Inter Project Authors (https://github.com/rsms/inter)
License: OFL-1.1
 This Font Software is licensed under the SIL Open Font License, Version
 1.1. The full text is in
 /usr/share/doc/swiftly-jellyfin/LICENSES/OFL-1.1-Inter.txt.

Files: usr/lib/swiftly-jellyfin/librlottie.so*
Copyright: Samsung Electronics Co., Ltd. and the rlottie authors
License: MIT
 The full text is in /usr/share/doc/swiftly-jellyfin/LICENSES/MIT.txt.

License: LGPL-2.1+
 The libraries libVLC and GTK 4, which this program uses, are licensed
 under the GNU Lesser General Public License, version 2.1 or (at your
 option) any later version. The full text is in
 /usr/share/doc/swiftly-jellyfin/LICENSES/LGPL-2.1-or-later.txt and in
 /usr/share/common-licenses/LGPL-2.1.
CR
}

# ------------------------------------------------------------------- .deb

say() { printf '==> %s\n' "$1"; }

say "deb"
deb="$(mktemp -d)"
tree_fill "$deb"
mkdir -p "$deb/DEBIAN"
size=$(du -sk "$deb" | cut -f1)
cat > "$deb/DEBIAN/control" <<EOF
Package: $PROGRAM
Version: $debVersion
Section: video
Priority: optional
Architecture: amd64
Depends: libgtk-4-1 (>= 4.14), libvlc5 | libvlc-bin, vlc-plugin-base, libc6 (>= 2.39)
Maintainer: Paul Herter <accounts@paulherter.de>
Installed-Size: $size
Homepage: https://github.com/paulherter/swiftly-player
Description: Jellyfin client that never transcodes
 Swiftly plays everything on your Jellyfin server as Direct Play or Direct
 Stream. The server never re-encodes, so the picture stays untouched and the
 machine stays quiet.
EOF
debian_copyright "$deb/usr/share/doc/$PROGRAM/copyright"
chmod 644 "$deb/usr/share/doc/$PROGRAM/copyright"
dpkg-deb --build --root-owner-group "$deb" "$out/${PROGRAM}_${debVersion}_amd64.deb" >/dev/null
rm -rf "$deb"

# ------------------------------------------------------------------- .rpm

say "rpm"
rpmbaum="$(mktemp -d)"
mkdir -p "$rpmbaum"/{BUILD,RPMS,SOURCES,SPECS,BUILDROOT}
buffer="$rpmbaum/BUILDROOT/$PROGRAM-$version-$state.x86_64"
tree_fill "$buffer"
cat > "$rpmbaum/SPECS/$PROGRAM.spec" <<EOF
Name:           $PROGRAM
Version:        $version
Release:        $state
Summary:        Jellyfin client that never transcodes
License:        MPL-2.0
URL:            https://github.com/paulherter/swiftly-player
BuildArch:      x86_64
Requires:       gtk4 >= 4.14
Requires:       vlc-libs
AutoReqProv:    no

%description
Swiftly plays everything on your Jellyfin server as Direct Play or Direct
Stream. The server never re-encodes, so the picture stays untouched and the
machine stays quiet.

%files
/usr/lib/$PROGRAM
/usr/bin/$PROGRAM
/usr/share/applications/$ID.desktop
/usr/share/metainfo/$ID.metainfo.xml
/usr/share/icons/hicolor/*/apps/$ID.png
%dir /usr/share/doc/$PROGRAM
%license /usr/share/doc/$PROGRAM/LICENSE
%license /usr/share/doc/$PROGRAM/LICENSES
%doc /usr/share/doc/$PROGRAM/THIRD-PARTY-NOTICES.md

%changelog
EOF
# **Pass `--buildroot` explicitly instead of relying on the default.**
#
# Newer `rpm` versions put the build root under
# `%{_builddir}/%{name}-%{version}-build/BUILDROOT` instead of
# `%{_topdir}/BUILDROOT/...`. The script fills the latter, so rpmbuild
# looked in the former and reported "File not found" for every file. An
# explicit path makes it version-independent.
rpmbuild --define "_topdir $rpmbaum" --define "_build_id_links none" \
    --buildroot "$buffer" \
    -bb "$rpmbaum/SPECS/$PROGRAM.spec" >/dev/null
cp "$rpmbaum"/RPMS/x86_64/*.rpm "$out/"
rm -rf "$rpmbaum"

# ---------------------------------------------------------------- Tarball

say "tar.gz"
tarbaum="$(mktemp -d)/$PROGRAM-$version"
mkdir -p "$tarbaum"
tree_fill "$tarbaum"
tar -czf "$out/${PROGRAM}-${version}-x86_64.tar.gz" -C "$(dirname "$tarbaum")" "$PROGRAM-$version"
rm -rf "$(dirname "$tarbaum")"

say "fertig"
ls -1sh "$out"
