# -*- coding: utf-8 -*-
"""Seite /music/ fuer Swiftly Music, gebaut aus dem Stylesheet der Startseite.

Das CSS und die Fusszeile kommen bei jedem Bau aus Website/index.html: die
Seite sieht damit zwangslaeufig aus wie die Startseite (Rand, Bahn, Kacheln,
Ecken, Knoepfe, Aurora), und aendert sich die Startseite, zieht sie mit.

Solange ZIEL auf den Entwurf zeigt, landet sie unter Website/.entwurf/music/.
Versteckte Ordner laedt website-hochladen.py nie hoch. Live gehen: siehe
Website/.entwurf/music/LIVE.md.
"""
import html as _html
import json
import os
import re
import shutil
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import WEBSITE, DISCORD, GITHUB

ZIEL = "/music/"
PFAD = "/music/"

# Oeffentlicher Link der Gruppe „Swiftly Music Beta", sobald Apple die
# Beta-Pruefung durch hat. Bis dahin fuehrt Download auf den Discord.
MUSIC_TESTFLIGHT = "https://testflight.apple.com/join/Ws5snXzX"

# Echte Bildschirme liegen als Website/bilder/music-<name>.webp; fehlt einer,
# zeigt der Schirm den Nachbau.

WORTMARKE = "/Users/paul/Documents/Swiftly/Notizen/SwiftlyMusic/logo/wortmarke.svg"

DOWNLOAD = MUSIC_TESTFLIGHT or DISCORD
WEG_TITEL = "TestFlight" if MUSIC_TESTFLIGHT else "Beta on TestFlight"
WEG_TEXT = "iPhone, free beta" if MUSIC_TESTFLIGHT else "Opening soon, news on Discord"
BETA_ZEILE = ("Free beta on TestFlight. No account, no ads." if MUSIC_TESTFLIGHT
              else "Beta for iPhone, coming to TestFlight. No account, no ads.")

# ------------------------------------------------------------------ Stil

index = open(os.path.join(WEBSITE, "index.html"), encoding="utf-8").read()
STIL = re.search(r"<style>(.*?)</style>", index, re.S).group(1)
STIL = STIL.replace("url(schrift/", "url(/schrift/").replace("url(aufnahmen/", "url(/aufnahmen/")
FUSS = re.search(r"<footer class=\"fuss\">.*?</footer>", index, re.S).group(0)
FUSS = FUSS.replace('src="wortmarke.svg"', 'src="/wortmarke.svg"')
FUSS = re.sub(r'<div class="fuss__marke">.*?</div>',
              '<div class="fuss__marke">\n        <img src="wortmarke-music.svg" alt="Swiftly Music" width="62" height="21">\n'
              '        <p>A music player for your own Jellyfin or Navidrome server. Built by one person.</p>\n      </div>',
              FUSS, count=1, flags=re.S)

