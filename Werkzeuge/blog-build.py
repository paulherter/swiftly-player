#!/usr/bin/env python3
"""Builds the blog of swiftlyplayer.com from Markdown.

Sources:  Website/blog/quellen/<slug>.md
          Website/seiten/quellen/<name>.md  (landing pages, front matter plus `pfad:`)
Output:   Website/blog/_artikel/  finished HTML of ALL articles, artikel.json,
                                  cover images, lib.php (blocked via .htaccess)
          Website/blog/*.php      article, index, feed.xml, sitemap.xml,
                                  llms.txt, cover images: filtered at runtime
          Website/<pfad>/index.html  landing pages (visible immediately)

The website publishes itself: PHP on the web host serves an article only from
its `datum` (Europe/Berlin) on, 404 before that. No Mac, no schedule. PHP
reports newly due articles to IndexNow once. Upload after every build:
  website-upload.py --nur-geaendert

  blog-build.py              build Website/ (all articles, protected)
  blog-build.py --vorschau   additionally a static preview with all articles
                             outside Website/ (never uploaded);
                             view with: website-server.py 8789 <folder>
Cover images: SVG with outlines from blog-font.json (blog-font.swift),
rasterized with sips (macOS). Images in the text live in Website/blog/bilder/.

Front matter of every source (mandatory):
  ---
  titel: ...
  beschreibung: ...          # <= 155 characters
  datum: 2026-09-22
  slug: best-jellyfin-client-linux
  schlagworte: [jellyfin, linux, clients]
  offenlegung: ja
  aktualisiert: 2026-09-22   # optional
  ---
Markdown: # to ####, paragraphs, - / 1. lists (indented = nested), tables,
``` code, > quote, ---, **bold**, *italic*, `code`, [Link](url),
![Alt](file.webp "Caption | Source: ...") on its own line = figure.
Special block `:::swiftly` ... `:::`. `## FAQ` with `### Question` also
produces FAQPage JSON-LD.

No third-party packages, runs with /usr/bin/python3 (3.9) because launchd uses
exactly that. No raw HTML in the sources: everything is escaped.
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

# The supporter switch lives in download-pages/parts.py, one place for the whole site.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "download-pages"))
from parts import SUPPORTER_ON, SUPPORTER_PATH, SUPPORTER_LINK

# The one page shell and the shared components (kit design).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import web_parts
import web_shell

HERE = os.path.dirname(os.path.abspath(__file__))
WEBSITE = os.environ.get("SWIFTLY_WEBSITE") or os.path.normpath(os.path.join(HERE, "..", "Website"))
SOURCES = os.path.join(WEBSITE, "blog", "quellen")
PAGES_SOURCES = os.path.join(WEBSITE, "seiten", "quellen")
IMAGES = os.path.join(WEBSITE, "blog", "bilder")
PREVIEW = os.path.expanduser("~/Library/Caches/swiftly-blog-vorschau")

DOMAIN = "https://swiftlyplayer.com"
HERAUSGEBER = "Swiftly Player"          # never a person's name on an article
APP_ID = "6806824067"
APP_STORE = "https://apps.apple.com/app/id6806824067"
GITHUB = "https://github.com/paulherter/swiftly-player"
RELEASES = GITHUB + "/releases"
# Each platform has its own page with steps and sketches; the buttons link there rather than directly to the store.
APPLE_PAGE = "/download/app-store/"
WINDOWS = "/download/windows/"
LINUX = "/download/linux/"
ANDROID = "/android/"
TESTFLIGHT_PAGE = "/download/testflight/"
DISCORD = "https://discord.gg/MeGwfv3UwN"
MARKER = '<meta name="generator" content="blog-bauen">'
DISCLOSURE = ("<strong>Disclosure:</strong> we build Swiftly Player, one of the clients in this "
               "article. We point out where other apps do better.")
ZONE = ZoneInfo("Europe/Berlin")
MONATE = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]

warnungen = []


def warn(text):
    warnungen.append(text)
    print("Warnung: " + text, file=sys.stderr)


# ------------------------------------------------------------------ Sources

def header_read(text, file):
    if not text.startswith("---"):
        raise ValueError(f"{file}: Kopf fehlt (erste Zeile muss --- sein)")
    rows = text.split("\n")
    end = next((i for i in range(1, len(rows)) if rows[i].strip() == "---"), None)
    if end is None:
        raise ValueError(f"{file}: Kopf nicht mit --- geschlossen")
    header = {}
    for z in rows[1:end]:
        if not z.strip() or z.lstrip().startswith("#"):
            continue
        if ":" not in z:
            raise ValueError(f"{file}: Kopfzeile ohne Doppelpunkt: {z!r}")
        k, v = z.split(":", 1)
        v = re.sub(r"\s+#.*$", "", v).strip()          # trailing comment
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if v.startswith("[") and v.endswith("]"):
            v = [t.strip().strip("\"'") for t in v[1:-1].split(",") if t.strip()]
        header[k.strip().lower()] = v
    return header, "\n".join(rows[end + 1:])


def date_read(value, field, file):
    try:
        return dt.date.fromisoformat(str(value))
    except ValueError:
        raise ValueError(f"{file}: {field} ist kein Datum JJJJ-MM-TT: {value!r}")


def article_load(folder=SOURCES, pages=False):
    """Blog articles, or with seiten=True landing pages (additionally `pfad:`, no date filter)."""
    article = []
    if not os.path.isdir(folder):
        return article
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".md") or name.startswith("_"):
            continue
        path = os.path.join(folder, name)
        with open(path, encoding="utf-8") as h:
            header, body = header_read(h.read().replace("\r\n", "\n"), name)
        for field in ("titel", "beschreibung", "datum", "slug"):
            if not header.get(field):
                raise ValueError(f"{name}: Feld '{field}' fehlt")
        slug = header["slug"]
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug):
            raise ValueError(f"{name}: slug nur a-z, 0-9 und Bindestriche: {slug!r}")
        if name[:-3] != slug and not name.startswith("_"):
            warn(f"{name}: Dateiname und slug '{slug}' weichen ab")
        if len(header["beschreibung"]) > 155:
            warn(f"{name}: beschreibung hat {len(header['beschreibung'])} Zeichen (> 155)")
        schlagworte = header.get("schlagworte") or []
        if isinstance(schlagworte, str):
            schlagworte = [s.strip() for s in schlagworte.split(",") if s.strip()]
        date = date_read(header["datum"], "datum", name)
        aktualisiert = date_read(header["aktualisiert"], "aktualisiert", name) if header.get("aktualisiert") else None
        blocks = blocks_read(body.split("\n"))
        if re.search(r"^\W*disclosure\b", body, re.I | re.M):
            warn(f"{name}: eigener 'Disclosure'-Absatz im Text; der Kasten kommt schon aus 'offenlegung: ja'")
        article.append({
            "datei": name, "titel": header["titel"], "beschreibung": header["beschreibung"],
            "datum": date, "aktualisiert": aktualisiert if aktualisiert and aktualisiert > date else None,
            "slug": slug, "schlagworte": [s.lower() for s in schlagworte],
            "offenlegung": str(header.get("offenlegung", "nein")).lower() in ("ja", "yes", "true", "1"),
            "bloecke": blocks, "woerter": len(re.findall(r"\w+", body)),
            "url": f"{DOMAIN}/blog/{slug}/", "pfad": f"/blog/{slug}/", "seite": pages,
            "bild": f"/blog/titel/{slug}.jpg", "kategorie": header.get("kategorie") or "",
            # index: nein -> noindex, not in sitemap and llms.txt; the page stays available to readers.
            "index": str(header.get("index", "ja")).lower() not in ("nein", "no", "false", "0"),
        })
        if pages:
            target = str(header.get("pfad") or "")
            if not re.fullmatch(r"/[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)*/", target) \
                    or target.split("/")[1] in ("blog", "bilder", "aufnahmen", "schrift", "android", "seiten"):
                raise ValueError(f"{name}: pfad fehlt oder ist nicht erlaubt: {target!r} (Form /jellyfin-client-apple-tv/)")
            trunk = target.strip("/").split("/")[-1].replace("jellyfin-client-", "")
            short = header.get("kurzname") or " and ".join(
                {"tv": "TV", "iphone": "iPhone", "ipad": "iPad", "mac": "Mac", "macos": "macOS"}.get(w, w.title())
                for w in trunk.split("-")).replace("Android and TV", "Android TV").replace("Apple and TV", "Apple TV")
            article[-1].update({"pfad": target, "url": DOMAIN + target, "bild": target + "titelbild.jpg", "kurzname": short})
    double = {a["slug"] for a in article if sum(b["slug"] == a["slug"] for b in article) > 1}
    if double:
        raise ValueError(f"slug doppelt vergeben: {sorted(double)}")
    return article


# ------------------------------------------------------------------ Markdown

def e(text):
    return html.escape(text, quote=True)


def identifier(text):
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
    fromValue, pos = [], 0
    for m in INLINE.finditer(text):
        fromValue.append(e(text[pos:m.start()]))
        if m.group("code"):
            fromValue.append(f"<code>{e(m.group('codetext').strip())}</code>")
        elif m.group("bild") is not None:
            fromValue.append(image_tag(m.group("bild"), m.group("alt")))
        elif m.group("link") is not None:
            fromValue.append(f"<a{link_attr(m.group('link'))}>{inline(m.group('linktext'))}</a>")
        elif m.group("auto"):
            fromValue.append(f"<a{link_attr(m.group('auto'))}>{e(m.group('auto'))}</a>")
        elif m.group("fett") is not None:
            fromValue.append(f"<strong>{inline(m.group('fett'))}</strong>")
        else:
            fromValue.append(f"<em>{inline(m.group('kursiv') or m.group('kursiv2'))}</em>")
        pos = m.end()
    fromValue.append(e(text[pos:]))
    return "".join(fromValue)


def paragraph_inline(rows):
    parts = []
    for i, z in enumerate(rows):
        wrap = i < len(rows) - 1 and (z.endswith("  ") or z.endswith("\\"))
        z = z.rstrip()
        if z.endswith("\\"):
            z = z[:-1]
        parts.append(inline(z.strip()) + ("<br>" if wrap else ""))
    return "\n".join(parts)


def image_metrics(path):
    """Width, height from SVG (viewBox), PNG, WebP or JPEG; None if unreadable."""
    try:
        with open(path, "rb") as h:
            header = h.read(4096) if not path.endswith(".jpg") and not path.endswith(".jpeg") else h.read()
    except OSError:
        return None
    if path.endswith(".svg"):
        m = re.search(rb'viewBox="\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)', header)
        return (round(float(m.group(1))), round(float(m.group(2)))) if m else None
    if header[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", header[16:24])
    if header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        art = header[12:16]
        if art == b"VP8X":
            return (1 + int.from_bytes(header[24:27], "little"), 1 + int.from_bytes(header[27:30], "little"))
        if art == b"VP8 ":
            b, h_ = struct.unpack("<HH", header[26:30])
            return (b & 0x3FFF, h_ & 0x3FFF)
        if art == b"VP8L":
            n = int.from_bytes(header[21:25], "little")
            return ((n & 0x3FFF) + 1, ((n >> 14) & 0x3FFF) + 1)
    if header[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(header):
            if header[i] != 0xFF:
                i += 1
                continue
            mark, length = header[i + 1], struct.unpack(">H", header[i + 2:i + 4])[0]
            if mark in (0xC0, 0xC1, 0xC2):
                h_, b = struct.unpack(">HH", header[i + 5:i + 9])
                return (b, h_)
            i += 2 + length
    return None


def image_source(src):
    """'file.webp' -> /blog/bilder/file.webp. Third-party images are not allowed (copyright)."""
    if src.startswith("http"):
        warn(f"Bild aus dem Netz: {src} (nur eigene Bilder unter blog/bilder/)")
        return src, None
    if src.startswith("/"):
        return src, os.path.join(WEBSITE, src.lstrip("/"))
    return "/blog/bilder/" + src, os.path.join(IMAGES, src)


def image_tag(src, alt):
    url, file = image_source(src)
    metrics = image_metrics(file) if file else None
    if file and metrics is None:
        warn(f"Bild fehlt oder unlesbar: {src}")
    size = f' width="{metrics[0]}" height="{metrics[1]}"' if metrics else ""
    up = " hoch" if metrics and metrics[1] > metrics[0] else ""
    return f'<img class="abbildung{up}" src="{e(url)}" alt="{e(alt)}"{size} loading="lazy" decoding="async">'


IMAGE_LINE = re.compile(r'^!\[(?P<alt>[^\]]*)\]\((?P<bild>[^)\s]+)(?:\s+"(?P<titel>[^"]*)")?\)$')


def mapping(m):
    """Caption 'Text | Source: ...' -> text plus a subdued source credit."""
    under = ""
    if m.group("titel"):
        text, _, source = m.group("titel").partition(" | ")
        under = inline(text.strip())
        if source.strip():
            under += f' <span class="quelle">{inline(source.strip())}</span>'
        under = f"<figcaption>{under}</figcaption>"
    return f"<figure>{image_tag(m.group('bild'), m.group('alt'))}{under}</figure>"


LIST = re.compile(r"^( *)([-*+]|\d+[.)])\s+(.*)$")
TABLE_SEPARATOR = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def cells(row):
    z = row.strip()
    if z.startswith("|"):
        z = z[1:]
    if z.endswith("|") and not z.endswith("\\|"):
        z = z[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", z)]


def is_block_start(z):
    s = z.strip()
    return (s.startswith("#") and re.match(r"^#{1,6}\s", s)) or s.startswith("```") \
        or s.startswith(">") or s.startswith(":::") or LIST.match(z) \
        or re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", s)


def blocks_read(rows):
    """Lines -> list of blocks (dicts). No HTML here."""
    blocks, i, n = [], 0, len(rows)
    while i < n:
        z = rows[i]
        s = z.strip()
        if not s:
            i += 1
            continue
        if s.startswith("```"):
            language = s[3:].strip()
            i += 1
            code = []
            while i < n and not rows[i].strip().startswith("```"):
                code.append(rows[i])
                i += 1
            i += 1
            blocks.append({"art": "code", "sprache": language, "text": "\n".join(code)})
            continue
        if s.lower().startswith(":::swiftly"):
            i += 1
            inner, depth = [], 1
            while i < n:
                t = rows[i].strip()
                if t.startswith(":::") and t != ":::":
                    depth += 1
                elif t == ":::":
                    depth -= 1
                    if depth == 0:
                        break
                inner.append(rows[i])
                i += 1
            i += 1
            blocks.append({"art": "swiftly", "kinder": blocks_read(inner)})
            continue
        m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", s)
        if m:
            blocks.append({"art": "ueberschrift", "stufe": len(m.group(1)), "text": m.group(2)})
            i += 1
            continue
        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", s):
            blocks.append({"art": "linie"})
            i += 1
            continue
        if s.startswith(">"):
            inner = []
            while i < n and rows[i].strip().startswith(">"):
                inner.append(re.sub(r"^\s*>\s?", "", rows[i]))
                i += 1
            blocks.append({"art": "zitat", "kinder": blocks_read(inner)})
            continue
        if "|" in s and i + 1 < n and TABLE_SEPARATOR.match(rows[i + 1]) and rows[i + 1].count("-") >= 2:
            header = cells(z)
            alignment = []
            for c in cells(rows[i + 1]):
                alignment.append("center" if c.startswith(":") and c.endswith(":")
                                   else "right" if c.endswith(":") else "left" if c.startswith(":") else "")
            i += 2
            rails = []
            while i < n and rows[i].strip() and "|" in rows[i]:
                rails.append(cells(rows[i]))
                i += 1
            blocks.append({"art": "tabelle", "kopf": header, "ausrichtung": alignment, "reihen": rails})
            continue
        m = LIST.match(z)
        if m:
            inset = len(m.group(1))
            geordnet = m.group(2)[0].isdigit()
            start = int(re.match(r"\d+", m.group(2)).group()) if geordnet else 1
            points = []
            while i < n:
                m = LIST.match(rows[i])
                if m and len(m.group(1)) <= inset + 1 and m.group(2)[0].isdigit() == geordnet:
                    points.append([m.group(3)])
                    i += 1
                    continue
                if m and len(m.group(1)) <= inset + 1:
                    break                                   # different list type
                if not rows[i].strip():
                    # blank line: the list continues if an indented line or a new item follows
                    j = i + 1
                    while j < n and not rows[j].strip():
                        j += 1
                    if j < n and points and (rows[j].startswith(" " * (inset + 2))
                                             or (LIST.match(rows[j]) and len(LIST.match(rows[j]).group(1)) <= inset + 1
                                                 and LIST.match(rows[j]).group(2)[0].isdigit() == geordnet)):
                        points[-1].append("")
                        i = j
                        continue
                    break
                if rows[i].startswith(" " * (inset + 2)) or (points and not is_block_start(rows[i])):
                    points[-1].append(rows[i][inset + 2:] if rows[i].startswith(" " * (inset + 2)) else rows[i].strip())
                    i += 1
                    continue
                break
            blocks.append({"art": "liste", "geordnet": geordnet, "start": start,
                            "punkte": [blocks_read(p) for p in points],
                            "eng": all("" not in p for p in points)})
            continue
        paragraph = []
        while i < n and rows[i].strip() and not (paragraph and is_block_start(rows[i])):
            if "|" in rows[i] and i + 1 < n and TABLE_SEPARATOR.match(rows[i + 1]) and paragraph:
                break
            paragraph.append(rows[i])
            i += 1
        blocks.append({"art": "absatz", "zeilen": paragraph})
    return blocks


def render(blocks, narrow=False, vergebene=None):
    vergebene = vergebene if vergebene is not None else set()
    fromValue = []
    for b in blocks:
        art = b["art"]
        if art == "absatz":
            imageLine = IMAGE_LINE.match(b["zeilen"][0].strip()) if len(b["zeilen"]) == 1 else None
            if imageLine:
                fromValue.append(mapping(imageLine))
                continue
            content = paragraph_inline(b["zeilen"])
            fromValue.append(content if narrow else f"<p>{content}</p>")
        elif art == "ueberschrift":
            level = b["stufe"]
            if level == 1:
                warn("'# ' im Artikel: der Titel kommt aus dem Kopf, gesetzt als h2")
                level = 2
            k, base, figure = identifier(b["text"]), identifier(b["text"]), 2
            while k in vergebene:
                k, figure = f"{base}-{figure}", figure + 1
            vergebene.add(k)
            fromValue.append(f'<h{level} id="{k}">{inline(b["text"])}</h{level}>')
        elif art == "code":
            kind = f' class="language-{e(b["sprache"])}"' if b["sprache"] else ""
            # The box carries the copy button that the script inserts (without the script a button that does nothing would show). For a command, a note below says what to do with it, since not everyone knows a one-liner belongs in a terminal.
            schale = f'<div class="codeblock"><pre><code{kind}>{e(b["text"])}</code></pre></div>'
            if b["sprache"] in ("sh", "bash", "shell", "zsh", "console"):
                schale += '<p class="befehlszeile">Paste it into a terminal and press Enter.</p>'
            fromValue.append(schale)
        elif art == "linie":
            fromValue.append("<hr>")
        elif art == "zitat":
            fromValue.append(f"<blockquote>{render(b['kinder'], vergebene=vergebene)}</blockquote>")
        elif art == "tabelle":
            def cell(tag, text, column):
                a = b["ausrichtung"][column] if column < len(b["ausrichtung"]) else ""
                style = f' style="text-align:{a}"' if a else ""
                return f"<{tag}{style}>{inline(text)}</{tag}>"
            header = "".join(cell("th", t, j) for j, t in enumerate(b["kopf"]))
            rails = "".join("<tr>" + "".join(cell("td", r[j] if j < len(r) else "", j)
                                              for j in range(len(b["kopf"]))) + "</tr>" for r in b["reihen"])
            fromValue.append(f'<div class="tabelle"><table><thead><tr>{header}</tr></thead><tbody>{rails}</tbody></table></div>')
        elif art == "liste":
            tag = "ol" if b["geordnet"] else "ul"
            start = f' start="{b["start"]}"' if b["geordnet"] and b["start"] != 1 else ""
            points = "".join(f"<li>{render(p, narrow=b['eng'], vergebene=vergebene)}</li>" for p in b["punkte"])
            fromValue.append(f"<{tag}{start}>{points}</{tag}>")
        elif art == "swiftly":
            fromValue.append(swiftly_box(render(b["kinder"], vergebene=vergebene)))
        elif art == "kurz":
            k = identifier(b["titel"])
            vergebene.add(k)
            fromValue.append(f'<section class="kurz" aria-labelledby="{k}"><h2 id="{k}">{inline(b["titel"])}</h2>'
                       f'{render(b["kinder"], vergebene=vergebene)}</section>')
        elif art == "faq":
            ask = []
            for n, (question, response) in enumerate(b["paare"]):
                k, base, figure = identifier(question), identifier(question), 2
                while k in vergebene:
                    k, figure = f"{base}-{figure}", figure + 1
                vergebene.add(k)
                opened = " open" if n == 0 else ""
                ask.append(f'<details class="frage" id="{k}"{opened}><summary class="frage__knopf">'
                              f'<h3>{inline(question)}</h3>{ARROW}</summary>'
                              f'<div class="frage__antwort">{render(response, vergebene=vergebene)}</div></details>')
            fromValue.append(f'<div class="fragen__blatt">{"".join(ask)}</div>')
    return "\n".join(fromValue)


FIND_TITLE = ("faq", "faqs", "frequently asked questions")


def structure(blocks):
    """## FAQ -> sheet with collapsible questions as on the home page,
    ## TL;DR -> short box. Everything else stays as it is."""
    fromValue, i = [], 0
    while i < len(blocks):
        b = blocks[i]
        title = b.get("text", "").strip().lower() if b["art"] == "ueberschrift" and b["stufe"] <= 2 else None
        if title in FIND_TITLE or title in ("tl;dr", "tldr", "in short"):
            j = i + 1
            while j < len(blocks) and not (blocks[j]["art"] == "ueberschrift" and blocks[j]["stufe"] <= 2):
                j += 1
            part = blocks[i + 1:j]
            if title in FIND_TITLE:
                intro, pairs = [], []
                for c in part:
                    if c["art"] == "ueberschrift" and c["stufe"] == 3:
                        pairs.append((c["text"], []))
                    elif pairs:
                        pairs[-1][1].append(c)
                    else:
                        intro.append(c)
                fromValue += [b] + intro + [{"art": "faq", "paare": pairs}]
            else:
                fromValue.append({"art": "kurz", "titel": b["text"], "kinder": part})
            i = j
            continue
        fromValue.append(b)
        i += 1
    return fromValue


