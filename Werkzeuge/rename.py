#!/usr/bin/env python3
"""Applies a name mapping (TSV old->new) to Swift and Kotlin sources.

Default is a dry run; files are written only with --anwenden.

  rename.py [--tsv NAMEN.tsv] [--zusatz DATEI] [--schutz schutz.txt]
                [--bereich PFAD...] [--absichern] [--dateien] [--anwenden]
                [--offen offen.txt] [--ohne-auto-schutz] [--weich] [--wurzel DIR]
                [--kurz]

Input
  TSV: columns alt,neu,art,klasse,plattformen,schutz,kollision,hinweis. Only rows with schutz=nein
  (with --weich also "pruefen: ..."), kollision=nein and no '?' in neu/hinweis are used.
  If a name has several rows, all must be allowed and have the same neu.
  Extra file (TAB): "alt<TAB>neu[<TAB>frei]" sets/overrides a row independently of the TSV columns
  (also works against schutz=ja); "alt<TAB>-" removes the name; "frei" additionally lifts the
  automatic string protection. Lines with '#' are comments.
  schutz.txt: one name per line, always takes precedence (also over the extra file).

Protection
  Any name that appears anywhere as a whole string (or as a part, separated by . / : _ - #, of a
  string without spaces) is protected automatically. Exceptions are raw values
  "case x = "wert"" and @SerialName("wert"): the string stays untouched there anyway.

Replacement happens only in code, not in comments, strings and raw strings; Swift \\( ... ) and
Kotlin ${ ... } / $name count as code.
"""
import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict

ROOTS = ["Sources", "Packages", "Android", "Linux", "Windows", "Werkzeuge"]
SKIP_DIRS = {"build", ".build", ".gradle", "Pods", "DerivedData", ".git", "node_modules", "Vendor", ".swiftpm", "xcuserdata"}
PLATFORM_DIRS = {
    "Kit": "Packages", "Shared": "Sources/Shared", "iOS": "Sources/iOS", "tvOS": "Sources/tvOS",
    "macOS": "Sources/macOS", "TopShelf": "Sources/TopShelf", "AndroidHandy": "Android/phone",
    "AndroidKern": "Android/core", "AndroidGem": "Android/shared", "Linux": "Linux",
    "Windows": "Windows", "Werkzeuge": "Werkzeuge",
}
APPLE = ["Shared", "iOS", "tvOS", "macOS", "TopShelf"]
ANDROID = ["AndroidHandy", "AndroidKern", "AndroidGem"]

SWIFT_KW = set("""associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default
defer do else fallthrough for guard if in repeat return throw switch where while Any as await false is nil self Self super
throws true try _ async some any actor get set willSet didSet""".split())
KOTLIN_KW = set("""as break class continue do else false for fun if in interface is null object package return super this
throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init
param property receiver set setparam value where abstract actual annotation companion const crossinline data enum expect
external final infix inline inner internal lateinit noinline open operator out override private protected public reified
sealed suspend tailrec vararg""".split())
SYSTEM_TYPES = set("""Row Box Card View Image List Error Result Collection Toggle Slider Text Button Label Section Tab
Sheet Item Event State Request Response Cache Point Character Badge Edge Display Store Player Job Tile Transition Menu Form
Group Stack Spacer Divider Picker Alert Link Table Color Font Path Shape Canvas Scene App Binding Task Data Date URL Set
Array Dictionary Optional String Int Bool Double Float Never Void Any Type Protocol Self Index Range Element Key Value
Context Environment Layout Gesture Animation Timer Operation Bundle Notification Process Thread Stream Scanner Formatter
Locale Calendar Measurement Progress Navigation Page Screen Window Surface Modifier Content Scroll Pair Triple Unit
Sequence Iterator Comparable Hashable Equatable Codable Identifiable Sendable Decoder Encoder Mirror Selector
Surface Dialog Icon Chip Switch Surface Scaffold Column Modifier Composable""".split())

IDENT = re.compile(r"(?<![\w])[^\W\d]\w*")
IDENT_FULL = re.compile(r"^[^\W\d]\w*$")


# ------------------------------------------------------------------ Lexer

class Lexed:
    __slots__ = ("kind", "mask", "literals")