EIGEN = """
/* ================= Nur /music/ =================
   Alles andere kommt unveraendert aus der Startseite. */
.knopf--zweit { background: var(--flaeche); color: var(--schrift); }
.knopf--zweit:active { background: var(--gedrueckt); }
.hero__knoepfe { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; margin-top: 26px; }
.hero__knoepfe .hero__knopf { margin-top: 0; }

/* Drei iPhones auf der Buehne: links und rechts gekippt wie Mac und TV
   auf der Startseite, das mittlere vorn. */
.hero__buehne .geraet--links  { left: 21.5%; top: 16%; width: 17.2%; transform: rotate(-5deg); }
.hero__buehne .geraet--mitte  { left: 39.24%; top: 5.6%; width: 21.53%; z-index: 3;
  filter: drop-shadow(0 40px 60px rgba(0,0,0,.55)); }
.hero__buehne .geraet--rechts { left: 61.3%; top: 16%; width: 17.2%; transform: rotate(5deg); }

/* ---------- Nachgebaute Schirme. Alles in cqw: 1cqw = 1 % der Geraetebreite,
   so waechst der Inhalt mit dem Rahmen wie ein echtes Bild. ---------- */
div.geraet__schirm { background: var(--grund); overflow: hidden; }
.schirm { position: absolute; inset: 0; padding: 15cqw 6.5cqw 6cqw; display: flex; flex-direction: column; gap: 3cqw;
  font-family: var(--schriftart); color: var(--schrift); }
.schirm__griff { width: 9cqw; height: 1cqw; border-radius: 1cqw; background: rgba(255,255,255,.25); margin: -5cqw auto 2cqw; }
.schirm__kopf { font-size: 7.4cqw; font-weight: 700; letter-spacing: -.021em; }
.schirm__reihe { font-size: 5.2cqw; font-weight: 600; margin-top: 2cqw; }
.schirm__klein { font-size: 3.4cqw; color: var(--sehr-leise); }
.huelle { aspect-ratio: 1; border-radius: 2.6cqw; }
.schirm__raster { display: grid; grid-template-columns: repeat(3, 1fr); gap: 3cqw; }
.schirm__raster .huelle { border-radius: 2.6cqw; }
.schirm__titel { display: flex; justify-content: space-between; align-items: end; gap: 2cqw; margin-top: 3cqw; }
.schirm__titel b { display: block; font-size: 6.2cqw; font-weight: 600; letter-spacing: -.014em; }
.schirm__titel span { font-size: 4.6cqw; color: var(--leise); font-weight: 600; }
.schirm__plakette { font-size: 3.2cqw; font-weight: 600; color: var(--akzent);
  background: color-mix(in srgb, var(--akzent) 15%, transparent); padding: 1.2cqw 2.2cqw; border-radius: 2cqw; }
.schirm__spur { height: 1.3cqw; border-radius: 1cqw; background: rgba(255,255,255,.3); position: relative; margin-top: 3cqw; }
.schirm__spur::before { content: ""; position: absolute; inset: 0 58% 0 0; border-radius: inherit; background: var(--akzent); }
.schirm__zeiten { display: flex; justify-content: space-between; font-size: 3.2cqw; color: var(--sehr-leise); font-variant-numeric: tabular-nums; }
.schirm__steuer { display: flex; justify-content: space-between; align-items: center; margin-top: 1cqw; }
.schirm__steuer svg { width: 7cqw; height: 7cqw; fill: var(--schrift); }
.schirm__steuer .an { fill: var(--akzent); }
.schirm__spiel { width: 19cqw; height: 19cqw; border-radius: 50%; background: var(--schrift); display: grid; place-items: center; }
.schirm__spiel svg { width: 7.5cqw; height: 7.5cqw; fill: var(--auf-akzent); }
.schirm__aktionen { display: flex; justify-content: space-around; margin-top: auto; font-size: 3.2cqw; color: var(--leise); }
.schirm__aktionen span { display: grid; justify-items: center; gap: 1.2cqw; }
.schirm__aktionen svg { width: 5.4cqw; height: 5.4cqw; fill: none; stroke: var(--leise); stroke-width: 2; }
.schirm__lied { display: flex; gap: 3cqw; align-items: center; }
.schirm__lied .huelle { width: 13cqw; flex: none; border-radius: 2cqw; }
.schirm__lied b { display: block; font-size: 4.4cqw; font-weight: 600; }
.schirm__lied span { font-size: 3.6cqw; color: var(--sehr-leise); }
.schirm__liedtext { display: grid; gap: 3.6cqw; margin-top: 4cqw; font-size: 8cqw; font-weight: 700; line-height: 1.16; letter-spacing: -.021em; }
.schirm__liedtext .vorbei { color: #5C5C5C; }
.schirm__liedtext .kommt { color: var(--sehr-leise); }
.schirm__zeile { display: flex; gap: 3cqw; align-items: center; padding-block: 1.6cqw; border-bottom: 1px solid var(--linie); }
.schirm__zeile .huelle { width: 12cqw; flex: none; border-radius: 2cqw; }
.schirm__zeile b { display: block; font-size: 4.2cqw; font-weight: 600; }
.schirm__zeile span { font-size: 3.4cqw; color: var(--sehr-leise); }
.schirm__mini { margin-top: auto; display: flex; gap: 3cqw; align-items: center; background: var(--flaeche);
  border-radius: 4cqw; padding: 2.4cqw; }
.schirm__mini .huelle { width: 11cqw; border-radius: 2cqw; flex: none; }
.schirm__mini b { font-size: 4cqw; font-weight: 600; display: block; }
.schirm__mini span { font-size: 3.2cqw; color: var(--leise); }

/* Huellen: gerechnete Plattencover, bis echte Bildschirme kommen. */
.h1 { background: radial-gradient(circle at 30% 30%, #5fd6db 0 12%, transparent 12.5%), repeating-linear-gradient(115deg, #143b3d 0 5%, #0f2c2e 5% 10%); }
.h2 { background: linear-gradient(160deg, #3a2a1c, #d9864a 60%, #f1c27d); }
.h3 { background: radial-gradient(circle at 50% 50%, #111 0 18%, #e8e8e8 18.5% 22%, #111 22.5%); }
.h4 { background: linear-gradient(0deg, #1d1d3a 0 50%, #6c5ce7 50%); }
.h5 { background: repeating-radial-gradient(circle at 20% 80%, #2b2b2b 0 4%, #3a3a3a 4% 8%); }
.h6 { background: linear-gradient(135deg, #0e3b2c, #2fbf88); }
.h7 { background: radial-gradient(circle at 70% 30%, #f5f5f5 0 14%, transparent 14.5%), #b23a3a; }
.h8 { background: linear-gradient(90deg, #222 0 33%, #50D5DA 33% 66%, #eee 66%); }
.h9 { background: conic-gradient(from 45deg, #412b5e, #c17bd6, #412b5e); }

/* ---------- Bento: dieselben drei Kacheln wie die Startseite ---------- */
.kachel--mobil .geraet--hinten { right: 6%; bottom: -24%; width: 40%; transform: rotate(6deg); z-index: 1; opacity: .9; }
.kachel--mobil .geraet--vorn { left: 8%; bottom: -12%; width: 48%; z-index: 2; }
.lautsprecher {
  position: absolute; right: 6%; top: 50%; translate: 0 -50%; width: 50%;
  background: var(--flaeche); border-radius: 16px; padding: 18px 18px 8px;
  display: grid; gap: 4px;
}
.lautsprecher__kopf { font-size: 13px; color: var(--sehr-leise); font-weight: 600; margin-bottom: 6px; }
.lautsprecher__zeile { display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; align-items: center; padding-block: 8px; }
.lautsprecher__zeile + .lautsprecher__zeile { border-top: 1px solid var(--linie); }
.lautsprecher__zeichen { width: 32px; height: 32px; border-radius: 10px; background: var(--erhoeht); display: grid; place-items: center; grid-row: span 2; }
.lautsprecher__zeichen svg { width: 16px; height: 16px; fill: none; stroke: var(--leise); stroke-width: 1.8; }
.lautsprecher__zeile--an .lautsprecher__zeichen { background: var(--akzent-leise); }
.lautsprecher__zeile--an .lautsprecher__zeichen svg { stroke: var(--akzent); }
.lautsprecher__zeile b { font-size: 14px; font-weight: 600; }
.regler { height: 4px; border-radius: 2px; background: rgba(255,255,255,.18); position: relative; }
.regler i { position: absolute; inset: 0 auto 0 0; border-radius: inherit; background: var(--schrift); }
.lautsprecher__zeile--an .regler i { background: var(--akzent); }

.qualitaet { position: absolute; right: 6%; top: 50%; translate: 0 -50%; width: 46%;
  background: var(--flaeche); border-radius: 16px; padding: 8px 18px; }
.qualitaet__kopf { font-size: 13px; color: var(--sehr-leise); font-weight: 600; padding: 10px 0 4px; }
.qualitaet__zeile { display: flex; justify-content: space-between; align-items: center; padding-block: 11px; font-size: 15px; font-weight: 500; color: var(--leise); }
.qualitaet__zeile + .qualitaet__zeile { border-top: 1px solid var(--linie); }
.qualitaet__zeile--an { color: var(--schrift); font-weight: 600; }
.qualitaet__zeile--an svg { width: 18px; height: 18px; fill: none; stroke: var(--akzent); stroke-width: 2.4; }

/* ---------- Drei ruhige Karten unter dem Bento ---------- */
.dreier { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 14px; margin-top: 14px; }
.dreier .kachel { padding: 28px 32px 30px; }
.dreier h3 { font-size: clamp(19px, 1.6vw, 22px); }
.dreier p { margin-top: 10px; color: var(--leise); font-size: 16px; line-height: 1.45; }

/* ---------- Bedienbare Karten: Lautsprecher und Qualitaet ---------- */
.lautsprecher, .qualitaet { pointer-events: auto; }
.kachel__bild:has(.lautsprecher), .kachel__bild:has(.qualitaet) { pointer-events: auto; }
.lautsprecher__zeile { grid-template-columns: minmax(0, 1fr); gap: 8px; padding-block: 10px; }
.lautsprecher__wahl { display: flex; align-items: center; gap: 12px; padding: 0; border: 0; background: none;
  color: var(--leise); font: inherit; text-align: left; cursor: pointer; }
.lautsprecher__zeile--an .lautsprecher__wahl { color: var(--schrift); }
.lautsprecher__zeichen { grid-row: auto; transition: background-color 200ms var(--raus); }
.lautsprecher__zeichen svg { transition: stroke 200ms var(--raus); }
.regler { -webkit-appearance: none; appearance: none; width: 100%; height: 18px; margin: 0; background: transparent; cursor: pointer; --stand: 50%; }
.regler::-webkit-slider-runnable-track { height: 4px; border-radius: 2px;
  background: linear-gradient(to right, var(--farbe, #fff) var(--stand), rgba(255,255,255,.18) var(--stand)); }
.regler::-moz-range-track { height: 4px; border-radius: 2px; background: rgba(255,255,255,.18); }
.regler::-moz-range-progress { height: 4px; border-radius: 2px; background: var(--farbe, #fff); }
.regler::-webkit-slider-thumb { -webkit-appearance: none; width: 16px; height: 16px; margin-top: -6px; border-radius: 50%; background: #fff; border: 0; }
.regler::-moz-range-thumb { width: 16px; height: 16px; border-radius: 50%; background: #fff; border: 0; }
.lautsprecher__zeile--an .regler { --farbe: var(--akzent); }
.lautsprecher__zeile:not(.lautsprecher__zeile--an) .regler { opacity: .35; }
.lautsprecher__wahl:focus-visible, .qualitaet__zeile:focus-visible, .regler:focus-visible,
.spektrum__wahl button:focus-visible { outline: 2px solid var(--akzent); outline-offset: 3px; border-radius: 8px; }
.qualitaet__zeile { width: 100%; border: 0; background: none; font: inherit; cursor: pointer; text-align: left; }
.qualitaet__zeile svg { width: 18px; height: 18px; fill: none; stroke: var(--akzent); stroke-width: 2.4; opacity: 0; transition: opacity 180ms var(--raus); }
.qualitaet__zeile[aria-checked="true"] { color: var(--schrift); font-weight: 600; }
.qualitaet__zeile[aria-checked="true"] svg { opacity: 1; }
@media (hover: hover) and (pointer: fine) {
  .qualitaet__zeile:hover, .lautsprecher__wahl:hover { color: var(--schrift); }
}

/* ---------- Die drei Karten bekommen ein Zeichen ---------- */
.kachel__zeichen { display: grid; place-items: center; width: 40px; height: 40px; margin-bottom: 14px;
  border-radius: 10px; background: var(--flaeche); color: var(--akzent); }
.kachel__zeichen svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }

/* ---------- Every bit of the song ---------- */
.spektrum { margin: 48px 0 0; }
.spektrum__bild { position: relative; overflow: hidden; border-radius: 16px; background: #101010; aspect-ratio: 5 / 2; }
.spektrum__bild img { display: block; width: 100%; height: 100%; object-fit: cover; }
.spektrum { --anteil: .274; }
.spektrum[data-stufe="320"] { --anteil: .093; }
.spektrum[data-stufe="flac"] { --anteil: 0; }
/* Was fehlt, deckt eine Flaeche von oben ab; sie gleitet mit einer Feder. */
.spektrum__schnitt {
  position: absolute; left: 0; right: 0; top: 0; height: calc(var(--anteil) * 100%);
  background: rgba(16,16,16,.94);
  box-shadow: inset 0 -1.5px 0 rgba(80,213,218,.9);
  transition: height 900ms cubic-bezier(.32,.72,0,1), box-shadow 300ms var(--raus);
}
.spektrum[data-stufe="flac"] .spektrum__schnitt { box-shadow: inset 0 0 0 rgba(80,213,218,0); }
.spektrum__marke { position: absolute; right: 16px; bottom: 10px; padding: 5px 10px; border-radius: 8px;
  background: var(--akzent-leise); color: var(--akzent); font-size: 12.5px; font-weight: 600; white-space: nowrap;
  transition: opacity 300ms var(--raus); }
.spektrum[data-stufe="flac"] .spektrum__marke { opacity: 0; }
.spektrum__wahl { display: flex; justify-content: center; gap: 6px; margin: 22px auto 0; padding: 5px; width: fit-content;
  border-radius: 999px; background: var(--gruppe, #1E1E1E); }
.spektrum__wahl button { display: grid; justify-items: center; gap: 1px; min-width: 124px; padding: 9px 18px; border: 0; border-radius: 999px;
  background: none; color: var(--leise); font: 600 15px var(--schriftart); cursor: pointer;
  transition: background-color 200ms var(--raus), color 200ms var(--raus); }
.spektrum__wahl button small { font-size: 12px; font-weight: 500; color: var(--sehr-leise); }
.spektrum__wahl button[aria-checked="true"] { background: var(--erhoeht); color: var(--schrift); }
.spektrum__wahl button[aria-checked="true"] small { color: var(--akzent); }
.spektrum figcaption { margin-top: 14px; text-align: center; color: var(--sehr-leise); font-size: 13px; }
@media (max-width: 900px) {
  .spektrum__bild { aspect-ratio: 4 / 3; border-radius: 14px; }
  .spektrum__wahl button { min-width: 0; padding: 8px 12px; font-size: 14px; }
}
.skala { position: absolute; left: 14px; top: 14px; bottom: 14px; z-index: 2; pointer-events: none; }
.skala i { position: absolute; left: 0; translate: 0 50%; font-style: normal; font-size: 12px; font-weight: 600;
  color: rgba(255,255,255,.7); white-space: nowrap; font-variant-numeric: tabular-nums; }
.skala i:first-child { translate: 0 100%; }
.skala i:last-child { translate: 0 0; }
.linse__buehne--spektrum .linse__marke--kopie { left: auto; right: 18px; }

/* Zwei ruhige Wege unter dem grossen, gleich breit wie auf der Startseite. */
.weg__app { flex: none; width: 32px; height: 32px; border-radius: 8px; display: block; }
.laden__rest--zwei { grid-template-columns: repeat(2, minmax(0, 1fr)) !important; }

@media (max-width: 900px) {
  .hero__knoepfe { margin-top: 29px; }
  /* Sonos und Qualitaet: die Karte steht direkt unter dem Text, ohne Loch. */
  .kachel--tv .kachel__bild, .kachel--desktop .kachel__bild { height: auto; padding: 0 24px 26px; }
  .lautsprecher, .qualitaet { position: static; translate: none; width: 100%; }
  /* Mobil: drei Telefone nebeneinander, das mittlere vorn und groesser. */
  .hero__buehne { aspect-ratio: 390 / 330; }
  .hero__buehne .geraet--mitte  { left: 31%; top: 3%; width: 38%; }
  .hero__buehne .geraet--links  { left: 5%; top: 15%; width: 29%; }
  .hero__buehne .geraet--rechts { left: 66%; top: 15%; width: 29%; }
  .kachel--mobil .geraet--vorn { left: 6%; width: 44%; bottom: -20%; }
  .kachel--mobil .geraet--hinten { right: 8%; width: 36%; bottom: -30%; }
  .dreier { grid-template-columns: 1fr; }
}
"""

