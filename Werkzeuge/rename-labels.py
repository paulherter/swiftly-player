#!/usr/bin/env python3
"""Finds and renames the German identifiers that `rename.py` does not cover.

`rename.py` works from a list of declared names. What it cannot see are
argument labels, parameter names, locals, Kotlin enum entries and compound names
nobody listed. This tool works on the tokens themselves:

  rename-labels.py measure  --names NAMEN.tsv [--extra zusatz.tsv] [--force words.txt]
      Counts the identifier tokens that contain a German word (code only, never
      comments or strings). Prints the total and the count per area.

  rename-labels.py compose  --names NAMEN.tsv --glossary glossar.txt
                                [--tokens tokens.txt] --out mapping.tsv
      Builds `alt<TAB>neu` for every German token from a word glossary
      (`wort<TAB>english words`) and optional whole-token overrides.

  rename-labels.py apply    --mapping mapping.tsv [--areas Kit,Apple,...] [--write]
      Replaces the tokens in Swift, Kotlin and C sources (dry run without --write).

Rules that make the replacement safe:
  * Only code tokens change. Strings, raw strings and comments are untouched,
    except identifiers inside backticks in comments (they point at code).
  * Codable properties and String enum cases keep their wire names: the
    protection plan of `rename.py` inserts `CodingKeys` / `= "alt"` first.
  * `aus` is `off` for enum cases and `from` everywhere else; `fuer` is the label
    `for` and otherwise `of`, because `for` cannot be a parameter name in Swift.
  * A name `_x` always follows the name `x` (property wrapper storage).
"""
import argparse
import collections
import csv
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tokenize

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

_spec = importlib.util.spec_from_file_location("renamer", os.path.join(HERE, "rename.py"))
renamer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(renamer)

CODE_EXT = {".swift": "swift", ".kt": "kotlin", ".h": "kotlin", ".c": "kotlin"}
TOP_DIRS = ("Packages/", "Sources/", "Android/", "Linux/", "Windows/", "Werkzeuge/")

# Words that are English although a German list could contain them.
ENGLISH_WORDS = set("""widget widgets items decoder encoder json inline async struct enum boolean px app swiftly
localized composable androidx kotlinx coroutines nonisolated escaping dispatchers semibold lowercased appending
allows bounds enumerated indicators website networking tracking traits blog monospaced exists typed prepares
stretches crossfade repeating hashable choices restoring multiline checkbox toolbar situations retained stats
constraints properties kotlin clickable plays edits attributes named compat linux gestures uuid defaults
attempts newlines chars popup shifted replacing libs realtime formatter pictures inout dirname mutating
shortcut coordinator takeable passphrase nanoseconds pointee editable occurrences resolving provides
obstacles substring uppercased typealias grep argv starts insets popdown google beats animations modifiers
filters stops needed hunts returning payload mkdir lowercase github darwin minmax generated foreach
samsung bitmap htaccess sudo hdr vlc dts tmdb jellyfin seerr trakt discord quickconnect syncplay airplay
mkv hevc rlottie lottie gtk gdk glib wlan wifi tvos ios macos ipados android windows sdk apk ndk jni gradle
xcode swiftui uikit appkit held username demuxer taglines""".split())

ARTICLES = ("von zu zum zur mit auf fuer ueber bei nach aus und oder der die das den dem des ein eine einen einer "
            "nicht kein keine noch schon nur auch wie wenn dann sonst alle alles jede jeder diese dieser ohne "
            "unter vor hinter neben zwischen durch gegen im ans ins beim vom wird ist hat sind war waren sein "
            "haben wurde").split()
SHORT_AMBIGUOUS = {"a", "i", "x", "y", "id", "ui", "url", "tv", "vlc", "ok", "db", "io", "ip", "um", "an", "in",
                   "as", "so", "do", "on", "or", "at", "is"}
SUFFIXES = ("ung", "keit", "heit", "schaft", "lich", "chen", "lein")
UMLAUT_FALSE = re.compile(r"(aes|oes|uel|ueu|que|ued|uet|ues|uer|ouet|aer|oer|ael|oel|uen|uef|uea|ueb|uec|ueg|uem|uep|uex|ouel|aeo|eue|uev|aet)")

HARD_KEYWORDS = set("""associatedtype class deinit enum extension fileprivate func import init inout internal let operator
private protocol public rethrows static struct subscript typealias var break case catch continue default defer do else
fallthrough for guard if in repeat return throw switch where while as false is nil self super throws true try interface
fun val null object package this typeof when""".split())
PYTHON_KEYWORDS = set("False None True and as assert async await break class continue def del elif else except finally "
                      "for from global if import in is lambda nonlocal not or pass raise return try while with yield".split())