def lex(text, language):
    n = len(text)
    kind = bytearray(n)  # 0 = code, 1 = not code
    literals = []
    swift = language == "swift"
    open_c, close_c = ("(", ")") if swift else ("{", "}")
    pat = re.compile(r"""[/"#(){}']""" if not swift else r"""[/"#()]""")
    ident_start = re.compile(r"[^\W\d]")

    def mark(a, b):
        if b > a:
            kind[a:b] = b"\x01" * (b - a)

    def comment_block(i):
        depth = 1
        j = i + 2
        while j < n and depth:
            if text.startswith("/*", j):
                depth += 1
                j += 2
            elif text.startswith("*/", j):
                depth -= 1
                j += 2
            else:
                j += 1
        mark(i, j)
        return j

    def raw_string_swift(i):
        j = i
        while j < n and text[j] == "#":
            j += 1
        hashes = j - i
        if j >= n or text[j] != '"':
            return None
        multi = text.startswith('"""', j) and text[j + 3: j + 4] in ("\n", "\r")
        term = ('"""' if multi else '"') + "#" * hashes
        interp = "\\" + "#" * hashes + "("
        k = j + (3 if multi else 1)
        seg = i
        while k < n:
            if text.startswith(interp, k):
                mark(seg, k + len(interp))
                literals.append(text[seg:k])
                e = code(k + len(interp), True)
                seg = e
                k = e + 1
                continue
            if text.startswith(term, k):
                end = k + len(term)
                mark(seg, end)
                literals.append(text[seg:end])
                return end
            k += 1
        mark(seg, n)
        literals.append(text[seg:n])
        return n

    def string(i):
        multi = text.startswith('"""', i)
        j = i + (3 if multi else 1)
        seg = i
        while j < n:
            c = text[j]
            if c == "\\" and swift:
                if text.startswith("\\(", j):
                    mark(seg, j + 2)
                    literals.append(text[seg:j])
                    k = code(j + 2, True)
                    seg = k  # ')' belongs to the next segment
                    j = k + 1
                    continue
                j += 2
                continue
            if c == "\\" and not multi:  # Kotlin, not raw
                j += 2
                continue
            if not swift and c == "$":
                if text.startswith("${", j):
                    mark(seg, j + 2)
                    literals.append(text[seg:j])
                    k = code(j + 2, True)
                    seg = k
                    j = k + 1
                    continue
                if j + 1 < n and ident_start.match(text[j + 1]):
                    mark(seg, j + 1)
                    literals.append(text[seg:j])
                    k = j + 1
                    while k < n and (text[k].isalnum() or text[k] == "_"):
                        k += 1
                    seg = k
                    j = k
                    continue
            if multi:
                if text.startswith('"""', j):
                    end = j + 3
                    while end < n and text[end] == '"':  # Kotlin: """"
                        end += 1
                    mark(seg, end)
                    literals.append(text[seg:j])
                    return end
            else:
                if c == '"':
                    mark(seg, j + 1)
                    literals.append(text[seg:j])
                    return j + 1
                if c == "\n":
                    mark(seg, j)
                    literals.append(text[seg:j])
                    return j
            j += 1
        mark(seg, n)
        literals.append(text[seg:n])
        return n

    def code(i, nested):
        """Reads code from i. With nested=True up to the closing bracket; returns its index."""
        depth = 0
        while i < n:
            m = pat.search(text, i)
            if not m:
                return n
            j = m.start()
            c = text[j]
            if c == "/":
                if text.startswith("//", j):
                    k = text.find("\n", j)
                    k = n if k < 0 else k
                    mark(j, k)
                    i = k
                elif text.startswith("/*", j):
                    i = comment_block(j)
                else:
                    i = j + 1
            elif c == '"':
                i = string(j)
            elif c == "#":
                if swift:
                    k = raw_string_swift(j)
                    i = k if k is not None else j + 1
                else:
                    i = j + 1
            elif c == "'" and not swift:
                k = j + 1
                if k < n and text[k] == "\\":
                    k += 2
                else:
                    k += 1
                while k < n and text[k] != "'" and k - j < 12 and text[k] != "\n":
                    k += 1
                if k < n and text[k] == "'":
                    mark(j, k + 1)
                    i = k + 1
                else:
                    i = j + 1
            elif c == open_c:
                depth += 1
                i = j + 1
            elif c == close_c:
                if depth == 0 and nested:
                    return j
                depth = max(0, depth - 1)
                i = j + 1
            else:
                i = j + 1
        return n

    code(0, False)
    out = Lexed()
    out.kind = kind
    chars = list(text)
    for a, b in _runs(kind):
        for p in range(a, b):
            if chars[p] != "\n":
                chars[p] = " "
    out.mask = "".join(chars)
    out.literals = literals
    return out


def _runs(kind):
    n = len(kind)
    i = 0
    while i < n:
        j = kind.find(b"\x01", i)
        if j < 0:
            return
        k = j
        while k < n and kind[k] == 1:
            k += 1
        yield j, k
        i = k


# ------------------------------------------------------------------ Files

class SourceFile:
    def __init__(self, rel, text, language):
        self.rel = rel
        self.text = text
        self.language = language
        self.lx = lex(text, language)
        self.groups = group_of(rel)
        self._decl = None

    def relex(self, text):
        self.text = text
        self.lx = lex(text, self.language)
        self._decl = None


def group_of(rel):
    for g, d in PLATFORM_DIRS.items():
        if rel == d or rel.startswith(d + "/"):
            return g
    if rel.startswith("Sources/"):
        return "Shared"
    if rel.startswith("Android/"):
        return "AndroidHandy"
    return "Werkzeuge"


def visible_from(g):
    """Platforms whose declarations are visible from g."""
    if g == "Kit":
        return set(PLATFORM_DIRS)
    s = {g, "Kit"}
    if g in APPLE:
        s.add("Shared")
    if g == "Shared":
        s.update(APPLE)
    if g in ANDROID:
        s.update(ANDROID)
    return s


def collect_files(root, ranges_ignored=None):
    files = []
    for r in ROOTS:
        base = os.path.join(root, r)
        if not os.path.isdir(base):
            continue
        for dp, dns, fns in os.walk(base):
            dns[:] = sorted(d for d in dns if d not in SKIP_DIRS and not d.startswith("."))
            for fn in sorted(fns):
                if fn.endswith(".swift") or fn.endswith(".kt"):
                    p = os.path.join(dp, fn)
                    rel = os.path.relpath(p, root)
                    with open(p, encoding="utf-8", errors="surrogateescape", newline="") as f:
                        t = f.read()
                    files.append(SourceFile(rel, t, "swift" if fn.endswith(".swift") else "kotlin"))
    return files