ARROW = '<svg class="frage__pfeil" aria-hidden="true"><use href="#ph-b-caret-right"/></svg>'


def plain_text(blocks):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", render(blocks)))).strip()


def find_faq(blocks):
    """## FAQ -> [(question, answer text)] up to the next h2."""
    pairs, inside, question, response = [], False, None, []
    for b in blocks + [{"art": "ueberschrift", "stufe": 2, "text": ""}]:
        if b["art"] == "ueberschrift" and b["stufe"] <= 3:
            if question and response:
                pairs.append((html.unescape(re.sub(r"<[^>]+>", "", inline(question))), plain_text(response)))
            question, response = None, []
            if b["stufe"] <= 2:
                inside = b["text"].strip().lower() in ("faq", "faqs", "frequently asked questions")
            elif inside:
                question = b["text"]
            continue
        if inside and question:
            response.append(b)
    return pairs


# ------------------------------------------------------------------ Template

def date_text(d):
    return f"{d.day} {MONATE[d.month - 1]} {d.year}"


def swiftly_box(content):
    # Short: the buttons are already in the sidebar (#laden).
    return f"""<aside class="swiftly" aria-label="Swiftly Player">
<p class="swiftly__marke"><img src="/symbol.svg" alt="" width="22" height="22">Swiftly Player</p>
{content}
<p class="swiftly__weiter"><a href="#laden">Get Swiftly Player</a></p>
</aside>"""


