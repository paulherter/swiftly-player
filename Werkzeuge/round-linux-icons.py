#!/usr/bin/env python3
"""Writes the Linux launcher icons Distribution/desktop/icons/swiftly-player-<size>.png.

Every app icon in this repository (iOS, macOS, the desktop crate) is the same full square picture: iOS and macOS cut
its corners themselves, and no pre-cut export exists. Linux shells draw an icon exactly as given, so the taskbar and
the app menu showed a square. These files are that picture, the macOS app icon master, with its corners cut at the
corner the app itself draws for this icon (`APP_ICON_CORNER` = 22.37 % of the side in `login_mac.rs`); nothing is
redrawn. The window icon in the binary and every Linux package (deb, rpm, tar.gz installer, AUR) use them.
Needs Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/macOS/Assets.xcassets/AppIcon.appiconset/swiftly-mac-512x512@2x.png"  # 1024 px master
OUT = ROOT / "Distribution/desktop/icons"
CORNER = 0.2237
SIZES = (32, 48, 64, 128, 256)
SUPER = 8  # the mask is drawn 8x larger and scaled down, so the edge is smooth


def mask(side: int) -> Image.Image:
    big = side * SUPER
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, big - 1, big - 1), radius=big * CORNER, fill=255)
    return m.resize((side, side), Image.LANCZOS)


def main() -> None:
    src = Image.open(SOURCE).convert("RGBA")
    OUT.mkdir(parents=True, exist_ok=True)
    for side in SIZES:
        icon = src.resize((side, side), Image.LANCZOS)
        icon.putalpha(mask(side))
        icon.save(OUT / f"swiftly-player-{side}.png", optimize=True)


if __name__ == "__main__":
    main()
