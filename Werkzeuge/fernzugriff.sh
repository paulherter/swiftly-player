#!/usr/bin/env bash
# Richtet echten Fernzugriff auf diesen Rechner ein — Bild **und** Eingabe.
#
# **Warum ein Skript und kein Klickweg.** Der RDP-Dienst von Plasma
# (`krdp`) wird sonst in den Systemeinstellungen eingeschaltet; wer nicht am
# Rechner sitzt, kommt dort nicht hin. Hier steht dasselbe als Befehlsfolge.
#
# **Warum ueber SSH statt ueber das Netz.** Der Dienst hoert nur auf
# 127.0.0.1. Damit muss keine Portfreigabe in die Firewall, und das
# RDP-Passwort laeuft nie ueber das LAN — der SSH-Tunnel traegt es
# verschluesselt. Vom MacBook aus:
#
#     ssh -f -N -L 3389:127.0.0.1:3389 cachy
#
# und dann in der Windows App auf `localhost:3389` verbinden.
set -euo pipefail

echo "== 1/4  Paket =="
if ! pacman -Q krdp >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm krdp
else
    echo "krdp liegt schon da."
fi

ORDNER="$HOME/.local/share/krdpserver"
mkdir -p "$ORDNER"

echo
echo "== 2/4  Zertifikat =="
# RDP verlangt TLS. Ein selbst unterschriebenes reicht: die Gegenstelle bist
# du selbst, und der Weg dorthin liegt ohnehin schon in einem SSH-Tunnel.
if [ ! -f "$ORDNER/server.crt" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$ORDNER/server.key" -out "$ORDNER/server.crt" \
        -subj "/CN=$(hostname)" 2>/dev/null
    chmod 600 "$ORDNER/server.key"
    echo "angelegt."
else
    echo "liegt schon da."
fi

echo
echo "== 3/4  Zugang =="
echo "Denk dir ein Passwort **nur fuer RDP** aus — nicht dein Anmeldepasswort."
read -r -s -p "RDP-Passwort: " RDPPW; echo
read -r -s -p "noch einmal:  " RDPPW2; echo
[ "$RDPPW" = "$RDPPW2" ] || { echo "Die beiden stimmen nicht ueberein."; exit 1; }
[ -n "$RDPPW" ] || { echo "Leer geht nicht."; exit 1; }

echo
echo "== 4/4  Dienst =="
systemctl --user reset-failed swiftly-rdp 2>/dev/null || true
systemctl --user stop swiftly-rdp 2>/dev/null || true

# `krdpserver` bringt seine Optionen selbst mit; weichen sie ab, steht die
# Hilfe hier statt einer stillen Fehlermeldung.
if ! krdpserver --help 2>&1 | grep -q -- "--username"; then
    echo "Achtung: krdpserver kennt --username nicht. Seine Hilfe:"
    krdpserver --help 2>&1 | head -30
    exit 1
fi

systemd-run --user --collect --unit=swiftly-rdp \
    --setenv=XDG_RUNTIME_DIR="/run/user/$(id -u)" \
    --setenv=WAYLAND_DISPLAY=wayland-0 \
    --setenv=XDG_SESSION_TYPE=wayland \
    --property=StandardOutput=append:/tmp/swiftly-rdp.log \
    --property=StandardError=append:/tmp/swiftly-rdp.log \
    krdpserver --address 127.0.0.1 --port 3389 \
               --username "$USER" --password "$RDPPW" \
               --certificate "$ORDNER/server.crt" \
               --certificate-key "$ORDNER/server.key" >/dev/null

sleep 2
if ss -ltn 2>/dev/null | grep -q "127.0.0.1:3389"; then
    echo
    echo "Laeuft. Auf dem MacBook:"
    echo "    ssh -f -N -L 3389:127.0.0.1:3389 cachy"
    echo "  dann Windows App → localhost:3389, Benutzer $USER, dein RDP-Passwort."
else
    echo
    echo "Der Dienst horcht nicht. Protokoll:"
    tail -20 /tmp/swiftly-rdp.log 2>/dev/null
    exit 1
fi
