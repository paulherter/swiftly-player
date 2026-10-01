#!/usr/bin/env python3
"""Erzeugt THIRD-PARTY-NOTICES.md aus LICENSES/bausteine.json.

Die JSON-Datei ist die einzige Quelle: die Apps lesen sie samt LICENSES/*.txt
aus dem Buendel, dieses Skript macht daraus die lesbare Fassung. Die Markdown-
Datei wird nie von Hand gepflegt.

    Werkzeuge/lizenzen-erzeugen.py            schreibt THIRD-PARTY-NOTICES.md
    Werkzeuge/lizenzen-erzeugen.py --pruefen  Exit 1, wenn die Datei veraltet ist
                                              oder ein genannter Lizenztext fehlt
"""
import json, sys
from pathlib import Path

wurzel = Path(__file__).resolve().parent.parent
quelle = wurzel / "LICENSES" / "bausteine.json"
ziel = wurzel / "THIRD-PARTY-NOTICES.md"

NAMEN = {"ios": "iPhone", "ipados": "iPad", "macos": "Mac", "tvos": "Apple TV",
         "android": "Android", "androidtv": "Android TV", "windows": "Windows",
         "linux": "Linux", "website": "Website"}

def plattformen(liste):
    apple = {"ios", "ipados", "macos", "tvos"}
    if apple <= set(liste):
        rest = [p for p in liste if p not in apple]
        namen = ["Apple (iPhone, iPad, Mac, Apple TV)"] + [NAMEN[p] for p in rest]
    else:
        namen = [NAMEN[p] for p in liste]
    return ", ".join(namen)

def zelle(s):
    return s.replace("|", "\\|").replace("\n", " ")

def erzeugen(doc):
    a = doc["angebot"]
    z = []
    z.append("# Third-party notices\n")
    z.append("Swiftly Player is published under the MPL-2.0 (see `LICENSE`). It "
             "contains and uses the third-party components listed here. Each "
             "keeps its own license; the license texts are in `LICENSES/`. "
             "This file is generated from `LICENSES/bausteine.json` "
             "(`Werkzeuge/lizenzen-erzeugen.py`); do not edit it by hand.\n")
    z.append(f"## {a['titel']}\n")
    z.append(f"**{a['kurz']}**\n")
    for ab in a["abschnitte"]:
        z.append(f"### {ab['titel']}\n")
        for p in ab["absaetze"]:
            z.append(p + "\n")
    gruppen = [("player", "Player"), ("app", "Application and fonts"),
               ("in-vlckit", "Libraries built into VLCKit (Apple)")]
    for g, titel in gruppen:
        zeilen = [b for b in doc["bausteine"] if b["gruppe"] == g]
        z.append(f"## {titel}\n")
        z.append("| Component | Version | License (SPDX) | Copyright | Source | Platforms |")
        z.append("|---|---|---|---|---|---|")
        for b in zeilen:
            z.append("| " + " | ".join(zelle(x) for x in (
                b["name"], b["version"], b["spdx"], b["urheber"],
                b["quelle"], plattformen(b["plattformen"]))) + " |")
        z.append("")
        notizen = [b for b in zeilen if b.get("notiz")]
        if notizen:
            z.append("Notes:\n")
            for b in notizen:
                z.append(f"- **{b['name']}** — {b['notiz']}")
            z.append("")
    z.append("## License texts\n")
    texte = sorted({t for b in doc["bausteine"] for t in b["texte"]})
    for t in texte:
        z.append(f"- [`LICENSES/{t}`](LICENSES/{t})")
    z.append("")
    return "\n".join(z)

def main():
    doc = json.loads(quelle.read_text(encoding="utf-8"))
    fehlt = [t for b in doc["bausteine"] for t in b["texte"]
             if not (wurzel / "LICENSES" / t).is_file()]
    if fehlt:
        print("Lizenztext fehlt:", ", ".join(sorted(set(fehlt))))
        sys.exit(1)
    text = erzeugen(doc)
    if "--pruefen" in sys.argv:
        if not ziel.is_file() or ziel.read_text(encoding="utf-8") != text:
            print("THIRD-PARTY-NOTICES.md ist veraltet: Werkzeuge/lizenzen-erzeugen.py ausfuehren")
            sys.exit(1)
        print("Lizenzangaben stimmen.")
        return
    ziel.write_text(text, encoding="utf-8")
    print("geschrieben:", ziel)

main()