SKRIPT = """(function () {
  /* Copy button on every code box, with visible confirmation. */
  document.querySelectorAll(".codeblock").forEach(function (kasten) {
    var code = kasten.querySelector("code");
    if (!code || !navigator.clipboard) return;
    var b = document.createElement("button");
    b.type = "button"; b.className = "sw-btn sw-btn--sm sw-btn--secondary pb-copy"; b.textContent = "Copy";
    var t = 0;
    b.addEventListener("click", function () {
      navigator.clipboard.writeText(code.textContent).then(function () { b.textContent = "Copied"; }, function () { b.textContent = "Press Cmd C"; });
      clearTimeout(t); t = setTimeout(function () { b.textContent = "Copy"; }, 2000);
    });
    kasten.appendChild(b);
  });
})();"""



def json_ld(data):
    # "</" in the JSON would close the script element.
    return ('<script type="application/ld+json">\n'
            + json.dumps(data, ensure_ascii=False, indent=2).replace("</", "<\\/")
            + "\n</script>")


PAGES = []          # landing pages, filled by main(); the footer links them


# The footer links the guides listed in the index, not the per-platform landing pages: they look too similar to each other (doorway pages).
FOOTER_GUIDES = [("/blog/best-jellyfin-client/", "Best Jellyfin client"),
               ("/blog/best-jellyfin-client-apple-tv/", "Apple TV"),
               ("/blog/best-jellyfin-client-iphone/", "iPhone"),
               ("/blog/jellyfin-android-tv-clients-compared/", "Android TV"),
               ("/blog/best-jellyfin-client-mac/", "Mac"),
               ("/blog/why-is-jellyfin-transcoding/", "Why it transcodes")]


ORGANISATION = {"@type": "Organization", "name": HERAUSGEBER, "url": DOMAIN + "/",
                "logo": {"@type": "ImageObject", "url": DOMAIN + "/apple-touch-icon.png"}}


def download_band():
    """The download band at the end of every article (id "laden": the article callout links to it)."""
    stores = [
        ("apple", APP_STORE, "si-appstore", "App Store", "iPhone, iPad, Apple TV and Mac", "iOS 18 · tvOS 18 · macOS 15", True, ""),
        ("android", "https://play.google.com/store/apps/details?id=de.paulherter.swiftly", "si-googleplay", "Google Play",
         "Android and Android TV", "Android 9 or newer", False, ""),
        ("desktop", GITHUB + "/releases/latest", "si-github", "GitHub", "Windows and Linux",
         "Windows 10 (64-bit) · apt, dnf, pacman, zypper", False, ""),
    ]
    return web_parts.band(["Get Swiftly", "Player."], "Free. Open source. No ads.", stores,
                          "Plex and Emby: beta. Jellyfin 10.8 or newer.", ident="laden") + "\n"


