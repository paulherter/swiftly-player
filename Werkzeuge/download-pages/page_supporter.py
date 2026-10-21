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
CANCEL = "https://pay.paulherter.de/cancel"
PREVIEW = SUPPORTER == "preview"

IMG = "/bilder/supporter/"
SPROUT = ('<svg class="spross" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 13C12 8.5 8.5 6 4 6c0 4.5 3 7 8 7zM12 11c0-4 3-7 8-7 0 4.5-3 7-8 7z" fill="currentColor"/>'
          '<path d="M12 22V10" stroke="currentColor" stroke-width="2" stroke-linecap="round" fill="none"/></svg>')
HEART = '<path fill="currentColor" d="M12 20.5s-7.8-4.7-7.8-10.6A4.4 4.4 0 0 1 12 7.2a4.4 4.4 0 0 1 7.8 2.7c0 5.9-7.8 10.6-7.8 10.6z"/>'
LOOKS = ["Original", "Neon Night", "Sunset", "Aurora", "Ice", "Ember", "Gold", "Emerald"]
PLUS = ('<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
        'stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>')


def svg(path):
    return ('<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{path}</svg>')


def phones():
    """Three mini phones with Home in Sunset, Neon Night and Aurora, as in the app sheet."""
    one = []
    for colour, turn, delay in (("#FF8C6B", "-7deg", "0s"), ("#B08CFF", "0deg", ".6s"), ("#5AD3E8", "7deg", "1.2s")):
        one.append(f'<div class="platz"><div class="mini" style="--a: {colour}; --r: {turn}; animation-delay: {delay}">'
                   f'<span class="mini__schein"></span><img class="mini__logo" src="{IMG}mini-logo.svg" alt="">'
                   f'<svg class="mini__herz" viewBox="0 0 24 24" aria-hidden="true">{HEART}</svg>'
                   '<span class="mini__t">Continue watching</span>'
                   f'<span class="mini__quer"><img src="{IMG}poster-quer.webp" alt="" loading="lazy"><i></i></span>'
                   f'<span class="mini__hoch mini__hoch--1"><img src="{IMG}poster-1.webp" alt="" loading="lazy"></span>'
                   f'<span class="mini__hoch mini__hoch--2"><img src="{IMG}poster-2.webp" alt="" loading="lazy"></span>'
                   '<span class="mini__tabs"><i class="an"></i><i></i><i></i><i></i></span></div></div>')
    return ('<div class="drei" role="img" aria-label="Home in three looks: Sunset, Neon Night and Aurora">'
            + "".join(one) + "</div>")


def scoped(css):
    """Puts every selector under .pg, so the v5 styles never reach the bar, the
    footer or the base styles. Everything after the "unscoped" comment stays as it is."""
    css, _, rest = css.partition("/* unscoped")
    rest = rest.split("*/", 1)[1] if rest else ""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)

    def rules(text):
        out, i = [], 0
        while True:
            j = text.find("{", i)
            if j < 0:
                return "".join(out)
            head = text[i:j].strip()
            depth, k = 1, j + 1
            while depth:
                depth += {"{": 1, "}": -1}.get(text[k], 0)
                k += 1
            body = text[j + 1:k - 1]
            if head.startswith("@keyframes"):
                out.append(f"{head} {{{body}}}\n")
            elif head.startswith("@"):
                out.append(f"{head} {{\n{rules(body)}}}\n")
            else:
                sel = ", ".join(x if x.startswith(".pg") else ".pg " + x
                                for x in (y.strip() for y in head.split(",")))
                out.append(f"{sel} {{{body}}}\n")
            i = k
    return rules(css) + rest


def style(name):
    return scoped(open(os.path.join(HERE, name), encoding="utf-8").read())


# Beta invitation for supporters. Empty until Paul has the real link (TestFlight
# public link or similar). While empty, the thank-you pages show a placeholder
# line and carry the marker BETA-PLATZHALTER, which the upload check looks for.
BETA_INVITE_URL = ""
DE_PATH = SUPPORTER_PATH + "de/"
THANKS_PATH = SUPPORTER_PATH + "thanks/"
THANKS_DE_PATH = DE_PATH + "danke/"

