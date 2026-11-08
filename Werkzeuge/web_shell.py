# -*- coding: utf-8 -*-
"""The one page shell of swiftlyplayer.com: head assets, announcement bar, navbar (with the mobile menu),
footer and the sprite. Single source of truth: every generator builds its pages with page() from here.

  head_assets(css)      kit CSS/JS links; Inter is self-hosted (@font-face in kit/tokens.css), no Google Fonts
  announce_bar(lang)    thin strip above the nav: "New in <version> · <summary> · See what's new"
  nav(lang, home, cur)  logo, links, Discord, Donate, Download, one mobile menu panel
  footer(lang)          quiet logo, link columns, legal bar (Impressum, Privacy, Datenschutz, Terms, Licenses)
  page(...)             the full document around a page's own head lines and main content

Language: "en" or "de" (supporter/de/, datenschutz, nutzungsbedingungen, Impressum).
Kit files (tokens.css, kit.css, shell.css, shell.js, page CSS) live in kit/; this module only links them.
"""
import datetime as dt
import html
import json
import os
import re
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(HERE, ".."))
WEBSITE = os.path.join(APP, "Website")
STAGING = os.path.join(APP, "design", "web-neu")


def _first(*paths):
    for p in paths:
        if p and os.path.exists(p):
            return p
    return paths[-1]


KIT_DIR = _first(os.environ.get("SWIFTLY_KIT"), os.path.join(WEBSITE, "kit"), os.path.join(STAGING, "kit"))
RELEASES_DIR = _first(os.environ.get("SWIFTLY_RELEASES"), os.path.join(WEBSITE, "whats-new", "releases"),
                      os.path.join(STAGING, "whats-new", "releases"))

DISCORD = "https://discord.gg/MeGwfv3UwN"
GITHUB = "https://github.com/paulherter/swiftly-player"
KIT = "/kit/"
ZONE = ZoneInfo("Europe/Berlin")

# ------------------------------------------------------------------ texts per language

T = {
    "en": {
        "lang": "en", "home": "Swiftly Player, home", "main": "Main", "menu": "Menu", "skip": "Skip to content",
        "features": "Features", "devices": "Devices", "news": "What's new", "music_nav": "Music", "support": "Support", "blog": "Blog", "github": "GitHub",
        "donate": "Donate", "donate_url": "/supporter/", "download": "Download", "discord": "Discord",
        "about": "Free player for your own Jellyfin server. Plex and Emby in beta.".replace("Free player", "A free player"),
        "about_text": "A free player for your own Jellyfin server. Plex and Emby in beta.",
        "product": "Product", "help": "Help", "code": "Code", "community": "Community",
        "music": "Swiftly Music", "about_link": "About", "guides": "Guides", "bug": "Report a bug",
        "fine": ("Free · Open source · No ads · © 2026 Swiftly Player"),
        "legal": "Legal",
        "legal_links": [("/impressum.html", "Impressum"), ("/privacy.html", "Privacy"), ("/datenschutz.html", "Datenschutz"),
                        ("/terms/", "Terms"), ("/licenses/", "Licenses")],
        "small": ('Not part of the Jellyfin project, hosts nothing itself. Code under the MPL-2.0; name, wordmark and icon are not. '
                  'Playback uses VLCKit and libVLC by VideoLAN under the LGPL-2.1-or-later: <a href="/licenses/">licenses and source</a>. '
                  'App Store is a service mark of Apple Inc. The Android robot is reproduced or modified from work created and shared by '
                  'Google and used according to the Creative Commons 3.0 Attribution License.'),
        "bar_new": "New in", "bar_more": "See what's new", "bar_close": "Dismiss",
        "news_url": "/whats-new/",
    },
    "de": {
        "lang": "de", "home": "Swiftly Player, Startseite", "main": "Hauptmenü", "menu": "Menü", "skip": "Zum Inhalt",
        "features": "Funktionen", "devices": "Geräte", "news": "Neuigkeiten", "music_nav": "Music", "support": "Support", "blog": "Blog", "github": "GitHub",
        "donate": "Spenden", "donate_url": "/supporter/de/", "download": "Download", "discord": "Discord",
        "about_text": "Ein kostenloser Player für deinen eigenen Jellyfin-Server. Plex und Emby in der Beta.",
        "product": "Produkt", "help": "Hilfe", "code": "Code", "community": "Community",
        "music": "Swiftly Music", "about_link": None, "guides": "Blog", "bug": "Fehler melden",
        "fine": "Kostenlos · Open Source · Keine Werbung · © 2026 Swiftly Player",
        "legal": "Rechtliches",
        "legal_links": [("/impressum.html", "Impressum"), ("/datenschutz.html", "Datenschutz"), ("/privacy.html", "Privacy"),
                        ("/nutzungsbedingungen.html", "Nutzungsbedingungen"), ("/licenses/", "Lizenzen")],
        "small": ('Kein Teil des Jellyfin-Projekts, hostet selbst nichts. Code unter der MPL-2.0; Name, Wortmarke und Icon nicht. '
                  'Die Wiedergabe nutzt VLCKit und libVLC von VideoLAN unter der LGPL-2.1 oder neuer: <a href="/licenses/">Lizenzen und Quellcode</a>. '
                  'App Store ist eine Dienstleistungsmarke von Apple Inc. Der Android-Roboter ist ein Werk von Google, verwendet nach der '
                  'Creative-Commons-3.0-Lizenz (Namensnennung).'),
        "bar_new": "Neu in", "bar_more": "Das ist neu", "bar_close": "Schließen",
        "news_url": "/whats-new/",
    },
}


