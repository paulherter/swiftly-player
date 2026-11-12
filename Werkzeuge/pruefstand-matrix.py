#!/usr/bin/env python3 -I
"""pruefstand-matrix.py <results.jsonl> <out.md> [swift-test-exit]: the playback matrix (pass/fail per cell) from the bench's results.
Prints FAIL lines and exits 1 if any cell failed (known gaps are shown but do not fail)."""
import json, sys, datetime

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
last = {}
for r in rows:
    last[(r["cell"], r["column"])] = r          # a later line for the same cell wins
cells = sorted({c for c, _ in last})
cols = ["plan", "ready", "duration", "frame", "picture", "seek", "end", "download"]
extra = sorted({k for _, k in last} - set(cols))

def mark(r):
    if r is None: return "-"
    if not r["ok"]: return "FAIL"
    return "gap" if r["detail"].startswith("KNOWN GAP") else "ok"

lines = ["# Playback matrix (Wiedergabe-Pruefstand)", "",
         f"Generated {datetime.date.today()} by `Werkzeuge/wiedergabe-pruefstand.sh`: the core's `playPlan` and player state machine drive the real "
         "AetherEngine headless (no screen), against real files served by `cargo xtask fixture-server` (media made by `Werkzeuge/pruefstand-medien.py`).",
         "", "ok = checked and passed, gap = known difference that the shipping line has too (does not fail the gate), FAIL = fails the gate, - = not applicable.", "",
         "## Titles x checks", "", "| title | " + " | ".join(cols) + " |", "|---|" + "---|" * len(cols)]
for c in cells:
    if any((c, k) in last for k in cols):
        lines.append(f"| {c} | " + " | ".join(mark(last.get((c, k))) for k in cols) + " |")
lines += ["", "Checks: plan = core `playPlan` equals the old `PlaybackPlan.make` (Aether and both AVPlayer profiles); ready = playing + first picture; duration = "
          "10 s +-0.7 in the engine and in the core's transport; frame = clock advances; picture = the decoded frame is not green, black, white or flat (HDR / Dolby Vision / AV1 titles); seek = seek intent lands and plays on; end = reaches the end; "
          "download = the stored file plays offline with the right length and seeks.", "", "## Features", "", "| title | check | result | detail |", "|---|---|---|---|"]
for (c, k), r in sorted(last.items()):
    if k in extra:
        lines.append(f"| {c} | {k} | {mark(r)} | {r['detail'][:140].replace('|', '/')} |")
fails = [(c, k, r["detail"]) for (c, k), r in last.items() if not r["ok"]]
lines += ["", f"Result: {len(last)} checks, {len(fails)} failed, {sum(1 for r in last.values() if r['detail'].startswith('KNOWN GAP'))} known gaps.", ""]
open(sys.argv[2], "w").write("\n".join(lines))
for c, k, d in fails:
    print(f"FAIL {c} / {k}: {d}")
sys.exit(1 if fails else 0)
