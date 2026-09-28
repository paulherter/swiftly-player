#!/usr/bin/env python3
"""Prueft Blog-Quellen vor dem Bauen: Wortverbote (swiftly-wording), Ausrufe-
zeichen, Emojis, tote interne Links, Kopf, Titel-/Beschreibungslaenge, FAQ.

  blog-pruefen.py                 alle Quellen
  blog-pruefen.py slug [slug ...] nur diese

Exit 1, wenn ein Fehler gefunden wurde. Warnungen brechen nicht ab.
"""
import os, re, sys

HIER = os.path.dirname(os.path.abspath(__file__))
WEBSITE = os.path.normpath(os.path.join(HIER, "..", "Website"))
QUELLEN = os.path.join(WEBSITE, "blog", "quellen")
SEITEN = os.path.join(WEBSITE, "seiten", "quellen")

VERBOTEN = [r"seamless\w*", r"effortless\w*", r"blazing[- ]fast", r"powerful", r"beautiful\w*", r"elegant\w*",
            r"intuitive\w*", r"revolutionary", r"game[- ]chang\w*", r"unleash\w*", r"dive in", r"journey",
            r"ultimate", r"and (so )?much more", r"viewing experience", r"user experience", r"the experience",
            r"an experience", r"your experience", r"not just [^.]{1,40}, it'?s"]
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")


def slugs():
    return {f[:-3] for f in os.listdir(QUELLEN) if f.endswith(".md")}


def pfade():
    p = {"/", "/blog/", "/android/", "/support.html", "/privacy.html", "/impressum.html", "/datenschutz.html"}
    for wurzel, _, namen in os.walk(WEBSITE):
        if "index.html" in namen:
            p.add("/" + os.path.relpath(wurzel, WEBSITE).replace(os.sep, "/").strip(".") + "/")
    for f in os.listdir(SEITEN):
        if f.endswith(".md"):
            m = re.search(r"(?m)^pfad:\s*(\S+)", open(os.path.join(SEITEN, f), encoding="utf-8").read())
            if m:
                p.add(m.group(1))
    return {x.replace("//", "/") for x in p}


def pruefen(slug, alle, bekannt):
    fehler, warn = [], []
    s = open(os.path.join(QUELLEN, slug + ".md"), encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n(.*)", s, re.S)
    if not m:
        return ["kein Kopf"], []
    kopf, text = m.group(1), m.group(2)
    felder = dict(re.findall(r"(?m)^(\w+):\s*(.*)$", kopf))
    for f in ("titel", "beschreibung", "datum", "slug", "schlagworte", "offenlegung"):
        if f not in felder:
            fehler.append("Kopf ohne " + f)
    titel = felder.get("titel", "").strip("\"'")
    beschr = felder.get("beschreibung", "").strip("\"'")
    if felder.get("slug") != slug:
        fehler.append("slug passt nicht zum Dateinamen")
    if len(beschr) > 155:
        fehler.append("Beschreibung %d > 155 Zeichen" % len(beschr))
    if len(titel) > 70:
        warn.append("Titel %d Zeichen (Google kuerzt ab ~60-65)" % len(titel))
    ohne_code = re.sub(r"```.*?```", "", text, flags=re.S)
    ohne_code = re.sub(r"`[^`]*`", "", ohne_code)
    prosa = re.sub(r"\]\([^)]*\)", "]", ohne_code)
    for w in VERBOTEN:
        for t in re.findall(r"(?i)\b" + w + r"\b", titel + "\n" + beschr + "\n" + prosa):
            fehler.append("Verbotswort: " + t)
    if "!" in re.sub(r"!\[", "[", prosa):
        fehler.append("Ausrufezeichen: %d" % re.sub(r"!\[", "[", prosa).count("!"))
    if EMOJI.search(prosa):
        fehler.append("Emoji")
    if "<" in re.sub(r"<(https?://[^>]+)>", "", prosa) and re.search(r"</?[a-z][a-z0-9]*[ >]", prosa):
        warn.append("sieht nach rohem HTML aus")
    for ziel in re.findall(r"\]\((/[^)\s#]*)", text):
        z = ziel if ziel.endswith("/") or "." in ziel.rsplit("/", 1)[-1] else ziel + "/"
        b = re.match(r"^/blog/([a-z0-9-]+)/$", z)
        if b:
            if b.group(1) not in alle:
                fehler.append("toter Link " + ziel)
        elif z not in bekannt and not os.path.exists(os.path.join(WEBSITE, z.lstrip("/"))):
            fehler.append("toter Link " + ziel)
    if "## FAQ" not in text:
        warn.append("keine FAQ")
    worte = len(re.sub(r"[#*`|\-\[\]()>]", " ", ohne_code).split())
    if worte < 1200:
        warn.append("nur %d Woerter" % worte)
    return fehler, warn


def main():
    alle = slugs()
    bekannt = pfade()
    ziel = sys.argv[1:] or sorted(alle)
    schlecht = 0
    for slug in ziel:
        f, w = pruefen(slug, alle, bekannt)
        if f or w:
            print(slug)
            for x in f:
                print("  FEHLER  " + x)
            for x in w:
                print("  Hinweis " + x)
        schlecht += bool(f)
    print("%d Quellen geprueft, %d mit Fehlern." % (len(ziel), schlecht))
    sys.exit(1 if schlecht else 0)


if __name__ == "__main__":
    main()
