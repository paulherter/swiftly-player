# -*- coding: utf-8 -*-
"""Seite /licenses/: Lizenzen der Bausteine, Quelltext von VLCKit und libVLC,
schriftliches Angebot nach LGPL-2.1.

Der Inhalt wird hier nicht geschrieben, sondern aus THIRD-PARTY-NOTICES.md
uebernommen (die erzeugt Werkzeuge/lizenzen-erzeugen.py aus
LICENSES/bausteine.json). Eigene Worte gibt es nur im Seitenkopf und an den
Knoepfen. Die Lizenztexte aus LICENSES/ gehen unveraendert nach
Website/licenses/ und werden von der Seite verlinkt.
"""
import html, os, re, shutil, sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import *

APP = os.path.dirname(WEBSITE)
QUELLE = os.path.join(APP, "THIRD-PARTY-NOTICES.md")
TEXTE = os.path.join(APP, "LICENSES")
ZIEL = os.path.join(WEBSITE, "licenses")

# Pfade im Repository, die der Text nennt: auf der Website werden daraus Links.
REPO = {
    "Werkzeuge/vlckit-patches/": GITHUB + "/tree/main/Werkzeuge/vlckit-patches",
    "Documentation/VLCKit.md": GITHUB + "/blob/main/Documentation/VLCKit.md",
    "Documentation/Building.md": GITHUB + "/blob/main/Documentation/Building.md",
    "Website/schrift/OFL.txt": "/schrift/OFL.txt",
}


