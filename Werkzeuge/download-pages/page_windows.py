# -*- coding: utf-8 -*-
import sys, json
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from parts import *

# On Windows the VLC runtime from VideoLAN is bundled, and some of its modules
# are under the GPL. The sentence comes from THIRD-PARTY-NOTICES.md.
VLC_WINDOWS = VLC_HINT.replace(' <a href="/licenses/">',
    ' On Windows the app ships the VLC 3.0.21 runtime; some of its plugins are under the GPL 2.0 or later. <a href="/licenses/">')
assert VLC_WINDOWS != VLC_HINT

S1 = sketch(1, "A browser window with its download list open; the file Swiftly-Setup.exe is marked",
    BROWSER +
    '<path d="M352 28v11m-4.5-4.5 4.5 4.5 4.5-4.5" stroke="var(--leise)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" fill="none"/>' +
    row(40, 78, 120) + row(40, 96, 92) + row(40, 114, 108) + row(40, 132, 76) +
    '<rect x="196" y="62" width="180" height="104" rx="12" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<text x="208" y="82">Downloads</text>' +
    '<rect x="206" y="92" width="160" height="34" rx="10" fill="rgba(80,213,218,.16)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="218" y="113">Swiftly-Setup.exe</text>' +
    row(206, 136, 120, ".4") +
    pointer(300, 104))

S2 = sketch(2, "A warning window from Windows; the words More info are marked",
    '<rect x="52" y="18" width="296" height="174" rx="16" fill="var(--flaeche)" stroke="var(--rand)"/>' +
    '<path d="M72 62 82 44l10 18z" fill="none" stroke="var(--warm)" stroke-width="1.8" stroke-linejoin="round"/>' +
    '<path d="M82 51v5m0 3v.6" stroke="var(--warm)" stroke-width="1.8" stroke-linecap="round"/>' +
    '<text class="titel" x="104" y="58">Windows protected your PC</text>' +
    row(72, 78, 206) + row(72, 94, 168) +
    '<rect x="66" y="112" width="86" height="26" rx="8" fill="rgba(80,213,218,.16)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="78" y="129">More info</text>' +
    '<rect x="262" y="150" width="76" height="26" rx="8" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<text x="277" y="167">Don&#8217;t run</text>' +
    pointer(120, 122))

S3 = sketch(3, "The same warning window, now with the button Run anyway marked",
    '<rect x="52" y="18" width="296" height="174" rx="16" fill="var(--flaeche)" stroke="var(--rand)"/>' +
    '<text class="titel" x="72" y="52">Windows protected your PC</text>' +
    row(72, 68, 206) + row(72, 84, 150) +
    '<text x="72" y="116">App: Swiftly-Setup.exe</text>' +
    row(72, 126, 120, ".4") +
    '<rect x="176" y="148" width="92" height="30" rx="9" fill="rgba(80,213,218,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="191" y="167">Run anyway</text>' +
    '<rect x="276" y="148" width="62" height="30" rx="9" fill="var(--erhoeht)" stroke="var(--rand)"/>' +
    '<text x="290" y="167">Cancel</text>' +
    pointer(232, 160))

S4 = sketch(4, "The Swiftly Player installer with the Install button marked",
    '<rect x="52" y="18" width="296" height="174" rx="16" fill="var(--flaeche)" stroke="var(--rand)"/>' +
    '<rect x="74" y="44" width="38" height="38" rx="12" fill="rgba(80,213,218,.18)" stroke="var(--marke)"/>' +
    '<path d="M86 56h14m-14 7h14m-14 7h9" stroke="var(--marke)" stroke-width="1.6" stroke-linecap="round"/>' +
    '<text class="titel" x="124" y="60">Swiftly Player</text>' +
    '<text x="124" y="78">Version for Windows</text>' +
    row(74, 104, 200) + row(74, 120, 160) +
    '<rect x="204" y="146" width="88" height="30" rx="9" fill="rgba(80,213,218,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="230" y="165">Install</text>' +
    pointer(258, 158))

