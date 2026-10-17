#!/usr/bin/env python3
"""Translations from the Xcode catalog for Android.

    python3 Werkzeuge/texts-to-android.py [target-folder]

Reads Sources/Shared/Localizable.xcstrings and writes one JSON file per
language, `<language>.json` (key = German wording, as on Linux). Kotlin reads
them with `uebersetzt("...")`. A second catalog maintained by hand would be a
second source of truth -- hence generated, not maintained.

Placeholders are rewritten for `String.format`: %@ -> %s, %lld/%ld -> %d,
%1$@ -> %1$s. Plural forms: "other" applies (as on Linux, where stringsdict is
missing).
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

def singular(entry: dict):
    """The form for exactly one, if the catalog has its own ("1 result" instead of "1 results")."""
    one = entry.get("variations", {}).get("plural", {}).get("one")
    return one["stringUnit"]["value"] if one and "stringUnit" in one else None

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
        # Store the singular only if it differs -- `Texte.text` asks for `...#eins` when the count is exactly 1.
        e = singular(places[s]) if s in places else None
        if e is not None and e != w:
            tabellen[s][kotlinformat(key) + "#eins"] = kotlinformat(e)

TARGET.mkdir(parents=True, exist_ok=True)
for s, t in tabellen.items():
    (TARGET / f"{s}.json").write_text(json.dumps(t, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    print(f"{s}: {len(t)} Texte → {TARGET / (s + '.json')}")