# ------------------------------------------------------------------ Schirme

STEUER = """<div class="schirm__steuer">
            <svg class="an" viewBox="0 0 24 24"><path d="M16 3h5v5l-1.8-1.8L14 11.4 12.6 10l5.2-5.2zM3 6h4.6l9.6 9.6L19 14v5h-5l1.8-1.8L6.8 8H3zm0 12h3.8l3.1-3.1 1.4 1.4L7.6 20H3z"/></svg>
            <svg viewBox="0 0 24 24"><path d="M6 5h2v14H6zm3.5 7L19 5v14z"/></svg>
            <span class="schirm__spiel"><svg viewBox="0 0 24 24"><path d="M7 5h4v14H7zm6 0h4v14h-4z"/></svg></span>
            <svg viewBox="0 0 24 24"><path d="M16 5h2v14h-2zM5 5l9.5 7L5 19z"/></svg>
            <svg viewBox="0 0 24 24"><path d="M7 7h10v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2z"/></svg>
          </div>"""

SCHIRM_WIEDERGABE = f"""<div class="geraet__schirm"><div class="schirm">
          <div class="schirm__griff"></div>
          <div class="huelle h1"></div>
          <div class="schirm__titel"><div><b>Northern Lines</b><span>Harbour Lights</span></div><span class="schirm__plakette">FLAC</span></div>
          <div class="schirm__spur"></div>
          <div class="schirm__zeiten"><span>1:52</span><span>-1:21</span></div>
          {STEUER}
          <div class="schirm__aktionen">
            <span><svg viewBox="0 0 24 24"><path d="M4 6h16M4 12h10M4 18h13"/></svg>Lyrics</span>
            <span><svg viewBox="0 0 24 24"><rect x="5" y="3" width="14" height="18" rx="3"/><circle cx="12" cy="14" r="3"/></svg>Living room</span>
            <span><svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h8"/></svg>Up next</span>
          </div>
        </div></div>"""