# ------------------------------------------------------------------ Structure (declarations, blocks)

SWIFT_DECL = re.compile(
    r"\b(?:func|let|var|struct|enum|protocol|typealias|actor|associatedtype|"
    r"class(?!\s+(?:func|var|let|final|private|static|override|subscript|init|deinit)\b))\s+`?([^\W\d]\w*)")
KOTLIN_DECL = re.compile(
    r"\b(?:fun|val|var|class|object|interface|typealias)\s+(?:<[^>]*>\s*)?(?:[\w.<>?,\s]*\.)?`?([^\W\d]\w*)")


def match_braces(mask):
    match = {}
    stack = []
    depth = [0] * (len(mask) + 1)
    d = 0
    for i, c in enumerate(mask):
        depth[i] = d
        if c == "{":
            stack.append(i)
            d += 1
        elif c == "}":
            d = max(0, d - 1)
            if stack:
                match[stack.pop()] = i
    depth[len(mask)] = d
    return match, depth


def split_top(s):
    """Splits s at commas outside of brackets; returns (offset, text)."""
    out = []
    d = 0
    st = 0
    for i, c in enumerate(s):
        if c in "([{<" and not (c == "<" and False):
            d += 1 if c != "<" else 0
        elif c in ")]}":
            d -= 1
        elif c == "," and d == 0:
            out.append((st, s[st:i]))
            st = i + 1
    out.append((st, s[st:]))
    return out


class Struktur:
    """Blocks of a Swift file (enum/struct/class/extension) on the mask."""
    BLK = re.compile(r"\b(enum|struct|class|extension|actor)\s+([\w.`]+)([^{};]*)\{")

    def __init__(self, file):
        mask = file.lx.mask
        self.mask = mask
        self.match, self.depth = match_braces(mask)
        self.blocks = []
        for m in self.BLK.finditer(mask):
            kw, name, head = m.group(1), m.group(2).strip("`"), m.group(3)
            if kw == "class" and name in SWIFT_KW:
                continue
            ob = m.end() - 1
            if ob not in self.match:
                continue
            self.blocks.append({
                "kw": kw, "name": name, "head": head, "open": ob, "start": ob + 1, "end": self.match[ob],
                "d": self.depth[ob] + 1, "pos": m.start(),
            })

    def tokens(self, blk):
        h = blk["head"]
        i = h.find(":")
        return set(re.findall(r"[\w]+", h[i + 1:])) if i >= 0 else set()

    def cases(self, blk):
        """Returns [(name, ident_start, ident_end, has_raw_value, has_assoc)] of the cases at block level."""
        out = []
        mask = self.mask
        for m in re.finditer(r"\bcase\b", mask[blk["start"]:blk["end"]]):
            pos = blk["start"] + m.start()
            if self.depth[pos] != blk["d"]:
                continue
            i = pos + 4
            pd = 0
            j = i
            while j < blk["end"]:
                c = mask[j]
                if c in "([":
                    pd += 1
                elif c in ")]":
                    pd -= 1
                elif (c == "\n" and pd <= 0) or (c == ";" and pd <= 0):
                    break
                j += 1
            seg = mask[i:j]
            for off, el in split_top(seg):
                mm = re.match(r"\s*`?([^\W\d]\w*)`?", el)
                if not mm:
                    continue
                rest = el[mm.end():]
                out.append((mm.group(1), i + off + mm.start(1), i + off + mm.end(1) + (1 if mm.group(0).endswith("`") else 0),
                            bool(re.match(r"\s*=", rest)), bool(re.match(r"\s*\(", rest))))
        return out

    def props(self, blk):
        """Stored properties at block level: [(name, has_default)]"""
        out = []
        mask = self.mask
        rx = re.compile(r"^([ \t]*)((?:@\w+(?:\([^)\n]*\))?[ \t]+)*(?:[\w()]+[ \t]+)*?)(let|var)[ \t]+([^\W\d]\w*)([^\n]*)", re.M)
        for m in rx.finditer(mask, blk["start"], blk["end"]):
            if self.depth[m.start(3)] != blk["d"]:
                continue
            mods = m.group(2)
            if re.search(r"\b(static|class|lazy)\b", mods):
                continue
            rest = m.group(5)
            has_default = bool(re.search(r"=", rest.split("{")[0]))
            if m.group(3) == "let" and has_default:
                continue
            if "{" in rest and not has_default:
                # computed, except observers
                ob = mask.find("{", m.start(5))
                cb = self.match.get(ob, ob)
                inner = mask[ob:cb]
                if not re.search(r"\b(didSet|willSet)\b", inner):
                    continue
            out.append((m.group(4), has_default))
            more = re.match(r"((?:\s*,\s*[^\W\d]\w*)+)\s*[:=]", rest)
            if more:
                for extra in re.findall(r"[^\W\d]\w*", more.group(1)):
                    out.append((extra, has_default))
        return out

    def decl_names(self):
        names = set()
        for blk in self.blocks:
            if blk["kw"] == "enum":
                for c in self.cases(blk):
                    names.add(c[0])
        return names


