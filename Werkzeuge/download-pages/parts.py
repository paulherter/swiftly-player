# -*- coding: utf-8 -*-
"""Shared parts of the swiftlyplayer.com download pages.
Generates hand-maintained, self-contained HTML pages: the website sits
on simple web hosting, with no build step on delivery."""
import re, os

WEBSITE = os.environ.get("SWIFTLY_WEBSITE") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "Website")
DISCORD = "https://discord.gg/MeGwfv3UwN"
GITHUB = "https://github.com/paulherter/swiftly-player"
ISSUES = GITHUB + "/issues"
APP_STORE = "https://apps.apple.com/app/id6806824067"
RATE = APP_STORE + "?action=write-review"
TESTFLIGHT = "https://testflight.apple.com/join/MqeP2cnj"
PLAY = "https://play.google.com/store/apps/details?id=de.paulherter.swiftly"

# The base style lives in the Android page; it is the template for all
# download pages (same structure, same style).
REASON = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "style-base.css")).read()
SKIZZEN_CSS = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sketches.css")).read()

ADDITION_CSS = """
/* The box at the top holds the page's one action. It sits before the
   steps: anyone who knows what they want clicks and reads no further. */
.download { margin-top: 34px; padding: 24px 22px 22px; border-radius: 16px; text-align: center;
  background: color-mix(in srgb, var(--akzent) 8%, var(--flaeche));
  box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 28%, transparent); }
.download p { font-size: 17px; line-height: 1.5; }
.download__klein { margin-top: 14px; color: var(--sehr-leise); font-size: 14.5px; }
.download .knopf { margin-top: 16px; min-height: 52px; padding-inline: 28px; }
@media (min-width: 901px) { .download { padding: 28px 32px 26px; border-radius: 16px; } }

/* One quiet line to the supporter page, below the help box. */
.kaffeehinweis { margin-top: 18px; text-align: center; color: var(--sehr-leise); font-size: 15px; line-height: 1.55; }
.kaffeehinweis a { color: var(--leise); text-decoration: underline; text-underline-offset: 3px; }

/* Get involved: one card with short lines, never the large download buttons
   (otherwise it looks like a copied category). */
.mitmachen__karte { margin-top: 64px; padding: 26px 22px 20px; border-radius: 16px;
  background: var(--flaeche); }
.mitmachen__karte h2 { margin: 0; font-size: 22px; font-weight: 600; line-height: 1.15; letter-spacing: -.02em; }
.mitmachen__karte > p { margin-top: 10px; color: var(--leise); font-size: 15.5px; line-height: 1.5; }
.mitmachen__liste { display: grid; gap: 0; margin: 16px 0 0; padding: 0; list-style: none; }
.mitmachen__liste a { display: flex; align-items: center; gap: 12px; min-height: 48px;
  padding: 8px 10px 8px 8px; margin-inline: -8px; border-radius: 14px;
  transition: background-color 160ms var(--raus); }
.mitmachen__zeichen { flex: none; width: 30px; height: 30px; display: grid; place-items: center; border-radius: 10px; }
.mitmachen__zeichen svg { width: 15px; height: 15px; }
.mitmachen__zeichen--akzent { background: rgba(80,213,218,.14); color: var(--akzent); }
.mitmachen__zeichen--kuehl { background: rgba(80,213,218,.14); color: var(--kuehl); }
.mitmachen__zeichen--warm { background: rgba(80,213,218,.14); color: var(--warm); }
.mitmachen__wort { flex: 1 1 auto; min-width: 0; }
.mitmachen__wort b { display: block; font-size: 15px; font-weight: 600; line-height: 1.25; letter-spacing: -.01em; }
.mitmachen__wort em { display: block; font-size: 13px; font-style: normal; line-height: 1.3; color: var(--sehr-leise); }
.mitmachen__pfeil { flex: none; width: 12px; height: 12px; color: var(--sehr-leise); }
.mitmachen__liste a:active { background: rgba(255,255,255,.07); }
@media (min-width: 901px) {
  .mitmachen__karte { padding: 30px 32px 24px; border-radius: 16px; }
  .mitmachen__karte h2 { font-size: 26px; }
  .mitmachen__liste { grid-template-columns: repeat(2, minmax(0,1fr)); column-gap: 20px; }
}
@media (hover: hover) and (pointer: fine) {
  .mitmachen__liste a:hover { background: rgba(255,255,255,.05); }
  .mitmachen__liste a:hover .mitmachen__pfeil { color: var(--leise); }
}

/* Command with copy button, as in the blog (Werkzeuge/blog-bauen.py). */
.codeblock { position: relative; margin-top: 18px; }
.codeblock pre { margin: 0; padding: 20px 22px; overflow-x: auto; border-radius: 14px; background: var(--tief);
  border: 1px solid var(--linie); font-size: 15px; line-height: 1.55; }
.codeblock code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; }
.kopieren { position: absolute; top: 10px; right: 12px; display: inline-flex; align-items: center;
  min-height: 36px; padding: 8px 14px; border: 0; border-radius: 999px; box-shadow: inset 0 0 0 1px var(--rand);
  background: var(--erhoeht); color: var(--leise); font-family: inherit; font-size: 13.5px; font-weight: 600;
  line-height: 1; cursor: pointer; transition: color 160ms var(--raus), box-shadow 160ms var(--raus); }
.kopieren[data-kopiert] { color: var(--akzent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 45%, transparent); }
.befehlszeile { margin-top: 10px; color: var(--sehr-leise); font-size: 14.5px; line-height: 1.5; }
@media (max-width: 700px) {
  .kopieren { position: static; margin-top: 10px; min-height: 44px; width: 100%; justify-content: center; }
}
.paketliste { margin: 14px 0 0; padding: 0; list-style: none; }
.paketliste li { display: flex; gap: 10px; padding: 10px 0; border-top: 1px solid var(--linie);
  color: var(--leise); font-size: 16px; line-height: 1.45; }
.paketliste b { flex: none; min-width: 96px; color: var(--schrift); font-weight: 600; }
"""