def page(title, description, url, content, og_type="website", addition_header="", ld=(), robots="",
          image=None, image_old=None, blog_active=True):
    """Whole page: this module writes head lines and content, web_shell.py wraps bar, nav, footer and scripts.
    The icon sprite is not inlined: lib.php pastes it in at runtime (<!--sw:sprite-->), so the articles stay small."""
    image_url = DOMAIN + image if image else DOMAIN + "/vorschau.jpg"
    image_old = image_old or "iPad, iPhone and an Apple TV, all showing Swiftly Player"
    kanonisch = f'<link rel="canonical" href="{e(url)}">\n' if url else ""
    head = f"""<title>{e(title)}</title>
<meta name="description" content="{e(description)}">
{robots}{kanonisch}<meta name="author" content="{HERAUSGEBER}">
<meta name="apple-itunes-app" content="app-id={APP_ID}">
<meta property="og:title" content="{e(title)}">
<meta property="og:description" content="{e(description)}">
<meta property="og:url" content="{e(url or DOMAIN + '/blog/')}">
<meta property="og:type" content="{og_type}">
<meta property="og:site_name" content="Swiftly Player">
<meta property="og:image" content="{e(image_url)}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{e(image_old)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{e(title)}">
<meta name="twitter:description" content="{e(description)}">
<meta name="twitter:image" content="{e(image_url)}">
<meta name="theme-color" content="#101010">
{addition_header}<link rel="alternate" type="application/rss+xml" title="Swiftly Player blog" href="/blog/feed.xml">
<link rel="icon" href="/symbol.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
{MARKER}
{chr(10).join(ld)}"""
    doc = web_shell.page(head, content + download_band(), css="pages-blog.css", scripts=f"<script>\n{SKRIPT}\n</script>")
    return doc.replace(web_shell.sprite(), "<!--sw:sprite-->", 1)

# ------------------------------------------------------------------ Due dates
# Blocks that may only become visible from a certain date sit between
#   <!--f:GRUPPE:JJJJ-MM-TT--> ... <!--/f:GRUPPE-->
# and <!--wennvoll:GRUPPE--> / <!--wennleer:GRUPPE--> depend on whether anything
# was left over. PHP (lib.php) does exactly the same at runtime.
LIMITS = {"rel": 3}


def gated(group, date, content):
    return f"<!--f:{group}:{date.isoformat()}-->{content}<!--/f:{group}-->"


def filter(text, heute_iso):
    figure = {}

    def block(m):
        group, date = m.group(1), m.group(2)
        if date > heute_iso or figure.get(group, 0) >= LIMITS.get(group, 10 ** 9):
            return ""
        figure[group] = figure.get(group, 0) + 1
        return m.group(3)
    text = re.sub(r"<!--f:(\w+):(\d{4}-\d{2}-\d{2})-->(.*?)<!--/f:\1-->", block, text, flags=re.S)
    text = re.sub(r"<!--wennvoll:(\w+)-->(.*?)<!--/wennvoll:\1-->",
                  lambda m: m.group(2) if figure.get(m.group(1)) else "", text, flags=re.S)
    return re.sub(r"<!--wennleer:(\w+)-->(.*?)<!--/wennleer:\1-->",
                  lambda m: "" if figure.get(m.group(1)) else m.group(2), text, flags=re.S)


# ------------------------------------------------------------------ Cover image

_font = None


def font(weight):
    global _font
    if _font is None:
        with open(os.path.join(HERE, "blog-font.json"), encoding="utf-8") as h:
            _font = json.load(h)
    return _font[str(weight)]


def text_width(text, weight, size, lock=0.0):
    t = font(weight)
    b = 0.0
    for i, z in enumerate(text):
        b += (t.get(z) or t[" "])["v"]
        if i + 1 < len(text):
            b += t["_kern"].get(z + text[i + 1], 0) + lock * 1000
    return b * size / 1000


def text_outline(text, weight, size, x, y, color, lock=0.0):
    """Text as paths: sips does not support web fonts."""
    t = font(weight)
    parts, ox = [], 0.0
    for i, z in enumerate(text):
        g = t.get(z)
        if g is None:
            warn(f"Titelbild: Zeichen {z!r} fehlt in blog-font.json")
            g = t[" "]
        if g["d"]:
            parts.append(f'<path transform="translate({ox:.1f} 0)" d="{g["d"]}"/>')
        ox += g["v"]
        if i + 1 < len(text):
            ox += t["_kern"].get(z + text[i + 1], 0) + lock * 1000
    return f'<g transform="translate({x:.1f} {y:.1f}) scale({size / 1000:.4f})" fill="{color}">{"".join(parts)}</g>'


TAG_NAMES = {"android tv": "Android TV", "google tv": "Google TV", "intro skipper": "Intro Skipper",
                    "syncplay": "SyncPlay", "quick connect": "Quick Connect", "12.0": "Jellyfin 12",
                    "apple tv": "Apple TV", "windows": "Windows", "linux": "Linux", "macos": "macOS",
                    "ios": "iPhone", "ipad": "iPad", "multi-device": "Multi-device",
                    "iphone": "iPhone", "fire tv": "Fire TV", "samsung tv": "Samsung TV", "lg tv": "LG TV",
                    "mkv": "MKV", "hdr": "HDR", "dolby vision": "Dolby Vision", "atmos": "Atmos",
                    "truehd": "TrueHD", "dts": "DTS", "picture in picture": "Picture in Picture",
                    "pip": "Picture in Picture", "nas": "NAS", "seerr": "Seerr", "docker": "Docker",
                    "mac": "Mac", "tvos": "tvOS", "vs": "Comparison", "plex": "Plex vs Emby"}


def schlagwort_name(s):
    """Known names as written, otherwise every word capitalized; abbreviations stay."""
    if s in TAG_NAMES:
        return TAG_NAMES[s]
    return " ".join(w.upper() if len(w) <= 3 and w.isalpha() and w not in ("and", "for", "the") else w.capitalize()
                    for w in s.split())


def kategorie(a):
    if a.get("kategorie"):
        return a["kategorie"]
    for s in a["schlagworte"]:
        if s not in ("jellyfin", "clients"):
            return schlagwort_name(s)
    return "Jellyfin"


def tag_name(a):
    """Label on cards and article heads: the start-here guide is just 'Guide', not its first keyword."""
    return "Guide" if a["slug"] == LEITARTIKEL else kategorie(a)


def title_svg(a):
    random = hashlib.sha1(a["slug"].encode()).digest()

    def play(i, span):
        return (random[i] / 255 - .5) * span
    size = 78
    while True:
        rows, akt = [], ""
        for word in a["titel"].split():
            probe = (akt + " " + word).strip()
            if akt and text_width(probe, 700, size) > 1050:
                rows.append(akt)
                akt = word
            else:
                akt = probe
        rows.append(akt)
        if len(rows) <= 3 or size <= 50:
            break
        size -= 2
    spacing = size * 1.1
    first = 520 - (len(rows) - 1) * spacing
    kat_y = first - size * .76 - 36

    def glow(n, cx, cy, r, color, strength):
        return (f'<radialGradient id="{n}" cx="{cx:.0f}" cy="{cy:.0f}" r="{r}" gradientUnits="userSpaceOnUse">'
                f'<stop offset="0" stop-color="{color}" stop-opacity="{strength}"/>'
                f'<stop offset=".55" stop-color="{color}" stop-opacity="{strength * .3:.3f}"/>'
                f'<stop offset="1" stop-color="{color}" stop-opacity="0"/></radialGradient>')
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">',
        "<defs>" + glow("a", 960 + play(0, 180), 90 + play(1, 100), 600, "#50D5DA", .34)
        + "</defs>",
        '<rect width="1200" height="630" fill="#101010"/>',
        '<rect width="1200" height="630" fill="url(#a)"/>',
        '<g transform="translate(72 64) scale(.0547)"><rect width="1024" height="1024" rx="230" fill="#17181b" '
        'stroke="#ffffff" stroke-opacity=".16" stroke-width="18"/><path fill="#50d5da" d="M440.1,280l285,163.2c38,'
        '21.7,51.2,70,29.6,108-7,12.3-17.2,22.5-29.6,29.6l-285,163.2c-37.9,21.8-86.3,8.6-108.1-29.3-6.9-12-10.5-25.6-'
        '10.5-39.4v-326.6c0-43.7,35.5-79.2,79.2-79.2,13.8,0,27.4,3.6,39.4,10.5Z"/></g>',
        text_outline("Swiftly Player", 600, 30, 144, 102, "#FFFFFF"),
        text_outline(kategorie(a).upper(), 700, 22, 74, kat_y, "#50D5DA", lock=.12),
    ]
    for i, z in enumerate(rows):
        parts.append(text_outline(z, 700, size, 70, first + i * spacing, "#FFFFFF"))
    address = "swiftlyplayer.com" + (a["pfad"].rstrip("/") if a["seite"] else "/blog")
    parts.append(text_outline(address, 600, 22, 74, 584, "#FFFFFF", lock=.01)
                 .replace('fill="#FFFFFF"', 'fill="#FFFFFF" fill-opacity=".5"'))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def title_write(a, folder, name):
    """Write the SVG; re-rasterize the 1200x630 JPEG only if the SVG changed."""
    svg = os.path.join(folder, name + ".svg")
    jpg = os.path.join(folder, name + ".jpg")
    new = write(svg, title_svg(a))
    if new or not os.path.exists(jpg):
        erg = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "86", svg, "--out", jpg],
                             capture_output=True, text=True)
        if erg.returncode != 0 or image_metrics(jpg) != (1200, 630):
            warn(f"Titelbild {name}.jpg: sips fehlgeschlagen ({erg.stderr.strip()[:200]})")
        else:
            print("gerastert    " + os.path.relpath(jpg, os.path.dirname(WEBSITE)))


# ------------------------------------------------------------------ Pages