# All visible words of the page, per language. The English text is the master.
TXT = {
    "en": {
        "title": "Support Swiftly - Swiftly Player",
        "desc": "Swiftly Player stays free. On Linux and Windows you can support it here: 1.99 € a month, 19.99 € once, or a tip.",
        "og_title": "Help Swiftly grow",
        "og_text": "Your support keeps Swiftly going. Open source, no ads, everything for watching stays free.",
        "h1": "Help Swiftly <span class=\"nb\">grow{S}</span>",
        "unter": "Your support keeps Swiftly going.",
        "klein2": "Open source, no ads, everything for watching stays free.",
        "b_support": "Support Swiftly", "b_where": "Where to buy",
        "phones": "Home in three looks: Sunset, Neon Night and Aurora", "phones_t": "Continue watching",
        "where_h": "Where to buy",
        "in_app": "In the app",
        "in_app_p": "iPhone, iPad, Mac, Apple TV, Android and Android TV. You support inside the app, through the App Store or Google Play.",
        "here": "Here on this page",
        "here_p": "Linux and Windows. You buy right here and get a key for those two.",
        "get_h": "What you get", "get_p": "Watching stays free. Supporters get these extras.",
        "benefits": [
            ("8 looks", "One tap changes the accent, the Home light and the app icon. Try each one first."),
            ("Accent and Home glow", "Pick the colour and set the glow to off, soft or bright."),
            ("8 app icons", "One per look, drawn like any app icon."),
            ("Your name in the credits", "Optional. Listed in the app's About screen and in the supporters list on GitHub, only if you tick the box. Gone on request."),
        ],
        "icons_h": "The app icons", "icons_n": "App icons depend on what each system allows.",
        "opt_h": "Support on Linux and Windows", "opt_p": "Same prices as in the stores.",
        "legend": "How you want to support",
        "m_mark": "Popular", "m_name": "Monthly", "m_price": "1.99 € <small>a month</small>",
        "m_sub": "Renews every month until you cancel. Cancel any time.",
        "l_mark": "Great deal", "l_name": "Lifetime", "l_price": "19.99 € <small>once</small>",
        "l_sub": "Pay once, for as long as Swiftly Player exists.",
        "tip_label": "Just a thank-you, it unlocks nothing", "tip_group": "Just a thank-you",
        "tip": ["1.99 €", "4.99 €", "9.99 €"], "other": "Other", "own_aria": "Your own amount in euros",
        "name_l": "Name for the credits", "name_o": "Optional", "name_ph": "How we should write it",
        "credit": "Show this name in the credits: in the app's About screen and in the supporters list on GitHub. Not ticked, no name is shown. Remove it any time with one email to <a href=\"mailto:info@swiftlyplayer.com\">info@swiftlyplayer.com</a>; it is gone from the next app update and from GitHub within a week.",
        "withdraw": "Send me the key right away. I agree that you start before the 14-day withdrawal period ends, and I know that I lose my right of withdrawal once I have the key.",
        "choose": "Choose an option",
        "fine": "Monthly: 1.99 € a month, VAT included, renews every month until you cancel under <a class=\"text\" href=\"{CANCEL}\">Cancel your plan</a>. Lifetime: 19.99 € once, VAT included. Tips unlock nothing. Payments go through Link (by Stripe), which is the seller: it handles payment, tax and the receipt. We never see your card. <a class=\"text\" href=\"/privacy.html\">Privacy</a> · <a class=\"text\" href=\"/terms/\">Terms</a>",
        "q_h": "Questions", "q_p": "Anything else?",
        "qs": [
            ("Is Swiftly still free?", "Yes. Everything you need to watch, download and keep in sync is free, with no ads. Extras change how Swiftly looks, never what it can do."),
            ("Where does the key go?", "After paying you get a supporter key on the thank-you page and by email. In Swiftly Player on Linux or Windows, open Settings, then Support Swiftly, choose &ldquo;I have a supporter key&rdquo; and paste it. A monthly key renews itself in the app while your plan runs."),
            ("Can I cancel?", "Yes, any time, under <a href=\"{CANCEL}\">Cancel your plan</a> or with the link in your confirmation email. Your order number or key is enough. A monthly plan then ends at the end of the period you paid for. Bought through the App Store or Google Play? Cancel there, in your Apple Account or Play subscriptions."),
            ("Can I get a refund?", "Write to <a href=\"mailto:info@swiftlyplayer.com\">info@swiftlyplayer.com</a> with your order number. In the apps, Apple and Google handle refunds."),
            ("What happens when my plan ends?", "The extras pause and Swiftly goes back to its own look. Your choices stay saved and come back when you support again."),
            ("Do I need an account?", "No. No account with us and no tracking. If you give a name for the credits, we use it for that and nothing else. Store purchases stay with Apple or Google, and we only see anonymous totals."),
        ],
        "we": "We make Swiftly in the open, with help from many.",
        "we_links": ("Report a bug", "Help translate", "Send a pull request"),
        "other_lang": ("Auf Deutsch", "de", DE_PATH),
        "js": {"cont": "Continue to payment", "month": " a month", "choose": "Choose an option",
               "min": "The smallest tip is 1.99 \\u20ac.", "max": "The largest tip is 500 \\u20ac.",
               "preview": "Preview only. On the real page this takes you to the payment page.", "comma": False},
    },
    "de": {
        "title": "Swiftly unterstützen - Swiftly Player",
        "desc": "Swiftly Player bleibt kostenlos. Unter Linux und Windows kannst du es hier unterstützen: 1,99 € im Monat, 19,99 € einmalig oder mit einem Trinkgeld.",
        "og_title": "Hilf Swiftly beim Wachsen",
        "og_text": "Deine Unterstützung hält Swiftly am Laufen. Open Source, keine Werbung, alles zum Schauen bleibt kostenlos.",
        "h1": "Hilf Swiftly beim <span class=\"nb\">Wachsen{S}</span>",
        "unter": "Deine Unterstützung hält Swiftly am Laufen.",
        "klein2": "Open Source, keine Werbung, alles zum Schauen bleibt kostenlos.",
        "b_support": "Swiftly unterstützen", "b_where": "Wo du kaufst",
        "phones": "Home in drei Looks: Sunset, Neon Night und Aurora", "phones_t": "Weiterschauen",
        "where_h": "Wo du kaufst",
        "in_app": "In der App",
        "in_app_p": "iPhone, iPad, Mac, Apple TV, Android und Android TV. Du unterstützt direkt in der App, über den App Store oder Google Play.",
        "here": "Hier auf dieser Seite",
        "here_p": "Linux und Windows. Du kaufst gleich hier und bekommst einen Schlüssel für diese beiden.",
        "get_h": "Das bekommst du", "get_p": "Schauen bleibt kostenlos. Unterstützer bekommen diese Extras.",
        "benefits": [
            ("8 Looks", "Ein Tipp ändert Akzent, Home-Licht und App-Icon. Probier vorher jeden aus."),
            ("Akzent und Home-Glow", "Du wählst die Farbe und stellst das Leuchten auf aus, sanft oder hell."),
            ("8 App-Icons", "Eins pro Look, gezeichnet wie jedes andere App-Icon."),
            ("Dein Name in den Credits", "Optional. Steht im Über-Bildschirm der App und in der Unterstützerliste auf GitHub, nur wenn du das Häkchen setzt. Auf Wunsch wieder weg."),
        ],
        "icons_h": "Die App-Icons", "icons_n": "Welche App-Icons gehen, bestimmt jedes System selbst.",
        "opt_h": "Unterstützen unter Linux und Windows", "opt_p": "Gleiche Preise wie in den Stores.",
        "legend": "Wie du unterstützen willst",
        "m_mark": "Beliebt", "m_name": "Monatlich", "m_price": "1,99 € <small>pro Monat</small>",
        "m_sub": "Verlängert sich jeden Monat, bis du kündigst. Jederzeit kündbar.",
        "l_mark": "Gutes Angebot", "l_name": "Lifetime", "l_price": "19,99 € <small>einmalig</small>",
        "l_sub": "Einmal zahlen, so lange es Swiftly Player gibt.",
        "tip_label": "Nur ein Dankeschön, schaltet nichts frei", "tip_group": "Nur ein Dankeschön",
        "tip": ["1,99 €", "4,99 €", "9,99 €"], "other": "Anderer", "own_aria": "Dein eigener Betrag in Euro",
        "name_l": "Name für die Credits", "name_o": "Optional", "name_ph": "So sollen wir ihn schreiben",
        "credit": "Diesen Namen in den Credits zeigen: im Über-Bildschirm der App und in der Unterstützerliste auf GitHub. Ohne Häkchen wird kein Name gezeigt. Mit einer Mail an <a href=\"mailto:info@swiftlyplayer.com\">info@swiftlyplayer.com</a> nehmen wir ihn jederzeit raus; mit dem nächsten App-Update und auf GitHub innerhalb einer Woche ist er weg.",
        "withdraw": "Schickt mir den Schlüssel sofort. Ich bin einverstanden, dass ihr vor Ablauf der 14-tägigen Widerrufsfrist beginnt, und weiß, dass mein Widerrufsrecht erlischt, sobald ich den Schlüssel habe.",
        "choose": "Wähle eine Option",
        "fine": "Monatlich: 1,99 € pro Monat inkl. USt, verlängert sich jeden Monat, bis du unter <a class=\"text\" href=\"{CANCEL}\">Cancel your plan</a> kündigst. Lifetime: 19,99 € einmalig inkl. USt. Trinkgelder schalten nichts frei. Die Zahlung läuft über Link (von Stripe). Link ist der Verkäufer und kümmert sich um Zahlung, Steuer und Beleg. Deine Karte sehen wir nie. <a class=\"text\" href=\"/datenschutz.html\">Datenschutz</a> · <a class=\"text\" href=\"/nutzungsbedingungen.html\">Nutzungsbedingungen</a>",
        "q_h": "Fragen", "q_p": "Noch was?",
        "qs": [
            ("Ist Swiftly weiter kostenlos?", "Ja. Alles zum Schauen, Herunterladen und Abgleichen ist kostenlos und ohne Werbung. Extras ändern, wie Swiftly aussieht, nie was es kann."),
            ("Wohin kommt der Schlüssel?", "Nach dem Bezahlen bekommst du einen Supporter-Schlüssel auf der Dankeseite und per Mail. In Swiftly Player unter Linux oder Windows öffnest du die Einstellungen, dann Support Swiftly, wählst &bdquo;I have a supporter key&ldquo; und fügst ihn ein. Ein Monatsschlüssel verlängert sich in der App von selbst, solange dein Tarif läuft."),
            ("Kann ich kündigen?", "Ja, jederzeit, unter <a href=\"{CANCEL}\">Cancel your plan</a> oder mit dem Link in deiner Bestätigungsmail. Bestellnummer oder Schlüssel reichen. Ein Monatstarif endet dann mit dem Zeitraum, den du bezahlt hast. Über App Store oder Google Play gekauft? Dann kündigst du dort, in deinem Apple-Account oder bei den Play-Abos."),
            ("Bekomme ich Geld zurück?", "Schreib an <a href=\"mailto:info@swiftlyplayer.com\">info@swiftlyplayer.com</a> mit deiner Bestellnummer. In den Apps erstatten Apple und Google."),
            ("Was passiert, wenn mein Tarif endet?", "Die Extras pausieren und Swiftly zeigt wieder sein eigenes Aussehen. Deine Auswahl bleibt gespeichert und ist wieder da, wenn du erneut unterstützt."),
            ("Brauche ich ein Konto?", "Nein. Kein Konto bei uns und kein Tracking. Wenn du einen Namen für die Credits angibst, nutzen wir ihn dafür und für sonst nichts. Käufe im Store bleiben bei Apple oder Google, wir sehen nur anonyme Summen."),
        ],
        "we": "Wir bauen Swiftly offen, mit Hilfe von vielen.",
        "we_links": ("Fehler melden", "Beim Übersetzen helfen", "Pull Request schicken"),
        "other_lang": ("In English", "en", SUPPORTER_PATH),
        "js": {"cont": "Weiter zur Zahlung", "month": " pro Monat", "choose": "Wähle eine Option",
               "min": "Das kleinste Trinkgeld ist 1,99 \\u20ac.", "max": "Das größte Trinkgeld ist 500 \\u20ac.",
               "preview": "Nur Vorschau. Auf der echten Seite geht es hier zur Zahlungsseite.", "comma": True},
    },
}

