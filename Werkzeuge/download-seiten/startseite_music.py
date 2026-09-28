# -*- coding: utf-8 -*-
"""Startseite fuer Swiftly Music: Punkt „Music" in Leiste und Menue, ein
zweiter Knopf neben „Download" im Kopf, ein Link in der Fusszeile.

  startseite_music.py            Vorschau nach Website/.entwurf/start/
  startseite_music.py --anwenden index.html selbst aendern (erst am Tag, an
                                 dem /music/ live geht)
Laeuft nur einmal sauber: steht „/music/" schon in der Leiste, bricht es ab.
"""
import os
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import WEBSITE

QUELLE = os.path.join(WEBSITE, "index.html")

CSS = """
/* Zweiter Knopf im Kopf: Swiftly Music neben Download. Gleiche Groesse,
   ruhige Flaeche, damit Download der erste bleibt. */
.hero__knoepfe { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; margin-top: 26px; }
.hero__knoepfe .hero__knopf { margin-top: 0; }
.knopf--zweit { background: var(--flaeche); color: var(--schrift); }
.knopf--zweit:active { background: var(--gedrueckt); }
@media (max-width: 900px) { .hero__knoepfe { margin-top: 29px; } }
"""

ERSETZEN = [
    ('    <a class="leiste__punkt nur-desktop" href="/blog/">Blog</a>',
     '    <a class="leiste__punkt nur-desktop" href="/music/">Music</a>\n'
     '    <a class="leiste__punkt nur-desktop" href="/blog/">Blog</a>'),
    ('<nav class="menue" id="menue" aria-label="Menu">\n  <a href="/blog/">Blog</a>',
     '<nav class="menue" id="menue" aria-label="Menu">\n  <a href="/music/">Swiftly Music</a>\n  <a href="/blog/">Blog</a>'),
    ('      <a class="knopf knopf--gross hero__knopf" href="#downloads">Download</a>',
     '      <div class="hero__knoepfe">\n'
     '        <a class="knopf knopf--gross hero__knopf" href="#downloads">Download</a>\n'
     '        <a class="knopf knopf--gross knopf--zweit hero__knopf" href="/music/">Swiftly Music</a>\n'
     '      </div>'),
    ('          <li><a href="/download/linux/">Linux</a></li>',
     '          <li><a href="/download/linux/">Linux</a></li>\n          <li><a href="/music/">Swiftly Music</a></li>'),
    ('</style>', CSS + '</style>'),
]


def umbauen(text):
    if 'href="/music/">Music</a>' in text:
        sys.exit("Startseite hat den Punkt Music schon, nichts getan.")
    for alt, neu in ERSETZEN:
        if text.count(alt) != 1:
            sys.exit("Stelle nicht eindeutig gefunden: " + alt[:60])
        text = text.replace(alt, neu)
    return text


text = umbauen(open(QUELLE, encoding="utf-8").read())
if "--anwenden" in sys.argv:
    open(QUELLE, "w", encoding="utf-8").write(text)
    print("geaendert", QUELLE)
else:
    ziel = os.path.join(WEBSITE, ".entwurf", "start")
    os.makedirs(ziel, exist_ok=True)
    # Die Startseite verweist relativ auf bilder/, schrift/ usw.; aus dem
    # Unterordner heraus zeigt <base> wieder auf die Wurzel.
    text = text.replace("<head>", '<head>\n<base href="/">', 1)
    pfad = os.path.join(ziel, "index.html")
    open(pfad, "w", encoding="utf-8").write(text)
    print("Vorschau", pfad)
