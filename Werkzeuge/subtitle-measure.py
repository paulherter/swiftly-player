#!/usr/bin/env python3 -I
"""Measures a rendered subtitle (white fill, black outline) in a PNG: stem weight and outline thickness in
percent of the font size, so the same look can be compared across platforms (contract subtitles.md lines 8/9).

usage: subtitle-measure.py <png> <font-px> [x0 y0 x1 y1]     prints: fill=<%> outline=<%> width=<%> height=<%>
Area of fill pixels (luminance >= 200) and of dark outline pixels (luminance <= 60), in percent of font-size squared,
plus the ink bounding box in percent of the font size. Same text on a mid-grey ground gives the same numbers on every
platform when weight, typeface and outline ratio match.
"""
import struct, sys, zlib
from collections import Counter

def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w = 8, b"", 0
    while pos < len(d):
        n, t = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        if t == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif t == b"IDAT":
            idat += body
        pos += 12 + n
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride, prev, rows, p = w * ch, bytearray(w * ch), [], 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]; c = prev[i - ch] if i >= ch else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, ch, rows

def measure(path, font_px, box=None):
    """Area metrics, independent of the renderer: fill = pixels with luminance >= 200, ink = fill or outline
    (luminance <= 60). All in percent of the font size (areas of its square)."""
    w, h, ch, rows = read_png(path)
    x0, y0, x1, y1 = box or (0, 0, w, h)
    fill = dark = 0
    bx0, by0, bx1, by1 = w, h, 0, 0
    for y in range(y0, y1):
        r = rows[y]
        for x in range(x0, x1):
            R, G, B = r[x * ch], r[x * ch + 1], r[x * ch + 2]
            f = (0.299 * R + 0.587 * G + 0.114 * B) >= 200
            d = (0.299 * R + 0.587 * G + 0.114 * B) <= 60
            if f or d:
                fill += f; dark += d
                bx0, by0, bx1, by1 = min(bx0, x), min(by0, y), max(bx1, x), max(by1, y)
    sq = font_px * font_px
    return {"fill": 100 * fill / sq, "outline": 100 * dark / sq, "width": 100 * (bx1 - bx0 + 1) / font_px,
            "height": 100 * (by1 - by0 + 1) / font_px}

if __name__ == "__main__":
    a = sys.argv
    box = tuple(int(v) for v in a[3:7]) if len(a) >= 7 else None
    m = measure(a[1], float(a[2]), box)
    print("fill=%.1f outline=%.1f width=%.1f height=%.1f" % (m["fill"], m["outline"], m["width"], m["height"]))