BEHAVIOR = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "behavior.css")).read()
STYLE = REASON.rstrip() + "\n" + SKIZZEN_CSS + ADDITION_CSS + BEHAVIOR

# ------------------------------------------------------------------ Sketches

def pointer(x, y):
    """A cleanly drawn pointer arrow, tip exactly at (x, y).

    Own shape, not a third-party pointer: Apple's and Microsoft's pointers
    are protected, and an outside image would not fit the style anyway. The
    points are round numbers in a 12 x 18 box so the arrow has the same
    angle and size in every sketch. The outline uses non-scaling-stroke:
    the sketch scales with its viewBox, the line keeps its thickness.
    """
    path = "M0 0 L0 16 L4 12 L7 18 L10 17 L7 11 L12 11 Z"
    return (f'<g transform="translate({x},{y})" style="filter: drop-shadow(0 1.5px 2px rgba(0,0,0,.55))">'
            f'<path d="{path}" fill="var(--schrift)" stroke="var(--grund)" stroke-width="1.4" '
            'stroke-linejoin="round" vector-effect="non-scaling-stroke"/>'
            '</g>')


def tap(x, y):
    """Touch instead of pointer: two rings around the spot that is tapped.

    A phone sketch has no mouse, so there is no mouse pointer either. Both
    rings are centered on (x, y) and have the same size in every sketch.
    """
    return (f'<g transform="translate({x},{y})" fill="none" stroke="var(--akzent)" '
            'vector-effect="non-scaling-stroke">'
            '<circle r="20" stroke-width="1.2" opacity=".45"/>'
            '<circle r="13" stroke-width="2"/>'
            '</g>')


def row(x, y, w, o=".55"):
    return f'<rect x="{x}" y="{y}" width="{w}" height="8" rx="4" fill="var(--rand)" opacity="{o}"/>'

BROWSER = ('<rect x="14" y="16" width="372" height="178" rx="16" fill="var(--flaeche)" stroke="var(--rand)"/>'
           '<path d="M14 52h372" stroke="var(--linie)"/>'
           '<circle cx="34" cy="34" r="4" fill="var(--rand)"/>'
           '<circle cx="48" cy="34" r="4" fill="var(--rand)"/>'
           '<circle cx="62" cy="34" r="4" fill="var(--rand)"/>'
           '<rect x="84" y="27" width="168" height="15" rx="7.5" fill="var(--erhoeht)"/>')

PHONE = ('<rect x="132" y="10" width="136" height="190" rx="22" fill="var(--flaeche)" stroke="var(--rand)"/>'
           '<rect x="140" y="20" width="120" height="170" rx="16" fill="var(--tief)" stroke="var(--linie)"/>')

MARK = ('<rect x="152" y="34" width="34" height="34" rx="11" fill="rgba(80,213,218,.18)" stroke="var(--marke)"/>'
         '<path d="M162 45h14m-14 7h14m-14 7h9" stroke="var(--marke)" stroke-width="1.6" stroke-linecap="round"/>')

