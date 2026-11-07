#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Builds every non-blog page of swiftlyplayer.com on the Swiftly web kit, with the one shell from web_shell.py.

  index.html, about/, support.html, music/     from web-vorlagen/quellen/ (the old pages give head and text)
  download/*, android/, supporter/*, licenses/, terms/, impressum, privacy, datenschutz, nutzungsbedingungen
                                               from web-vorlagen/<path> (head lines, main content, page scripts)
  jellyfin-client-*/                           landing pages from blog-build.py (landing_page)
  whats-new/_shell.html                        shell fragments for the PHP pages in whats-new/ (_lib.php includes them)

  python3 Werkzeuge/web_build.py [--out DIR] [--only home,about,support,music,landing,vorlagen,whatsnew]

Default output is Website/. The kit (kit/, schrift/, ...) is not copied here. The blog articles and the blog overview
are built by blog-build.py and are not touched.
"""
import argparse, html, importlib.util, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_shell as shell                        # noqa: E402
from web_parts import *                          # noqa: E402,F401
from web_parts import head_strip, fit_h2, page_head, band, phone, tile, frame, landing_body, EXT, SWIFTLY_STORES, DISCORD, ASSETS  # noqa: E402

QUELLEN = os.path.join(HERE, "web-vorlagen", "quellen")
VORLAGEN = os.path.join(HERE, "web-vorlagen")
OUT = os.path.join(HERE, "..", "Website")


def rd(path):
    with open(path, encoding="utf-8") as h:
        return h.read()


def wr(rel, text):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as h:
        h.write(text)


def original(rel):
    """Old hand-written page whose head and text the kit page keeps."""
    return rd(os.path.join(QUELLEN, rel))


def build_home():
    src = rd(os.path.join(QUELLEN, "startseite.html"))
    main = src[src.index('<section class="sw-hero'):src.index("<footer")]
    main = main.replace('src="assets/', f'src="{ASSETS}').replace("https://swiftlyplayer.com/", "/")
    main = main.replace('<a class="sw-btn" href="#pg" data-sw-hero-dl>', '<a class="sw-btn" href="#download" data-sw-hero-dl>')
    assert "#pg" not in main, "unresolved placeholder link"
    teaser = f"""<section class="sw-section sw-lines pm-teaser" id="music"><div class="sw-g">
  <div class="pm-teaser__text">
    <p class="pm-teaser__tag"><i class="sw-nav__dot" aria-hidden="true"></i>New · Free beta</p>
    <h2 class="pm-hero__title pm-teaser__title">Swiftly Music<i>.</i></h2>
    <p class="sw-lead">A music player for the <b>Jellyfin or Navidrome server you run yourself.</b> FLAC as stored, synced lyrics, downloads, Sonos and AirPlay.</p>
    <div class="sw-hero__cta"><a class="sw-btn" href="/music/">See Swiftly Music<svg class="sw-tri" aria-hidden="true"><use href="#sw-tri"/></svg></a><span class="sw-hero__meta">iPhone · TestFlight</span></div>
  </div>
  <div class="pm-teaser__stage" aria-hidden="true">{phone("/bilder/music-album.webp", "pm-phone--l")}{phone("/bilder/music-wiedergabe.webp", "pm-phone--m")}</div>
