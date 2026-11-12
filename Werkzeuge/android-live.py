#!/usr/bin/env python3
"""The running-app media matrix on an Android emulator (phone 5554 / TV 5556), against the xtask fixture server.

usage: android-live.py phone|tv [--kind jellyfin|plex] [--titles a,b] [--no-install] [--out DIR]
For every title: force-stop the app, launch it with the debug extras (testServer + testSessionB64 + testPlay), wait for the
player's first frame, check the log (plan line, video format, errors), take two screenshots, and judge them by pixels
(not black, not green-dominated, picture changes over time). Result: DIR/result.json and DIR/<title>.png.
Needs the debug APK installed (`cd Android && ./gradlew :phone:assembleDirectDebug`) and the Pillow venv
~/Library/Caches/swiftly-live-venv (re-runs itself in it). The emulator and the fixture server are started and stopped here.
"""
import argparse, base64, glob, json, os, re, subprocess, sys, time

VENV = os.path.expanduser("~/Library/Caches/swiftly-live-venv/bin/python")
if os.path.exists(VENV) and "LIVE_VENV" not in os.environ:
    os.environ["LIVE_VENV"] = "1"; os.execv(VENV, [VENV] + sys.argv)
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PKG = "de.paulherter.swiftly"
FIX = 18466
DEV = {"phone": ("swiftly-handy", 5554), "tv": ("swiftly-tv", 5556)}


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw).stdout


def stats(png):
    a = np.asarray(Image.open(png).convert("RGB")).astype(np.int16)
    h = a.shape[0]
    a = a[int(h * 0.08):int(h * 0.92)]  # system bars out
    luma = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    green = ((a[..., 1] - np.maximum(a[..., 0], a[..., 2])) > 60) & (a[..., 1] > 120)
    return {"luma": round(float(luma.mean()), 1), "green_share": round(float(green.mean()), 3), "std": round(float(luma.std()), 1)}


