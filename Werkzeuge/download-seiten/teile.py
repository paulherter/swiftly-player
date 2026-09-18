# -*- coding: utf-8 -*-
"""Gemeinsame Teile der Download-Seiten von swiftlyplayer.com.
Erzeugt von Hand gepflegte, eigenstaendige HTML-Seiten: die Website liegt
auf einem einfachen Webspace, es gibt keinen Bauschritt beim Ausliefern."""
import re, os

WEBSITE = "/Users/paul/Documents/Swiftly/App/Website"
DISCORD = "https://discord.gg/MeGwfv3UwN"
GITHUB = "https://github.com/paulherter/swiftly-player"
ISSUES = GITHUB + "/issues"
APP_STORE = "https://apps.apple.com/app/id6806824067"
BEWERTEN = APP_STORE + "?action=write-review"
TESTFLIGHT = "https://testflight.apple.com/join/MqeP2cnj"
PLAY = "https://play.google.com/store/apps/details?id=de.paulherter.swiftly"

# Der Grundstil steht in der Android-Seite; sie ist die Vorlage fuer alle
# Download-Seiten (Paul, 17.09.: gleicher Aufbau, gleicher Stil).
GRUND = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "stil-grund.css")).read()
SKIZZEN_CSS = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "skizzen.css")).read()

ZUSATZ_CSS = """
/* Der Kasten oben traegt die eine Handlung der Seite. Er steht vor den
   Schritten: wer weiss, was er will, klickt und liest nicht weiter. */
.download { margin-top: 34px; padding: 24px 22px 22px; border-radius: 24px; text-align: center;
  background: color-mix(in srgb, var(--akzent) 8%, var(--flaeche));
  box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--akzent) 28%, transparent); }
.download p { font-size: 17px; line-height: 1.5; }
.download__klein { margin-top: 14px; color: var(--sehr-leise); font-size: 14.5px; }
.download .knopf { margin-top: 16px; min-height: 52px; padding-inline: 28px; }
@media (min-width: 901px) { .download { padding: 28px 32px 26px; border-radius: 32px; } }

/* Mitmachen: eine Karte mit knappen Zeilen, nie die grossen Downloadknoepfe
   (Paul, 17.09.: sonst sieht es aus wie eine kopierte Kategorie). */
.mitmachen__karte { margin-top: 64px; padding: 26px 22px 20px; border-radius: 24px;
  background: var(--flaeche); border: 1px solid var(--linie); }
.mitmachen__karte h2 { margin: 0; font-size: 22px; font-weight: 600; line-height: 1.15; letter-spacing: -.02em; }
.mitmachen__karte > p { margin-top: 10px; color: var(--leise); font-size: 15.5px; line-height: 1.5; }
.mitmachen__liste { display: grid; gap: 0; margin: 16px 0 0; padding: 0; list-style: none; }
.mitmachen__liste a { display: flex; align-items: center; gap: 12px; min-height: 48px;
  padding: 8px 10px 8px 8px; margin-inline: -8px; border-radius: 14px;
  transition: background-color 160ms var(--raus); }
.mitmachen__zeichen { flex: none; width: 30px; height: 30px; display: grid; place-items: center; border-radius: 10px; }
.mitmachen__zeichen svg { width: 15px; height: 15px; }
.mitmachen__zeichen--akzent { background: rgba(92,209,194,.14); color: var(--akzent); }
.mitmachen__zeichen--kuehl { background: rgba(126,155,255,.14); color: var(--kuehl); }
.mitmachen__zeichen--warm { background: rgba(232,131,58,.14); color: var(--warm); }
.mitmachen__wort { flex: 1 1 auto; min-width: 0; }
.mitmachen__wort b { display: block; font-size: 15px; font-weight: 600; line-height: 1.25; letter-spacing: -.01em; }
.mitmachen__wort em { display: block; font-size: 13px; font-style: normal; line-height: 1.3; color: var(--sehr-leise); }
.mitmachen__pfeil { flex: none; width: 12px; height: 12px; color: var(--sehr-leise); }
.mitmachen__liste a:active { background: rgba(255,255,255,.07); }
@media (min-width: 901px) {
  .mitmachen__karte { padding: 30px 32px 24px; border-radius: 32px; }
  .mitmachen__karte h2 { font-size: 26px; }
  .mitmachen__liste { grid-template-columns: repeat(2, minmax(0,1fr)); column-gap: 20px; }
}
@media (hover: hover) and (pointer: fine) {
  .mitmachen__liste a:hover { background: rgba(255,255,255,.05); }
  .mitmachen__liste a:hover .mitmachen__pfeil { color: var(--leise); }
}

/* Befehl mit Kopieren-Knopf, wie im Blog (Werkzeuge/blog-bauen.py). */
.codeblock { position: relative; margin-top: 18px; }
.codeblock pre { margin: 0; padding: 20px 22px; overflow-x: auto; border-radius: 18px; background: var(--tief);
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

VERHALTEN = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "verhalten.css")).read()
STIL = GRUND.rstrip() + "\n" + SKIZZEN_CSS + ZUSATZ_CSS + VERHALTEN

# ------------------------------------------------------------------ Skizzen

def zeiger(x, y):
    """Ein sauber gezeichneter Zeigerpfeil, Spitze genau auf (x, y).

    Eigene Form, kein fremder Zeiger: Apples und Microsofts Zeiger sind
    geschuetzt, und ein Bild von aussen passt ohnehin nicht zum Stil. Die
    Punkte sind runde Zahlen in einem 12 x 18 grossen Kaestchen, damit der
    Pfeil in jeder Skizze denselben Winkel und dieselbe Groesse hat. Die
    Kontur laeuft ueber non-scaling-stroke: die Skizze skaliert mit ihrem
    viewBox, die Linie bleibt gleich dick.
    """
    pfad = "M0 0 L0 16 L4 12 L7 18 L10 17 L7 11 L12 11 Z"
    return (f'<g transform="translate({x},{y})" style="filter: drop-shadow(0 1.5px 2px rgba(0,0,0,.55))">'
            f'<path d="{pfad}" fill="var(--schrift)" stroke="var(--grund)" stroke-width="1.4" '
            'stroke-linejoin="round" vector-effect="non-scaling-stroke"/>'
            '</g>')


def tipp(x, y):
    """Beruehrung statt Zeiger: zwei Ringe um die Stelle, die getippt wird.

    Auf einer Handyskizze gibt es keine Maus, also steht dort auch kein
    Mauszeiger. Beide Ringe liegen mittig auf (x, y) und sind in jeder
    Skizze gleich gross.
    """
    return (f'<g transform="translate({x},{y})" fill="none" stroke="var(--akzent)" '
            'vector-effect="non-scaling-stroke">'
            '<circle r="20" stroke-width="1.2" opacity=".45"/>'
            '<circle r="13" stroke-width="2"/>'
            '</g>')


def zeile(x, y, w, o=".55"):
    return f'<rect x="{x}" y="{y}" width="{w}" height="8" rx="4" fill="var(--rand)" opacity="{o}"/>'

BROWSER = ('<rect x="14" y="16" width="372" height="178" rx="16" fill="var(--flaeche)" stroke="var(--rand)"/>'
           '<path d="M14 52h372" stroke="var(--linie)"/>'
           '<circle cx="34" cy="34" r="4" fill="var(--rand)"/>'
           '<circle cx="48" cy="34" r="4" fill="var(--rand)"/>'
           '<circle cx="62" cy="34" r="4" fill="var(--rand)"/>'
           '<rect x="84" y="27" width="168" height="15" rx="7.5" fill="var(--erhoeht)"/>')

TELEFON = ('<rect x="132" y="10" width="136" height="190" rx="22" fill="var(--flaeche)" stroke="var(--rand)"/>'
           '<rect x="140" y="20" width="120" height="170" rx="16" fill="var(--tief)" stroke="var(--linie)"/>')

MARKE = ('<rect x="152" y="34" width="34" height="34" rx="11" fill="rgba(47,219,192,.18)" stroke="var(--marke)"/>'
         '<path d="M162 45h14m-14 7h14m-14 7h9" stroke="var(--marke)" stroke-width="1.6" stroke-linecap="round"/>')

def skizze(nummer, titel, inhalt):
    return f"""<svg viewBox="0 0 400 210" role="img" aria-labelledby="skizze{nummer}-titel">
  <title id="skizze{nummer}-titel">{titel}</title>
  {inhalt}