SCRIPT = """<script>
/* The checkout (pay.paulherter.de) takes interval month, lifetime or once.
   A tip sends amount in euros; it unlocks nothing and needs no key. Monthly
   and lifetime need withdrawal_consent=1. The checkout checks every limit
   itself, this only keeps the button honest. Nothing is preselected. */
(function () {
  var preview = __PREVIEW__, comma = __COMMA__;
  var el = function (id) { return document.getElementById(id); };
  var go = el("weiter"), own = el("eigenZahl"), note = el("meldung"), agree = el("widerruf"), agreeBox = el("widerrufZeile");
  var radios = document.querySelectorAll('input[name="plan"]');
  var pick = null;
  function eur(c) { return (c / 100).toFixed(2); }
  function shown(c) { var s = eur(c); return comma ? s.replace(".", ",") : s; }
  function show() {
    var paid = !!pick && pick.interval !== "once";
    var ok = !!pick && (paid || (pick.cents >= 199 && pick.cents <= 50000));
    el("intervall").value = pick ? pick.interval : "";
    el("betrag").value = pick && !paid ? eur(pick.cents) : "";
    el("betrag").disabled = !(pick && !paid);
    agreeBox.hidden = !paid; agree.disabled = !paid;
    go.disabled = !ok || (paid && !agree.checked);
    go.textContent = ok ? "__CONT__ \\u00b7 " + shown(pick.cents) + " \\u20ac" + (pick.interval === "month" ? "__MONTH__" : "") : "__CHOOSE__";
  }
  radios.forEach(function (r) {
    r.addEventListener("change", function () {
      own.value = ""; note.textContent = "";
      if (r.value === "month") pick = { interval: "month", cents: 199 };
      else if (r.value === "lifetime") pick = { interval: "lifetime", cents: 1999 };
      else pick = { interval: "once", cents: parseInt(r.value.split("-")[1], 10) };
      show();
    });
  });
  own.addEventListener("input", function () {
    var raw = own.value.replace(",", ".").replace(/[^0-9.]/g, ""); own.value = comma ? raw.replace(".", ",") : raw;
    radios.forEach(function (r) { r.checked = false; });
    var c = Math.round(parseFloat(raw) * 100);
    pick = raw && c ? { interval: "once", cents: c } : null;
    note.textContent = pick && c < 199 ? "__MIN__" : pick && c > 50000 ? "__MAX__" : "";
    show();
  });
  agree.addEventListener("change", show);
  el("kasse").addEventListener("submit", function (e) {
    if (go.disabled) { e.preventDefault(); return; }
    if (preview) { e.preventDefault(); note.textContent = "__PREVIEW_TEXT__"; }
  });
  show();
})();
</script>
"""