LD = """<script type="application/ld+json">
%s
</script>
<script type="application/ld+json">
%s
</script>
""" % (json.dumps({
  "@context": "https://schema.org", "@type": "HowTo",
  "name": "Install Swiftly Player on Windows",
  "description": "Four steps from the downloaded installer to the running app.",
  "inLanguage": "en", "totalTime": "PT2M",
  "estimatedCost": {"@type": "MonetaryAmount", "currency": "USD", "value": "0"},
  "step": [
    {"@type": "HowToStep", "position": 1, "name": "Open the file",
     "text": "The browser puts the installer in your downloads. Click it there.",
     "url": "https://swiftlyplayer.com/download/windows/#schritt-1"},
    {"@type": "HowToStep", "position": 2, "name": "Click More info",
     "text": "Windows says it protected your PC, because it does not know the installer yet. Click More info.",
     "url": "https://swiftlyplayer.com/download/windows/#schritt-2"},
    {"@type": "HowToStep", "position": 3, "name": "Click Run anyway",
     "text": "Under the file name a button Run anyway appears. Click it.",
     "url": "https://swiftlyplayer.com/download/windows/#schritt-3"},
    {"@type": "HowToStep", "position": 4, "name": "Click Install",
     "text": "The installer opens. Click Install. The first start can take up to a minute.",
     "url": "https://swiftlyplayer.com/download/windows/#schritt-4"}]}, indent=2),
 json.dumps({
  "@context": "https://schema.org", "@type": "BreadcrumbList",
  "itemListElement": [
    {"@type": "ListItem", "position": 1, "name": "Swiftly Player", "item": "https://swiftlyplayer.com/"},
    {"@type": "ListItem", "position": 2, "name": "Windows", "item": "https://swiftlyplayer.com/download/windows/"}]}, indent=2))

DOWNLOAD_JS = """
  /* The installer name differs per version (Swiftly-1.0.3-Setup.exe), so
     there is no fixed name under releases/latest/download. The .exe is
     taken from the GitHub API. Without script or on an error the button
     stays a link to the releases page: the same file, one click further.

     This page is the one place that starts the download, whether someone
     opens it directly or arrives via the home page button. That button
     used to start the download itself and change the address 120 ms later,
     which aborts the download just begun. It is now a plain link here. */
  var stand = document.getElementById("stand");
  var erneut = document.getElementById("erneut");
  var fassung = document.getElementById("fassung");
  /* An .exe is useless on a phone, so nothing is downloaded there. */
  var schreibtisch = !/Android|iPhone|iPad|iPod/i.test(navigator.userAgent || "");
  if (!schreibtisch && stand) {
    stand.textContent = "Open this page on your Windows PC and the download starts by itself.";
  }
  if (!window.fetch) { return; }
  fetch("https://api.github.com/repos/paulherter/swiftly-player/releases/latest",
        { headers: { Accept: "application/vnd.github+json" } })
    .then(function (a) { return a.ok ? a.json() : null; })
    .then(function (d) {
      var liste = (d && d.assets) || [], exe = "";
      for (var i = 0; i < liste.length; i++) {
        if (/\\.exe$/i.test(liste[i].name || "")) { exe = liste[i].browser_download_url; break; }
      }
      if (!exe) { throw new Error("kein .exe im Release"); }
      if (erneut) {
        erneut.href = exe;
        erneut.removeAttribute("target");
      }
      if (fassung && d.tag_name) { fassung.textContent = ", version " + String(d.tag_name).replace(/^v/, ""); }
      if (!schreibtisch) { return; }
      /* GitHub sends the file with Content-Disposition: attachment, so the
         browser downloads it and stays on this page. Clicking a generated
         <a> would be more direct, but browsers block that without a user
         gesture. */
      if (stand) { stand.textContent = "Your download has started."; }
      location.href = exe;
    })
    .catch(function () {
      if (stand && schreibtisch) {
        stand.textContent = "Your download did not start. Use the button below.";
      }
    });
"""