SCHIRM_LIEDTEXT = """<div class="geraet__schirm"><div class="schirm">
          <div class="schirm__lied"><div class="huelle h1"></div><div><b>Northern Lines</b><span>Harbour Lights</span></div></div>
          <div class="schirm__liedtext">
            <span class="vorbei">The ferry's gone and the lights are low</span>
            <span>Every line I never said out loud</span>
            <span class="kommt">rolls in with the tide for me</span>
            <span class="kommt">So leave the window open wide</span>
          </div>
        </div></div>"""

SCHIRM_START = """<div class="geraet__schirm"><div class="schirm">
          <div class="schirm__kopf">Home</div>
          <div class="schirm__reihe">Recently played</div>
          <div class="schirm__raster"><div class="huelle h2"></div><div class="huelle h3"></div><div class="huelle h4"></div></div>
          <div class="schirm__reihe">New albums</div>
          <div class="schirm__raster"><div class="huelle h5"></div><div class="huelle h6"></div><div class="huelle h7"></div></div>
          <div class="schirm__mini"><div class="huelle h1"></div><div><b>Northern Lines</b><span>Harbour Lights</span></div></div>
        </div></div>"""


def schirm(name, nachbau):
    # Echter Bildschirm, sobald es ihn gibt; sonst der Nachbau (Liedtext).
    if os.path.exists(os.path.join(WEBSITE, "bilder", "music-" + name + ".webp")):
        return f'<img class="geraet__schirm" src="/bilder/music-{name}.webp" alt="" loading="lazy">'
    return nachbau


