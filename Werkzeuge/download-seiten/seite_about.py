# -*- coding: utf-8 -*-
"""Seite /about/: wer Swiftly baut, warum, und wie die Anleitungen entstehen.

Google gewichtet, ob hinter einer Website ein erkennbarer Mensch steht. Der
Name steht ohnehin im Impressum; hier steht er mit dem, was ihn ausweist.
Nur Belegtes: nichts, was README oder Impressum nicht auch sagen.
"""
import sys, json
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import *

LD = """<script type="application/ld+json">
%s
</script>
""" % json.dumps({
    "@context": "https://schema.org", "@type": "AboutPage",
    "url": "https://swiftlyplayer.com/about/", "name": "About Swiftly Player",
    "mainEntity": {
        "@type": "Person", "name": "Paul Herter", "url": "https://swiftlyplayer.com/about/",
        "sameAs": ["https://github.com/paulherter"],
        "knowsAbout": ["Jellyfin", "Navidrome", "Video playback", "iOS", "tvOS", "macOS"]},
    "about": {"@type": "Organization", "name": "Swiftly Player", "url": "https://swiftlyplayer.com/"}},
    indent=2)

seite = kopf(
  "About Swiftly Player",
  "Swiftly Player and Swiftly Music are free Jellyfin clients built by one developer. Why they exist, how they are made, and how the guides on this site are checked.",
  "/about/",
  og_titel="About Swiftly Player",
  og_text="Two free Jellyfin clients, built by one person.",
  extra_ld=LD) + f"""  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>About</li></ol>
    <h1>Built by one person</h1>
    <p class="unter">I'm Paul Herter. I build Swiftly Player and Swiftly Music on my own, in Germany: free apps for the Jellyfin server you run yourself.</p>
  </header>

  <section class="abschnitt" aria-labelledby="warum">
    <h2 id="warum">Why it exists</h2>
    <p>I run Jellyfin at home. I wanted a client that plays the original file instead of asking the server for a converted copy, and Picture in Picture on the iPhone. That second one is what sent me looking in the first place, and I ended up building my own.</p>
    <p>Swiftly Player now runs on iPhone, iPad, Mac, Apple TV, Android, Android TV, Windows and Linux. <a href="/music/">Swiftly Music</a> does the same for music, on iPhone for now, with Jellyfin and Navidrome.</p>
  </section>

  <section class="abschnitt" aria-labelledby="wie">
    <h2 id="wie">How it is made</h2>
    <p>There is no company behind it, no account, no ads and no tracking. What you watch goes to your own server and nowhere else. The code is open source under the MPL-2.0 and lives <a href="{GITHUB}" target="_blank" rel="noopener">on GitHub</a>. Bugs and wishes come in through <a href="{DISCORD}" target="_blank" rel="noopener">Discord</a> and GitHub issues, and most releases start there.</p>
  </section>

  <section class="abschnitt" aria-labelledby="anleitungen">
    <h2 id="anleitungen">About the guides</h2>
    <p>The <a href="/blog/">guides</a> compare Jellyfin clients, the ones that compete with Swiftly included. Every version number, price and feature links to the project's own page, and each guide says when it was checked. Where another app does something better, the guide says so, and every guide that mentions Swiftly says that I build it.</p>
  </section>

  <section class="abschnitt" aria-labelledby="kontakt">
    <h2 id="kontakt">Contact</h2>
    <p>Email <a href="mailto:info@swiftlyplayer.com">info@swiftlyplayer.com</a>, or find me on <a href="{DISCORD}" target="_blank" rel="noopener">Discord</a>. The legal details are in the <a href="/impressum.html">Impressum</a>.</p>
  </section>

{HILFE}
""" + fuss("/about/")

schreiben("/about/", seite)