def declarations(file):
    if file._decl is not None:
        return file._decl
    mask = file.lx.mask
    names = set()
    if file.language == "swift":
        for m in SWIFT_DECL.finditer(mask):
            if m.group(1) not in SWIFT_KW:
                names.add(m.group(1))
        names |= Struktur(file).decl_names()
    else:
        for m in KOTLIN_DECL.finditer(mask):
            if m.group(1) not in KOTLIN_KW:
                names.add(m.group(1))
        for _, nm, _s in kotlin_enum_entries(file):
            names.add(nm)
    file._decl = names
    return names


def kotlin_enum_entries(file):
    """[(enum_name, entry, abs_position)]"""
    mask = file.lx.mask
    match, depth = match_braces(mask)
    out = []
    for m in re.finditer(r"\benum\s+class\s+(\w+)[^{;]*\{", mask):
        ob = m.end() - 1
        cb = match.get(ob)
        if cb is None:
            continue
        d = depth[ob] + 1
        i = ob + 1
        st = i
        pd = 0
        pieces = []
        while i < cb:
            c = mask[i]
            if c in "({":
                pd += 1
            elif c in ")}":
                pd -= 1
            elif pd == 0 and c in ",;":
                pieces.append((st, mask[st:i]))
                st = i + 1
                if c == ";":
                    break
            i += 1
        else:
            pieces.append((st, mask[st:cb]))
        for off, el in pieces:
            mm = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s*)*([A-Za-z_]\w*)", el)
            if mm and not re.match(r"\s*(fun|val|var|companion|private|override)\b", el):
                out.append((m.group(1), mm.group(1), off + mm.start(1)))
    return out


# ------------------------------------------------------------------ Loading the name list

def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            p = line.rstrip("\n").split("\t")
            p += [""] * (8 - len(p))
            rows.append(dict(zip(header, p)))
    return rows


def load_mapping(rows, soft, notes):
    by_alt = defaultdict(list)
    for r in rows:
        if r["art"] == "Datei":
            continue
        by_alt[r["alt"]].append(r)
    mapping = {}
    plat = {}
    for alt, rs in sorted(by_alt.items()):
        ok = True
        why = ""
        neus = set()
        for r in rs:
            s = r["schutz"].strip()
            if s != "nein" and not (soft and s.startswith("pruefen")):
                ok, why = False, "schutz"
            if r["kollision"].strip() != "nein":
                ok, why = False, "kollision"
            if "?" in r["neu"] or "?" in r["hinweis"] or not r["neu"]:
                ok, why = False, "unsicher"
            neus.add(r["neu"])
        if ok and len(neus) != 1:
            ok, why = False, "uneinheitlich"
        if ok:
            new = neus.pop()
            if new == alt:
                continue
            if not IDENT_FULL.match(new):
                notes.append((alt, "neu kein Bezeichner"))
                continue
            mapping[alt] = new
            plat[alt] = {p.strip() for r in rs for p in r["plattformen"].split(",") if p.strip()}
    return mapping, plat


def load_extra(path, mapping, plat, free):
    if not path:
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            p = line.split("\t")
            if len(p) < 2:
                continue
            alt, new = p[0].strip(), p[1].strip()
            if new == "-":
                mapping.pop(alt, None)
                continue
            if new != alt and IDENT_FULL.match(new):
                mapping[alt] = new
                plat.setdefault(alt, set())
                if len(p) > 2 and p[2].strip() == "frei":
                    free.add(alt)


def load_protect(path):
    s = set()
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.split("#")[0].strip()
                if line:
                    s.add(line)
    return s


# ------------------------------------------------------------------ Automatic string protection

RAW_PRE_SWIFT = re.compile(r"(?:\bcase\s+|,\s*)[\w`]+\s*=\s*$")
RAW_PRE_ANY = re.compile(r"@SerialName\(\s*$")
SPLIT = re.compile(r"[./:_\-#]")


def auto_protect(files):
    prot = set()
    for d in files:
        txt = d.text
        pos = 0
        for lit in d.lx.literals:
            if not lit or lit.startswith('"#') or lit.startswith("#"):
                pass
            # String without delimiters; determine the raw-value position
            index = txt.find(lit, pos) if lit else -1
            if index >= 0:
                pos = index + len(lit)
                pre = txt[max(0, index - 90): index]
                pre = pre.rstrip('"').rstrip()
                pre = txt[max(0, index - 90): index].rstrip('"')
                if RAW_PRE_ANY.search(pre) or (d.language == "swift" and RAW_PRE_SWIFT.search(pre)):
                    continue
            s = lit.strip('"').strip()
            if not s:
                continue
            if IDENT_FULL.match(s):
                prot.add(s)
            if not re.search(r"\s", s):
                prot.add(s)
                for part in SPLIT.split(s):
                    if IDENT_FULL.match(part):
                        prot.add(part)
    return prot


# ------------------------------------------------------------------ Main work

def token_hits(file, names):
    """{name: [(start,end)]} for code tokens that are in names."""
    out = defaultdict(list)
    kind = file.lx.kind
    for m in IDENT.finditer(file.text):
        w = m.group(0)
        if w in names and kind[m.start()] == 0:
            out[w].append((m.start(), m.end()))
    return out