def script(lang):
    j = TXT[lang]["js"]
    return (SCRIPT.replace("__PREVIEW__", "true" if PREVIEW else "false")
            .replace("__COMMA__", "true" if j["comma"] else "false")
            .replace("__CONT__", j["cont"]).replace("__MONTH__", j["month"]).replace("__CHOOSE__", j["choose"])
            .replace("__MIN__", j["min"]).replace("__MAX__", j["max"]).replace("__PREVIEW_TEXT__", j["preview"]))


def localize(page, lang, path, other_path):
    """The shared header is English. For the German page: language, skip link, menu label,
    and for both pages the language alternates."""
    other = "de" if lang == "en" else "en"
    alt = (f'<link rel="alternate" hreflang="{lang}" href="https://swiftlyplayer.com{path}">\n'
           f'<link rel="alternate" hreflang="{other}" href="https://swiftlyplayer.com{other_path}">\n')
    page = page.replace("</head>", alt + "</head>", 1)
    if lang == "de":
        page = (page.replace('<html lang="en">', '<html lang="de">', 1)
                .replace('>Skip to content<', '>Zum Inhalt springen<', 1)
                .replace('aria-label="Swiftly Player, home"', 'aria-label="Swiftly Player, Startseite"', 1)
                .replace('aria-label="Menu"', 'aria-label="Menü"'))
    return page