</div></section>
"""
    marker = '<section class="sw-section sw-lines sw-lines--faq"'
    assert marker in main
    main = main.replace(marker, teaser + marker, 1)
    # live head (title, description, OG/Twitter, canonical, structured data, favicons) with the kit instead of the old CSS
    live = original("index.html")
    head = head_strip(live)
    # FAQPage structured data follows the visible FAQ
    faq = re.findall(r'<div class="sw-faq__item"><h3>(.*?)</h3><p>(.*?)</p></div>', main)

    def faq_ld(m):
        data = json.loads(m.group(1))
        graph = data.get("@graph")
        for node in (graph if graph is not None else [data]):
            if node.get("@type") == "FAQPage":
                node["mainEntity"] = [{"@type": "Question", "name": html.unescape(q),
                                       "acceptedAnswer": {"@type": "Answer", "text": html.unescape(a)}} for q, a in faq]
        return '<script type="application/ld+json">\n' + json.dumps(data, indent=2, ensure_ascii=False) + "\n</script>"
    head = re.sub(r'<script type="application/ld\+json">\s*(.*?)\s*</script>', faq_ld, head, flags=re.S)
    wr("index.html", shell.page(head, main, home=True))


# ------------------------------------------------------------------ about, support

def sections_to_prose(text):
    out = []
    for m in re.finditer(r'<section class="abschnitt"[^>]*>(.*?)</section>', text, re.S):
        out.append(m.group(1).strip())
    return "\n".join(out)


def build_about():
    old = original("about/index.html")
    head = head_strip(old)
    prose = sections_to_prose(old)
    prose = re.sub(r'\s+target="_blank" rel="noopener"', EXT, prose)
    sub = re.search(r'<p class="unter">(.*?)</p>', old, re.S).group(1)
    body = page_head([("Swiftly Player", "/"), ("About", "")], "Built by one person", sub) + f"""
<main class="sw-section sw-lines" id="inhalt"><div class="sw-g">
  <article class="sw-prose">
{prose}
    <aside class="sw-callout sw-callout--accent"><svg aria-hidden="true"><use href="#ph-f-info"/></svg><div><strong>Stuck somewhere?</strong><p>Ask on Discord.</p><p class="sw-mt-5"><a class="sw-btn sw-btn--on-accent" href="{DISCORD}"{EXT}>Get help on Discord<svg class="sw-tri"><use href="#sw-tri"/></svg></a></p></div></aside>
    <p>All the features you need are free. If it helps you, <a href="/supporter/">buy us a coffee</a>.</p>
  </article>
</div></main>
""" + band(["Get Swiftly", "Player."], "Free. Open source. No ads.", SWIFTLY_STORES, "Plex and Emby: beta. Jellyfin 10.8 or newer.")
    wr("about/index.html", shell.page(head, body))


def build_support():
    old = original("support.html")
    head = head_strip(old)
    main = old[old.index("<main>"):old.index("</main>")]
    sub = re.search(r'<p class="unter">(.*?)</p>', main, re.S).group(1)
    sub = " ".join(sub.split())
    kasten = re.search(r'<div class="kasten">\s*<p>(.*?)</p>\s*</div>', main, re.S).group(1)
    parts = []
    for m in re.finditer(r'<div class="frage">(.*?)</div>', main, re.S):
        parts.append(m.group(1).strip())
    tail = main[main.index("<h2>Something else</h2>"):]
    tail = re.sub(r"</?div[^>]*>|</?main[^>]*>", "", tail).strip()
    prose = f"""<h2>Before anything else</h2>
<aside class="sw-callout"><svg aria-hidden="true"><use href="#ph-f-info"/></svg><div><p>{kasten}</p></div></aside>
<h2>Common questions</h2>
{chr(10).join(parts)}
{tail}"""
    body = page_head([("Swiftly Player", "/"), ("Support", "")], "Support", sub) + f"""
<main class="sw-section sw-lines" id="inhalt"><div class="sw-g">
  <article class="sw-prose">
{prose}
  </article>