def scope_of(alt, platforms_by_file):
    sc = set()
    for g in platforms_by_file:
        sc |= visible_from(g)
    return sc


def swift_reflexion(file):
    return bool(re.search(r"String\(\s*(describing|reflecting)\s*:|\bMirror\(|\bdump\(", file.lx.mask))


CODABLE = {"Codable", "Encodable", "Decodable"}
CODING_LIKE = CODABLE | {"CodingKey"}
RAW_OTHER = {"Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float", "Character"}


def active_in(d, active):
    return not active.isdisjoint(IDENT.findall(d.lx.mask))


def protection_plan(files, active):
    """Plans protections. Returns (edits[file.rel] -> [(pos,text,name)], offen[name] -> [reason])."""
    edits = defaultdict(list)
    blocked = defaultdict(list)
    for d in files:
        if d.language == "swift":
            _abs_swift(d, active, edits, blocked)
        else:
            _abs_kotlin(d, active, edits, blocked)
    return edits, blocked


def _abs_swift(d, active, edits, blocked):
    if not active_in(d, active):
        return
    st = Struktur(d)
    refl = swift_reflexion(d)
    coded_ext = set()
    blocks = st.blocks
    for b in blocks:
        if b["kw"] == "extension" and st.tokens(b) & CODING_LIKE:
            coded_ext.add(b["name"].split(".")[-1])
    for b in blocks:
        if b["kw"] == "enum":
            toks = st.tokens(b)
            raw_string = "String" in toks
            raw_other = bool(toks & RAW_OTHER)
            coding = bool(toks & CODING_LIKE)
            for name, a, e, has_raw, assoc in st.cases(b):
                if name not in active or has_raw:
                    continue
                where = "%s:%s" % (d.rel, b["name"])
                if raw_string and not assoc:
                    edits[d.rel].append((e, ' = "%s"' % name, frozenset([name])))
                elif raw_other and not assoc:
                    continue
                elif coding:
                    blocked[name].append("%s: enum %s ohne Rohwert mit Codable/CodingKey" % (where, b["name"]))
                elif refl:
                    blocked[name].append("%s: Reflexion (String(describing:)) in der Datei, enum %s" % (where, b["name"]))
        elif b["kw"] in ("struct", "class", "actor"):
            toks = st.tokens(b)
            coded = bool(toks & CODABLE) or b["name"] in coded_ext
            if not coded:
                continue
            props = st.props(b)
            hit = [p for p, _ in props if p in active]
            if not hit:
                continue
            has_keys = any(c["kw"] == "enum" and c["name"] == "CodingKeys" and c["d"] == b["d"] + 1 and
                           b["start"] <= c["open"] < b["end"] for c in blocks)
            custom = re.search(r"\binit\s*\(\s*from\b|\bfunc\s+encode\s*\(\s*to\b", d.lx.mask[b["start"]:b["end"]])
            if has_keys:
                continue  # the enum rule handles the CodingKeys cases
            if b["name"] in coded_ext and not (toks & CODABLE):
                for h in hit:
                    blocked[h].append("%s: Codable ueber extension, %s ohne CodingKeys" % (d.rel, b["name"]))
                continue
            if custom:
                for h in hit:
                    blocked[h].append("%s: %s hat eigene init(from:)/encode(to:) ohne CodingKeys" % (d.rel, b["name"]))
                continue
            ls = d.text.rfind("\n", 0, b["pos"]) + 1
            indent = re.match(r"[ \t]*", d.text[ls:]).group(0)
            lines = ["", "%s    enum CodingKeys: String, CodingKey {" % indent]
            for p, _ in props:
                lines.append('%s        case %s%s' % (indent, p, ' = "%s"' % p if p in active else ""))
            lines.append("%s    }" % indent)
            edits[d.rel].append((b["start"], "\n".join(lines), frozenset(hit)))


