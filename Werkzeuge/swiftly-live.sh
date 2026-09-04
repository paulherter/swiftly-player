#!/usr/bin/env bash
# Zeigt den Linux-Bildschirm im Browser — ohne Installation, ohne Passwort.
#
# **Was das ist und was nicht.** Es ist ein Blick, keine Fernbedienung:
# Bilder gehen hinaus, Tastendrücke kommen nicht herein. Für echtes
# Fernsteuern braucht es einen RDP- oder VNC-Dienst, und der lässt sich nur
# mit Systemrechten einrichten.
set -uo pipefail
U=$(id -u)
export XDG_RUNTIME_DIR=/run/user/$U
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus
export WAYLAND_DISPLAY=wayland-0
ORDNER=/tmp/swiftly-live
mkdir -p "$ORDNER"

cat > "$ORDNER/index.html" <<'HTML'
<!doctype html><meta charset=utf-8><title>Swiftly — Linux</title>
<style>
 html,body{margin:0;height:100%;background:#0e0e10;color:#8b8b90;
  font:13px/1.4 system-ui,sans-serif;display:flex;flex-direction:column}
 img{flex:1;min-height:0;object-fit:contain;width:100%}
 p{margin:0;padding:8px 12px;text-align:center}
</style>
<img id=b>
<p>Nur Ansicht — Tastatur und Maus wirken hier nicht.</p>
<script>
 const b=document.getElementById('b');
 const neu=()=>{const i=new Image();i.onload=()=>{b.src=i.src};i.src='bild.png?'+Date.now()};
 setInterval(neu,1200); neu();
</script>
HTML

while true; do
  if spectacle -b -a -n -o "$ORDNER/neu.png" >/dev/null 2>&1; then
    mv -f "$ORDNER/neu.png" "$ORDNER/bild.png"
  fi
  sleep 1
done