def anker(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def zeile(text):
    """Eine Zeile Markdown als HTML: Code, fett, Links, nackte Adressen, Repo-Pfade."""
    teile, rest = [], text
    muster = re.compile(
        r"\[`?([^\]`]+)`?\]\(([^)]+)\)"          # [Text](Ziel)
        r"|`([^`]+)`"                            # `Code`
        r"|\*\*([^*]+)\*\*"                      # **fett**
        r"|(https?://[^\s|)]+[^\s|).,;])"        # nackte Adresse
        r"|(info@swiftlyplayer\.com)"
        r"|(LICENSES/[A-Za-z0-9.+-]+\.txt)"
        r"|(" + "|".join(re.escape(p) for p in REPO) + r")")
    pos = 0
    for m in muster.finditer(rest):
        teile.append(html.escape(rest[pos:m.start()], quote=False))
        pos = m.end()
        if m.group(1):
            ziel = m.group(2)
            if ziel.startswith("LICENSES/"):
                ziel = "/licenses/" + ziel.split("/", 1)[1]
            teile.append(f'<a href="{html.escape(ziel)}">{html.escape(m.group(1).replace("LICENSES/", ""))}</a>')
        elif m.group(3):
            wort = m.group(3)
            if wort == "LICENSE":
                teile.append(f'<a href="{GITHUB}/blob/main/LICENSE" target="_blank" rel="noopener"><code>LICENSE</code></a>')
            elif wort == "LICENSES/":
                teile.append('<a href="#license-texts">the list below</a>')
            else:
                teile.append(f"<code>{html.escape(wort)}</code>")
        elif m.group(4):
            teile.append(f"<strong>{zeile(m.group(4))}</strong>")
        elif m.group(5):
            u = html.escape(m.group(5))
            teile.append(f'<a href="{u}" target="_blank" rel="noopener">{u.split("://", 1)[1].rstrip("/")}</a>')
        elif m.group(6):
            teile.append(f'<a href="mailto:{m.group(6)}">{m.group(6)}</a>')
        elif m.group(7):
            name = m.group(7).split("/", 1)[1]
            teile.append(f'<a href="/licenses/{name}">{name}</a>')
        else:
            pfad = m.group(8)
            fremd = "" if REPO[pfad].startswith("/") else ' target="_blank" rel="noopener"'
            teile.append(f'<a href="{REPO[pfad]}"{fremd}>{html.escape(pfad)}</a>')
    teile.append(html.escape(rest[pos:], quote=False))
    return "".join(teile)


def tabelle(zeilen):
    kopf_zellen = [z.strip() for z in zeilen[0].strip("|").split("|")]
    aus = ['    <div class="lz-tabelle"><table>', "      <thead><tr>"
           + "".join(f"<th scope=\"col\">{html.escape(k)}</th>" for k in kopf_zellen) + "</tr></thead>", "      <tbody>"]
    for z in zeilen[2:]:
        zellen = [c.strip() for c in z.strip().strip("|").split("|")]
        aus.append("        <tr>" + "".join(
            (f'<th scope="row" data-k="{html.escape(kopf_zellen[i])}">{zeile(c)}</th>' if i == 0
             else f'<td data-k="{html.escape(kopf_zellen[i])}">{zeile(c)}</td>')
            for i, c in enumerate(zellen)) + "</tr>")
    aus += ["      </tbody>", "    </table></div>"]
    return "\n".join(aus)


def umsetzen(text):
    """Die Notices-Datei in Abschnitte der Seite. Gibt (einleitung, html) zurueck."""
    zeilen = text.splitlines()
    einleitung, aus, i, offen = "", [], 0, False
    while i < len(zeilen):
        z = zeilen[i]
        if not z.strip():
            i += 1
            continue
        if z.startswith("# "):
            i += 1
            continue
        if z.startswith("## "):
            titel = z[3:].strip()
            if offen:
                aus.append("  </section>\n")
            kennung = anker(titel)
            aus.append(f'  <section class="abschnitt lz" aria-labelledby="{kennung}">\n    <h2 id="{kennung}">{zeile(titel)}</h2>')
            offen = True
            i += 1
        elif z.startswith("### "):
            titel = z[4:].strip()
            aus.append(f'    <h3 id="{anker(titel)}">{zeile(titel)}</h3>')
            i += 1
        elif z.startswith("|"):
            block = []
            while i < len(zeilen) and zeilen[i].startswith("|"):
                block.append(zeilen[i])
                i += 1
            aus.append(tabelle(block))
        elif z.startswith("- "):
            punkte = []
            while i < len(zeilen) and zeilen[i].startswith("- "):
                punkte.append(f"      <li>{zeile(zeilen[i][2:].strip())}</li>")
                i += 1
            aus.append('    <ul class="lz-liste">\n' + "\n".join(punkte) + "\n    </ul>")
        else:
            absatz = []
            while i < len(zeilen) and zeilen[i].strip() and not zeilen[i].startswith(("#", "|", "- ")):
                absatz.append(zeilen[i].strip())
                i += 1
            ganz = " ".join(absatz)
            if not offen:
                # Der Satz ueber die Erzeugung der Datei gilt dem Repository, nicht der Seite.
                einleitung = re.sub(r"\s*This file is generated.*$", "", ganz)
            elif ganz == "Notes:":
                aus.append('    <p class="lz-notiz">Notes</p>')
            else:
                aus.append(f"    <p>{zeile(ganz)}</p>")
    if offen:
        aus.append("  </section>\n")
    return einleitung, "\n".join(aus)


CSS = """<style>
.lz > h3 { margin: 34px 0 0; font-size: 19px; font-weight: 600; letter-spacing: -.01em; }
.lz > p { max-width: 760px; overflow-wrap: anywhere; }
.lz > p.lz-notiz { margin-top: 26px; color: var(--schrift); font-size: 15px; font-weight: 600; }
.lz code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: .92em; }
.lz-liste { margin: 12px 0 0; padding-left: 20px; max-width: 760px; color: var(--leise); font-size: 15.5px; line-height: 1.55; }
.lz-liste li { margin-top: 7px; overflow-wrap: anywhere; }
.lz-liste strong, .lz > p strong { color: var(--schrift); font-weight: 600; }
.lz-kurz { margin-top: 40px; padding: 24px 26px; border-radius: 20px; background: var(--flaeche); }
.lz-kurz p { margin: 0; color: var(--schrift); font-size: 18px; font-weight: 600; line-height: 1.4; }
.lz-kurz ul { display: flex; flex-wrap: wrap; gap: 8px 22px; margin: 14px 0 0; padding: 0; list-style: none; font-size: 15.5px; }
.lz-kurz a { color: var(--akzent); text-decoration: underline; text-underline-offset: 3px; }
/* Sechs Spalten brauchen mehr als die Lesespalte: die Tabelle ragt mittig darueber hinaus. */
.lz-tabelle { position: relative; left: 50%; translate: -50% 0; width: min(1120px, 100vw - 48px); margin-top: 20px;
  overflow-x: auto; -webkit-overflow-scrolling: touch; border-radius: 16px; background: var(--flaeche); }
.lz-tabelle table { width: 100%; min-width: 900px; border-collapse: collapse; font-size: 14px; line-height: 1.45; }
.lz-tabelle th, .lz-tabelle td { padding: 11px 14px; text-align: left; vertical-align: top; border-top: 1px solid var(--linie); color: var(--leise); font-weight: 400; overflow-wrap: anywhere; }
.lz-tabelle thead th { border-top: 0; color: var(--schrift); font-size: 13px; font-weight: 600; white-space: nowrap; }
.lz-tabelle tbody th { color: var(--schrift); font-weight: 600; min-width: 170px; }
@media (max-width: 760px) {
  .lz-tabelle { position: static; translate: none; width: auto; overflow: visible; background: none; border-radius: 0; }
  .lz-tabelle table { min-width: 0; display: block; }
  .lz-tabelle thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
  .lz-tabelle tbody { display: block; }
  .lz-tabelle tr { display: block; margin-top: 10px; padding: 14px 16px; border-radius: 14px; background: var(--flaeche); }
  .lz-tabelle th, .lz-tabelle td { display: block; padding: 0; border: 0; min-width: 0; }
  .lz-tabelle tbody th { font-size: 16px; margin-bottom: 6px; }
  .lz-tabelle td { margin-top: 4px; }
  .lz-tabelle td::before { content: attr(data-k) ": "; color: var(--schrift); }
}
</style>
"""


def bauen():
    einleitung, inhalt = umsetzen(open(QUELLE, encoding="utf-8").read())
    os.makedirs(ZIEL, exist_ok=True)
    for name in sorted(os.listdir(TEXTE)):
        if name.endswith(".txt"):
            shutil.copyfile(os.path.join(TEXTE, name), os.path.join(ZIEL, name))
    # Der GPL-Text liegt nur bei, solange ein Baustein ihn braucht (VLC-Module unter Windows).
    gpl = ('\n      <li><a href="/licenses/GPL-2.0-or-later.txt">Full text of the GPL 2.0</a></li>'
           if os.path.exists(os.path.join(TEXTE, "GPL-2.0-or-later.txt")) else "")
    seite = kopf(
        "Open-source licenses - Swiftly Player",
        "Swiftly Player uses VLCKit and libVLC by VideoLAN under the LGPL 2.1 or later. Every third-party component with its license, copyright and source, and how to get the source code.",
        "/licenses/",
        og_titel="Open-source licenses",
        og_text="The third-party components in Swiftly Player, their licenses, and where the source code is.",
        extra_ld=CSS) + f"""  <header class="seitenkopf">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>Open-source licenses</li></ol>
    <h1>Open-source licenses</h1>
    <p class="unter">{zeile(einleitung)}</p>
  </header>

  <div class="lz-kurz">
    <p>Swiftly Player uses VLCKit and libVLC by VideoLAN under the LGPL 2.1 or later.</p>
    <ul>
      <li><a href="/licenses/LGPL-2.1-or-later.txt">Full text of the LGPL 2.1</a></li>{gpl}
      <li><a href="{REPO["Werkzeuge/vlckit-patches/"]}" target="_blank" rel="noopener">Swiftly's patches on GitHub</a></li>
      <li><a href="{GITHUB}/tree/main/Werkzeuge/vlckit-bau" target="_blank" rel="noopener">Build scripts on GitHub</a></li>
      <li><a href="https://code.videolan.org/videolan/VLCKit" target="_blank" rel="noopener">VLCKit at VideoLAN</a></li>
      <li><a href="#written-offer">Written offer for the source code</a></li>
    </ul>
  </div>

{inhalt}
""" + fuss("/licenses/")
    schreiben("/licenses/", seite)


bauen()