def _abs_kotlin(d, active, edits, blocked):
    text = d.text
    mask = d.lx.mask
    if not active_in(d, active):
        return
    match, depth = match_braces(mask)
    has_serial = "@Serializable" in mask
    foreign = bool(re.search(r"com\.google\.gson|com\.squareup\.moshi|@SerializedName|@Json\b", text))
    need_import = False
    handled = set()
    # @Serializable classes
    for m in re.finditer(r"@Serializable\b[^\n]*", mask):
        k = re.compile(r"\b(?:data\s+|sealed\s+|enum\s+|open\s+)*(class|object|interface)\s+(\w+)").search(mask, m.start())
        if not k:
            continue
        i = k.end()
        props_ranges = []
        j = i
        while j < len(mask) and mask[j] in " \t\n<":
            j += 1
        if mask[i:].lstrip().startswith("<"):
            g = mask.find(">", i)
            j = g + 1 if g > 0 else i
        pm = re.compile(r"\s*(?:\w+\s+)*\(").match(mask, j)
        if pm:
            ob = pm.end() - 1
            pd = 0
            c = ob
            while c < len(mask):
                if mask[c] == "(":
                    pd += 1
                elif mask[c] == ")":
                    pd -= 1
                    if pd == 0:
                        break
                c += 1
            props_ranges.append((ob, c))
            j = c + 1
        bm = re.compile(r"[^{};\n]*\{").match(mask, j)
        if bm:
            ob = bm.end() - 1
            cb = match.get(ob)
            if cb:
                props_ranges.append((ob + 1, cb, depth[ob] + 1))
        for pr in props_ranges:
            a, b = pr[0], pr[1]
            for vm in re.finditer(r"\b(val|var)\s+`?([^\W\d]\w*)", mask[a:b]):
                ps = a + vm.start()
                if len(pr) == 3 and depth[ps] != pr[2]:
                    continue
                nm = vm.group(2)
                if nm not in active or ps in handled:
                    continue
                handled.add(ps)
                before = mask[max(a, ps - 160):ps]
                seg = re.split(r"[,(\n{;]", before)[-1] if len(pr) == 2 else before.split("\n")[-1]
                full = text[max(a, ps - 160):ps]
                lastline = re.split(r"[,(\n]", full)[-1] if len(pr) == 2 else full.split("\n")[-1]
                if "@SerialName" in lastline or "@Transient" in lastline or "@Transient" in full.split("\n")[-2:][0] and len(pr) == 3 and False:
                    continue
                if len(pr) == 3 and re.search(r"@(SerialName|Transient)[^\n]*$", text[max(0, ps - 120):ps].split("\n")[-2] if "\n" in text[max(0, ps - 120):ps] else ""):
                    continue
                edits[d.rel].append((ps, '@SerialName("%s") ' % nm, frozenset([nm])))
                need_import = True
    # Enum entries
    for enum, ent, pos in kotlin_enum_entries(d):
        if ent not in active:
            continue
        em = re.search(r"enum\s+class\s+" + re.escape(enum) + r"\b", mask)
        pre = mask[max(0, em.start() - 200): em.start()] if em else ""
        if "@Serializable" in pre and not text[max(0, pos - 40):pos].count("@SerialName"):
            edits[d.rel].append((pos, '@SerialName("%s") ' % ent, frozenset([ent])))
            need_import = True
        elif "@Serializable" in pre:
            continue
        else:
            blocked[ent].append("%s: Kotlin-Enum-Eintrag in %s (name()/valueOf nicht pruefbar)" % (d.rel, enum))
    if foreign:
        for pm in re.finditer(r"\b(val|var)\s+`?([^\W\d]\w*)", mask):
            nm = pm.group(2)
            if nm in active:
                line = text[text.rfind("\n", 0, pm.start()) + 1: pm.start()]
                if "@SerializedName" not in line and "@Json" not in line:
                    blocked[nm].append("%s: Gson/Moshi-Datei, Eigenschaft ohne Annotation" % d.rel)
    if need_import and "import kotlinx.serialization.SerialName" not in text and \
            not re.search(r"import kotlinx\.serialization\.\*", text):
        pm = re.search(r"^package .*$", text, re.M)
        pos = pm.end() if pm else 0
        edits[d.rel].append((pos, "\n\nimport kotlinx.serialization.SerialName" if pm else "import kotlinx.serialization.SerialName\n",
                             frozenset()))


def apply_edits(text, eds):
    eds = sorted(eds, key=lambda e: (e[0], e[1] or ""), reverse=True)
    for pos, into, _ in eds:
        if into:
            text = text[:pos] + into + text[pos:]
    return text


