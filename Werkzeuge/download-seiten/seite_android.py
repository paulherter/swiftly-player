# -*- coding: utf-8 -*-
import sys, json
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import *

GRUPPE = "https://groups.google.com/g/swiftly-beta"
TESTEN = "https://play.google.com/apps/testing/de.paulherter.swiftly"

S1 = skizze(1, "A browser window showing the test group page; the Join group button is marked",
    BROWSER +
    '<text class="titel" x="40" y="80">swiftly-beta</text>' +
    zeile(40, 92, 210) + zeile(40, 108, 172) +
    '<rect x="40" y="132" width="112" height="32" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="56" y="152">Join group</text>' +
    zeiger(96, 144))

S2 = skizze(2, "A browser window showing the testing page; the Become a tester button is marked",
    BROWSER +
    '<text class="titel" x="40" y="80">Swiftly Player</text>' +
    '<text x="40" y="100">Test programme</text>' +
    zeile(40, 112, 196) +
    '<rect x="40" y="136" width="146" height="32" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="56" y="156">Become a tester</text>' +
    zeiger(110, 148))

S3 = skizze(3, "A phone with the app page open; the Install button is marked",
    TELEFON + MARKE +
    '<text class="titel" x="194" y="48">Swiftly</text><text x="194" y="64">Free</text>' +
    '<rect x="152" y="80" width="96" height="30" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="176" y="99">Install</text>' +
    zeile(152, 126, 96, ".45") + zeile(152, 142, 74, ".35") + zeile(152, 158, 88, ".3") +
    tipp(238, 95))

LD = ""
for daten in [
  {"@context": "https://schema.org", "@type": "HowTo",
   "name": "Get Swiftly Player on Android and Android TV",
   "description": "Swiftly Player for Android is in testing on Google Play. Anyone can join in three steps.",
   "inLanguage": "en", "totalTime": "PT5M",
   "estimatedCost": {"@type": "MonetaryAmount", "currency": "USD", "value": "0"},
   "step": [
     {"@type": "HowToStep", "position": 1, "name": "Join the test group",
      "text": "Open the swiftly-beta Google Group and join it with the same Google account the Play Store on your device uses.",
      "url": "https://swiftlyplayer.com/android/#schritt-1"},
     {"@type": "HowToStep", "position": 2, "name": "Become a tester",
      "text": "Open the Google Play testing page for Swiftly Player and tap Become a tester.",
      "url": "https://swiftlyplayer.com/android/#schritt-2"},
     {"@type": "HowToStep", "position": 3, "name": "Install from Google Play",
      "text": "Open Swiftly Player on Google Play and install it. On Android TV, search for Swiftly in the Play Store on the television.",
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
    LD += '<script type="application/ld+json">\n' + json.dumps(daten, indent=2) + "\n</script>\n"

def frage(titel, antwort, offen=False):
    return f"""      <details class="frage"{' open' if offen else ''}>
        <summary class="frage__knopf"><h3>{titel}</h3>
          <svg class="frage__pfeil" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M7.5 4.5 13 10l-5.5 5.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></summary>
        <div class="frage__antwort"><p>{antwort}</p></div>
      </details>"""

seite = kopf(
  "Get Swiftly Player on Android and Android TV",
  "Swiftly Player for Android and Android TV is in testing on Google Play. Join the test group, become a tester, then install it from Google Play. Free.",
  "/android/",
  og_titel="Get Swiftly Player on Android and Android TV",
  og_text="Three steps: join the test group, become a tester, install from Google Play. Free.",
  extra_ld=LD) + f"""  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>Android</li></ol>
    <h1>Get Swiftly on Android and Android TV</h1>
    <p class="unter">The Android version is in testing on Google Play. Anyone can join, and it is free. It takes three steps.</p>
  </header>

  <ol class="schritte">
    <li class="schritt" id="schritt-1">
      <span class="schritt__zahl" aria-hidden="true">1</span>
      <h2>Join the test group</h2>
      <p>Open the Google Group swiftly-beta and tap <strong>Join group</strong>. Use the <strong>same Google account</strong> your phone or TV uses for the Play Store.</p>
      <a class="knopf" href="{GRUPPE}" target="_blank" rel="noopener">Join the test group</a>
{figur(S1, "The group page in a browser. Join group is the only button that matters.")}
    </li>
    <li class="schritt" id="schritt-2">
      <span class="schritt__zahl" aria-hidden="true">2</span>
      <h2>Become a tester</h2>
      <p>Open the testing page on Google Play and tap <strong>Become a tester</strong>. This only works after step 1.</p>
      <a class="knopf" href="{TESTEN}" target="_blank" rel="noopener">Become a tester</a>
{figur(S2, "The testing page. One button, and step 1 has to be done first.")}
    </li>
    <li class="schritt" id="schritt-3">
      <span class="schritt__zahl" aria-hidden="true">3</span>
      <h2>Install from Google Play</h2>
      <p>Swiftly Player now shows up on Google Play like any other app. Updates arrive the same way.</p>
      <a class="knopf" href="{PLAY}" target="_blank" rel="noopener">Install from Google Play</a>
{figur(S3, "The app page on the phone, with the Install button.")}
    </li>
  </ol>

  <aside class="hinweis" aria-labelledby="nichts">
    <h2 id="nichts">Nothing shows up?</h2>
    <ul>
      <li><strong>A different Google account.</strong> The account in the group has to be the one signed in to the Play Store on your device. If you have several, check which one the Play Store uses.</li>
      <li><strong>Google needs a moment.</strong> After joining, it can take a few minutes, sometimes a few hours, until Google knows you are a tester. Until then the Play Store says the item was not found. Try again later.</li>
    </ul>
  </aside>

  <section class="abschnitt" aria-labelledby="tv">
    <h2 id="tv">Android TV</h2>
    <p>Do steps 1 and 2 on your phone or computer, with the Google account your TV uses. Then search for Swiftly in the Play Store on the TV, or install it from the Play Store on your phone and pick the TV under &#8220;Install on more devices&#8221;.</p>
  </section>

  <section class="abschnitt" aria-labelledby="fragen">
    <h2 id="fragen">Questions</h2>
    <div class="fragen__blatt">
{frage("Does it cost anything?", "No. Swiftly Player is free, with no subscription and no account with us. Joining the test is free as well.", offen=True)}
{frage("Is it safe?", f'The app comes from Google Play, like any other app, and Google checks it the same way. The group is only the list of testers that Google Play checks. Your watch progress goes to your own Jellyfin server, nowhere else. The code is on <a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>.')}
{frage("Why a test and not a normal release?", "Google asks new developers to test an app with real testers before it can be released to everyone. Once that is done, Swiftly Player will be a normal download and these steps go away. You keep the app either way.")}
    </div>
  </section>

{mitmachen("Tell me what you think",
           "The Android version is the youngest one, so your report is often the first time a device gets tested at all.",
           [("discord", "akzent", "Discord", "Help, ideas, early builds", DISCORD),
            ("fehler", "kuehl", "Report a bug", "On GitHub, with your device", ISSUES),
            ("code", "akzent", "Read the source", "MPL-2.0, Android included", GITHUB)])}

{andere("/android/")}

{HILFE}
""" + fuss("/android/")

schreiben("/android/", seite)
