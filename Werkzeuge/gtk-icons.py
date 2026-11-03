#!/usr/bin/env python3
"""Builds the Swiftly icon theme and the player icons for Linux/Windows from the design kit.

The Mac draws its icons from `Sources/iOS/Icons.xcassets` (Phosphor, one symbol set per
stroke). This reads exactly those files, so Windows and Linux show the same shapes; the
Android drawables are only the fallback for names the kit does not carry. GTK symbolic
names (left) are answered by our own icons (right); everything unmapped falls through to
Adwaita. Run from the repo root after changing the table.
"""
import os, re, sys
SRC = "Android/shared/src/main/res/drawable"
OUT = "Linux/Resources/icons/Swiftly/scalable/actions"
PLAYER = "Linux/Resources/icons/player"
KIT = "Sources/iOS/Icons.xcassets"
S = 0.4375
def conv(d):
    toks = re.findall(r'[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?', d)
    out=[]; i=0; cmd=None
    def tx(x): return (x-1650)/S+128
    def ty(y): return (y-1090.77)/S+128
    def f(v): return ('%.2f'%v).rstrip('0').rstrip('.')
    n={'M':2,'L':2,'H':1,'V':1,'C':6,'A':7,'Z':0,'S':4,'Q':4}
    while i<len(toks):
        if toks[i].isalpha(): cmd=toks[i]; i+=1; out.append(cmd); 
        else:
            if cmd in 'Mm': cmd = 'L' if cmd=='M' else 'l'
        up=cmd.upper(); rel=cmd.islower()
        if up=='Z': continue
        k=n[up]; a=[float(t) for t in toks[i:i+k]]; i+=k
        if up in 'ML' or up=='C' or up in 'SQ':
            r=[]
            for j in range(0,k,2):
                r += [a[j]/S if rel else tx(a[j]), a[j+1]/S if rel else ty(a[j+1])]
        elif up=='H': r=[a[0]/S if rel else tx(a[0])]
        elif up=='V': r=[a[0]/S if rel else ty(a[0])]
        elif up=='A': r=[a[0]/S,a[1]/S,a[2],a[3],a[4], a[5]/S if rel else tx(a[5]), a[6]/S if rel else ty(a[6])]
        out.append(' '.join(f(v) for v in r))
    return ''.join(o if False else [])+' '.join(out)
def kit(name):
    p=f"{KIT}/icon.{name}.symbolset/icon.{name}.svg"
    try: s=open(p).read()
    except FileNotFoundError: return None
    m=re.search(r'<g id="Regular-M"><path d="([^"]+)"',s)
    return conv(m.group(1)) if m else None

def shape(ph, weight=""):
    """Path of a Phosphor name (`play_fill`): the kit's symbol set first, the Android drawable second."""
    name = ph.replace("_fill", ".fill").replace("_", "-")
    d = kit(name + weight) or kit(name)
    if d: return d
    xml = open(f"{SRC}/ph_{ph}.xml").read()
    return re.search(r'pathData="([^"]+)"', xml).group(1)