def iphone(klasse, name, nachbau):
    return f"""<div class="geraet geraet--fon {klasse}">
        {schirm(name, nachbau)}
        <img class="geraet__rahmen" src="/bilder/rahmen-iphone.webp" alt="" width="700" height="1431">
      </div>"""


PFEIL = ('<svg class="frage__pfeil" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.9" '
         'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7.5 4.5 13 10l-5.5 5.5"/></svg>')


def frage(n, f, a, offen=False):
    return f"""      <div class="frage">
        <button class="frage__knopf" type="button" aria-expanded="{'true' if offen else 'false'}" aria-controls="antwort-{n}">
          <span>{f}</span>
          {PFEIL}
        </button>
        <div class="frage__antwort" id="antwort-{n}"><div><p>{a}</p></div></div>
      </div>"""


FRAGEN = [
    ("Is this Swiftly Player with music?", "No. It is its own app, built only for music, with the same look and the same buttons as <a class=\"frage__link\" href=\"/\">Swiftly Player</a>."),
    ("Which servers work?", "Jellyfin and Navidrome, and other servers that speak OpenSubsonic. You sign in with the account you already have on your server."),
    ("Do I need Swiftly Player too?", "No. Each app works on its own. If you use both, they share nothing but the look."),
    ("Which devices does it run on?", "iPhone. It is in beta on TestFlight."),
    ("What data leaves my phone?", "Only what your own server needs: what you played. There is no account with me and no analytics."),
]

