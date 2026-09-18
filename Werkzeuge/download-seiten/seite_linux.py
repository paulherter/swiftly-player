# -*- coding: utf-8 -*-
import sys, json
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from teile import *

BEFEHL = "curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Installieren/swiftly-installieren.sh | bash"

S1 = skizze(1, "The command on this page with the Copy button marked",
    '<rect x="14" y="40" width="372" height="130" rx="16" fill="var(--tief)" stroke="var(--linie)"/>' +
    '<text x="34" y="80">curl -fsSL https://...</text>' +
    '<text x="34" y="100">/swiftly-installieren.sh | bash</text>' +
    '<rect x="252" y="118" width="96" height="32" rx="16" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="284" y="138">Copy</text>' +
    zeiger(300, 130))

S2 = skizze(2, "A terminal window with the pasted command and the Enter key marked",
    '<rect x="14" y="20" width="372" height="170" rx="16" fill="var(--tief)" stroke="var(--rand)"/>' +
    '<path d="M14 54h372" stroke="var(--linie)"/>' +
    '<circle cx="34" cy="37" r="4" fill="var(--rand)"/><circle cx="48" cy="37" r="4" fill="var(--rand)"/><circle cx="62" cy="37" r="4" fill="var(--rand)"/>' +
    '<text x="150" y="42">Terminal</text>' +
    '<text x="34" y="86">$ curl -fsSL https://...</text>' +
    '<text x="34" y="106">  | bash</text>' +
    '<rect x="34" y="124" width="8" height="14" fill="var(--akzent)"/>' +
    '<rect x="226" y="134" width="120" height="36" rx="10" fill="rgba(92,209,194,.18)" stroke="var(--akzent)"/>' +
    '<text class="ziel" x="262" y="156">Enter</text>' +
    zeiger(282, 148))

LD = """<script type="application/ld+json">
%s
</script>
<script type="application/ld+json">
%s
</script>
""" % (json.dumps({
  "@context": "https://schema.org", "@type": "HowTo",
  "name": "Install Swiftly Player on Linux",
  "description": "Copy one command, paste it into a terminal, press Enter. It sets up the repository and installs the package.",
  "inLanguage": "en", "totalTime": "PT2M",
  "estimatedCost": {"@type": "MonetaryAmount", "currency": "USD", "value": "0"},
  "step": [
    {"@type": "HowToStep", "position": 1, "name": "Copy the command",
     "text": "Copy the one-line install command from this page.",
     "url": "https://swiftlyplayer.com/download/linux/#schritt-1"},
    {"@type": "HowToStep", "position": 2, "name": "Paste it into a terminal",
     "text": "Open a terminal, paste the command and press Enter. The script adds the repository and installs the package for apt, dnf, zypper or pacman.",
     "url": "https://swiftlyplayer.com/download/linux/#schritt-2"},
    {"@type": "HowToStep", "position": 3, "name": "Start Swiftly Player",
     "text": "Swiftly Player then shows up in your application menu. Updates arrive with your normal system update.",
     "url": "https://swiftlyplayer.com/download/linux/#schritt-3"}]}, indent=2),
 json.dumps({
  "@context": "https://schema.org", "@type": "BreadcrumbList",
  "itemListElement": [
    {"@type": "ListItem", "position": 1, "name": "Swiftly Player", "item": "https://swiftlyplayer.com/"},
    {"@type": "ListItem", "position": 2, "name": "Linux", "item": "https://swiftlyplayer.com/download/linux/"}]}, indent=2))