def _t(lang):
    return T["de" if lang == "de" else "en"]


# ------------------------------------------------------------------ releases (one place for the announcement bar)

def today():
    forced = os.environ.get("SWIFTLY_HEUTE", "")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", forced):
        return forced
    return dt.datetime.now(ZONE).strftime("%Y-%m-%d")


def _vkey(v):
    return tuple(int(p) for p in v.split("."))


def released(directory=None):
    """All releases that are already out (date reached), newest version first. Broken or incomplete files are skipped."""
    directory = directory or RELEASES_DIR
    out = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, name), encoding="utf-8") as h:
                r = json.load(h)
            v, d = str(r["version"]), str(r["date"])
            if not re.fullmatch(r"\d+\.\d+(\.\d+)?", v) or name[:-5] != v or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", d):
                continue
            if d > today():
                continue
            out.append(r)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return sorted(out, key=lambda r: _vkey(str(r["version"])), reverse=True)


def latest_release(directory=None):
    """Newest release that is already out, or None."""
    rows = released(directory)
    return rows[0] if rows else None


# ------------------------------------------------------------------ pieces

def sprite():
    with open(os.path.join(KIT_DIR, "assets", "sprite.svg"), encoding="utf-8") as h:
        return h.read().strip()


def head_assets(css="pages-main.css"):
    """Font preload and kit stylesheets. `css` is the page's own CSS file in kit/ (pages-main.css, pages-download.css)."""
    sheets = ["tokens.css", "kit.css", "shell.css"] + ([css] if css else [])
    return ('<link rel="preload" as="font" type="font/woff2" href="/schrift/inter-latin.woff2" crossorigin>\n'
            + "\n".join(f'<link rel="stylesheet" href="{KIT}{s}">' for s in sheets))


