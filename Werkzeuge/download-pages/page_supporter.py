# -*- coding: utf-8 -*-
"""Page /supporter/ and every way to it on the hand-written pages.

The switch is SUPPORTER in parts.py. This script builds or removes the page and
adds or removes the links on the pages no generator writes: index.html (bar,
menu, footer, a quiet band below the downloads), support.html, impressum.html,
datenschutz.html and privacy.html (footer link, and the payments section in
both privacy notices). Everything it adds sits between supporter markers, so
switching off removes exactly that. Run it before page_music.py, which copies
the footer of index.html.
"""
import os, re, shutil, sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from parts import *

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKOUT = "https://pay.paulherter.de/checkout"
PREVIEW = SUPPORTER == "preview"

ICON = {
    "frei": '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    "schloss": '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
    "leute": '<circle cx="9" cy="9" r="3"/><path d="M3.5 19c.6-3 2.7-5 5.5-5s4.9 2 5.5 5M16 6.5a3 3 0 0 1 0 5.8M17 14.2c2 .5 3.2 2.2 3.6 4.8"/>',
}


def chip(number, icon, title, under):
    return (f'    <div class="plakette plakette--{number}" aria-hidden="true"><span class="plakette__zeichen">'
            f'<svg viewBox="0 0 24 24">{ICON[icon]}</svg></span><span><b>{title}</b><em>{under}</em></span></div>')


SCRIPT = """<script>
(function () {
  var preview = %s;
  var tiers = {
    once: [
      { cents: 500,  emoji: "\\u2615", name: "A coffee", note: "" },
      { cents: 1000, emoji: "\\ud83c\\udf70", name: "Coffee and cake", note: "suggested" },
      { cents: 2500, emoji: "\\ud83c\\udfac", name: "A movie night", note: "" }
    ],
    monthly: [
      { cents: 300, emoji: "\\u2615", name: "A small coffee", note: "" },
      { cents: 500, emoji: "\\ud83c\\udf6a", name: "Coffee and a cookie", note: "suggested" }
    ]
  };
  var start = { once: 1000, monthly: 500 };
  var least = { once: 500, monthly: 300 };
  var most = 50000;
  var mode = "once", cents = start.once;
  var el = function (id) { return document.getElementById(id); };
  var box = el("stufen"), own = el("eigen"), ownIn = el("eigenZahl"), note = el("meldung"), go = el("weiter");

  function eur(c) { return (c / 100) %% 1 ? (c / 100).toFixed(2) : String(c / 100); }
  function label() { return (mode === "once" ? "Buy us a coffee \\u00b7 " : "Support us every month \\u00b7 ") + eur(cents) + " \\u20ac"; }

  function draw() {
    box.innerHTML = "";
    box.className = "stufen" + (mode === "monthly" ? " stufen--zwei" : "");
    tiers[mode].forEach(function (t, i) {
      var id = "t-" + mode + i, d = document.createElement("div");
      d.className = "stufe";
      /* The radios only pick; they belong to no form, so only the hidden
         fields go to the checkout. */
      d.innerHTML =
        '<input type="radio" form="nur-auswahl" name="wahl" id="' + id + '" value="' + t.cents + '"' + (t.cents === cents && !own.classList.contains("aktiv") ? " checked" : "") + '>' +
        '<label for="' + id + '">' +
          (t.note ? '<span class="stufe__marke">' + t.note + '</span>' : '') +
          '<span class="stufe__bild" aria-hidden="true">' + t.emoji + '</span>' +
          '<span class="stufe__name">' + t.name + '</span>' +
          '<span class="stufe__preis">' + eur(t.cents) + ' \\u20ac' + (mode === "monthly" ? ' a month' : '') + '</span>' +
        '</label>';
      d.querySelector("input").addEventListener("change", function () {
        cents = t.cents; own.classList.remove("aktiv"); ownIn.value = ""; sync();
      });
      box.appendChild(d);
    });
    el("eigenText").textContent = mode === "once" ? "Something else? Pick your own amount, 5 to 500 \\u20ac" : "Something else? Pick your own monthly amount, from 3 \\u20ac";
    sync();
  }

  /* The checkout takes interval (once or month), tier (5, 10, 25 or 3, 5) or
     tier=custom with amount in euros. It checks the limits itself. */
  function fields() {
    var custom = own.classList.contains("aktiv");
    el("intervall").value = mode === "once" ? "once" : "month";
    el("stufe").value = custom ? "custom" : String(cents / 100);
    el("betrag").value = custom ? eur(cents) : "";
    el("betrag").disabled = !custom;
  }

  function sync() {
    var ok = cents >= least[mode] && cents <= most;
    fields();
    go.disabled = !ok; go.textContent = label();
    if (ok) { note.textContent = ""; note.className = "kasse__meldung"; }
  }

  document.querySelectorAll(".umschalter button").forEach(function (b) {
    b.addEventListener("click", function () {
      mode = b.getAttribute("data-mode");
      document.querySelectorAll(".umschalter button").forEach(function (x) { x.setAttribute("aria-checked", x === b ? "true" : "false"); });
      own.classList.remove("aktiv"); ownIn.value = ""; cents = start[mode]; draw();
    });
  });

  ownIn.addEventListener("input", function () {
    var raw = ownIn.value.replace(/[^0-9]/g, ""); ownIn.value = raw;
    if (!raw) { own.classList.remove("aktiv"); cents = start[mode]; draw(); return; }
    var v = parseInt(raw, 10) * 100;
    own.classList.add("aktiv");
    box.querySelectorAll("input").forEach(function (r) { r.checked = false; });
    cents = v; fields(); go.textContent = label();
    if (v < least[mode]) { note.textContent = mode === "once" ? "The smallest amount is 5 \\u20ac." : "The smallest monthly amount is 3 \\u20ac."; note.className = "kasse__meldung an"; go.disabled = true; return; }
    if (v > most) { note.textContent = "The largest amount is 500 \\u20ac."; note.className = "kasse__meldung an"; go.disabled = true; return; }
    sync();
  });

  el("kasse").addEventListener("submit", function (e) {
    if (go.disabled) { e.preventDefault(); return; }
    if (preview) {
      e.preventDefault();
      note.className = "kasse__meldung"; note.textContent = "Preview only. On the real page this takes you to the payment page.";
    }
  });

  draw();
})();
</script>
""" % ("true" if PREVIEW else "false")