LD = [
    {"@context": "https://schema.org", "@type": "SoftwareApplication", "name": "Swiftly Music",
     "applicationCategory": "MultimediaApplication", "operatingSystem": "iOS",
     "url": "https://swiftlyplayer.com/music/",
     "description": "A music player for your own Jellyfin or Navidrome server: albums, playlists, synced lyrics, Sonos, original quality.",
     "author": {"@type": "Person", "name": "Paul Herter"}},
    {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
        {"@type": "Question", "name": f, "acceptedAnswer": {"@type": "Answer", "text": re.sub(r"<[^>]+>", "", a)}}
        for f, a in FRAGEN]},
    {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": 1, "name": "Swiftly Player", "item": "https://swiftlyplayer.com/"},
        {"@type": "ListItem", "position": 2, "name": "Swiftly Music", "item": "https://swiftlyplayer.com/music/"}]},
]
LD_TEXT = "".join(f'<script type="application/ld+json">\n{json.dumps(x, indent=2)}\n</script>\n' for x in LD)

TITEL = "Swiftly Music: a music player for Jellyfin and Navidrome"
BESCHREIBUNG = ("Swiftly Music plays your own Jellyfin or Navidrome music library on iPhone: "
                "albums, playlists, synced lyrics, Sonos and original quality.")
AUSSEN = ' target="_blank" rel="noopener"' if MUSIC_TESTFLIGHT or DOWNLOAD == DISCORD else ""

seite = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{TITEL}</title>
<meta name="description" content="{BESCHREIBUNG}">
<link rel="canonical" href="https://swiftlyplayer.com{PFAD}">
<meta property="og:title" content="Swiftly Music">
<meta property="og:description" content="Your own music library, on your phone. For Jellyfin and Navidrome.">
<meta property="og:url" content="https://swiftlyplayer.com{PFAD}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Swiftly Player">
<meta property="og:image" content="https://swiftlyplayer.com/vorschau.jpg">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#101010">
<link rel="preload" as="font" type="font/woff2" href="/schrift/figtree-latin.woff2" crossorigin>
<link rel="icon" href="icon-music.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>{STIL}{EIGEN}</style>
{LD_TEXT}</head>
<body>

<a class="nur-fuer-leser" href="#inhalt">Skip to content</a>

<header class="leiste">
  <div class="leiste__kapsel">
    <a class="leiste__marke" href="{PFAD}" aria-label="Swiftly Music, to the top">
      <img src="wortmarke-music.svg" alt="Swiftly Music" width="62" height="21">
    </a>
    <a class="leiste__punkt nur-desktop" href="/">Player</a>
    <a class="leiste__punkt nur-desktop" href="/blog/">Blog</a>
    <a class="leiste__punkt nur-desktop" href="{DISCORD}" target="_blank" rel="noopener">Discord</a>
    <a class="leiste__punkt nur-desktop" href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>
    <button class="leiste__burger" type="button" aria-expanded="false" aria-controls="menue" aria-label="Menu">
      <span></span><span></span><span></span>
    </button>
  </div>
</header>

<nav class="menue" id="menue" aria-label="Menu">
  <a href="/">Swiftly Player</a>
  <a href="/blog/">Blog</a>
  <a href="{DISCORD}" target="_blank" rel="noopener">Discord</a>
  <a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>
  <a class="knopf knopf--gross" href="#downloads">Download</a>
</nav>

<main id="inhalt">

<div class="auftakt">
<section class="hero" data-plaketten>
  <div class="aurora" aria-hidden="true"></div>
  <div class="hero__rahmen">

    <div class="bahn hero__text">
      <h1>Your player<br>for your music</h1>
      <p>A music player for the Jellyfin or Navidrome server you run yourself.</p>
      <div class="hero__knoepfe">
        <a class="knopf knopf--gross hero__knopf" href="#downloads">Download</a>
        <a class="knopf knopf--gross knopf--zweit hero__knopf" href="/">Swiftly Player</a>
      </div>
      <p class="hero__frei">{BETA_ZEILE}</p>
    </div>

    <div class="plakette plakette--direkt nur-desktop" aria-hidden="true">
      <span class="plakette__zeichen">
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 5h12M4 10h8M4 15h10"/></svg>
      </span>
      <span><b>Synced lyrics</b><em>Line by line, as it is sung</em></span>
    </div>

    <div class="plakette plakette--resume nur-desktop" aria-hidden="true">
      <span class="plakette__zeichen">
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2.5" width="10" height="15" rx="2.5"/><circle cx="10" cy="11.5" r="2.6"/><path d="M10 6h.01"/></svg>
      </span>
      <span><b>Sonos and AirPlay</b><em>Plays on without your phone</em></span>
    </div>

    <div class="plakette plakette--pip nur-desktop" aria-hidden="true">
      <span class="plakette__zeichen">
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 10h2.5l2.5-6 3.5 12 2.5-6H18"/></svg>
      </span>
      <span><b>Original quality</b><em>FLAC, streamed as stored</em></span>
    </div>

    <div class="hero__buehne" aria-hidden="true">
      {iphone("geraet--links", "start", SCHIRM_START)}
      {iphone("geraet--rechts", "album", SCHIRM_LIEDTEXT)}
      {iphone("geraet--mitte", "wiedergabe", SCHIRM_WIEDERGABE)}
    </div>
  </div>
  <div class="hero__ausklang" aria-hidden="true"></div>
