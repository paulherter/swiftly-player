#!/usr/bin/env python3
"""Glass look tiles: the play mark on a dark glass tile, no glow.

The look icons (Neon Night, Halloween) and the fan tiles of the looks card are drawn
from one template: a dark ground, a light edge, the mark in the look's gradient with a
sheen and a white light edge, and a contact shadow as quiet as the regular icon's.
Nothing shines around the mark.

    python3 build-glass.py            # all, into svg/ and the app catalogs
    python3 build-glass.py Halloween  # only this one 

Needs Pillow and Google Chrome (headless, SVG to PNG), like build-icons.py.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
APP = ROOT.parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MARK = ("M440.1,280l285,163.2c38,21.7,51.2,70,29.6,108-7,12.3-17.2,22.5-29.6,29.6l-285,163.2"
        "c-37.9,21.8-86.3,8.6-108.1-29.3-6.9-12-10.5-25.6-10.5-39.4v-326.6c0-43.7,35.5-79.2,"
        "79.2-79.2,13.8,0,27.4,3.6,39.4,10.5Z")

# The Halloween web: hub in the top left corner of the tile, hugging its rounded corner.
# Fine white threads, 20 percent, no glow. Pulled 22 units toward the corner so it reads as
# hanging in it (the first version sat a little too far in).
WEB = ('<g transform="translate(-22 -22)" fill="none" stroke="#fff" stroke-opacity=".2" stroke-width="5" '
       'stroke-linecap="round" stroke-linejoin="round"><path d="M118 118 L440 74"/><path d="M118 118 L370 236"/>'
       '<path d="M118 118 L236 370"/><path d="M118 118 L74 440"/>'
       '<path d="M221 104 Q193 128 199 156 Q167 167 156 199 Q128 193 104 221"/>'
       '<path d="M298 93 Q250 135 259 184 Q203 203 184 259 Q135 250 93 298"/>'
       '<path d="M376 83 Q306 142 320 212 Q239 239 212 320 Q142 306 83 376"/></g>')

# name: (mark gradient stops top left to bottom right, extra detail)
TILES = {
    "Halloween": (["#FFB466", "#F06A1C"], WEB),
    "NeonNight": (["#5B7CFF", "#C24BFF"], None),
    "Gold": (["#FFF0C2", "#F1CB76", "#D19B3C", "#9C6B1E"], None),
    "Aurora": (["#46DCD8", "#3F7BFF", "#9B5CFF"], None),
    "Sunset": (["#FFCB57", "#FF6E7F", "#B83FD0"], None),
    "Ice": (["#F2FAFF", "#6FB6FF"], None),
    "Ember": (["#FFB13B", "#B3122B"], None),
    "Emerald": (["#5BE6C9", "#0E9E6E"], None),
}

# The supporter looks: an alternate app icon (`AppIcon-Look<Name>`) and the picker tile
# (`LookIcon-<Name>`). Sunset, Aurora and Gold also keep their small `LookFan-` tile.
LOOKS = ["Sunset", "Aurora", "Ice", "Ember", "Gold", "Emerald"]
FAN = ["Sunset", "Aurora", "Gold"]


def svg(stops, detail=None, mac=False):
    n = len(stops) - 1
    # The Mac has no alternate icons: a Dock image, the tile at 80 percent on a transparent canvas.
    open_ = '<g transform="translate(100 100) scale(0.8047)">' if mac else ''
    close_ = '</g>' if mac else ''
    rx = ' rx="230"' if mac else ''
    st = "".join(f'<stop offset="{i / n:.2f}" stop-color="{c}"/>' for i, c in enumerate(stops))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs>
<linearGradient id="t" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2C2C31"/><stop offset="1" stop-color="#121214"/></linearGradient>
<linearGradient id="f" x1="0.2" y1="0.15" x2="0.85" y2="0.9">{st}</linearGradient>
<linearGradient id="r" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".85"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="e" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".35" stop-color="#fff" stop-opacity=".04"/><stop offset="1" stop-color="#fff" stop-opacity=".02"/></linearGradient>
<linearGradient id="s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".28"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
<filter id="d" x="-20%" y="-20%" width="140%" height="160%"><feGaussianBlur stdDeviation="12"/></filter>
</defs>{open_}<rect width="1024" height="1024"{rx} fill="url(#t)"/><rect x="4" y="4" width="1016" height="1016" rx="226" fill="none" stroke="url(#e)" stroke-width="8"/>{detail or ""}
<path d="{MARK}" fill="#000" opacity=".22" transform="translate(0 10)" filter="url(#d)"/>
<path d="{MARK}" fill="url(#f)"/><path d="{MARK}" fill="url(#s)"/>
<path d="{MARK}" fill="none" stroke="url(#r)" stroke-width="9"/>{close_}</svg>
'''


def render(src: Path, png: Path):
    with tempfile.TemporaryDirectory() as prof:
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        "--force-device-scale-factor=1", "--default-background-color=00000000",
                        f"--user-data-dir={prof}", "--window-size=1024,1024",
                        f"--screenshot={png}", src.as_uri()],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def imageset(folder: Path, base: str, master: Image.Image, points: int):
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("*.png"):
        old.unlink()
    for scale in (2, 3):
        master.resize((points * scale, points * scale), Image.LANCZOS).save(folder / f"{base}@{scale}x.png", optimize=True)
    (folder / "Contents.json").write_text(json.dumps({"images": [
        {"idiom": "universal", "scale": "1x"},
        {"filename": f"{base}@2x.png", "idiom": "universal", "scale": "2x"},
        {"filename": f"{base}@3x.png", "idiom": "universal", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def mac(name: str, master: Image.Image):
    """The Mac's look tile (104 pt at 1x and 2x) and the Dock image (512 and 1024, transparent)
    of one look; the Dock image is what the app shows while the look is worn."""
    cat = APP / "Sources/macOS/Assets.xcassets"
    low = name.lower()
    tile = cat / f"LookIcon-{name}.imageset"
    tile.mkdir(parents=True, exist_ok=True)
    master.resize((104, 104), Image.LANCZOS).save(tile / f"look-{low}@1x.png", optimize=True)
    master.resize((208, 208), Image.LANCZOS).save(tile / f"look-{low}@2x.png", optimize=True)
    (tile / "Contents.json").write_text(json.dumps({"images": [
        {"filename": f"look-{low}@1x.png", "idiom": "universal", "scale": "1x"},
        {"filename": f"look-{low}@2x.png", "idiom": "universal", "scale": "2x"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    if name in FAN:
        fan = cat / f"LookFan-{name}.imageset"
        imageset(fan, f"fan-{low}", master, 70)
    # The Dock image carries the name of the alternate icon: `AppIcon-Look<Name>` becomes
    # `DockIcon-Look<Name>` (Halloween and Neon Night have no `Look` in the name).
    dock_name = name if name in ("Halloween", "NeonNight") else f"Look{name}"
    dock_set = cat / f"DockIcon-{dock_name}.imageset"
    dock_set.mkdir(parents=True, exist_ok=True)
    src = ROOT / "svg" / f"{name}-glass-mac.svg"
    src.write_text(svg(TILES[name][0], TILES[name][1], mac=True))
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "dock.png"
        render(src, png)
        dock = Image.open(png).convert("RGBA")
        dock.save(dock_set / f"dock-{low}@2x.png", optimize=True)
        dock.resize((512, 512), Image.LANCZOS).save(dock_set / f"dock-{low}.png", optimize=True)
    (dock_set / "Contents.json").write_text(json.dumps({"images": [
        {"filename": f"dock-{low}.png", "idiom": "universal", "scale": "1x"},
        {"filename": f"dock-{low}@2x.png", "idiom": "universal", "scale": "2x"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def main():
    cat = APP / "Sources/iOS/Assets.xcassets"
    with tempfile.TemporaryDirectory() as tmp:
        for name, (stops, detail) in TILES.items():
            if sys.argv[1:] and name not in sys.argv[1:]:
                continue
            src = ROOT / "svg" / f"{name}-glass.svg"
            src.write_text(svg(stops, detail))
            png = Path(tmp) / f"{name}.png"
            render(src, png)
            master = Image.open(png).convert("RGB")
            if name == "NeonNight":
                master.save(cat / "AppIcon-NeonNight.appiconset/AppIcon-NeonNight-1024.png", optimize=True)
                imageset(cat / "LookIcon-NeonNight.imageset", "look-neon", master, 104)
            elif name == "Halloween":
                master.save(cat / "AppIcon-Halloween.appiconset/AppIcon-Halloween-1024.png", optimize=True)
                imageset(cat / "LookIcon-Halloween.imageset", "look-halloween", master, 104)
            if name in LOOKS:
                icon = cat / f"AppIcon-Look{name}.appiconset"
                icon.mkdir(parents=True, exist_ok=True)
                master.save(icon / f"AppIcon-Look{name}-1024.png", optimize=True)
                (icon / "Contents.json").write_text(json.dumps({"images": [
                    {"filename": f"AppIcon-Look{name}-1024.png", "idiom": "universal",
                     "platform": "ios", "size": "1024x1024"}],
                    "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
                imageset(cat / f"LookIcon-{name}.imageset", f"look-{name.lower()}", master, 104)
            if name in FAN:
                imageset(cat / f"LookFan-{name}.imageset", f"fan-{name.lower()}", master, 70)
            mac(name, master)
            print("built", name)


if __name__ == "__main__":
    main()
