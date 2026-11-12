#!/usr/bin/env python3 -I
"""Proves that a subtitle look changed on another device reaches the running Mac app, and measures how long it takes.

usage: look-sync-proof.py [mac|iphone] [--port 18907] [--wait 12]   (iphone: the "Swiftly Live iPhone" simulator, app built by
`xcodebuild -scheme SwiftlyLive-iOS -derivedDataPath ~/Library/Caches/swiftly-dd/<pool>-sim`; booted and shut down here)
Starts the fixture server (it keeps `/DisplayPreferences/swiftly` in memory), opens the Mac live build with two titles in
`-SwiftlyLiveLookWatch` mode and plays "another device": POSTs the same body a second client would write.
  1. look -> yellow while title 1 plays: seconds until the open player's overlay draws it (`overlay changed`).
  2. look -> grey, then title 2 is started `--wait` seconds later: the new player's overlay must start grey (`overlay made`).
Prints one JSON object. DerivedData `~/Library/Caches/swiftly-dd/<SWIFTLY_POOL>-mac` (build it with live-lauf.py mac first).
"""
import argparse, json, os, shutil, subprocess, sys, time, urllib.request

HOME = os.path.expanduser("~")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POOL = os.environ.get("SWIFTLY_POOL", "pool-3")
APP = f"{HOME}/Library/Caches/swiftly-dd/{POOL}-mac/Build/Products/Debug/Swiftly.app"
BOX = f"{HOME}/Library/Containers/de.paulherter.swiftly/Data/tmp/swiftly-live"
MEDIA = f"{HOME}/Library/Caches/swiftly-live-media"

SIMAPP = f"{HOME}/Library/Caches/swiftly-dd/{POOL}-sim/Build/Products/Debug-iphonesimulator/Swiftly-iOS.app"
BUNDLE = "de.paulherter.swiftly"
HOSTBOX = f"{HOME}/Library/Caches/swiftly-live-runs/look-sync-ios"
DEVICE = "mac"
UDID = None

def sh(cmd, **kw): return subprocess.run(cmd, text=True, capture_output=True, **kw)

