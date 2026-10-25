#!/usr/bin/env python3
"""Translations from the Xcode catalog for Android.

    python3 Werkzeuge/texts-to-android.py [target-folder]

Reads Sources/Shared/Localizable.xcstrings and writes one JSON file per
language, `<language>.json` (key = German wording, as on Linux). Kotlin reads
them with `uebersetzt("...")`. A second catalog maintained by hand would be a
second source of truth -- hence generated, not maintained.

Placeholders are rewritten for `String.format`: %@ -> %s, %lld/%ld -> %d,
%1$@ -> %1$s. Plural forms: "other" is the plain entry; the others go under
`key#eins`, `key#few`, `key#many` where they differ, and Kotlin picks one with
`PluralRules` (Russian needs three).
"""
import json, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/Shared/Localizable.xcstrings"
TARGET = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Android/shared/src/main/assets/texts"

def kotlinformat(text: str) -> str:
    text = re.sub(r"%(\d+\$)?@", lambda m: f"%{m.group(1) or ''}s", text)
    text = re.sub(r"%(\d+\$)?l{0,2}[du]", lambda m: f"%{m.group(1) or ''}d", text)
    text = re.sub(r"%(\d+\$)?l?f", lambda m: f"%{m.group(1) or ''}f", text)
    return text

def value(entry: dict):
    if "stringUnit" in entry:
        return entry["stringUnit"].get("value")
    plural = entry.get("variations", {}).get("plural", {})
    different = plural.get("other") or next(iter(plural.values()), None)
    return different["stringUnit"]["value"] if different and "stringUnit" in different else None

def form(entry: dict, category: str):
    """A plural form other than `other`, if the catalog has one ("1 result", "2 сезона")."""
    found = entry.get("variations", {}).get("plural", {}).get(category)
    return found["stringUnit"]["value"] if found and "stringUnit" in found else None

# Suffix per CLDR category. `one` keeps its old name so the German and English tables stay as they were.
SUFFIXES = {"one": "eins", "two": "two", "few": "few", "many": "many"}

catalog = json.loads(SOURCE.read_text(encoding="utf-8"))
quellsprache = catalog.get("sourceLanguage", "de")
languages = sorted({s for v in catalog["strings"].values() for s in v.get("localizations", {})} | {quellsprache})
tabellen = {s: {} for s in languages}
for key, entry in catalog["strings"].items():
    if not key.strip():
        continue
    places = entry.get("localizations", {})
    for s in languages:
        w = value(places[s]) if s in places else (key if s == quellsprache else None)
        if w is not None:
            tabellen[s][kotlinformat(key)] = kotlinformat(w)
        # Store a form only if it differs -- `Texts.text` asks for `...#<suffix>` by the count's category.
        for category, suffix in SUFFIXES.items():
            e = form(places[s], category) if s in places else None
            if e is not None and e != w:
                tabellen[s][kotlinformat(key) + "#" + suffix] = kotlinformat(e)

# **"Support Swiftly" texts come from the package** (`SupportCopy` in JellyfinKit), not from the
# app catalog: every platform copies the same pairs. The shared ones go into the normal tables;
# the direct-only ones (website, supporter key; `DirectSupportCopy.swift`, module SupportKeyKit)
# go into the `direct` flavor's own assets, so the Play build never carries them
# (`Werkzeuge/store-guard-android.py` checks that). Kotlin merges `texts/<language>.*.json`.
PAIR = re.compile(r'SupportCopy\(\s*de:\s*"((?:[^"\\]|\\.)*)",\s*en:\s*"((?:[^"\\]|\\.)*)"\)', re.S)
KIT = ROOT / "Packages/JellyfinKit/Sources"

def pairs(path: pathlib.Path):
    return [(de, en) for de, en in PAIR.findall(path.read_text(encoding="utf-8"))]

def add(table: dict, language: str, found):
    for de, en in found:
        table.setdefault(kotlinformat(de), kotlinformat(de if language == "de" else en))

shared_pairs = pairs(KIT / "JellyfinKit/SupportCopy.swift")
direct_pairs = pairs(KIT / "SupportKeyKit/DirectSupportCopy.swift")
for s, t in tabellen.items():
    add(t, s, shared_pairs)

TARGET.mkdir(parents=True, exist_ok=True)
for s, t in tabellen.items():
    (TARGET / f"{s}.json").write_text(json.dumps(t, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    print(f"{s}: {len(t)} Texte → {TARGET / (s + '.json')}")

if len(sys.argv) <= 1:
    direct = ROOT / "Android/phone/src/direct/assets/texts"
    direct.mkdir(parents=True, exist_ok=True)
    for s in tabellen:
        t = {}
        add(t, s, direct_pairs)
        (direct / f"{s}.direct.json").write_text(json.dumps(t, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
        print(f"{s}: {len(t)} Direkt-Texte → {direct / (s + '.direct.json')}")