</div></main>
"""
    wr("support.html", shell.page(head, body, cur="support"))


# ------------------------------------------------------------------ music

def phone(src, cls=""):
    return (f'<div class="sw-iphone pm-phone {cls}"><img class="sw-iphone__screen" src="{src}" alt="" loading="lazy">'
            f'<img class="sw-bezel" src="{ASSETS}bezels/iphone-18-promax-black.webp" alt="" loading="lazy"></div>')


def tile(icon, title, text, extra="", cls=""):
    return (f'<article class="sw-tile {cls}"><svg class="sw-icon"><use href="#{icon}"/></svg>'
            f'<h3>{title}</h3><p>{text}</p>{extra}</article>')


def build_music():
    old = original("music/index.html")
    head = head_strip(old)
    faq = re.findall(r'<button class="frage__knopf"[^>]*>\s*<span>(.*?)</span>\s*<svg class="frage__pfeil".*?<div class="frage__antwort"[^>]*><div>(.*?)</div></div>', old, re.S)
    faq_html = "".join(f'<div class="sw-faq__item"><h3>{q}</h3>{a}</div>' for q, a in faq)
    assert len(faq) == 5, len(faq)
    chips = lambda xs: '<div class="sw-chips">' + "".join(f'<span class="sw-chip">{x}</span>' for x in xs) + "</div>"
    hero = f"""<section class="sw-section sw-lines pm-hero"><div class="sw-g">
  <div class="pm-hero__text">
    <h1 class="pm-hero__title">Your player<br>for your music<i>.</i></h1>
    <p class="sw-lead">A music player for the <b>Jellyfin or Navidrome server you run yourself.</b></p>
    <div class="sw-hero__cta"><a class="sw-btn" href="#download">Download<svg class="sw-tri"><use href="#sw-tri"/></svg></a><span class="sw-hero__meta">Free beta · No account · No ads</span></div>
  </div>
  <div class="pm-hero__stage" aria-hidden="true">
    {phone("/bilder/music-album.webp", "pm-phone--l")}{phone("/bilder/music-wiedergabe.webp", "pm-phone--m")}{phone("/bilder/music-start.webp", "pm-phone--r")}
  </div>
</div></section>"""
    features = f"""<section class="sw-section sw-lines sw-lines--features" id="features"><div class="sw-g">
  {fit_h2(["Made for", "music."])}
  <p class="sw-section__intro">The look and the buttons of Swiftly Player, arranged around albums and the song that is playing.</p>
  <div class="sw-tiles pm-tiles">
    <article class="sw-tile sw-tile--accent"><svg class="sw-icon"><use href="#ph-f-speaker-high"/></svg><p class="sw-tile__big">Original quality</p><p>FLAC and everything else streams as stored. On mobile data you choose how much.</p>{chips(["FLAC", "Original", "320 kbit/s", "128 kbit/s"])}</article>
    {tile("ph-f-subtitles", "Synced lyrics", "Line by line, as it is sung.")}
    {tile("ph-f-devices", "Sonos and AirPlay", "Keeps playing when your phone leaves the room.")}
    {tile("ph-f-arrow-circle-down", "Downloads", "Albums and playlists on the phone, over Wi-Fi only if you like.", cls="pm-t4")}
    {tile("ph-f-speaker-high", "Even volume", "Loud and quiet albums play at the same level.", cls="pm-t4")}
    {tile("ph-f-play", "It keeps going", "When the album ends, similar songs follow. Switch it off for silence.", cls="pm-t4")}
  </div>
</div></section>"""
    spectrum = f"""<section class="sw-section sw-lines sw-lines--looks" id="original"><div class="sw-g">
  {fit_h2(["Every bit", "of the song."])}
  <p class="sw-section__intro">A lossy copy cuts off the top of the sound. FLAC keeps all of it, and Swiftly Music plays it as stored.</p>
  <figure class="pm-spectrum"><img src="/bilder/spektrum.webp" alt="A spectrogram of a song: time runs to the right, pitch goes up to 22 kHz" width="1600" height="640" loading="lazy">
    <figcaption>An illustration. Where an MP3 stops depends on the encoder; 16 kHz at 128 kbit/s and 20 kHz at 320 kbit/s are typical.</figcaption></figure>
</div></section>"""
    faqs = f"""<section class="sw-section sw-lines sw-lines--faq" id="fragen"><div class="sw-g">
  {fit_h2(["Questions."], "sw-h2 sw-faq__title")}
  {faq_html}