KEYWORD_FALLBACK = {"switch": "change", "self": "itself", "class": "kind", "when": "moment", "in": "inside",
                    "is": "equals", "as": "asValue", "else": "otherwise", "for": "of", "do": "run", "if": "condition",
                    "while": "during", "return": "result", "object": "item", "default": "fallback", "where": "place",
                    "try": "attempt", "true": "yes", "false": "no", "from": "fromValue"}


def split_words(identifier):
    """camelCase / snake_case / digits -> lower-case words."""
    words = []
    for part in re.split(r"[_\d]+", identifier):
        words += re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[A-Z]+", part)
    return [w.lower() for w in words if w]


def read_lines(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.strip() and not line.startswith("#"):
                yield line.rstrip("\n").split("\t")


class Lexicon:
    """Decides whether a word is German. Built from the old-name column of the name list."""

    def __init__(self, names_tsv, extra_tsv=None, force_file=None):
        english = set()
        for path in ("/usr/share/dict/words", "/usr/share/dict/web2"):
            if os.path.exists(path):
                english |= {w.strip().lower() for w in open(path, errors="ignore")}
        self.english = english
        new_words, kept, german = set(), set(), collections.Counter()
        with open(names_tsv, encoding="utf-8") as handle:
            for row in csv.DictReader(handle, delimiter="\t"):
                if row["art"] == "Datei":
                    continue
                old = split_words(row["alt"])
                new = split_words(row["neu"].replace("?", ""))
                new_words.update(new)
                if row["klasse"] == "en":
                    kept.update(old)
                elif len(old) == len(new):
                    for x, y in zip(old, new):
                        (kept.add(x) if x == y else german.update([x]))
                elif row["klasse"] == "de":
                    german.update(x for x in old if x not in new)
        if extra_tsv:
            for cells in read_lines(extra_tsv):
                if len(cells) >= 2 and cells[1] != "-":
                    old, new = split_words(cells[0]), split_words(cells[1])
                    new_words.update(new)
                    if len(old) == len(new):
                        for x, y in zip(old, new):
                            (kept.add(x) if x == y else german.update([x]))
        self.new_words = new_words
        forced = set()
        if force_file:
            forced = {line[0] for line in read_lines(force_file)}
        words = set()
        for w in german:
            if len(w) < 2 or w in kept or w in ENGLISH_WORDS:
                continue
            if w in english and (len(w) <= 4 or w in new_words):
                continue
            words.add(w)
        words |= set(ARTICLES) | forced
        words -= SHORT_AMBIGUOUS | ENGLISH_WORDS
        self.words = words

    def is_german(self, word):
        if word in self.words:
            return True
        if word in ENGLISH_WORDS or word in self.new_words or word in self.english:
            return False
        if len(word) >= 5 and word.endswith(SUFFIXES):
            return True
        return bool(re.search(r"(ae|oe|ue)", word) and not UMLAUT_FALSE.search(word))


def tracked_files(root):
    out = subprocess.check_output(["git", "ls-files"], cwd=root, text=True).splitlines()
    for rel in out:
        if rel.startswith(TOP_DIRS) and "/Vendor/" not in rel and not rel.startswith("Android/build"):
            yield rel, os.path.splitext(rel)[1].lstrip(".")


def area_of(rel):
    top = rel.split("/")[0]
    return {"Packages": "Kit", "Sources": "Apple"}.get(top, top)


def tokens_of(root, rel, ext):
    """Identifier tokens that are code (no comments, no strings)."""
    with open(os.path.join(root, rel), errors="ignore") as handle:
        text = handle.read()
    if ext in ("swift", "h", "c"):
        mask = renamer.lex(text, "swift").mask
    elif ext in ("kt", "kts", "java"):
        mask = renamer.lex(text, "kotlin").mask
    elif ext == "py":
        found = []
        try:
            for tok in tokenize.generate_tokens(io.StringIO(text).readline):
                if tok.type == tokenize.NAME:
                    found.append(tok.string)
        except (tokenize.TokenError, IndentationError):
            pass
        return found
    else:
        stripped = re.sub(r"(?m)^\s*#.*", "", text)
        stripped = re.sub(r"'[^']*'", "", stripped)
        return (re.findall(r"(?<![\w$])([A-Za-z_]\w*)=", stripped)
                + re.findall(r"\$\{?[#!]?([A-Za-z_]\w*)", stripped)
                + re.findall(r"(?m)^\s*(?:function\s+)?([A-Za-z_]\w*)\s*\(\)", stripped))
    return re.findall(r"(?<!\w)[^\W\d]\w*", mask)


def measure(args):
    lexicon = Lexicon(args.names, args.extra, args.force)
    seen = collections.defaultdict(lambda: {"count": 0, "areas": set()})
    for rel, ext in tracked_files(args.root):
        if ext not in ("swift", "kt", "kts", "h", "c", "py", "sh", "mjs", "ps1"):
            continue
        for token in tokens_of(args.root, rel, ext):
            if len(token) > 1 and any(lexicon.is_german(w) for w in split_words(token)):
                entry = seen[token]
                entry["count"] += 1
                entry["areas"].add(area_of(rel))
    per_area = collections.Counter(a for e in seen.values() for a in e["areas"])
    print("German identifiers (unique): %d, occurrences: %d" % (len(seen), sum(e["count"] for e in seen.values())))
    for area, count in sorted(per_area.items()):
        print("  %-10s %d" % (area, count))
    if args.list:
        with open(args.list, "w", encoding="utf-8") as out:
            for token, entry in sorted(seen.items(), key=lambda kv: -kv[1]["count"]):
                out.write("%s\t%d\t%s\n" % (token, entry["count"], ",".join(sorted(entry["areas"]))))
    return 0


# ------------------------------------------------------------------ compose

def compose_token(token, glossary, overrides, lexicon):
    if token in overrides:
        return overrides[token]
    has_german = any(lexicon.is_german(w) for w in split_words(token))
    parts = re.findall(r"[A-Za-z]+|[^A-Za-z]+", token)
    snake = "_" in token
    upper = token.isupper() and (snake or len(token) > 3)
    lower_snake = snake and token == token.lower()
    pieces, first, changed = [], True, False
    for part in parts:
        if not part[0].isalpha():
            pieces.append(part)
            continue
        for word in re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[A-Z]+", part):
            lower = word.lower()
            english = glossary.get(lower) if (lexicon.is_german(lower) or has_german) and lower not in ENGLISH_WORDS else None
            if english is None or english == lower:
                pieces.append(word.upper() if upper else word)
                first = False
                continue
            changed = True
            sub = english.split()
            if upper:
                pieces.append("_".join(s.upper() for s in sub))
            elif lower_snake:
                pieces.append("_".join(s.lower() for s in sub))
            else:
                cased = []
                for i, s in enumerate(sub):
                    if first and i == 0:
                        cased.append(s[0].upper() + s[1:] if word[0].isupper() else s[0].lower() + s[1:])
                    else:
                        cased.append(s[0].upper() + s[1:])
                pieces.append("".join(cased))
            first = False
    return "".join(pieces) if changed else token


def compose(args):
    lexicon = Lexicon(args.names, args.extra, args.force)
    glossary = {cells[0]: cells[1] for cells in read_lines(args.glossary) if len(cells) >= 2}
    overrides = {cells[0]: cells[1] for cells in read_lines(args.tokens) if len(cells) >= 2} if args.tokens else {}
    tokens = collections.defaultdict(set)
    for rel, ext in tracked_files(args.root):
        if ext in ("swift", "kt", "h", "c"):
            for token in tokens_of(args.root, rel, ext):
                if any(lexicon.is_german(w) for w in split_words(token)):
                    tokens[token].add(area_of(rel))
    with open(args.out, "w", encoding="utf-8") as out:
        for token in sorted(tokens):
            new = compose_token(token, glossary, overrides, lexicon)
            if new == token:
                continue
            if new in HARD_KEYWORDS:
                new = KEYWORD_FALLBACK.get(new, new + "Value")
            out.write("%s\t%s\t%s\n" % (token, new, ",".join(sorted(tokens[token]))))
    return 0


# ------------------------------------------------------------------ apply

PARAMETER_LIST = re.compile(r"\b(?:func\s+[^\s(<]+|init[?!]?|subscript)\s*(?:<[^>(]*>)?\s*\(")


def parameter_spans(source):
    spans = []
    mask = source.lx.mask
    for match in PARAMETER_LIST.finditer(mask):
        depth, pos = 1, match.end()
        while pos < len(mask) and depth:
            depth += {"(": 1, ")": -1}.get(mask[pos], 0)
            pos += 1
        spans.append((match.end(), pos - 1))
    return spans


def context_name(source, start, end, word, spans):
    """Context-dependent replacement for the few words that mean two things."""
    mask = source.lx.mask
    before = start - 1
    while before >= 0 and mask[before] in " \t":
        before -= 1
    previous = mask[before] if before >= 0 else ""
    after = end
    while after < len(mask) and mask[after] in " \t":
        after += 1
    following = mask[after] if after < len(mask) else ""
    if word == "aus" and source.language == "swift":
        line = mask[mask.rfind("\n", 0, start) + 1:start]
        is_case = re.search(r"\bcase\b[^{};]*$", line) is not None
        if (previous == "." or is_case) and following not in "(:" or (previous == "." and following == ":"):
            return "off"
        return "from"
    if word == "fuer":
        if source.language != "swift":
            return "of"
        if previous == ".":
            return "of" if (mask[end:end + 1] == "(") else "for"
        if previous in "(,":
            in_header = any(a <= start < b for a, b in spans)
            if in_header:
                if mask[end:end + 1] == ":":
                    return "for of"
                if re.match(r"\s+[A-Za-z_]\w*\s*:", mask[end:end + 80]):
                    return "for"
                return "of"
            if mask[end:end + 1] == ":":
                return "for"
        return "of"
    return None


def token_edits(source, mapping):
    text, kind, found = source.text, source.lx.kind, []
    spans = parameter_spans(source) if source.language == "swift" and "fuer" in mapping else []
    for match in renamer.IDENT.finditer(text):
        word = match.group(0)
        if word in mapping and kind[match.start()] == 0:
            special = context_name(source, match.start(), match.end(), word, spans) if word in ("aus", "fuer") else None
            found.append((match.start(), match.end(), special or mapping[word]))
    for ticks in re.finditer(r"`([^`\n]{1,80})`", text):
        inner = ticks.group(1)
        if re.search(r"[/\-]|\.(swift|kt|ps1|sh|py|xml|json|c|h|yml|md|txt|plist|gradle|kts|mjs|tsv|ttf)\b", inner):
            continue
        a = ticks.start(1)
        if kind[a] == 1 and kind[ticks.end(1) - 1] == 1:
            line_start = text.rfind("\n", 0, a) + 1
            before = text[line_start:a]
            if "//" in before or before.lstrip().startswith(("*", "/*")):
                for ident in renamer.IDENT.finditer(inner):
                    if inner[:ident.start()].count('"') % 2 == 1:
                        continue  # inside a quoted wire name or UI text
                    if ident.group(0) in mapping and ident.group(0) not in ("aus", "fuer"):
                        found.append((a + ident.start(), a + ident.end(), mapping[ident.group(0)]))
    return found


def load_sources(root):
    sources = []
    for rel, _ in tracked_files(root):
        ext = os.path.splitext(rel)[1]
        if ext in CODE_EXT:
            with open(os.path.join(root, rel), encoding="utf-8", errors="surrogateescape", newline="") as handle:
                sources.append(renamer.SourceFile(rel, handle.read(), CODE_EXT[ext]))
    return sources


def apply(args):
    mapping, areas = {}, {}
    for cells in read_lines(args.mapping):
        mapping[cells[0]] = cells[1]
        areas[cells[0]] = set(cells[2].split(",")) if len(cells) > 2 else set()
    allowed = set(args.areas.split(",")) if args.areas else None
    if allowed:
        mapping = {k: v for k, v in mapping.items() if areas[k] <= allowed}
    for name in list(mapping):  # wrapper storage follows its property
        if name.startswith("_") and name[1:] in mapping:
            mapping[name] = "_" + mapping[name[1:]]
        elif name.startswith("_"):
            del mapping[name]
    sources = load_sources(args.root)
    active = dict(mapping)
    edits, blocked = renamer.protection_plan(sources, set(active))
    for name, reasons in blocked.items():
        if any("ohne Rohwert" in r or "ueber extension" in r for r in reasons) and name not in args.reviewed.split(","):
            active.pop(name, None)
            print("blocked (needs a manual look):", name, reasons[0][:100])
    total = 0
    for source in sources:
        planned = [e for e in edits.get(source.rel, []) if e[1]]
        text = source.text
        if planned:
            text = renamer.apply_edits(text, planned)
            source.relex(text)
        found = token_edits(source, active)
        if not found and not planned:
            continue
        for a, b, new in sorted(found, reverse=True):
            text = text[:a] + new + text[b:]
        total += len(found)
        if args.write and (found or planned):
            with open(os.path.join(args.root, source.rel), "w", encoding="utf-8", errors="surrogateescape", newline="") as out:
                out.write(text)
    print("%s %d tokens in %d names" % ("replaced" if args.write else "would replace", total, len(active)))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("measure", "compose", "apply"):
        p = sub.add_parser(name)
        p.add_argument("--root", default=ROOT)
        p.add_argument("--names")
        p.add_argument("--extra")
        p.add_argument("--force", help="file with extra German words (first column)")
    sub.choices["measure"].add_argument("--list", help="write every token with count and areas")
    sub.choices["compose"].add_argument("--glossary", required=True)
    sub.choices["compose"].add_argument("--tokens")
    sub.choices["compose"].add_argument("--out", required=True)
    sub.choices["apply"].add_argument("--mapping", required=True)
    sub.choices["apply"].add_argument("--areas")
    sub.choices["apply"].add_argument("--write", action="store_true")
    sub.choices["apply"].add_argument("--reviewed", default="", help="names whose custom Codable code was checked")
    args = parser.parse_args(argv)
    if args.command in ("measure", "compose") and not args.names:
        parser.error("--names is required")
    return {"measure": measure, "compose": compose, "apply": apply}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
