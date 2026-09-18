#!/usr/bin/env python3
"""Baut den Blog von swiftlyplayer.com aus Markdown.

Quellen:  Website/blog/quellen/<slug>.md
          Website/seiten/quellen/<name>.md  (Landingpages, Kopf plus `pfad:`)
Ausgabe:  Website/blog/_artikel/  fertiges HTML ALLER Artikel, artikel.json,
                                  Titelbilder, lib.php (per .htaccess gesperrt)
          Website/blog/*.php      Artikel, Uebersicht, feed.xml, sitemap.xml,
                                  llms.txt, Titelbilder: zur Laufzeit gefiltert
          Website/<pfad>/index.html  Landingpages (sofort sichtbar)

Die Website veroeffentlicht selbst: PHP auf dem Webspace liefert einen Artikel
erst ab `datum` (Europe/Berlin) aus, vorher 404. Kein Mac, kein Zeitplan. Neu
Faelliges meldet PHP einmal an IndexNow. Hochladen nach jedem Bau:
  website-hochladen.py --nur-geaendert

  blog-bauen.py              Website/ bauen (alle Artikel, geschuetzt)
  blog-bauen.py --vorschau   zusaetzlich statische Vorschau mit allen Artikeln
                             ausserhalb von Website/ (wird nie hochgeladen);
                             ansehen mit: website-server.py 8789 <ordner>
Titelbilder: SVG mit Umrissen aus blog-schrift.json (blog-schrift.swift),
gerastert mit sips (macOS). Bilder im Text liegen in Website/blog/bilder/.

Kopf jeder Quelle (verbindlich):
  ---
  titel: ...
  beschreibung: ...          # <= 155 Zeichen
  datum: 2026-09-22
  slug: best-jellyfin-client-linux
  schlagworte: [jellyfin, linux, clients]
  offenlegung: ja
  aktualisiert: 2026-09-22   # optional
  ---
Markdown: # bis ####, Absaetze, - / 1. Listen (eingerueckt verschachtelt),
Tabellen, ``` Code, > Zitat, ---, **fett**, *kursiv*, `code`, [Link](url),
![Alt](datei.webp "Unterschrift | Source: ...") als eigene Zeile
= Abbildung. Sonderblock `:::swiftly` ... `:::`. `## FAQ` mit `### Frage`
ergibt zusaetzlich FAQPage-JSON-LD.

Ohne Fremdpakete, laeuft mit /usr/bin/python3 (3.9), weil launchd genau den
nimmt. Kein rohes HTML in den Quellen: alles wird maskiert.
"""
import datetime as dt
import email.utils
import hashlib
import html
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo

HIER = os.path.dirname(os.path.abspath(__file__))
WEBSITE = os.path.normpath(os.path.join(HIER, "..", "Website"))
QUELLEN = os.path.join(WEBSITE, "blog", "quellen")
SEITEN_QUELLEN = os.path.join(WEBSITE, "seiten", "quellen")
BILDER = os.path.join(WEBSITE, "blog", "bilder")
VORSCHAU = os.path.expanduser("~/Library/Caches/swiftly-blog-vorschau")

DOMAIN = "https://swiftlyplayer.com"
HERAUSGEBER = "Swiftly Player"          # nie ein Personenname an einem Artikel
APP_ID = "6806824067"
APP_STORE = "https://apps.apple.com/app/id6806824067"
GITHUB = "https://github.com/paulherter/swiftly-player"
RELEASES = GITHUB + "/releases"
# Jede Plattform hat ihre eigene Seite mit Schritten und Skizzen; die
# Knoepfe fuehren dorthin und nicht mehr direkt nach aussen (Paul, 17.09.).
APPLE_SEITE = "/download/app-store/"
WINDOWS = "/download/windows/"
LINUX = "/download/linux/"
ANDROID = "/android/"
TESTFLIGHT_SEITE = "/download/testflight/"
DISCORD = "https://discord.gg/MeGwfv3UwN"
MARKER = '<meta name="generator" content="blog-bauen">'
OFFENLEGUNG = ("<strong>Disclosure:</strong> we build Swiftly Player, one of the clients in this "
               "article. We point out where other apps do better.")
ZONE = ZoneInfo("Europe/Berlin")
MONATE = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]

warnungen = []


def warne(text):
    warnungen.append(text)
    print("Warnung: " + text, file=sys.stderr)


# ------------------------------------------------------------------ Quellen

def kopf_lesen(text, datei):
    if not text.startswith("---"):
        raise ValueError(f"{datei}: Kopf fehlt (erste Zeile muss --- sein)")
    zeilen = text.split("\n")
    ende = next((i for i in range(1, len(zeilen)) if zeilen[i].strip() == "---"), None)
    if ende is None:
        raise ValueError(f"{datei}: Kopf nicht mit --- geschlossen")
    kopf = {}
    for z in zeilen[1:ende]:
        if not z.strip() or z.lstrip().startswith("#"):
            continue
        if ":" not in z:
            raise ValueError(f"{datei}: Kopfzeile ohne Doppelpunkt: {z!r}")
        k, v = z.split(":", 1)
        v = re.sub(r"\s+#.*$", "", v).strip()          # Kommentar am Zeilenende
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if v.startswith("[") and v.endswith("]"):
            v = [t.strip().strip("\"'") for t in v[1:-1].split(",") if t.strip()]
        kopf[k.strip().lower()] = v
    return kopf, "\n".join(zeilen[ende + 1:])


def datum_lesen(wert, feld, datei):
    try:
        return dt.date.fromisoformat(str(wert))
    except ValueError:
        raise ValueError(f"{datei}: {feld} ist kein Datum JJJJ-MM-TT: {wert!r}")


def artikel_laden(ordner=QUELLEN, seiten=False):
    """Blogartikel, oder mit seiten=True Landingpages (zusaetzlich `pfad:`, kein Datumsfilter)."""
    artikel = []
    if not os.path.isdir(ordner):
        return artikel
    for name in sorted(os.listdir(ordner)):
        if not name.endswith(".md") or name.startswith("_"):
            continue
        pfad = os.path.join(ordner, name)
        with open(pfad, encoding="utf-8") as h:
            kopf, rumpf = kopf_lesen(h.read().replace("\r\n", "\n"), name)
        for feld in ("titel", "beschreibung", "datum", "slug"):
            if not kopf.get(feld):
                raise ValueError(f"{name}: Feld '{feld}' fehlt")
        slug = kopf["slug"]
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug):
            raise ValueError(f"{name}: slug nur a-z, 0-9 und Bindestriche: {slug!r}")
        if name[:-3] != slug and not name.startswith("_"):
            warne(f"{name}: Dateiname und slug '{slug}' weichen ab")
        if len(kopf["beschreibung"]) > 155:
            warne(f"{name}: beschreibung hat {len(kopf['beschreibung'])} Zeichen (> 155)")
        schlagworte = kopf.get("schlagworte") or []
        if isinstance(schlagworte, str):
            schlagworte = [s.strip() for s in schlagworte.split(",") if s.strip()]
        datum = datum_lesen(kopf["datum"], "datum", name)
        aktualisiert = datum_lesen(kopf["aktualisiert"], "aktualisiert", name) if kopf.get("aktualisiert") else None
        bloecke = bloecke_lesen(rumpf.split("\n"))
        if re.search(r"^\W*disclosure\b", rumpf, re.I | re.M):
            warne(f"{name}: eigener 'Disclosure'-Absatz im Text; der Kasten kommt schon aus 'offenlegung: ja'")
        artikel.append({
            "datei": name, "titel": kopf["titel"], "beschreibung": kopf["beschreibung"],
            "datum": datum, "aktualisiert": aktualisiert if aktualisiert and aktualisiert > datum else None,
            "slug": slug, "schlagworte": [s.lower() for s in schlagworte],
            "offenlegung": str(kopf.get("offenlegung", "nein")).lower() in ("ja", "yes", "true", "1"),
            "bloecke": bloecke, "woerter": len(re.findall(r"\w+", rumpf)),
            "url": f"{DOMAIN}/blog/{slug}/", "pfad": f"/blog/{slug}/", "seite": seiten,
            "bild": f"/blog/titel/{slug}.jpg", "kategorie": kopf.get("kategorie") or "",
        })
        if seiten:
            ziel = str(kopf.get("pfad") or "")
            if not re.fullmatch(r"/[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)*/", ziel) \
                    or ziel.split("/")[1] in ("blog", "bilder", "aufnahmen", "schrift", "android", "seiten"):
                raise ValueError(f"{name}: pfad fehlt oder ist nicht erlaubt: {ziel!r} (Form /jellyfin-client-apple-tv/)")
            stamm = ziel.strip("/").split("/")[-1].replace("jellyfin-client-", "")
            kurz = kopf.get("kurzname") or " and ".join(
                {"tv": "TV", "iphone": "iPhone", "ipad": "iPad", "mac": "Mac", "macos": "macOS"}.get(w, w.title())
                for w in stamm.split("-")).replace("Android and TV", "Android TV").replace("Apple and TV", "Apple TV")
            artikel[-1].update({"pfad": ziel, "url": DOMAIN + ziel, "bild": ziel + "titelbild.jpg", "kurzname": kurz})
    doppelt = {a["slug"] for a in artikel if sum(b["slug"] == a["slug"] for b in artikel) > 1}
    if doppelt:
        raise ValueError(f"slug doppelt vergeben: {sorted(doppelt)}")
    return artikel


# ------------------------------------------------------------------ Markdown

def e(text):
    return html.escape(text, quote=True)


def kennung(text):
    t = re.sub(r"<[^>]+>", "", text).lower()
    t = re.sub(r"[^a-z0-9]+", "-", t).strip("-")
    return t or "abschnitt"


INLINE = re.compile(
    r"(?P<code>`+)(?P<codetext>.+?)(?P=code)"
    r"|!\[(?P<alt>[^\]]*)\]\((?P<bild>[^)\s]+)(?:\s+\"(?P<bildtitel>[^\"]*)\")?\)"
    r"|\[(?P<linktext>(?:[^\[\]]|\[[^\]]*\])+)\]\((?P<link>[^)\s]+)\)"
    r"|<(?P<auto>https?://[^>\s]+)>"
    r"|\*\*(?P<fett>.+?)\*\*"
    r"|(?<![\w*])\*(?P<kursiv>[^*\s](?:[^*]*[^*\s])?)\*(?![\w*])"
    r"|(?<![\w_])_(?P<kursiv2>[^_\s](?:[^_]*[^_\s])?)_(?![\w_])"
)


def link_attr(url):
    extern = url.startswith("http") and not url.startswith(DOMAIN)
    return f' href="{e(url)}"' + (' target="_blank" rel="noopener"' if extern else "")


def inline(text):
    aus, pos = [], 0
    for m in INLINE.finditer(text):
        aus.append(e(text[pos:m.start()]))
        if m.group("code"):
            aus.append(f"<code>{e(m.group('codetext').strip())}</code>")
        elif m.group("bild") is not None:
            aus.append(bild_tag(m.group("bild"), m.group("alt")))
        elif m.group("link") is not None:
            aus.append(f"<a{link_attr(m.group('link'))}>{inline(m.group('linktext'))}</a>")
        elif m.group("auto"):
            aus.append(f"<a{link_attr(m.group('auto'))}>{e(m.group('auto'))}</a>")
        elif m.group("fett") is not None:
            aus.append(f"<strong>{inline(m.group('fett'))}</strong>")
        else:
            aus.append(f"<em>{inline(m.group('kursiv') or m.group('kursiv2'))}</em>")
        pos = m.end()
    aus.append(e(text[pos:]))
    return "".join(aus)


def absatz_inline(zeilen):
    teile = []
    for i, z in enumerate(zeilen):
        umbruch = i < len(zeilen) - 1 and (z.endswith("  ") or z.endswith("\\"))
        z = z.rstrip()
        if z.endswith("\\"):
            z = z[:-1]
        teile.append(inline(z.strip()) + ("<br>" if umbruch else ""))
    return "\n".join(teile)


