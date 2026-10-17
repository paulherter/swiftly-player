#!/usr/bin/env python3
"""Is every label from the source in the catalog -- and in English?

**Why this exists.** A user reported that the sign-in of a second account
showed German. The cause was 54 strings that had never been exported to the
catalog. This never shows up by itself: the app runs, looks right in German,
and the build is green -- because whatever is not in the catalog falls back to
the key, and here the key *is* the German wording.
"""
import json, pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / "Sources/Shared/Localizable.xcstrings").read_text())["strings"]

# The places where a label appears as a literal word in the code.
# **Extended twice, each time because strings would otherwise slip through.**
#
# The first pattern only knew `Text(` and the named arguments. It still missed
# about 50 labels that were never in the catalog -- they sit in `Button(`, in
# `String(localized:)` or as the value of a `switch`. English users saw German
# there: download states, part of the Seerr branding and the info cards in the
# player.
muster = re.compile(r'(?<![A-Za-z])(?:Text\(|Button\(|Toggle\(|Label\(|Menu\(|Section\(|'
                    r'String\(localized:\s*|navigationTitle\(|\.help\(|'
                    r'confirmationDialog\(|accessibilityLabel\(|accessibilityValue\(|'
                    r'accessibilityHint\(|'
                    r'titel:\s*|unter:\s*|beschriftung:\s*|platzhalter:\s*|'
                    r'kopfzeile:\s*|hinweis:\s*|text:\s*|wort:\s*|ansage:\s*|'
                    r'title:\s*|under:\s*|(?<!DispatchQueue\()label:\s*|placeholder:\s*|'
                    r'headerRow:\s*|hint:\s*|word:\s*|announcement:\s*)"([^"\\]{3,})"')

# **And the cases of a `switch`, but only inside a `LocalizedStringKey`.**
#
# The pattern above could never find them: it looks for a keyword before the
# quotation mark, and `case .foo:` has none. That is how `Startreihe.name`
# ("Neue Filme", "Neue Serien", "Neu hinzugefuegt") went unnoticed.
#
# Limited to blocks that explicitly return `LocalizedStringKey`: next to them
# there is regularly a second `switch` with the same cases that returns
# **SF Symbol names**. Those must not be translated, and without the
# restriction they would all be listed here.
block = re.compile(r':\s*LocalizedStringKey\s*\{(.*?)\n(\s*)\}', re.S)
branch = re.compile(r'\b(?:Text|Button|Label)\(\s*[^"()\n]*\?\s*"([^"\\]{3,})"\s*:\s*"([^"\\]{3,})"')
fall = re.compile(r'case\s+\.[A-Za-z][A-Za-zÄÖÜäöü]*:\s*"([^"\\]{3,})"')

missing, raw = set(), set()

# **Including files that are not committed yet.** `git ls-files` only knows
# tracked files -- a view that was just written is invisible to the check,
# and that is exactly when its strings are most likely not in the catalog yet.
# Several new views once passed with "ok" while their labels showed German on
# an English simulator.
#
# `--others --exclude-standard` adds what is untracked and not ignored; the
# build directory stays out.
files = subprocess.run(["git", "ls-files", "--cached", "--others",
                          "--exclude-standard", "Sources"], cwd=root,
                         capture_output=True, text=True).stdout.split()
for distance in files:
    if not distance.endswith(".swift"):
        continue
    source = (root / distance).read_text()
    hit_list = muster.findall(source)
    for body, _ in block.findall(source):
        hit_list += fall.findall(body)
    # **Both branches of a choice inside the call.** `Text(empty ? "A" : "B")`
    # is localized like `Text("A")`, but the quotation mark is preceded by
    # `?` or `:` and no keyword. Such labels were missing from the catalog.
    for yes, no in branch.findall(source):
        hit_list += [yes, no]
    for hit in hit_list:
        if not re.search(r"[a-zäöüßA-ZÄÖÜ]", hit):
            continue
        entry = catalog.get(hit)
        if entry is None:
            missing.add((distance, hit))
            continue
        english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
        if english.get("state") != "translated":
            raw.add((distance, hit))

# **Labels with an interpolated value.**
#
# `String(localized: "Geboren \(datum)")` becomes the key `Geboren %@` --
# and the pattern above cannot find it, because it looks for literals without
# a backslash. An English device therefore showed "Geboren October 22, 1986"
# on the person page.
#
# Which placeholder Foundation inserts depends on the type: `%@` for text and
# date, `%lld` for an integer. The type is not known here, so both forms are
# built and **one** of them must be in the catalog.
eingesetzt = re.compile(r'String\(localized:\s*"((?:[^"\\]|\\\()+)"')
loch = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')  # one level of parentheses inside the interpolation
for distance in files:
    if not distance.endswith(".swift"):
        continue
    for text in eingesetzt.findall((root / distance).read_text()):
        if "\\(" not in text:
            continue
        shape = {loch.sub(sentence, text) for sentence in ("%@", "%lld")}
        # **A quotation mark inside the interpolation itself** -- e.g.
        # `\\(name ?? "-")` -- ends the literal too early for this pattern
        # and the built form would be nonsense. There are three such places;
        # their keys are in the catalog. Better to skip than to report wrongly:
        # a check that complains about known lines does not get read.
        if any("\\(" in f for f in shape):
            continue
        if not (shape & set(catalog)):
            missing.add((distance, sorted(shape)[0]))

# **The check only finds what it knows -- the catalog itself knows more.**
#
# A user once reported "12 offen" on an English device. Its key is
# `%lld offen`, produced by `String(localized: "\(n) offen")` -- a literal
# with an interpolated value, which no pattern searching for `"..."` without a
# backslash can reach.
#
# The cross-check is simpler than any pattern: **every entry in the catalog
# needs an English version.** How the key came about no longer matters. Xcode
# adds new keys itself when building; from then on this notices that the
# translation is missing.
for key, entry in catalog.items():
    if not entry.get("shouldTranslate", True):
        continue
    en = entry.get("localizations", {}).get("en")
    if en is None:
        raw.add(("Katalog", key))
        continue
    if "variations" in en:
        for form in en["variations"].get("plural", {}).values():
            if form.get("stringUnit", {}).get("state") != "translated":
                raw.add(("Katalog", key))
    elif en.get("stringUnit", {}).get("state") != "translated":
        raw.add(("Katalog", key))

for name, amount in (("nicht im Katalog", missing), ("ohne englische Fassung", raw)):
    for distance, text in sorted(amount):
        print(f"  {name}: {distance.split('/')[-1]} · {text[:64]}")

count = len(missing) + len(raw)
print(f"Katalog{'':26}{'ok' if count == 0 else f'{count} offen'}")
sys.exit(1 if count else 0)
