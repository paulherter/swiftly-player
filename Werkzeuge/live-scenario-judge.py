#!/usr/bin/env python3 -I
"""Judges a `live-lauf.py <iphone|ipad> --scenario <name>` run folder: prints one PASS/FAIL line per check.
usage: ~/Library/Caches/swiftly-live-venv/bin/python3 Werkzeuge/live-scenario-judge.py <run folder> <scenario>"""
import json, os, sys
from PIL import Image, ImageChops

out, scenario = sys.argv[1], sys.argv[2]
ev = [json.loads(l) for l in open(f"{out}/events.jsonl") if l.strip()]
shots = lambda n: f"{out}/shots/{n}.png"
res = []
def check(name, ok, detail=""): res.append(ok); print(("PASS " if ok else "FAIL ") + name, detail)

def diff_px(a, b):
    A, B = Image.open(shots(a)).convert("RGB"), Image.open(shots(b)).convert("RGB")
    return sum(1 for p in ImageChops.difference(A, B).convert("L").getdata() if p > 40)

def text_colour(name, off):
    """Mean colour of the pixels the subtitle added (differ from the same frame with subtitles off) and are bright."""
    A, B = Image.open(shots(name)).convert("RGB"), Image.open(shots(off)).convert("RGB")
    d = ImageChops.difference(A, B).convert("L")
    px = [a for a, m in zip(A.getdata(), d.getdata()) if m > 60 and max(a) > 180]
    if not px: return None, 0
    return tuple(sum(c[i] for c in px) // len(px) for i in range(3)), len(px)

for e in (e for e in ev if e.get("kind") == "result" and not e.get("ok")): check("run", False, str(e))
if scenario == "filestyle":
    on, off = text_colour("bm-ass-styled--keep-on", "bm-ass-styled--off-on"), text_colour("bm-ass-styled--keep-off", "bm-ass-styled--off-off")
    check("keep on = file colours (yellow: blue far below red)", on[0] is not None and on[0][2] < on[0][0] * 0.6, str(on))
    check("keep off = our look (white fill)", off[0] is not None and off[0][2] > off[0][0] * 0.85, str(off))
elif scenario == "start":
    for t in [e for e in ev if e.get("kind") == "tracks" and e.get("step") == "start"]:
        forced = [s for s in t["subtitles"] if "forced=true" in s]
        playing = t["playing"]
        check(f"{t['title']} list once", t["distinct"], str(t["subtitles"]))
        check(f"{t['title']} start picked a forced track", any(f"[{playing} " in s for s in forced), f"playing={playing} forced={forced}")
        a, b = f"{t['title']}--start-chosen-by-rule", f"{t['title']}--start-off"
        if os.path.exists(shots(a)) and os.path.exists(shots(b)):
            n = diff_px(a, b); check(f"{t['title']} forced cue drawn at the cue (differs from off)", n > 500, f"{n} px")
elif scenario == "memory":
    for e in (e for e in ev if e.get("kind") == "tracks"): check(f"{e['title']} {e['step']} list once", e["distinct"], str(e["subtitles"]))
    for e in (e for e in ev if e.get("kind") == "memory" and "got" in e): check(f"{e['title']} {e['step']}", e["ok"], f"want {e['want']} got {e['got']}")
elif scenario == "download":
    for e in (e for e in ev if e.get("kind") == "downloaded"): check(f"{e['title']} stored", e["file"], str(e["subtitleFiles"]))
    for e in (e for e in ev if e.get("kind") == "offline"): check(f"{e['title']} plays offline", e["position"] > 0, str(e))
    # Labels the stored title must show (the same ones as online): the file's external tracks ("... · Datei") and the embedded text tracks of the stored file, each once.
    for e in (e for e in ev if e.get("kind") == "tracks" and e.get("step") == "offline"):
        names = e["subtitles"]; want = {"bm-ext-subs": ["Englisch · SRT · Datei", "Deutsch · ASS · Datei"],
                                      "bm-multi-mkv": ["Englisch · SRT", "Deutsch · ASS"]}.get(e["title"], [])
        check(f"{e['title']} offline labels", bool(names) and e["distinct"] and all(any(w in n for n in names) for w in want), str(names))
    shots_off = [f for f in os.listdir(f"{out}/shots") if "--offline-" in f and not f.endswith("offline-off.png")]
    check("a cue shot per stored title", len({f.split("--")[0] for f in shots_off}) >= len({e["title"] for e in ev if e.get("kind") == "offline"}), str(shots_off))
    for n in sorted(f[:-4] for f in os.listdir(f"{out}/shots") if "--offline-" in f and not f.endswith("offline-off.png")):
        t = n.split("--")[0]; d = diff_px(n, f"{t}--offline-off"); check(f"{n} cue drawn offline", d > 500, f"{d} px vs off")
elif scenario == "timing":
    for e in (e for e in ev if e.get("kind") == "timing"): check(f"timing {e['phase']}", e["ok"], json.dumps({k: v for k, v in e.items() if k not in ("kind", "t")}))
print("ALL PASS" if res and all(res) else "NOT ALL PASS")
