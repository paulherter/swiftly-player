#!/usr/bin/env python3
"""Build the six supporter app icons for every platform from one description.

Every icon is the same play mark as the regular app icon (same path, same
position), only colour, light and one small detail change. Each icon is
described once below as three layers:

    back    opaque base (solid colour or gradient)
    middle  light: glows or a soft contact shadow (transparent elsewhere)
    front   the mark itself, plus a sheen and, for Heart, the heart

From that one description the script writes:

    svg/<Name>.svg                      1024 x 1024 master, full bleed, no rounding
    svg/<Name>/0-back.svg ... 2-front   the three layers at 1024 (Icon Composer, tvOS)
    svg/<Name>/tv-*.svg                 the three layers on the 800 x 480 tvOS canvas
    svg/<Name>/android-*.svg            the adaptive layers on the 108 x 108 dp grid
    ios/AppIcon-<Name>.appiconset       1024 master, same layout as Sources/iOS AppIcon
    ios/previews/AppIconPreview-<Name>.imageset   60 pt @2x/@3x for an in-app picker
    macos/AppIcon-<Name>.appiconset     the ten sizes, same layout as Sources/macOS AppIcon
    macos/AppIcon-<Name>.icns           built with iconutil
    tvos/AppIcon-<Name>.imagestack      alternate icon, 3 layers, 400 x 240 @1x/@2x
    android/res/...                     vector drawables: background, foreground, monochrome
    android/preview/<name>.png          composite for the preview sheet

Rendering uses Chrome headless (SVG -> PNG) and Pillow for downscaling, both
already present on a Mac with Chrome. Nothing is installed.

Usage:  python3 build-icons.py            # everything
        python3 build-icons.py --svg-only # sources only, no PNGs
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# The brand mark, unchanged from Sources/Shared/Marks.swift and Website/symbol.svg.
MARK = ("M440.1,280l285,163.2c38,21.7,51.2,70,29.6,108-7,12.3-17.2,22.5-29.6,29.6"
        "l-285,163.2c-37.9,21.8-86.3,8.6-108.1-29.3-6.9-12-10.5-25.6-10.5-39.4"
        "v-326.6c0-43.7,35.5-79.2,79.2-79.2,13.8,0,27.4,3.6,39.4,10.5Z")
MARK_TOP, MARK_BOTTOM = 280.0, 744.0

# A heart in a 100 x 100 box, centre of its bounding box at (50, 49).
HEART = ("M50,88 C44,83 9,60 9,33 C9,19 19,9 31,9 C40,9 46,14 50,21 "
         "C54,14 60,9 69,9 C81,9 91,19 91,33 C91,60 56,83 50,88 Z")


# --------------------------------------------------------------------------
# Path handling: everything is converted to absolute M/L/C/Z and transformed,
# so SVG and Android get identical geometry without group transforms (the
# gradient coordinates then share the same space as the paths on Android).

TOKEN = re.compile(r"[MmLlHhVvCcZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def absolute(d: str) -> list[tuple[str, list[float]]]:
    toks = TOKEN.findall(d)
    out, i, cmd = [], 0, None
    x = y = sx = sy = 0.0
    nargs = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "Z": 0}
    while i < len(toks):
        t = toks[i]
        if t.isalpha():
            cmd = t
            i += 1
            if cmd in "Zz":
                out.append(("Z", []))
                x, y = sx, sy
                continue
        n = nargs[cmd.upper()]
        a = [float(v) for v in toks[i:i + n]]
        i += n
        rel = cmd.islower()
        up = cmd.upper()
        if up == "M":
            x, y = (x + a[0], y + a[1]) if rel else (a[0], a[1])
            sx, sy = x, y
            out.append(("M", [x, y]))
            cmd = "l" if rel else "L"
        elif up == "L":
            x, y = (x + a[0], y + a[1]) if rel else (a[0], a[1])
            out.append(("L", [x, y]))
        elif up == "H":
            x = x + a[0] if rel else a[0]
            out.append(("L", [x, y]))
        elif up == "V":
            y = y + a[0] if rel else a[0]
            out.append(("L", [x, y]))
        elif up == "C":
            pts = [(x + a[k], y + a[k + 1]) if rel else (a[k], a[k + 1]) for k in (0, 2, 4)]
            out.append(("C", [c for p in pts for c in p]))
            x, y = pts[2]
    return out


def transform(path, s: float, tx: float, ty: float) -> str:
    parts = []
    for c, a in path:
        pts = [f"{a[k] * s + tx:.2f},{a[k + 1] * s + ty:.2f}" for k in range(0, len(a), 2)]
        parts.append(c + " ".join(pts))
    return " ".join(parts)


MARK_ABS = absolute(MARK)
HEART_ABS = absolute(HEART)


def heart_in_mark(cx: float, cy: float, width: float):
    k = width / 82.0  # the heart spans x 9..91
    return [(c, [v * k + (cx - 50 * k if j % 2 == 0 else cy - 49 * k) for j, v in enumerate(a)])
            for c, a in HEART_ABS]


# --------------------------------------------------------------------------
# Icon descriptions. Coordinates of glows and gradients on the mark are in the
# 1024 icon space ("mark"); background gradients are fractions of the canvas
# ("canvas"), so they fill the tvOS and Android canvases as well.

def lin(space, x1, y1, x2, y2, *stops):
    return {"type": "linear", "space": space, "p": (x1, y1, x2, y2), "stops": stops}


def rad(space, cx, cy, r, *stops):
    return {"type": "radial", "space": space, "p": (cx, cy, r), "stops": stops}


def glow(space, cx, cy, r, color, alpha, mid=0.45):
    return rad(space, cx, cy, r, (0, color, alpha), (mid, color, alpha * 0.45), (1, color, 0))


SHEEN = lin("mark", 0, MARK_TOP, 0, MARK_BOTTOM, (0, "#FFFFFF", 0.38), (0.42, "#FFFFFF", 0.0))

HEART_CENTRE = (462.0, 514.0)

# **No glow, anywhere.** The tiles are dark glass like the regular icon: a calm ground
# and a quiet contact shadow under the mark, nothing that shines around it.
SHADOW = glow("mark", 520, 560, 330, "#000000", 0.18, 0.5)

ICONS = {
    "Heart": {
        "back": [lin("canvas", 0, 0, 0, 1, (0, "#1F2024"), (1, "#111214"))],
        "middle": [SHADOW],
        "mark": lin("mark", 330, 280, 750, 744, (0, "#8EEDF0"), (0.5, "#50D5DA"), (1, "#3BBEC4")),
        "sheen": SHEEN,
        "heart": {"hole": 238, "fill": 194,
                  "paint": lin("mark", 0, 420, 0, 600, (0, "#FF8FA0"), (1, "#F0566E"))},
    },
    "Aurora": {
        "back": [lin("canvas", 0, 0, 1, 1, (0, "#12424A"), (0.55, "#0E1A2E"), (1, "#1E1538"))],
        "middle": [SHADOW],
        "mark": lin("mark", 330, 280, 750, 744, (0, "#FFFFFF"), (1, "#D2F6F8")),
        "sheen": None,
    },
    "Gold": {
        "back": [lin("canvas", 0, 0, 0, 1, (0, "#26201A"), (1, "#0F0D0B"))],
        "middle": [SHADOW],
        "mark": lin("mark", 330, 280, 740, 744, (0, "#FFF0C2"), (0.32, "#F1CB76"),
                    (0.68, "#D19B3C"), (1, "#9C6B1E")),
        "sheen": SHEEN,
    },
    "Light": {
        "back": [lin("canvas", 0, 0, 0, 1, (0, "#FFFFFF"), (1, "#DDE0E3"))],
        "middle": [glow("mark", 520, 560, 330, "#000000", 0.16, 0.5)],
        "mark": lin("mark", 0, 280, 0, 744, (0, "#2C2E33"), (1, "#121315")),
        "sheen": lin("mark", 0, MARK_TOP, 0, MARK_BOTTOM, (0, "#FFFFFF", 0.14), (0.45, "#FFFFFF", 0.0)),
    },
    "Night": {
        "back": [lin("canvas", 0, 0, 0, 1, (0, "#0A0B0C"), (1, "#030303"))],
        "middle": [SHADOW],
        "mark": rad("mark", 470, 500, 330, (0, "#E6FEFF"), (0.45, "#8CEEF1"), (1, "#3CC8CE")),
        "sheen": None,
    },
    "Coffee": {
        "back": [lin("canvas", 0, 0, 0, 1, (0, "#3D2B21"), (1, "#1C130E"))],
        "middle": [SHADOW],
        "mark": lin("mark", 330, 280, 740, 744, (0, "#FBEBD6"), (0.5, "#E2C29C"), (1, "#B98A5C")),
        "sheen": SHEEN,
    },
}


# --------------------------------------------------------------------------
# Targets: where the 1024 icon space lands on each canvas.

class Target:
    def __init__(self, w, h, s, cx=None, cy=None):
        self.w, self.h, self.s = w, h, s
        cx = w / 2 if cx is None else cx
        cy = h / 2 if cy is None else cy
        self.tx, self.ty = cx - 512 * s, cy - 512 * s

    def pt(self, space, x, y):
        if space == "canvas":
            return x * self.w, y * self.h
        return x * self.s + self.tx, y * self.s + self.ty

    def length(self, space, r):
        return r * max(self.w, self.h) if space == "canvas" else r * self.s


MASTER = Target(1024, 1024, 1.0)
# Android: the 1024 tile maps onto the guaranteed 72 dp of the 108 dp layer,
# exactly as the regular ic_launcher_foreground.xml does.
ANDROID = Target(108, 108, 72 / 1024)
# tvOS: 800 x 480 (@2x of 400 x 240). The mark is 46 % of the height, a bit
# larger than on iOS because the TV tile is wide and seen from the sofa.
TV = Target(800, 480, 0.476)


def svg_paint(p, t: Target, gid: str):
    stops = "".join(
        f'<stop offset="{s[0]}" stop-color="{s[1]}" stop-opacity="{s[2] if len(s) > 2 else 1}"/>'
        for s in p["stops"])
    if p["type"] == "linear":
        x1, y1 = t.pt(p["space"], p["p"][0], p["p"][1])
        x2, y2 = t.pt(p["space"], p["p"][2], p["p"][3])
        return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{x1:.2f}" y1="{y1:.2f}" '
                f'x2="{x2:.2f}" y2="{y2:.2f}">{stops}</linearGradient>')
    cx, cy = t.pt(p["space"], p["p"][0], p["p"][1])
    r = t.length(p["space"], p["p"][2])
    return (f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{cx:.2f}" cy="{cy:.2f}" '
            f'r="{r:.2f}">{stops}</radialGradient>')


def shapes(icon, layer: str, t: Target, mono=False):
    """Return [(path_d, paint_or_colour, evenodd)] for one layer."""
    rect = f"M0,0 L{t.w},0 L{t.w},{t.h} L0,{t.h} Z"
    out = []
    if layer == "back":
        for p in icon["back"]:
            out.append((rect, p, False))
    elif layer == "middle":
        for p in icon["middle"]:
            out.append((rect, p, False))
    else:
        mark = transform(MARK_ABS, t.s, t.tx, t.ty)
        heart = icon.get("heart")
        evenodd = False
        if heart:
            hole = transform(heart_in_mark(*HEART_CENTRE, heart["hole"]), t.s, t.tx, t.ty)
            mark = mark + " " + hole
            evenodd = True
        if mono:
            return [(mark, "#FFFFFF", evenodd)]
        out.append((mark, icon["mark"], evenodd))
        if icon.get("sheen"):
            out.append((mark, icon["sheen"], evenodd))
        if heart:
            fill = transform(heart_in_mark(*HEART_CENTRE, heart["fill"]), t.s, t.tx, t.ty)
            out.append((fill, heart["paint"], False))
    return out


def write_svg(path: Path, icon, layers, t: Target, mono=False):
    defs, body = [], []
    n = 0
    for layer in layers:
        for d, paint, eo in shapes(icon, layer, t, mono):
            rule = ' fill-rule="evenodd"' if eo else ""
            if isinstance(paint, str):
                body.append(f'<path d="{d}" fill="{paint}"{rule}/>')
            else:
                gid = f"g{n}"
                n += 1
                defs.append(svg_paint(paint, t, gid))
                body.append(f'<path d="{d}" fill="url(#{gid})"{rule}/>')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{t.w}" height="{t.h}" viewBox="0 0 {t.w} {t.h}">'
        f'<defs>{"".join(defs)}</defs>{"".join(body)}</svg>\n')


# --------------------------------------------------------------------------
# Android vector drawables (adaptive icon layers, 108 x 108 dp).

def argb(c, a=1.0):
    return f"#{round(a * 255):02X}{c.lstrip('#').upper()}"


def vd_paint(paint, t: Target):
    items = "".join(
        f'\n                <item android:offset="{s[0]}" android:color="{argb(s[1], s[2] if len(s) > 2 else 1)}" />'
        for s in paint["stops"])
    if paint["type"] == "linear":
        x1, y1 = t.pt(paint["space"], paint["p"][0], paint["p"][1])
        x2, y2 = t.pt(paint["space"], paint["p"][2], paint["p"][3])
        g = (f'android:type="linear" android:startX="{x1:.2f}" android:startY="{y1:.2f}" '
             f'android:endX="{x2:.2f}" android:endY="{y2:.2f}"')
    else:
        cx, cy = t.pt(paint["space"], paint["p"][0], paint["p"][1])
        r = t.length(paint["space"], paint["p"][2])
        g = (f'android:type="radial" android:centerX="{cx:.2f}" android:centerY="{cy:.2f}" '
             f'android:gradientRadius="{r:.2f}"')
    return (f'\n        <aapt:attr name="android:fillColor">\n            <gradient {g}>{items}'
            f'\n            </gradient>\n        </aapt:attr>')


def write_vector(path: Path, icon, layers, t: Target, comment: str, mono=False):
    body = []
    for layer in layers:
        for d, paint, eo in shapes(icon, layer, t, mono):
            rule = ' android:fillType="evenOdd"' if eo else ""
            if isinstance(paint, str):
                body.append(f'    <path android:pathData="{d}" android:fillColor="{argb(paint)}"{rule} />')
            else:
                body.append(f'    <path android:pathData="{d}"{rule}>{vd_paint(paint, t)}\n    </path>')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f"<!-- {comment} Generated by Assets/SupporterIcons/build-icons.py, do not edit by hand. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    xmlns:aapt="http://schemas.android.com/aapt"\n'
        '    android:width="108dp" android:height="108dp"\n'
        '    android:viewportWidth="108" android:viewportHeight="108">\n'
        + "\n".join(body) + "\n</vector>\n")


# --------------------------------------------------------------------------
# Rendering

def render(svg: Path, png: Path, w: int, h: int):
    png.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as prof:
        subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=1", "--default-background-color=00000000",
             f"--user-data-dir={prof}", f"--window-size={w},{h}",
             f"--screenshot={png}", svg.as_uri()],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    im = Image.open(png)
    assert im.size == (w, h), f"{png}: {im.size}"


def resize(src: Path, dst: Path, w: int, h: int | None = None, opaque=True):
    im = Image.open(src).convert("RGBA").resize((w, h or w), Image.LANCZOS)
    if opaque:
        im = im.convert("RGB")
    dst.parent.mkdir(parents=True, exist_ok=True)
    im.save(dst, optimize=True)


def write_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


INFO = {"author": "xcode", "version": 1}
MAC_SIZES = [16, 32, 128, 256, 512]


def build(name: str, icon, svg_only: bool):
    low = name.lower()
    s = ROOT / "svg"
    master = s / f"{name}.svg"
    write_svg(master, icon, ["back", "middle", "front"], MASTER)
    for i, layer in enumerate(["back", "middle", "front"]):
        write_svg(s / name / f"{i}-{layer}.svg", icon, [layer], MASTER)
        write_svg(s / name / f"tv-{i}-{layer}.svg", icon, [layer], TV)
    write_svg(s / name / "android-background.svg", icon, ["back", "middle"], ANDROID)
    write_svg(s / name / "android-foreground.svg", icon, ["front"], ANDROID)
    write_svg(s / name / "android-monochrome.svg", icon, ["front"], ANDROID, mono=True)
    write_svg(s / name / "android-composite.svg", icon, ["back", "middle", "front"], ANDROID)

    # Android vectors
    res = ROOT / "android" / "res"
    write_vector(res / "drawable" / f"ic_launcher_{low}_background.xml", icon, ["back", "middle"], ANDROID,
                 f"Supporter icon {name}: background layer, opaque, no rounding (the system mask cuts the corners).")
    write_vector(res / "drawable" / f"ic_launcher_{low}_foreground.xml", icon, ["front"], ANDROID,
                 f"Supporter icon {name}: the brand mark, 1024 tile mapped onto the inner 72 dp safe zone.")
    write_vector(res / "drawable" / f"ic_launcher_{low}_monochrome.xml", icon, ["front"], ANDROID,
                 f"Supporter icon {name}: silhouette for themed icons (only alpha counts).", mono=True)
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f"<!-- Supporter icon {name}. Generated by Assets/SupporterIcons/build-icons.py. -->\n"
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        f'    <background android:drawable="@drawable/ic_launcher_{low}_background" />\n'
        f'    <foreground android:drawable="@drawable/ic_launcher_{low}_foreground" />\n'
        f'    <monochrome android:drawable="@drawable/ic_launcher_{low}_monochrome" />\n'
        "</adaptive-icon>\n")
    for suffix in ("", "_round"):
        p = res / "mipmap-anydpi-v26" / f"ic_launcher_{low}{suffix}.xml"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(adaptive)

    if svg_only:
        return

    tmp = ROOT / ".render" / name
    tmp.mkdir(parents=True, exist_ok=True)
    # The Android composite is rendered at 4x for the preview sheet.
    big = tmp / "android-432.svg"
    big.write_text((s / name / "android-composite.svg").read_text()
                   .replace('width="108" height="108"', 'width="432" height="432"'))
    jobs = [(master, tmp / "master.png", 1024, 1024), (big, tmp / "android.png", 432, 432)]
    for i, layer in enumerate(["back", "middle", "front"]):
        jobs.append((s / name / f"tv-{i}-{layer}.svg", tmp / f"tv-{layer}.png", 800, 480))
    with ThreadPoolExecutor(4) as ex:
        list(ex.map(lambda j: render(*j), jobs))

    m = tmp / "master.png"
    # iOS / iPadOS: one 1024 universal image, as Sources/iOS/.../AppIcon.appiconset
    ios = ROOT / "ios" / f"AppIcon-{name}.appiconset"
    resize(m, ios / f"AppIcon-{name}-1024.png", 1024)
    write_json(ios / "Contents.json", {"images": [{"filename": f"AppIcon-{name}-1024.png", "idiom": "universal",
                                                   "platform": "ios", "size": "1024x1024"}], "info": INFO})
    prev = ROOT / "ios" / "previews" / f"AppIconPreview-{name}.imageset"
    resize(m, prev / f"preview-{low}@2x.png", 120)
    resize(m, prev / f"preview-{low}@3x.png", 180)
    write_json(prev / "Contents.json", {"images": [
        {"idiom": "universal", "scale": "1x"},
        {"filename": f"preview-{low}@2x.png", "idiom": "universal", "scale": "2x"},
        {"filename": f"preview-{low}@3x.png", "idiom": "universal", "scale": "3x"}], "info": INFO})

    # macOS: same ten images as Sources/macOS/.../AppIcon.appiconset, plus .icns
    mac = ROOT / "macos" / f"AppIcon-{name}.appiconset"
    iconset = ROOT / ".render" / f"AppIcon-{name}.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    images = []
    for sz in MAC_SIZES:
        for sc in (1, 2):
            fn = f"appicon-{low}-{sz}x{sz}@{sc}x.png"
            resize(m, mac / fn, sz * sc)
            shutil.copy(mac / fn, iconset / f"icon_{sz}x{sz}{'@2x' if sc == 2 else ''}.png")
            images.append({"filename": fn, "idiom": "mac", "scale": f"{sc}x", "size": f"{sz}x{sz}"})
    write_json(mac / "Contents.json", {"images": images, "info": INFO})
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o",
                    str(ROOT / "macos" / f"AppIcon-{name}.icns")], check=True)

    # tvOS: a top-level image stack named like the icon, three layers,
    # 400 x 240 @1x and @2x. actool only finds an alternate icon as a bare
    # `.imagestack` next to the primary `AppIcon.brandassets`; inside a
    # `.brandassets` of its own it reports "No applicable image stack found".
    stack = ROOT / "tvos" / f"AppIcon-{name}.imagestack"
    write_json(stack / "Contents.json", {"layers": [{"filename": "Front.imagestacklayer"},
                                                    {"filename": "Middle.imagestacklayer"},
                                                    {"filename": "Back.imagestacklayer"}], "info": INFO})
    for layer, cap in (("back", "Back"), ("middle", "Middle"), ("front", "Front")):
        lay = stack / f"{cap}.imagestacklayer"
        write_json(lay / "Contents.json", {"info": INFO})
        img = lay / "Content.imageset"
        src = tmp / f"tv-{layer}.png"
        resize(src, img / f"{low}-{layer}-400x240.png", 400, 240, opaque=(layer == "back"))
        resize(src, img / f"{low}-{layer}-800x480.png", 800, 480, opaque=(layer == "back"))
        write_json(img / "Contents.json", {"images": [
            {"filename": f"{low}-{layer}-400x240.png", "idiom": "tv", "scale": "1x"},
            {"filename": f"{low}-{layer}-800x480.png", "idiom": "tv", "scale": "2x"}], "info": INFO})

    # Preview helpers (not shipped): tvOS composite and Android composite
    pv = ROOT / "preview"
    pv.mkdir(exist_ok=True)
    comp = Image.new("RGBA", (800, 480))
    for layer in ("back", "middle", "front"):
        comp.alpha_composite(Image.open(tmp / f"tv-{layer}.png").convert("RGBA"))
    comp.convert("RGB").save(pv / f"tv-{low}.png", optimize=True)
    resize(tmp / "android.png", pv / f"android-{low}.png", 432)
    resize(m, pv / f"ios-{low}.png", 360)


def main():
    svg_only = "--svg-only" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    for d in ("ios", "macos", "tvos", "android", ".render", "preview"):
        if not svg_only and not only:
            shutil.rmtree(ROOT / d, ignore_errors=True)
    for name, icon in ICONS.items():
        if only and name not in only:
            continue
        build(name, icon, svg_only)
        print("built", name)
    shutil.rmtree(ROOT / ".render", ignore_errors=True)


if __name__ == "__main__":
    main()