</div></section>"""
    stores = [
        ("apple", TESTFLIGHT_MUSIC, "ph-f-rocket-launch", "TestFlight", "iPhone, free beta", "iOS 18 or newer", True, EXT),
        ("android", "/", "ph-f-play", "Swiftly Player", "Films and shows", "The sister app", False, ""),
        ("desktop", DISCORD, "si-discord", "Discord", "Feedback and news", "Join the server", False, EXT),
    ]
    store = band(["Get Swiftly", "Music."], "For iPhone, in beta on TestFlight.", stores, "Your films and shows live in Swiftly Player.")
    store = store.replace("<span class=\"sw-store__tag\">For this device</span>", "")
    body = hero + features + spectrum + faqs + store
    wr("music/index.html", shell.page(head, body))


# ------------------------------------------------------------------ pages from templates

def build_vorlagen():
    """Download, android, supporter, legal pages: the page's own head lines, content and scripts are stored in
    web-vorlagen/<path>; the shell around them comes from web_shell."""
    for root, dirs, files in os.walk(VORLAGEN):
        dirs[:] = [d for d in dirs if d != "quellen"]
        for name in sorted(files):
            if not name.endswith(".html"):
                continue
            rel = os.path.relpath(os.path.join(root, name), VORLAGEN)
            build_one(rel)


def build_one(rel):
    t = rd(os.path.join(VORLAGEN, rel))
    meta, head, body, scripts = re.match(r"<!--META (.*?)-->\n<!--HEAD-->\n(.*?)\n<!--BODY-->\n(.*?)\n<!--SCRIPTS-->\n(.*)\Z", t, re.S).groups()
    m = dict(kv.split("=", 1) for kv in meta.split())
    wr(rel, shell.page(head, body, lang=m.get("lang", "en"), css=m.get("css") or "pages-download.css", cur=m.get("cur") or None, scripts=scripts))


# ------------------------------------------------------------------ what's new: shell for the PHP pages

def build_whatsnew_shell():
    """whats-new/_shell.html: head assets, bar, nav, footer, download band and scripts as marked fragments.
    whats-new/_lib.php includes them, so PHP pages and static pages share one shell (web_shell.py)."""
    dl_band = band(["Get Swiftly", "Player."], "Free. Open source. No ads.", [
        ("apple", APPSTORE, "si-appstore", "App Store", "iPhone, iPad, Apple TV and Mac", "iOS 18 · tvOS 18 · macOS 15", True, ""),
        ("android", PLAY, "si-googleplay", "Google Play", "Android and Android TV", "Android 9 or newer", False, ""),
        ("desktop", RELEASES, "si-github", "GitHub", "Windows and Linux", "Windows 10 (64-bit) · apt, dnf, pacman, zypper", False, ""),
    ], "Plex and Emby: beta. Jellyfin 10.8 or newer.", ident="laden")
    pieces = (("head", shell.head_assets("pages-blog.css")), ("bar", shell.announce_bar("en")),
              ("nav", shell.nav("en", cur="news")), ("band", dl_band), ("footer", shell.footer("en")),
              ("scripts", f'<script src="{shell.KIT}kit.js"></script>\n<script src="{shell.KIT}shell.js"></script>'))
    text = "<!-- Generated by Werkzeuge/web_build.py (web_shell.py). Do not edit; included by _lib.php. -->\n"
    text += "".join(f"<!--sw:{k}-->{shell.ext_links(v)}<!--/sw:{k}-->\n" for k, v in pieces)
    wr("whats-new/_shell.html", text)


# ------------------------------------------------------------------ landing pages (via blog-build.py)

def load_blog_build():
    spec = importlib.util.spec_from_file_location("blog_build", os.path.join(HERE, "blog-build.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["blog_build"] = mod
    spec.loader.exec_module(mod)
    return mod


def build_landing():
    bb = load_blog_build()
    pages = bb.article_load(bb.PAGES_SOURCES, pages=True)
    bb.PAGES = pages
    for a in pages:
        wr(a["pfad"].strip("/") + "/index.html", bb.filter(bb.landing_page(a, pages), "9999-12-31"))


def cli(pages=None, steps=None):
    """Entry for the thin page_*.py scripts: build only the given template pages / steps."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    globals()["OUT"] = os.path.abspath(args.out)
    for rel in pages or []:
        build_one(rel)
        print("ok", rel)
    for name, fn in STEPS:
        if name in (steps or []):
            fn()
            print("ok", name)


STEPS = (("home", build_home), ("about", build_about), ("support", build_support), ("music", build_music),
         ("landing", build_landing), ("vorlagen", build_vorlagen), ("whatsnew", build_whatsnew_shell))

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    OUT = os.path.abspath(args.out)
    only = set(filter(None, args.only.split(",")))
    for name, fn in STEPS:
        if only and name not in only:
            continue
        fn()
        print("ok", name)