def sketch(number, title, content):
    return f"""<svg viewBox="0 0 400 210" role="img" aria-labelledby="skizze{number}-titel">
  <title id="skizze{number}-titel">{title}</title>
  {content}
</svg>"""

def figure(svg, image):
    return f"""      <figure class="skizze">
        {svg}
        <figcaption>{image}</figcaption>
      </figure>"""

# ------------------------------------------------------------------ Frame

# Swiftly Music gets a "Music" item in the bar once the page
# /music/ is live. Until then only the draft itself shows it.
MUSIC_LIVE = True

# ------------------------------------------------------------------ Supporter
# One switch for the supporter page and every way to it on the site.
#   "off"      no page and no links; the generators remove what they added
#   "preview"  page and links are generated locally, the form does not send,
#              and website-upload.py refuses to upload
#   "live"     page and links go up, the form posts to the checkout
# After changing it, run page_supporter.py first (it also maintains the
# hand-written pages), then the other generators and blog-build.py.
SUPPORTER = "live"
SUPPORTER_ON = SUPPORTER in ("preview", "live")
SUPPORTER_PATH = "/supporter/"
SUPPORTER_LINK = "Donate"
# Second button next to Download (it takes the place of the other app's button) in the header of the home and music page.
# Its style travels with the supporter block in index.html (page_supporter.py),
# which the music page copies.
DONATE_BUTTON = ('        <a class="knopf knopf--gross knopf--zweit knopf--spenden hero__knopf" href="/supporter/">'
                 '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.2a4.3 4.3 0 0 1 7.5 2.6C19.5 15.4 12 20 12 20z"/></svg>'
                 'Donate</a>')


def supporter_upload_block(website=WEBSITE):
    """Why an upload must not run now, or None. Before "live" nothing may go up
    while the site still carries the page or a link to it, so a dead form
    never reaches the server by accident."""
    if SUPPORTER == "live":
        return None
    if os.path.isdir(os.path.join(website, SUPPORTER_PATH.strip("/"))):
        return (f'Supporter is "{SUPPORTER}" in parts.py, but Website{SUPPORTER_PATH} exists. '
                'Set it to "off" and run the generators, or to "live" once the checkout works.')
    for root, folders, files in os.walk(website):
        folders[:] = [f for f in folders if not f.startswith(".") and f not in ("quellen", "aufnahmen", "bilder", "schrift")]
        for name in files:
            if name.endswith((".html", ".php", ".txt", ".json", ".xml")):
                with open(os.path.join(root, name), encoding="utf-8", errors="ignore") as h:
                    if f'href="{SUPPORTER_PATH}"' in h.read():
                        rel = os.path.relpath(os.path.join(root, name), website)
                        return (f'Supporter is "{SUPPORTER}" in parts.py, but {rel} links to {SUPPORTER_PATH}. '
                                'Set it to "off" and run the generators, or to "live" once the checkout works.')
    return None


def header(title, description, path, og_title=None, og_text=None, extra_ld="", music=False):
    place = f"https://swiftlyplayer.com{path}"
    show = music or MUSIC_LIVE
    now = ' aria-current="page"' if music else ""
    music_bar = f'\n    <a class="leiste__punkt" href="/music/"{now}>Music</a>' if show else ""
    music_menu = f'\n  <a href="/music/"{now}>Music</a>' if show else ""
    here = ' aria-current="page"' if path == SUPPORTER_PATH else ""
    coffee_menu = f'\n  <a href="{SUPPORTER_PATH}"{here}>{SUPPORTER_LINK}</a>' if SUPPORTER_ON else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="canonical" href="{place}">
<meta property="og:title" content="{og_title or title}">
<meta property="og:description" content="{og_text or description}">
<meta property="og:url" content="{place}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Swiftly Player">
<meta property="og:image" content="https://swiftlyplayer.com/vorschau.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="iPad, iPhone and an Apple TV, all showing Swiftly Player">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{og_title or title}">
<meta name="twitter:description" content="{og_text or description}">
<meta name="theme-color" content="#101010">
<link rel="preload" as="font" type="font/woff2" href="/schrift/figtree-latin.woff2" crossorigin>
<link rel="icon" href="/symbol.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
{STYLE}</style>
{extra_ld}</head>
<body>

<a class="nur-fuer-leser" href="#inhalt">Skip to content</a>

