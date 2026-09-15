#!/usr/bin/env python3
"""Uebersetzungen aus dem Xcode-Katalog fuer Android.

    python3 Werkzeuge/texte-nach-android.py [zielordner]

Liest Sources/Shared/Localizable.xcstrings und schreibt je Sprache eine JSON-Datei
`<sprache>.json` (Schluessel = deutscher Wortlaut, wie auf Linux). Kotlin liest
sie mit `uebersetzt("…")`. Ein zweiter Katalog von Hand waere eine zweite
Wahrheit — deshalb erzeugt, nicht gepflegt. Plan: Notizen/Android/PLAN.md.

Platzhalter werden fuer `String.format` umgeschrieben: %@ → %s, %lld/%ld → %d,
%1$@ → %1$s. Mehrzahlformen: es gilt „other" (wie auf Linux, wo stringsdict fehlt).
"""
import json, re, sys, pathlib

WURZEL = pathlib.Path(__file__).resolve().parent.parent
QUELLE = WURZEL / "Sources/Shared/Localizable.xcstrings"
ZIEL = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else WURZEL / "Android/gemeinsam/src/main/assets/texte"

def kotlinformat(text: str) -> str:
    text = re.sub(r"%(\d+\$)?@", lambda m: f"%{m.group(1) or ''}s", text)
    text = re.sub(r"%(\d+\$)?l{0,2}[du]", lambda m: f"%{m.group(1) or ''}d", text)
    text = re.sub(r"%(\d+\$)?l?f", lambda m: f"%{m.group(1) or ''}f", text)
    return text

def wert(eintrag: dict):
    if "stringUnit" in eintrag:
        return eintrag["stringUnit"].get("value")
    mehrzahl = eintrag.get("variations", {}).get("plural", {})
    anders = mehrzahl.get("other") or next(iter(mehrzahl.values()), None)
    return anders["stringUnit"]["value"] if anders and "stringUnit" in anders else None

def einzahl(eintrag: dict):
    """Die Form fuer genau eins, falls der Katalog eine eigene hat („1 result" statt „1 results")."""
    eins = eintrag.get("variations", {}).get("plural", {}).get("one")
    return eins["stringUnit"]["value"] if eins and "stringUnit" in eins else None

katalog = json.loads(QUELLE.read_text(encoding="utf-8"))
quellsprache = katalog.get("sourceLanguage", "de")
sprachen = sorted({s for v in katalog["strings"].values() for s in v.get("localizations", {})} | {quellsprache})
tabellen = {s: {} for s in sprachen}
for schluessel, eintrag in katalog["strings"].items():
    if not schluessel.strip():
        continue
    orte = eintrag.get("localizations", {})
    for s in sprachen:
        w = wert(orte[s]) if s in orte else (schluessel if s == quellsprache else None)
        if w is not None:
            tabellen[s][kotlinformat(schluessel)] = kotlinformat(w)
        # Einzahl nur ablegen, wenn sie sich unterscheidet — `Texte.text` fragt `…#eins` bei genau 1.
        e = einzahl(orte[s]) if s in orte else None
        if e is not None and e != w:
            tabellen[s][kotlinformat(schluessel) + "#eins"] = kotlinformat(e)

ZIEL.mkdir(parents=True, exist_ok=True)
for s, t in tabellen.items():
    (ZIEL / f"{s}.json").write_text(json.dumps(t, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    print(f"{s}: {len(t)} Texte → {ZIEL / (s + '.json')}")
