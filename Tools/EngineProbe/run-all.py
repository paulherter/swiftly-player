#!/usr/bin/env python3
"""Runs aether-probe over every movie/episode of a local Jellyfin test server (Direct Play of the
original file) and stores one JSONL log per title. Usage: run-all.py <probe-binary> <outdir> [name-filter]"""
import json, subprocess, sys, urllib.request, os
base = "http://localhost:8096"
auth = 'MediaBrowser Client="probe", Device="Mac", DeviceId="probe1", Version="1"'
def req(path, data=None, token=None):
    h = {"Authorization": auth + (f', Token="{token}"' if token else ""), "Content-Type": "application/json"}
    r = urllib.request.Request(base + path, data=json.dumps(data).encode() if data else None, headers=h)
    return json.load(urllib.request.urlopen(r))
a = req("/Users/AuthenticateByName", {"Username": "tester", "Pw": "tester"})
tok, uid = a["AccessToken"], a["User"]["Id"]
items = req(f"/Users/{uid}/Items?Recursive=true&Fields=MediaSources&IncludeItemTypes=Movie,Episode,Video", token=tok)["Items"]
probe, outdir = sys.argv[1], sys.argv[2]
flt = sys.argv[3] if len(sys.argv) > 3 else ""
os.makedirs(outdir, exist_ok=True)
for it in sorted(items, key=lambda i: i["Name"]):
    if flt not in it["Name"]: continue
    url = f"{base}/Videos/{it['Id']}/stream?static=true&api_key={tok}"
    with open(os.path.join(outdir, it["Name"] + ".jsonl"), "w") as f:
        try:
            subprocess.run([probe, url, it["Name"]], stdout=f, stderr=subprocess.STDOUT, timeout=100)
        except subprocess.TimeoutExpired:
            f.write('{"ev":"driverTimeout"}\n')
    print("done", it["Name"], flush=True)