def build():
    css = open(os.path.join(HERE, "supporter.css"), encoding="utf-8").read()
    head = (f'<meta name="robots" content="noindex, follow">\n<style>\n{css}</style>\n'
            '<script src="/js/effekte.js" defer></script>\n')
    badge = '\n<div class="vorschau">Preview, not connected</div>\n' if PREVIEW else ""
    page = header(
        "Buy us a coffee - Swiftly Player",
        "All the features you need are free. If it makes your evenings better, a coffee gets you a few extras and helps us keep it going.",
        SUPPORTER_PATH,
        og_title="Buy us a coffee",
        og_text="All the features you need are free. A coffee gets you a few extras and helps us keep it going.",
        extra_ld=head) + f"""{badge}  <div class="kaffeekopf hero" data-plaketten>
{chip(1, "frei", "Free for everyone", "All the features you need")}
{chip(2, "schloss", "No account, no ads", "And no tracking")}
{chip(3, "leute", "Built together", "With your bug reports and pull requests")}
    <header class="seitenkopf seitenkopf--mitte">
      <h1>Buy us a coffee <span class="tasse">&#9749;</span></h1>
      <p class="unter">All the features you need are free. If it makes your evenings better, a coffee gets you a few extras and helps us keep it going.</p>
    </header>
  </div>

  <form class="kasse" id="kasse" method="post" action="{CHECKOUT}" novalidate>
    <input type="hidden" name="app" value="swiftly">
    <input type="hidden" name="interval" id="intervall" value="once">
    <input type="hidden" name="tier" id="stufe" value="10">
    <input type="hidden" name="amount" id="betrag" value="" disabled>

    <div class="umschalter" role="radiogroup" aria-label="How often">
      <button type="button" role="radio" aria-checked="true" data-mode="once">Just once</button>
      <button type="button" role="radio" aria-checked="false" data-mode="monthly">Every month</button>
    </div>

    <fieldset id="stufen" class="stufen"><legend class="nur-fuer-leser">Amount</legend></fieldset>

    <div class="eigen" id="eigen">
      <label id="eigenText" for="eigenZahl">Something else? Pick your own amount, 5 to 500 &euro;</label>
      <div class="eigen__feld"><input id="eigenZahl" type="text" inputmode="numeric" autocomplete="off" placeholder="15"><b aria-hidden="true">&euro;</b></div>
    </div>
    <p class="kasse__meldung" id="meldung" role="status" aria-live="polite"></p>

    <div class="kasse__weiter">
      <button class="knopf knopf--gross" id="weiter" type="submit">Buy us a coffee &middot; 10 &euro;</button>
      <p class="kasse__klein">Payments go through Link (by Stripe), which also handles tax and receipts. We never see your card.</p>
    </div>
  </form>

  <section class="abschnitt" aria-labelledby="dank">
    <h2 id="dank">Thank you, in small things</h2>
    <div class="dank">
      <div class="dank__kachel"><span class="dank__zeichen" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5a2 2 0 0 0 4 0M4 4l16 16"/></svg></span><h3>No more reminders</h3><p>The app asks once per version. With your key it stays quiet.</p></div>
      <div class="dank__kachel"><span class="dank__zeichen" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="4.5"/><path d="M12 16.2s-3.6-2.2-3.6-4.9a2 2 0 0 1 3.6-1.2 2 2 0 0 1 3.6 1.2c0 2.7-3.6 4.9-3.6 4.9z"/></svg></span><h3>Supporter icons</h3><p>Extra app icons, and a little heart in About.</p></div>
      <div class="dank__kachel"><span class="dank__zeichen" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 5h14M5 9.5h14M5 14h9M5 18.5h6"/><path d="m16 17 1.6 1.6L21 15"/></svg></span><h3>Your name in the credits</h3><p>If you want it. It is up to you.</p></div>
    </div>
    <p class="dank__frei"><span>All the features you need stay free, for everyone.</span> Supporters get a few extras on top.</p>
  </section>

{join("No coffee? Still welcome.",
      "Swiftly gets better when many people chip in.",
      [("fehler", "akzent", "Report a bug or a wish", "On Discord or GitHub", ISSUES),
       ("code", "kuehl", "Send a pull request", "The contributing guide shows how", GITHUB + "/blob/main/CONTRIBUTING.md"),
       ("discord", "akzent", "Help with a translation", "Every language counts", DISCORD),
       ("stern", "kuehl", "Tell a friend with a Jellyfin server", "That helps most of all", "/")])}

  <section class="abschnitt" aria-labelledby="fragen">
    <h2 id="fragen">Questions</h2>
    <div class="fragen__blatt">
{question("Where does the money go?", "Into the running costs: the Apple developer fee, hosting for the site and updates, and test devices.", opened=True)}
{question("Do I need an account?", "No. After paying you get a key on the thank-you page and by email. You type it into the app.")}
{question("Where does the key work?", "In the Windows, Linux and Android APK builds from this site or GitHub. The App Store and Google Play versions have no key field. Everything you need to watch is free there too.")}
{question("Can I cancel or get a refund?", 'Yes. Every receipt links to manage or cancel a monthly payment. For a refund, write to <a href="mailto:info@swiftlyplayer.com">info@swiftlyplayer.com</a>.')}
    </div>
  </section>

{SCRIPT}""" + footer(SUPPORTER_PATH)
    write(SUPPORTER_PATH, page)


