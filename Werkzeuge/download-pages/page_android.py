# -*- coding: utf-8 -*-
import sys, json
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from parts import *

TESTEN = "https://play.google.com/apps/testing/de.paulherter.swiftly"

S1 = sketch(1, "A phone with the app page on Google Play; the Install button is marked",
    PHONE + MARK +
    '<text class="titel" x="194" y="48">Swiftly</text><text x="194" y="64">Free</text>' +
    '<rect x="152" y="80" width="96" height="30" rx="10" fill="rgba(80,213,218,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="176" y="99">Install</text>' +
    row(152, 126, 96, ".45") + row(152, 142, 74, ".35") + row(152, 158, 88, ".3") +
    tap(238, 95))

S2 = sketch(2, "The app asking for a server address, with the Connect button marked",
    PHONE +
    '<text class="titel" x="152" y="46">Your server</text>' +
    '<rect x="152" y="58" width="96" height="26" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<text x="160" y="75">jelly.home</text>' +
    '<rect x="152" y="92" width="96" height="26" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    row(160, 101, 52, ".5") +
    '<rect x="152" y="128" width="96" height="30" rx="10" fill="rgba(80,213,218,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="174" y="147">Connect</text>' +
    tap(238, 143))

S3 = sketch(3, "The library on the phone, with the play button on a film marked",
    PHONE +
    '<rect x="152" y="34" width="44" height="60" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<rect x="204" y="34" width="44" height="60" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<circle cx="174" cy="64" r="15" fill="rgba(80,213,218,.20)" stroke="var(--akzent)"/>' +
    '<path d="M170 57 181 64l-11 7z" fill="var(--schrift)"/>' +
    row(152, 104, 96, ".45") + row(152, 120, 70, ".35") +
    '<rect x="152" y="140" width="96" height="34" rx="10" fill="var(--erhoeht)" stroke="var(--linie)"/>' +
    row(160, 152, 60, ".3") +
    tap(174, 64))

LD = ""
for data in [
  {"@context": "https://schema.org", "@type": "HowTo",
   "name": "Get Swiftly Player on Android and Android TV",
   "description": "Three steps from Google Play to the first film on your own Jellyfin server, on an Android phone or Android TV.",
   "inLanguage": "en", "totalTime": "PT3M",
   "estimatedCost": {"@type": "MonetaryAmount", "currency": "USD", "value": "0"},
   "step": [
     {"@type": "HowToStep", "position": 1, "name": "Install from Google Play",
      "text": "Open Swiftly Player on Google Play and install it. On Android TV, search for Swiftly in the Play Store on the television.",
      "url": "https://swiftlyplayer.com/android/#schritt-1"},
     {"@type": "HowToStep", "position": 2, "name": "Add your server",
      "text": "Open the app, type the address of your Jellyfin server and sign in, or use Quick Connect.",
      "url": "https://swiftlyplayer.com/android/#schritt-2"},
     {"@type": "HowToStep", "position": 3, "name": "Press play",
      "text": "Your library shows up. Press play, and the file runs as Direct Play.",
      "url": "https://swiftlyplayer.com/android/#schritt-3"}]},
  {"@context": "https://schema.org", "@type": "SoftwareApplication",
   "name": "Swiftly Player", "applicationCategory": "MultimediaApplication",
   "operatingSystem": "Android", "url": "https://swiftlyplayer.com/android/",
   "downloadUrl": PLAY,
   "description": "A video player for your own Jellyfin server, for Android phones and Android TV.",
   "author": {"@type": "Person", "name": "Paul Herter"},
   "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"}},
  {"@context": "https://schema.org", "@type": "BreadcrumbList",
   "itemListElement": [
     {"@type": "ListItem", "position": 1, "name": "Swiftly Player", "item": "https://swiftlyplayer.com/"},
     {"@type": "ListItem", "position": 2, "name": "Android", "item": "https://swiftlyplayer.com/android/"}]}]:
    LD += '<script type="application/ld+json">\n' + json.dumps(data, indent=2) + "\n</script>\n"

