# -*- coding: utf-8 -*-
"""Home page for Swiftly Music: a "Music" item in the bar and menu, a second
button next to "Download" in the header, a link in the footer.

  homepage_music.py            preview to Website/.entwurf/start/
  homepage_music.py --anwenden modify index.html itself (only on the day
                                 /music/ goes live)
Runs cleanly only once: if "/music/" is already in the bar, it aborts.
"""
import os
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from parts import WEBSITE

SOURCE = os.path.join(WEBSITE, "index.html")

CSS = """
/* Second button in the header: Swiftly Music next to Download. Same size,
   quiet surface so Download stays the primary one. */
.hero__knoepfe { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; margin-top: 26px; }
.hero__knoepfe .hero__knopf { margin-top: 0; }
.knopf--zweit { background: var(--flaeche); color: var(--schrift); }
.knopf--zweit:active { background: var(--gedrueckt); }
@media (max-width: 900px) { .hero__knoepfe { margin-top: 29px; } }
"""

REPLACE = [
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


def rebuild(text):
    if 'href="/music/">Music</a>' in text:
        sys.exit("Startseite hat den Punkt Music schon, nichts getan.")
    for alt, new in REPLACE:
        if text.count(alt) != 1:
            sys.exit("Stelle nicht eindeutig gefunden: " + alt[:60])
        text = text.replace(alt, new)
    return text


text = rebuild(open(SOURCE, encoding="utf-8").read())
if "--anwenden" in sys.argv:
    open(SOURCE, "w", encoding="utf-8").write(text)
    print("geaendert", SOURCE)
else:
    target = os.path.join(WEBSITE, ".entwurf", "start")
    os.makedirs(target, exist_ok=True)
    # The home page links relatively to bilder/, schrift/ etc.; from the
    # subfolder, <base> points back to the root.
    text = text.replace("<head>", '<head>\n<base href="/">', 1)
    path = os.path.join(target, "index.html")
    open(path, "w", encoding="utf-8").write(text)
    print("Vorschau", path)
