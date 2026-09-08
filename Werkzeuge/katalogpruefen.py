#!/usr/bin/env python3
"""Steht jede Beschriftung aus dem Quelltext im Katalog — und auf Englisch?

**Warum es das gibt.** Am 06.09.2026 hat ein Nutzer gemeldet, dass die
Anmeldung eines zweiten Kontos bei ihm auf Deutsch steht. Der Grund waren 54
Texte, die nie in den Katalog exportiert wurden. Das faellt von selbst nie
auf: die App laeuft, auf Deutsch sieht sie richtig aus, und der Bau ist gruen
— denn was nicht im Katalog steht, faellt auf den Schluessel zurueck, und der
Schluessel *ist* bei uns der deutsche Wortlaut.
"""
import json, pathlib, re, subprocess, sys

wurzel = pathlib.Path(__file__).resolve().parent.parent
katalog = json.loads((wurzel / "Sources/Shared/Localizable.xcstrings").read_text())["strings"]

# Die Stellen, an denen eine Beschriftung als festes Wort im Code steht.
# **Zweimal erweitert, zweimal weil es sonst durchgerutscht waere.**
#
# Der erste Bogen kannte nur `Text(` und die benannten Argumente. Am
# 06.09.2026 fanden sich damit trotzdem 50 weitere Beschriftungen, die nie im
# Katalog standen — sie stehen in `Button(`, in `String(localized:)` oder als
# Wert eines `switch`. Englische Nutzer lasen dort Deutsch: Downloadzustaende
# („wartet", „angehalten", „frei"), die halbe Seerr-Marke und die
# Auskunftskarten im Player.
muster = re.compile(r'(?:Text\(|Button\(|Toggle\(|Label\(|Menu\(|Section\(|'
                    r'String\(localized:\s*|navigationTitle\(|\.help\(|'
                    r'confirmationDialog\(|'
                    r'titel:\s*|unter:\s*|beschriftung:\s*|platzhalter:\s*|'
                    r'kopfzeile:\s*|hinweis:\s*|text:\s*|wort:\s*|ansage:\s*)"([^"\\]{3,})"')

fehlt, roh = set(), set()
dateien = subprocess.run(["git", "ls-files", "Sources"], cwd=wurzel,
                         capture_output=True, text=True).stdout.split()
for weg in dateien:
    if not weg.endswith(".swift"):
        continue
    for treffer in muster.findall((wurzel / weg).read_text()):
        if not re.search(r"[a-zäöüßA-ZÄÖÜ]", treffer):
            continue
        eintrag = katalog.get(treffer)
        if eintrag is None:
            fehlt.add((weg, treffer))
            continue
        englisch = eintrag.get("localizations", {}).get("en", {}).get("stringUnit", {})
        if englisch.get("state") != "translated":
            roh.add((weg, treffer))

# **Der Bogen findet nur, was er kennt — der Katalog selbst weiss mehr.**
#
# Am 07.09.2026 hat ein Nutzer „12 offen" auf einem englischen Geraet
# gemeldet. Der Schluessel dazu heisst `%lld offen` und entsteht aus
# `String(localized: "\(n) offen")` — ein Literal mit eingesetztem Wert, und
# genau daran kommt kein Muster heran, das nach `"..."` ohne Backslash sucht.
#
# Die Gegenprobe ist einfacher als jedes Muster: **jeder Eintrag im Katalog
# braucht eine englische Fassung.** Wie der Schluessel entstanden ist, spielt
# dann keine Rolle mehr. Xcode traegt neue Schluessel beim Bauen selbst ein;
# ab da faellt hier auf, dass die Uebersetzung fehlt.
for schluessel, eintrag in katalog.items():
    if not eintrag.get("shouldTranslate", True):
        continue
    en = eintrag.get("localizations", {}).get("en")
    if en is None:
        roh.add(("Katalog", schluessel))
        continue
    if "variations" in en:
        for form in en["variations"].get("plural", {}).values():
            if form.get("stringUnit", {}).get("state") != "translated":
                roh.add(("Katalog", schluessel))
    elif en.get("stringUnit", {}).get("state") != "translated":
        roh.add(("Katalog", schluessel))

for name, menge in (("nicht im Katalog", fehlt), ("ohne englische Fassung", roh)):
    for weg, text in sorted(menge):
        print(f"  {name}: {weg.split('/')[-1]} · {text[:64]}")

anzahl = len(fehlt) + len(roh)
print(f"Katalog{'':26}{'ok' if anzahl == 0 else f'{anzahl} offen'}")
sys.exit(1 if anzahl else 0)
