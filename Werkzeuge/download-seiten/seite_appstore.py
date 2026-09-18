# -*- coding: utf-8 -*-
import sys, json
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import *

S1 = skizze(1, "A phone showing the app page in a store, with the Get button marked",
    TELEFON + MARKE +
    '<text class="titel" x="194" y="48">Swiftly</text><text x="194" y="64">Free</text>' +
    '<rect x="152" y="80" width="96" height="30" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="182" y="99">Get</text>' +
    zeile(152, 126, 96, ".45") + zeile(152, 142, 74, ".35") + zeile(152, 158, 88, ".3") +
    tipp(238, 95))

S2 = skizze(2, "The app asking for a server address, with the Connect button marked",
    TELEFON +
    '<text class="titel" x="152" y="46">Your server</text>' +
    '<rect x="152" y="58" width="96" height="26" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<text x="160" y="75">jelly.home</text>' +
    '<rect x="152" y="92" width="96" height="26" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    zeile(160, 101, 52, ".5") +
    '<rect x="152" y="128" width="96" height="30" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="174" y="147">Connect</text>' +
    tipp(238, 143))

S3 = skizze(3, "The library on the phone, with the play button on a film marked",
    TELEFON +
    '<rect x="152" y="34" width="44" height="60" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<rect x="204" y="34" width="44" height="60" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<circle cx="174" cy="64" r="15" fill="rgba(92,209,194,.20)" stroke="var(--akzent)"/>' +
    '<path d="M170 57 181 64l-11 7z" fill="var(--schrift)"/>' +
    zeile(152, 104, 96, ".45") + zeile(152, 120, 70, ".35") +
    '<rect x="152" y="140" width="96" height="34" rx="10" fill="var(--erhoeht)" stroke="var(--linie)"/>' +
    zeile(160, 152, 60, ".3") +
    tipp(174, 64))

LD = """<script type="application/ld+json">
%s
</script>
<script type="application/ld+json">
%s
</script>
""" % (json.dumps({
  "@context": "https://schema.org", "@type": "HowTo",
  "name": "Get Swiftly Player from the App Store",
  "description": "Three steps from the App Store to the first film on your own Jellyfin server.",
  "inLanguage": "en", "totalTime": "PT3M",
  "estimatedCost": {"@type": "MonetaryAmount", "currency": "USD", "value": "0"},
  "step": [
    {"@type": "HowToStep", "position": 1, "name": "Install from the App Store",
     "text": "Open Swiftly Player on the App Store and install it. One download covers iPhone, iPad, Mac and Apple TV.",
     "url": "https://swiftlyplayer.com/download/app-store/#schritt-1"},
    {"@type": "HowToStep", "position": 2, "name": "Add your server",
     "text": "Open the app, type the address of your Jellyfin server and sign in, or use Quick Connect.",
     "url": "https://swiftlyplayer.com/download/app-store/#schritt-2"},
    {"@type": "HowToStep", "position": 3, "name": "Press play",
     "text": "Your library shows up. Press play, and the file runs as Direct Play.",
     "url": "https://swiftlyplayer.com/download/app-store/#schritt-3"}]}, indent=2),
 json.dumps({
  "@context": "https://schema.org", "@type": "BreadcrumbList",
  "itemListElement": [
    {"@type": "ListItem", "position": 1, "name": "Swiftly Player", "item": "https://swiftlyplayer.com/"},
    {"@type": "ListItem", "position": 2, "name": "App Store", "item": "https://swiftlyplayer.com/download/app-store/"}]}, indent=2))

seite = kopf(
  "Get Swiftly Player on iPhone, iPad, Mac and Apple TV",
  "One download from the App Store covers iPhone, iPad, Mac and Apple TV. Install it, add your Jellyfin server, press play. Free, no account with us.",
  "/download/app-store/",
  og_titel="Swiftly Player on the App Store",
  og_text="Install it, add your Jellyfin server, press play.",
  extra_ld=LD) + f"""  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>App Store</li></ol>
    <h1>Swiftly on iPhone, iPad, Mac and Apple TV</h1>
    <p class="unter">One download covers all four. It is free, there is no account with me, and your server stays yours.</p>
  </header>

  <div class="download">
    <p>Swiftly Player is on the App Store.</p>
    <a class="knopf knopf--gross" href="{APP_STORE}" target="_blank" rel="noopener">Open the App Store</a>
    <p class="download__klein">iOS and iPadOS 17, macOS 14, tvOS 17 or newer.</p>
  </div>

  <ol class="schritte">
    <li class="schritt" id="schritt-1">
      <span class="schritt__zahl" aria-hidden="true">1</span>
      <h2>Install it</h2>
      <p>Tap <strong>Get</strong>. The same download works on iPhone, iPad, Mac and Apple TV, so you buy nothing twice.</p>
{figur(S1, "The app page in the store. Get is the only button you need.")}
    </li>
    <li class="schritt" id="schritt-2">
      <span class="schritt__zahl" aria-hidden="true">2</span>
      <h2>Add your server</h2>
      <p>Type the address of your Jellyfin server and sign in. On the Apple TV, use <strong>Quick Connect</strong>: six digits in a browser and you are in.</p>
{figur(S2, "The first screen: server address, then Connect.")}
    </li>
    <li class="schritt" id="schritt-3">
      <span class="schritt__zahl" aria-hidden="true">3</span>
      <h2>Press play</h2>
      <p>Your library shows up as it is on the server. Swiftly plays the original file, so your server has nothing to convert.</p>
{figur(S3, "The library. Press play and the file runs as it is.")}
    </li>
  </ol>

  <aside class="hinweis" aria-labelledby="gut-zu-wissen">
    <h2 id="gut-zu-wissen">Good to know</h2>
    <ul>
      <li><strong>You need a Jellyfin server.</strong> Swiftly is the client. It speaks the Jellyfin API and nothing else, so Plex and Emby will not work.</li>
      <li><strong>Jellyfin 10.8 or newer.</strong> Skip Intro, Skip Recap and Skip Credits need 10.10, because that is where Jellyfin keeps the segments.</li>
      <li><strong>Want the next build first?</strong> The beta runs on <a href="/download/testflight/">TestFlight</a>.</li>
    </ul>
  </aside>

{mitmachen("Tell me what you think",
           "Built by one person. Most of what changes starts as a message from someone who uses it.",
           [("stern", "warm", "Write a review", "On the App Store, it helps a lot", BEWERTEN),
            ("discord", "akzent", "Discord", "Help, ideas, early builds", DISCORD),
            ("fehler", "kuehl", "Report a bug", "On GitHub or Discord", ISSUES)])}

{andere("/download/app-store/")}

{HILFE}
""" + fuss("/download/app-store/")

schreiben("/download/app-store/", seite)