seite = kopf(
  "Install Swiftly Player on Linux",
  "One command installs Swiftly Player on Debian, Ubuntu, Fedora, openSUSE and Arch. Copy it, paste it into a terminal, press Enter. Updates come with your system.",
  "/download/linux/",
  og_titel="Swiftly Player on Linux",
  og_text="One command for apt, dnf, zypper and pacman. Updates with your system.",
  extra_ld=LD) + f"""  <header class="seitenkopf seitenkopf--mitte">
    <ol class="pfad"><li><a href="/">Swiftly Player</a></li><li>Linux</li></ol>
    <h1>Swiftly on Linux</h1>
    <p class="unter">One command sets up the repository and installs the package. After that, Swiftly updates with the rest of your system.</p>
  </header>

  <div class="download">
    <p>Copy this, paste it into a terminal, press Enter.</p>
    <div class="codeblock"><pre><code class="language-sh">{BEFEHL}</code></pre></div>
    <p class="download__klein">GTK 4, x86-64. Debian, Ubuntu, Fedora, openSUSE and Arch are covered.</p>
  </div>

  <ol class="schritte">
    <li class="schritt" id="schritt-1">
      <span class="schritt__zahl" aria-hidden="true">1</span>
      <h2>Copy the command</h2>
      <p>The <strong>Copy</strong> button above puts it on your clipboard and says <strong>Copied</strong>. You can also select the line and copy it by hand.</p>
{figur(S1, "The command with its Copy button.")}
    </li>
    <li class="schritt" id="schritt-2">
      <span class="schritt__zahl" aria-hidden="true">2</span>
      <h2>Paste it into a terminal and press Enter</h2>
      <p>Open a terminal, paste the line and press <strong>Enter</strong>. The script asks for your password once, because installing a package needs it. It adds the Swiftly repository and installs the package your system uses.</p>
{figur(S2, "A terminal with the pasted command, waiting for Enter.")}
    </li>
    <li class="schritt" id="schritt-3">
      <span class="schritt__zahl" aria-hidden="true">3</span>
      <h2>Start it and add your server</h2>
      <p>Swiftly Player shows up in your application menu. Type the address of your Jellyfin server, sign in, and press play. Updates then arrive with your normal system update.</p>
    </li>
  </ol>

  <section class="abschnitt" aria-labelledby="pakete">
    <h2 id="pakete">What the command installs</h2>
    <p>Nothing surprising: the repository for your package manager, then the package.</p>
    <ul class="paketliste">
      <li><b>apt</b><span>Debian and Ubuntu, from our apt repository</span></li>
      <li><b>dnf</b><span>Fedora, from our rpm repository</span></li>
      <li><b>zypper</b><span>openSUSE, same rpm packages</span></li>
      <li><b>pacman</b><span>Arch, package built for x86-64</span></li>
    </ul>
    <p style="margin-top:18px">If you would rather not pipe a script into a shell: the <code>.deb</code>, <code>.rpm</code> and <code>.tar.gz</code> files are attached to every <a href="{GITHUB}/releases/latest" target="_blank" rel="noopener">GitHub release</a>, and the install script itself is <a href="{GITHUB}/blob/main/Linux/Installieren/swiftly-installieren.sh" target="_blank" rel="noopener">right there to read</a> before you run it.</p>
  </section>

  <aside class="hinweis" aria-labelledby="gut-zu-wissen">
    <h2 id="gut-zu-wissen">Good to know</h2>
    <ul>
      <li><strong>Playback uses libVLC.</strong> The same engine as on the Apple versions, so MKV, HEVC, AV1 and PGS subtitles play as they are.</li>
      <li><strong>Wayland and X11 both work.</strong> The interface is GTK 4.</li>
      <li><strong>Something missing?</strong> Linux is the newest version, and the list of what is not there yet is short but real. Say what you need.</li>
    </ul>
  </aside>

{mitmachen("Tell me what you think",
           "Built by one person. On Linux, your report is often the first time a distribution gets tested at all.",
           [("discord", "akzent", "Discord", "Help, ideas, early builds", DISCORD),
            ("fehler", "kuehl", "Report a bug", "On GitHub, with your distribution", ISSUES),
            ("code", "akzent", "Read the source", "MPL-2.0, including the install script", GITHUB)])}

{andere("/download/linux/")}

{HILFE}
""" + fuss("/download/linux/", mit_kopieren=True)

schreiben("/download/linux/", seite)
