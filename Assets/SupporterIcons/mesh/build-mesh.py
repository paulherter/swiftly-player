#!/usr/bin/env python3
"""Farbnetz supporter icons: the play mark filled with a real mesh gradient.

One composition for all variants, only the palette changes:

    back    calm ground (light or dark radial), a faint top gloss
    middle  soft coloured glow below the mark plus a tight contact shadow
    front   the mark (same path and position as Website/symbol.svg), filled
            with a smooth colour field, lit from the top left: thin glass
            edge, sheen, darker inner edge bottom right

The colour field is a normalised Gaussian blend of a few colour nodes,
interpolated in Oklab, with a gentle domain warp so it flows instead of
showing circles. Everything is computed in float at 2048 px, composited in
linear light, scaled to 1024 and dithered (fine monochrome grain), so there is
no banding.

Writes, per icon:
    png/<Name>.png                1024 master, full bleed, no rounding
    layers/<Name>/0-back.png      opaque ground
    layers/<Name>/1-middle.png    glow and shadow (transparent)
    layers/<Name>/2-front.png     the mark (transparent)
    preview/<name>-tile.png       rounded tile with edge, for the preview sheet

Usage:  python3 build-mesh.py            # all
        python3 build-mesh.py Aurora Eis # only these
Needs Python 3 with numpy and Pillow.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
S = 2048            # working size
K = S / 1024        # 1024-space to working space

MARK = ("M440.1,280l285,163.2c38,21.7,51.2,70,29.6,108-7,12.3-17.2,22.5-29.6,29.6"
        "l-285,163.2c-37.9,21.8-86.3,8.6-108.1-29.3-6.9-12-10.5-25.6-10.5-39.4"
        "v-326.6c0-43.7,35.5-79.2,79.2-79.2,13.8,0,27.4,3.6,39.4,10.5Z")

# --------------------------------------------------------------------------
# Palettes. Nodes in 1024 space: (x, y, sigma, colour, weight).
# The layout is shared, so every variant has the same light and structure:
#   tl  top left, where the light comes from
#   tip the point of the triangle
#   bl  bottom left
#   core a softer glow in the middle
#   base fills the top and bottom edges between the nodes

LAYOUT = {
    "tl":   (360, 315, 150, 1.0),
    "tip":  (740, 495, 125, 1.0),
    "bl":   (395, 745, 150, 1.0),
    "core": (530, 520, 95, 0.5),
    "baseT": (585, 375, 115, 0.8),
    "baseB": (585, 660, 115, 0.8),
}

LIGHT_GROUND = ("#FFFFFF", "#E6E8ED")

ICONS = {
    "Aurora": dict(
        ground=LIGHT_GROUND,
        tl="#46DCD8", tip="#9B5CFF", bl="#1F5BFF", core="#7EF2E2", base="#3F7BFF",
        glow="#50D5DA"),
    "Sunset": dict(
        ground=LIGHT_GROUND,
        tl="#FFC247", tip="#C93A9E", bl="#FF5A3C", core="#FFB58A", base="#F2507E",
        glow="#FF7A6B", deep=0.02),
    "Neon": dict(
        ground=("#1E1A2E", "#0B0A12"),
        tl="#3D7BFF", tip="#FF3FD2", bl="#7A33FF", core="#B98CFF", base="#5B3BFF",
        glow="#8B5CFF", dark=True),
    "Smaragd": dict(
        ground=LIGHT_GROUND,
        tl="#5BE6C9", tip="#22B85A", bl="#0B6A7A", core="#9BF0C8", base="#119C8C",
        glow="#2FC9A6"),
    "Eis": dict(
        ground=("#1A2638", "#0A0F18"),
        tl="#F4FBFF", tip="#4FA3FF", bl="#9CD6FF", core="#E2F5FF", base="#7EC0FF",
        glow="#7EC0FF", dark=True),
    "Glut": dict(
        ground=("#2A1712", "#0E0807"),
        tl="#FFBE3B", tip="#B30F33", bl="#FF4A12", core="#FF9A4A", base="#E02A2A",
        glow="#FF5A2A", dark=True),
    "Gold": dict(
        ground=("#2A241A", "#100D08"),
        tl="#FFF0C7", tip="#B9782A", bl="#E3A94B", core="#FFE7A8", base="#D49A3E",
        glow="#E3A94B", dark=True),
    "Graphit": dict(
        ground=("#232427", "#0C0C0D"),
        tl="#B3B9C1", tip="#50D5DA", bl="#363A41", core="#6A7078", base="#50565E",
        glow="#3FA9AD", dark=True, tipw=0.85, glow_a=0.30, chroma=1.0),
}

# --------------------------------------------------------------------------
# Colour


def hex_rgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)], float)


def to_lin(c):
    c = np.asarray(c, float)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])


def lin_to_oklab(c):
    return np.cbrt(c @ M1.T) @ M2.T


def oklab_to_lin(c):
    return ((c @ np.linalg.inv(M2).T) ** 3) @ np.linalg.inv(M1).T


def lab(h):
    return lin_to_oklab(to_lin(hex_rgb(h)))


# --------------------------------------------------------------------------
# Geometry


def flatten(d: str, steps=48):
    toks = re.findall(r"[MmLlVvHhCcZz]|-?(?:\d+\.?\d*|\.\d+)", d)
    pts, i, x, y, cmd = [], 0, 0.0, 0.0, None
    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]
            i += 1
            if cmd in "Zz":
                continue
        n = {"M": 2, "m": 2, "L": 2, "l": 2, "V": 1, "v": 1, "H": 1, "h": 1, "C": 6, "c": 6}[cmd]
        a = [float(t) for t in toks[i:i + n]]
        i += n
        rel = cmd.islower()
        ox, oy = (x, y) if rel else (0, 0)
        u = cmd.upper()
        if u in "ML":
            x, y = ox + a[0], oy + a[1]
            pts.append((x, y))
        elif u == "V":
            y = oy + a[0] if rel else a[0]
            pts.append((x, y))
        elif u == "H":
            x = ox + a[0] if rel else a[0]
            pts.append((x, y))
        else:
            p0 = np.array([x, y])
            p1, p2, p3 = (np.array([ox + a[k], oy + a[k + 1]]) for k in (0, 2, 4))
            for t in np.linspace(0, 1, steps)[1:]:
                q = ((1 - t) ** 3) * p0 + 3 * ((1 - t) ** 2) * t * p1 + 3 * (1 - t) * t * t * p2 + t ** 3 * p3
                pts.append(tuple(q))
            x, y = p3
    return pts


def poly_mask(pts, dx=0.0, dy=0.0):
    ss = 4
    im = Image.new("L", (S * ss, S * ss), 0)
    ImageDraw.Draw(im).polygon([((px + dx) * K * ss, (py + dy) * K * ss) for px, py in pts], fill=255)
    im = im.resize((S, S), Image.BOX)
    return np.asarray(im, float) / 255


def blur(a, sigma):
    """Gaussian blur via FFT, zero padded."""
    sigma *= K
    pad = int(3 * sigma) + 2
    h, w = a.shape
    p = np.pad(a, pad)
    fy = np.fft.fftfreq(p.shape[0])[:, None]
    fx = np.fft.rfftfreq(p.shape[1])[None, :]
    g = np.exp(-2 * (np.pi * sigma) ** 2 * (fx ** 2 + fy ** 2))
    out = np.fft.irfft2(np.fft.rfft2(p) * g, s=p.shape)
    return out[pad:pad + h, pad:pad + w]


YY, XX = np.mgrid[0:S, 0:S].astype(float) / K + 0.5 / K   # 1024-space coords

# --------------------------------------------------------------------------


def mesh_field(icon):
    # gentle domain warp, so the field flows rather than reading as blobs
    wx = XX + 26 * np.sin(YY / 150 + 0.7) + 14 * np.sin((XX + YY) / 95 + 2.1)
    wy = YY + 26 * np.sin(XX / 170 + 1.9) + 14 * np.sin((XX - YY) / 110 + 0.4)
    num = np.zeros((S, S, 3))
    den = np.zeros((S, S))
    for key, (nx, ny, sg, wt) in LAYOUT.items():
        col = lab(icon["base"] if key.startswith("base") else icon[key])
        if key == "tip":
            wt *= icon.get("tipw", 1.0)
        w = wt * np.exp(-((wx - nx) ** 2 + (wy - ny) ** 2) / (2 * sg ** 2))
        num += w[..., None] * col
        den += w
    den += 1e-4
    num += 1e-4 * lab(icon["base"])
    c = num / den[..., None]
    # an Oklab average loses chroma where hues meet; give it back
    c[..., 1:] *= icon.get("chroma", 1.12)
    # on the light ground the mark sits a little deeper, so it holds at 60 px
    if not icon.get("dark", False):
        c[..., 0] -= icon.get("deep", 0.055)
    return np.clip(oklab_to_lin(c), 0, 1)


def radial(c0, c1, cx, cy, r):
    t = np.clip(np.hypot(XX - cx, YY - cy) / r, 0, 1)[..., None]
    t = t * t * (3 - 2 * t)
    return oklab_to_lin(lab(c0) * (1 - t) + lab(c1) * t)


def over(dst, col, a):
    a = np.clip(a, 0, 1)[..., None]
    return dst * (1 - a) + col * a


def render(name, icon):
    dark = icon.get("dark", False)
    pts = flatten(MARK)
    m = poly_mask(pts)

    # back ------------------------------------------------------------
    back = radial(icon["ground"][0], icon["ground"][1], 400, 300, 900)
    gloss = np.clip(1 - YY / 460, 0, 1) ** 1.6
    back = over(back, np.ones(3), gloss * (0.05 if dark else 0.10))

    # middle: coloured glow + contact shadow -------------------------------
    glow_a = blur(poly_mask(pts, 0, 40), 90) * icon.get("glow_a", 0.55 if dark else 0.36)
    shadow_a = blur(poly_mask(pts, 0, 14), 16) * (0.35 if dark else 0.10)
    glow_c = to_lin(hex_rgb(icon["glow"]))
    mid_rgb = np.zeros((S, S, 3))
    mid_a = np.zeros((S, S))
    # premultiplied build-up: shadow first, glow above it
    mid_rgb = mid_rgb * (1 - shadow_a[..., None])
    mid_a = shadow_a
    mid_rgb = mid_rgb * (1 - glow_a[..., None]) + glow_c * glow_a[..., None]
    mid_a = mid_a * (1 - glow_a) + glow_a

    # front: mesh + light -------------------------------------------------
    f = mesh_field(icon)
    # direction across the mark, 0 at the top left, 1 at the bottom right
    t = np.clip(((XX - 330) * 430 + (YY - 280) * 460) / (430 ** 2 + 460 ** 2), 0, 1)

    # darker inner edge towards the bottom right (gives it body)
    inner = np.clip(1 - blur(m, 30) * 1.9, 0, 1) * m
    f = f * (1 - (inner * np.clip((t - 0.45) / 0.55, 0, 1) * 0.42)[..., None])

    # sheen from the top left
    ex, ey = XX - 470, YY - 330
    c, s_ = np.cos(np.radians(28)), np.sin(np.radians(28))
    u, v = ex * c + ey * s_, -ex * s_ + ey * c
    ell = ((u / 230) ** 2 + (v / 95) ** 2 <= 1).astype(float)
    sheen = blur(ell * np.clip(1 - (YY - 260) / 280, 0, 1), 26) * 0.18
    f = over(f, np.ones(3), sheen)

    # glass edge: soft inner light near the top left, a hair line all round
    edge_soft = np.clip(1 - blur(m, 7) * 1.6, 0, 1) * m
    rimL = np.interp(t, [0, 0.38, 0.72, 1], [1, 0, 0, 0.45])
    f = over(f, np.ones(3), edge_soft * rimL * 0.38)
    g = blur(m, 1.4)
    hair = np.exp(-((g - 0.5) / 0.22) ** 2) * m
    f = over(f, np.ones(3), hair * (0.25 + 0.5 * rimL))

    # composite --------------------------------------------------------
    comp = back * (1 - mid_a[..., None]) + mid_rgb
    comp = over(comp, f, m)
    return dict(back=back, mid=(mid_rgb, mid_a), front=(f, m), comp=comp)


# --------------------------------------------------------------------------
# Output


rng = np.random.default_rng(7)


def down(a):
    """2048 float -> 1024 float with Lanczos, per channel."""
    if a.ndim == 2:
        return np.asarray(Image.fromarray(a.astype(np.float32), "F").resize((1024, 1024), Image.LANCZOS))
    return np.stack([down(a[..., i]) for i in range(a.shape[2])], -1)


def quant(srgb, grain):
    """sRGB float -> uint8 with monochrome grain plus TPDF dither."""
    h, w = srgb.shape[:2]
    n = rng.normal(0, 1, (h, w))[..., None] * grain[..., None]
    tp = (rng.random((h, w, 1)) - rng.random((h, w, 1))) / 255
    return np.clip(np.round((srgb + n + tp) * 255), 0, 255).astype(np.uint8)


def squircle(size):
    """Continuous-corner tile outline (as the system rounds the icon), antialiased."""
    ss = 4
    t = np.linspace(0, 2 * np.pi, 2000, endpoint=False)
    c, s_ = np.cos(t), np.sin(t)
    n = 4.3
    # superellipse, same corner as the tile in the concept sheet
    x = np.sign(c) * np.abs(c) ** (2 / n)
    y = np.sign(s_) * np.abs(s_) ** (2 / n)
    pts = [((xi + 1) / 2 * size * ss, (yi + 1) / 2 * size * ss) for xi, yi in zip(x, y)]
    im = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(im).polygon(pts, fill=255)
    im = im.resize((size, size), Image.BOX)
    return np.asarray(im, float) / 255


def build(name, icon):
    r = render(name, icon)
    m1 = np.clip(down(r["front"][1]), 0, 1)
    grain = 0.006 + 0.008 * m1         # 0.6 % on the ground, 1.4 % in the mark
    comp = to_srgb(np.clip(down(r["comp"]), 0, 1))
    out = quant(comp, grain)
    (ROOT / "png").mkdir(exist_ok=True)
    Image.fromarray(out, "RGB").save(ROOT / "png" / f"{name}.png", optimize=True)

    ld = ROOT / "layers" / name
    ld.mkdir(parents=True, exist_ok=True)
    back = quant(to_srgb(down(r["back"])), np.full((1024, 1024), 0.006))
    Image.fromarray(back, "RGB").save(ld / "0-back.png", optimize=True)
    mrgb, ma = r["mid"]
    ma1 = np.clip(down(ma), 0, 1)
    straight = down(mrgb) / np.maximum(ma1, 1e-4)[..., None]
    mid = np.dstack([quant(to_srgb(straight), np.zeros((1024, 1024))), np.round(ma1 * 255).astype(np.uint8)])
    Image.fromarray(mid, "RGBA").save(ld / "1-middle.png", optimize=True)
    fr = np.dstack([quant(to_srgb(down(r["front"][0])), np.full((1024, 1024), 0.014)),
                    np.round(m1 * 255).astype(np.uint8)])
    Image.fromarray(fr, "RGBA").save(ld / "2-front.png", optimize=True)

    # preview tile: rounded, with the faint system edge
    q = squircle(1024)
    edge = np.clip(q - np.asarray(Image.fromarray((q * 255).astype(np.uint8)).resize((1004, 1004), Image.LANCZOS).resize((1024, 1024)), float) / 255, 0, 1)
    tile = out.astype(float) / 255
    yy = np.linspace(0, 1, 1024)[:, None]
    rim_a = edge * np.interp(yy, [0, 0.3, 0.75, 1], [0.55, 0.08, 0.04, 0.2])
    tile = tile * (1 - rim_a[..., None]) + rim_a[..., None]
    rgba = np.dstack([np.round(tile * 255).astype(np.uint8), np.round(q * 255).astype(np.uint8)])
    (ROOT / "preview").mkdir(exist_ok=True)
    Image.fromarray(rgba, "RGBA").save(ROOT / "preview" / f"{name.lower()}-tile.png", optimize=True)
    print(name, "ok")


def main():
    names = sys.argv[1:] or list(ICONS)
    for n in names:
        build(n, ICONS[n])


if __name__ == "__main__":
    main()
