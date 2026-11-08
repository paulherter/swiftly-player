# -*- coding: utf-8 -*-
"""Page components shared by the generators (kit markup): page head, download band, fitted headline,
device frames, landing-page body. The shell (head assets, bar, nav, footer) is in web_shell.py."""
import html, re

DISCORD = "https://discord.gg/MeGwfv3UwN"
GITHUB = "https://github.com/paulherter/swiftly-player"
APPSTORE = "https://apps.apple.com/app/id6806824067"
PLAY = "https://play.google.com/store/apps/details?id=de.paulherter.swiftly"
RELEASES = GITHUB + "/releases/latest"
TESTFLIGHT_MUSIC = "https://testflight.apple.com/join/Ws5snXzX"
ASSETS = "/kit/assets/"


def head_strip(text):
    """Head inner HTML of an old page without inline CSS, kit/font links and old scripts."""
    head = re.search(r"<head>(.*?)</head>", text, re.S).group(1)
    head = re.sub(r"<style\b.*?</style>", "", head, flags=re.S)
    head = re.sub(r'<link rel="preload" as="font"[^>]*>', "", head)
    head = re.sub(r'<link rel="stylesheet"[^>]*>', "", head)
    head = re.sub(r'<link rel="preconnect"[^>]*>', "", head)
    head = re.sub(r'<script src="[^"]*"[^>]*></script>', "", head)
    head = re.sub(r'<meta name="viewport"[^>]*>|<meta charset="utf-8">', "", head)
    return "\n".join(l for l in head.split("\n") if l.strip())


def fit_h2(lines, cls="sw-h2 sw-section__title", extra=""):
    """Headline in the kit's fitted markup: every line is fitted to the column lines by kit.js."""
    out = []
    for i, line in enumerate(lines):
        last = i == len(lines) - 1
        if line.endswith("."):
            core = html.escape(line[:-1])
            end = f'<i class="sw-ls0">.</i>' if last else '<span class="sw-ls0">.</span>'
            out.append(f'<span><span class="sw-fitline">{core}{end}</span></span>')
        else:
            core, tail = html.escape(line[:-1]), html.escape(line[-1])
            out.append(f'<span><span class="sw-fitline">{core}<span class="sw-ls0">{tail}</span></span></span>')
    return f'<h2 class="{cls}" data-sw-fit{extra}>{"".join(out)}</h2>'


def page_head(crumbs, title, sub, meta=""):
    items = "".join(f'<li><a href="{u}">{html.escape(t)}</a></li>' for t, u in crumbs[:-1])
    items += f'<li aria-current="page">{html.escape(crumbs[-1][0])}</li>'
    t = html.escape(title.rstrip("."))
    return f"""<section class="sw-page-head sw-lines"><div class="sw-g">
  <div class="sw-page-head__crumbs"><ol class="sw-crumbs">{items}</ol></div>
  <h1 class="sw-page-head__title">{t}<i>.</i></h1>
  <p class="sw-page-head__sub">{sub}</p>{meta}
</div></section>"""


def band(title_lines, sub, stores, note="", ident="download"):
    cards = "".join(
        f'<a class="sw-store{" is-you" if me else ""}" data-sw-os="{os_}" href="{href}"{ext}>'
        f'<svg aria-hidden="true"><use href="#{icon}"/></svg><span class="sw-store__tag">For this device</span>'
        f'<b>{name}</b><span class="sw-store__for">{for_}</span>'
        f'<span class="sw-store__req"><span>{req}</span><svg aria-hidden="true"><use href="#ph-b-arrow-right"/></svg></span></a>'
        for os_, href, icon, name, for_, req, me, ext in stores)
    return f"""<section class="sw-band sw-lines" id="{ident}"><svg class="sw-band__shape" aria-hidden="true"><use href="#sw-tri"/></svg><div class="sw-g">
  {fit_h2(title_lines, "sw-h2 sw-band__title")}
  <p class="sw-band__sub">{sub}</p>
  <nav class="sw-stores" aria-label="Download">{cards}</nav>
  <p class="sw-band__note">{note}</p>
</div></section>"""


EXT = ' target="_blank" rel="noopener"'
SWIFTLY_STORES = [
    ("apple", APPSTORE, "si-appstore", "App Store", "iPhone, iPad, Apple TV, Mac", "iOS 18, macOS 15 or newer", True, ""),
    ("android", PLAY, "si-googleplay", "Google Play", "Android and Android TV", "Android 9 or newer", False, ""),
    ("desktop", RELEASES, "si-github", "GitHub", "Windows and Linux", "Windows 10, Linux with GTK 4.14", False, ""),
]


def phone(src, cls=""):
    return (f'<div class="sw-iphone pm-phone {cls}"><img class="sw-iphone__screen" src="{src}" alt="" loading="lazy">'
            f'<img class="sw-bezel" src="{ASSETS}bezels/iphone-18-promax-black.webp" alt="" loading="lazy"></div>')