def build(lang="en"):
    t = TXT[lang]
    path = SUPPORTER_PATH if lang == "en" else DE_PATH
    other_text, other_code, other_path = t["other_lang"]
    head = (f'<meta name="robots" content="noindex, follow">\n<style>\n{style("supporter.css")}</style>\n')
    badge = '\n<div class="vorschau">Preview, not connected</div>\n' if PREVIEW else ""
    icons_svg = ['<circle cx="9" cy="12" r="6"/><circle cx="15" cy="12" r="6"/>',
                 '<circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4L7 17M17 7l1.4-1.4"/>',
                 '<rect x="4" y="4" width="16" height="16" rx="4.5"/>',
                 '<path d="M12 20.5s-7.8-4.7-7.8-10.6A4.4 4.4 0 0 1 12 7.2a4.4 4.4 0 0 1 7.8 2.7c0 5.9-7.8 10.6-7.8 10.6z"/>']
    benefit_rows = "\n".join(f'<div class="vorteil"><span class="vorteil__zeichen">{svg(i)}</span><div><b>{a}</b><span class="t">{b}</span></div></div>'
                             for i, (a, b) in zip(icons_svg, t["benefits"]))
    icons = "".join(f'<figure><img src="{IMG}look-{n.lower().replace(" ", "-")}.svg" alt="" loading="lazy"><figcaption>{n}</figcaption></figure>'
                    for n in LOOKS)
    question_rows = "".join(f'<details class="frage"><summary>{q}{PLUS}</summary><p>{a.replace("{CANCEL}", CANCEL)}</p></details>' for q, a in t["qs"])
    tip_boxes = "".join(f'<div class="tipp"><input type="radio" form="nur-auswahl" name="plan" id="t{i+1}" value="tip-{v}"><label for="t{i+1}">{lab}</label></div>'
                        for i, (v, lab) in enumerate(zip((199, 499, 999), t["tip"])))
    bug, translate, pull = t["we_links"]
    page = header(t["title"], t["desc"], path, og_title=t["og_title"], og_text=t["og_text"], extra_ld=head) + f"""</div>{badge}
<div class="pg"><div class="licht" aria-hidden="true"></div>
<section class="held bahn" aria-labelledby="h-held">
<div><h1 id="h-held">{t["h1"].replace("{S}", SPROUT)}</h1>
<p class="unter">{t["unter"]}</p>
<p class="klein2">{t["klein2"]}</p>
<div class="held__wege"><a class="knopf" href="#options">{t["b_support"]}</a><a class="knopf knopf--leise" href="#how">{t["b_where"]}</a></div>
<p class="klein2"><a class="text" href="{other_path}" hreflang="{other_code}" lang="{other_code}">{other_text}</a></p></div>
{phones().replace("Home in three looks: Sunset, Neon Night and Aurora", t["phones"]).replace("Continue watching", t["phones_t"])}
</section>

<section class="bahn" id="how" aria-labelledby="h-how"><h2 class="leser" id="h-how">{t["where_h"]}</h2>
<div class="regel">
<div class="regel__karte"><span class="regel__zeichen">{svg('<rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M11 18h2"/>')}</span><div><strong>{t["in_app"]}</strong><p>{t["in_app_p"]}</p><p class="regel__links"><a class="text" href="{APP_STORE}" target="_blank" rel="noopener">App Store</a> · <a class="text" href="{PLAY}" target="_blank" rel="noopener">Google Play</a></p></div></div>
<div class="regel__karte regel__karte--hier"><span class="regel__zeichen">{svg('<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6M12 16v4"/>')}</span><div><strong>{t["here"]}</strong><p>{t["here_p"]}</p></div></div>
</div>
</section>

<section class="etage bahn" aria-labelledby="h-get"><div class="kopf kopf--kurz"><h2 id="h-get">{t["get_h"]}</h2><p>{t["get_p"]}</p></div>
<div class="vorteile">
<div class="liste">
{benefit_rows}
</div>
<div class="ikonen"><h3>{t["icons_h"]}</h3><div class="raster">{icons}</div><p class="fussnote">{t["icons_n"]}</p></div>
</div>
</section>

<section class="etage bahn" id="options" aria-labelledby="h-wahl"><div class="kopf"><h2 id="h-wahl">{t["opt_h"]}</h2><p>{t["opt_p"]}</p></div>
<form class="kasse" id="kasse" method="post" action="{CHECKOUT}" novalidate>
<input type="hidden" name="app" value="swiftly"><input type="hidden" name="interval" id="intervall" value=""><input type="hidden" name="amount" id="betrag" value="" disabled>
<fieldset class="wahl"><legend class="leser">{t["legend"]}</legend>
<label class="option" for="p-monat"><span class="option__marke option__marke--laut">{t["m_mark"]}</span><input type="radio" form="nur-auswahl" name="plan" id="p-monat" value="month"><span class="option__ring"></span><span class="option__name">{t["m_name"]}</span><span class="option__preis">{t["m_price"]}</span><span class="option__unter">{t["m_sub"]}</span></label>
<label class="option" for="p-immer"><span class="option__marke">{t["l_mark"]}</span><input type="radio" form="nur-auswahl" name="plan" id="p-immer" value="lifetime"><span class="option__ring"></span><span class="option__name">{t["l_name"]}</span><span class="option__preis">{t["l_price"]}</span><span class="option__unter">{t["l_sub"]}</span></label>
</fieldset>
<div class="danke" role="radiogroup" aria-label="{t["tip_group"]}"><span class="danke__text">{t["tip_label"]}</span>
{tip_boxes}<div class="tipp tipp--eigen"><input type="text" form="nur-auswahl" id="eigenZahl" inputmode="decimal" autocomplete="off" placeholder="{t["other"]}" aria-label="{t["own_aria"]}"></div></div>
<div class="name"><label for="creditName">{t["name_l"]}<small>{t["name_o"]}</small></label><input type="text" id="creditName" name="credit_name" maxlength="32" autocomplete="nickname" placeholder="{t["name_ph"]}"></div>
<label class="zustimmung" for="creditOk"><input type="checkbox" id="creditOk" name="credit_consent" value="1"><span>{t["credit"]}</span></label>
<label class="zustimmung" id="widerrufZeile" for="widerruf" hidden><input type="checkbox" id="widerruf" name="withdrawal_consent" value="1" disabled><span>{t["withdraw"]}</span></label>
<p class="kasse__meldung" id="meldung" role="status" aria-live="polite"></p>
<div class="kasse__weiter"><button class="knopf" id="weiter" type="submit" disabled>{t["choose"]}</button><p class="klein">{t["fine"].replace("{CANCEL}", CANCEL)}</p></div>
</form></section>

<section class="etage bahn" id="questions" aria-labelledby="h-fragen"><div class="fragen"><div class="fragen__kopf"><h2 id="h-fragen">{t["q_h"]}</h2><p>{t["q_p"]} <a class="text" href="mailto:info@swiftlyplayer.com">info@swiftlyplayer.com</a></p></div>
<div class="fragen__liste">{question_rows}</div>
<div class="fragen__wir"><p>{t["we"]}</p><div class="wir__links"><a href="{ISSUES}" target="_blank" rel="noopener">{bug}</a><a href="{DISCORD}" target="_blank" rel="noopener">{translate}</a><a href="{GITHUB}" target="_blank" rel="noopener">{pull}</a></div></div>
</div></section>
</div>
{script(lang)}<div>""" + footer(path)
    write(path, localize(page, lang, path, other_path))