<header class="leiste">
  <div class="leiste__kapsel">
    <a class="leiste__marke" href="/" aria-label="Swiftly Player, home">
      <img src="/wortmarke.svg" alt="Swiftly" width="61" height="21">
    </a>{music_bar}
    <a class="leiste__punkt" href="/blog/">Blog</a>
    <a class="leiste__punkt" href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>
    <button class="leiste__burger" type="button" aria-expanded="false" aria-controls="menue" aria-label="Menu">
      <span></span><span></span><span></span>
    </button>
  </div>
</header>

<nav class="menue" id="menue" aria-label="Menu">{music_menu}
  <a href="/blog/">Blog</a>
  <a href="{DISCORD}" target="_blank" rel="noopener">Discord</a>
  <a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>{coffee_menu}
  <a class="knopf knopf--gross" href="/#downloads">Download</a>
</nav>

<main id="inhalt">
<div class="schein" aria-hidden="true"></div>
<div class="seite">
"""

def footer(current, with_copy=False):
    def point(name, href):
        now = ' aria-current="page"' if href == current else ""
        return f'          <li><a href="{href}"{now}>{name}</a></li>'
    coffee_footer = ("\n" + point(SUPPORTER_LINK, SUPPORTER_PATH)) if SUPPORTER_ON else ""
    list = "\n".join([point("App Store", "/download/app-store/"),
                       point("TestFlight", "/download/testflight/"),
                       point("Android", "/android/"),
                       point("Windows", "/download/windows/"),
                       point("Linux", "/download/linux/")])
    copy = """
  /* Copy button on the command, with visible confirmation. It is only added
     here: without script there would be a button that does nothing. */
  document.querySelectorAll(".codeblock").forEach(function (kasten) {
    var code = kasten.querySelector("code");
    if (!code) { return; }
    var knopf = document.createElement("button");
    knopf.type = "button";
    knopf.className = "kopieren";
    knopf.textContent = "Copy";
    var zurueck = 0;
    knopf.addEventListener("click", function () {
      var fertig = function (gut) {
        knopf.textContent = gut ? "Copied" : "Press Ctrl C";
        if (gut) { knopf.setAttribute("data-kopiert", ""); }
        clearTimeout(zurueck);
        zurueck = setTimeout(function () { knopf.textContent = "Copy"; knopf.removeAttribute("data-kopiert"); }, 2000);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(code.textContent).then(function () { fertig(true); }, function () { fertig(false); });
      } else {
        var feld = document.createElement("textarea");
        feld.value = code.textContent;
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
""" if with_copy else ""
    return f"""</div>
</main>

<footer class="fuss">
  <div class="bahn">
    <div class="fuss__linie"></div>
    <div class="fuss__raster">
      <div class="fuss__marke">
        <img src="/wortmarke.svg" alt="Swiftly" width="61" height="21">
        <p>A video player for your own Jellyfin server. Built by one person.</p>
      </div>
      <div class="fuss__spalte">
        <h2>Download</h2>
        <ul>
{list}
        </ul>
      </div>
      <div class="fuss__spalte">
        <h2>Elsewhere</h2>
        <ul>
          <li><a href="/about/">About</a></li>
          <li><a href="/blog/">Blog</a></li>
          <li><a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a></li>
          <li><a href="{DISCORD}" target="_blank" rel="noopener">Discord</a></li>{coffee_footer}
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
          <li><a href="/licenses/">Open-source licenses</a></li>
        </ul>
      </div>
    </div>
    <div class="fuss__linie"></div>
    <p class="fuss__klein">
      Swiftly Player is not part of the Jellyfin project and hosts nothing itself. App Store is a
      service mark of Apple Inc. Google Play and Android are trademarks of Google LLC. Windows is a
      trademark of Microsoft Corporation. The drawings on this page are our own and show no material
      from those companies. The code is under the MPL-2.0; the name, the wordmark and the app icon
      are not. Playback uses VLCKit and libVLC by VideoLAN under the LGPL-2.1-or-later:
      <a href="/licenses/">licenses and source</a>.
    </p>
  </div>
</footer>

<script>
(function () {{
  var burger = document.querySelector(".leiste__burger");
  var menue = document.getElementById("menue");
  if (burger && menue) {{
    var setzen = function (offen) {{
      burger.setAttribute("aria-expanded", offen ? "true" : "false");
      if (offen) {{ menue.setAttribute("data-offen", ""); }} else {{ menue.removeAttribute("data-offen"); }}
    }};
    burger.addEventListener("click", function () {{ setzen(burger.getAttribute("aria-expanded") !== "true"); }});
    menue.addEventListener("click", function (e) {{ if (e.target.closest("a")) setzen(false); }});
    document.addEventListener("keydown", function (e) {{ if (e.key === "Escape") setzen(false); }});
  }}
{copy}}})();
</script>
</body>
</html>
"""

# One FAQ entry as details, so it works without script.
def question(title, response, opened=False):
    return f"""      <details class="frage"{' open' if opened else ''}>
        <summary class="frage__knopf"><h3>{title}</h3>
          <svg class="frage__pfeil" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M7.5 4.5 13 10l-5.5 5.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></summary>
        <div class="frage__antwort"><p>{response}</p></div>
      </details>"""


# ------------------------------------------------------------------ Get involved

GLYPH = {
  "discord": '<path d="M2 3.2a1.2 1.2 0 0 1 1.2-1.2h5.6A1.2 1.2 0 0 1 10 3.2v4a1.2 1.2 0 0 1-1.2 1.2H5.4L3 10.4V8.4h.2A1.2 1.2 0 0 1 2 7.2z"/>',
  "stern": '<path d="m6 1.6 1.35 2.75 3.05.45-2.2 2.15.5 3.05L6 8.55 3.3 10l.5-3.05-2.2-2.15 3.05-.45z"/>',
  "fehler": '<circle cx="6" cy="6" r="4.6"/><path d="M6 3.6v2.8M6 8.3v.1"/>',
  "code": '<path d="M4 3.4 1.6 6 4 8.6M8 3.4 10.4 6 8 8.6"/>',
  "brief": '<path d="M1.6 3.4h8.8v5.2H1.6z"/><path d="m1.6 3.6 4.4 3 4.4-3"/>',
}

def join(title, sentence, points):
    rows = []
    for glyph, color, name, under, href in points:
        fromValue = ' target="_blank" rel="noopener"' if href.startswith("http") else ""
        rows.append(f"""        <li>
          <a href="{href}"{fromValue}>
            <span class="mitmachen__zeichen mitmachen__zeichen--{color}" aria-hidden="true">
              <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">{GLYPH[glyph]}</svg>
            </span>
            <span class="mitmachen__wort"><b>{name}</b><em>{under}</em></span>
            <svg class="mitmachen__pfeil" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M4.5 2.5 8 6l-3.5 3.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </a>
        </li>""")
    content = "\n".join(rows)
    return f"""  <section class="mitmachen__karte" aria-labelledby="mitmachen">
      <h2 id="mitmachen">{title}</h2>
      <p>{sentence}</p>
      <ul class="mitmachen__liste">
{content}
      </ul>
  </section>"""

# Appears on every download page: anyone downloading the app learns that VLCKit
# or libVLC is inside and where license and source code are (LGPL 2.1, section 6).
VLC_HINT = """  <p class="lizenzhinweis">Swiftly Player uses VLCKit and libVLC by VideoLAN under the LGPL 2.1 or later. <a href="/licenses/">Licenses and source</a></p>
"""

HELP = f"""  <div class="hilfe">
    <p>Stuck somewhere? Ask on Discord.</p>
    <a class="knopf knopf--leise" href="{DISCORD}" target="_blank" rel="noopener">Get help on Discord</a>
  </div>"""
# Below the help box on every download page: one quiet line to the supporter page.
if SUPPORTER_ON:
    HELP += f"""
  <p class="kaffeehinweis">All the features you need are free. If it helps you, <a href="{SUPPORTER_PATH}">buy us a coffee</a>.</p>"""

def other(ausser):
    all = [("Windows", "/download/windows/"), ("Linux", "/download/linux/"),
            ("iPhone, iPad, Mac and Apple TV", "/download/app-store/"),
            ("Android and Android TV", "/android/"), ("TestFlight", "/download/testflight/")]
    teile = [f'<a href="{h}">{n}</a>' for n, h in all if h != ausser]
    return f"""  <section class="abschnitt" aria-labelledby="andere">
    <h2 id="andere">Other systems</h2>
    <p>Swiftly Player also runs on {", ".join(teile[:-1])} and {teile[-1]}. Every download is on the <a href="/#downloads">start page</a>.</p>
  </section>"""

def write(path, text):
    whole = os.path.join(WEBSITE, path.strip("/"), "index.html")
    os.makedirs(os.path.dirname(whole), exist_ok=True)
    open(whole, "w").write(text)
    print("geschrieben", whole, len(text))
