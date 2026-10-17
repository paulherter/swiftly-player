#!/usr/bin/env python3
"""Checks blog sources before building: banned words, exclamation marks,
emoji, dead internal links, front matter, title/description length, FAQ.

  blog-check.py                 all sources
  blog-check.py slug [slug ...] only these

Exits 1 if any error was found. Warnings do not fail the run.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
WEBSITE = os.path.normpath(os.path.join(HERE, "..", "Website"))
SOURCES = os.path.join(WEBSITE, "blog", "quellen")
PAGES = os.path.join(WEBSITE, "seiten", "quellen")

FORBIDDEN = [r"seamless\w*", r"effortless\w*", r"blazing[- ]fast", r"powerful", r"beautiful\w*", r"elegant\w*",
            r"intuitive\w*", r"revolutionary", r"game[- ]chang\w*", r"unleash\w*", r"dive in", r"journey",
            r"ultimate", r"and (so )?much more", r"viewing experience", r"user experience", r"the experience",
            r"an experience", r"your experience", r"not just [^.]{1,40}, it'?s"]
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")


def slugs():
    return {f[:-3] for f in os.listdir(SOURCES) if f.endswith(".md")}


def paths():
    p = {"/", "/blog/", "/android/", "/support.html", "/privacy.html", "/impressum.html", "/datenschutz.html"}
    for root, _, names in os.walk(WEBSITE):
        if "index.html" in names:
            p.add("/" + os.path.relpath(root, WEBSITE).replace(os.sep, "/").strip(".") + "/")
    for f in os.listdir(PAGES):
        if f.endswith(".md"):
            m = re.search(r"(?m)^pfad:\s*(\S+)", open(os.path.join(PAGES, f), encoding="utf-8").read())
            if m:
                p.add(m.group(1))
    return {x.replace("//", "/") for x in p}


def check(slug, all, known):
    error, warn = [], []
    s = open(os.path.join(SOURCES, slug + ".md"), encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n(.*)", s, re.S)
    if not m:
        return ["kein Kopf"], []
    header, text = m.group(1), m.group(2)
    fields = dict(re.findall(r"(?m)^(\w+):\s*(.*)$", header))
    for f in ("titel", "beschreibung", "datum", "slug", "schlagworte", "offenlegung"):
        if f not in fields:
            error.append("Kopf ohne " + f)
    title = fields.get("titel", "").strip("\"'")
    beschr = fields.get("beschreibung", "").strip("\"'")
    if fields.get("slug") != slug:
        error.append("slug passt nicht zum Dateinamen")
    if len(beschr) > 155:
        error.append("Beschreibung %d > 155 Zeichen" % len(beschr))
    if len(title) > 70:
        warn.append("Titel %d Zeichen (Google kuerzt ab ~60-65)" % len(title))
    without_code = re.sub(r"```.*?```", "", text, flags=re.S)
    without_code = re.sub(r"`[^`]*`", "", without_code)
    prosa = re.sub(r"\]\([^)]*\)", "]", without_code)
    for w in FORBIDDEN:
        for t in re.findall(r"(?i)\b" + w + r"\b", title + "\n" + beschr + "\n" + prosa):
            error.append("Verbotswort: " + t)
    if "!" in re.sub(r"!\[", "[", prosa):
        error.append("Ausrufezeichen: %d" % re.sub(r"!\[", "[", prosa).count("!"))
    if EMOJI.search(prosa):
        error.append("Emoji")
    if "<" in re.sub(r"<(https?://[^>]+)>", "", prosa) and re.search(r"</?[a-z][a-z0-9]*[ >]", prosa):
        warn.append("sieht nach rohem HTML aus")
    for target in re.findall(r"\]\((/[^)\s#]*)", text):
        z = target if target.endswith("/") or "." in target.rsplit("/", 1)[-1] else target + "/"
        b = re.match(r"^/blog/([a-z0-9-]+)/$", z)
        if b:
            if b.group(1) not in all:
                error.append("toter Link " + target)
        elif z not in known and not os.path.exists(os.path.join(WEBSITE, z.lstrip("/"))):
            error.append("toter Link " + target)
    if "## FAQ" not in text:
        warn.append("keine FAQ")
    phrases = len(re.sub(r"[#*`|\-\[\]()>]", " ", without_code).split())
    if phrases < 1200:
        warn.append("nur %d Woerter" % phrases)
    return error, warn


def main():
    all = slugs()
    known = paths()
    target = sys.argv[1:] or sorted(all)
    bad = 0
    for slug in target:
        f, w = check(slug, all, known)
        if f or w:
            print(slug)
            for x in f:
                print("  FEHLER  " + x)
            for x in w:
                print("  Hinweis " + x)
        bad += bool(f)
    print("%d Quellen geprueft, %d mit Fehlern." % (len(target), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