THANKS = {
    "en": {
        "title": "Thank you - Swiftly Player",
        "desc": "Thank you for supporting Swiftly. Here is your invitation to the Swiftly beta.",
        "h1": "Thank you", "p1": "Thanks for supporting Swiftly. Here comes your beta invitation.",
        "p2": "The beta is a thank-you, not an extra: everything in Swiftly stays free for everyone, with or without it.",
        "btn": "Join the beta", "wait": "Your invitation link will appear here.",
        "note": "Keep the link for yourself. Questions? <a class=\"text\" href=\"mailto:info@swiftlyplayer.com\">info@swiftlyplayer.com</a>",
        "back": "Back to Swiftly Player", "other": ("Auf Deutsch", "de", THANKS_DE_PATH),
    },
    "de": {
        "title": "Danke - Swiftly Player",
        "desc": "Danke, dass du Swiftly unterstützt. Hier ist deine Einladung zur Swiftly-Beta.",
        "h1": "Danke", "p1": "Danke, dass du Swiftly unterstützt. Hier kommt deine Beta-Einladung.",
        "p2": "Die Beta ist ein Dankeschön, kein Extra: Alles in Swiftly bleibt für alle kostenlos, mit oder ohne sie.",
        "btn": "Zur Beta", "wait": "Hier erscheint dein Einladungslink.",
        "note": "Gib den Link nicht weiter. Fragen? <a class=\"text\" href=\"mailto:info@swiftlyplayer.com\">info@swiftlyplayer.com</a>",
        "back": "Zurück zu Swiftly Player", "other": ("In English", "en", THANKS_PATH),
    },
}