MAP = {
 "object-select": "check", "media-playback-start": "play_fill", "media-playback-pause": "pause_fill",
 "pan-down": "caret_down", "pan-up": "caret_up", "pan-end": "caret_right", "pan-start": "caret_left",
 "go-next": "caret_right", "go-previous": "caret_left", "go-down": "caret_down", "go-up": "caret_up",
 "folder-download": "tray_arrow_down", "system-users": "users", "view-refresh": "arrow_clockwise",
 "user-trash": "trash", "network-server": "hard_drives", "text-x-generic": "file_text",
 "dialog-warning": "warning", "media-skip-forward": "skip_forward", "list-remove": "minus",
 "list-add": "plus", "view-grid": "squares_four", "view-app-grid": "squares_four", "view-list": "rows",
 "view-continuous": "rows", "tv": "television", "starred": "star_fill", "emblem-favorite": "heart_fill",
 "edit-undo": "arrow_u_up_left", "document-edit": "pencil_simple", "avatar-default": "user",
 "user-available": "user", "applications-internet": "globe", "window-close": "x",
 "video-x-generic": "film_strip", "tag": "tag", "system-search": "magnifying_glass",
 "edit-find": "magnifying_glass", "network-offline": "wifi_slash", "format-text-bold": "text_t",
 "document-open-recent": "clock_counter_clockwise", "clock": "clock", "dialog-password": "lock",
 "channel-secure": "lock", "content-loading": "hourglass", "bookmark-new": "bookmark_simple",
 "user-bookmarks": "bookmark_simple", "applications-graphics": "palette",
 "view-sort-ascending": "arrows_down_up", "view-sort-descending": "arrows_down_up",
 "view-more-horizontal": "dots_three", "video-display": "desktop", "computer": "desktop",
 "software-update-available": "arrow_circle_down", "phone": "device_mobile", "tablet": "device_tablet",
 "network-wireless": "wifi_high", "network-wireless-signal-weak": "wifi_high",
 "media-seek-forward": "fast_forward", "mail-inbox": "tray_arrow_down", "emblem-system": "gear",
 "preferences-system": "gear", "drive-harddisk": "hard_drive", "dialog-information": "info",
 "audio-volume-high": "speaker_high", "user-home": "house", "system-log-out": "sign_out",
 "media-view-subtitles": "subtitles", "media-playlist-shuffle": "shuffle",
 "format-justify-left": "text_align_left", "appointment-missed": "clock",
 "swiftly-trailer": "monitor_play", "swiftly-gesehen": "check_circle", "swiftly-gesehen-an": "check_circle_fill",
 "go-down": "caret_down", "view-sort-ascending-name": "arrows_down_up",
 "folder": "stack", "folder-new": "plus_circle", "application-exit": "sign_out", "zoom-in": "text_aa",
 "media-seek-backward": "arrow_counter_clockwise", "view-calendar": "calendar_blank",
 "x-office-calendar": "calendar_blank", "mail-unread": "tray_arrow_down", "network-workgroup": "globe",
 "network-transmit-receive": "arrows_down_up", "swiftly-heart": "heart_fill", "swiftly-heartline": "heart",
 "swiftly-merken": "bookmark_simple", "swiftly-merken-an": "bookmark_simple_fill",
 "swiftly-clock": "clock", "swiftly-tag": "tag", "swiftly-tray": "tray",
}
os.makedirs(OUT, exist_ok=True)
for gtk, ph in MAP.items():
    open(f"{OUT}/{gtk}-symbolic.svg", "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 256 256"><path d="{shape(ph)}"/></svg>\n')

# Player icons: the app paints these itself (PlayerCharacter), filled outlines from the same kit.
# Weight as on the Mac (`AppIcon.suffix`): the skips at 44 pt use the light stroke, small marks the heavy one.
ARROWS_OUT = "M216,48V96a8,8,0,0,1-16,0V67.31l-42.34,42.35a8,8,0,0,1-11.32-11.32L188.69,56H160a8,8,0,0,1,0-16h48A8,8,0,0,1,216,48ZM98.34,146.34,56,188.69V160a8,8,0,0,0-16,0v48a8,8,0,0,0,8,8H96a8,8,0,0,0,0-16H67.31l42.35-42.34a8,8,0,0,0-11.32-11.32Z"
SLASH = "M56.49,39.51L216.49,199.51L199.51,216.49L39.51,56.49Z"
PLAYER_ICONS = {
 "play": ("play_fill", ""), "pause": ("pause_fill", ""), "next": ("skip_forward_fill", ""),
 "settings": ("sliders_horizontal", ""), "subtitles": ("subtitles", ""), "episodes": ("stack", ""),
 "tv": ("television", ""), "close": ("x", ""), "plus": ("plus", ""), "minus": ("minus", ""),
 "checkmark": ("check", ".w32"), "chevron": ("caret_right", ".w32"), "reset": ("arrow_counter_clockwise", ""),
 "warning": ("warning_fill", ""), "back": ("arrow_counter_clockwise", ".light"),
 "forward": ("arrow_clockwise", ".light"), "speaker-loud": ("speaker_high", ""),
 "speaker-quiet": ("speaker_high", ""), "fullscreen-exit": ("arrows_in_simple", ""),
}
os.makedirs(PLAYER, exist_ok=True)
for name, (ph, weight) in PLAYER_ICONS.items():
    zahl = ' data-zahl="128 140.8 78.9"' if name in ("back", "forward") else ""
    d = shape(ph, weight)
    open(f"{PLAYER}/{name}.svg", "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" fill="currentColor"{zahl}>\n  <path d="{d}"/>\n</svg>\n')
open(f"{PLAYER}/fullscreen.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" fill="currentColor">\n  <path d="{ARROWS_OUT}"/>\n</svg>\n')
open(f"{PLAYER}/speaker-muted.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" fill="currentColor">\n  <path d="{shape("speaker_high")}"/>\n  <path d="{SLASH}"/>\n</svg>\n')
open("Linux/Resources/icons/Swiftly/index.theme", "w").write(
"""[Icon Theme]
Name=Swiftly
Comment=Swiftly icons
Inherits=Adwaita,hicolor
Directories=scalable/actions

[scalable/actions]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
Context=Actions
""")
print(len(MAP), "icons")
