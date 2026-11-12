#!/usr/bin/env python3
"""Judge of the `pausedseek` scenario: which frame of the bench clip is on screen in each shot?

usage: live-pausedseek-judge.py <run dir> <media file> [--rect x,y,w,h]

The bench clips (testsrc2, 24 fps) burn a clock into the top-left corner. The judge cuts that corner out of every frame of the
clip and out of each screenshot (the video rectangle, default the whole image), finds the nearest frame and reports its time
next to the target the scenario asked for. A shot is ok when the shown time is within 0.25 s of the target.
"""
import json, os, subprocess, sys, tempfile

W, H = 100, 36  # the clock corner, in clip pixels (clip 320x180)
FPS = 24.0

def gray(args, size):
    p = subprocess.run(["ffmpeg", "-v", "error", "-y"] + args + ["-vf", f"crop=iw*{W}/320:ih*{H}/180:0:0,scale={W}:{H},format=gray",
                                                                  "-f", "rawvideo", "-"], capture_output=True, check=True)
    n = W * H
    return [p.stdout[i:i + n] for i in range(0, len(p.stdout) - n + 1, n)]

def main():
    run, media = sys.argv[1], sys.argv[2]
    rect = None
    if "--rect" in sys.argv:
        rect = [int(v) for v in sys.argv[sys.argv.index("--rect") + 1].split(",")]
    refs = gray(["-i", media], None)
    shots = {}
    for l in open(f"{run}/events.jsonl"):
        try: e = json.loads(l)
        except ValueError: continue
        if e.get("kind") == "shot-wanted" and "target" in e: shots[e["name"]] = e
    ok_all = True
    for name, e in shots.items():
        png = f"{run}/shots/{name}.png"
        if not os.path.exists(png): print(name, "no screenshot"); ok_all = False; continue
        pre = f"crop={rect[2]}:{rect[3]}:{rect[0]}:{rect[1]}," if rect else ""
        p = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", png, "-vf",
                            f"{pre}crop=iw*{W}/320:ih*{H}/180:0:0,scale={W}:{H},format=gray", "-f", "rawvideo", "-"],
                           capture_output=True, check=True).stdout
        best = min(range(len(refs)), key=lambda i: sum(abs(a - b) for a, b in zip(p, refs[i])))
        dist = sum(abs(a - b) for a, b in zip(p, refs[best])) / (W * H)
        shown = best / FPS
        ok = abs(shown - e["target"]) <= 0.25
        ok_all &= ok
        print(f"{name:22} target {e['target']:5.2f}  engine position {e['position']:6.2f}  playing {e['playing']}  picture shows {shown:6.2f}"
              f"  (match {dist:4.1f})  {'ok' if ok else 'STALE'}")
    print("ALL OK" if ok_all else "NOT OK")

main()