def start_app(url):
    global BOX, UDID
    args = ["-SwiftlyFixture", url, "-SwiftlyLiveTitles", "bm-pgs-mkv,bm-h264-aac-mp4", "-SwiftlyLiveDir", BOX, "-SwiftlyLiveLookWatch"]
    if DEVICE == "mac":
        subprocess.run(["pkill", "-f", f"{APP}/Contents/MacOS/Swiftly"])
        subprocess.run(["open", "-n", "-a", APP, "--args"] + args)
        return
    devs = json.loads(sh(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)["devices"]
    UDID = next(d["udid"] for ds in devs.values() for d in ds if d["name"] == "Swiftly Live iPhone")
    booted = json.loads(sh(["xcrun", "simctl", "list", "devices", "booted", "-j"]).stdout)["devices"]
    other = [d["name"] for ds in booted.values() for d in ds if d["udid"] != UDID]
    if other: sys.exit("another simulator is booted: " + ", ".join(other))
    sh(["xcrun", "simctl", "boot", UDID]); sh(["xcrun", "simctl", "bootstatus", UDID])
    sh(["xcrun", "simctl", "install", UDID, SIMAPP])
    r = sh(["xcrun", "simctl", "launch", "--terminate-running-process", UDID, BUNDLE] + args)
    if r.returncode: sys.exit("launch failed: " + r.stderr)

def stop_app():
    if DEVICE == "mac": subprocess.run(["pkill", "-f", f"{APP}/Contents/MacOS/Swiftly"])
    elif UDID: sh(["xcrun", "simctl", "terminate", UDID, BUNDLE]); sh(["xcrun", "simctl", "shutdown", UDID])

def events():
    try: return [json.loads(l) for l in open(f"{BOX}/events.jsonl").read().splitlines() if l.strip().startswith("{")]
    except OSError: return []

def wait(pred, secs, what):
    end = time.time() + secs
    while time.time() < end:
        e = next((e for e in events() if pred(e)), None)
        if e: return e
        time.sleep(0.05)
    sys.exit(f"timeout waiting for {what}")

def main():
    global DEVICE, BOX
    ap = argparse.ArgumentParser(); ap.add_argument("device", nargs="?", default="mac", choices=["mac", "iphone"]); ap.add_argument("--port", type=int, default=18907); ap.add_argument("--wait", type=float, default=12)
    a = ap.parse_args(); DEVICE = a.device
    if DEVICE == "iphone": BOX = HOSTBOX
    url = f"http://127.0.0.1:{a.port}"
    srv = subprocess.Popen([f"{ROOT}/target/debug/xtask", "fixture-server", "--port", str(a.port)],
                           env=dict(os.environ, SWIFTLY_FIXTURE_MEDIA_DIR=MEDIA), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ROOT)
    out = {}
    try:
        for _ in range(50):
            try: urllib.request.urlopen(url + "/System/Info/Public", timeout=1); break
            except OSError: time.sleep(0.2)
        def prefs(): return json.load(urllib.request.urlopen(url + "/DisplayPreferences/swiftly?userId=u1&client=Swiftly")).get("CustomPrefs", {})
        def other_device(colour):
            now_ms = str(int(time.time() * 1000))
            body = {"Id": "swiftly", "CustomPrefs": {**prefs(), "swiftly.utAussehen": json.dumps({"colour": colour, "size": "large"}),
                                                    "swiftly.changed": now_ms, "swiftly.format": "1"}}
            req = urllib.request.Request(url + "/DisplayPreferences/swiftly?userId=u1&client=Swiftly", json.dumps(body).encode(),
                                         {"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=5).read()
            return time.time()
        shutil.rmtree(BOX, ignore_errors=True); os.makedirs(BOX)
        start_app(url)
        wait(lambda e: e.get("kind") == "watch-ready" and e.get("n") == 0, 90, "title 1 playing")
        if DEVICE == "mac": subprocess.run(["open", "-a", APP]); time.sleep(1.5)  # in front, as for a user watching a title (the sync polls only then)
        made = [e for e in events() if e.get("kind") == "overlay" and e.get("what") == "made"]
        out["title1_overlay_made"] = made[-1]["colour"] if made else None
        # the app's own first run pushes the defaults; wait until the server holds them
        for _ in range(100):
            if "swiftly.changed" in prefs(): break
            time.sleep(0.2)
        # Worst case: the change lands right after a run ended, so the next poll tick (30 s) has to find it.
        ran = wait(lambda e: e.get("kind") == "sync-run" and e.get("what") == "answer", 70, "a sync run of the running app")
        t0 = other_device("yellow")
        e = wait(lambda e: e.get("kind") == "overlay" and e.get("what") == "changed" and e.get("colour") == "yellow" and e["t"] >= t0 - 0.01, 60, "yellow in the open player")
        out["last_run_before_change_s"] = round(t0 - ran["t"], 2)
        out["open_player_seconds"] = round(e["t"] - t0, 2)
        # the app echoes the normalised look back (a push) a few seconds later; the second change comes after that
        wait(lambda e: e.get("kind") == "sync-run" and e.get("what") == "answer" and e["t"] > t0 + out["open_player_seconds"] and "pushed" in e.get("result", ""), 20, "echo push")
        time.sleep(0.3)
        t1 = other_device("grey")
        time.sleep(a.wait)
        early = [x for x in events() if x.get("kind") == "overlay" and x.get("what") == "changed" and x.get("colour") == "grey" and x["t"] >= t1 - 0.01]
        out["grey_in_open_player_before_next_title_seconds"] = round(early[0]["t"] - t1, 2) if early else None
        open(f"{BOX}/next-0", "w").close()
        tn = time.time()
        m = wait(lambda e: e.get("kind") == "overlay" and e.get("what") == "made" and e["t"] >= tn - 0.01, 60, "title 2 overlay")
        out["title2_overlay_made_colour"] = m["colour"]
        out["title2_started_seconds_after_change"] = round(m["t"] - t1, 2)
        out["ok"] = out["open_player_seconds"] <= 30 and out["title2_overlay_made_colour"] == "grey"
        open(f"{BOX}/next-1", "w").close()
    finally:
        stop_app()
        srv.kill(); srv.wait()
    print(json.dumps(out, indent=1))
    shutil.copy(f"{BOX}/events.jsonl", f"{HOME}/Library/Caches/swiftly-live-runs/look-sync-{DEVICE}-events.jsonl") if os.path.isdir(f"{HOME}/Library/Caches/swiftly-live-runs") else None

main()