def announce_bar(lang="en"):
    """The strip above the nav. Static for the release that is out today; shell.js swaps it for a newer one
    from /whats-new/latest.json. No release data: no bar."""
    r = latest_release()
    if not r:
        return ""
    t = _t(lang)
    v = html.escape(str(r["version"]))
    summary = r.get("summary_de") if lang == "de" else r.get("summary")
    summary = html.escape(summary) if summary else ""
    mid = f'<span class="sw-announce__dot" aria-hidden="true">·</span><span class="sw-announce__text">{summary}</span>' if summary else ""
    return (f'<div class="sw-announce" id="sw-announce" data-version="{v}" data-lang="{t["lang"]}" '
            f'data-new="{html.escape(t["bar_new"])}" data-more="{html.escape(t["bar_more"])}" role="region" aria-label="{html.escape(t["news"])}">'
            f'<a class="sw-announce__link" href="/whats-new/{v}/"><b><svg class="sw-tri" aria-hidden="true"><use href="#sw-tri"/></svg>'
            f'<span class="sw-announce__new">{html.escape(t["bar_new"])} {v}</span></b>{mid}'
            f'<span class="sw-announce__dot" aria-hidden="true">·</span><u>{html.escape(t["bar_more"])}</u></a>'
            f'<button type="button" class="sw-announce__x" aria-label="{html.escape(t["bar_close"])}"><svg class="sw-icon" aria-hidden="true"><use href="#ph-r-x"/></svg></button></div>'
            f'<script>try{{if(localStorage.getItem("sw-announce")==="{v}")document.getElementById("sw-announce").hidden=true}}catch(e){{}}</script>')


def nav(lang="en", home=False, cur=None):
    """Navbar + the one mobile menu panel. home: Download appears once the hero button has scrolled out (kit.js);
    otherwise it is always there. cur: 'donate' | 'support' | 'news' marks the link of the current page."""
    t = _t(lang)
    f = "" if home else "/"
    dl = not home
    mark = lambda k: ' aria-current="page"' if cur == k else ""
    donate_url = t["donate_url"]
    links = [(f"{f}#features", t["features"], None), (f"{f}#devices", t["devices"], None), ("/music/", t["music_nav"], "music"),
             ("/whats-new/", t["news"], "news"), ("/blog/", t["blog"], "blog"), (GITHUB, t["github"], None)]
    item = lambda u, n, k: (f'<a href="{u}"{mark(k) if k else ""}{" class=" + chr(34) + "sw-nav__new" + chr(34) if k == "music" else ""}>'
                            f'{html.escape(n)}{"<i class=" + chr(34) + "sw-nav__dot" + chr(34) + " aria-hidden=" + chr(34) + "true" + chr(34) + "></i>" if k == "music" else ""}</a>')
    top = "".join(item(*l) for l in links if l[0] != GITHUB)  # GitHub stays in the footer and the mobile menu: six links do not fit the bar
    panel = "".join(item(*l) for l in links)
    cls = "sw-nav sw-nav--sticky" + (" is-dl" if dl else "")
    dl_attrs = "" if dl else ' tabindex="-1" aria-hidden="true"'
    return (f'<header class="{cls}" id="sw-nav"><div class="sw-g">'
            f'<a class="sw-nav__logo-link" href="/" aria-label="{html.escape(t["home"])}"><svg class="sw-nav__logo" role="img" aria-label="Swiftly"><use href="#sw-logo"/></svg></a>'
            f'<nav class="sw-nav__links" aria-label="{html.escape(t["main"])}">{top}</nav>'
            f'<a class="sw-nav__discord" href="{DISCORD}"><svg aria-hidden="true"><use href="#si-discord"/></svg><span>{t["discord"]}</span></a>'
            f'<a class="sw-btn sw-btn--sm sw-btn--secondary sw-nav__donate" href="{donate_url}"{mark("donate")}>{html.escape(t["donate"])}</a>'
            f'<a class="sw-btn sw-btn--sm sw-nav__download" href="{f}#download"{dl_attrs}>{html.escape(t["download"])}<svg class="sw-tri"><use href="#sw-tri"/></svg></a>'
            f'<button type="button" class="sw-nav__menu" aria-label="{html.escape(t["menu"])}" aria-expanded="false" aria-controls="sw-menu"><svg class="sw-icon" aria-hidden="true"><use href="#ph-r-list"/></svg></button>'
            f'</div><nav class="sw-menu" id="sw-menu" aria-label="{html.escape(t["menu"])}" hidden>{panel}</nav></header>')