def card(href, tag, date_iso, date_txt, title, desc, extra="", planned=""):
    """Article card of the kit (overview and 'Keep reading'). title and desc arrive already escaped."""
    return (f'<a class="sw-card{extra}" href="{href}"><span class="sw-card__body"><span class="sw-card__meta"><span class="sw-tag">{tag}</span>'
            f'<time class="sw-date" datetime="{date_iso}">{date_txt}</time>{planned}</span><h3>{title}</h3><p>{desc}</p>'
            f'<span class="sw-card__more">Read<svg aria-hidden="true"><use href="#ph-b-arrow-right"/></svg></span></span></a>')


def article_card(a, heute=None):
    planned = '<span class="sw-tag">Scheduled</span>' if heute and not a["seite"] and a["datum"] > heute else ""
    return card(a["pfad"], e(tag_name(a)), a["datum"].isoformat(), date_text(a["datum"]), e(a["titel"]), e(a["beschreibung"]),
                planned=planned)


# Three categories for the index. Visitors are looking for an app, have a playback problem, or are setting up a server.
CATEGORY = [
    ("kc", "clients", "Pick a client", "The best Jellyfin app for each device, compared with sources."),
    ("kw", "wiedergabe", "Fix playback", "Why a file transcodes, and how subtitles, HDR, audio and downloads behave."),
    ("ks", "server", "Run your server", "Install, update and extend Jellyfin, and reach it from outside."),
]
SERVER_PHRASES = ("docker", "synology", "set-up", "setup", "plugin", "remote", "hardware", "seerr", "unraid",
                "truenas", "raspberry", "backup", "naming", "metadata", "tailscale", "cloudflare", "caddy",
                "requirements", "12-whats-new", "vs-plex", "vs-kodi", "migrate", "live-tv", "iptv", "anime",
                "parental", "trakt", "collections")
LEITARTIKEL = "best-jellyfin-client"


# What most people look for comes first; the rest by date, newest first.
PRIORITY = ["best-jellyfin-client-apple-tv", "best-jellyfin-client-iphone", "jellyfin-android-tv-clients-compared",
           "best-jellyfin-client-android", "best-jellyfin-client-mac", "best-jellyfin-client-windows",
           "best-jellyfin-client-linux", "jellyfin-ipad-client", "best-jellyfin-client-fire-tv", "jellyfin-roku",
           "jellyfin-samsung-lg-tv", "swiftfin-alternatives", "infuse-alternatives-jellyfin",
           "why-is-jellyfin-transcoding", "jellyfin-mkv-iphone-apple-tv", "jellyfin-subtitles-guide",
           "jellyfin-dolby-vision-hdr", "jellyfin-atmos-truehd-passthrough",
           "how-to-set-up-jellyfin", "jellyfin-docker-compose-setup", "jellyfin-vs-plex-vs-emby"]


def priority(a):
    i = PRIORITY.index(a["slug"]) if a["slug"] in PRIORITY else len(PRIORITY)
    return (i, -a["datum"].toordinal(), a["slug"])


def category(a):
    if a.get("rubrik"):
        return a["rubrik"]
    slug = a["slug"]
    if any(w in slug for w in SERVER_PHRASES):
        return "server"
    if slug.startswith("best-jellyfin") or "clients" in slug or "alternatives" in slug or slug in (
            "jellyfin-ipad-client", "jellyfin-roku", "jellyfin-samsung-lg-tv"):
        return "clients"
    return "wiedergabe"


def leadCard(a):
    return (f'<section class="sw-section pb-lead" aria-label="Start here"><div class="sw-g">'
            f'<a class="sw-card sw-card--wide pb-feature" href="{a["pfad"]}"><img class="sw-card__media" src="/kit/assets/shots/mac-01-home.webp" alt="" width="1600" height="1000" loading="eager">'
            f'<span class="sw-card__body"><span class="sw-card__meta"><span class="sw-tag">Start here</span></span><h2>{e(a["titel"])}</h2><p>{e(a["beschreibung"])}</p>'
            f'<span class="sw-card__more">Read the guide<svg aria-hidden="true"><use href="#ph-b-arrow-right"/></svg></span></span></a></div></section>')


def related(a, all):
    """All others, best first. filtern() decides which of them appear."""
    other = [b for b in all if b["pfad"] != a["pfad"]]
    return sorted(other, key=lambda b: (len(set(a["schlagworte"]) & set(b["schlagworte"])), b["datum"]), reverse=True)


def breadcrumb(entries):
    return {"@context": "https://schema.org", "@type": "BreadcrumbList",
            "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": n, "item": u}
                                for i, (n, u) in enumerate(entries)]}


def sidebar(body, rel, rel_title="Keep reading"):
    """Table of contents (from three H2 on) and the 'Keep reading' cards."""
    content = re.findall(r'<h2 id="([^"]+)">(.*?)</h2>', body)
    toc = ""
    if len(content) >= 3:
        points = "".join(f'<li><a href="#{k}">{t}</a></li>' for k, t in content)
        toc = f'<nav class="pb-toc" aria-labelledby="pb-toc-t"><h2 id="pb-toc-t">On this page</h2><ol>{points}</ol></nav>'
    cards = "".join(gated("rel", b["datum"] if not b["seite"] else dt.date(2000, 1, 1),
                          card(b["pfad"], e(tag_name(b)), b["datum"].isoformat(), date_text(b["datum"]), e(b["titel"]),
                               html.escape(b["beschreibung"], quote=False)))
                    for b in rel)
    rel_html = (f'<!--wennvoll:rel--><section class="sw-section pb-related" aria-labelledby="pb-rel"><div class="sw-g"><h2 class="pb-h2" id="pb-rel">{rel_title}<i>.</i></h2>'
                f'<div class="sw-cards">{cards}</div></div></section><!--/wennvoll:rel-->\n')
    return toc, rel_html


def article_page(a, all, heute=None):
    """heute set = static preview (with a 'Preview' note), otherwise template for PHP."""
    vergebene = set()
    body = render(structure(a["bloecke"]), vergebene=vergebene)
    minutes = max(1, round(a["woerter"] / 230))
    planned = (f'<span class="sw-tag">Preview · goes live on {date_text(a["datum"])}</span>'
               if heute and not a["seite"] and a["datum"] > heute else "")
    dates = f'<time class="sw-date" datetime="{a["datum"].isoformat()}">{date_text(a["datum"])}</time>'
    if a["aktualisiert"]:
        dates += f'Updated <time class="sw-date" datetime="{a["aktualisiert"].isoformat()}">{date_text(a["aktualisiert"])}</time>'
    meta = f'<span class="sw-tag">{e(tag_name(a))}</span>{planned}{dates}<span class="sw-date">{minutes} min read</span>'
    opened = (f'<aside class="sw-callout pb-disclosure"><svg aria-hidden="true"><use href="#ph-f-info"/></svg><p>{DISCLOSURE}</p></aside>\n'
              if a["offenlegung"] else "")
    crumbs = '<li><a href="/">Swiftly Player</a></li>' + ('' if a["seite"] else '<li><a href="/blog/">Blog</a></li>')
    toc, rel_html = sidebar(body, related(a, all))
    # The "Swiftly Player" box from the :::swiftly block, in the kit's callout.
    body = re.sub(r'<aside class="swiftly" aria-label="Swiftly Player">\s*<p class="swiftly__marke">.*?</p>\s*(.*?)<p class="swiftly__weiter"><a href="#laden">Get Swiftly Player</a></p>\s*</aside>',
                  r'<aside class="sw-callout pb-swiftly" aria-label="Swiftly Player"><svg aria-hidden="true"><use href="#ph-f-play"/></svg><div><strong>Swiftly Player</strong>\1<p class="pb-swiftly__more"><a href="#laden">Get Swiftly Player</a></p></div></aside>',
                  body, flags=re.S)
    content = f"""<section class="sw-page-head sw-lines pb-head"><div class="sw-g">
  <div class="sw-page-head__crumbs"><ol class="sw-crumbs">{crumbs}</ol></div>
  <h1 class="sw-page-head__title pb-title">{e(a["titel"])}</h1>
  <p class="sw-page-head__sub">{e(a["beschreibung"])}</p>
  <div class="sw-page-head__meta"><div class="sw-dateline">{meta}</div></div>
</div></section>
<main id="inhalt" class="sw-section pb-article"><div class="sw-g">
{toc}
<article class="sw-prose pb-prose">
{opened}{body.strip()}
<p class="pb-back"><a class="sw-back" href="{'/' if a['seite'] else '/blog/'}"><svg aria-hidden="true"><use href="#ph-b-arrow-left"/></svg>{'Swiftly Player' if a['seite'] else 'All articles'}</a></p>
</article>
</div></main>
{rel_html}"""
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
    chain = [("Swiftly Player", DOMAIN + "/")] + ([] if a["seite"] else [("Blog", DOMAIN + "/blog/")]) + [(a["titel"], a["url"])]
    ld = [json_ld(posting), json_ld(breadcrumb(chain))]
    faq = find_faq(a["bloecke"])
    if faq:
        ld.append(json_ld({"@context": "https://schema.org", "@type": "FAQPage",
                           "mainEntity": [{"@type": "Question", "name": f,
                                           "acceptedAnswer": {"@type": "Answer", "text": t}} for f, t in faq]}))
    header = (f'<meta property="article:published_time" content="{a["datum"].isoformat()}">\n'
            f'<meta property="article:modified_time" content="{(a["aktualisiert"] or a["datum"]).isoformat()}">\n'
            f'<meta property="article:author" content="{HERAUSGEBER}">\n'
            + "".join(f'<meta property="article:tag" content="{e(t)}">\n' for t in a["schlagworte"]))
    robots = '<meta name="robots" content="noindex">\n' if planned else (
        "" if a["index"] else '<meta name="robots" content="noindex, follow">\n')
    return page(f'{a["titel"]} | Swiftly Player', a["beschreibung"], a["url"], content,
                 og_type="article", addition_header=header, ld=ld, robots=robots,
                 image=a["bild"], image_old=a["titel"], blog_active=not a["seite"])


