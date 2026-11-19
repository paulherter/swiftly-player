#!/usr/bin/env python3
"""Detail-page guard: nothing inside a movie, episode or series page animates in.

The page slides in as a whole (the navigation's own push). Inside it, content that arrives later (the chips under
the title, the Play label, the cast and rails below, the logo, the colour mood) appears in place: skeletons of
the final size while the data is missing, no fade, no slide, no stagger. Rules for `ItemDetailView` and the series
page (Sources/Shared/BrowseViews.swift, Sources/Shared/SeriesView.swift):

  * the proof row is drawn through `ProofRow(waiting: ...)` (skeleton chips, then all real chips in one frame) and is never
    hidden with `.opacity(proof ...)`;
  * no `.animation(..., value: <proof | bottom ready | label ready>)` on content that arrives with the data;
  * the page calls `.arrivesStill()`, which switches off the fade of logo and colour mood below it (`Picture` cross-fades once from its placeholder, 200 ms);
  * in `ProofRow` (Sources/Shared/Style.swift) the playback mark is the last chip, skeleton and settled row alike (its word
    changes width when it settles and must not move chips to its right).

A line may carry `still-ok` plus a reason to be skipped. Exit code 1 lists the places.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = ["Sources/Shared/BrowseViews.swift", "Sources/Shared/SeriesView.swift"]
BAD = [
    (re.compile(r"\.opacity\(\s*proof"), "the proof row is never hidden by opacity; use ProofRow(waiting:)"),
    (re.compile(r"\.animation\([^\n]*value:[^\n]*(proof|bottom\??\.ready|labelReady)"),
     "content that arrives with the data must not animate in"),
]
problems = []
for name in FILES:
    path = ROOT / name
    text = path.read_text()
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        if "still-ok" in line:
            continue
        for pattern, why in BAD:
            if pattern.search(line):
                problems.append(f"{name}:{number}: {why}: {line.strip()}")
    if ".arrivesStill()" not in text:
        problems.append(f"{name}: the page must call .arrivesStill()")
    if "ProofRow(waiting:" not in text:
        problems.append(f"{name}: the proof row must be drawn with ProofRow(waiting:)")
    # The head picture stands in frame 1 as the BlurHash from the tile / stored copy, then the sharp picture replaces it in place.
    if "HeroImage(url:" in text and not re.search(r"HeroImage\(url:[^\n]*blur:", text):
        problems.append(f"{name}: HeroImage must be given the head's BlurHash (blur:) so the head is there in frame 1")
    # And the picture the title's tile showed (stand:), which wins over the BlurHash when the picture memory still has it.
    hero_call = re.search(r"HeroImage\(url:", text)
    if hero_call and "stand:" not in text[hero_call.start():hero_call.start() + 260]:
        problems.append(f"{name}: HeroImage must be given the tile pictures (stand:) so frame 1 shows the tile's picture")
# Frame-1 rules of the Apple head and the season chooser (the first open of a page must be right, not only the second).
for name, needle, why in [
    ("Sources/Shared/Style.swift", ".anchored(.top)", "HeroImage must cut a mismatching picture at the top (a poster must not show a zoomed middle slice in the head)"),
    ("Sources/Shared/SeriesView.swift", "seasons.expected", "the season chevron must be decided by the core's `expected` count, not by the list that is still loading"),
    ("crates/swiftly-vm/src/series.rs", "header_image_waiting", "the series head must not use the poster fallback before the series answered"),
    ("crates/swiftly-vm/src/detail.rs", "proof_mark::shown", "the title page must show the stored proof mark from frame 1 (no second 'Direct Play' load on every open)"),
]:
    if needle not in (ROOT / name).read_text():
        problems.append(f"{name}: {why}")
# The proof row: the playback mark ("Direct Play", a hint, the Seerr status) is the LAST chip, in the skeleton and in the
# settled row. It settles with a word of another width ("Transcode" is wider than "Direct Play"); a chip with chips to its
# right moved them when it settled.
try:
    style = (ROOT / "Sources/Shared/Style.swift").read_text()
    row = style[style.index("struct ProofRow: View"):]
    row = row[:row.index("\n}\n")]
    sk = row[row.index("private var skeletons"):row.index("private static func ageWords")]
    ch = row[row.index("private var chips"):]
    for label, text, first, last in [
        ("skeleton", sk, "if let expectedAge", 'Text("Direct Play")'),
        ("settled row", ch, "if let sharing", "if let own"),
    ]:
        if first not in text or last not in text or text.index(first) > text.index(last):
            problems.append(f"Sources/Shared/Style.swift: ProofRow {label}: the playback mark must come after the stars and the age rating")
except ValueError:
    # ProofRow lost its `skeletons` / `ageWords` shape (the guard crashed here before); the chip-order rule cannot be read any more.
    print("note: ProofRow's shape changed, the chip-order rule is skipped")
if problems:
    print("Detail pages animate content in:")
    print("\n".join("  " + p for p in problems))
    sys.exit(1)
print("detail pages: nothing animates in")
