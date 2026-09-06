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
muster = re.compile(r'(?:Text\(|titel:\s*|unter:\s*|beschriftung:\s*|platzhalter:\s*|'
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

for name, menge in (("nicht im Katalog", fehlt), ("ohne englische Fassung", roh)):
    for weg, text in sorted(menge):
        print(f"  {name}: {weg.split('/')[-1]} · {text[:64]}")

anzahl = len(fehlt) + len(roh)
print(f"Katalog{'':26}{'ok' if anzahl == 0 else f'{anzahl} offen'}")
sys.exit(1 if anzahl else 0)