def question(title, response, opened=False):
    return f"""      <details class="frage"{' open' if opened else ''}>
        <summary class="frage__knopf"><h3>{title}</h3>
          <svg class="frage__pfeil" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M7.5 4.5 13 10l-5.5 5.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></summary>
        <div class="frage__antwort"><p>{response}</p></div>
      </details>"""

page = header(
  "Get Swiftly Player on Android and Android TV",
  "Swiftly Player for Android phones and Android TV is on Google Play. Install it, add your Jellyfin server, press play. Free, Android 9 or newer, no account with us.",
  "/android/",
  og_title="Get Swiftly Player on Android and Android TV",
  og_text="Install it from Google Play, add your Jellyfin server, press play. Free.",
  extra_ld=LD) + f"""  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>Android</li></ol>
    <h1>Get Swiftly on Android and Android TV</h1>
    <p class="unter">The same app for your phone and your TV. It is free, there is no account with me, and your server stays yours.</p>
  </header>

  <div class="download">
    <p>Swiftly Player is on Google Play.</p>
    <a class="knopf knopf--gross" href="{PLAY}" target="_blank" rel="noopener">Open Google Play</a>
    <p class="download__klein">Android phones, tablets and Android TV, Android 9 or newer.</p>
  </div>

  <ol class="schritte">
    <li class="schritt" id="schritt-1">
      <span class="schritt__zahl" aria-hidden="true">1</span>
      <h2>Install from Google Play</h2>
      <p>Tap <strong>Install</strong>. Updates arrive through Google Play like for any other app.</p>
{figure(S1, "The app page on the phone, with the Install button.")}
    </li>
    <li class="schritt" id="schritt-2">
      <span class="schritt__zahl" aria-hidden="true">2</span>
      <h2>Add your server</h2>
      <p>Type the address of your Jellyfin server and sign in. Or choose <strong>Quick Connect</strong> and approve the code from a device that is already signed in.</p>
{figure(S2, "The address of your server, then Connect.")}
    </li>
    <li class="schritt" id="schritt-3">
      <span class="schritt__zahl" aria-hidden="true">3</span>
      <h2>Press play</h2>
      <p>Your library shows up. The file plays as it is, through libVLC, so MKV, HEVC, AV1 and PGS subtitles need no transcoding on the server.</p>
{figure(S3, "The library. Press play and the file runs as it is.")}
    </li>
  </ol>

  <section class="abschnitt" aria-labelledby="tv">
    <h2 id="tv">Android TV</h2>
    <p>Search for Swiftly in the Play Store on the TV. Or install it from Google Play on your phone and pick the TV under &#8220;Install on more devices&#8221;. Sign in on the TV with Quick Connect, so you don&#8217;t have to type a password with the remote.</p>
  </section>

  <section class="abschnitt" aria-labelledby="fragen">
    <h2 id="fragen">Questions</h2>
    <div class="fragen__blatt">
{question("Does it cost anything?", "No. Swiftly Player is free, with no subscription and no account with us.", opened=True)}
{question("Which devices does it run on?", "Android phones and tablets and Android TV, Android 9 or newer. Fire TV is not supported: it installs apps from the Amazon Appstore, not from Google Play.")}
{question("I joined the test earlier. Do I need to do anything?", f'No. The app stays installed and keeps updating through Google Play. If you only want the regular releases, leave the test on the <a href="{TESTEN}" target="_blank" rel="noopener">testing page</a>.')}
{question("Is it safe?", f'It comes from Google Play, like any other app. Your watch progress goes to your own Jellyfin server, nowhere else. The code is on <a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>.')}
    </div>
  </section>

{join("Tell me what you think",
           "The Android version is the youngest one, so a report from your device often helps more than you would think.",
           [("discord", "akzent", "Discord", "Help, ideas, early builds", DISCORD),
            ("fehler", "kuehl", "Report a bug", "On GitHub, with your device", ISSUES),
            ("code", "akzent", "Read the source", "MPL-2.0, Android included", GITHUB)])}

{other("/android/")}

{VLC_HINT}
{HELP}
""" + footer("/android/")

write("/android/", page)