page = header(
  "Install Swiftly Player on Windows",
  "The Windows installer downloads right away. Four steps: open the file, click More info, click Run anyway, then Install. With a drawing for each one.",
  "/download/windows/",
  og_title="Install Swiftly Player on Windows",
  og_text="Open the file, click More info, click Run anyway, then Install.",
  extra_ld=LD) + f"""  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>Windows</li></ol>
    <h1>Installing on Windows</h1>
    <p class="unter">Four steps, with a drawing for each one. Windows warns about the installer; the third step is where that warning goes away.</p>
  </header>

  <div class="download">
    <p id="stand">Your download should start automatically.</p>
    <a class="knopf knopf--gross" id="erneut" href="{GITHUB}/releases/latest" target="_blank" rel="noopener">If not, click here</a>
    <p class="download__klein">Windows 10 and 11, 64-bit<span id="fassung"></span>.</p>
  </div>

  <ol class="schritte">
    <li class="schritt" id="schritt-1">
      <span class="schritt__zahl" aria-hidden="true">1</span>
      <h2>Open the file</h2>
      <p>The browser puts <strong>Swiftly-Setup.exe</strong> in your downloads. Click it there, or open the Downloads folder and double-click it.</p>
{figure(S1, "The download list in the browser, with the installer in it.")}
    </li>
    <li class="schritt" id="schritt-2">
      <span class="schritt__zahl" aria-hidden="true">2</span>
      <h2>Click More info</h2>
      <p>Windows does not know this installer yet and says <strong>Windows protected your PC</strong>. Click <strong>More info</strong>.</p>
{figure(S2, "The warning window. More info is the small line above the buttons.")}
    </li>
    <li class="schritt" id="schritt-3">
      <span class="schritt__zahl" aria-hidden="true">3</span>
      <h2>Click Run anyway</h2>
      <p>The window now shows the file name, and under it a new button: <strong>Run anyway</strong>. Click it.</p>
{figure(S3, "The same window after More info, now with Run anyway.")}
    </li>
    <li class="schritt" id="schritt-4">
      <span class="schritt__zahl" aria-hidden="true">4</span>
      <h2>Click Install</h2>
      <p>The installer opens. Click <strong>Install</strong> and wait a few seconds. Swiftly Player then starts on its own.</p>
{figure(S4, "The installer. One button, then it is done.")}
    </li>
  </ol>

  <aside class="hinweis" aria-labelledby="erster-start">
    <h2 id="erster-start">The first start takes a moment</h2>
    <ul>
      <li><strong>Up to a minute.</strong> On the first start Swiftly unpacks its player. A small window shows that it is working. Every start after that is quick.</li>
      <li><strong>Why Windows warns.</strong> The installer carries no paid signing certificate, so Windows does not recognise the publisher. The code is on <a href="{GITHUB}" target="_blank" rel="noopener">GitHub</a>, and the installer is built from it.</li>
      <li><strong>You need a Jellyfin server.</strong> Swiftly is the client, and it speaks the Jellyfin API only.</li>
    </ul>
  </aside>

{join("Tell me what you think",
           "Windows is the newest version after Linux, so a report from you often finds something nobody has seen yet.",
           [("discord", "akzent", "Discord", "Help, ideas, early builds", DISCORD),
            ("fehler", "kuehl", "Report a bug", "On GitHub, with your Windows version", ISSUES),
            ("code", "akzent", "Read the source", "MPL-2.0, including the installer", GITHUB)])}

{other("/download/windows/")}

{VLC_WINDOWS}
{HELP}
""" + footer("/download/windows/").replace("{kopieren}", "").replace("\n})();", DOWNLOAD_JS + "})();")

write("/download/windows/", page)