def overview(list, heute=None):
    description = "Jellyfin guides: the best client for Apple TV, Android TV, iPhone, Mac, Windows and Linux, why files transcode, and server setup."
    lead = next((a for a in list if a["slug"] == LEITARTIKEL and not a["seite"]), None)
    top = gated("kf", lead["datum"], leadCard(lead)) if lead else ""
    rest = [a for a in list if a is not lead]
    jump = "".join(f'<a class="sw-btn sw-btn--sm sw-btn--secondary" href="#{anchor}">{title}</a>' for _, anchor, title, _ in CATEGORY)
    sections = ""
    for group, anchor, title, sentence in CATEGORY:
        cards = "".join(gated(group, a["datum"], article_card(a, heute))
                        for a in sorted((x for x in rest if category(x) == anchor), key=priority))
        sections += (f'<!--wennvoll:{group}--><section class="sw-section pb-topic" id="{anchor}" aria-labelledby="t-{anchor}"><div class="sw-g">'
                     f'<h2 class="pb-h2" id="t-{anchor}">{title}<i>.</i></h2><p class="pb-topic__intro">{sentence}</p><div class="sw-cards">{cards}</div></div></section><!--/wennvoll:{group}-->\n')
    empty = ('<!--wennleer:alle--><section class="sw-section"><div class="sw-g"><div class="pb-empty"><svg aria-hidden="true"><use href="#ph-f-calendar-blank"/></svg>'
             '<h2>No articles yet.</h2><p>The first guides are on their way. Until then, the download and the FAQ are on the home page.</p>'
             '<a class="sw-btn" href="/">Back to Swiftly Player<svg class="sw-tri" aria-hidden="true"><use href="#sw-tri"/></svg></a></div></div></section><!--/wennleer:alle-->')
    content = f"""<section class="sw-page-head sw-lines"><div class="sw-g">
  <div class="sw-page-head__crumbs"><ol class="sw-crumbs"><li><a href="/">Swiftly Player</a></li><li><span aria-current="page">Blog</span></li></ol></div>
  <h1 class="sw-page-head__title">Jellyfin guides and client comparisons<i>.</i></h1>
  <p class="sw-page-head__sub">Which Jellyfin client to use on which device, why a file transcodes, and how to set up the server around it. Written by the developer of Swiftly Player.</p>
  <div class="sw-page-head__meta"><nav class="pb-jump" aria-label="Topics">{jump}</nav></div>
</div></section>
<main id="inhalt">
<!--wennvoll:kf-->{top}<!--/wennvoll:kf-->
{sections}{empty}
</main>
"""
    url = DOMAIN + "/blog/"
    ld = [json_ld({"@context": "https://schema.org", "@type": "Blog", "name": "Swiftly Player blog", "url": url,
                   "inLanguage": "en", "author": {"@type": "Organization", "name": HERAUSGEBER, "url": DOMAIN + "/"},
                   "publisher": ORGANISATION}),
          json_ld(breadcrumb([("Swiftly Player", DOMAIN + "/"), ("Blog", url)]))]
    return page("Jellyfin guides and client comparisons | Swiftly Player blog", description, url, content, ld=ld)


def page_404():
    content = """<section class="sw-page-head sw-lines pb-404"><div class="sw-g">
  <div class="sw-page-head__crumbs"><ol class="sw-crumbs"><li><a href="/">Swiftly Player</a></li><li><a href="/blog/">Blog</a></li></ol></div>
  <h1 class="sw-page-head__title" id="inhalt">Page not found<i>.</i></h1>
  <p class="sw-page-head__sub">There is no page at this address. It may have moved, or it is not out yet.</p>
  <div class="sw-page-head__meta pb-404__ways"><a class="sw-btn" href="/blog/">All articles<svg class="sw-tri" aria-hidden="true"><use href="#sw-tri"/></svg></a><a class="sw-back" href="/"><svg aria-hidden="true"><use href="#ph-b-arrow-left"/></svg>Home</a></div>
</div></section>
"""
    return page("Page not found | Swiftly Player", "There is no page at this address.", "", content,
                 robots='<meta name="robots" content="noindex">\n')


# ------------------------------------------------------------------ PHP
# Runs on the web host (PHP 8.5). No framework, no database, no cron.