def bild_masse(pfad):
    """Breite, Hoehe aus SVG (viewBox), PNG, WebP oder JPEG; None, wenn unlesbar."""
    try:
        with open(pfad, "rb") as h:
            kopf = h.read(4096) if not pfad.endswith(".jpg") and not pfad.endswith(".jpeg") else h.read()
    except OSError:
        return None
    if pfad.endswith(".svg"):
        m = re.search(rb'viewBox="\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)', kopf)
        return (round(float(m.group(1))), round(float(m.group(2)))) if m else None
    if kopf[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", kopf[16:24])
    if kopf[:4] == b"RIFF" and kopf[8:12] == b"WEBP":
        art = kopf[12:16]
        if art == b"VP8X":
            return (1 + int.from_bytes(kopf[24:27], "little"), 1 + int.from_bytes(kopf[27:30], "little"))
        if art == b"VP8 ":
            b, h_ = struct.unpack("<HH", kopf[26:30])
            return (b & 0x3FFF, h_ & 0x3FFF)
        if art == b"VP8L":
            n = int.from_bytes(kopf[21:25], "little")
            return ((n & 0x3FFF) + 1, ((n >> 14) & 0x3FFF) + 1)
    if kopf[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(kopf):
            if kopf[i] != 0xFF:
                i += 1
                continue
            marke, laenge = kopf[i + 1], struct.unpack(">H", kopf[i + 2:i + 4])[0]
            if marke in (0xC0, 0xC1, 0xC2):
                h_, b = struct.unpack(">HH", kopf[i + 5:i + 9])
                return (b, h_)
            i += 2 + laenge
    return None


def bild_quelle(src):
    """'datei.webp' -> /blog/bilder/datei.webp. Fremde Bilder gibt es nicht (Urheberrecht)."""
    if src.startswith("http"):
        warne(f"Bild aus dem Netz: {src} (nur eigene Bilder unter blog/bilder/)")
        return src, None
    if src.startswith("/"):
        return src, os.path.join(WEBSITE, src.lstrip("/"))
    return "/blog/bilder/" + src, os.path.join(BILDER, src)


def bild_tag(src, alt):
    url, datei = bild_quelle(src)
    masse = bild_masse(datei) if datei else None
    if datei and masse is None:
        warne(f"Bild fehlt oder unlesbar: {src}")
    groesse = f' width="{masse[0]}" height="{masse[1]}"' if masse else ""
    hoch = " hoch" if masse and masse[1] > masse[0] else ""
    return f'<img class="abbildung{hoch}" src="{e(url)}" alt="{e(alt)}"{groesse} loading="lazy" decoding="async">'


BILDZEILE = re.compile(r'^!\[(?P<alt>[^\]]*)\]\((?P<bild>[^)\s]+)(?:\s+"(?P<titel>[^"]*)")?\)$')


def abbildung(m):
    """Unterschrift 'Text | Source: ...' -> Text plus leise Quellenangabe."""
    unter = ""
    if m.group("titel"):
        text, _, quelle = m.group("titel").partition(" | ")
        unter = inline(text.strip())
        if quelle.strip():
            unter += f' <span class="quelle">{inline(quelle.strip())}</span>'
        unter = f"<figcaption>{unter}</figcaption>"
    return f"<figure>{bild_tag(m.group('bild'), m.group('alt'))}{unter}</figure>"


LISTE = re.compile(r"^( *)([-*+]|\d+[.)])\s+(.*)$")
TABELLE_TRENNER = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def zellen(zeile):
    z = zeile.strip()
    if z.startswith("|"):
        z = z[1:]
    if z.endswith("|") and not z.endswith("\\|"):
        z = z[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", z)]


def ist_blockanfang(z):
    s = z.strip()
    return (s.startswith("#") and re.match(r"^#{1,6}\s", s)) or s.startswith("```") \
        or s.startswith(">") or s.startswith(":::") or LISTE.match(z) \
        or re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", s)


def bloecke_lesen(zeilen):
    """Zeilen -> Liste von Bloecken (dicts). Kein HTML hier."""
    bloecke, i, n = [], 0, len(zeilen)
    while i < n:
        z = zeilen[i]
        s = z.strip()
        if not s:
            i += 1
            continue
        if s.startswith("```"):
            sprache = s[3:].strip()
            i += 1
            code = []
            while i < n and not zeilen[i].strip().startswith("```"):
                code.append(zeilen[i])
                i += 1
            i += 1
            bloecke.append({"art": "code", "sprache": sprache, "text": "\n".join(code)})
            continue
        if s.lower().startswith(":::swiftly"):
            i += 1
            innen, tiefe = [], 1
            while i < n:
                t = zeilen[i].strip()
                if t.startswith(":::") and t != ":::":
                    tiefe += 1
                elif t == ":::":
                    tiefe -= 1
                    if tiefe == 0:
                        break
                innen.append(zeilen[i])
                i += 1
            i += 1
            bloecke.append({"art": "swiftly", "kinder": bloecke_lesen(innen)})
            continue
        m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", s)
        if m:
            bloecke.append({"art": "ueberschrift", "stufe": len(m.group(1)), "text": m.group(2)})
            i += 1
            continue
        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", s):
            bloecke.append({"art": "linie"})
            i += 1
            continue
        if s.startswith(">"):
            innen = []
            while i < n and zeilen[i].strip().startswith(">"):
                innen.append(re.sub(r"^\s*>\s?", "", zeilen[i]))
                i += 1
            bloecke.append({"art": "zitat", "kinder": bloecke_lesen(innen)})
            continue
        if "|" in s and i + 1 < n and TABELLE_TRENNER.match(zeilen[i + 1]) and zeilen[i + 1].count("-") >= 2:
            kopf = zellen(z)
            ausrichtung = []
            for c in zellen(zeilen[i + 1]):
                ausrichtung.append("center" if c.startswith(":") and c.endswith(":")
                                   else "right" if c.endswith(":") else "left" if c.startswith(":") else "")
            i += 2
            reihen = []
            while i < n and zeilen[i].strip() and "|" in zeilen[i]:
                reihen.append(zellen(zeilen[i]))
                i += 1
            bloecke.append({"art": "tabelle", "kopf": kopf, "ausrichtung": ausrichtung, "reihen": reihen})
            continue
        m = LISTE.match(z)
        if m:
            einzug = len(m.group(1))
            geordnet = m.group(2)[0].isdigit()
            start = int(re.match(r"\d+", m.group(2)).group()) if geordnet else 1
            punkte = []
            while i < n:
                m = LISTE.match(zeilen[i])
                if m and len(m.group(1)) <= einzug + 1 and m.group(2)[0].isdigit() == geordnet:
                    punkte.append([m.group(3)])
                    i += 1
                    continue
                if m and len(m.group(1)) <= einzug + 1:
                    break                                   # andere Listenart
                if not zeilen[i].strip():
                    # Leerzeile: Liste geht weiter, wenn danach eingerueckt oder neuer Punkt folgt
                    j = i + 1
                    while j < n and not zeilen[j].strip():
                        j += 1
                    if j < n and punkte and (zeilen[j].startswith(" " * (einzug + 2))
                                             or (LISTE.match(zeilen[j]) and len(LISTE.match(zeilen[j]).group(1)) <= einzug + 1
                                                 and LISTE.match(zeilen[j]).group(2)[0].isdigit() == geordnet)):
                        punkte[-1].append("")
                        i = j
                        continue
                    break
                if zeilen[i].startswith(" " * (einzug + 2)) or (punkte and not ist_blockanfang(zeilen[i])):
                    punkte[-1].append(zeilen[i][einzug + 2:] if zeilen[i].startswith(" " * (einzug + 2)) else zeilen[i].strip())
                    i += 1
                    continue
                break
            bloecke.append({"art": "liste", "geordnet": geordnet, "start": start,
                            "punkte": [bloecke_lesen(p) for p in punkte],
                            "eng": all("" not in p for p in punkte)})
            continue
        absatz = []
        while i < n and zeilen[i].strip() and not (absatz and ist_blockanfang(zeilen[i])):
            if "|" in zeilen[i] and i + 1 < n and TABELLE_TRENNER.match(zeilen[i + 1]) and absatz:
                break
            absatz.append(zeilen[i])
            i += 1
        bloecke.append({"art": "absatz", "zeilen": absatz})
    return bloecke


def rendern(bloecke, eng=False, vergebene=None):
    vergebene = vergebene if vergebene is not None else set()
    aus = []
    for b in bloecke:
        art = b["art"]
        if art == "absatz":
            bildzeile = BILDZEILE.match(b["zeilen"][0].strip()) if len(b["zeilen"]) == 1 else None
            if bildzeile:
                aus.append(abbildung(bildzeile))
                continue
            inhalt = absatz_inline(b["zeilen"])
            aus.append(inhalt if eng else f"<p>{inhalt}</p>")
        elif art == "ueberschrift":
            stufe = b["stufe"]
            if stufe == 1:
                warne("'# ' im Artikel: der Titel kommt aus dem Kopf, gesetzt als h2")
                stufe = 2
            k, basis, zahl = kennung(b["text"]), kennung(b["text"]), 2
            while k in vergebene:
                k, zahl = f"{basis}-{zahl}", zahl + 1
            vergebene.add(k)
            aus.append(f'<h{stufe} id="{k}">{inline(b["text"])}</h{stufe}>')
        elif art == "code":
            klasse = f' class="language-{e(b["sprache"])}"' if b["sprache"] else ""
            # Der Kasten traegt den Kopieren-Knopf, den das Skript hineinsetzt
            # (ohne Skript stuende sonst ein Knopf da, der nichts tut). Bei
            # einem Befehl steht darunter, was man damit macht: Paul hat den
            # Einzeiler fuer Linux behalten, aber nicht jeder weiss, dass er
            # in ein Terminal gehoert.
            schale = f'<div class="codeblock"><pre><code{klasse}>{e(b["text"])}</code></pre></div>'
            if b["sprache"] in ("sh", "bash", "shell", "zsh", "console"):
                schale += '<p class="befehlszeile">Paste it into a terminal and press Enter.</p>'
            aus.append(schale)
        elif art == "linie":
            aus.append("<hr>")
        elif art == "zitat":
            aus.append(f"<blockquote>{rendern(b['kinder'], vergebene=vergebene)}</blockquote>")
        elif art == "tabelle":
            def zelle(tag, text, spalte):
                a = b["ausrichtung"][spalte] if spalte < len(b["ausrichtung"]) else ""
                stil = f' style="text-align:{a}"' if a else ""
                return f"<{tag}{stil}>{inline(text)}</{tag}>"
            kopf = "".join(zelle("th", t, j) for j, t in enumerate(b["kopf"]))
            reihen = "".join("<tr>" + "".join(zelle("td", r[j] if j < len(r) else "", j)
                                              for j in range(len(b["kopf"]))) + "</tr>" for r in b["reihen"])
            aus.append(f'<div class="tabelle"><table><thead><tr>{kopf}</tr></thead><tbody>{reihen}</tbody></table></div>')
        elif art == "liste":
            tag = "ol" if b["geordnet"] else "ul"
            start = f' start="{b["start"]}"' if b["geordnet"] and b["start"] != 1 else ""
            punkte = "".join(f"<li>{rendern(p, eng=b['eng'], vergebene=vergebene)}</li>" for p in b["punkte"])
            aus.append(f"<{tag}{start}>{punkte}</{tag}>")
        elif art == "swiftly":
            aus.append(swiftly_kasten(rendern(b["kinder"], vergebene=vergebene)))
        elif art == "kurz":
            k = kennung(b["titel"])
            vergebene.add(k)
            aus.append(f'<section class="kurz" aria-labelledby="{k}"><h2 id="{k}">{inline(b["titel"])}</h2>'
                       f'{rendern(b["kinder"], vergebene=vergebene)}</section>')
        elif art == "faq":
            fragen = []
            for n, (frage, antwort) in enumerate(b["paare"]):
                k, basis, zahl = kennung(frage), kennung(frage), 2
                while k in vergebene:
                    k, zahl = f"{basis}-{zahl}", zahl + 1
                vergebene.add(k)
                offen = " open" if n == 0 else ""
                fragen.append(f'<details class="frage" id="{k}"{offen}><summary class="frage__knopf">'
                              f'<h3>{inline(frage)}</h3>{PFEIL}</summary>'
                              f'<div class="frage__antwort">{rendern(antwort, vergebene=vergebene)}</div></details>')
            aus.append(f'<div class="fragen__blatt">{"".join(fragen)}</div>')
    return "\n".join(aus)


FAQ_TITEL = ("faq", "faqs", "frequently asked questions")


def gliedern(bloecke):
    """## FAQ -> Blatt mit aufklappbaren Fragen wie auf der Startseite,
    ## TL;DR -> kurzer Kasten. Alles andere bleibt, wie es ist."""
    aus, i = [], 0
    while i < len(bloecke):
        b = bloecke[i]
        titel = b.get("text", "").strip().lower() if b["art"] == "ueberschrift" and b["stufe"] <= 2 else None
        if titel in FAQ_TITEL or titel in ("tl;dr", "tldr", "in short"):
            j = i + 1
            while j < len(bloecke) and not (bloecke[j]["art"] == "ueberschrift" and bloecke[j]["stufe"] <= 2):
                j += 1
            teil = bloecke[i + 1:j]
            if titel in FAQ_TITEL:
                vorspann, paare = [], []
                for c in teil:
                    if c["art"] == "ueberschrift" and c["stufe"] == 3:
                        paare.append((c["text"], []))
                    elif paare:
                        paare[-1][1].append(c)
                    else:
                        vorspann.append(c)
                aus += [b] + vorspann + [{"art": "faq", "paare": paare}]
            else:
                aus.append({"art": "kurz", "titel": b["text"], "kinder": teil})
            i = j
            continue
        aus.append(b)
        i += 1
    return aus


PFEIL = ('<svg class="frage__pfeil" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.9" '
         'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7.5 4.5 13 10l-5.5 5.5"/></svg>')


def reiner_text(bloecke):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", rendern(bloecke)))).strip()


def faq_finden(bloecke):
    """## FAQ -> [(Frage, Antworttext)] bis zur naechsten h2."""
    paare, drin, frage, antwort = [], False, None, []
    for b in bloecke + [{"art": "ueberschrift", "stufe": 2, "text": ""}]:
        if b["art"] == "ueberschrift" and b["stufe"] <= 3:
            if frage and antwort:
                paare.append((html.unescape(re.sub(r"<[^>]+>", "", inline(frage))), reiner_text(antwort)))
            frage, antwort = None, []
            if b["stufe"] <= 2:
                drin = b["text"].strip().lower() in ("faq", "faqs", "frequently asked questions")
            elif drin:
                frage = b["text"]
            continue
        if drin and frage:
            antwort.append(b)
    return paare


# ------------------------------------------------------------------ Vorlage

def datum_text(d):
    return f"{d.day} {MONATE[d.month - 1]} {d.year}"


SYMBOL = ('<svg viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.7" '
          'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8.5 3 4.5 7l4 4"/></svg>')

# Plattformlogos einfarbig in currentColor, Pfade aus Simple Icons (CC0):
# android (Roboter nach Google, CC BY 3.0, Hinweis im Fuss), linux (Tux).
# Windows ist bei Simple Icons auf Wunsch von Microsoft entfernt; die vier
# Quadrate wie "Windows logo - 2021.svg" auf Wikimedia Commons (gemeinfrei).
# apple (Simple Icons, CC0). Paul, 17.09.: das grosse "Download on the
# App Store"-Badge sah neben den vier kleinen Knoepfen wie ein Fremdkoerper
# aus. Jetzt tragen alle vier dasselbe Zeichen im Kreis. Der Hinweis
# "App Store is a service mark of Apple Inc." bleibt im Fuss.
_Z = '<svg viewBox="0 0 24 24" fill="currentColor">'
ZEICHEN_ANDROID = _Z + '<path d="M18.4395 5.5586c-.675 1.1664-1.352 2.3318-2.0274 3.498-.0366-.0155-.0742-.0286-.1113-.043-1.8249-.6957-3.484-.8-4.42-.787-1.8551.0185-3.3544.4643-4.2597.8203-.084-.1494-1.7526-3.021-2.0215-3.4864a1.1451 1.1451 0 0 0-.1406-.1914c-.3312-.364-.9054-.4859-1.379-.203-.475.282-.7136.9361-.3886 1.5019 1.9466 3.3696-.0966-.2158 1.9473 3.3593.0172.031-.4946.2642-1.3926 1.0177C2.8987 12.176.452 14.772 0 18.9902h24c-.119-1.1108-.3686-2.099-.7461-3.0683-.7438-1.9118-1.8435-3.2928-2.7402-4.1836a12.1048 12.1048 0 0 0-2.1309-1.6875c.6594-1.122 1.312-2.2559 1.9649-3.3848.2077-.3615.1886-.7956-.0079-1.1191a1.1001 1.1001 0 0 0-.8515-.5332c-.5225-.0536-.9392.3128-1.0488.5449zm-.0391 8.461c.3944.5926.324 1.3306-.1563 1.6503-.4799.3197-1.188.0985-1.582-.4941-.3944-.5927-.324-1.3307.1563-1.6504.4727-.315 1.1812-.1086 1.582.4941zM7.207 13.5273c.4803.3197.5506 1.0577.1563 1.6504-.394.5926-1.1038.8138-1.584.4941-.48-.3197-.5503-1.0577-.1563-1.6504.4008-.6021 1.1087-.8106 1.584-.4941z"/></svg>'
ZEICHEN_WINDOWS = _Z + '<path d="M0 0h11.377v11.372H0zm12.623 0H24v11.372H12.623zM0 12.623h11.377V24H0zm12.623 0H24V24H12.623z"/></svg>'
ZEICHEN_LINUX = _Z + '<path d="M12.504 0c-.155 0-.315.008-.48.021-4.226.333-3.105 4.807-3.17 6.298-.076 1.092-.3 1.953-1.05 3.02-.885 1.051-2.127 2.75-2.716 4.521-.278.832-.41 1.684-.287 2.489a.424.424 0 00-.11.135c-.26.268-.45.6-.663.839-.199.199-.485.267-.797.4-.313.136-.658.269-.864.68-.09.189-.136.394-.132.602 0 .199.027.4.055.536.058.399.116.728.04.97-.249.68-.28 1.145-.106 1.484.174.334.535.47.94.601.81.2 1.91.135 2.774.6.926.466 1.866.67 2.616.47.526-.116.97-.464 1.208-.946.587-.003 1.23-.269 2.26-.334.699-.058 1.574.267 2.577.2.025.134.063.198.114.333l.003.003c.391.778 1.113 1.132 1.884 1.071.771-.06 1.592-.536 2.257-1.306.631-.765 1.683-1.084 2.378-1.503.348-.199.629-.469.649-.853.023-.4-.2-.811-.714-1.376v-.097l-.003-.003c-.17-.2-.25-.535-.338-.926-.085-.401-.182-.786-.492-1.046h-.003c-.059-.054-.123-.067-.188-.135a.357.357 0 00-.19-.064c.431-1.278.264-2.55-.173-3.694-.533-1.41-1.465-2.638-2.175-3.483-.796-1.005-1.576-1.957-1.56-3.368.026-2.152.236-6.133-3.544-6.139zm.529 3.405h.013c.213 0 .396.062.584.198.19.135.33.332.438.533.105.259.158.459.166.724 0-.02.006-.04.006-.06v.105a.086.086 0 01-.004-.021l-.004-.024a1.807 1.807 0 01-.15.706.953.953 0 01-.213.335.71.71 0 00-.088-.042c-.104-.045-.198-.064-.284-.133a1.312 1.312 0 00-.22-.066c.05-.06.146-.133.183-.198.053-.128.082-.264.088-.402v-.02a1.21 1.21 0 00-.061-.4c-.045-.134-.101-.2-.183-.333-.084-.066-.167-.132-.267-.132h-.016c-.093 0-.176.03-.262.132a.8.8 0 00-.205.334 1.18 1.18 0 00-.09.4v.019c.002.089.008.179.02.267-.193-.067-.438-.135-.607-.202a1.635 1.635 0 01-.018-.2v-.02a1.772 1.772 0 01.15-.768c.082-.22.232-.406.43-.533a.985.985 0 01.594-.2zm-2.962.059h.036c.142 0 .27.048.399.135.146.129.264.288.344.465.09.199.14.4.153.667v.004c.007.134.006.2-.002.266v.08c-.03.007-.056.018-.083.024-.152.055-.274.135-.393.2.012-.09.013-.18.003-.267v-.015c-.012-.133-.04-.2-.082-.333a.613.613 0 00-.166-.267.248.248 0 00-.183-.064h-.021c-.071.006-.13.04-.186.132a.552.552 0 00-.12.27.944.944 0 00-.023.33v.015c.012.135.037.2.08.334.046.134.098.2.166.268.01.009.02.018.034.024-.07.057-.117.07-.176.136a.304.304 0 01-.131.068 2.62 2.62 0 01-.275-.402 1.772 1.772 0 01-.155-.667 1.759 1.759 0 01.08-.668 1.43 1.43 0 01.283-.535c.128-.133.26-.2.418-.2zm1.37 1.706c.332 0 .733.065 1.216.399.293.2.523.269 1.052.468h.003c.255.136.405.266.478.399v-.131a.571.571 0 01.016.47c-.123.31-.516.643-1.063.842v.002c-.268.135-.501.333-.775.465-.276.135-.588.292-1.012.267a1.139 1.139 0 01-.448-.067 3.566 3.566 0 01-.322-.198c-.195-.135-.363-.332-.612-.465v-.005h-.005c-.4-.246-.616-.512-.686-.71-.07-.268-.005-.47.193-.6.224-.135.38-.271.483-.336.104-.074.143-.102.176-.131h.002v-.003c.169-.202.436-.47.839-.601.139-.036.294-.065.466-.065zm2.8 2.142c.358 1.417 1.196 3.475 1.735 4.473.286.534.855 1.659 1.102 3.024.156-.005.33.018.513.064.646-1.671-.546-3.467-1.089-3.966-.22-.2-.232-.335-.123-.335.59.534 1.365 1.572 1.646 2.757.13.535.16 1.104.021 1.67.067.028.135.06.205.067 1.032.534 1.413.938 1.23 1.537v-.043c-.06-.003-.12 0-.18 0h-.016c.151-.467-.182-.825-1.065-1.224-.915-.4-1.646-.336-1.77.465-.008.043-.013.066-.018.135-.068.023-.139.053-.209.064-.43.268-.662.669-.793 1.187-.13.533-.17 1.156-.205 1.869v.003c-.02.334-.17.838-.319 1.35-1.5 1.072-3.58 1.538-5.348.334a2.645 2.645 0 00-.402-.533 1.45 1.45 0 00-.275-.333c.182 0 .338-.03.465-.067a.615.615 0 00.314-.334c.108-.267 0-.697-.345-1.163-.345-.467-.931-.995-1.788-1.521-.63-.4-.986-.87-1.15-1.396-.165-.534-.143-1.085-.015-1.645.245-1.07.873-2.11 1.274-2.763.107-.065.037.135-.408.974-.396.751-1.14 2.497-.122 3.854a8.123 8.123 0 01.647-2.876c.564-1.278 1.743-3.504 1.836-5.268.048.036.217.135.289.202.218.133.38.333.59.465.21.201.477.335.876.335.039.003.075.006.11.006.412 0 .73-.134.997-.268.29-.134.52-.334.74-.4h.005c.467-.135.835-.402 1.044-.7zm2.185 8.958c.037.6.343 1.245.882 1.377.588.134 1.434-.333 1.791-.765l.211-.01c.315-.007.577.01.847.268l.003.003c.208.199.305.53.391.876.085.4.154.78.409 1.066.486.527.645.906.636 1.14l.003-.007v.018l-.003-.012c-.015.262-.185.396-.498.595-.63.401-1.746.712-2.457 1.57-.618.737-1.37 1.14-2.036 1.191-.664.053-1.237-.2-1.574-.898l-.005-.003c-.21-.4-.12-1.025.056-1.69.176-.668.428-1.344.463-1.897.037-.714.076-1.335.195-1.814.12-.465.308-.797.641-.984l.045-.022zm-10.814.049h.01c.053 0 .105.005.157.014.376.055.706.333 1.023.752l.91 1.664.003.003c.243.533.754 1.064 1.189 1.637.434.598.77 1.131.729 1.57v.006c-.057.744-.48 1.148-1.125 1.294-.645.135-1.52.002-2.395-.464-.968-.536-2.118-.469-2.857-.602-.369-.066-.61-.2-.723-.4-.11-.2-.113-.602.123-1.23v-.004l.002-.003c.117-.334.03-.752-.027-1.118-.055-.401-.083-.71.043-.94.16-.334.396-.4.69-.533.294-.135.64-.202.915-.47h.002v-.002c.256-.268.445-.601.668-.838.19-.201.38-.336.663-.336zm7.159-9.074c-.435.201-.945.535-1.488.535-.542 0-.97-.267-1.28-.466-.154-.134-.28-.268-.373-.335-.164-.134-.144-.333-.074-.333.109.016.129.134.199.2.096.066.215.2.36.333.292.2.68.467 1.167.467.485 0 1.053-.267 1.398-.466.195-.135.445-.334.648-.467.156-.136.149-.267.279-.267.128.016.034.134-.147.332a8.097 8.097 0 01-.69.468zm-1.082-1.583V5.64c-.006-.02.013-.042.029-.05.074-.043.18-.027.26.004.063 0 .16.067.15.135-.006.049-.085.066-.135.066-.055 0-.092-.043-.141-.068-.052-.018-.146-.008-.163-.065zm-.551 0c-.02.058-.113.049-.166.066-.047.025-.086.068-.14.068-.05 0-.13-.02-.136-.068-.01-.066.088-.133.15-.133.08-.031.184-.047.259-.005.019.009.036.03.03.05v.02h.003z"/></svg>'
ZEICHEN_APPLE = _Z + '<path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.04 3.517-.52 8.75 1.47 11.594.98 1.404 2.13 2.965 3.69 2.913 1.47-.052 2.03-.962 3.81-.962 1.77 0 2.28.962 3.83.936 1.6-.026 2.62-1.443 3.6-2.847 1.14-1.612 1.61-3.171 1.64-3.249-.03-.013-3.15-1.209-3.18-4.8-.026-3.003 2.45-4.442 2.56-4.512-1.4-2.055-3.57-2.29-4.33-2.343-1.95-.156-3.6 1.067-4.52 1.067zm3.09-3.093c.84-1.014 1.4-2.418 1.25-3.803-1.22.05-2.71.81-3.58 1.824-.78.897-1.47 2.338-1.29 3.71 1.36.106 2.77-.692 3.62-1.73"/></svg>'

# Reihenfolge ohne Skript. Mit Skript rueckt der Knopf fuers erkannte Geraet
# nach vorn und wird dadurch der helle (erstes Kind).
LADEN = [
    ("apple", APPLE_SEITE, ZEICHEN_APPLE, "App Store", "iPhone, iPad, Apple TV, Mac"),
    ("android", ANDROID, ZEICHEN_ANDROID, "Android", "Phone and Android TV, beta"),
    ("windows", WINDOWS, ZEICHEN_WINDOWS, "Windows", "Windows 10 and 11"),
    ("linux", LINUX, ZEICHEN_LINUX, "Linux", "apt, dnf, pacman"),
]


def extern(href):
    return ' target="_blank" rel="noopener"' if href.startswith("http") and not href.startswith(DOMAIN) else ""


def laden_kasten():
    knoepfe = "".join(
        f'<a class="laden" href="{e(href)}"{extern(href)} data-geraet="{g}">'
        f'<span class="laden__zeichen" aria-hidden="true">{z}</span><span><b>{t}</b><em>{u}</em></span></a>'
        for g, href, z, t, u in LADEN)
    return f"""<section class="leistenkasten" id="laden" aria-labelledby="laden-titel">
<p class="leistenkasten__marke" id="laden-titel"><img src="/symbol.svg" alt="" width="28" height="28">Swiftly Player</p>
<p class="leistenkasten__satz">A free player for your own Jellyfin server. Pause on the TV, keep watching on your phone.</p>
<div class="knoepfe" data-geraete>{knoepfe}</div>
<a class="alle-wege" href="/#downloads">All downloads</a>
</section>"""


def swiftly_kasten(inhalt):
    # Kurz: die Knoepfe stehen schon in der Seitenleiste (#laden).
    return f"""<aside class="swiftly" aria-label="Swiftly Player">
<p class="swiftly__marke"><img src="/symbol.svg" alt="" width="22" height="22">Swiftly Player</p>
{inhalt}
<p class="swiftly__weiter"><a href="#laden">Get Swiftly Player</a></p>
</aside>"""


STIL = """
@font-face { font-family: "Figtree"; font-style: normal; font-weight: 400 800; font-display: swap;
  src: url(/schrift/figtree-latin.woff2) format("woff2");
  unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD; }
@font-face { font-family: "Figtree"; font-style: normal; font-weight: 400 800; font-display: swap;
  src: url(/schrift/figtree-latin-ext.woff2) format("woff2");
  unicode-range: U+0100-02BA, U+02BD-02C5, U+02C7-02CC, U+02CE-02D7, U+02DD-02FF, U+0304, U+0308, U+0329, U+1D00-1DBF, U+1E00-1E9F, U+1EF2-1EFF, U+2020, U+20A0-20AB, U+20AD-20C0, U+2113, U+2C60-2C7F, U+A720-A7FF; }
/* Farben und Leiste wie index.html. Die Startseite kennt nur dunkel,
   also auch der Blog. */
:root {
  --grund: #0B0B0D; --tief: #08080A; --flaeche: #161619; --erhoeht: #1E1E22;
  --akzent: #5CD1C2; --kuehl: #7E9BFF; --warm: #E8833A; --marke: #2FDBC0;
  --schrift: #FFFFFF; --leise: rgba(255,255,255,.64); --sehr-leise: rgba(255,255,255,.40);
  --linie: rgba(255,255,255,.07); --rand: rgba(255,255,255,.13);
  --schriftart: "Figtree", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --bahn: 1280px; --lesen: 820px; --leiste: 312px; --seitenrand: clamp(24px, 4vw, 40px);
  --raus: cubic-bezier(.23, 1, .32, 1);
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; scrollbar-color: #2f2f33 var(--grund); }
@media (prefers-reduced-motion: reduce) { html { scroll-behavior: auto; } }
body { margin: 0; background: var(--grund); color: var(--schrift); font-family: var(--schriftart);
  font-size: 18px; line-height: 1.45; -webkit-font-smoothing: antialiased; }
img { max-width: 100%; height: auto; }
a { color: inherit; text-decoration: none; }
p { margin: 0; }
::selection { background: rgba(92,209,194,.32); color: var(--schrift); }
:focus-visible { outline: 2px solid var(--akzent); outline-offset: 3px; border-radius: 4px; }
.nur-fuer-leser { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
.bahn { width: 100%; max-width: calc(var(--bahn) + 2 * var(--seitenrand)); margin-inline: auto; padding-inline: var(--seitenrand); }

/* Leiste */
.leiste { position: absolute; top: 10px; left: 0; right: 0; z-index: 60; display: flex; justify-content: center;
  padding-inline: var(--seitenrand); pointer-events: none; }
.leiste__kapsel { pointer-events: auto; display: flex; align-items: center; gap: 10px; padding: 6px 6px 6px 24px;
  border-radius: 999px; border: 1px solid var(--rand); background: rgba(22,22,25,.72);
  backdrop-filter: blur(20px) saturate(160%); -webkit-backdrop-filter: blur(20px) saturate(160%);
  box-shadow: 0 12px 30px rgba(0,0,0,.45); }
.leiste__marke { display: flex; align-items: center; min-height: 44px; margin-right: 6px; }
.leiste__marke img { height: 21px; width: auto; }
.leiste__punkt { padding: 10px 18px; border-radius: 999px; font-size: 14.5px; font-weight: 500; color: var(--leise);
  transition: color 160ms var(--raus), background-color 160ms var(--raus); }
.leiste__punkt[aria-current] { color: var(--schrift); }
.knopf { display: inline-flex; align-items: center; justify-content: center; border: 0; border-radius: 999px;
  background: var(--schrift); color: var(--grund); font-family: inherit; font-weight: 600; line-height: 1.2;
  cursor: pointer; transition: transform 160ms var(--raus), background-color 160ms var(--raus); }
.knopf--leiste { padding: 11px 22px; font-size: 14.5px; }
.knopf--gross { padding: 17px 30px; font-size: 16.5px; }
.knopf--leise { padding: 10px 21px; font-size: 14.5px; background: transparent; color: var(--schrift);
  box-shadow: inset 0 0 0 1px var(--rand); }
.leiste__burger { display: none; }
.menue { display: none; position: fixed; z-index: 55; left: 20px; right: 20px; top: 12px; padding: 78px 0 22px;
  border-radius: 30px; border: 1px solid var(--rand); background: rgba(22,22,25,.92);
  backdrop-filter: blur(24px) saturate(160%); -webkit-backdrop-filter: blur(24px) saturate(160%);
  box-shadow: 0 12px 30px rgba(0,0,0,.5); transform-origin: top center; opacity: 0;
  transform: scaleY(.86) translateY(-10px); pointer-events: none;
  transition: opacity 220ms var(--raus), transform 320ms var(--raus); }
.menue[data-offen] { opacity: 1; transform: none; pointer-events: auto; }
.menue a { display: block; padding: 15px 20px; color: var(--leise); font-size: 19px; font-weight: 500; }
.menue a[aria-current] { color: var(--schrift); }
.menue .knopf { display: flex; width: calc(100% - 40px); margin: 14px 20px 0; color: var(--grund); }

/* Kopf der Seite. Licht wie die Aurora der Startseite, schwaecher:
   hier soll gelesen werden. Liegt unter dem Text (DESIGN.md 2). */
main { position: relative; padding: 140px 0 110px; }
.schein { position: absolute; left: 0; right: 0; top: -10px; height: 560px; z-index: 0; pointer-events: none; opacity: .55;
  background:
    radial-gradient(ellipse 30% 46% at 50.7% 30%, rgba(92,209,194,.40), rgba(92,209,194,.16) 62%, rgba(92,209,194,0) 100%),
    radial-gradient(ellipse 26% 42% at 27% 40%, rgba(126,155,255,.34), rgba(126,155,255,.13) 62%, rgba(126,155,255,0) 100%),
    radial-gradient(ellipse 28% 42% at 80% 38%, rgba(232,131,58,.28), rgba(232,131,58,.11) 62%, rgba(232,131,58,0) 100%); }
main > :not(.schein) { position: relative; z-index: 6; }
.pfad { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 0 0 22px; padding: 0; list-style: none;
  font-size: 14.5px; color: var(--sehr-leise); }
.pfad a { color: var(--leise); transition: color 160ms var(--raus); }
.pfad li + li::before { content: "/"; margin-right: 8px; color: var(--sehr-leise); }
.seitenkopf h1 { font-size: clamp(36px, 4.4vw, 60px); font-weight: 600; line-height: 1.04; letter-spacing: -.03em;
  margin: 0; text-wrap: balance; }
.seitenkopf .unter { margin-top: 18px; color: var(--leise); font-size: clamp(17px, 1.4vw, 20px); line-height: 1.5; text-wrap: pretty; }
.seitenkopf--mitte { text-align: center; }
.seitenkopf--mitte .pfad { justify-content: center; }
.seitenkopf--mitte h1 { font-size: clamp(38px, 5.55vw, 80px); line-height: 1.02; }
.seitenkopf--mitte .unter { max-width: 620px; margin-inline: auto; text-wrap: balance; }
.angaben { margin-top: 22px; color: var(--sehr-leise); font-size: 14.5px; }
.angaben span + span::before { content: "·"; margin: 0 8px; }
.geplant { display: inline-block; margin: 0 0 18px; padding: 6px 14px; border-radius: 999px; font-size: 13px;
  font-weight: 600; color: var(--warm); background: color-mix(in srgb, var(--warm) 10%, var(--flaeche));
  box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--warm) 30%, transparent); }

/* Artikel */
.artikel .seitenkopf h1 { font-size: clamp(34px, 3.7vw, 52px); line-height: 1.06; }
.artikel .seitenkopf .unter { font-size: clamp(17px, 1.3vw, 19px); }
.titelbild { margin: 34px 0 0; border-radius: 24px; overflow: hidden; border: 1px solid var(--linie); background: var(--tief); }
.titelbild img { display: block; width: 100%; height: auto; }
.offenlegung { margin: 30px 0 0; padding: 2px 0 2px 16px; border-left: 2px solid var(--rand);
  color: var(--leise); font-size: 15px; line-height: 1.55; }
.offenlegung strong { color: var(--schrift); font-weight: 600; }
.text { margin-top: 40px; font-size: 18px; line-height: 1.7; color: var(--leise); }
.text > * + * { margin-top: 20px; }
.text h2 { margin-top: 64px; font-size: clamp(26px, 2.6vw, 34px); font-weight: 600; line-height: 1.1;
  letter-spacing: -.03em; color: var(--schrift); scroll-margin-top: 90px; }
.text h3 { margin-top: 38px; font-size: clamp(20px, 1.8vw, 23px); font-weight: 600; line-height: 1.2; letter-spacing: -.02em;
  color: var(--schrift); scroll-margin-top: 90px; }
.text h4 { margin-top: 28px; font-size: 18px; font-weight: 600; letter-spacing: -.014em; color: var(--schrift); }
.text h2 + *, .text h3 + *, .text h4 + * { margin-top: 14px; }
.text strong { color: var(--schrift); font-weight: 600; }
.text a { color: var(--akzent); text-decoration: underline; text-decoration-color: rgba(92,209,194,.35);
  text-underline-offset: 3px; transition: text-decoration-color 160ms var(--raus); }
.text ul, .text ol { padding-left: 1.3em; }
.text li + li { margin-top: 8px; }
.text li > * + * { margin-top: 10px; }
.text li::marker { color: var(--sehr-leise); }
.text code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: .86em;
  padding: .12em .4em; border-radius: 6px; background: var(--erhoeht); color: var(--schrift); }
.text pre { margin-top: 24px; padding: 20px 22px; overflow-x: auto; border-radius: 18px; background: var(--tief);
  border: 1px solid var(--linie); font-size: 15px; line-height: 1.55; }
.text pre code { padding: 0; background: none; font-size: inherit; }
/* Kopieren-Knopf im Codekasten. Er sitzt oben rechts, bestaetigt sichtbar
   ("Copied") und verschwindet ohne Skript, weil ihn erst das Skript setzt. */
.codeblock { position: relative; }
.codeblock pre { margin-top: 24px; }
.kopieren { position: absolute; top: 34px; right: 12px; display: inline-flex; align-items: center; gap: 6px;
  min-height: 36px; padding: 8px 14px; border: 0; border-radius: 999px; box-shadow: inset 0 0 0 1px var(--rand);
  background: var(--erhoeht); color: var(--leise); font-family: inherit; font-size: 13.5px; font-weight: 600;
  line-height: 1; cursor: pointer; transition: color 160ms var(--raus), box-shadow 160ms var(--raus); }
.kopieren[data-kopiert] { color: var(--akzent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 45%, transparent); }
.kopieren svg { width: 13px; height: 13px; }
.befehlszeile { margin-top: 10px; color: var(--sehr-leise); font-size: 14.5px; line-height: 1.5; }
@media (max-width: 700px) {
  /* Mobil steht der Knopf unter dem Befehl: nebenan verdeckt er ihn. */
  .kopieren { position: static; margin-top: 10px; min-height: 44px; width: 100%; justify-content: center; }
}
.text blockquote { margin-inline: 0; padding-left: 20px; border-left: 2px solid var(--rand); }
.text blockquote > * + * { margin-top: 12px; }
.text hr { border: 0; height: 1px; background: var(--linie); margin-block: 48px; }
.text figure { margin: 34px 0 0; }
.text figure + * { margin-top: 30px; }
.text .abbildung { display: block; margin-inline: auto; max-width: 100%; height: auto; border-radius: 18px; }
.text .abbildung.hoch { max-height: 620px; width: auto; }
.text figcaption { margin-top: 12px; text-align: center; font-size: 14px; line-height: 1.5; color: var(--sehr-leise); text-wrap: balance; }
.text figcaption .quelle { white-space: nowrap; }
.text figcaption .quelle::before { content: "· "; }
.tabelle { margin-top: 28px; overflow-x: auto; border-radius: 18px; background: var(--flaeche); border: 1px solid var(--linie); }
.tabelle table { width: 100%; border-collapse: collapse; font-size: 15px; line-height: 1.45; }
.tabelle th, .tabelle td { padding: 14px 18px; text-align: left; vertical-align: top; }
.tabelle th { color: var(--sehr-leise); font-size: 12px; font-weight: 600; letter-spacing: .13em; text-transform: uppercase;
  white-space: nowrap; border-bottom: 1px solid var(--linie); }
.tabelle td:first-child { color: var(--schrift); font-weight: 600; }
.tabelle tbody tr + tr td { border-top: 1px solid var(--linie); }

/* TL;DR: ein Blatt, Ueberschrift klein wie die Spaltenkoepfe im Fuss */
.kurz { margin-top: 36px; padding: 26px 30px; border-radius: 32px; background: var(--flaeche); border: 1px solid var(--linie); }
.text .kurz h2 { margin: 0; font-size: 12px; line-height: 1.3; letter-spacing: .13em; text-transform: uppercase; color: var(--akzent); }
.text .kurz > * + * { margin-top: 12px; }
.text .kurz h2 + * { margin-top: 14px; }

/* FAQ: wie "Common questions" auf der Startseite, als details, damit es ohne
   Skript geht (DESIGN.md 9). Die erste Antwort steht offen. */
.fragen__blatt { margin-top: 28px; border-radius: 32px; background: var(--flaeche); border: 1px solid var(--linie); overflow: hidden; }
.frage + .frage { border-top: 1px solid var(--linie); }
.frage__knopf { display: flex; align-items: center; justify-content: space-between; gap: 20px; padding: 24px 32px;
  cursor: pointer; list-style: none; transition: background-color 160ms var(--raus); }
.frage__knopf::-webkit-details-marker { display: none; }
.text .frage__knopf h3 { margin: 0; font-size: clamp(16px, 1.4vw, 19px); line-height: 1.3; letter-spacing: -.014em; }
.frage__pfeil { flex: none; width: 20px; height: 20px; color: var(--sehr-leise); transition: transform 280ms var(--raus), color 160ms var(--raus); }
.frage[open] .frage__pfeil { transform: rotate(90deg); color: var(--leise); }
.frage__antwort { padding: 0 32px 27px; font-size: clamp(15px, 1.2vw, 16.5px); line-height: 1.55; }
.frage__antwort > * + * { margin-top: 12px; }

/* :::swiftly im Text: kurz, die Knoepfe stehen in der Seitenleiste */
.swiftly { position: relative; margin-top: 40px; padding: 22px 26px 24px; border-radius: 24px; overflow: hidden;
  background: radial-gradient(ellipse 70% 90% at 0% 0%, rgba(92,209,194,.12), rgba(92,209,194,0) 70%), var(--flaeche);
  border: 1px solid var(--linie); color: var(--leise); }
.text .swiftly > * + * { margin-top: 10px; }
.swiftly__marke { display: flex; align-items: center; gap: 10px; font-size: 12px; font-weight: 600; letter-spacing: .13em;
  text-transform: uppercase; color: var(--schrift); }
.swiftly__marke img { width: 22px; height: 22px; }
.text .swiftly__weiter a { font-weight: 600; }

/* Raster Artikel + Seitenleiste */
.artikelbahn { width: 100%; max-width: calc(var(--bahn) + 2 * var(--seitenrand)); margin-inline: auto; padding-inline: var(--seitenrand);
  display: grid; grid-template-columns: minmax(0, var(--lesen)) var(--leiste); justify-content: center;
  column-gap: clamp(36px, 3.5vw, 60px); align-items: start; }
.seitenleiste { display: flex; flex-direction: column; gap: 30px; padding-top: 40px; align-self: stretch; }
.seitenleiste__klebt { position: sticky; top: 24px; display: flex; flex-direction: column; gap: 30px;
  max-height: calc(100vh - 48px); overflow-y: auto; overscroll-behavior: contain; scrollbar-width: none; }
.leistenblock h2 { margin: 0 0 12px; font-size: 12px; font-weight: 600; line-height: 1.3; letter-spacing: .13em;
  text-transform: uppercase; color: var(--sehr-leise); }
.inhaltsliste { margin: 0; padding: 0; list-style: none; border-left: 1px solid var(--linie); }
.inhaltsliste a { display: block; margin-left: -1px; padding: 6px 0 6px 15px; border-left: 1px solid transparent;
  font-size: 14.5px; line-height: 1.35; color: var(--leise); transition: color 160ms var(--raus), border-color 160ms var(--raus); }
.leistenkasten { padding: 22px 20px 20px; border-radius: 24px; border: 1px solid var(--linie);
  background: radial-gradient(ellipse 80% 70% at 0% 0%, rgba(92,209,194,.13), rgba(92,209,194,0) 70%), var(--flaeche); }
.leistenkasten__marke { display: flex; align-items: center; gap: 10px; font-size: 17px; font-weight: 600; letter-spacing: -.014em; }
.leistenkasten__marke img { width: 28px; height: 28px; }
.leistenkasten__satz { margin-top: 10px; font-size: 14.5px; line-height: 1.5; color: var(--leise); }
.knoepfe { display: grid; gap: 8px; margin-top: 18px; }
.knoepfe > :nth-child(2) { --farbe: var(--akzent); }
.knoepfe > :nth-child(3) { --farbe: var(--kuehl); }
.knoepfe > :nth-child(4) { --farbe: var(--warm); }
/* Alle vier Wege sind gleich gebaut: ruhige Flaeche, ein Ring im Akzent,
   das Logo einfarbig in einem Kreis ohne Kontur, Kreis zu Zeichen 2 zu 1.
   Der erste (der zum Geraet passende) ist eine Stufe betonter, nicht
   weiss gefuellt: eine vollflaechig weisse Kapsel war neben dem ruhigen
   Rest zu schwer (Paul, 17.09.). Ein Akzent fuer alle, nicht vier Farben. */
.laden { display: flex; align-items: center; gap: 12px; min-height: 54px; padding: 8px 16px 8px 10px; border-radius: 999px;
  line-height: 1.25; color: var(--schrift); background: color-mix(in srgb, var(--akzent) 8%, var(--erhoeht));
  box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 24%, transparent); }
.laden__zeichen { flex: none; width: 30px; height: 30px; display: grid; place-items: center; border-radius: 50%;
  background: rgba(255,255,255,.06); color: var(--schrift); }
.laden__zeichen svg { width: 15px; height: 15px; }
.laden b { display: block; font-size: 15px; font-weight: 600; letter-spacing: -.014em; }
.laden em { display: block; font-size: 12.5px; font-style: normal; color: var(--leise); }
.knoepfe > :first-child { background: color-mix(in srgb, var(--akzent) 14%, var(--flaeche));
  box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 38%, transparent); }
.knoepfe > :first-child .laden__zeichen { background: color-mix(in srgb, var(--akzent) 20%, transparent); color: var(--akzent); }
.alle-wege { display: inline-block; margin: 14px 0 0 10px; font-size: 14.5px; font-weight: 600; color: var(--akzent); }
.verwandtliste { display: grid; gap: 14px; margin: 0; padding: 0; list-style: none; }
.weiterlesen { margin-top: 64px; padding-top: 40px; border-top: 1px solid var(--linie); }
.weiterlesen h2 { margin: 0 0 22px; font-size: 22px; font-weight: 600; letter-spacing: -.014em; }
.verwandtliste--unten { grid-template-columns: repeat(3, minmax(0,1fr)); gap: 20px; }
.verwandtliste--unten .verwandt { grid-template-columns: 1fr; gap: 10px; align-items: start; }
.verwandtliste--unten .verwandt img { width: 100%; height: auto; border-radius: 16px; }
@media (max-width: 700px) { .verwandtliste--unten { grid-template-columns: 1fr; } }
.verwandt { display: grid; grid-template-columns: 92px minmax(0,1fr); gap: 14px; align-items: center; }
.verwandt img { width: 92px; height: auto; border-radius: 10px; border: 1px solid var(--linie); }
.verwandt b { display: block; font-size: 14.5px; font-weight: 600; line-height: 1.3; letter-spacing: -.01em;
  transition: color 160ms var(--raus); }
.verwandt time { display: block; margin-top: 4px; font-size: 12.5px; color: var(--sehr-leise); }

/* Uebersicht */
.karten { display: grid; gap: 20px; margin: 0; padding: 0; list-style: none; }
.karten--raster { grid-template-columns: repeat(3, minmax(0,1fr)); margin-top: 60px; }
.karte { display: flex; flex-direction: column; height: 100%; border-radius: 28px; overflow: hidden;
  background: var(--flaeche); border: 1px solid var(--linie);
  transition: transform 200ms var(--raus), box-shadow 200ms var(--raus), border-color 200ms var(--raus); }
.karte__bild { display: block; background: var(--tief); border-bottom: 1px solid var(--linie); }
.karte__bild img { display: block; width: 100%; height: auto; }
.karte__rumpf { display: flex; flex-direction: column; flex: 1; padding: 20px 24px 24px; }
.karte__kopf { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; font-size: 13.5px; color: var(--sehr-leise); }
.karte__kopf > span:first-child { color: var(--akzent); font-weight: 600; }
.karte__kopf .geplant { margin: 0; padding: 3px 10px; font-size: 12px; }
.karte h2, .karte h3 { margin: 10px 0 0; font-size: clamp(19px, 1.5vw, 22px); font-weight: 600; line-height: 1.22; letter-spacing: -.02em; }
.karte p { margin-top: 10px; font-size: 15px; line-height: 1.55; color: var(--leise); }
.karte__weiter { margin-top: auto; padding-top: 18px; font-size: 14.5px; font-weight: 600; color: var(--akzent); }
.leer { margin-top: 60px; text-align: center; color: var(--leise); }
.mitte { text-align: center; }
.zurueck { display: inline-flex; align-items: center; gap: 9px; margin-top: 56px; padding: 9px 16px 9px 13px;
  border: 1px solid var(--linie); border-radius: 999px; color: var(--leise); font-size: 15px;
  transition: color 160ms var(--raus), border-color 160ms var(--raus); }
.zurueck svg { width: 14px; height: 14px; }

/* Fuss wie index.html */
.fuss { padding-block: 0 43px; }
.fuss__linie { height: 1px; background: var(--linie); }
.fuss__raster { display: grid; grid-template-columns: minmax(0,440px) minmax(0,280px) minmax(0,280px) minmax(0,240px);
  row-gap: 40px; padding-block: 64px 73px; }
.fuss__raster--fuenf { grid-template-columns: minmax(0,360px) repeat(4, minmax(0,230px)); }
.fuss__marke { max-width: 360px; }
.fuss__marke img { height: 21px; width: auto; }
.fuss__marke p { margin-top: 14px; color: var(--leise); font-size: 15px; line-height: 1.55; }
.fuss__spalte h2 { margin: 0; font-size: 12px; font-weight: 600; line-height: 1.3; letter-spacing: .13em;
  color: var(--sehr-leise); text-transform: uppercase; }
.fuss__spalte ul { margin: 16px 0 0; padding: 0; list-style: none; font-size: 15px; line-height: 1.4; }
.fuss__spalte li + li { margin-top: 11px; }
.fuss__spalte a { color: var(--leise); transition: color 160ms var(--raus); }
.fuss__klein { padding-top: 28px; max-width: 880px; color: var(--sehr-leise); font-size: 13px; line-height: 1.6; }

@media (hover: hover) and (pointer: fine) {
  .leiste__punkt:hover { color: var(--schrift); background: rgba(255,255,255,.06); }
  .knopf--leise:hover { background: rgba(255,255,255,.06); }
  .fuss__spalte a:hover, .pfad a:hover, .zurueck:hover { color: var(--schrift); }
  .text a:hover { text-decoration-color: currentColor; }
  .frage__knopf:hover { background: rgba(255,255,255,.03); }
  .inhaltsliste a:hover { color: var(--schrift); border-left-color: var(--akzent); }
  .verwandt:hover b, .alle-wege:hover { color: var(--schrift); }
}
@media (prefers-reduced-motion: reduce) {
  .knopf, .menue, .karte, .laden { transition-property: opacity, color, background-color, border-color, box-shadow; }
  .menue { transform: none; }
  .frage__pfeil { transition: none; }
}

@media (max-width: 1100px) {
  .karten--raster { grid-template-columns: repeat(2, minmax(0,1fr)); }
  .fuss__raster--fuenf { grid-template-columns: 1fr 1fr 1fr; }
}
@media (max-width: 1000px) {
  .artikelbahn { grid-template-columns: minmax(0,1fr); max-width: calc(var(--lesen) + 2 * var(--seitenrand)); }
  .seitenleiste { padding-top: 64px; }
  .seitenleiste__klebt { position: static; }
  .leistenblock--inhalt { display: none; }
}
@media (max-width: 900px) {
  .leiste { position: fixed; top: 12px; padding-inline: 20px; }
  .leiste__kapsel { width: 100%; justify-content: space-between; padding: 8px 8px 8px 20px; }
  .leiste__punkt, .knopf--leiste.nur-desktop { display: none; }
  .leiste__burger { display: grid; align-content: center; justify-items: start; width: 44px; height: 44px;
    border: 0; padding: 0 0 0 12px; background: none; cursor: pointer; }
  .leiste__burger span { display: block; width: 20px; height: 2px; border-radius: 1px; background: var(--schrift);
    transform-origin: left center; transition: transform 280ms var(--raus), opacity 180ms var(--raus); }
  .leiste__burger span + span { margin-top: 5px; }
  .leiste__burger span:nth-child(3) { transform: scaleX(.65); }
  .leiste__burger[aria-expanded="true"] span:nth-child(1) { transform: translateY(7px) rotate(45deg); }
  .leiste__burger[aria-expanded="true"] span:nth-child(2) { opacity: 0; }
  .leiste__burger[aria-expanded="true"] span:nth-child(3) { transform: translateY(-7px) rotate(-45deg); }
  .menue { display: block; }
  main { padding: 112px 0 84px; }
  .schein { top: 38px; height: 420px; }
  .seitenkopf h1 { font-size: 36px; line-height: 1.06; }
  .seitenkopf--mitte h1 { font-size: 46px; line-height: 1; }
  .seitenkopf .unter { font-size: 17px; }
  .text { margin-top: 36px; font-size: 17px; line-height: 1.65; }
  .text h2 { margin-top: 52px; font-size: 27px; line-height: 1.1; }
  .text h3 { font-size: 20px; }
  .text pre { font-size: 14px; }
  .tabelle table { font-size: 14px; }
  .tabelle th, .tabelle td { padding: 11px 14px; }
  .kurz { padding: 22px; border-radius: 24px; }
  .fragen__blatt { border-radius: 24px; }
  .frage__knopf { padding: 18px; }
  .text .frage__knopf h3 { font-size: 15.5px; }
  .frage__antwort { padding: 0 18px 20px; font-size: 16px; }
  .swiftly { padding: 20px 20px 20px; }
  .titelbild { margin-top: 26px; border-radius: 18px; }
  .artikel .seitenkopf h1 { font-size: 34px; }
  .karte { border-radius: 24px; }
  .fuss__raster, .fuss__raster--fuenf { grid-template-columns: 1fr 1fr; padding-block: 48px 40px; }
  .fuss__marke { grid-column: 1 / -1; }
  .fuss__spalte:last-child { grid-column: 1 / -1; }
  .fuss__klein { font-size: 11.5px; padding-top: 20px; }
  .fuss { padding-bottom: 18px; }
}
@media (max-width: 700px) {
  .karten--raster { grid-template-columns: 1fr; margin-top: 40px; }
}

/* =====================================================================
   Verhalten, 17.09. Paul: "Jeder Knopf hat eine andere Animation ...
   such dir die beste aus und mach bei allen dieselbe."

   Vorbild ist die ruhigste der vorhandenen Varianten, der Kartenhover:
   zwei Pixel anheben, ein Schatten dahinter, fertig. Raus sind der harte
   Sprung auf 104,5 Prozent am Download-Knopf, die Welle nach aussen und
   das Huepfen per Skript. Eine Flaeche, die beim Zeigen groesser wird,
   verrueckt den Text darin, und drei Varianten nebeneinander sehen nach
   Zufall aus statt nach System.

   Alles steht in Variablen: eine Dauer, eine Kurve, eine Hebung, ein
   Druck, eine Aufhellung, ein Fokusring. Keine Komponente erfindet
   eigene Werte. Zwei Staerken, weil eine Zeile im Fuss sich nicht wie
   ein Knopf anheben darf: Flaechen heben sich, Zeilen hellen auf.
   ===================================================================== */
:root {
  --dauer: 170ms;
  --kurve: cubic-bezier(.23, 1, .32, 1);
  --hebung: -2px;
  --druck: .985;
  --aufhellen: rgba(255,255,255,.06);
  --schatten-hoch: 0 12px 26px rgba(0,0,0,.45);
}
.knopf, .weg-gross, .weg-klein, .karte, .kopieren, .laden, .weg,
.reiter button, .frage__knopf, .mitmachen__liste a, .leiste__punkt, .leiste__marke,
.menue a, .fuss__spalte a, .pfad a, .zurueck, .alle-wege, .text a, .frage__link,
.schritt .knopf, .hilfe .knopf, .download .knopf {
  transition: transform var(--dauer) var(--kurve), background-color var(--dauer) var(--kurve),
              box-shadow var(--dauer) var(--kurve), color var(--dauer) var(--kurve),
              border-color var(--dauer) var(--kurve), text-decoration-color var(--dauer) var(--kurve);
}
@media (hover: hover) and (pointer: fine) {
  /* Flaechen: anheben. */
  .knopf:hover, .weg-gross:hover, .karte:hover, .kopieren:hover, .laden:hover, .weg:hover,
  .schritt .knopf:hover, .hilfe .knopf:hover, .download .knopf:hover {
    transform: translateY(var(--hebung));
    box-shadow: var(--schatten-hoch);
  }
  .weg-klein:hover {
    transform: translateY(var(--hebung));
    box-shadow: inset 0 0 0 1px var(--rand), var(--schatten-hoch);
  }
  /* Der Hauptweg behaelt seinen Akzentring, sonst blinkt er beim Zeigen weg. */
  .weg-gross:hover, .knoepfe > :first-child:hover {
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 55%, transparent), var(--schatten-hoch);
  }
  .laden:hover { box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 40%, transparent), var(--schatten-hoch); }
  .karte:hover { border-color: var(--rand); }
  .kopieren:hover { color: var(--schrift); box-shadow: inset 0 0 0 1px var(--rand), var(--schatten-hoch); }
  /* Zeilen und Verweise: aufhellen. */
  .reiter button:hover, .frage__knopf:hover, .mitmachen__liste a:hover, .leiste__punkt:hover {
    background: var(--aufhellen);
    color: var(--schrift);
  }
  .menue a:hover, .fuss__spalte a:hover, .pfad a:hover, .zurueck:hover, .alle-wege:hover { color: var(--schrift); }
  .text a:hover, .frage__link:hover, .hinweis a:hover, .abschnitt a:not(.knopf):hover,
  .frage__antwort a:hover { text-decoration-color: currentColor; }
}
/* Der Druck: ein Wert fuer jedes anfassbare Element. */
.knopf:active, .weg-gross:active, .weg-klein:active, .karte:active, .kopieren:active,
.reiter button:active, .laden:active, .weg:active { transform: scale(var(--druck)); }
.mitmachen__liste a:active, .frage__knopf:active { background: rgba(255,255,255,.09); }
/* Ein Fokusring fuer alles. */
:focus-visible { outline: 2px solid var(--akzent); outline-offset: 3px; border-radius: 6px; }
.knopf:focus-visible, .weg-gross:focus-visible, .weg-klein:focus-visible, .laden:focus-visible,
.weg:focus-visible, .reiter button:focus-visible, .kopieren:focus-visible { border-radius: inherit; }
@media (prefers-reduced-motion: reduce) {
  /* Weniger, nicht nichts: Farbe bleibt, Bewegung geht. */
  .knopf, .weg-gross, .weg-klein, .karte, .kopieren, .laden, .weg, .reiter button,
  .frage__knopf, .mitmachen__liste a, .leiste__punkt, .menue a, .fuss__spalte a, .pfad a, .text a {
    transition-property: color, background-color, box-shadow, border-color, text-decoration-color;
  }
  .knopf:hover, .weg-gross:hover, .weg-klein:hover, .karte:hover, .kopieren:hover, .laden:hover,
  .weg:hover, .knopf:active, .weg-gross:active, .weg-klein:active, .karte:active,
  .kopieren:active, .laden:active, .weg:active, .reiter button:active { transform: none; }
}
"""

SKRIPT = """(function () {
  var burger = document.querySelector(".leiste__burger");
  var menue = document.getElementById("menue");
  if (burger && menue) {
    var setzen = function (offen) {
      burger.setAttribute("aria-expanded", offen ? "true" : "false");
      if (offen) { menue.setAttribute("data-offen", ""); } else { menue.removeAttribute("data-offen"); }
    };
    burger.addEventListener("click", function () { setzen(burger.getAttribute("aria-expanded") !== "true"); });
    menue.addEventListener("click", function (e) { if (e.target.closest("a")) setzen(false); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") setzen(false); });
  }
  /* Kopieren-Knopf an jedem Codekasten, mit sichtbarer Bestaetigung. */
  document.querySelectorAll(".codeblock").forEach(function (kasten) {
    var code = kasten.querySelector("code");
    if (!code) return;
    var knopf = document.createElement("button");
    knopf.type = "button";
    knopf.className = "kopieren";
    var wort = document.createElement("span");
    wort.textContent = "Copy";
    knopf.appendChild(wort);
    var zurueck = 0;
    knopf.addEventListener("click", function () {
      var text = code.textContent;
      var fertig = function (gut) {
        wort.textContent = gut ? "Copied" : "Press Cmd C";
        if (gut) knopf.setAttribute("data-kopiert", "");
        clearTimeout(zurueck);
        zurueck = setTimeout(function () { wort.textContent = "Copy"; knopf.removeAttribute("data-kopiert"); }, 2000);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { fertig(true); }, function () { fertig(false); });
      } else {
        /* Aelterer Weg: markieren und execCommand. */
        var feld = document.createElement("textarea");
        feld.value = text;
        feld.setAttribute("readonly", "");
        feld.style.position = "absolute";
        feld.style.left = "-9999px";
        document.body.appendChild(feld);
        feld.select();
        var gut = false;
        try { gut = document.execCommand("copy"); } catch (e) { gut = false; }
        document.body.removeChild(feld);
        fertig(gut);
      }
    });
    kasten.appendChild(knopf);
  });
  /* Passenden Download zuerst. Ohne Skript bleibt die feste Reihenfolge. */
  var ua = navigator.userAgent || "", pf = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  var geraet = /Android/i.test(ua) ? "android" : /iPhone|iPad|iPod|Macintosh|Mac OS X/i.test(ua) ? "apple"
    : /Win/i.test(pf) || /Windows/i.test(ua) ? "windows" : /Linux|X11|CrOS/i.test(pf + ua) ? "linux" : "";
  if (!geraet) return;
  document.querySelectorAll("[data-geraete]").forEach(function (liste) {
    var knopf = liste.querySelector('[data-geraet="' + geraet + '"]');
    if (knopf && knopf !== liste.firstElementChild) liste.insertBefore(knopf, liste.firstElementChild);
  });
})();"""


def json_ld(daten):
    # "</" im JSON wuerde das Skript-Element schliessen.
    return ('<script type="application/ld+json">\n'
            + json.dumps(daten, ensure_ascii=False, indent=2).replace("</", "<\\/")
            + "\n</script>")


SEITEN = []          # Landingpages, von main() gefuellt; Fusszeile verlinkt sie


def fuss_seiten():
    if not SEITEN:
        return ""
    punkte = "".join(f'<li><a href="{a["pfad"]}">{e(a.get("kurzname") or a["titel"])}</a></li>' for a in SEITEN)
    return f"""
      <div class="fuss__spalte">
        <h2>Jellyfin clients</h2>
        <ul>{punkte}</ul>
      </div>"""


ORGANISATION = {"@type": "Organization", "name": HERAUSGEBER, "url": DOMAIN + "/",
                "logo": {"@type": "ImageObject", "url": DOMAIN + "/apple-touch-icon.png"}}


def seite(titel, beschreibung, url, inhalt, og_typ="website", zusatz_kopf="", ld=(), robots="",
          bild=None, bild_alt=None, blog_aktiv=True):
    bild_url = DOMAIN + bild if bild else DOMAIN + "/vorschau.jpg"
    bild_alt = bild_alt or "iPad, iPhone and an Apple TV, all showing Swiftly Player"
    aktuell = ' aria-current="page"' if blog_aktiv else ""
    kanonisch = f'<link rel="canonical" href="{e(url)}">\n' if url else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(titel)}</title>
<meta name="description" content="{e(beschreibung)}">
{robots}{kanonisch}<meta name="author" content="{HERAUSGEBER}">
<meta name="apple-itunes-app" content="app-id={APP_ID}">
<meta property="og:title" content="{e(titel)}">
<meta property="og:description" content="{e(beschreibung)}">
<meta property="og:url" content="{e(url or DOMAIN + '/blog/')}">
<meta property="og:type" content="{og_typ}">
<meta property="og:site_name" content="Swiftly Player">
<meta property="og:image" content="{e(bild_url)}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{e(bild_alt)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{e(titel)}">
<meta name="twitter:description" content="{e(beschreibung)}">
<meta name="twitter:image" content="{e(bild_url)}">
<meta name="theme-color" content="#0B0B0D">
{zusatz_kopf}<link rel="alternate" type="application/rss+xml" title="Swiftly Player blog" href="/blog/feed.xml">
<link rel="preload" as="font" type="font/woff2" href="/schrift/figtree-latin.woff2" crossorigin>
<link rel="icon" href="/symbol.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
{MARKER}
<style>{STIL}</style>
{chr(10).join(ld)}
</head>
<body>

<a class="nur-fuer-leser" href="#inhalt">Skip to content</a>

<header class="leiste">
  <div class="leiste__kapsel">
    <a class="leiste__marke" href="/" aria-label="Swiftly Player, home">
      <img src="/wortmarke.svg" alt="Swiftly" width="61" height="21">
    </a>
    <a class="leiste__punkt" href="/blog/"{aktuell}>Blog</a>
    <a class="leiste__punkt" href="{DISCORD}" target="_blank" rel="noopener">Discord</a>
    <a class="leiste__punkt" href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>
    <a class="knopf knopf--leiste nur-desktop" href="/#downloads">Download</a>
    <button class="leiste__burger" type="button" aria-expanded="false" aria-controls="menue" aria-label="Menu">
      <span></span><span></span><span></span>
    </button>
  </div>
</header>

<nav class="menue" id="menue" aria-label="Menu">
  <a href="/blog/"{aktuell}>Blog</a>
  <a href="{DISCORD}" target="_blank" rel="noopener">Discord</a>
  <a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>
  <a class="knopf knopf--gross" href="/#downloads">Download</a>
</nav>

<main id="inhalt">
{inhalt}
</main>

<footer class="fuss">
  <div class="bahn">
    <div class="fuss__linie"></div>
    <div class="fuss__raster{' fuss__raster--fuenf' if SEITEN else ''}">
      <div class="fuss__marke">
        <img src="/wortmarke.svg" alt="Swiftly" width="61" height="21">
        <p>A video player for your own Jellyfin server. Built by one person.</p>
      </div>
      <div class="fuss__spalte">
        <h2>Download</h2>
        <ul>
          <li><a href="{APPLE_SEITE}">App Store</a></li>
          <li><a href="{TESTFLIGHT_SEITE}">TestFlight</a></li>
          <li><a href="{ANDROID}">Android</a></li>
          <li><a href="{WINDOWS}">Windows</a></li>
          <li><a href="{LINUX}">Linux</a></li>
        </ul>
      </div>{fuss_seiten()}
      <div class="fuss__spalte">
        <h2>Elsewhere</h2>
        <ul>
          <li><a href="/blog/">Blog</a></li>
          <li><a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a></li>
          <li><a href="{DISCORD}" target="_blank" rel="noopener">Discord</a></li>
          <li><a href="/support.html">Support</a></li>
          <li><a href="https://jellyfin.org" target="_blank" rel="noopener">Jellyfin</a></li>
        </ul>
      </div>
      <div class="fuss__spalte">
        <h2>Legal</h2>
        <ul>
          <li><a href="/impressum.html">Impressum</a></li>
          <li><a href="/privacy.html">Privacy</a></li>
          <li><a href="/datenschutz.html">Datenschutz</a></li>
          <li><a href="{GITHUB}/blob/main/LICENSE" target="_blank" rel="noopener">Licences</a></li>
        </ul>
      </div>
    </div>
    <div class="fuss__linie"></div>
    <p class="fuss__klein">
      Swiftly Player is not part of the Jellyfin project and hosts nothing itself. The code is
      under the MPL-2.0; the name, the wordmark and the app icon are not. Playback uses VLCKit
      under the LGPL-2.1-or-later. App Store is a service mark of Apple Inc. The Android robot is
      reproduced or modified from work created and shared by Google and used according to terms
      described in the Creative Commons 3.0 Attribution License.
    </p>
  </div>
</footer>

<script>
{SKRIPT}
</script>
</body>
</html>
"""


# ------------------------------------------------------------------ Faelligkeit
# Bloecke, die erst ab einem Datum sichtbar sein duerfen, stehen zwischen
#   <!--f:GRUPPE:JJJJ-MM-TT--> ... <!--/f:GRUPPE-->
# und <!--wennvoll:GRUPPE--> / <!--wennleer:GRUPPE--> haengen davon ab, ob
# etwas uebrig blieb. PHP (lib.php) macht zur Laufzeit genau dasselbe.
GRENZEN = {"rel": 3}


def gated(gruppe, datum, inhalt):
    return f"<!--f:{gruppe}:{datum.isoformat()}-->{inhalt}<!--/f:{gruppe}-->"


def filtern(text, heute_iso):
    zahl = {}

    def block(m):
        gruppe, datum = m.group(1), m.group(2)
        if datum > heute_iso or zahl.get(gruppe, 0) >= GRENZEN.get(gruppe, 10 ** 9):
            return ""
        zahl[gruppe] = zahl.get(gruppe, 0) + 1
        return m.group(3)
    text = re.sub(r"<!--f:(\w+):(\d{4}-\d{2}-\d{2})-->(.*?)<!--/f:\1-->", block, text, flags=re.S)
    text = re.sub(r"<!--wennvoll:(\w+)-->(.*?)<!--/wennvoll:\1-->",
                  lambda m: m.group(2) if zahl.get(m.group(1)) else "", text, flags=re.S)
    return re.sub(r"<!--wennleer:(\w+)-->(.*?)<!--/wennleer:\1-->",
                  lambda m: "" if zahl.get(m.group(1)) else m.group(2), text, flags=re.S)


# ------------------------------------------------------------------ Titelbild

_schrift = None


def schrift(gewicht):
    global _schrift
    if _schrift is None:
        with open(os.path.join(HIER, "blog-schrift.json"), encoding="utf-8") as h:
            _schrift = json.load(h)
    return _schrift[str(gewicht)]


def text_breite(text, gewicht, groesse, sperrung=0.0):
    t = schrift(gewicht)
    b = 0.0
    for i, z in enumerate(text):
        b += (t.get(z) or t[" "])["v"]
        if i + 1 < len(text):
            b += t["_kern"].get(z + text[i + 1], 0) + sperrung * 1000
    return b * groesse / 1000


def text_umriss(text, gewicht, groesse, x, y, farbe, sperrung=0.0):
    """Text als Pfade: sips kennt keine Webfonts."""
    t = schrift(gewicht)
    teile, ox = [], 0.0
    for i, z in enumerate(text):
        g = t.get(z)
        if g is None:
            warne(f"Titelbild: Zeichen {z!r} fehlt in blog-schrift.json")
            g = t[" "]
        if g["d"]:
            teile.append(f'<path transform="translate({ox:.1f} 0)" d="{g["d"]}"/>')
        ox += g["v"]
        if i + 1 < len(text):
            ox += t["_kern"].get(z + text[i + 1], 0) + sperrung * 1000
    return f'<g transform="translate({x:.1f} {y:.1f}) scale({groesse / 1000:.4f})" fill="{farbe}">{"".join(teile)}</g>'


SCHLAGWORT_NAMEN = {"android tv": "Android TV", "google tv": "Google TV", "intro skipper": "Intro Skipper",
                    "syncplay": "SyncPlay", "quick connect": "Quick Connect", "12.0": "Jellyfin 12",
                    "apple tv": "Apple TV", "windows": "Windows", "linux": "Linux", "macos": "macOS",
                    "ios": "iPhone", "ipad": "iPad", "multi-device": "Multi-device"}


def kategorie(a):
    if a.get("kategorie"):
        return a["kategorie"]
    for s in a["schlagworte"]:
        if s not in ("jellyfin", "clients"):
            return SCHLAGWORT_NAMEN.get(s, s.title())
    return "Jellyfin"


def titelbild_svg(a):
    zufall = hashlib.sha1(a["slug"].encode()).digest()

    def spiel(i, spanne):
        return (zufall[i] / 255 - .5) * spanne
    groesse = 78
    while True:
        zeilen, akt = [], ""
        for wort in a["titel"].split():
            probe = (akt + " " + wort).strip()
            if akt and text_breite(probe, 700, groesse) > 1050:
                zeilen.append(akt)
                akt = wort
            else:
                akt = probe
        zeilen.append(akt)
        if len(zeilen) <= 3 or groesse <= 50:
            break
        groesse -= 2
    abstand = groesse * 1.1
    erste = 520 - (len(zeilen) - 1) * abstand
    kat_y = erste - groesse * .76 - 36

    def schein(n, cx, cy, r, farbe, staerke):
        return (f'<radialGradient id="{n}" cx="{cx:.0f}" cy="{cy:.0f}" r="{r}" gradientUnits="userSpaceOnUse">'
                f'<stop offset="0" stop-color="{farbe}" stop-opacity="{staerke}"/>'
                f'<stop offset=".55" stop-color="{farbe}" stop-opacity="{staerke * .3:.3f}"/>'
                f'<stop offset="1" stop-color="{farbe}" stop-opacity="0"/></radialGradient>')
    teile = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">',
        "<defs>" + schein("a", 960 + spiel(0, 180), 90 + spiel(1, 100), 600, "#5CD1C2", .44)
        + schein("b", 120 + spiel(2, 160), 20 + spiel(3, 80), 520, "#7E9BFF", .30)
        + schein("c", 1150 + spiel(4, 120), 640 + spiel(5, 80), 480, "#E8833A", .26) + "</defs>",
        '<rect width="1200" height="630" fill="#0B0B0D"/>',
        '<rect width="1200" height="630" fill="url(#b)"/><rect width="1200" height="630" fill="url(#a)"/>'
        '<rect width="1200" height="630" fill="url(#c)"/>',
        '<g transform="translate(72 64) scale(.0547)"><rect width="1024" height="1024" rx="230" fill="#17181b" '
        'stroke="#ffffff" stroke-opacity=".16" stroke-width="18"/><path fill="#2fdbc0" d="M440.1,280l285,163.2c38,'
        '21.7,51.2,70,29.6,108-7,12.3-17.2,22.5-29.6,29.6l-285,163.2c-37.9,21.8-86.3,8.6-108.1-29.3-6.9-12-10.5-25.6-'
        '10.5-39.4v-326.6c0-43.7,35.5-79.2,79.2-79.2,13.8,0,27.4,3.6,39.4,10.5Z"/></g>',
        text_umriss("Swiftly Player", 600, 30, 144, 102, "#FFFFFF"),
        text_umriss(kategorie(a).upper(), 700, 22, 74, kat_y, "#5CD1C2", sperrung=.12),
    ]
    for i, z in enumerate(zeilen):
        teile.append(text_umriss(z, 700, groesse, 70, erste + i * abstand, "#FFFFFF"))
    adresse = "swiftlyplayer.com" + (a["pfad"].rstrip("/") if a["seite"] else "/blog")
    teile.append(text_umriss(adresse, 600, 22, 74, 584, "#FFFFFF", sperrung=.01)
                 .replace('fill="#FFFFFF"', 'fill="#FFFFFF" fill-opacity=".5"'))
    teile.append("</svg>")
    return "\n".join(teile) + "\n"


def titelbild_schreiben(a, ordner, name):
    """SVG schreiben; JPEG 1200x630 nur neu rastern, wenn sich das SVG geaendert hat."""
    svg = os.path.join(ordner, name + ".svg")
    jpg = os.path.join(ordner, name + ".jpg")
    neu = schreiben(svg, titelbild_svg(a))
    if neu or not os.path.exists(jpg):
        erg = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "86", svg, "--out", jpg],
                             capture_output=True, text=True)
        if erg.returncode != 0 or bild_masse(jpg) != (1200, 630):
            warne(f"Titelbild {name}.jpg: sips fehlgeschlagen ({erg.stderr.strip()[:200]})")
        else:
            print("gerastert    " + os.path.relpath(jpg, os.path.dirname(WEBSITE)))


# ------------------------------------------------------------------ Seiten

def karte(a, stufe="h2", heute=None):
    geplant = '<span class="geplant">Scheduled</span>' if heute and not a["seite"] and a["datum"] > heute else ""
    return (f'<li><a class="karte" href="{a["pfad"]}">'
            f'<span class="karte__bild"><img src="{a["bild"]}" alt="" width="1200" height="630" loading="lazy" decoding="async"></span>'
            f'<span class="karte__rumpf"><span class="karte__kopf"><span>{e(kategorie(a))}</span>'
            f'<time datetime="{a["datum"].isoformat()}">{datum_text(a["datum"])}</time>{geplant}</span>'
            f'<{stufe}>{e(a["titel"])}</{stufe}><p>{e(a["beschreibung"])}</p>'
            f'<span class="karte__weiter" aria-hidden="true">Read</span></span></a></li>')


def verwandte(a, alle):
    """Alle anderen, beste zuerst. Welche davon erscheinen, entscheidet filtern()."""
    andere = [b for b in alle if b["pfad"] != a["pfad"]]
    return sorted(andere, key=lambda b: (len(set(a["schlagworte"]) & set(b["schlagworte"])), b["datum"]), reverse=True)


def breadcrumb(eintraege):
    return {"@context": "https://schema.org", "@type": "BreadcrumbList",
            "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": n, "item": u}
                                for i, (n, u) in enumerate(eintraege)]}


def seitenleiste(rumpf, rel, rel_titel="Related articles"):
    inhalt = re.findall(r'<h2 id="([^"]+)">(.*?)</h2>', rumpf)
    toc = ""
    if len(inhalt) >= 3:
        punkte = "".join(f'<li><a href="#{k}">{t}</a></li>' for k, t in inhalt)
        toc = (f'<nav class="leistenblock leistenblock--inhalt" aria-labelledby="inhalt-titel">'
               f'<h2 id="inhalt-titel">On this page</h2><ol class="inhaltsliste">{punkte}</ol></nav>')
    punkte = "".join(gated("rel", b["datum"] if not b["seite"] else dt.date(2000, 1, 1),
                           f'<li><a class="verwandt" href="{b["pfad"]}"><img src="{b["bild"]}" alt="" width="1200" height="630" '
                           f'loading="lazy" decoding="async"><span><b>{e(b["titel"])}</b>'
                           f'<time datetime="{b["datum"].isoformat()}">{datum_text(b["datum"])}</time></span></a></li>')
                     for b in rel)
    rel_html = (f'<!--wennvoll:rel--><section class="weiterlesen" aria-labelledby="verwandt">'
                f'<h2 id="verwandt">{rel_titel}</h2><ul class="verwandtliste verwandtliste--unten">{punkte}</ul></section><!--/wennvoll:rel-->')
    leiste = f"""<aside class="seitenleiste" aria-label="Contents and Swiftly Player downloads">
  <div class="seitenleiste__klebt">
  {toc}
{laden_kasten()}
  </div>
</aside>"""
    return leiste, rel_html


def artikel_seite(a, alle, heute=None):
    """heute gesetzt = statische Vorschau (mit Hinweis 'Preview'), sonst Vorlage fuer PHP."""
    vergebene = set()
    rumpf = rendern(gliedern(a["bloecke"]), vergebene=vergebene)
    minuten = max(1, round(a["woerter"] / 230))
    angaben = [f"<span>By {HERAUSGEBER}</span>",
               f'<span><time datetime="{a["datum"].isoformat()}">{datum_text(a["datum"])}</time></span>']
    if a["aktualisiert"]:
        angaben.append(f'<span>Updated <time datetime="{a["aktualisiert"].isoformat()}">{datum_text(a["aktualisiert"])}</time></span>')
    angaben.append(f"<span>{minuten} min read</span>")
    geplant = (f'<p class="geplant">Preview · goes live on {datum_text(a["datum"])}</p>\n'
               if heute and not a["seite"] and a["datum"] > heute else "")
    offen = f'<p class="offenlegung">{OFFENLEGUNG}</p>\n' if a["offenlegung"] else ""
    pfad = ('<ol class="pfad"><li><a href="/">Swiftly Player</a></li><li><a href="/blog/">Blog</a></li></ol>'
            if not a["seite"] else '<ol class="pfad"><li><a href="/">Swiftly Player</a></li></ol>')
    leiste, rel_html = seitenleiste(rumpf, verwandte(a, alle), "Other devices" if a["seite"] else "Related articles")
    inhalt = f"""<div class="schein" aria-hidden="true"></div>
<div class="artikelbahn">
<article class="artikel">
  <header class="seitenkopf">
    {pfad}
    {geplant}<h1>{e(a["titel"])}</h1>
    <p class="unter">{e(a["beschreibung"])}</p>
    <p class="angaben">{"".join(angaben)}</p>
  </header>
  <figure class="titelbild"><img src="{a["bild"]}" alt="" width="1200" height="630" fetchpriority="high" decoding="async"></figure>
  {offen}<div class="text">
{rumpf}
  </div>
  {rel_html}
  <a class="zurueck" href="{'/' if a['seite'] else '/blog/'}">{SYMBOL}{'Swiftly Player' if a['seite'] else 'All articles'}</a>
</article>
{leiste}
</div>"""
    posting = {
        "@context": "https://schema.org", "@type": "BlogPosting" if not a["seite"] else "Article",
        "headline": a["titel"], "description": a["beschreibung"],
        "datePublished": a["datum"].isoformat(),
        "dateModified": (a["aktualisiert"] or a["datum"]).isoformat(),
        "author": {"@type": "Organization", "name": HERAUSGEBER, "url": DOMAIN + "/"},
        "publisher": ORGANISATION,
        "mainEntityOfPage": {"@type": "WebPage", "@id": a["url"]},
        "url": a["url"], "image": DOMAIN + a["bild"], "inLanguage": "en",
        "keywords": ", ".join(a["schlagworte"]), "wordCount": a["woerter"],
    }
    kette = [("Swiftly Player", DOMAIN + "/")] + ([] if a["seite"] else [("Blog", DOMAIN + "/blog/")]) + [(a["titel"], a["url"])]
    ld = [json_ld(posting), json_ld(breadcrumb(kette))]
    faq = faq_finden(a["bloecke"])
    if faq:
        ld.append(json_ld({"@context": "https://schema.org", "@type": "FAQPage",
                           "mainEntity": [{"@type": "Question", "name": f,
                                           "acceptedAnswer": {"@type": "Answer", "text": t}} for f, t in faq]}))
    kopf = (f'<meta property="article:published_time" content="{a["datum"].isoformat()}">\n'
            f'<meta property="article:modified_time" content="{(a["aktualisiert"] or a["datum"]).isoformat()}">\n'
            f'<meta property="article:author" content="{HERAUSGEBER}">\n'
            + "".join(f'<meta property="article:tag" content="{e(t)}">\n' for t in a["schlagworte"]))
    robots = '<meta name="robots" content="noindex">\n' if geplant else ""
    return seite(f'{a["titel"]} | Swiftly Player', a["beschreibung"], a["url"], inhalt,
                 og_typ="article", zusatz_kopf=kopf, ld=ld, robots=robots,
                 bild=a["bild"], bild_alt=a["titel"], blog_aktiv=not a["seite"])


def uebersicht(liste, heute=None):
    beschreibung = "Guides and comparisons for Jellyfin: clients, Direct Play, Apple TV, Android TV and more, from the developer of Swiftly Player."
    karten = "".join(gated("karte", a["datum"], karte(a, "h2", heute)) for a in liste)
    inhalt = f"""<div class="schein" aria-hidden="true"></div>
<div class="bahn">
  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li></ol>
    <h1>Blog</h1>
    <p class="unter">Guides and comparisons for people who run their own Jellyfin server. Written by the developer of Swiftly Player.</p>
  </header>
  <!--wennvoll:karte--><ul class="karten karten--raster">{karten}</ul><!--/wennvoll:karte-->
  <!--wennleer:karte--><p class="leer">Nothing here yet.</p><!--/wennleer:karte-->
</div>"""
    url = DOMAIN + "/blog/"
    ld = [json_ld({"@context": "https://schema.org", "@type": "Blog", "name": "Swiftly Player blog", "url": url,
                   "inLanguage": "en", "author": {"@type": "Organization", "name": HERAUSGEBER, "url": DOMAIN + "/"},
                   "publisher": ORGANISATION}),
          json_ld(breadcrumb([("Swiftly Player", DOMAIN + "/"), ("Blog", url)]))]
    robots = '<!--wennleer:karte--><meta name="robots" content="noindex">\n<!--/wennleer:karte-->'
    return seite("Blog | Swiftly Player", beschreibung, url, inhalt, ld=ld, robots=robots)


def seite_404():
    inhalt = f"""<div class="schein" aria-hidden="true"></div>
<div class="bahn">
  <header class="seitenkopf seitenkopf--mitte">
    <h1>Page not found</h1>
    <p class="unter">There is no page at this address.</p>
  </header>
  <p class="mitte"><a class="zurueck" href="/blog/">{SYMBOL}All articles</a></p>
</div>"""
    return seite("Page not found | Swiftly Player", "There is no page at this address.", "", inhalt,
                 robots='<meta name="robots" content="noindex">\n')


# ------------------------------------------------------------------ PHP
# Laeuft auf dem Webspace (PHP 8.5). Kein Framework, keine Datenbank, kein Cron.

PHP_LIB = r"""<?php
// Erzeugt von Werkzeuge/blog-bauen.py. Nicht von Hand aendern.
declare(strict_types=1);

const DOMAIN = 'https://swiftlyplayer.com';
const INDEXNOW_SCHLUESSEL = '@SCHLUESSEL@';
const GRENZEN = ['rel' => 3];

function heute(): string
{
    // Nur der lokale Testserver (php -S) darf einen Tag vorgeben.
    $vorgabe = (string) getenv('SWIFTLY_HEUTE');
    if (PHP_SAPI === 'cli-server' && preg_match('/^\d{4}-\d{2}-\d{2}$/', $vorgabe)) {
        return $vorgabe;
    }
    return (new DateTimeImmutable('now', new DateTimeZone('Europe/Berlin')))->format('Y-m-d');
}

function daten(): array
{
    static $daten = null;
    if ($daten === null) {
        $roh = @file_get_contents(__DIR__ . '/artikel.json');
        $daten = is_string($roh) ? (json_decode($roh, true) ?: []) : [];
    }
    return $daten;
}

function faellige(): array
{
    $heute = heute();
    return array_values(array_filter(daten()['artikel'] ?? [], fn ($a) => $a['datum'] <= $heute));
}

function finden(string $slug): ?array
{
    if (!preg_match('/^[a-z0-9]+(-[a-z0-9]+)*$/', $slug)) {
        return null;
    }
    foreach (faellige() as $a) {
        if ($a['slug'] === $slug) {
            return $a;
        }
    }
    return null;
}

function tagesbeginn(string $datum): int
{
    return (new DateTimeImmutable($datum . ' 00:00', new DateTimeZone('Europe/Berlin')))->getTimestamp();
}

function stand(array $artikel, string $datei): int
{
    $zeit = (int) @filemtime($datei);
    foreach ($artikel as $a) {
        $zeit = max($zeit, tagesbeginn($a['datum']));
    }
    return $zeit;
}

function filtern(string $html): string
{
    $heute = heute();
    $zahl = [];
    $html = preg_replace_callback('/<!--f:(\w+):(\d{4}-\d{2}-\d{2})-->(.*?)<!--\/f:\1-->/s',
        function ($m) use ($heute, &$zahl) {
            $n = $zahl[$m[1]] ?? 0;
            if ($m[2] > $heute || $n >= (GRENZEN[$m[1]] ?? PHP_INT_MAX)) {
                return '';
            }
            $zahl[$m[1]] = $n + 1;
            return $m[3];
        }, $html);
    $html = preg_replace_callback('/<!--wennvoll:(\w+)-->(.*?)<!--\/wennvoll:\1-->/s',
        fn ($m) => empty($zahl[$m[1]]) ? '' : $m[2], $html);
    return preg_replace_callback('/<!--wennleer:(\w+)-->(.*?)<!--\/wennleer:\1-->/s',
        fn ($m) => empty($zahl[$m[1]]) ? $m[2] : '', $html);
}

function kopfzeilen(string $typ, int $stand, int $sekunden): void
{
    header('Content-Type: ' . $typ);
    header('X-Content-Type-Options: nosniff');
    header('Last-Modified: ' . gmdate('D, d M Y H:i:s', $stand) . ' GMT');
    header('Cache-Control: public, max-age=' . $sekunden);
    $seit = $_SERVER['HTTP_IF_MODIFIED_SINCE'] ?? '';
    if ($seit !== '' && ($t = strtotime($seit)) !== false && $t >= $stand) {
        http_response_code(304);
        exit;
    }
}

function nicht_gefunden(): never
{
    http_response_code(404);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: public, max-age=300');
    readfile(__DIR__ . '/_404.html');
    exit;
}

// IndexNow: jede faellige Adresse genau einmal melden, nach der Antwort an den
// Browser. Fehler bleiben still; ein neuer Versuch fruehestens nach einer Stunde.
function melden(): void
{
    if (PHP_SAPI === 'cli' || PHP_SAPI === 'cli-server') {
        return;
    }
    $urls = [DOMAIN . '/', DOMAIN . '/blog/'];
    foreach (daten()['seiten'] ?? [] as $s) {
        $urls[] = DOMAIN . $s;
    }
    foreach (faellige() as $a) {
        $urls[] = DOMAIN . '/blog/' . $a['slug'] . '/';
    }
    $datei = __DIR__ . '/.gemeldet.json';
    $stand = json_decode((string) @file_get_contents($datei), true) ?: [];
    if (!array_diff($urls, $stand['urls'] ?? []) || time() - (int) ($stand['versuch'] ?? 0) < 3600) {
        return;
    }
    register_shutdown_function(function () use ($datei, $urls) {
        if (function_exists('fastcgi_finish_request')) {
            fastcgi_finish_request();
        }
        $h = @fopen($datei, 'c+');
        if (!$h || !flock($h, LOCK_EX | LOCK_NB)) {
            return;
        }
        $stand = json_decode((string) stream_get_contents($h), true) ?: [];
        $bekannt = $stand['urls'] ?? [];
        $offen = array_values(array_diff($urls, $bekannt));
        if ($offen && time() - (int) ($stand['versuch'] ?? 0) >= 3600) {
            $stand['versuch'] = time();
            $inhalt = json_encode(['host' => 'swiftlyplayer.com', 'key' => INDEXNOW_SCHLUESSEL,
                'keyLocation' => DOMAIN . '/' . INDEXNOW_SCHLUESSEL . '.txt', 'urlList' => $offen]);
            $kontext = stream_context_create(['http' => ['method' => 'POST', 'timeout' => 2, 'ignore_errors' => true,
                'header' => "Content-Type: application/json; charset=utf-8\r\n", 'content' => $inhalt]]);
            @file_get_contents('https://api.indexnow.org/indexnow', false, $kontext);
            $antwort = function_exists('http_get_last_response_headers') ? (http_get_last_response_headers() ?? []) : [];
            if (preg_match('#^HTTP/\S+\s+(200|202)\b#', (string) ($antwort[0] ?? ''))) {
                $stand['urls'] = array_values(array_unique(array_merge($bekannt, $offen)));
                unset($stand['versuch']);
            }
            ftruncate($h, 0);
            rewind($h);
            fwrite($h, (string) json_encode($stand, JSON_UNESCAPED_SLASHES));
        }
        flock($h, LOCK_UN);
        fclose($h);
    });
}

function x(string $text): string
{
    return htmlspecialchars($text, ENT_XML1 | ENT_QUOTES, 'UTF-8');
}
"""

PHP_ARTIKEL = r"""<?php
// Erzeugt von Werkzeuge/blog-bauen.py. /blog/<slug>/ -> hier (siehe .htaccess).
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$slug = $_GET['slug'] ?? '';
$artikel = is_string($slug) ? finden($slug) : null;
$datei = $artikel ? __DIR__ . '/_artikel/' . $artikel['slug'] . '.html' : '';
if (!$artikel || !is_file($datei)) {
    nicht_gefunden();
}
melden();
kopfzeilen('text/html; charset=utf-8', stand([$artikel], $datei), 300);
echo filtern((string) file_get_contents($datei));
"""

PHP_INDEX = r"""<?php
// Erzeugt von Werkzeuge/blog-bauen.py. /blog/
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$datei = __DIR__ . '/_artikel/_uebersicht.html';
melden();
kopfzeilen('text/html; charset=utf-8', stand(faellige(), $datei), 300);
echo filtern((string) file_get_contents($datei));
"""

PHP_TITEL = r"""<?php
// Erzeugt von Werkzeuge/blog-bauen.py. /blog/titel/<slug>.jpg|svg, erst ab dem Tag des Artikels.
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$typen = ['jpg' => 'image/jpeg', 'svg' => 'image/svg+xml'];
$slug = is_string($_GET['slug'] ?? null) ? $_GET['slug'] : '';
$typ = is_string($_GET['typ'] ?? null) ? $_GET['typ'] : '';
// All-Inkl liefert bei /blog/titel/<slug>.jpg keine Abfragewerte an dieses
// Skript, obwohl die Regel in .htaccess sie anhaengt (bei artikel.php kommen
// sie an). Deshalb notfalls aus der Adresse selbst lesen.
if ($slug === '' || $typ === '') {
    $pfad = parse_url((string) ($_SERVER['REQUEST_URI'] ?? ''), PHP_URL_PATH) ?: '';
    if (preg_match('#/titel/([a-z0-9]+(?:-[a-z0-9]+)*)\.(jpg|svg)$#', $pfad, $teile)) {
        $slug = $teile[1];
        $typ = $teile[2];
    }
}
$artikel = finden($slug);
if (!$artikel || !isset($typen[$typ])) {
    nicht_gefunden();
}
$datei = __DIR__ . '/_artikel/titel/' . $artikel['slug'] . '.' . $typ;
if (!is_file($datei)) {
    nicht_gefunden();
}
kopfzeilen($typen[$typ], stand([$artikel], $datei), 86400);
header('Content-Length: ' . filesize($datei));
readfile($datei);
"""

PHP_FEED = r"""<?php
// Erzeugt von Werkzeuge/blog-bauen.py. /blog/feed.xml
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$liste = faellige();
melden();
kopfzeilen('application/rss+xml; charset=utf-8', stand($liste, __DIR__ . '/_artikel/artikel.json'), 600);
$rfc = fn (string $d) => (new DateTimeImmutable($d . ' 07:00', new DateTimeZone('Europe/Berlin')))->format(DATE_RSS);
echo '<?xml version="1.0" encoding="UTF-8"?>', "\n";
echo '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">', "\n<channel>\n";
echo "  <title>Swiftly Player blog</title>\n  <link>", DOMAIN, "/blog/</link>\n";
echo '  <atom:link href="', DOMAIN, '/blog/feed.xml" rel="self" type="application/rss+xml"/>', "\n";
echo "  <description>Guides and comparisons for people who run their own Jellyfin server.</description>\n";
echo "  <language>en</language>\n";
if ($liste) {
    echo '  <lastBuildDate>', $rfc($liste[0]['datum']), "</lastBuildDate>\n";
}
foreach ($liste as $a) {
    $url = DOMAIN . '/blog/' . $a['slug'] . '/';
    echo "  <item>\n    <title>", x($a['titel']), "</title>\n    <link>", $url, "</link>\n";
    echo '    <guid isPermaLink="true">', $url, "</guid>\n    <pubDate>", $rfc($a['datum']), "</pubDate>\n";
    echo '    <description>', x($a['beschreibung']), "</description>\n";
    echo '    <enclosure url="', DOMAIN, '/blog/titel/', $a['slug'], '.jpg" type="image/jpeg" length="', (int) @filesize(__DIR__ . '/_artikel/titel/' . $a['slug'] . '.jpg'), '"/>', "\n";
    foreach ($a['schlagworte'] as $s) {
        echo '    <category>', x($s), "</category>\n";
    }
    echo "  </item>\n";
}
echo "</channel>\n</rss>\n";
"""

PHP_SITEMAP = r"""<?php
// Erzeugt von Werkzeuge/blog-bauen.py. /sitemap.xml (Rewrite in der Wurzel) und /blog/sitemap.xml
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$liste = faellige();
melden();
kopfzeilen('application/xml; charset=utf-8', stand($liste, __DIR__ . '/_artikel/artikel.json'), 600);
echo '<?xml version="1.0" encoding="UTF-8"?>', "\n", '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">', "\n";
foreach (daten()['sitemap'] ?? [] as $u) {
    echo '  <url><loc>', x($u['loc']), '</loc>';
    foreach (['lastmod', 'changefreq', 'priority'] as $feld) {
        if (!empty($u[$feld])) {
            echo "<$feld>", x($u[$feld]), "</$feld>";
        }
    }
    echo "</url>\n";
}
if ($liste) {
    $neueste = max(array_map(fn ($a) => $a['aktualisiert'] ?: $a['datum'], $liste));
    echo '  <url><loc>', DOMAIN, '/blog/</loc><lastmod>', $neueste, "</lastmod><changefreq>weekly</changefreq><priority>0.7</priority></url>\n";
}
foreach ($liste as $a) {
    echo '  <url><loc>', DOMAIN, '/blog/', $a['slug'], '/</loc><lastmod>', $a['aktualisiert'] ?: $a['datum'],
        "</lastmod><changefreq>monthly</changefreq><priority>0.6</priority></url>\n";
}
echo "</urlset>\n";
"""

PHP_LLMS = r"""<?php
// Erzeugt von Werkzeuge/blog-bauen.py. /llms.txt (Rewrite in der Wurzel)
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$liste = faellige();
melden();
kopfzeilen('text/plain; charset=utf-8', stand($liste, __DIR__ . '/_artikel/artikel.json'), 600);
echo implode("\n", daten()['llms'] ?? []), "\n";
if ($liste) {
    echo "## Blog\n\n";
    foreach ($liste as $a) {
        echo '- [', $a['titel'], '](', DOMAIN, '/blog/', $a['slug'], '/): ', $a['beschreibung'], "\n";
    }
    echo "\n";
}
"""

HTACCESS_BLOG = r"""# Erzeugt von Werkzeuge/blog-bauen.py. Artikel erscheinen ab ihrem Datum (PHP).
Options -Indexes
DirectoryIndex index.php
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /blog/
RewriteRule ^_artikel(/.*)?$ - [R=404,L]
RewriteRule ^feed\.xml$ feed.php [L]
RewriteRule ^sitemap\.xml$ sitemap.php [L]
RewriteRule ^llms\.txt$ llms.php [L]
RewriteRule ^titel/([a-z0-9]+(?:-[a-z0-9]+)*)\.(jpg|svg)$ titel.php?slug=$1&typ=$2 [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^([a-z0-9]+(?:-[a-z0-9]+)*)$ /blog/$1/ [R=301,L]
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^([a-z0-9]+(?:-[a-z0-9]+)*)/$ artikel.php?slug=$1 [L]
</IfModule>
"""

HTACCESS_GESPERRT = "# Erzeugt von Werkzeuge/blog-bauen.py. Nur fuer PHP lesbar.\nRequire all denied\n"

# Nur dieser Block gehoert uns; website-hochladen.py setzt ihn in eine
# vorhandene .htaccess auf dem Server ein, statt sie zu ersetzen.
HTACCESS_WURZEL = r"""# BEGIN swiftly-blog
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule ^sitemap\.xml$ blog/sitemap.php [L]
RewriteRule ^llms\.txt$ blog/llms.php [L]
</IfModule>
# END swiftly-blog
"""


# ------------------------------------------------------------------ Dateien

def schreiben(pfad, text):
    """Schreibt nur bei Aenderung (gleiche Pruefsumme = kein Upload). True, wenn geschrieben."""
    os.makedirs(os.path.dirname(pfad), exist_ok=True)
    alt = None
    if os.path.exists(pfad):
        with open(pfad, encoding="utf-8") as h:
            alt = h.read()
    if alt == text:
        return False
    with open(pfad, "w", encoding="utf-8") as h:
        h.write(text)
    print("geschrieben  " + os.path.relpath(pfad, os.path.dirname(WEBSITE)))
    return True


def feste_seiten():
    """Nicht-Blog-Eintraege aus Website/sitemap.xml (die bleibt als Rueckfall ohne Blog)."""
    ns = "http://www.sitemaps.org/schemas/sitemap/0.9"
    pfad = os.path.join(WEBSITE, "sitemap.xml")
    feste = []
    if os.path.exists(pfad):
        for url in ET.parse(pfad).getroot().findall(f"{{{ns}}}url"):
            loc = url.findtext(f"{{{ns}}}loc", "")
            if "/blog/" in loc:
                continue
            feste.append({"loc": loc, "lastmod": url.findtext(f"{{{ns}}}lastmod"),
                          "changefreq": url.findtext(f"{{{ns}}}changefreq"), "priority": url.findtext(f"{{{ns}}}priority")})
    return feste


def sitemap_text(eintraege):
    zeilen = []
    for u in eintraege:
        teile = f"<loc>{e(u['loc'])}</loc>" + "".join(f"<{k}>{e(u[k])}</{k}>" for k in ("lastmod", "changefreq", "priority") if u.get(k))
        zeilen.append(f"  <url>{teile}</url>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
            + "\n".join(zeilen) + "\n</urlset>\n")


def sitemap_eintraege(liste, seiten):
    eintraege = [u for u in feste_seiten() if not any(u["loc"] == s["url"] for s in seiten)]
    eintraege += [{"loc": s["url"], "lastmod": (s["aktualisiert"] or s["datum"]).isoformat(),
                   "changefreq": "monthly", "priority": "0.7"} for s in seiten]
    if liste:
        neueste = max((a["aktualisiert"] or a["datum"]) for a in liste)
        eintraege.append({"loc": DOMAIN + "/blog/", "lastmod": neueste.isoformat(), "changefreq": "weekly", "priority": "0.7"})
        eintraege += [{"loc": a["url"], "lastmod": (a["aktualisiert"] or a["datum"]).isoformat(),
                       "changefreq": "monthly", "priority": "0.6"} for a in liste]
    return eintraege


def llms_kopf(seiten):
    zeilen = ["# Swiftly Player", "",
              "> A free, open-source video player for your own Jellyfin server. It plays files as Direct Play "
              "or Direct Stream instead of transcoding them. For iPhone, iPad, Mac, Apple TV, Android, "
              "Android TV, Windows and Linux. Built by one person.", "",
              "## Pages", "",
              f"- [Swiftly Player]({DOMAIN}/): features, supported platforms, downloads, FAQ",
              f"- [App Store]({DOMAIN}/download/app-store/): install on iPhone, iPad, Mac and Apple TV",
              f"- [TestFlight]({DOMAIN}/download/testflight/): join the beta and send feedback",
              f"- [Android and Android TV]({DOMAIN}/android/): how to join the closed test on Google Play",
              f"- [Windows]({DOMAIN}/download/windows/): installing the Windows build, step by step",
              f"- [Linux]({DOMAIN}/download/linux/): one command for apt, dnf, zypper and pacman",
              f"- [Support]({DOMAIN}/support.html): help and contact",
              f"- [Privacy]({DOMAIN}/privacy.html): the app collects nothing",
              f"- [Source code]({GITHUB}): MPL-2.0"]
    zeilen += [f"- [{s['titel']}]({s['url']}): {s['beschreibung']}" for s in seiten]
    return zeilen + [""]


def feed_text(liste):
    def rfc(d):
        return email.utils.format_datetime(dt.datetime(d.year, d.month, d.day, 7, 0, tzinfo=ZONE))
    items = "".join(f"""
  <item>
    <title>{e(a["titel"])}</title>
    <link>{a["url"]}</link>
    <guid isPermaLink="true">{a["url"]}</guid>
    <pubDate>{rfc(a["datum"])}</pubDate>
    <description>{e(a["beschreibung"])}</description>
{"".join(f"    <category>{e(t)}</category>{chr(10)}" for t in a["schlagworte"])}  </item>""" for a in liste)
    stand = f"\n  <lastBuildDate>{rfc(liste[0]['datum'])}</lastBuildDate>" if liste else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
  <title>Swiftly Player blog</title>
  <link>{DOMAIN}/blog/</link>
  <atom:link href="{DOMAIN}/blog/feed.xml" rel="self" type="application/rss+xml"/>
  <description>Guides and comparisons for people who run their own Jellyfin server.</description>
  <language>en</language>{stand}{items}
</channel>
</rss>
"""


def indexnow_schluessel():
    """Oeffentlicher Schluessel fuer IndexNow (kein Geheimnis): Website/<32 hex>.txt."""
    for name in sorted(os.listdir(WEBSITE)):
        m = re.fullmatch(r"([0-9a-f]{32})\.txt", name)
        if m:
            return m.group(1)
    schluessel = hashlib.sha256(os.urandom(32)).hexdigest()[:32]
    schreiben(os.path.join(WEBSITE, schluessel + ".txt"), schluessel)
    return schluessel


def aufraeumen(ziel, slugs, seiten):
    """Veraltete Ausgaben entfernen: alte statische Blogseiten (Kennung MARKER),
    Vorlagen und Titelbilder geloeschter Artikel. Nie quellen/ oder bilder/."""
    blog = os.path.join(ziel, "blog")
    if not os.path.isdir(blog):
        return
    for name in os.listdir(blog):
        pfad = os.path.join(blog, name, "index.html")
        if name in ("quellen", "bilder", "_artikel", "titel") or not os.path.isfile(pfad):
            continue
        if ziel == VORSCHAU and name in slugs:
            continue
        with open(pfad, encoding="utf-8") as h:
            if MARKER not in h.read(4000):
                continue
        shutil.rmtree(os.path.join(blog, name))
        print("entfernt     " + os.path.relpath(os.path.join(blog, name), ziel) + "/")
    if ziel == WEBSITE:
        for alt in ("index.html", "feed.xml"):
            p = os.path.join(blog, alt)
            if os.path.isfile(p):
                os.remove(p)
                print("entfernt     blog/" + alt)
    for ordner, endungen in ((os.path.join(blog, "_artikel"), (".html",)),
                             (os.path.join(blog, "_artikel", "titel"), (".svg", ".jpg")),
                             (os.path.join(blog, "titel"), (".svg", ".jpg"))):
        if not os.path.isdir(ordner):
            continue
        for name in os.listdir(ordner):
            stamm, endung = os.path.splitext(name)
            if endung in endungen and not stamm.startswith("_") and stamm not in slugs:
                os.remove(os.path.join(ordner, name))
                print("entfernt     " + os.path.relpath(os.path.join(ordner, name), ziel))


def landingpages_bauen(ziel, seiten):
    for s in seiten:
        ordner = os.path.join(ziel, s["pfad"].strip("/"))
        if ziel != WEBSITE and os.path.islink(os.path.join(ziel, s["pfad"].strip("/").split("/")[0])):
            continue                                   # Vorschau spiegelt Website/ per Verknuepfung
        if ziel == WEBSITE:
            titelbild_schreiben(s, ordner, "titelbild")
        else:
            for endung in (".svg", ".jpg"):
                quelle = os.path.join(WEBSITE, s["pfad"].strip("/"), "titelbild" + endung)
                if os.path.exists(quelle):
                    os.makedirs(ordner, exist_ok=True)
                    shutil.copy2(quelle, os.path.join(ordner, "titelbild" + endung))
        index = os.path.join(ordner, "index.html")
        if os.path.exists(index):
            with open(index, encoding="utf-8") as h:
                if MARKER not in h.read(4000):
                    warne(f"{s['pfad']}index.html stammt nicht vom Generator; nicht ueberschrieben")
                    continue
        schreiben(index, filtern(artikel_seite(s, seiten), "9999-12-31"))


def startseite_pflegen(seiten):
    """index.html: Fussspalte 'Jellyfin clients' mit den Landingpages, und das
    FAQPage-JSON-LD aus der sichtbaren FAQ neu (Google verlangt Gleichstand)."""
    pfad = os.path.join(WEBSITE, "index.html")
    if not os.path.exists(pfad):
        return
    with open(pfad, encoding="utf-8") as h:
        s = alt = h.read()
    s = re.sub(r"<!-- seiten:anfang.*?<!-- seiten:ende -->\n\n      ", "", s, flags=re.S)
    s = s.replace('<div class="fuss__raster fuss__raster--fuenf">', '<div class="fuss__raster">')
    anker = '<div class="fuss__spalte">\n        <h2>Elsewhere</h2>'
    if seiten and anker in s:
        punkte = "".join(f'\n          <li><a href="{x["pfad"]}">{e(x["kurzname"])}</a></li>' for x in seiten)
        s = s.replace(anker, '<!-- seiten:anfang (blog-bauen.py) -->\n      <div class="fuss__spalte">\n'
                      f'        <h2>Jellyfin clients</h2>\n        <ul>{punkte}\n        </ul>\n      </div>\n'
                      '      <!-- seiten:ende -->\n\n      ' + anker, 1)
        s = s.replace('<div class="fuss__raster">', '<div class="fuss__raster fuss__raster--fuenf">', 1)

    def rein(x):
        x = html.unescape(re.sub(r"<[^>]+>", " ", x))
        return re.sub(r"\s+([.,;:!?)])", r"\1", re.sub(r"\s+", " ", x)).strip()
    fragen = re.findall(r'<button class="frage__knopf"[^>]*>\s*<span>(.*?)</span>.*?'
                        r'<div class="frage__antwort"[^>]*><div>(.*?)</div></div>', s, re.S)
    if fragen:
        ld = json_ld({"@context": "https://schema.org", "@type": "FAQPage",
                      "mainEntity": [{"@type": "Question", "name": rein(f),
                                      "acceptedAnswer": {"@type": "Answer", "text": rein(a)}} for f, a in fragen]})
        s = re.sub(r'<script type="application/ld\+json">\s*\{\s*"@context": "https://schema.org",\s*"@type": "FAQPage".*?</script>',
                   lambda m: ld, s, count=1, flags=re.S)
    if s != alt:
        schreiben(pfad, s)


def bauen_live(artikel, seiten):
    """Website/: alle Artikel geschuetzt, PHP entscheidet ueber Sichtbarkeit."""
    liste = sorted(artikel, key=lambda a: (a["datum"], a["slug"]), reverse=True)
    blog = os.path.join(WEBSITE, "blog")
    lager = os.path.join(blog, "_artikel")
    for a in liste:
        titelbild_schreiben(a, os.path.join(lager, "titel"), a["slug"])
        schreiben(os.path.join(lager, a["slug"] + ".html"), artikel_seite(a, liste))
    schreiben(os.path.join(lager, "_uebersicht.html"), uebersicht(liste))
    schreiben(os.path.join(lager, "_404.html"), seite_404())
    daten = {
        "artikel": [{"slug": a["slug"], "titel": a["titel"], "beschreibung": a["beschreibung"],
                     "datum": a["datum"].isoformat(),
                     "aktualisiert": a["aktualisiert"].isoformat() if a["aktualisiert"] else "",
                     "bild": a["bild"], "schlagworte": a["schlagworte"]} for a in liste],
        "seiten": [s["pfad"] for s in seiten],
        "sitemap": sitemap_eintraege([], seiten),
        "llms": llms_kopf(seiten),
    }
    schreiben(os.path.join(lager, "artikel.json"), json.dumps(daten, ensure_ascii=False, indent=1) + "\n")
    schreiben(os.path.join(lager, "lib.php"), PHP_LIB.replace("@SCHLUESSEL@", indexnow_schluessel()))
    schreiben(os.path.join(lager, ".htaccess"), HTACCESS_GESPERRT)
    for name, text in (("artikel.php", PHP_ARTIKEL), ("index.php", PHP_INDEX), ("titel.php", PHP_TITEL),
                       ("feed.php", PHP_FEED), ("sitemap.php", PHP_SITEMAP), ("llms.php", PHP_LLMS),
                       (".htaccess", HTACCESS_BLOG)):
        schreiben(os.path.join(blog, name), text)
    schreiben(os.path.join(WEBSITE, ".htaccess"), HTACCESS_WURZEL)
    # Rueckfall, falls ein Rewrite fehlt: ohne Blog, damit nichts Kuenftiges durchsickert.
    schreiben(os.path.join(WEBSITE, "sitemap.xml"), sitemap_text(sitemap_eintraege([], seiten)))
    schreiben(os.path.join(WEBSITE, "llms.txt"), "\n".join(llms_kopf(seiten)))
    landingpages_bauen(WEBSITE, seiten)
    startseite_pflegen(seiten)
    aufraeumen(WEBSITE, {a["slug"] for a in liste}, seiten)
    return liste


def bauen_vorschau(artikel, seiten, heute):
    """Statisch, alle Artikel sichtbar, kuenftige mit Hinweis. Nie hochgeladen."""
    vorschau_vorbereiten()
    liste = sorted(artikel, key=lambda a: (a["datum"], a["slug"]), reverse=True)
    for a in liste:
        schreiben(os.path.join(VORSCHAU, "blog", a["slug"], "index.html"),
                  filtern(artikel_seite(a, liste, heute), "9999-12-31"))
        for endung in (".svg", ".jpg"):
            quelle = os.path.join(WEBSITE, "blog", "_artikel", "titel", a["slug"] + endung)
            ziel = os.path.join(VORSCHAU, "blog", "titel", a["slug"] + endung)
            os.makedirs(os.path.dirname(ziel), exist_ok=True)
            if os.path.exists(quelle):
                shutil.copy2(quelle, ziel)
    schreiben(os.path.join(VORSCHAU, "blog", "index.html"), filtern(uebersicht(liste, heute), "9999-12-31"))
    schreiben(os.path.join(VORSCHAU, "blog", "feed.xml"), feed_text(liste))
    schreiben(os.path.join(VORSCHAU, "sitemap.xml"), sitemap_text(sitemap_eintraege(liste, seiten)))
    schreiben(os.path.join(VORSCHAU, "llms.txt"), "\n".join(llms_kopf(seiten)))
    schreiben(os.path.join(VORSCHAU, "404.html"), seite_404())
    landingpages_bauen(VORSCHAU, seiten)
    aufraeumen(VORSCHAU, {a["slug"] for a in liste}, seiten)


def vorschau_vorbereiten():
    """Spiegel der Website aus Verknuepfungen, damit /schrift, /wortmarke.svg usw. aufloesen."""
    os.makedirs(os.path.join(VORSCHAU, "blog"), exist_ok=True)
    for name in os.listdir(WEBSITE):
        if name in ("blog", "sitemap.xml", "llms.txt") or name.startswith("."):
            continue
        link = os.path.join(VORSCHAU, name)
        if not os.path.lexists(link):
            os.symlink(os.path.join(WEBSITE, name), link)
    link = os.path.join(VORSCHAU, "blog", "bilder")
    if not os.path.lexists(link):
        os.symlink(BILDER, link)


def main():
    global SEITEN
    args = sys.argv[1:]
    heute = dt.datetime.now(ZONE).date()
    try:
        artikel = artikel_laden()
        seiten = artikel_laden(SEITEN_QUELLEN, seiten=True)
    except (ValueError, OSError) as fehler:
        sys.exit(f"Abbruch: {fehler}")
    SEITEN = seiten
    bauen_live(artikel, seiten)
    kuenftig = sorted(a["datum"].isoformat() + "  " + a["slug"] for a in artikel if a["datum"] > heute)
    print(f"Stand {heute}: {len(artikel) - len(kuenftig)} faellig, {len(kuenftig)} erscheinen spaeter von selbst, "
          f"{len(seiten)} Landingpages.")
    for k in kuenftig:
        print("  ab " + k)
    if "--vorschau" in args:
        bauen_vorschau(artikel, seiten, heute)
        print(f"Vorschau: {VORSCHAU}\n"
              f"  ansehen: python3 {os.path.join(HIER, 'website-server.py')} 8789 {VORSCHAU}\n"
              f"  dann http://127.0.0.1:8789/blog/")
    print("Hochladen: python3 " + os.path.join(HIER, "website-hochladen.py") + " --nur-geaendert")
    if warnungen:
        print(f"{len(warnungen)} Warnung(en).", file=sys.stderr)


if __name__ == "__main__":
    main()