</section>
</div>

<section class="etage" id="merkmale">
  <div class="bahn">
    <div class="etagenkopf"><h2>Made for music</h2>
      <p>The look and the buttons of Swiftly Player, arranged around albums, playlists and the song that is playing.</p></div>

    <div class="bento">
      <article class="kachel kachel--mobil">
        <div class="kachel__text">
          <h3>Lyrics that follow the song</h3>
          <p>Synced lyrics from your server scroll with the music. The line being sung stands out, the ones behind it fade.</p>
        </div>
        <div class="kachel__bild" aria-hidden="true">
          {iphone("geraet--hinten", "wiedergabe", SCHIRM_WIEDERGABE)}
          {iphone("geraet--vorn", "liedtext", SCHIRM_LIEDTEXT)}
        </div>
      </article>

      <article class="kachel kachel--tv">
        <div class="kachel__text">
          <h3>Sonos and AirPlay</h3>
          <p>Send the queue to a Sonos speaker. It keeps playing when your phone leaves the room.</p>
        </div>
        <div class="kachel__bild" aria-hidden="true">
          <div class="lautsprecher" data-lautsprecher>
            <div class="lautsprecher__kopf">Play on</div>
            <div class="lautsprecher__zeile lautsprecher__zeile--an" data-ziel="lautsprecher">
              <button class="lautsprecher__wahl" type="button" aria-pressed="true">
                <span class="lautsprecher__zeichen"><svg viewBox="0 0 20 20"><rect x="5" y="2.5" width="10" height="15" rx="2.5"/><circle cx="10" cy="11.5" r="2.6"/></svg></span>
                <b>Living room</b>
              </button>
              <input class="regler" type="range" min="0" max="100" value="62" aria-label="Volume, Living room">
            </div>
            <div class="lautsprecher__zeile lautsprecher__zeile--an" data-ziel="lautsprecher">
              <button class="lautsprecher__wahl" type="button" aria-pressed="true">
                <span class="lautsprecher__zeichen"><svg viewBox="0 0 20 20"><rect x="5" y="2.5" width="10" height="15" rx="2.5"/><circle cx="10" cy="11.5" r="2.6"/></svg></span>
                <b>Kitchen</b>
              </button>
              <input class="regler" type="range" min="0" max="100" value="40" aria-label="Volume, Kitchen">
            </div>
            <div class="lautsprecher__zeile" data-ziel="telefon">
              <button class="lautsprecher__wahl" type="button" aria-pressed="false">
                <span class="lautsprecher__zeichen"><svg viewBox="0 0 20 20"><rect x="4" y="2" width="12" height="16" rx="3"/><path d="M8.5 15h3"/></svg></span>
                <b>This iPhone</b>
              </button>
              <input class="regler" type="range" min="0" max="100" value="70" aria-label="Volume, this iPhone">
            </div>
          </div>
        </div>
      </article>

      <article class="kachel kachel--desktop">
        <div class="kachel__text">
          <h3>Original quality</h3>
          <p>FLAC and everything else stream as stored. On mobile data you choose how much.</p>
        </div>
        <div class="kachel__bild" aria-hidden="true">
          <div class="qualitaet" role="radiogroup" aria-label="Streaming on mobile data" data-qualitaet>
            <div class="qualitaet__kopf">Streaming on mobile data</div>
            <button class="qualitaet__zeile" type="button" role="radio" aria-checked="true">Original<svg viewBox="0 0 20 20"><path d="m4.5 10.5 3.5 3.5 7.5-8"/></svg></button>
            <button class="qualitaet__zeile" type="button" role="radio" aria-checked="false">320 kbit/s<svg viewBox="0 0 20 20"><path d="m4.5 10.5 3.5 3.5 7.5-8"/></svg></button>
            <button class="qualitaet__zeile" type="button" role="radio" aria-checked="false">128 kbit/s<svg viewBox="0 0 20 20"><path d="m4.5 10.5 3.5 3.5 7.5-8"/></svg></button>
          </div>
        </div>
      </article>
    </div>

    <div class="dreier">
      <article class="kachel"><span class="kachel__zeichen" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 4v10m0 0-4-4m4 4 4-4M5 19h14"/></svg></span><h3>Downloads</h3><p>Keep albums and playlists on the phone, over Wi-Fi only if you like.</p></article>
      <article class="kachel"><span class="kachel__zeichen" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 9v6M9.5 6v12M14 8v8M18.5 10v4"/></svg></span><h3>Even volume</h3><p>Loud and quiet albums play at the same level, one after the other.</p></article>
      <article class="kachel"><span class="kachel__zeichen" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M4 7h10M4 12h10M4 17h6"/><path d="m16 14 5 3-5 3z" fill="currentColor" stroke="none"/></svg></span><h3>It keeps going</h3><p>When the album ends, similar songs follow. Switch it off if you want silence.</p></article>
    </div>
  </div>