</svg>"""

def figur(svg, bild):
    return f"""      <figure class="skizze">
        {svg}
        <figcaption>{bild}</figcaption>
      </figure>"""

# ------------------------------------------------------------------ Rahmen

def kopf(titel, beschreibung, pfad, og_titel=None, og_text=None, extra_ld=""):
    ort = f"https://swiftlyplayer.com{pfad}"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{titel}</title>
<meta name="description" content="{beschreibung}">
<link rel="canonical" href="{ort}">
<meta property="og:title" content="{og_titel or titel}">
<meta property="og:description" content="{og_text or beschreibung}">
<meta property="og:url" content="{ort}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Swiftly Player">
<meta property="og:image" content="https://swiftlyplayer.com/vorschau.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="iPad, iPhone and an Apple TV, all showing Swiftly Player">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{og_titel or titel}">
<meta name="twitter:description" content="{og_text or beschreibung}">
<meta name="theme-color" content="#0B0B0D">
<link rel="preload" as="font" type="font/woff2" href="/schrift/figtree-latin.woff2" crossorigin>
<link rel="icon" href="/symbol.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
{STIL}</style>
{extra_ld}</head>
<body>

<a class="nur-fuer-leser" href="#inhalt">Skip to content</a>

<header class="leiste">
  <div class="leiste__kapsel">
    <a class="leiste__marke" href="/" aria-label="Swiftly Player, home">
      <img src="/wortmarke.svg" alt="Swiftly" width="61" height="21">
    </a>
    <a class="leiste__punkt" href="/blog/">Blog</a>
    <a class="leiste__punkt" href="{DISCORD}" target="_blank" rel="noopener">Discord</a>
    <a class="leiste__punkt" href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>
    <a class="knopf knopf--leiste nur-desktop" href="/#downloads">Download</a>
    <button class="leiste__burger" type="button" aria-expanded="false" aria-controls="menue" aria-label="Menu">
      <span></span><span></span><span></span>
    </button>
  </div>
</header>

<nav class="menue" id="menue" aria-label="Menu">
  <a href="/blog/">Blog</a>
  <a href="{DISCORD}" target="_blank" rel="noopener">Discord</a>
  <a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>
  <a class="knopf knopf--gross" href="/#downloads">Download</a>
</nav>

<main id="inhalt">
<div class="schein" aria-hidden="true"></div>
<div class="seite">
"""

