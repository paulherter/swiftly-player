#!/usr/bin/env python3
"""Generates THIRD-PARTY-NOTICES.md from LICENSES/components.json.

The JSON file is the only source: the apps read it together with
LICENSES/*.txt from the bundle, and this script turns it into the readable
version. The Markdown file is never maintained by hand.

    Werkzeuge/licenses-generate.py            writes THIRD-PARTY-NOTICES.md
    Werkzeuge/licenses-generate.py --pruefen  exit 1 if the file is out of date
                                              or a named license text is missing
"""
import json, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = root / "LICENSES" / "components.json"
target = root / "THIRD-PARTY-NOTICES.md"

NAMES = {"ios": "iPhone", "ipados": "iPad", "macos": "Mac", "tvos": "Apple TV",
         "android": "Android", "androidtv": "Android TV", "windows": "Windows",
         "linux": "Linux", "website": "Website"}

def platforms(list):
    apple = {"ios", "ipados", "macos", "tvos"}
    if apple <= set(list):
        rest = [p for p in list if p not in apple]
        names = ["Apple (iPhone, iPad, Mac, Apple TV)"] + [NAMES[p] for p in rest]
    else:
        names = [NAMES[p] for p in list]
    return ", ".join(names)

def cell(s):
    return s.replace("|", "\\|").replace("\n", " ")

def generate(doc):
    a = doc["angebot"]
    z = []
    z.append("# Third-party notices\n")
    z.append("Swiftly Player is published under the MPL-2.0 (see `LICENSE`). It "
             "contains and uses the third-party components listed here. Each "
             "keeps its own license; the license texts are in `LICENSES/`. "
             "This file is generated from `LICENSES/components.json` "
             "(`Werkzeuge/licenses-generate.py`); do not edit it by hand.\n")
    z.append(f"## {a['titel']}\n")
    z.append(f"**{a['kurz']}**\n")
    for since in a["abschnitte"]:
        z.append(f"### {since['titel']}\n")
        for p in since["absaetze"]:
            z.append(p + "\n")
    groups = [("player", "Player"), ("app", "Application and fonts"),
               ("in-vlckit", "Libraries built into VLCKit (Apple)")]
    for g, title in groups:
        rows = [b for b in doc["bausteine"] if b["gruppe"] == g]
        z.append(f"## {title}\n")
        z.append("| Component | Version | License (SPDX) | Copyright | Source | Platforms |")
        z.append("|---|---|---|---|---|---|")
        for b in rows:
            z.append("| " + " | ".join(cell(x) for x in (
                b["name"], b["version"], b["spdx"], b["urheber"],
                b["quelle"], platforms(b["plattformen"]))) + " |")
        z.append("")
        notes = [b for b in rows if b.get("notiz")]
        if notes:
            z.append("Notes:\n")
            for b in notes:
                z.append(f"- **{b['name']}** — {b['notiz']}")
            z.append("")
    z.append("## License texts\n")
    texts = sorted({t for b in doc["bausteine"] for t in b["texte"]})
    for t in texts:
        z.append(f"- [`LICENSES/{t}`](LICENSES/{t})")
    z.append("")
    return "\n".join(z)

def main():
    doc = json.loads(source.read_text(encoding="utf-8"))
    missing = [t for b in doc["bausteine"] for t in b["texte"]
             if not (root / "LICENSES" / t).is_file()]
    if missing:
        print("Lizenztext fehlt:", ", ".join(sorted(set(missing))))
        sys.exit(1)
    text = generate(doc)
    if "--pruefen" in sys.argv:
        if not target.is_file() or target.read_text(encoding="utf-8") != text:
            print("THIRD-PARTY-NOTICES.md ist veraltet: Werkzeuge/licenses-generate.py ausfuehren")
            sys.exit(1)
        print("Lizenzangaben stimmen.")
        return
    target.write_text(text, encoding="utf-8")
    print("geschrieben:", target)

main()