</section>

<section class="etage" id="original">
  <div class="bahn">
    <div class="etagenkopf"><h2>Every bit of the song</h2>
      <p>Pick a quality and see what stays. A lossy copy cuts off the top of the sound; FLAC keeps all of it, and Swiftly Music plays it as stored.</p></div>
    <figure class="spektrum" data-spektrum data-stufe="128">
      <div class="spektrum__bild">
        <img src="/bilder/spektrum.webp" alt="A spectrogram of a song: time runs to the right, pitch goes up to 22 kHz" width="1600" height="640" loading="lazy">
        <div class="spektrum__schnitt"><span class="spektrum__marke">Nothing above 16 kHz</span></div>
        <span class="skala" aria-hidden="true"><i style="bottom:100%">22 kHz</i><i style="bottom:72.6%">16 kHz</i><i style="bottom:45.4%">10 kHz</i><i style="bottom:0%">0</i></span>
      </div>
      <div class="spektrum__wahl" role="radiogroup" aria-label="Quality">
        <button type="button" role="radio" aria-checked="true" data-wahl="128" data-khz="16">128 kbit/s<small>MP3</small></button>
        <button type="button" role="radio" aria-checked="false" data-wahl="320" data-khz="20">320 kbit/s<small>MP3</small></button>
        <button type="button" role="radio" aria-checked="false" data-wahl="flac" data-khz="22.05">Original<small>FLAC</small></button>
      </div>
      <figcaption>An illustration: where an MP3 stops depends on the encoder, 16 and 20 kHz are typical for these bitrates.</figcaption>
    </figure>
  </div>
</section>

<section class="etage" id="fragen">
  <div class="bahn">
    <div class="etagenkopf"><h2>Common questions</h2></div>
    <div class="fragen__blatt">
{chr(10).join(frage(i, f, a, i == 0) for i, (f, a) in enumerate(FRAGEN))}
    </div>
  </div>
</section>

<section class="etage" id="downloads">
  <div class="bahn">
    <div class="etagenkopf">
      <h2>Get Swiftly Music</h2>
      <p>For iPhone, in beta on TestFlight. Your films and shows live in Swiftly Player.</p>
    </div>
    <div class="ladenblock">
      <div class="laden__haupt">
      <a class="weg-gross" href="{DOWNLOAD}"{AUSSEN}>
        <span class="weg__zeichen" aria-hidden="true"><svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4.6 1.2h2.8M5 1.2v3.3L2.4 9.3a1 1 0 0 0 .9 1.5h5.4a1 1 0 0 0 .9-1.5L7 4.5V1.2M3.4 7.6h5.2"/></svg></span>
        <span><b>{WEG_TITEL}</b><em>{WEG_TEXT}</em></span>
      </a>
      </div>
      <ul class="laden__rest laden__rest--zwei">
        <li>
      <a class="weg-klein" href="/">
        <img class="weg__app" src="/symbol.svg" alt="" width="32" height="32">
        <span><b>Swiftly Player</b><em>Films and shows</em></span>
      </a>
        </li>
        <li>
      <a class="weg-klein" href="{DISCORD}" target="_blank" rel="noopener">
        <span class="weg__zeichen" aria-hidden="true"><svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M2 3.2a1.2 1.2 0 0 1 1.2-1.2h5.6A1.2 1.2 0 0 1 10 3.2v4a1.2 1.2 0 0 1-1.2 1.2H5.4L3 10.4V8.4h.2A1.2 1.2 0 0 1 2 7.2z"/></svg></span>
        <span><b>Discord</b><em>Feedback and news</em></span>
      </a>
        </li>
      </ul>
    </div>
  </div>
</section>

</main>

{FUSS}

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
  var knoepfe = document.querySelectorAll(".frage__knopf");
  for (var f = 0; f < knoepfe.length; f++) {{
    knoepfe[f].addEventListener("click", function (e) {{
      var k = e.currentTarget, offen = k.getAttribute("aria-expanded") === "true";
      for (var q = 0; q < knoepfe.length; q++) {{ knoepfe[q].setAttribute("aria-expanded", "false"); }}
      k.setAttribute("aria-expanded", offen ? "false" : "true");
    }});
  }}
}})();
</script>
<script src="/js/effekte.js" defer></script>
</body>
</html>
"""

ordner = os.path.join(WEBSITE, ZIEL.strip("/"))
os.makedirs(ordner, exist_ok=True)
open(os.path.join(ordner, "index.html"), "w", encoding="utf-8").write(seite)
shutil.copy(WORTMARKE, os.path.join(ordner, "wortmarke-music.svg"))
shutil.copy(os.path.join(os.path.dirname(WORTMARKE), "icon.svg"), os.path.join(ordner, "icon-music.svg"))
print("geschrieben", os.path.join(ordner, "index.html"), len(seite))
