#!/usr/bin/env python3 -I
"""The running-app matrix on iPhone simulator, iPad simulator and the Mac app, against the fixture server.

usage: live-lauf.py <iphone|ipad|mac|tv|tv-device> [--kind jellyfin|plex] [--titles a,b,c] [--position S] [--tag T] [--no-build]
                    [--media DIR] [--port N]
Everything lives in fixed folders: DerivedData `~/Library/Caches/swiftly-dd/pool-3-<sim|mac>` (override the slot with
SWIFTLY_POOL), media `~/Library/Caches/swiftly-live-media` (made by `Werkzeuge/pruefstand-medien.py`), results in
`~/Library/Caches/swiftly-live-runs/<device>-<kind>/` (events.jsonl, shots/, pixel.json). Judging: `Werkzeuge/live-pixel.py`.
The catalog is data-driven: every `<id>.item.json` in the media folder is a title (so new clips join without a code change).
`tv` runs the tvOS app in a tvOS simulator (DerivedData `<pool>-tvsim`): installs it, launches it with the live arguments and
takes the screenshots itself with `simctl io screenshot` (a simulator app writes to host folders, so no UI-test target).
`tv-device` is the real Apple TV (see `tv_device`). Otherwise never touches /Applications, a real device or a real server; simulators booted here are shut down at the end.
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, time

HOME = os.path.expanduser("~")
APP_BUNDLE = "de.paulherter.swiftly"
SRV = []  # the fixture server process, so a scenario can cut it ("kill-server" event)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POOL = os.environ.get("SWIFTLY_POOL", "pool-3")
DD = f"{HOME}/Library/Caches/swiftly-dd/{POOL}-"
VENV = f"{HOME}/Library/Caches/swiftly-live-venv/bin/python3"
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode-27.1.app/Contents/Developer")

def sh(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)

def refuse_if_other_booted(own=None):
    """Simulator rule: only ONE simulator booted on the Mac at a time (a second one swapped the Mac). Exits when any
    simulator other than `own` (a udid) is booted; called right before every boot and every `xcodebuild test`."""
    devs = json.loads(sh(["xcrun", "simctl", "list", "devices", "booted", "-j"]).stdout)["devices"]
    other = [f"{d['name']} ({d['udid']})" for ds in devs.values() for d in ds if d["state"] == "Booted" and d["udid"] != own]
    if other: sys.exit("another simulator is booted, not starting: " + ", ".join(other))

def reset_look(udid=None):
    """Every run starts with the default subtitle look: the look is stored in the app's preferences (`utAussehen`) and a
    look-sync run left grey/large behind, which gave false "grey subtitles". A simulator (`udid`) or the Mac app."""
    if udid:
        # `simctl spawn defaults` writes the simulator's own preferences, not the app's: edit the plist in the app container
        # (the app must not run, or its cached copy is written back).
        sh(["xcrun", "simctl", "terminate", udid, APP_BUNDLE])
        r = sh(["xcrun", "simctl", "get_app_container", udid, APP_BUNDLE, "data"])
        plist = f"{r.stdout.strip()}/Library/Preferences/{APP_BUNDLE}.plist"
        if r.returncode == 0 and os.path.exists(plist): sh(["plutil", "-remove", "utAussehen", plist])
        left = os.path.exists(plist) and sh(["plutil", "-extract", "utAussehen", "raw", plist]).returncode == 0
        print("look reset:", "STILL SET" if left else "default")
    else:
        sh(["defaults", "delete", APP_BUNDLE, "utAussehen"])
        sh(["defaults", "delete", f"{HOME}/Library/Containers/{APP_BUNDLE}/Data/Library/Preferences/{APP_BUNDLE}", "utAussehen"])

SIM_TYPES = {"ipad": ("Swiftly Live iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-16GB"),
             "iphone": ("Swiftly Live iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")}

def sim(kind):
    """(udid, booted, runtime) of our own named iPhone / iPad simulator; creates it when missing.
    The iOS 27.1 runtime of Xcode 27.1 supports only the iPhone Duo, so both are made on the newest iOS runtime that
    supports their device type (iOS 27.0: `xcodebuild -downloadPlatform iOS -buildVersion 27.0`)."""
    name, dtype = SIM_TYPES[kind]
    devs = json.loads(sh(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)["devices"]
    for rt, ds in devs.items():
        for d in ds:
            if d["name"] == name: return d["udid"], d["state"] == "Booted", rt
    rts = json.loads(sh(["xcrun", "simctl", "list", "runtimes", "-j"]).stdout)["runtimes"]
    ok = [r for r in rts if r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")
          and any(t["identifier"] == dtype for t in r.get("supportedDeviceTypes", []))]
    if not ok: sys.exit(f"no iOS simulator runtime supports {dtype}")
    rt = sorted(ok, key=lambda r: r["version"])[-1]["identifier"]
    return sh(["xcrun", "simctl", "create", name, dtype, rt]).stdout.strip(), False, rt

# Where each subtitle track of a bench title has a cue (see `Werkzeuge/pruefstand-medien.py`). Every text track of the 10 s
# clips shows at 2.5 s (SRT/ASS/VTT 1-3 s) and so does their PGS (2-4 s), so only the long PGS title differs:
# bm-pgs-mkv has forced + full PGS from 124 s (2 s long) and its SRT at 3-5 s. Stream index -> seconds.
CUES = {"bm-pgs-mkv": {"2": 125.0, "3": 125.0, "4": 4.0},
        # the same clip as Plex title 9002; its streams are keyed by Plex stream id (forced PGS, full PGS, SRT)
        "9002": {"413111": 125.0, "413114": 125.0, "413117": 4.0}}

def cues_file():
    """The cue map as a host file the app reads (`-SwiftlyLiveCues`); a simulator app sees host paths."""
    path = f"{HOME}/Library/Caches/swiftly-live-runs/cues.json"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(CUES, open(path, "w"))
    return path

def screen_locked():
    """True while the login window covers the console session (the Mac app draws no window then)."""
    # The CGSSession dictionaries keep a stale CGSSessionScreenIsLocked key after unlocking; IOConsoleLocked is current.
    out = sh(["ioreg", "-n", "Root", "-d1", "-a"]).stdout
    return bool(re.search(r"<key>IOConsoleLocked</key>\s*<true/>", out))

def server(port, media, bind="127.0.0.1"):
    env = dict(os.environ, SWIFTLY_FIXTURE_MEDIA_DIR=media, SWIFTLY_FIXTURE_BIND=bind)
    p = subprocess.Popen([f"{ROOT}/target/debug/xtask", "fixture-server", "--port", str(port)], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ROOT)
    for _ in range(50):
        if sh(["curl", "-sf", f"http://127.0.0.1:{port}/System/Info/Public"]).returncode == 0: return p
        time.sleep(0.2)
    p.kill(); sys.exit("fixture server did not start")

# Titles the iOS simulator cannot play: they take the software decoder, whose GPUFrameConverter makes a no-copy Metal buffer
# (`newBufferWithLength:options:pointer:copyBytes:deallocator:`) that the simulator's MTLSimDevice rejects with EXC_BREAKPOINT
# (AetherEngine GPUFrameConverter.swift:234, report Swiftly-iOS-2026-11-11-040229.ips). Skipped there, run on a real device.
# Also `bm-dv5-mkv/mp4` (HEVC Dolby Vision 5): "no first picture in 40 s" on the iPhone, iPad and tvOS simulators, no crash. The core plan is
# right (direct play unless the host reports no DV decoder; test `dolby_vision_5_is_transcoded_only_on_a_device_without_a_dolby_vision_decoder`)
# and the Apple host never reports one, so the simulator's missing DV decode is the likely cause; NOT proven, needs a real device.
# `bm-dv5-transcode` is the same file with a server transcode on offer: an Apple host direct-plays it for the same reason.
SIM_LIMIT = {"bm-av110-mkv", "bm-av110-mp4", "bm-dv10-mkv", "bm-dv10-mp4", "bm-dv100-mkv", "bm-dv5-mkv", "bm-dv5-mp4", "bm-dv5-transcode"}

def last_title(events_path):
    """The title the app was opening / playing at the end of events.jsonl (phase `opening("<id>")`), or None."""
    title = None
    for l in (open(events_path).read().splitlines() if os.path.exists(events_path) else []):
        m = re.search(r'opening\(\\?"([^"\\]+)', l)
        if m: title = m.group(1)
    return title

def app_pids(udid, exe="Swiftly-iOS"):
    """Pids of the app under test inside simulator `udid` (the UI test runner has its own name and is not counted)."""
    r = sh(["pgrep", "-f", f"CoreSimulator/Devices/{udid}/.*/{exe}\\.app/{exe}"])
    return [p for p in r.stdout.split() if p]

def glob_new(pattern, since):
    return [f for f in glob.glob(pattern) if os.path.getmtime(f) > since]

def app_crashed(seg_dir, began, alive_seen, pids_now, exe="Swiftly-iOS"):
    """True when the app is gone for good: a crash report newer than the segment start exists, or the app ran once and
    its pid is gone without an `end` event. Only file reads, so `--selftest` can drive it."""
    ev = f"{seg_dir}/events.jsonl"
    if os.path.exists(ev) and '"kind":"end"' in open(ev).read().replace(" ", ""): return False
    if glob_new(f"{HOME}/Library/Logs/DiagnosticReports/{exe}-*.ips", began): return True
    return alive_seen and not pids_now

def ios_segment(a, udid, seg, titles, url, limit=2400):
    """One `xcodebuild test` over `titles` into folder `seg`, watched every 2 s: a dead app ends the segment within seconds
    (the UI test itself would wait its whole timeout). Returns (crashed, output)."""
    import threading
    env = dict(os.environ, TEST_RUNNER_LIVE_SERVER=url, TEST_RUNNER_LIVE_KIND=a.kind, TEST_RUNNER_LIVE_TITLES=",".join(titles),
               TEST_RUNNER_LIVE_DIR=seg, TEST_RUNNER_LIVE_POSITION=str(a.position), TEST_RUNNER_LIVE_CUES=cues_file(), TEST_RUNNER_LIVE_TIMEOUT=str(limit))
    began = time.time()
    p = subprocess.Popen(["xcodebuild", "-quiet", "-project", f"{ROOT}/Swiftly.xcodeproj", "-scheme", "SwiftlyLive-iOS",
                          "-configuration", "Debug", "-destination", f"id={udid}", "-derivedDataPath", DD + "sim",
                          "-resultBundlePath", f"{seg}.xcresult", "test"], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buf = []
    threading.Thread(target=lambda: buf.extend(p.stdout), daemon=True).start()
    alive_seen, gone, crashed = False, 0, False
    while p.poll() is None and time.time() < began + limit + 120:
        pids = app_pids(udid)
        alive_seen |= bool(pids)
        gone = 0 if pids or not alive_seen else gone + 1
        if (gone >= 2 or glob_new(f"{HOME}/Library/Logs/DiagnosticReports/Swiftly-iOS-*.ips", began)) and app_crashed(seg, began, alive_seen, pids):
            crashed = True; break
        time.sleep(2)
    if p.poll() is None:
        p.terminate()
        try: p.wait(15)
        except subprocess.TimeoutExpired: p.kill()
    return crashed, "".join(buf)

def ios_look(a, udid, out, url):
    """`--look`: build, install and launch the iOS app with `-SwiftlyLiveLookPage` (nothing is played), answer its `shot-wanted`
    with a `simctl io screenshot` (a simulator app writes to host folders, so no UI-test target is needed)."""
    if not a.no_build:
        r = sh(["xcodebuild", "-quiet", "-project", f"{ROOT}/Swiftly.xcodeproj", "-scheme", "Swiftly-iOS", "-configuration", "Debug",
                "-destination", f"id={udid}", "-derivedDataPath", DD + "sim", "build"])
        print("\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error:" in l)[:2000])
    sh(["xcrun", "simctl", "install", udid, f"{DD}sim/Build/Products/Debug-iphonesimulator/Swiftly-iOS.app"])
    os.makedirs(f"{out}/shots", exist_ok=True)
    r = sh(["xcrun", "simctl", "launch", "--terminate-running-process", udid, TV_BUNDLE, "-SwiftlyFixture", url, "-SwiftlyLiveTitles", "",
            "-SwiftlyLiveDir", out, "-SwiftlyLiveLookPage"])
    print(r.stdout.strip(), r.stderr.strip()[:300])
    done, end = set(), time.time() + 120
    while time.time() < end:
        ev = f"{out}/events.jsonl"
        stop = False
        for l in (open(ev).read().splitlines() if os.path.exists(ev) else []):
            try: e = json.loads(l)
            except ValueError: continue
            stop |= e.get("kind") == "end"
            if e.get("kind") == "shot-wanted" and e["n"] not in done:
                done.add(e["n"])
                sh(["xcrun", "simctl", "io", udid, "screenshot", f"{out}/shots/{e['name']}.png"])
                open(f"{out}/ack-{e['n']}", "w").close()
        if stop: break
        time.sleep(0.2)
    sh(["xcrun", "simctl", "terminate", udid, TV_BUNDLE])

def ios_scenario(a, udid, out, url):
    """`--scenario <name>`: build, install and launch the iOS app with `-SwiftlyLiveScenario` (see `LiveRun.scenario`), answer
    its `shot-wanted` with `simctl io screenshot`, and its `kill-server` by stopping the fixture (offline proof)."""
    if not a.no_build:
        r = sh(["xcodebuild", "-quiet", "-project", f"{ROOT}/Swiftly.xcodeproj", "-scheme", "Swiftly-iOS", "-configuration", "Debug",
                "-destination", f"id={udid}", "-derivedDataPath", DD + "sim", "build"])
        print("\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error:" in l or "BUILD" in l)[:2000])
    sh(["xcrun", "simctl", "uninstall", udid, APP_BUNDLE])  # a fresh container: no stored look, no per-title memory from an earlier run
    sh(["xcrun", "simctl", "install", udid, f"{DD}sim/Build/Products/Debug-iphonesimulator/Swiftly-iOS.app"])
    os.makedirs(f"{out}/shots", exist_ok=True)
    r = sh(["xcrun", "simctl", "launch", "--terminate-running-process", udid, APP_BUNDLE, "-SwiftlyFixture", url,
            "-SwiftlyFixtureKind", a.kind, "-SwiftlyLiveTitles", a.titles or "", "-SwiftlyLiveDir", out,
            "-SwiftlyLivePosition", str(a.position), "-SwiftlyLiveCues", cues_file(), "-SwiftlyLiveScenario", a.scenario] + a.arg)
    print(r.stdout.strip(), r.stderr.strip()[:300])
    done, end = set(), time.time() + 900
    while time.time() < end:
        ev = f"{out}/events.jsonl"
        stop = False
        for l in (open(ev).read().splitlines() if os.path.exists(ev) else []):
            try: e = json.loads(l)
            except ValueError: continue
            stop |= e.get("kind") == "end"
            if e.get("kind") == "kill-server" and "kill" not in done:
                done.add("kill")
                for p in SRV: p.terminate(); p.wait(10)
                open(f"{out}/offline-go", "w").close()
            if e.get("kind") == "shot-wanted" and e["n"] not in done:
                done.add(e["n"])
                sh(["xcrun", "simctl", "io", udid, "screenshot", f"{out}/shots/{e['name']}.png"])
                open(f"{out}/ack-{e['n']}", "w").close()
        if stop: break
        time.sleep(0.2)
    sh(["xcrun", "simctl", "terminate", udid, APP_BUNDLE])

def ios(a, out, titles, url):
    udid, booted, _ = sim(a.device)
    refuse_if_other_booted(udid)
    if not booted: sh(["xcrun", "simctl", "boot", udid]); sh(["xcrun", "simctl", "bootstatus", udid])
    reset_look(udid)
    if a.scenario:
        try: ios_scenario(a, udid, out, url)
        finally:
            if not booted: sh(["xcrun", "simctl", "shutdown", udid])
        return
    if a.look:
        try: ios_look(a, udid, out, url)
        finally:
            if not booted: sh(["xcrun", "simctl", "shutdown", udid])
        return
    status = {"crash": [], "sim-limit": [], "ran": []}
    try:
        if not a.include_sim_limit:
            status["sim-limit"] = [t for t in titles if t in SIM_LIMIT]
            titles = [t for t in titles if t not in SIM_LIMIT]
        k, todo = 0, list(titles)
        while todo:
            k += 1
            seg = f"{out}-seg{k}"
            shutil.rmtree(seg, ignore_errors=True); shutil.rmtree(seg + ".xcresult", ignore_errors=True)
            crashed, text = ios_segment(a, udid, seg, todo, url)
            print("\n".join(l for l in text.splitlines() if re.search(r"error:|TEST |Executed|failed", l))[:1500])
            bad = last_title(f"{seg}/events.jsonl") if crashed else None
            if crashed:
                bad = bad if bad in todo else todo[0]
                status["ran"] += todo[:todo.index(bad)]
                status["crash"].append(bad); print(f"CRASH: app died on {bad}; marked red, moving on")
                todo = todo[todo.index(bad) + 1:]
            else:
                status["ran"] += todo; todo = []
            os.makedirs(f"{out}/shots", exist_ok=True)  # merge the segment into `out` (events in order, shots side by side)
            if os.path.exists(f"{seg}/events.jsonl"): open(f"{out}/events.jsonl", "a").write(open(f"{seg}/events.jsonl").read())
            for f in glob.glob(f"{seg}/shots/*"): shutil.copy(f, f"{out}/shots/")
    finally:
        json.dump(status, open(f"{out}/status.json", "w"), indent=1)
        print("status:", json.dumps(status))
        if not booted: sh(["xcrun", "simctl", "shutdown", udid])

def mac(a, out, titles, url):
    if not a.no_build:
        r = sh(["xcodebuild", "-quiet", "-project", f"{ROOT}/Swiftly.xcodeproj", "-scheme", "SwiftlyLive-macOS", "-configuration", "Debug",
                "-destination", "platform=macOS", "-derivedDataPath", DD + "mac", "build"])
        print("\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error:" in l)[:2000])
    app = f"{DD}mac/Build/Products/Debug/Swiftly.app"
    reset_look()
    box = f"{HOME}/Library/Containers/de.paulherter.swiftly/Data/tmp/swiftly-live"
    shutil.rmtree(box, ignore_errors=True)
    # The Mac app is sandboxed: it cannot read the host's cue file, so it gets a copy inside its own container.
    os.makedirs(box, exist_ok=True)
    shutil.copy(cues_file(), f"{box}/cues.json")
    # Through LaunchServices (`open`): a process started straight from a headless shell has no window-server
    # connection, so it never shows a window and never reaches the code that writes the first event.
    subprocess.run(["pkill", "-f", f"{app}/Contents/MacOS/Swiftly"])
    sh(["open", "-n", "-a", app, "--args", "-SwiftlyFixture", url, "-SwiftlyFixtureKind", a.kind,
        "-SwiftlyLiveTitles", ",".join(titles), "-SwiftlyLiveDir", box, "-SwiftlyLivePosition", str(a.position), "-SwiftlyLiveCues", f"{box}/cues.json"] + (["-SwiftlyLiveFullscreen"] if a.fullscreen else []))
    alive = lambda: sh(["pgrep", "-f", f"{app}/Contents/MacOS/Swiftly"]).returncode == 0
    os.makedirs(f"{out}/shots", exist_ok=True)
    done, started, begin, end = set(), False, time.time(), time.time() + 2400
    ev = f"{box}/events.jsonl"
    try:
        while time.time() < end and alive():
            lines = open(ev).read().splitlines() if os.path.exists(ev) else []
            started = started or any('"kind":"start"' in l for l in lines)
            if not started and time.time() - begin > 60:
                sys.exit("the app runs but wrote no 'start' event within 60 s: no window-server session (locked Mac, or launched "
                         "outside the user's GUI session) or the app never reached MainView. Nothing to wait for.")
            stop = False
            for l in lines:
                try: e = json.loads(l)
                except ValueError: continue
                stop |= e.get("kind") == "end"
                if e.get("kind") == "shot-wanted" and e["n"] not in done:
                    done.add(e["n"])
                    png = f"{out}/shots/{e['name']}.png"
                    if e.get("selfShot"): shutil.copy(e["selfShot"], png)  # the app drew its own window
                    else: sh(["screencapture", "-x", "-o", "-l", str(e.get("windowNumber", 0)), png])
                    open(f"{box}/ack-{e['n']}", "w").close()
            if stop: break
            time.sleep(0.2)
    finally:
        if not alive(): print("app exited by itself after", len(done), "shots")
        subprocess.run(["pkill", "-f", f"{app}/Contents/MacOS/Swiftly"])
    if os.path.exists(ev): shutil.copy(ev, f"{out}/events.jsonl")

# --- tvOS simulator (own functions so the runner merges easily with the other devices) ---
TV_NAME = "swiftly-tv-w8"
TV_BUNDLE = "de.paulherter.swiftly"

def tv_sim():
    """(udid, booted) of the tvOS simulator named TV_NAME, or the first Apple TV one; creates TV_NAME when there is none."""
    devs = json.loads(sh(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)["devices"]
    rts = [r for r in devs if "tvOS" in r]
    if not rts: sys.exit("no tvOS simulator runtime (xcodebuild -downloadPlatform tvOS)")
    for rt in rts:
        for d in devs[rt]:
            if d["name"] == TV_NAME: return d["udid"], d["state"] == "Booted"
    u = sh(["xcrun", "simctl", "create", TV_NAME, "Apple TV 4K (3rd generation)", rts[-1]]).stdout.strip()
    return u, False

def tv_watchdog(udid, since):
    """PineBoard (the tvOS home screen process) must not restart in a loop: more than 2 pids since this boot = stop.
    `since` is the host time of the boot: older log lines belong to earlier boots, which have other pids anyway."""
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    out = sh(["xcrun", "simctl", "spawn", udid, "log", "show", "--start", start, "--style", "compact",
              "--predicate", 'process == "PineBoard"']).stdout
    return len(set(re.findall(r"PineBoard\[(\d+)\]", out)))

# The tvOS simulator also crashes in the software decoder path (same MTLSimDevice no-copy buffer) for these; the real
# Apple TV plays them (`tv-device`).
TV_SIM_LIMIT = SIM_LIMIT | {"bm-vp9-opus-webm", "bm-mpeg4-mp3-avi"}

def tv(a, out, titles, url):
    if not a.include_sim_limit: titles = [t for t in titles if t not in TV_SIM_LIMIT]
    udid, booted = tv_sim()
    refuse_if_other_booted(udid)
    since = time.time() - 180
    if not booted: since = time.time(); sh(["xcrun", "simctl", "boot", udid]); sh(["xcrun", "simctl", "bootstatus", udid])
    try:
        time.sleep(5)
        if (n := tv_watchdog(udid, since)) > 2:
            open(f"{out}/WATCHDOG", "w").write(f"PineBoard had {n} pids since the boot\n")
            sys.exit(f"PineBoard had {n} pids: the tvOS simulator is stopped")
        reset_look(udid)
        if not a.no_build:
            r = sh(["xcodebuild", "-quiet", "-project", f"{ROOT}/Swiftly.xcodeproj", "-scheme", "Swiftly-tvOS", "-configuration", "Debug",
                    "-destination", f"id={udid}", "-derivedDataPath", DD + "tvsim", "build"])
            print("\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error:" in l)[:2000])
        app = f"{DD}tvsim/Build/Products/Debug-appletvsimulator/Swiftly-tvOS.app"
        if a.scenario: sh(["xcrun", "simctl", "uninstall", udid, TV_BUNDLE])  # a fresh container: no per-title memory from an earlier run
        sh(["xcrun", "simctl", "install", udid, app])
        # The profile picker (a real Bool in the defaults, a launch argument would be a string) would cover the player.
        sh(["xcrun", "simctl", "spawn", udid, "defaults", "write", TV_BUNDLE, "askProfileAtLaunch", "-bool", "NO"])
        os.makedirs(f"{out}/shots", exist_ok=True)
        r = sh(["xcrun", "simctl", "launch", "--terminate-running-process", udid, TV_BUNDLE, "-SwiftlyFixture", url,
                "-SwiftlyFixtureKind", a.kind, "-SwiftlyLiveTitles", ",".join(titles), "-SwiftlyLiveDir", out,
                "-SwiftlyLivePosition", str(a.position), "-SwiftlyLiveCues", cues_file()] + (["-SwiftlyLiveLookPage"] if a.look else [])
                + (["-SwiftlyLiveScenario", a.scenario] if a.scenario else []) + a.arg)
        print(r.stdout.strip(), r.stderr.strip()[:300])
        done, end, began = set(), time.time() + 2400, time.time()
        while time.time() < end:
            ev = f"{out}/events.jsonl"
            stop = False
            # A crashed app never writes `end`: its report in DiagnosticReports stops the wait and names the last phase.
            crash = [f for f in glob.glob(f"{HOME}/Library/Logs/DiagnosticReports/Swiftly-tvOS-*.ips") if os.path.getmtime(f) > began]
            if crash:
                open(f"{out}/CRASH", "w").write(crash[0] + "\n"); print("app crashed:", crash[0]); break
            for l in (open(ev).read().splitlines() if os.path.exists(ev) else []):
                try: e = json.loads(l)
                except ValueError: continue
                stop |= e.get("kind") == "end"
                if e.get("kind") == "kill-server" and "kill" not in done:
                    done.add("kill")  # the download scenario: the fixture goes away, the title must play from the file
                    for p in SRV: p.terminate(); p.wait(10)
                    open(f"{out}/offline-go", "w").close()
                if e.get("kind") == "focus" and "startRetry" in e["target"] and e["t"] not in done:
                    done.add(e["t"])  # the start-failure screen with Retry focused is on screen now
                    time.sleep(1.0)
                    sh(["xcrun", "simctl", "io", udid, "screenshot", f"{out}/shots/failed-{len(done)}.png"])
                if e.get("kind") == "shot-wanted" and e["n"] not in done:
                    done.add(e["n"])
                    sh(["xcrun", "simctl", "io", udid, "screenshot", f"{out}/shots/{e['name']}.png"])
                    open(f"{out}/ack-{e['n']}", "w").close()
            if stop: break
            time.sleep(0.2)
        sh(["xcrun", "simctl", "terminate", udid, TV_BUNDLE])
    finally:
        if not booted: sh(["xcrun", "simctl", "shutdown", udid])

def tv_device(a, out, titles, url):
    """The real Apple TV (`tv-device`): a Debug build is installed over the app, launched with `-SwiftlyLiveMemory` (the fixture
    account lives in memory only: nothing reaches the Keychain, the stored accounts stay as they are) and driven through devicectl.
    The handshake folder is the app's own `tmp/swiftly-live` (sandbox): events are copied out, acks and the cue file copied in,
    screenshots made with `devicectl device capture screenshot`. The Release app is put back afterwards with Werkzeuge/to-appletv.sh."""
    dev, udid = None, None
    tmp = f"{out}/devices.json"
    sh(["xcrun", "devicectl", "list", "devices", "--json-output", tmp])
    for g in json.load(open(tmp))["result"]["devices"]:
        h = g.get("hardwareProperties", {})
        if h.get("platform") == "tvOS" and h.get("reality") == "physical": dev, udid = g["identifier"], h.get("udid"); break
    if not dev: sys.exit("no paired Apple TV found")
    if sh(["pgrep", "-f", "to-appletv.sh"]).stdout.strip(): sys.exit("to-appletv.sh is running: wait for it")
    team = re.search(r"DEVELOPMENT_TEAM:\s*(\w+)", open(f"{ROOT}/project.yml").read()).group(1)
    if not a.no_build:
        r = sh(["xcodebuild", "-quiet", "-allowProvisioningUpdates", "-project", f"{ROOT}/Swiftly.xcodeproj", "-scheme", "Swiftly-tvOS",
                "-configuration", "Debug", "-destination", f"id={udid}", "-derivedDataPath", DD + "tvdev",
                f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic", "ARCHS=arm64", "build"])
        print("\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error:" in l)[:2000])
    app = f"{DD}tvdev/Build/Products/Debug-appletvos/Swiftly-tvOS.app"
    if not os.path.isdir(app): sys.exit("no device build at " + app)
    print("built:", time.ctime(os.path.getmtime(f"{app}/Swiftly-tvOS")))
    r = sh(["xcrun", "devicectl", "device", "install", "app", "--device", dev, app]); print(r.stdout[-300:], r.stderr[-300:])
    if r.returncode: sys.exit("install failed")
    def pull(remote, local):
        return sh(["xcrun", "devicectl", "device", "copy", "from", "--device", dev, "--source", remote, "--destination", local,
                   "--domain-type", "appDataContainer", "--domain-identifier", TV_BUNDLE, "--timeout", "30"]).returncode == 0
    def push(local, remote):
        return sh(["xcrun", "devicectl", "device", "copy", "to", "--device", dev, "--source", local, "--destination", remote,
                   "--domain-type", "appDataContainer", "--domain-identifier", TV_BUNDLE, "--timeout", "30"]).returncode == 0
    def launch(extra):
        return sh(["xcrun", "devicectl", "device", "process", "launch", "--terminate-existing", "--device", dev, TV_BUNDLE, "--",
                   "-SwiftlyFixture", url, "-SwiftlyFixtureKind", a.kind, "-SwiftlyLiveMemory"] + extra)
    ev = f"{out}/events.jsonl"
    os.makedirs(f"{out}/shots", exist_ok=True)
    # Probe launch (no real title): the start event names the container's absolute path, which the cue file's argument needs.
    r = launch(["-SwiftlyLiveTitles", "none"]); print(r.stdout.strip()[-200:], r.stderr.strip()[-300:])
    base = None
    for _ in range(40):
        time.sleep(2)
        if pull("tmp/swiftly-live/events.jsonl", ev) and '"kind":"start"' in open(ev).read().replace(" ", ""):
            # Only the run's own start event: a "sync-run" line also says "start".
            starts = [e for e in (json.loads(l) for l in open(ev).read().splitlines() if l.strip()) if e.get("kind") == "start"]
            if starts: base = starts[-1]["dir"]; break
    if not base: sys.exit("probe launch: no start event (app not running, or the fixture address is not reachable)")
    cues = f"{os.path.dirname(base)}/cues.json"
    push(cues_file(), "tmp/cues.json")
    os.remove(ev)
    began = time.time()
    r = launch(["-SwiftlyLiveTitles", ",".join(titles), "-SwiftlyLivePosition", str(a.position), "-SwiftlyLiveCues", cues] + a.arg)
    print(r.stdout.strip()[-200:], r.stderr.strip()[-300:])
    done, last_new, seen = set(), time.time(), 0
    while time.time() < began + 3000 and time.time() - last_new < 180:
        if not pull("tmp/swiftly-live/events.jsonl", ev): time.sleep(1); continue
        lines = open(ev).read().splitlines()
        if len(lines) > seen: seen, last_new = len(lines), time.time()
        stop = False
        # The file on the device still holds the probe launch (its own start ... end): only read what follows the
        # start of the real run (the device clock is not the Mac's, so a time filter does not separate them).
        ev_list = []
        for l in lines:
            try: ev_list.append(json.loads(l))
            except ValueError: continue
        real = [i for i, e in enumerate(ev_list) if e.get("kind") == "start" and e.get("titles") != ["none"]]
        if not real: time.sleep(1); continue
        for e in ev_list[real[-1]:]:
            stop |= e.get("kind") == "end"
            if e.get("kind") == "shot-wanted" and e["n"] not in done:
                done.add(e["n"])
                sh(["xcrun", "devicectl", "device", "capture", "screenshot", "--device", dev, "--destination", f"{out}/shots/{e['name']}.png"])
                open(f"{out}/ack-{e['n']}", "w").close()
                push(f"{out}/ack-{e['n']}", f"tmp/swiftly-live/ack-{e['n']}")
        if stop: break
        time.sleep(0.5)
    else:
        print("stopped: no new event for 180 s or time limit")
    # Leave nothing running in front on the TV: end the app by its pid.
    pj = f"{out}/processes.json"
    sh(["xcrun", "devicectl", "device", "info", "processes", "--device", dev, "--json-output", pj])
    try:
        for p in json.load(open(pj))["result"]["runningProcesses"]:
            if "Swiftly-tvOS" in p.get("executable", ""):
                print("terminate:", sh(["xcrun", "devicectl", "device", "process", "terminate", "--device", dev, "--pid", str(p["processIdentifier"])]).returncode)
    except (OSError, ValueError, KeyError) as e: print("could not end the app:", e)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("device", choices=["iphone", "ipad", "mac", "tv", "tv-device"])
    ap.add_argument("--kind", default="jellyfin"); ap.add_argument("--titles"); ap.add_argument("--position", type=float, default=None, help="shot position; default 2.5 s, 125.5 s for the start scenario (the forced PGS cue of bm-pgs-mkv is at 124 s)")
    ap.add_argument("--tag", default="", help="suffix of the result folder: one run per batch of titles"); ap.add_argument("--no-build", action="store_true"); ap.add_argument("--look", action="store_true", help="open the subtitle look page and shoot it (`look-page`); with --titles '-' nothing is played"); ap.add_argument("--include-sim-limit", action="store_true", help="also run the titles the simulator cannot decode (to test the crash check)"); ap.add_argument("--fullscreen", action="store_true", help="mac: also toggle full screen (crashes today)"); ap.add_argument("--scenario", help="iphone/ipad/tv: filestyle|start|memory|download|timing|pausedseek (see LiveRun.scenario)"); ap.add_argument("--port", type=int, default=18_900); ap.add_argument("--arg", action="append", default=[], help="extra launch argument for the app (iphone/ipad/tv), repeatable")
    ap.add_argument("--media", default=f"{HOME}/Library/Caches/swiftly-live-media")
    a = ap.parse_args()
    if a.position is None: a.position = 125.5 if a.scenario == "start" else 2.5
    if not glob.glob(f"{a.media}/*.item.json"):
        subprocess.run(["python3", "-I", f"{ROOT}/Werkzeuge/pruefstand-medien.py", a.media], check=True)
    if not glob.glob(f"{a.media}/plex-90*.json"):
        subprocess.run(["python3", "-I", f"{ROOT}/Werkzeuge/pruefstand-plex.py", a.media], check=True)
    # A Plex server knows its titles by rating key (plex-<key>.json, made by pruefstand-plex.py), not by the bench ids.
    catalog = (sorted(os.path.basename(p)[5:-5] for p in glob.glob(f"{a.media}/plex-90*.json")) if a.kind == "plex"
               else sorted(os.path.basename(p)[:-10] for p in glob.glob(f"{a.media}/*.item.json")))
    titles = ([] if a.titles == "-" else a.titles.split(",")) if a.titles else catalog
    if a.device == "mac" and screen_locked():
        sys.exit("the Mac screen is locked: a locked session never opens the app window, so nothing starts and screencapture "
                 "fails ('could not create image from display'). Unlock the Mac (or run on a Mac with an open session).")
    out = f"{HOME}/Library/Caches/swiftly-live-runs/{a.device}-{a.kind}{a.tag}"
    shutil.rmtree(out, ignore_errors=True); shutil.rmtree(out + ".xcresult", ignore_errors=True); os.makedirs(out)
    real = a.device == "tv-device"
    lan = next(filter(None, (sh(["ipconfig", "getifaddr", i]).stdout.strip() for i in ("en0", "en1"))), "") if real else ""
    if real and not lan: sys.exit("no LAN address on en0/en1")
    srv = server(a.port, a.media, "0.0.0.0" if real else "127.0.0.1"); SRV.append(srv)
    try:
        {"mac": mac, "tv": tv, "tv-device": tv_device}.get(a.device, ios)(a, out, titles, f"http://{lan or '127.0.0.1'}:{a.port}")
    finally:
        srv.terminate()
    if os.path.exists(f"{out}/events.jsonl"):
        r = sh([VENV, f"{ROOT}/Werkzeuge/live-pixel.py", out])
        open(f"{out}/pixel.json", "w").write(r.stdout); print(r.stderr[-800:])
        print(f"pixel.json: {out}/pixel.json")

main()
