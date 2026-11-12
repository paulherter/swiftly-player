# One PGS display set (a solid white bar at the bottom of a 320x180 canvas) shown from 1 s to 3 s, written by hand
# because ffmpeg cannot encode PGS (same bytes as Werkzeuge/pruefstand-medien.py). Usage: make_pgs.py out.sup
import struct, sys
def seg(kind, pts, payload):
    return b"PG" + struct.pack(">II", int(pts * 90000), 0) + bytes([kind]) + struct.pack(">H", len(payload)) + payload
def display_set(start, end, w=320, h=180, bar_w=200, bar_h=24):
    def pcs(pts, shown, n):
        body = struct.pack(">HHBHBBBB", w, h, 0x10, n, 0x80, 0, 0, 1 if shown else 0)
        if shown:
            body += struct.pack(">HBBHH", 0, 0, 0, (w - bar_w) // 2, h - bar_h - 20)
        return seg(0x16, pts, body)
    wds = struct.pack(">BBHHHH", 1, 0, (w - bar_w) // 2, h - bar_h - 20, bar_w, bar_h)
    pds = struct.pack(">BB", 0, 0) + bytes([1, 235, 128, 128, 255])
    rle = (bytes([0, 0xC0 | (bar_w >> 8), bar_w & 0xFF, 1]) + bytes([0, 0])) * bar_h
    ods = struct.pack(">HBB", 0, 0, 0xC0) + struct.pack(">I", len(rle) + 4)[1:] + struct.pack(">HH", bar_w, bar_h) + rle
    return (pcs(start, True, 0) + seg(0x17, start, wds) + seg(0x14, start, pds) + seg(0x15, start, ods) + seg(0x80, start, b"")
            + pcs(end, False, 1) + seg(0x17, end, struct.pack(">BBHHHH", 1, 0, (w - bar_w) // 2, h - bar_h - 20, bar_w, bar_h)) + seg(0x80, end, b""))
open(sys.argv[1], "wb").write(display_set(1.0, 3.0))
