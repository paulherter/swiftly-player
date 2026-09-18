# -*- coding: utf-8 -*-
import sys, json
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import *

S1 = skizze(1, "A phone showing the TestFlight app page in a store, with the Get button marked",
    TELEFON +
    '<rect x="152" y="34" width="34" height="34" rx="11" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<path d="M162 60h14l-7-16z" fill="none" stroke="var(--leise)" stroke-width="1.6" stroke-linejoin="round"/>' +
    '<text class="titel" x="194" y="48">TestFlight</text><text x="194" y="64">Free</text>' +
    '<rect x="152" y="80" width="96" height="30" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="182" y="99">Get</text>' +
    zeile(152, 126, 96, ".4") + zeile(152, 142, 70, ".3") +
    tipp(238, 95))

S2 = skizze(2, "The tester app listing Swiftly Player, with the Install button marked",
    TELEFON + MARKE +
    '<text class="titel" x="194" y="48">Swiftly</text><text x="194" y="64">Beta</text>' +
    '<rect x="152" y="80" width="96" height="30" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="176" y="99">Install</text>' +
    zeile(152, 126, 96, ".4") + zeile(152, 142, 80, ".3") +
    tipp(238, 95))

S3 = skizze(3, "A phone with the feedback screen, with Send Beta Feedback marked",
    TELEFON +
    '<text class="titel" x="152" y="46">Swiftly, beta</text>' +
    zeile(152, 58, 96, ".4") +
    '<rect x="152" y="76" width="96" height="34" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="160" y="90">Send Beta</text><text class="ziel" x="160" y="104">Feedback</text>' +
    '<rect x="152" y="120" width="96" height="30" rx="10" fill="var(--erhoeht)" stroke="var(--linie)"/>' +
    zeile(160, 131, 60, ".3") +
    tipp(238, 93))

LD = """<script type="application/ld+json">
%s
</script>
<script type="application/ld+json">
%s
</script>
""" % (json.dumps({
  "@context": "https://schema.org", "@type": "HowTo",
  "name": "Join the Swiftly Player beta on TestFlight",
  "description": "Three steps: install TestFlight, accept the invitation, then send feedback from inside the app.",
  "inLanguage": "en", "totalTime": "PT3M",
  "estimatedCost": {"@type": "MonetaryAmount", "currency": "USD", "value": "0"},
  "step": [
    {"@type": "HowToStep", "position": 1, "name": "Install TestFlight",
     "text": "TestFlight is Apple's app for beta builds. Install it from the App Store.",
     "url": "https://swiftlyplayer.com/download/testflight/#schritt-1"},
    {"@type": "HowToStep", "position": 2, "name": "Accept the invitation",
     "text": "Open the invitation link on the device and tap Install. The beta sits next to the App Store version.",
     "url": "https://swiftlyplayer.com/download/testflight/#schritt-2"},
    {"@type": "HowToStep", "position": 3, "name": "Send feedback",
     "text": "Take a screenshot and share it, or use Send Beta Feedback in TestFlight. It reaches me with the device and the build number.",
     "url": "https://swiftlyplayer.com/download/testflight/#schritt-3"}]}, indent=2),
 json.dumps({
  "@context": "https://schema.org", "@type": "BreadcrumbList",
  "itemListElement": [
    {"@type": "ListItem", "position": 1, "name": "Swiftly Player", "item": "https://swiftlyplayer.com/"},
    {"@type": "ListItem", "position": 2, "name": "TestFlight", "item": "https://swiftlyplayer.com/download/testflight/"}]}, indent=2))

seite = kopf(
  "Swiftly Player beta on TestFlight",
  "Try the next Swiftly Player build before it reaches the App Store. Install TestFlight, accept the invitation, send feedback from the app. Free.",
  "/download/testflight/",
  og_titel="Swiftly Player beta on TestFlight",
  og_text="The next build first, and a short way to tell me what broke.",
  extra_ld=LD) + f"""  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>TestFlight</li></ol>
    <h1>The beta on TestFlight</h1>
    <p class="unter">The next build, a week or two before it reaches the App Store. It can break; that is the point, and your report is what fixes it.</p>
  </header>

  <div class="download">
    <p>The beta is open, no invite code needed.</p>
    <a class="knopf knopf--gross" href="{TESTFLIGHT}" target="_blank" rel="noopener">Join the beta</a>
    <p class="download__klein">iPhone, iPad, Mac and Apple TV. Open the link on the device you want it on.</p>
  </div>

  <ol class="schritte">
    <li class="schritt" id="schritt-1">
      <span class="schritt__zahl" aria-hidden="true">1</span>
      <h2>Install TestFlight</h2>
      <p>TestFlight is Apple's own app for beta builds. Install it once, from the App Store, like any other app.</p>
{figur(S1, "TestFlight in the store. Get, and that step is done.")}
    </li>
    <li class="schritt" id="schritt-2">
      <span class="schritt__zahl" aria-hidden="true">2</span>
      <h2>Accept the invitation</h2>
      <p>Open the link above on the device and tap <strong>Install</strong>. The beta sits next to the App Store version, with an orange dot on the icon.</p>
{figur(S2, "The beta in TestFlight. Install puts it on the device.")}
    </li>
    <li class="schritt" id="schritt-3">
      <span class="schritt__zahl" aria-hidden="true">3</span>
      <h2>Tell me what broke</h2>
      <p>Take a screenshot and share it to TestFlight, or tap <strong>Send Beta Feedback</strong>. Your report arrives with the device, the system and the build number, so I do not have to ask.</p>
{figur(S3, "Send Beta Feedback in TestFlight, with the build number attached.")}
    </li>
  </ol>

  <aside class="hinweis" aria-labelledby="gut-zu-wissen">
    <h2 id="gut-zu-wissen">Good to know</h2>
    <ul>
      <li><strong>A build expires after 90 days.</strong> TestFlight then asks for the next one. Nothing is lost; your servers and downloads stay.</li>
      <li><strong>Both versions at once is fine.</strong> Keep the App Store version installed if you want something that does not change.</li>
      <li><strong>Want the stable one?</strong> It is on the <a href="/download/app-store/">App Store</a>.</li>
    </ul>
  </aside>

{mitmachen("Tell me what you think",
           "A beta is only useful if you say what happened. Two short ways, both read by one person.",
           [("brief", "akzent", "Send Beta Feedback", "From inside TestFlight, with a screenshot", TESTFLIGHT),
            ("discord", "akzent", "Discord", "What is coming, and what just broke", DISCORD),
            ("fehler", "kuehl", "Report a bug", "On GitHub, with the build number", ISSUES)])}

{andere("/download/testflight/")}

{HILFE}
""" + fuss("/download/testflight/")

schreiben("/download/testflight/", seite)