def build_thanks(lang="en"):
    t = THANKS[lang]
    path = THANKS_PATH if lang == "en" else THANKS_DE_PATH
    other_text, other_code, other_path = t["other"]
    head = '<meta name="robots" content="noindex, nofollow">\n<meta name="referrer" content="no-referrer">\n' \
           f'<style>\n{style("supporter.css")}</style>\n'
    if BETA_INVITE_URL:
        invite = f'<div class="held__wege"><a class="knopf" href="{BETA_INVITE_URL}" rel="noopener">{t["btn"]}</a></div>'
    else:
        invite = f'<!-- BETA-PLATZHALTER --><p class="klein2">{t["wait"]}</p>'
    page = header(t["title"], t["desc"], path, extra_ld=head) + f"""</div>
<div class="pg"><div class="licht" aria-hidden="true"></div>
<section class="bahn etage" aria-labelledby="h-danke"><div class="kopf">
<h1 id="h-danke">{t["h1"]} <span class="nb">{SPROUT}</span></h1>
<p class="unter">{t["p1"]}</p>
<p class="klein2">{t["p2"]}</p>
{invite}
<p class="klein2">{t["note"]}</p>
<p class="klein2"><a class="text" href="/">{t["back"]}</a> · <a class="text" href="{other_path}" hreflang="{other_code}" lang="{other_code}">{other_text}</a></p>
</div></section>
</div>
<div>""" + footer(path)
    write(path, localize(page, lang, path, other_path))


def build_all():
    build("en"); build("de"); build_thanks("en"); build_thanks("de")


# ------------------------------------------------------------------ Hand-written pages

LINE = "<!-- supporter -->"
HIDDEN = "<!-- supporter:hidden"
START, END = "<!-- supporter:start -->", "<!-- supporter:end -->"
CSS_START, CSS_END = "/* supporter:start */", "/* supporter:end */"

# The band and its styles are built on demand: the CSS file is read in maintain().
def band_css():
    extra = """/* Donate next to Download, styled like the second button it replaces. */
.knopf--spenden { gap: 8px; }
.knopf--spenden svg { width: 18px; height: 18px; flex: none; fill: none; stroke: var(--akzent); stroke-width: 2; stroke-linejoin: round; }
"""
    return f"{CSS_START}\n{style('supporter-home.css')}{extra}{CSS_END}\n"


BAND = f"""{START}
<div class="pg startseite"><section class="etage bahn" aria-labelledby="h-start"><div class="startteil"><div class="startteil__licht" aria-hidden="true"></div>
<div class="startteil__text"><h2 id="h-start">Help Swiftly <span class="nb">grow{SPROUT}</span></h2><p>Your support keeps Swiftly going. Open source, no ads, everything for watching stays free.</p>
<ul class="startteil__punkte"><li>8 looks and app icons</li><li>Your own accent and Home glow</li><li>Your name in the credits</li></ul>
<div class="held__wege"><a class="knopf" href="{SUPPORTER_PATH}#options">Support Swiftly</a><a class="knopf knopf--leise" href="{SUPPORTER_PATH}">Learn more</a></div>
<p class="startteil__regel">Linux and Windows here on the website. iPhone, iPad, Mac, Apple TV and Android inside the app, through the App Store and Google Play.</p></div>
{phones()}</div></section></div>
{END}
"""