PHP_LIB = r"""<?php
// Generated by Werkzeuge/blog-bauen.py. Do not edit by hand.
declare(strict_types=1);

const DOMAIN = 'https://swiftlyplayer.com';
const INDEXNOW_SCHLUESSEL = '@SCHLUESSEL@';
const GRENZEN = ['rel' => 3];

function heute(): string
{
    // Only the local test server (php -S) may set a day.
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

// The kit's icon sprite, pasted inline once per page (external <use> needs CORS/file tricks).
function sprite(): string
{
    $roh = @file_get_contents(dirname(__DIR__, 2) . '/kit/assets/sprite.svg');
    return is_string($roh) ? $roh : '';
}

function filtern(string $html): string
{
    $html = str_replace('<!--sw:sprite-->', sprite(), $html);
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
    echo filtern((string) file_get_contents(__DIR__ . '/_404.html'));
    exit;
}

// IndexNow: report each due address exactly once, after the response to the
// browser. Errors stay silent; a retry happens after an hour at the earliest.
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

PHP_ARTICLE = r"""<?php
// Generated by Werkzeuge/blog-bauen.py. /blog/<slug>/ -> here (see .htaccess).
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
// Generated by Werkzeuge/blog-bauen.py. /blog/
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$datei = __DIR__ . '/_artikel/_uebersicht.html';
melden();
kopfzeilen('text/html; charset=utf-8', stand(faellige(), $datei), 300);
$html = (string) file_get_contents($datei);
// Empty state ("No articles yet") only while no article is due.
if (faellige()) {
    $html = (string) preg_replace('/<!--wennleer:alle-->.*?<!--\/wennleer:alle-->/s', '', $html);
}
echo filtern($html);
"""

PHP_TITLE = r"""<?php
// Generated by Werkzeuge/blog-bauen.py. /blog/titel/<slug>.jpg|svg, only from the article's day.
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$typen = ['jpg' => 'image/jpeg', 'svg' => 'image/svg+xml'];
$slug = is_string($_GET['slug'] ?? null) ? $_GET['slug'] : '';
$typ = is_string($_GET['typ'] ?? null) ? $_GET['typ'] : '';
// The host passes no query values to this script for /blog/titel/<slug>.jpg,
// although the rule in .htaccess appends them (for artikel.php they arrive).
// So read them from the address itself if necessary.
if ($slug === '' || $typ === '') {
    $pfad = parse_url((string) ($_SERVER['REQUEST_URI'] ?? ''), PHP_URL_PATH) ?: '';
    if (preg_match('#/titel/([a-z0-9]+(?:-[a-z0-9]+)*)\.(jpg|svg)$#', $pfad, $parts)) {
        $slug = $parts[1];
        $typ = $parts[2];
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
// Generated by Werkzeuge/blog-bauen.py. /blog/feed.xml
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
// Generated by Werkzeuge/blog-bauen.py. /sitemap.xml (rewrite in the root) and /blog/sitemap.xml
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
    if (($a['index'] ?? true) === false) {
        continue;
    }
    echo '  <url><loc>', DOMAIN, '/blog/', $a['slug'], '/</loc><lastmod>', $a['aktualisiert'] ?: $a['datum'],
        "</lastmod><changefreq>monthly</changefreq><priority>0.6</priority></url>\n";
}
echo "</urlset>\n";
"""

PHP_LLMS = r"""<?php
// Generated by Werkzeuge/blog-bauen.py. /llms.txt (rewrite in the root)
declare(strict_types=1);
require __DIR__ . '/_artikel/lib.php';

$liste = faellige();
melden();
kopfzeilen('text/plain; charset=utf-8', stand($liste, __DIR__ . '/_artikel/artikel.json'), 600);
echo implode("\n", daten()['llms'] ?? []), "\n";
if ($liste) {
    echo "## Blog\n\n";
    foreach ($liste as $a) {
        if (($a['index'] ?? true) === false) {
            continue;
        }
        echo '- [', $a['titel'], '](', DOMAIN, '/blog/', $a['slug'], '/): ', $a['beschreibung'], "\n";
    }
    echo "\n";
}
"""

HTACCESS_BLOG = r"""# Generated by Werkzeuge/blog-bauen.py. Articles appear from their date (PHP).
Options -Indexes
DirectoryIndex index.php
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /blog/
RewriteCond %{HTTP_HOST} ^www\.swiftlyplayer\.com$ [NC]
RewriteRule ^(.*)$ https://swiftlyplayer.com/blog/$1 [R=301,L]
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

HTACCESS_LOCKED = "# Generated by Werkzeuge/blog-bauen.py. Readable by PHP only.\nRequire all denied\n"

# Only this block is ours; website-upload.py inserts it into an existing .htaccess on the server instead of replacing it.
HTACCESS_ROOT = r"""# BEGIN swiftly-blog
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteCond %{HTTP_HOST} ^www\.swiftlyplayer\.com$ [NC]
RewriteRule ^(.*)$ https://swiftlyplayer.com/$1 [R=301,L]
RewriteCond %{THE_REQUEST} \s/+((?:[^\s?]*/)?)index\.html[\s?]
RewriteRule ^ https://swiftlyplayer.com/%1 [R=301,L]
RewriteRule ^sitemap\.xml$ blog/sitemap.php [L]
RewriteRule ^llms\.txt$ blog/llms.php [L]
</IfModule>
# END swiftly-blog
"""


# ------------------------------------------------------------------ Files

def write(path, text):
    """Writes only on change (same checksum = no upload). True if written."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    alt = None
    if os.path.exists(path):
        with open(path, encoding="utf-8") as h:
            alt = h.read()
    if alt == text:
        return False
    with open(path, "w", encoding="utf-8") as h:
        h.write(text)
    print("geschrieben  " + os.path.relpath(path, os.path.dirname(WEBSITE)))
    return True


def fixed_pages():
    """Non-blog entries from Website/sitemap.xml (which stays as a fallback without the blog)."""
    ns = "http://www.sitemaps.org/schemas/sitemap/0.9"
    path = os.path.join(WEBSITE, "sitemap.xml")
    fixed = []
    if os.path.exists(path):
        for url in ET.parse(path).getroot().findall(f"{{{ns}}}url"):
            loc = url.findtext(f"{{{ns}}}loc", "")
            if "/blog/" in loc or "/whats-new/" in loc:   # blog and release pages are generated below
                continue
            fixed.append({"loc": loc, "lastmod": url.findtext(f"{{{ns}}}lastmod"),
                          "changefreq": url.findtext(f"{{{ns}}}changefreq"), "priority": url.findtext(f"{{{ns}}}priority")})
    return fixed


def sitemap_text(entries):
    rows = []
    for u in entries:
        parts = f"<loc>{e(u['loc'])}</loc>" + "".join(f"<{k}>{e(u[k])}</{k}>" for k in ("lastmod", "changefreq", "priority") if u.get(k))
        rows.append(f"  <url>{parts}</url>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
            + "\n".join(rows) + "\n</urlset>\n")


def whatsnew_entries():
    """/whats-new/ and one page per release that is out today (releases/*.json, see whats-new/README.md)."""
    rows = web_shell.released(os.path.join(WEBSITE, "whats-new", "releases"))
    if not rows:
        return []
    out = [{"loc": DOMAIN + "/whats-new/", "lastmod": rows[0]["date"], "changefreq": "monthly", "priority": "0.6"}]
    return out + [{"loc": f"{DOMAIN}/whats-new/{r['version']}/", "lastmod": r["date"], "changefreq": "yearly", "priority": "0.5"} for r in rows]


def sitemap_entries(list, pages):
    entries = [u for u in fixed_pages() if not any(u["loc"] == s["url"] for s in pages)]
    entries += whatsnew_entries()
    entries += [{"loc": s["url"], "lastmod": (s["aktualisiert"] or s["datum"]).isoformat(),
                   "changefreq": "monthly", "priority": "0.7"} for s in pages if s["index"]]
    if list:
        latest = max((a["aktualisiert"] or a["datum"]) for a in list)
        entries.append({"loc": DOMAIN + "/blog/", "lastmod": latest.isoformat(), "changefreq": "weekly", "priority": "0.7"})
        entries += [{"loc": a["url"], "lastmod": (a["aktualisiert"] or a["datum"]).isoformat(),
                       "changefreq": "monthly", "priority": "0.6"} for a in list if a["index"]]
    return entries


NOINDEX_SINCE = "2026-09-28"


def sitemap_noindex(list, pages):
    """Second sitemap with only the URLs that are set to noindex. This makes Google
    re-crawl them quickly and see the noindex; otherwise they stay in the index
    with stale content for weeks. Can go once site: no longer shows them."""
    heute = dt.date.today()
    return ([{"loc": s["url"], "lastmod": NOINDEX_SINCE} for s in pages if not s["index"]]
            + [{"loc": a["url"], "lastmod": NOINDEX_SINCE} for a in list if not a["index"] and a["datum"] <= heute])


def whatsnew_llms():
    rows = web_shell.released(os.path.join(WEBSITE, "whats-new", "releases"))
    if not rows:
        return []
    out = [f"- [What's new]({DOMAIN}/whats-new/): release notes for every version"]
    return out + [f"- [Swiftly Player {r['version']}]({DOMAIN}/whats-new/{r['version']}/): {r.get('summary') or r['title']}" for r in rows]


def llms_header(pages):
    rows = ["# Swiftly Player", "",
              "> A free, open-source video player for your own Jellyfin server. It plays files as Direct Play "
              "or Direct Stream instead of transcoding them. For iPhone, iPad, Mac, Apple TV, Android, "
              "Android TV, Windows and Linux. Built by one person.", "",
              "## Pages", "",
              f"- [Swiftly Player]({DOMAIN}/): features, supported platforms, downloads, FAQ",
              f"- [App Store]({DOMAIN}/download/app-store/): install on iPhone, iPad, Mac and Apple TV",
              f"- [TestFlight]({DOMAIN}/download/testflight/): join the beta and send feedback",
              f"- [Android and Android TV]({DOMAIN}/android/): install from Google Play, phone and Android TV",
              f"- [Windows]({DOMAIN}/download/windows/): installing the Windows build, step by step",
              f"- [Linux]({DOMAIN}/download/linux/): one command for apt, dnf, zypper and pacman",
              f"- [Support]({DOMAIN}/support.html): help and contact",
              *whatsnew_llms(),
              f"- [Privacy]({DOMAIN}/privacy.html): the app collects nothing",
              f"- [Source code]({GITHUB}): MPL-2.0"]
    rows += [f"- [{s['titel']}]({s['url']}): {s['beschreibung']}" for s in pages]
    return rows + [""]


def feed_text(list):
    def rfc(d):
        return email.utils.format_datetime(dt.datetime(d.year, d.month, d.day, 7, 0, tzinfo=ZONE))
    items = "".join(f"""
  <item>
    <title>{e(a["titel"])}</title>
    <link>{a["url"]}</link>
    <guid isPermaLink="true">{a["url"]}</guid>
    <pubDate>{rfc(a["datum"])}</pubDate>
    <description>{e(a["beschreibung"])}</description>
{"".join(f"    <category>{e(t)}</category>{chr(10)}" for t in a["schlagworte"])}  </item>""" for a in list)
    state = f"\n  <lastBuildDate>{rfc(list[0]['datum'])}</lastBuildDate>" if list else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
  <title>Swiftly Player blog</title>
  <link>{DOMAIN}/blog/</link>
  <atom:link href="{DOMAIN}/blog/feed.xml" rel="self" type="application/rss+xml"/>
  <description>Guides and comparisons for people who run their own Jellyfin server.</description>
  <language>en</language>{state}{items}
</channel>
</rss>
"""


def indexnow_key():
    """Public key for IndexNow (not a secret): Website/<32 hex>.txt."""
    for name in sorted(os.listdir(WEBSITE)):
        m = re.fullmatch(r"([0-9a-f]{32})\.txt", name)
        if m:
            return m.group(1)
    key = hashlib.sha256(os.urandom(32)).hexdigest()[:32]
    write(os.path.join(WEBSITE, key + ".txt"), key)
    return key


def cleanUp(target, slugs, pages):
    """Remove stale output: old static blog pages (identified by MARKER), templates
    and cover images of deleted articles. Never quellen/ or bilder/."""
    blog = os.path.join(target, "blog")
    if not os.path.isdir(blog):
        return
    for name in os.listdir(blog):
        path = os.path.join(blog, name, "index.html")
        if name in ("quellen", "bilder", "_artikel", "titel") or not os.path.isfile(path):
            continue
        if target == PREVIEW and name in slugs:
            continue
        with open(path, encoding="utf-8") as h:
            if MARKER not in h.read(4000):
                continue
        shutil.rmtree(os.path.join(blog, name))
        print("entfernt     " + os.path.relpath(os.path.join(blog, name), target) + "/")
    if target == WEBSITE:
        for alt in ("index.html", "feed.xml"):
            p = os.path.join(blog, alt)
            if os.path.isfile(p):
                os.remove(p)
                print("entfernt     blog/" + alt)
    for folder, endungen in ((os.path.join(blog, "_artikel"), (".html",)),
                             (os.path.join(blog, "_artikel", "titel"), (".svg", ".jpg")),
                             (os.path.join(blog, "titel"), (".svg", ".jpg"))):
        if not os.path.isdir(folder):
            continue
        for name in os.listdir(folder):
            trunk, suffix = os.path.splitext(name)
            if suffix in endungen and not trunk.startswith("_") and trunk not in slugs:
                os.remove(os.path.join(folder, name))
                print("entfernt     " + os.path.relpath(os.path.join(folder, name), target))


def landing_page(s, pages):
    """Platform landing page (jellyfin-client-*) in the kit design: head, structured data and text come from
    article_page(); the page itself is built by the shared shell (web_shell.py) and components (web_parts.py)."""
    sys.path.insert(0, HERE)
    import web_parts
    import web_shell
    head = web_parts.head_strip(article_page(s, pages))
    return web_shell.page(head, web_parts.landing_body(s, pages, sys.modules[__name__]))


def build_build(target, pages):
    for s in pages:
        folder = os.path.join(target, s["pfad"].strip("/"))
        if target != WEBSITE and os.path.islink(os.path.join(target, s["pfad"].strip("/").split("/")[0])):
            continue                                   # the preview mirrors Website/ via symlinks
        if target == WEBSITE:
            title_write(s, folder, "titelbild")
        else:
            for suffix in (".svg", ".jpg"):
                source = os.path.join(WEBSITE, s["pfad"].strip("/"), "titelbild" + suffix)
                if os.path.exists(source):
                    os.makedirs(folder, exist_ok=True)
                    shutil.copy2(source, os.path.join(folder, "titelbild" + suffix))
        index = os.path.join(folder, "index.html")
        if os.path.exists(index):
            with open(index, encoding="utf-8") as h:
                if MARKER not in h.read(4000):
                    warn(f"{s['pfad']}index.html stammt nicht vom Generator; nicht ueberschrieben")
                    continue
        write(index, filter(landing_page(s, pages), "9999-12-31"))


def home_maintain(pages):
    """index.html: footer column 'Jellyfin clients' with the landing pages, and
    the FAQPage JSON-LD rebuilt from the visible FAQ (Google requires them to match)."""
    path = os.path.join(WEBSITE, "index.html")
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as h:
        s = alt = h.read()
    s = re.sub(r"<!-- seiten:anfang.*?<!-- seiten:ende -->\n\n      ", "", s, flags=re.S)
    s = s.replace('<div class="fuss__raster fuss__raster--fuenf">', '<div class="fuss__raster">')
    anchor = '<div class="fuss__spalte">\n        <h2>Elsewhere</h2>'
    if anchor in s:
        points = "".join(f'\n          <li><a href="{p}">{e(t)}</a></li>' for p, t in FOOTER_GUIDES)
        s = s.replace(anchor, '<!-- seiten:anfang (blog-bauen.py) -->\n      <div class="fuss__spalte">\n'
                      f'        <h2>Guides</h2>\n        <ul>{points}\n        </ul>\n      </div>\n'
                      '      <!-- seiten:ende -->\n\n      ' + anchor, 1)
        s = s.replace('<div class="fuss__raster">', '<div class="fuss__raster fuss__raster--fuenf">', 1)

    def pure(x):
        x = html.unescape(re.sub(r"<[^>]+>", " ", x))
        return re.sub(r"\s+([.,;:!?)])", r"\1", re.sub(r"\s+", " ", x)).strip()
    ask = re.findall(r'<button class="frage__knopf"[^>]*>\s*<span>(.*?)</span>.*?'
                        r'<div class="frage__antwort"[^>]*><div>(.*?)</div></div>', s, re.S)
    if ask:
        ld = json_ld({"@context": "https://schema.org", "@type": "FAQPage",
                      "mainEntity": [{"@type": "Question", "name": pure(f),
                                      "acceptedAnswer": {"@type": "Answer", "text": pure(a)}} for f, a in ask]})
        s = re.sub(r'<script type="application/ld\+json">\s*\{\s*"@context": "https://schema.org",\s*"@type": "FAQPage".*?</script>',
                   lambda m: ld, s, count=1, flags=re.S)
    if s != alt:
        write(path, s)


def build_live(article, pages):
    """Website/: all articles protected, PHP decides visibility."""
    list = sorted(article, key=lambda a: (a["datum"], a["slug"]), reverse=True)
    blog = os.path.join(WEBSITE, "blog")
    lager = os.path.join(blog, "_artikel")
    for a in list:
        title_write(a, os.path.join(lager, "titel"), a["slug"])
        write(os.path.join(lager, a["slug"] + ".html"), article_page(a, list))
    write(os.path.join(lager, "_uebersicht.html"), overview(list))
    write(os.path.join(lager, "_404.html"), page_404())
    data = {
        "artikel": [{"slug": a["slug"], "titel": a["titel"], "beschreibung": a["beschreibung"],
                     "datum": a["datum"].isoformat(),
                     "aktualisiert": a["aktualisiert"].isoformat() if a["aktualisiert"] else "",
                     "bild": a["bild"], "schlagworte": a["schlagworte"], "index": a["index"]} for a in list],
        "seiten": [s["pfad"] for s in pages],
        "sitemap": sitemap_entries([], pages),
        "llms": llms_header(pages),
    }
    write(os.path.join(lager, "artikel.json"), json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    write(os.path.join(lager, "lib.php"), PHP_LIB.replace("@SCHLUESSEL@", indexnow_key()))
    write(os.path.join(lager, ".htaccess"), HTACCESS_LOCKED)
    for name, text in (("artikel.php", PHP_ARTICLE), ("index.php", PHP_INDEX), ("titel.php", PHP_TITLE),
                       ("feed.php", PHP_FEED), ("sitemap.php", PHP_SITEMAP), ("llms.php", PHP_LLMS),
                       (".htaccess", HTACCESS_BLOG)):
        write(os.path.join(blog, name), text)
    write(os.path.join(WEBSITE, ".htaccess"), HTACCESS_ROOT)
    # Fallback in case a rewrite is missing: without the blog, so nothing future-dated leaks.
    write(os.path.join(WEBSITE, "sitemap.xml"), sitemap_text(sitemap_entries([], pages)))
    write(os.path.join(WEBSITE, "sitemap-recrawl.xml"), sitemap_text(sitemap_noindex(list, pages)))
    write(os.path.join(WEBSITE, "llms.txt"), "\n".join(llms_header(pages)))
    build_build(WEBSITE, pages)
    home_maintain(pages)
    cleanUp(WEBSITE, {a["slug"] for a in list}, pages)
    return list


def build_preview(article, pages, heute):
    """Static, all articles visible, future ones with a note. Never uploaded."""
    preview_prepare()
    list = sorted(article, key=lambda a: (a["datum"], a["slug"]), reverse=True)
    for a in list:
        write(os.path.join(PREVIEW, "blog", a["slug"], "index.html"),
                  filter(article_page(a, list, heute), "9999-12-31"))
        for suffix in (".svg", ".jpg"):
            source = os.path.join(WEBSITE, "blog", "_artikel", "titel", a["slug"] + suffix)
            target = os.path.join(PREVIEW, "blog", "titel", a["slug"] + suffix)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(source):
                shutil.copy2(source, target)
    write(os.path.join(PREVIEW, "blog", "index.html"), filter(overview(list, heute), "9999-12-31"))
    write(os.path.join(PREVIEW, "blog", "feed.xml"), feed_text(list))
    write(os.path.join(PREVIEW, "sitemap.xml"), sitemap_text(sitemap_entries(list, pages)))
    write(os.path.join(PREVIEW, "llms.txt"), "\n".join(llms_header(pages)))
    write(os.path.join(PREVIEW, "404.html"), page_404())
    build_build(PREVIEW, pages)
    cleanUp(PREVIEW, {a["slug"] for a in list}, pages)


def preview_prepare():
    """Mirror of the website made of symlinks so /schrift, /wortmarke.svg etc. resolve."""
    os.makedirs(os.path.join(PREVIEW, "blog"), exist_ok=True)
    for name in os.listdir(WEBSITE):
        if name in ("blog", "sitemap.xml", "llms.txt") or name.startswith("."):
            continue
        link = os.path.join(PREVIEW, name)
        if not os.path.lexists(link):
            os.symlink(os.path.join(WEBSITE, name), link)
    link = os.path.join(PREVIEW, "blog", "bilder")
    if not os.path.lexists(link):
        os.symlink(IMAGES, link)


def main():
    global PAGES
    args = sys.argv[1:]
    heute = dt.datetime.now(ZONE).date()
    try:
        article = article_load()
        pages = article_load(PAGES_SOURCES, pages=True)
    except (ValueError, OSError) as error:
        sys.exit(f"Abbruch: {error}")
    PAGES = pages
    build_live(article, pages)
    kuenftig = sorted(a["datum"].isoformat() + "  " + a["slug"] for a in article if a["datum"] > heute)
    print(f"Stand {heute}: {len(article) - len(kuenftig)} faellig, {len(kuenftig)} erscheinen spaeter von selbst, "
          f"{len(pages)} Landingpages.")
    for k in kuenftig:
        print("  ab " + k)
    if "--vorschau" in args:
        build_preview(article, pages, heute)
        print(f"Vorschau: {PREVIEW}\n"
              f"  ansehen: python3 {os.path.join(HERE, 'website-server.py')} 8789 {PREVIEW}\n"
              f"  dann http://127.0.0.1:8789/blog/")
    print("Hochladen: python3 " + os.path.join(HERE, "website-upload.py") + " --nur-geaendert")
    if warnungen:
        print(f"{len(warnungen)} Warnung(en).", file=sys.stderr)


if __name__ == "__main__":
    main()
