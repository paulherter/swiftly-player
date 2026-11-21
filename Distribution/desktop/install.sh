#!/bin/sh
# Installs Swiftly Player for the current user from the unpacked tar.gz: the program, its entry in the app menu and
# search ("Swiftly Player") and the icons. No root needed. `./install.sh --uninstall` removes it again.
# Without installing, ./swiftly-player starts from this folder.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
bin=$HOME/.local/bin
id=de.paulherter.swiftly.player
sizes="32 48 64 128 256"

refresh() {
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$data/icons/hicolor" >/dev/null 2>&1 || true
    # Plasma reads the menu from its own cache; this makes the new entry searchable at once.
    for k in kbuildsycoca6 kbuildsycoca5; do
        command -v "$k" >/dev/null 2>&1 && { "$k" >/dev/null 2>&1 || true; break; }
    done
    # A running Plasma keeps its icon list until it is told: without this signal the first start shows a "?" in the taskbar.
    if command -v busctl >/dev/null 2>&1; then
        busctl --user emit /KIconLoader org.kde.KIconLoader iconChanged i 0 >/dev/null 2>&1 || true
    elif command -v dbus-send >/dev/null 2>&1; then
        dbus-send --session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0 >/dev/null 2>&1 || true
    fi
}

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$bin/swiftly-player" "$data/applications/$id.desktop"
    for s in $sizes; do rm -f "$data/icons/hicolor/${s}x${s}/apps/swiftly-player.png"; done
    refresh
    echo "Swiftly Player removed."
    exit 0
fi

[ -x "$here/swiftly-player" ] || { echo "swiftly-player is not next to this script." >&2; exit 1; }
install -Dm755 "$here/swiftly-player" "$bin/swiftly-player"
for s in $sizes; do
    install -Dm644 "$here/icons/swiftly-player-$s.png" "$data/icons/hicolor/${s}x${s}/apps/swiftly-player.png"
done
# The menu starts the program by its full path: ~/.local/bin is not on every desktop session's PATH.
mkdir -p "$data/applications"
sed "s|^Exec=swiftly-player|Exec=$bin/swiftly-player|" "$here/$id.desktop" > "$data/applications/$id.desktop"
chmod 644 "$data/applications/$id.desktop"
refresh
echo "Swiftly Player installed. Search for \"Swiftly Player\" in the app menu."
command -v mpv >/dev/null 2>&1 || echo "libmpv is missing: install the package mpv-libs (Arch) or libmpv2 (Debian/Ubuntu)." >&2
