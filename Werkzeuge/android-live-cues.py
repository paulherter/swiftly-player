#!/usr/bin/env python3
"""Subtitle cue-time shots, resume and next-episode checks in the RUNNING Android app (emulator already up, fixture server on 18466).

usage: android-live-cues.py <serial> play <title> [--kind jellyfin|plex] [--sub N] [--pause-at S] [--since S] [--next] [--shot FILE] [--wait S]
       android-live-cues.py <serial> cue <title> <sub-index> <cue-at-s> <outside-at-s> [--kind ..] [--since S]
Drives the debug launch extras (`DebugPlay.kt`): the player seeks to the position and pauses, so the frame with the subtitle on and the
frame with it off are the same picture and the changed pixels are the subtitle. Prints one JSON line. Needs Pillow/numpy (live venv).
"""
import argparse, base64, json, os, re, subprocess, sys, time
VENV = os.path.expanduser("~/Library/Caches/swiftly-live-venv/bin/python")
if os.path.exists(VENV) and "LIVE_VENV" not in os.environ:
    os.environ["LIVE_VENV"] = "1"; os.execv(VENV, [VENV] + sys.argv)
import numpy as np
from PIL import Image
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PKG = "de.paulherter.swiftly"; SERVER = "http://10.0.2.2:" + os.environ.get("SWIFTLY_FIXTURE_PORT", "18466")
ENV = f"source {ROOT}/Werkzeuge/android-environment.sh >/dev/null 2>&1; "

def sh(c): return subprocess.run(ENV + c, shell=True, capture_output=True, text=True).stdout

def session(kind):
    if kind == "plex":
        s = {"accessToken": "fixture", "userID": "demo", "userName": "demo", "serverURL": SERVER, "kind": "plex",
             "plex": {"machineIdentifier": "plexfx", "serverName": "Fixture Plex", "accountToken": "fixture", "isLocal": True}}
    else:
        s = {"accessToken": "fixture-token", "userID": "u1", "userName": "demo", "serverURL": SERVER}
    return base64.b64encode(json.dumps(s).encode()).decode()

def play(ser, title, kind="jellyfin", sub=None, pause_at=None, since=None, nxt=False, shot=None, wait=60, activity="MainActivity", until=None):
    adb = f"adb -s {ser}"
    sh(f"{adb} shell am force-stop {PKG}; {adb} shell pm clear {PKG}; {adb} logcat -c")
    ex = f"--es testServer {SERVER} --es testSessionB64 {session(kind)} --es testPlay {title}"
    for k, v in (("testSubtitle", sub), ("testPauseAt", pause_at), ("testSince", since)):
        if v is not None: ex += f" --es {k} {v}"
    if nxt: ex += " --es testNext 1"
    sh(f"{adb} shell am start -n {PKG}/.{activity} {ex}")
    want = until or ("[Test] pausiert" if pause_at is not None else "[Media3] Erstes Bild")
    end = time.time() + wait; log = ""
    while time.time() < end:
        time.sleep(2); log = sh(f"{adb} logcat -d -s Swiftly:I")
        if want in log: break
    time.sleep(2)
    if shot:
        open(shot, "wb").write(subprocess.run(ENV + f"{adb} exec-out screencap -p", shell=True, capture_output=True).stdout)
    return sh(f"{adb} logcat -d -s Swiftly:V") if False else sh(f"{adb} logcat -d -s Swiftly:I")

def luma(a): return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
def diff(a, b):
    A = np.asarray(Image.open(a).convert("RGB")).astype(np.int16); B = np.asarray(Image.open(b).convert("RGB")).astype(np.int16)
    if A.shape != B.shape: return None
    ch = np.abs(luma(A) - luma(B)) > 40
    h = A.shape[0]; ch[:int(h * 0.05)] = False  # status bar clock
    ys = np.where(ch.any(axis=1))[0]
    return {"changed_px": int(ch.sum()), "light_px": int((ch & (luma(B) >= 200)).sum()),
            "rows": [int(ys.min()), int(ys.max())] if len(ys) else None, "height": h}

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("serial"); ap.add_argument("cmd", choices=["play", "cue"]); ap.add_argument("title")
    ap.add_argument("rest", nargs="*"); ap.add_argument("--kind", default="jellyfin"); ap.add_argument("--sub"); ap.add_argument("--pause-at")
    ap.add_argument("--since"); ap.add_argument("--next", action="store_true"); ap.add_argument("--shot"); ap.add_argument("--wait", type=int, default=60)
    ap.add_argument("--until"); ap.add_argument("--activity", default="MainActivity")
    a, extra = ap.parse_known_args(); a.rest = a.rest + extra
    out = f"{ROOT}/build/android-live/cues"; os.makedirs(out, exist_ok=True)
    act = a.activity
    if a.cmd == "play":
        log = play(a.serial, a.title, a.kind, a.sub, a.pause_at, a.since, a.next, a.shot, a.wait, act, a.until)
        print("\n".join(l for l in log.splitlines() if re.search(r"\[(Plan|Spuren|Test|Media3|Karte|Wechsel)\]|\[Media3\]", l)))
    else:
        idx, cue, outside = a.rest
        res = {}
        for name, sub, pos in (("off", -1, cue), ("on", idx, cue), ("outside-on", idx, outside), ("outside-off", -1, outside)):
            png = f"{out}/{a.title}-{name}.png"
            log = play(a.serial, a.title, a.kind, sub, pos, a.since, False, png, a.wait, act)
            res[name] = {"paused": "[Test] pausiert" in log, "track": re.findall(r"\[Spuren\] Test: .*", log)[-1:]}
        res["cue"] = diff(f"{out}/{a.title}-off.png", f"{out}/{a.title}-on.png")
        res["outside"] = diff(f"{out}/{a.title}-outside-off.png", f"{out}/{a.title}-outside-on.png")
        c = res["cue"]; o = res["outside"]
        low = lambda d: bool(d and d["rows"] and d["rows"][0] > 0.6 * d["height"])  # the subtitle sits in the lower part
        res["verdict"] = bool(c and c["changed_px"] > 150 and low(c) and o and o["changed_px"] < 60)
        print(json.dumps({a.title: res}))
main()