# ------------------------------------------------------------------ Hand-written pages

LINE = "<!-- supporter -->"
HIDDEN = "<!-- supporter:hidden"
START, END = "<!-- supporter:start -->", "<!-- supporter:end -->"
CSS_START, CSS_END = "/* supporter:start */", "/* supporter:end */"

BAND_CSS = f"""{CSS_START}
/* A quiet line below the downloads, to the supporter page. */
.kaffee {{ display: flex; align-items: center; justify-content: center; gap: 12px; flex-wrap: wrap;
  max-width: 760px; margin: 0 auto; padding: 8px var(--seitenrand) 0; text-align: center;
  color: var(--leise); font-size: 17px; line-height: 1.5; }}
.kaffee svg {{ flex: none; width: 22px; height: 22px; fill: none; stroke: var(--akzent); stroke-width: 1.8;
  stroke-linecap: round; stroke-linejoin: round; }}
.kaffee a {{ color: var(--schrift); font-weight: 600; text-decoration: underline;
  text-decoration-color: var(--akzent); text-underline-offset: 4px; }}
@media (hover: hover) and (pointer: fine) {{ .kaffee a:hover {{ color: var(--akzent); }} }}
/* Donate next to Download, styled like the second button it replaces. */
.knopf--spenden {{ gap: 8px; }}
.knopf--spenden svg {{ width: 18px; height: 18px; flex: none; fill: none; stroke: var(--akzent); stroke-width: 2; stroke-linejoin: round; }}
{CSS_END}
"""