def fuss(aktuell, mit_kopieren=False):
    def punkt(name, href):
        jetzt = ' aria-current="page"' if href == aktuell else ""
        return f'          <li><a href="{href}"{jetzt}>{name}</a></li>'
    liste = "\n".join([punkt("App Store", "/download/app-store/"),
                       punkt("TestFlight", "/download/testflight/"),
                       punkt("Android", "/android/"),
                       punkt("Windows", "/download/windows/"),
                       punkt("Linux", "/download/linux/")])
    kopieren = """
  /* Kopieren-Knopf am Befehl, mit sichtbarer Bestaetigung. Er wird erst
     hier gesetzt: ohne Skript stuende sonst ein Knopf da, der nichts tut. */
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
""" if mit_kopieren else ""
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
{liste}
        </ul>
      </div>
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
      Swiftly Player is not part of the Jellyfin project and hosts nothing itself. App Store is a
      service mark of Apple Inc. Google Play and Android are trademarks of Google LLC. Windows is a
      trademark of Microsoft Corporation. The drawings on this page are our own and show no material
      from those companies. The code is under the MPL-2.0; the name, the wordmark and the app icon
      are not.
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
{kopieren}}})();
</script>
</body>
</html>
"""

# ------------------------------------------------------------------ Mitmachen

ZEICHEN = {
  "discord": '<path d="M2 3.2a1.2 1.2 0 0 1 1.2-1.2h5.6A1.2 1.2 0 0 1 10 3.2v4a1.2 1.2 0 0 1-1.2 1.2H5.4L3 10.4V8.4h.2A1.2 1.2 0 0 1 2 7.2z"/>',
  "stern": '<path d="m6 1.6 1.35 2.75 3.05.45-2.2 2.15.5 3.05L6 8.55 3.3 10l.5-3.05-2.2-2.15 3.05-.45z"/>',
  "fehler": '<circle cx="6" cy="6" r="4.6"/><path d="M6 3.6v2.8M6 8.3v.1"/>',
  "code": '<path d="M4 3.4 1.6 6 4 8.6M8 3.4 10.4 6 8 8.6"/>',
  "brief": '<path d="M1.6 3.4h8.8v5.2H1.6z"/><path d="m1.6 3.6 4.4 3 4.4-3"/>',
}

def mitmachen(titel, satz, punkte):
    zeilen = []
    for zeichen, farbe, name, unter, href in punkte:
        aus = ' target="_blank" rel="noopener"' if href.startswith("http") else ""
        zeilen.append(f"""        <li>
          <a href="{href}"{aus}>
            <span class="mitmachen__zeichen mitmachen__zeichen--{farbe}" aria-hidden="true">
              <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">{ZEICHEN[zeichen]}</svg>
            </span>
            <span class="mitmachen__wort"><b>{name}</b><em>{unter}</em></span>
            <svg class="mitmachen__pfeil" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M4.5 2.5 8 6l-3.5 3.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </a>
        </li>""")
    inhalt = "\n".join(zeilen)
    return f"""  <section class="mitmachen__karte" aria-labelledby="mitmachen">
      <h2 id="mitmachen">{titel}</h2>
      <p>{satz}</p>
      <ul class="mitmachen__liste">
{inhalt}
      </ul>
  </section>"""

HILFE = f"""  <div class="hilfe">
    <p>Stuck somewhere? Ask on Discord.</p>
    <a class="knopf knopf--leise" href="{DISCORD}" target="_blank" rel="noopener">Get help on Discord</a>
  </div>"""

def andere(ausser):
    alle = [("Windows", "/download/windows/"), ("Linux", "/download/linux/"),
            ("iPhone, iPad, Mac and Apple TV", "/download/app-store/"),
            ("Android and Android TV", "/android/"), ("TestFlight", "/download/testflight/")]
    teile = [f'<a href="{h}">{n}</a>' for n, h in alle if h != ausser]
    return f"""  <section class="abschnitt" aria-labelledby="andere">
    <h2 id="andere">Other systems</h2>
    <p>Swiftly Player also runs on {", ".join(teile[:-1])} and {teile[-1]}. Every download is on the <a href="/#downloads">start page</a>.</p>
  </section>"""

def schreiben(pfad, text):
    ganz = os.path.join(WEBSITE, pfad.strip("/"), "index.html")
    os.makedirs(os.path.dirname(ganz), exist_ok=True)
    open(ganz, "w").write(text)
    print("geschrieben", ganz, len(text))