def run(args):
    root = os.path.abspath(args.root)
    here = os.path.dirname(os.path.abspath(__file__))
    tsv = args.tsv or os.path.join(root, "..", "Notizen", "Optimierung", "NAMEN.tsv")
    protect_path = args.protect or os.path.join(here, "schutz.txt")
    log = []
    P = lambda s: log.append(s)

    rows = read_tsv(tsv)
    notes = []
    mapping, plat = load_mapping(rows, args.soft, notes)
    free = set()
    load_extra(args.extra, mapping, plat, free)
    harter = load_protect(protect_path)
    for h in harter:
        mapping.pop(h, None)

    files = collect_files(root)
    P("Dateien gelesen: %d, Verzeichniseintraege: %d" % (len(files), len(mapping)))

    area = None
    if args.area:
        area = []
        for b in args.area:
            ap = os.path.abspath(b if os.path.isabs(b) else os.path.join(root, b))
            area.append(os.path.relpath(ap, root))

    def in_area(rel):
        return area is None or any(rel == b or rel.startswith(b.rstrip("/") + "/") for b in area)

    blocked = {}  # name -> reason
    for alt, why in notes:
        blocked[alt] = why

    # Automatic string protection
    if not args.no_auto_protect:
        prot = auto_protect(files)
        for n in sorted(mapping):
            if n in prot and n not in free:
                blocked[n] = "als Zeichenkette im Code"
    active = {a: b for a, b in mapping.items() if a not in blocked}

    # Hits (all files) and scopes
    hits = defaultdict(lambda: defaultdict(list))  # name -> rel -> spans
    for d in files:
        for w, sp in token_hits(d, active).items():
            hits[w][d.rel] = sp
    rel_group = {d.rel: d.groups for d in files}
    scope = {}
    for a in active:
        groups = {rel_group[r] for r in hits.get(a, {})} or {p for p in plat.get(a, set()) if p in PLATFORM_DIRS}
        sc = set()
        for g in groups:
            sc |= visible_from(g)
        if "Kit" in groups:
            sc = set(PLATFORM_DIRS)
        scope[a] = sc
    # Declarations and usage per name (all files)
    decl_in = defaultdict(set)  # name -> set(platform)
    used_tokens = defaultdict(set)
    for d in files:
        for nm in declarations(d):
            decl_in[nm].add(d.groups)
    # Capitalized names in use (for the system-type heuristic)
    cap_needed = {n for n in active.values() if n[:1].isupper()}
    if cap_needed:
        for d in files:
            for m in IDENT.finditer(d.lx.mask):
                w = m.group(0)
                if w in cap_needed:
                    used_tokens[w].add(d.groups)

    def conflicts(a):
        """Reasons why active[a] is not free."""
        new = active[a]
        kw = SWIFT_KW | KOTLIN_KW
        if new in kw:
            return "Schluesselwort"
        if new in SYSTEM_TYPES:
            return "Systemname"
        if new in harter:
            return "Schutzliste"
        sc = scope[a]
        for g in sc:
            if new in decl_in and g in decl_in.get(new, ()):
                if new in active and new != a and new in {x for x in active} and \
                        decl_in_only_renamed(new, g):
                    continue
                return "Kollision: %s schon deklariert (%s)" % (new, g)
        if new[:1].isupper() and new not in decl_in:
            for g in used_tokens.get(new, ()):
                if g in sc and not any(new == x for x in active):
                    return "Name wird schon verwendet (%s)" % g
        return None

    def decl_in_only_renamed(new, g):
        # new is itself a name being renamed (it disappears) and is declared only in g, provided it stays active
        return new in active

    changed = True
    rounds = 0
    while changed and rounds < 6:
        changed = False
        rounds += 1
        # duplicate targets
        seen = {}
        for a in sorted(active):
            new = active[a]
            if new in seen and scope[a] & scope[seen[new]]:
                blocked[a] = "Ziel %s schon fuer %s vergeben" % (new, seen[new])
                del active[a]
                changed = True
                continue
            seen[new] = a
        for a in sorted(list(active)):
            c = conflicts(a)
            if c:
                blocked[a] = c
                del active[a]
                changed = True

    # Securing
    edits, blocked_why = protection_plan(files, set(active))
    plan_names = defaultdict(set)
    for rel, es in edits.items():
        for pos, into, deps in es:
            for nm in deps:
                plan_names[nm].add(rel)
    for nm, whys in blocked_why.items():
        if nm in active:
            blocked[nm] = "offen: " + whys[0]
            del active[nm]
    if not args.secure:
        for nm in sorted(plan_names):
            if nm in active:
                blocked[nm] = "offen: braucht --absichern (Rohwert/CodingKeys)"
                del active[nm]
    for rel in list(edits):
        keep = [e for e in edits[rel] if e[2] and any(x in active for x in e[2])]
        if keep:
            keep += [e for e in edits[rel] if not e[2]]
            edits[rel] = keep
        else:
            del edits[rel]
    secured = sorted({nm for nm in plan_names if nm in active})

    # Recount dry-run hits for active names
    per_name = defaultdict(int)
    per_file = defaultdict(lambda: defaultdict(int))
    for a in active:
        for rel, sp in hits[a].items():
            per_name[a] += len(sp)
            per_file[rel][a] += len(sp)

    # Scope warnings
    warn = []
    for a in sorted(active):
        out_files = [r for r in hits[a] if not in_area(r)]
        in_files = [r for r in hits[a] if in_area(r)]
        if area is not None and in_files and out_files:
            warn.append("%s: auch genutzt ausserhalb des Bereichs (%d Dateien, z. B. %s)" % (a, len(out_files), out_files[0]))
        elif area is not None:
            miss = [p for p in sorted(plat.get(a, ())) if p in PLATFORM_DIRS and not in_area(PLATFORM_DIRS[p]) and
                    not any(b.startswith(PLATFORM_DIRS[p]) or PLATFORM_DIRS[p].startswith(b) for b in area)]
            if in_files and miss:
                warn.append("%s: Plattformen laut Verzeichnis nicht im Bereich: %s" % (a, ",".join(miss)))
    if area is not None:
        for a in list(active):
            if not any(in_area(r) for r in hits[a]):
                per_name.pop(a, None)

    # Apply / dry run
    total = 0
    written = 0
    fcount = 0
    sec_edits = 0
    for d in files:
        if not in_area(d.rel):
            continue
        fe = [e for e in edits.get(d.rel, []) if e[1]]
        fh = {a: hits[a][d.rel] for a in active if d.rel in hits[a]}
        n = sum(len(v) for v in fh.values())
        if not n and not fe:
            continue
        total += n
        sec_edits += len(fe)
        fcount += 1
        if args.apply:
            text = apply_edits(d.text, fe) if fe else d.text
            if fe:
                d.relex(text)
            spans = []
            for m in IDENT.finditer(d.text):
                w = m.group(0)
                if w in active and d.lx.kind[m.start()] == 0:
                    spans.append((m.start(), m.end(), active[w]))
            for a, b, nw in reversed(spans):
                text = text[:a] + nw + text[b:]
            if text != d.text or fe:
                with open(os.path.join(root, d.rel), "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
                    f.write(text)
                written += 1
        if not args.brief and not args.apply:
            P("  %s: %d Treffer (%d Namen)%s" % (d.rel, n, len(fh), ", %d Absicherungen" % len(fe) if fe else ""))
    if not args.brief and not args.apply:
        for a in sorted(per_name):
            P("  %s -> %s: %d Treffer in %d Dateien" % (a, active[a], per_name[a], len([r for r in hits[a] if in_area(r)])))

    blocked_lines = []
    for nm in sorted(blocked):
        if nm in mapping or nm in {x for x, _ in notes}:
            blocked_lines.append("%s\t%s\t%s" % (nm, mapping.get(nm, ""), blocked[nm]))

    # Renaming files
    moves = []
    refs = []
    if args.files:
        moves, refs = file_renames(rows, root, args, in_area, P)

    with open(args.blocked_file, "w", encoding="utf-8") as f:
        f.write("\n".join(blocked_lines) + ("\n" if blocked_lines else ""))
    P("Namen: %d aktiv, %d uebersprungen (siehe %s), %d abgesichert" % (len(per_name), len(blocked_lines), args.blocked_file, len(secured)))
    P("%s: %d Treffer in %d Dateien%s" % ("Geschrieben" if args.apply else "Trockenlauf", total, fcount,
                                          (", %d Dateien geaendert" % written) if args.apply else ""))
    for w in warn:
        P("WARNUNG " + w)
    for r in refs:
        P("HINWEIS Referenz: " + r)
    for line in log:
        print(line)
    return 0


def file_renames(rows, root, args, in_area, P):
    todo = []
    for r in rows:
        if r["art"] != "Datei":
            continue
        s = r["schutz"].strip()
        if s != "nein" and not (args.soft and s.startswith("pruefen")):
            continue
        if r["kollision"].strip() != "nein" or "?" in r["neu"] or "?" in r["hinweis"] or not r["neu"] or r["alt"] == r["neu"]:
            continue
        isdir = "Verzeichnis" in r["hinweis"]
        if not isdir and not (r["alt"].endswith(".swift") or r["alt"].endswith(".kt")):
            continue
        if not in_area(r["alt"]):
            continue
        todo.append((r["alt"], r["neu"], isdir))
    todo.sort(key=lambda t: (-t[0].count("/"), t[0]))
    done = []
    use_git = os.path.isdir(os.path.join(root, ".git"))
    for alt, new, isdir in todo:
        a, n = os.path.join(root, alt), os.path.join(root, new)
        if not os.path.exists(a):
            continue
        if os.path.exists(n) and not (isdir and os.path.isdir(n)):
            P("  Datei: Ziel existiert schon, uebersprungen: %s -> %s" % (alt, new))
            continue
        if isdir and os.path.isdir(n):
            for junk in (".DS_Store",):
                jp = os.path.join(a, junk)
                if os.path.exists(jp):
                    os.remove(jp)
            try:
                os.rmdir(a)
                P("  Verzeichnis leer entfernt: %s" % alt)
            except OSError:
                P("  Verzeichnis nicht leer, Ziel existiert: %s -> %s" % (alt, new))
            continue
        P("  %s %s -> %s" % ("Verzeichnis" if isdir else "Datei", alt, new))
        done.append((alt, new))
        if args.apply:
            os.makedirs(os.path.dirname(n), exist_ok=True)
            if use_git:
                rc = subprocess.run(["git", "-C", root, "mv", alt, new], capture_output=True, text=True)
                if rc.returncode != 0:
                    P("  git mv fehlgeschlagen (%s): %s" % (alt, rc.stderr.strip()))
            else:
                os.rename(a, n)
    refs = referenzen(root, done)
    return done, refs


REF_FILES = re.compile(r"(^project\.yml$|\.gradle$|\.gradle\.kts$|^Package\.swift$|\.pbxproj$|^AndroidManifest\.xml$|\.plist$|\.sh$|\.ps1$|\.py$|\.xml$)")


def referenzen(root, moves):
    out = []
    if not moves:
        return out
    keys = []
    for alt, _ in moves:
        keys.append((alt, os.path.basename(alt)))
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS and not d.startswith("."))
        for fn in sorted(fns):
            if not REF_FILES.search(fn):
                continue
            p = os.path.join(dp, fn)
            try:
                with open(p, encoding="utf-8", errors="ignore") as f:
                    for i, line in enumerate(f, 1):
                        for alt, base in keys:
                            if alt in line or (base in line and "." in base):
                                out.append("%s:%d enthaelt %s" % (os.path.relpath(p, root), i, base))
                                break
            except OSError:
                pass
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Namensverzeichnis auf Swift/Kotlin anwenden (Standard: Trockenlauf)")
    ap.add_argument("--wurzel", dest="root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--tsv", dest="tsv")
    ap.add_argument("--zusatz", dest="extra")
    ap.add_argument("--schutz", dest="protect")
    ap.add_argument("--bereich", dest="area", nargs="+")
    ap.add_argument("--absichern", dest="secure", action="store_true")
    ap.add_argument("--dateien", dest="files", action="store_true")
    ap.add_argument("--anwenden", dest="apply", action="store_true")
    ap.add_argument("--offen", dest="blocked_file", default="offen.txt")
    ap.add_argument("--ohne-auto-schutz", dest="no_auto_protect", action="store_true")
    ap.add_argument("--weich", dest="soft", action="store_true", help="auch Zeilen mit schutz=pruefen: ...")
    ap.add_argument("--kurz", dest="brief", action="store_true", help="nur Zusammenfassung")
    return run(ap.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