def footer(lang="en"):
    t = _t(lang)
    disc = f'<a href="{DISCORD}"><svg aria-hidden="true"><use href="#si-discord"/></svg>{t["discord"]}</a>'
    product = [("/#download", t["download"]), ("/whats-new/", t["news"]), (t["donate_url"], t["donate"]), ("/music/", t["music"])]
    if t["about_link"]:
        product.append(("/about/", t["about_link"]))
    helplinks = [("/support.html", t["support"]), ("/blog/", t["guides"])]
    codelinks = [(GITHUB, "GitHub"), (GITHUB + "/issues/new/choose", t["bug"])]
    col = lambda ident, title, items, first="": (
        f'<nav class="sw-footer__col{first}" aria-labelledby="{ident}"><h2 id="{ident}">{html.escape(title)}</h2>'
        + "".join(f'<a href="{u}">{html.escape(n)}</a>' for u, n in items) + "</nav>")
    legal = "".join(f'<a href="{u}">{html.escape(n)}</a>' for u, n in t["legal_links"])
    return ('<footer class="sw-footer sw-lines"><div class="sw-g">\n'
            f'  <div class="sw-footer__about"><svg role="img" aria-label="Swiftly"><use href="#sw-logo"/></svg><p>{t["about_text"]}</p></div>\n'
            f'  {col("z-p", t["product"], product, " sw-footer__col--first")}\n'
            f'  {col("z-h", t["help"], helplinks)}\n'
            f'  {col("z-c", t["code"], codelinks)}\n'
            f'  <nav class="sw-footer__col" aria-labelledby="z-d"><h2 id="z-d">{t["community"]}</h2>{disc}</nav>\n'
            '  <svg class="sw-footer__mark" aria-hidden="true"><use href="#sw-logo"/></svg>\n'
            f'  <div class="sw-footer__legal"><span>{t["fine"]}</span><nav aria-label="{html.escape(t["legal"])}">{legal}</nav></div>\n'
            f'  <p class="pm-fine">{t["small"]}</p>\n'
            '</div></footer>')


def ext_links(text):
    """Every link that leaves swiftlyplayer.com opens in a new tab. Internal links stay as they are."""
    def fix(m):
        tag = m.group(0)
        if "target=" in tag or re.search(r'href="https?://(www\.)?swiftlyplayer\.com[/"]', tag):
            return tag
        return tag[:-1] + ' target="_blank" rel="noopener">' if 'rel="' not in tag else tag[:-1] + ' target="_blank">'
    return re.sub(r'<a\b[^>]*\bhref="https?://[^"]*"[^>]*>', fix, text)


def page(head, body, lang="en", css="pages-main.css", home=False, cur=None, scripts=""):
    """Whole document. head: the page's own head lines (title, description, canonical, OG, JSON-LD, robots...).
    body: main content between nav and footer. scripts: page-specific <script> blocks after the shell scripts."""
    t = _t(lang)
    skip = f'<a class="sw-skip" href="#inhalt">{html.escape(t["skip"])}</a>\n' if 'id="inhalt"' in body else ""
    return ext_links(f"""<!doctype html>
<html lang="{t['lang']}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{head.strip()}
{head_assets(css)}
</head>
<body>
{skip}{sprite()}
<div class="sw-page"><div class="sw-w">
{announce_bar(lang)}
{nav(lang, home=home, cur=cur)}
{body.strip()}
{footer(lang)}
</div></div>
<script src="{KIT}kit.js"></script>
<script src="{KIT}shell.js"></script>
{scripts.strip()}
</body>
</html>
""")
