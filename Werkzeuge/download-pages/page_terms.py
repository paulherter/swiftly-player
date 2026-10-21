# -*- coding: utf-8 -*-
"""Terms of use: /terms/ (en) and /nutzungsbedingungen.html (de).

The text comes from Notizen/Supporter/nutzungsbedingungen-v5.html (both language
sections). The look is that of privacy.html: the style block and the font setup
are taken from it, so the legal pages stay alike. Draft notices and bracketed
review notes are dropped; the date is set below.
"""
import os, re, sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from parts import *

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "..", "Notizen", "Supporter", "nutzungsbedingungen-v5.html")
STAND = {"en": "Last updated 21 October 2026", "de": "Stand: 21. Oktober 2026"}
FIX = {  # the site footer has no "Cancel your plan" link; point to where it is
    "en": ('use "Cancel your plan" in the footer of every page or in your confirmation email',
           'use <a href="/supporter/">"Cancel your plan"</a> on the supporter page or the link in your confirmation email'),
    "de": ('nutze „Cancel your plan“ in der Fußzeile jeder Seite oder in deiner Bestätigungs-Mail',
           'nutze <a href="/supporter/de/">„Cancel your plan“</a> auf der Supporter-Seite oder den Link in deiner Bestätigungs-Mail'),
}


def sections():
    s = open(SOURCE, encoding="utf-8").read()
    return {lang: re.search(rf'<section id="{lang}".*?</section>', s, re.S).group(0) for lang in ("en", "de")}


def clean(lang, sec):
    sec = re.sub(r'<section[^>]*>', '', sec).replace('</section>', '')
    sec = re.sub(r'<h1[^>]*>(.*?)</h1>', '', sec)
    sec = re.sub(r'<p class="(stand|entwurf|sprache)">.*?</p>', '', sec)
    sec = re.sub(r'\s*\[[^\]]*(lawyer|Anwalt)[^\]]*\]', '', sec)
    old, new = FIX[lang]
    assert old in sec, lang
    sec = sec.replace(old, new)
    return sec.replace("<h2", "\n<h2").replace("</p>", "</p>\n").strip()


def page(lang, sec):
    en = lang == "en"
    title = "Terms of Use" if en else "Nutzungsbedingungen"
    other = ("/nutzungsbedingungen.html", "Auf Deutsch", "de") if en else ("/terms/", "In English", "en")
    me = "/terms/" if en else "/nutzungsbedingungen.html"
    desc = ("Terms of use for Swiftly Player: Supporter extras, payment, withdrawal." if en else
            "Nutzungsbedingungen für Swiftly Player: Supporter-Extras, Bezahlung, Widerruf.")
    sup = SUPPORTER_PATH if en else SUPPORTER_PATH + "de/"
    coffee = f' · <a href="{sup}">{"Donate" if en else "Spenden"}</a>' if SUPPORTER_ON else ""
    priv = ("/privacy.html", "Privacy") if en else ("/datenschutz.html", "Datenschutz")
    foot = (f'<a href="/">{"Home" if en else "Startseite"}</a> · <a href="/blog/">Blog</a> · '
            f'<a href="/impressum.html">Impressum</a> · <a href="{priv[0]}">{priv[1]}</a> · <a href="{me}">{title}</a>')
    h = open(os.path.join(WEBSITE, "privacy.html"), encoding="utf-8").read()
    head = h[:h.index("<title>")].replace('content="index, follow"', 'content="noindex, follow"')
    head = head.replace('<html lang="en">', f'<html lang="{lang}">')
    head += (f'<title>{title} · Swiftly Player</title>\n<meta name="description" content="{desc}">\n'
             f'<link rel="canonical" href="https://swiftlyplayer.com{me}">\n'
             f'<link rel="alternate" hreflang="{lang}" href="https://swiftlyplayer.com{me}">\n'
             f'<link rel="alternate" hreflang="{other[2]}" href="https://swiftlyplayer.com{other[0]}">\n</head>\n')
    return head + f"""<body>
<header><div class="bahn"><a class="zurueck" href="/"><svg viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 3 4.5 7l4 4"/></svg>Swiftly Player</a> <a class="zurueck" href="/blog/">Blog</a></div></header>
<main><div class="bahn">

<h1>{title}</h1>
<p class="unter">{STAND[lang]} · <a href="{other[0]}" hreflang="{other[2]}" lang="{other[2]}">{other[1]}</a></p>

{sec}

<p><a href="/impressum.html">Impressum</a> · <a href="{priv[0]}">{priv[1]}</a></p>
</div></main>
<footer><div class="bahn">{foot}{coffee}</div></footer>
</body>
</html>
"""


secs = sections()
for lang in ("en", "de"):
    html = page(lang, clean(lang, secs[lang]))
    if lang == "en":
        write("/terms/", html)
    else:
        p = os.path.join(WEBSITE, "nutzungsbedingungen.html")
        open(p, "w", encoding="utf-8").write(html)
        print("geschrieben", p, len(html))