def picture_diff(png, ref_png):
    """Mean absolute RGB difference (0-255) of the picture area against a reference frame of the source, both at 32x18.
    The picture area is the bounding box of the non-black pixels (the player draws the video letter-boxed on black).
    A decoder that hands over garbage (wrong stride, wrong format) scores far above a correct decode."""
    a = Image.open(png).convert("RGB"); m = np.asarray(a).astype(np.int16).max(axis=2) > 24
    ys, xs = np.where(m[int(a.height * 0.05):int(a.height * 0.95)])
    if len(xs) < 100: return None
    box = (int(xs.min()), int(ys.min()) + int(a.height * 0.05), int(xs.max()) + 1, int(ys.max()) + 1 + int(a.height * 0.05))
    x = np.asarray(a.crop(box).resize((32, 18), Image.BILINEAR)).astype(np.int16)
    r = np.asarray(Image.open(ref_png).convert("RGB").resize((32, 18), Image.BILINEAR)).astype(np.int16)
    return round(float(np.abs(x - r).mean()), 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("device", choices=list(DEV)); ap.add_argument("--kind", default="jellyfin")
    ap.add_argument("--titles"); ap.add_argument("--no-install", action="store_true"); ap.add_argument("--keep", action="store_true")
    ap.add_argument("--out"); ap.add_argument("--wait", type=int, default=45)
    a = ap.parse_args()
    avd, port = DEV[a.device]; ser = f"emulator-{port}"
    out = a.out or f"{ROOT}/build/android-live/{a.device}-{a.kind}"; os.makedirs(out, exist_ok=True)
    media = f"{ROOT}/build/pbench-media"
    env = os.environ.copy(); env["PATH"] = os.path.expanduser("~/.cargo/bin") + ":/opt/homebrew/bin:" + env["PATH"]
    sh(f"cd {ROOT} && source Werkzeuge/android-environment.sh >/dev/null 2>&1; python3 -I Werkzeuge/pruefstand-medien.py {media} | tail -1")
    fixture = None
    if "Failed" in sh(f"curl -s -o /dev/null -w '%{{http_code}}' localhost:{FIX}/System/Info/Public || echo Failed"):
        fixture = subprocess.Popen([f"{ROOT}/target/debug/xtask", "fixture-server", "--port", str(FIX)], env={**env, "SWIFTLY_FIXTURE_MEDIA_DIR": media},
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(2)
    # A first adb call would fork the daemon with our capture pipes and never return: start it detached.
    subprocess.run(f"source {ROOT}/Werkzeuge/android-environment.sh >/dev/null 2>&1; adb start-server", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    adb = f"source {ROOT}/Werkzeuge/android-environment.sh >/dev/null 2>&1; adb -s {ser}"
    emu = None
    if sh(f"{adb} get-state 2>&1").strip() != "device":
        emu = subprocess.Popen(["bash", "-c", f"source {ROOT}/Werkzeuge/android-environment.sh >/dev/null 2>&1; exec emulator -avd {avd} -port {port} -no-window -no-snapshot-load -gpu host -no-audio -no-boot-anim"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sh(f"{adb} wait-for-device")
        while sh(f"{adb} shell getprop sys.boot_completed").strip() != "1": time.sleep(3)
    try:
        if not a.no_install:
            apk = sh(f"ls {ROOT}/Android/phone/build/outputs/apk/direct/debug/*.apk | head -1").strip()
            print(sh(f"{adb} install -r -t {apk}")[-80:].strip())
        server = "http://10.0.2.2:%d" % FIX
        if a.kind == "plex":
            session = {"accessToken": "fixture", "userID": "demo", "userName": "demo", "serverURL": server, "kind": "plex",
                       "plex": {"machineIdentifier": "plexfx", "serverName": "Fixture Plex", "accountToken": "fixture", "isLocal": True}}
        else:
            session = {"accessToken": "fixture-token", "userID": "u1", "userName": "demo", "serverURL": server}
        b64 = base64.b64encode(json.dumps(session).encode()).decode()
        if a.kind == "plex" and not any(f.startswith("plex-90") for f in os.listdir(media)):
            sh(f"python3 -I {ROOT}/Werkzeuge/pruefstand-plex.py {media}")
        # A Plex server knows its titles by rating key (plex-<key>.json, made by pruefstand-plex.py), not by the bench id.
        titles = a.titles.split(",") if a.titles else (sorted(os.path.basename(p)[5:-5] for p in glob.glob(f"{media}/plex-90*.json")) if a.kind == "plex"
                 else sorted(os.path.basename(p)[:-10] for p in os.listdir(media) if p.endswith(".item.json")))
        sh(f"{adb} shell settings put global window_animation_scale 0")
        results = {}
        for t in titles:
            # A saved session (an earlier run, other server kind/port) makes the app skip the debug sign-in: start from clean data.
            sh(f"{adb} shell am force-stop {PKG}"); sh(f"{adb} shell pm clear {PKG}"); sh(f"{adb} logcat -c")
            sh(f"{adb} shell am start -n {PKG}/.MainActivity --es testServer {server} --es testSessionB64 {b64} --es testPlay {t}")
            end = time.time() + a.wait; log = ""; frame = False
            while time.time() < end:
                time.sleep(2); log = sh(f"{adb} logcat -d -s Swiftly:I")
                frame = "[Media3] Erstes Bild" in log
                if frame: break
            time.sleep(3)
            shots = []
            for i in range(2):
                png = f"{out}/{t}-{i}.png"
                open(png, "wb").write(subprocess.run(f"{adb} exec-out screencap -p", shell=True, capture_output=True).stdout); shots.append(png); time.sleep(2)
            log = sh(f"{adb} logcat -d -s Swiftly:I")
            s0, s1 = stats(shots[0]), stats(shots[1])
            open(f"{out}/{t}.log", "w").write(sh(f"{adb} logcat -d -s Swiftly:V"))
            if a.kind == "plex": src = [open(f"{media}/plex-{t}.media").read().strip()]
            else: src = [f for f in os.listdir(media) if f.startswith(t + ".") and f.rsplit(".", 1)[-1] in ("mp4", "mkv", "ts", "webm", "avi")]
            ref = f"{out}/{t}.ref.png"
            if src: sh(f"ffmpeg -v error -y -i {media}/{src[0]} -ss 3 -frames:v 1 {ref}")
            diff = picture_diff(shots[1], ref) if os.path.exists(ref) else None
            plan = re.findall(r"\[Plan\] .*", log); video = re.findall(r"\[Media3\] Video .*", log); errs = re.findall(r"\[Media3\] Fehler .*", log)
            os.replace(shots[1], f"{out}/{t}.png"); os.remove(shots[0])
            ok_pic = s1["luma"] > 12 and s1["luma"] < 245 and s1["green_share"] < 0.5 and s1["std"] > 3 and (diff is None or diff < 45)
            results[t] = {"plan": plan[-1:] , "video": video[-1:], "errors": errs[-2:], "first_frame": frame, "shot": s1, "ref_diff": diff, "picture_ok": bool(ok_pic and frame and not errs)}
            print(t, "OK" if results[t]["picture_ok"] else "RED", plan[-1:] , video[-1:], errs[-1:], s1, "diff", diff, flush=True)
        json.dump(results, open(f"{out}/result.json", "w"), indent=1)
        sh(f"{adb} shell am force-stop {PKG}")
    finally:
        if not a.keep:
            if emu: sh(f"{adb} emu kill"); emu.wait(timeout=60)
        if fixture: fixture.terminate()


main()