def tile(icon, title, text, extra="", cls=""):
    return (f'<article class="sw-tile {cls}"><svg class="sw-icon"><use href="#{icon}"/></svg>'
            f'<h3>{title}</h3><p>{text}</p>{extra}</article>')


FRAMES = {
    "/jellyfin-client-apple-tv/": ("tv", "/bilder/tvos-start.webp", "Swiftly Player on Apple TV"),
    "/jellyfin-client-iphone-ipad/": ("ipad", "/bilder/ipados-start.webp", "Swiftly Player on iPad and iPhone"),
    "/jellyfin-client-mac/": ("mac", "/bilder/macos-start.webp", "Swiftly Player on a Mac"),
    "/jellyfin-client-windows/": ("window", "/bilder/windows-start.webp", "Swiftly Player on Windows"),
    "/jellyfin-client-linux/": ("window", "/bilder/linux-start.webp", "Swiftly Player on Linux"),
}
YOU = {"/jellyfin-client-apple-tv/": "apple", "/jellyfin-client-iphone-ipad/": "apple", "/jellyfin-client-mac/": "apple",
       "/jellyfin-client-android-tv/": "android", "/jellyfin-client-windows/": "desktop", "/jellyfin-client-linux/": "desktop"}


def frame(kind, src, alt):
    if kind == "tv":
        return (f'<div class="pm-tv"><div class="sw-tv__panel"><div class="sw-tv__screen"><img src="{src}" alt="{alt}" fetchpriority="high"></div></div>'
                '<div class="sw-tv__neck"></div><div class="sw-tv__base"></div></div>')
    if kind == "mac":
        return (f'<div class="pm-mac"><div class="pm-mac__screen"><img src="{src}" alt="{alt}" fetchpriority="high"></div>'
                f'<img class="sw-bezel" src="{ASSETS}bezels/macbook-pro-14-black.webp" alt=""></div>')
    if kind == "ipad":
        return (f'<div class="pm-ipad"><img class="pm-ipad__screen" src="{src}" alt="" fetchpriority="high">'
                '<img class="sw-bezel" src="/bilder/rahmen-ipad.webp" alt="" width="1400" height="997"></div>'
                + phone("/bilder/ios-start.webp", "pm-ipad__phone"))
    return f'<img class="pm-window" src="{src}" alt="{alt}" fetchpriority="high">'


def landing_body(a, pages, bb):
    blocks = bb.structure(a["bloecke"])
    text = bb.render(blocks, vergebene=set())
    text = text.replace('<aside class="swiftly" aria-label="Swiftly Player">', '<aside class="sw-callout sw-callout--accent" aria-label="Swiftly Player">')
    text = re.sub(r'<p class="swiftly__marke">.*?</p>', "", text)
    text = re.sub(r'<p class="swiftly__weiter"><a href="#laden">(.*?)</a></p>', r'<p><a class="sw-btn sw-btn--on-accent" href="#download">\1<svg class="sw-tri"><use href="#sw-tri"/></svg></a></p>', text)
    text = re.sub(r'(<aside class="sw-callout[^>]*>)(.*?)(</aside>)',
                  lambda m: m.group(1) + '<svg aria-hidden="true"><use href="#ph-f-info"/></svg><div>' + m.group(2) + "</div>" + m.group(3), text, flags=re.S)
    kind = FRAMES.get(a["pfad"])
    stage = f'<div class="pm-stage">{frame(*kind)}</div>' if kind else ""
    others = "".join(
        f'<li><a href="{b["pfad"]}"><span>{html.escape(b["kurzname"])}</span><svg aria-hidden="true"><use href="#ph-b-arrow-right"/></svg></a></li>'
        for b in pages if b["pfad"] != a["pfad"])
    title = a["titel"]
    meta = ""
    if a["offenlegung"]:
        meta = f'<div class="sw-page-head__meta"><p class="pm-note">{bb.DISCLOSURE}</p></div>'
    # heading with a long sentence: the kit title is 76px, so mark it for a smaller size
    head = page_head([("Swiftly Player", "/"), (a["kurzname"], "")], title, html.escape(a["beschreibung"]), meta)
    head = head.replace('class="sw-page-head__title"', 'class="sw-page-head__title pm-title-long"')
    youos = YOU.get(a["pfad"], "apple")
    stores = [(o, h, i, n, f, r, o == youos, e) for (o, h, i, n, f, r, _, e) in SWIFTLY_STORES]
    return (head + stage + f"""
<main class="sw-section sw-lines" id="inhalt"><div class="sw-g">
  <article class="sw-prose pm-landing">
{text}
  </article>
  <nav class="pm-others" aria-labelledby="andere"><h2 id="andere">Other devices</h2><ul>{others}</ul></nav>
</div></main>
""" + band(["Get Swiftly", "Player."], "Free. Open source. No ads.", stores, "Plex and Emby: beta. Jellyfin 10.8 or newer."))