PRIVACY_EN = f"""{START}

<h2>Payments on the supporter page</h2>
<p>If you support Swiftly on the <a href="{SUPPORTER_PATH}">supporter page</a>, with a
monthly plan, a lifetime purchase or a tip, you pay through Link, a service by Stripe. For this purchase Link is the seller: it
processes the payment, handles tax and sends the receipt. Your card or bank
details go to Link and Stripe, not to me, and their privacy notices apply there.
Stripe may process data outside the EU; that is covered by the safeguards in
their notices.</p>
<p>The payment page itself, pay.paulherter.de, is run by me. When you start a
payment it receives the amount and interval you chose, and like any web server it
logs the request (IP address, time, browser identification). From the purchase I
receive only the order: the plan, the amount, the time, your email address for
the supporter key and, if you enter it, the name for the credits. The key is sent by email from
noreply@paulherter.de. The legal basis is Article 6(1)(b) GDPR, carrying out what
you asked for, and for the name in the credits your consent under Article 6(1)(a),
which you can withdraw. Order records are kept as long as tax law requires.
Nothing on the supporter page is tracked, and it sets no cookies.</p>

<h2>Purchases in the apps</h2>
<p>Where an app offers a tip or supporter purchase through the App Store or
Google Play, Apple or Google is the seller. You pay them under their terms and
privacy notices. I receive no data about buyers from the stores, only anonymous
sales totals.</p>

<h2>Supporter keys in the apps</h2>
<p>A supporter key you enter in Swiftly Player on Linux or Windows is checked on
the device. A lifetime key never leaves it. In the days before a monthly
key runs out, the app asks pay.paulherter.de, at most twice a day, whether the
plan still runs and fetches the
renewed key; it sends only the random licence number from the key, nothing else
about you or your device. Like any web server, the payment page logs that
request (IP address, time). Legal basis is Article 6(1)(b) GDPR.</p>

{END}
"""

PRIVACY_DE = f"""{START}

<h2>Zahlungen auf der Supporter-Seite</h2>
<p>Wenn Sie Swiftly auf der <a href="{SUPPORTER_PATH}">Supporter-Seite</a> unterstützen,
monatlich, einmalig für immer oder mit einem Trinkgeld, bezahlen Sie über Link, einen Dienst von Stripe. Für diesen Kauf ist
Link der Verkäufer: Link wickelt die Zahlung ab, kümmert sich um die Steuer und
verschickt den Beleg. Ihre Karten- oder Kontodaten gehen an Link und Stripe,
nicht an mich; dort gelten deren Datenschutzhinweise. Stripe kann Daten auch
außerhalb der EU verarbeiten; dafür gelten die Garantien in deren Hinweisen.</p>
<p>Die Zahlungsseite pay.paulherter.de betreibe ich selbst. Wenn Sie eine Zahlung
starten, erhält sie den gewählten Betrag und Rhythmus und hält, wie jeder
Webserver, die Anfrage fest (IP-Adresse, Zeitpunkt, Browserkennung). Aus dem Kauf
erhalte ich nur die Bestellung: Tarif, Betrag, Zeitpunkt, Ihre E-Mail-Adresse
für den Supporter-Schlüssel und, falls Sie ihn angeben, den Namen für die Credits.
Der Schlüssel
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
keine Daten über Käufer, nur anonyme Verkaufszahlen.</p>

<h2>Supporter-Schlüssel in den Apps</h2>
<p>Einen Supporter-Schlüssel, den Sie in Swiftly Player unter Linux oder Windows
eingeben, prüft die App auf dem Gerät. Ein Schlüssel für immer verlässt es nie.
In den Tagen, bevor ein Monatsschlüssel abläuft, fragt die App höchstens zweimal
am Tag bei pay.paulherter.de, ob der Tarif noch läuft, und holt den verlängerten Schlüssel; sie schickt dabei
nur die zufällige Lizenznummer aus dem Schlüssel, sonst nichts über Sie oder Ihr
Gerät. Wie jeder Webserver hält die Zahlungsseite diese Anfrage fest
(IP-Adresse, Zeitpunkt). Rechtsgrundlage ist Artikel 6 Absatz 1 Buchstabe b
DSGVO.</p>

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
    return insert(s, "</style>", band_css(), before=True)


def small_footer(word):
    def change(s):
        return insert(s, "</div></footer>", f'{START} · <a href="{SUPPORTER_PATH}">{word}</a>{END}', before=True)
    return change


def privacy(anchor, text, word):
    def change(s):
        return small_footer(word)(insert(s, anchor, text, before=True))
    return change


if SUPPORTER_ON:
    build_all()
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