BAND = f"""{START}
<aside class="kaffee" aria-label="Support Swiftly">
  <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h13v5a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5zM17 10.5h1.5a2.5 2.5 0 0 1 0 5H16.6M8 3.5c-.6.8-.6 1.7 0 2.5M12 3.5c-.6.8-.6 1.7 0 2.5"/></svg>
  <p>All the features you need are free. If it makes your evenings better, <a href="{SUPPORTER_PATH}">buy us a coffee</a> for a few extras.</p>
</aside>
{END}
"""

PRIVACY_EN = f"""{START}

<h2>Payments on the supporter page</h2>
<p>If you buy us a coffee on the <a href="{SUPPORTER_PATH}">supporter page</a>, you pay
through Link, a service by Stripe. For this purchase Link is the seller: it
processes the payment, handles tax and sends the receipt. Your card or bank
details go to Link and Stripe, not to me, and their privacy notices apply there.
Stripe may process data outside the EU; that is covered by the safeguards in
their notices.</p>
<p>The payment page itself, pay.paulherter.de, is run by me. When you start a
payment it receives the amount and interval you chose, and like any web server it
logs the request (IP address, time, browser identification). From the purchase I
receive only the order: the amount, the time and, if you enter them, your name
and email address for the supporter key. The key is sent by email from
noreply@paulherter.de. The legal basis is Article 6(1)(b) GDPR, carrying out what
you asked for, and for the name in the credits your consent under Article 6(1)(a),
which you can withdraw. Order records are kept as long as tax law requires.
Nothing on the supporter page is tracked, and it sets no cookies.</p>

<h2>Purchases in the apps</h2>
<p>Where an app offers a tip or supporter purchase through the App Store or
Google Play, Apple or Google is the seller. You pay them under their terms and
privacy notices. I receive no data about buyers from the stores, only anonymous
sales totals. A supporter key you enter in an app is checked on the device and
is not sent anywhere.</p>

{END}
"""

PRIVACY_DE = f"""{START}

<h2>Zahlungen auf der Supporter-Seite</h2>
<p>Wenn Sie uns auf der <a href="{SUPPORTER_PATH}">Supporter-Seite</a> einen Kaffee
ausgeben, bezahlen Sie über Link, einen Dienst von Stripe. Für diesen Kauf ist
Link der Verkäufer: Link wickelt die Zahlung ab, kümmert sich um die Steuer und
verschickt den Beleg. Ihre Karten- oder Kontodaten gehen an Link und Stripe,
nicht an mich; dort gelten deren Datenschutzhinweise. Stripe kann Daten auch
außerhalb der EU verarbeiten; dafür gelten die Garantien in deren Hinweisen.</p>
<p>Die Zahlungsseite pay.paulherter.de betreibe ich selbst. Wenn Sie eine Zahlung
starten, erhält sie den gewählten Betrag und Rhythmus und hält, wie jeder
Webserver, die Anfrage fest (IP-Adresse, Zeitpunkt, Browserkennung). Aus dem Kauf
erhalte ich nur die Bestellung: Betrag, Zeitpunkt und, falls Sie sie angeben,
Ihren Namen und Ihre E-Mail-Adresse für den Supporter-Schlüssel. Der Schlüssel
kommt per E-Mail von noreply@paulherter.de. Rechtsgrundlage ist Artikel 6
Absatz 1 Buchstabe b DSGVO, die Ausführung dessen, worum Sie gebeten haben, und
für den Namen in den Credits Ihre Einwilligung nach Buchstabe a, die Sie
widerrufen können. Bestelldaten werden so lange aufbewahrt, wie das Steuerrecht
es verlangt. Auf der Supporter-Seite selbst wird nichts verfolgt, sie setzt keine
Cookies.</p>

<h2>Käufe in den Apps</h2>
<p>Bietet eine App ein Trinkgeld oder einen Supporter-Kauf über den App Store
oder Google Play an, ist Apple beziehungsweise Google der Verkäufer. Sie bezahlen
dort nach deren Bedingungen und Datenschutzhinweisen. Aus den Stores erhalte ich
keine Daten über Käufer, nur anonyme Verkaufszahlen. Einen Supporter-Schlüssel,
den Sie in einer App eingeben, prüft die App auf dem Gerät; er wird nirgendwohin
geschickt.</p>

{END}
"""


def strip(s):
    s = re.sub(re.escape(START) + r".*?" + re.escape(END) + r"\n{0,2}", "", s, flags=re.S)
    s = re.sub(r"\n?" + re.escape(CSS_START) + r".*?" + re.escape(CSS_END) + r"\n?", "\n", s, flags=re.S)
    s = "\n".join(l for l in s.split("\n") if not l.rstrip().endswith(LINE))
    s = re.sub(re.escape(HIDDEN) + r" (.*?) -->", r"\1", s)
    return s


def insert(s, anchor, text, before=False):
    if s.count(anchor) != 1:
        sys.exit(f"anchor not unique: {anchor[:60]}")
    return s.replace(anchor, text + anchor if before else anchor + text)


def maintain(name, change):
    path = os.path.join(WEBSITE, name)
    with open(path, encoding="utf-8") as h:
        old = h.read()
    new = strip(old)
    if SUPPORTER_ON:
        new = change(new)
    if new != old:
        with open(path, "w", encoding="utf-8") as h:
            h.write(new)
        print("geschrieben", path, len(new))


def index(s):
    # Download and Donate only; the Swiftly Music button waits in a comment
    # and comes back when the switch is off. Music stays in the bar.
    music = '        <a class="knopf knopf--gross knopf--zweit hero__knopf" href="/music/">Swiftly Music</a>\n'
    s = insert(s, music, f"{DONATE_BUTTON} {LINE}\n")
    s = s.replace(music, f"        {HIDDEN} {music.strip()} -->\n", 1)
    s = insert(s, '  <a class="knopf knopf--gross" href="#downloads">Download</a>\n</nav>',
               f'  <a href="{SUPPORTER_PATH}">{SUPPORTER_LINK}</a> {LINE}\n', before=True)
    s = insert(s, '          <li><a href="https://discord.gg/MeGwfv3UwN" target="_blank" rel="noopener">Discord</a></li>\n',
               f'          <li><a href="{SUPPORTER_PATH}">{SUPPORTER_LINK}</a></li> {LINE}\n')
    s = insert(s, "</main>\n", BAND + "\n", before=True)
    return insert(s, "</style>", BAND_CSS, before=True)


def small_footer(word):
    def change(s):
        return insert(s, "</div></footer>", f'{START} · <a href="{SUPPORTER_PATH}">{word}</a>{END}', before=True)
    return change


def privacy(anchor, text, word):
    def change(s):
        return small_footer(word)(insert(s, anchor, text, before=True))
    return change


if SUPPORTER_ON:
    build()
else:
    folder = os.path.join(WEBSITE, SUPPORTER_PATH.strip("/"))
    if os.path.isdir(folder):
        shutil.rmtree(folder)
        print("entfernt", folder)

maintain("index.html", index)
maintain("support.html", small_footer(SUPPORTER_LINK))
maintain("impressum.html", small_footer("Spenden"))
maintain("privacy.html", privacy("<h2>Who is responsible, and your rights</h2>", PRIVACY_EN, SUPPORTER_LINK))
maintain("datenschutz.html", privacy("<h2>Verantwortlicher und Ihre Rechte</h2>", PRIVACY_DE, "Spenden"))
