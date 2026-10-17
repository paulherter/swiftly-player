#!/usr/bin/env python3
"""Do the Codable types still read and write the keys they wrote before?

**Why this exists.** Swift derives JSON keys from property names, enum raw values
from case names, and the keys of a synthesized enum payload from case and label
names. Renaming an identifier therefore silently renames a stored or exchanged
key: the build stays green, tests that build their values in code stay green, and
a device loses its settings, its download index or its accounts on the next
start. It happened during the move to English identifiers, on Android (the replies
of the core) and on Linux (the settings file).

The script parses the Swift sources (no compiler needed) and computes, for every
type that matters on the wire, its effective key set:

- Codable structs and classes with synthesized coding: the `CodingKeys` raw
  values, otherwise the stored property names;
- every enum conforming to `CodingKey`: its raw values;
- every enum with `String` raw values: its raw values (also what UserDefaults and
  `@AppStorage` store);
- Codable enums without raw values: case names with payload labels.

It compares them with `Werkzeuge/codable-keys.tsv`. A recorded key that is gone is
an error. New keys and new types are fine; record them with `--update` once the
change is deliberate.

    Werkzeuge/codable-keys-check.py            check
    Werkzeuge/codable-keys-check.py --update   rewrite the list from the sources
"""
import collections, os, re, sys

KEYWORDS_TYPE = {"struct", "class", "enum", "actor", "extension", "protocol"}
NOT_TYPE_AFTER_CLASS = {"func", "var", "let", "subscript", "override", "final", "static",
                        "private", "fileprivate", "public", "internal", "open", "init", "required",
                        "convenience", "nonisolated", "lazy", "weak", "unowned", "mutating"}


def lex(src):
    """Return list of tokens (kind, text, line). kinds: id, str, punct, nl, num."""
    toks = []
    i, n, line = 0, len(src), 1

    def read_string(i, hashes):
        # src[i] is the first quote char; returns (value, end_index)
        multi = src.startswith('"""', i)
        q = '"""' if multi else '"'
        i += len(q)
        out = []
        close = q + '#' * hashes
        nl = 0
        while i < n:
            if src.startswith(close, i):
                return ''.join(out), i + len(close), nl
            c = src[i]
            if c == '\\' and src.startswith('#' * hashes, i + 1):
                j = i + 1 + hashes
                if j < n and src[j] == '(':
                    # interpolation: skip balanced parens, nested strings allowed
                    depth, k = 0, j
                    while k < n:
                        ch = src[k]
                        if ch == '"':
                            h = 0
                            m = k - 1
                            _, k, l2 = read_string(k, 0)
                            nl += l2
                            continue
                        if ch == '(':
                            depth += 1
                        elif ch == ')':
                            depth -= 1
                            if depth == 0:
                                k += 1
                                break
                        elif ch == '\n':
                            nl += 1
                        k += 1
                    out.append('\\(…)')
                    i = k
                    continue
                out.append(src[i:j + 1])
                i = j + 1
                continue
            if c == '\n':
                nl += 1
            out.append(c)
            i += 1
        return ''.join(out), i, nl

    while i < n:
        c = src[i]
        if c == '\n':
            toks.append(('nl', '\n', line)); line += 1; i += 1; continue
        if c in ' \t\r':
            i += 1; continue
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src.startswith('/*', i):
            depth, j = 0, i
            while j < n:
                if src.startswith('/*', j): depth += 1; j += 2; continue
                if src.startswith('*/', j):
                    depth -= 1; j += 2
                    if depth == 0: break
                    continue
                if src[j] == '\n': line += 1
                j += 1
            i = j
            continue
        if c == '#' or c == '"':
            m = re.match(r'#*', src[i:])
            h = len(m.group(0))
            if i + h < n and src[i + h] == '"':
                val, j, nl = read_string(i + h, h)
                toks.append(('str', val, line)); line += nl; i = j; continue
            if c == '#':
                m2 = re.match(r'#[A-Za-z_]\w*', src[i:])
                if m2:
                    toks.append(('id', m2.group(0), line)); i += len(m2.group(0)); continue
                toks.append(('punct', '#', line)); i += 1; continue
        if c.isalpha() or c == '_' or c == '$':
            m = re.match(r'[\w$]+', src[i:])
            toks.append(('id', m.group(0), line)); i += len(m.group(0)); continue
        if c == '`':
            j = src.find('`', i + 1)
            toks.append(('id', src[i + 1:j], line)); i = j + 1; continue
        if c.isdigit():
            m = re.match(r'[0-9][0-9_a-zA-Z.]*', src[i:])
            t = m.group(0).rstrip('.')
            toks.append(('num', t, line)); i += len(t); continue
        if c == '@':
            m = re.match(r'@[\w]+', src[i:])
            if m:
                toks.append(('attr', m.group(0), line)); i += len(m.group(0)); continue
        if src.startswith('->', i):
            toks.append(('punct', '->', line)); i += 2; continue
        toks.append(('punct', c, line)); i += 1
    return toks


class Parser:
    def __init__(self, toks, fname):
        self.t = toks
        self.f = fname
        self.types = []

    def match_close(self, i, op, cl):
        depth = 0
        while i < len(self.t):
            k, v, _ = self.t[i]
            if k == 'punct' and v == op: depth += 1
            elif k == 'punct' and v == cl:
                depth -= 1
                if depth == 0: return i
            i += 1
        return len(self.t) - 1

    def parse(self):
        self.block(0, len(self.t), None, [])
        return self.types

    def line_start(self, i):
        j = i - 1
        while j >= 0 and self.t[j][0] != 'nl' and not (self.t[j][0] == 'punct' and self.t[j][1] in '{};'):
            j -= 1
        return j + 1

    def modifiers_before(self, i):
        j = self.line_start(i)
        return [v for k, v, _ in self.t[j:i]]

    def block(self, i, end, typ, path):
        t = self.t
        while i < end:
            k, v, ln = t[i]
            if k == 'id' and v in KEYWORDS_TYPE:
                prev = t[i - 1] if i else ('nl', '', 0)
                nxt = t[i + 1] if i + 1 < end else ('nl', '', 0)
                is_decl = nxt[0] == 'id' and not (v == 'class' and nxt[1] in NOT_TYPE_AFTER_CLASS)
                if prev[0] == 'punct' and prev[1] in '.':
                    is_decl = False
                if v == 'protocol' and prev[0] == 'punct' and prev[1] in (':', ',', '&'):
                    is_decl = False
                if is_decl:
                    i = self.type_decl(i, end, typ, path)
                    continue
            if typ is not None and k == 'id' and v in ('let', 'var') and typ['kind'] != 'protocol':
                i = self.prop(i, end, typ)
                continue
            if typ is not None and k == 'id' and v == 'case' and typ['kind'] == 'enum':
                i = self.cases(i, end, typ)
                continue
            if typ is not None and k == 'id' and v == 'init':
                j = i + 1
                if j < end and t[j][1] in ('?', '!'): j += 1
                if j < end and t[j][1] == '(' and j + 1 < end and t[j + 1][1] == 'from':
                    typ['customDecode'] = True
            if typ is not None and k == 'id' and v == 'func' and i + 2 < end and t[i + 1][1] == 'encode' \
                    and t[i + 2][1] == '(' and t[i + 3][1] == 'to':
                typ['customEncode'] = True
            if k == 'punct' and v == '{':
                c = self.match_close(i, '{', '}')
                self.block(i + 1, c, None, path)
                i = c + 1
                continue
            i += 1

    def type_decl(self, i, end, outer, path):
        t = self.t
        kw = t[i][1]
        j = i + 1
        name_parts = [t[j][1]]
        j += 1
        while j + 1 < end and t[j][1] == '.' and t[j + 1][0] == 'id':
            name_parts.append(t[j + 1][1]); j += 2
        if j < end and t[j][1] == '<':
            depth = 0
            while j < end:
                if t[j][1] == '<': depth += 1
                elif t[j][1] == '>':
                    depth -= 1
                    if depth == 0: j += 1; break
                j += 1
        inherits = []
        if j < end and t[j][1] == ':':
            j += 1
            cur = []
            depth = 0
            while j < end and not (t[j][1] == '{' and depth == 0) and not (t[j][1] == 'where' and depth == 0):
                tv = t[j][1]
                if tv in '<(': depth += 1
                elif tv in '>)': depth -= 1
                if depth == 0 and tv in (',', '&'):
                    if cur: inherits.append(''.join(cur)); cur = []
                elif t[j][0] != 'nl':
                    if tv not in ('any',) and t[j][0] != 'attr':
                        cur.append(tv)
                j += 1
            if cur: inherits.append(''.join(cur))
        while j < end and t[j][1] != '{':
            j += 1
        if j >= end:
            return j
        close = self.match_close(j, '{', '}')
        if kw == 'extension':
            full = '.'.join(name_parts)
        else:
            full = '.'.join(path + name_parts)
        rec = {'path': full, 'file': self.f, 'kind': kw, 'inherits': inherits, 'props': [],
               'cases': [], 'customDecode': False, 'customEncode': False, 'line': t[i][2]}
        self.types.append(rec)
        self.block(j + 1, close, rec, full.split('.'))
        return close + 1

    def prop(self, i, end, typ):
        t = self.t
        mods = self.modifiers_before(i)
        static = 'static' in mods or ('class' in mods)
        is_let = t[i][1] == 'let'
        j = i + 1
        names = []
        stored = True
        # read bindings
        while j < end:
            if t[j][1] == '(':  # tuple pattern
                c = self.match_close(j, '(', ')')
                names += [v for k, v, _ in t[j + 1:c] if k == 'id']
                j = c + 1
            elif t[j][0] == 'id':
                names.append(t[j][1]); j += 1
            else:
                break
            # skip type annotation / initializer until comma at depth0, nl, or {
            depth = 0
            saw_eq = False
            while j < end:
                k, v, _ = t[j]
                if k == 'punct' and v in '([<':
                    if v == '<' and not (j > 0 and t[j - 1][0] == 'id'):
                        pass
                    depth += 1 if v != '<' else 0
                    if v == '<': depth += 1
                elif k == 'punct' and v in ')]>':
                    depth -= 1
                if k == 'punct' and v == '=' and depth <= 0:
                    saw_eq = True
                if k == 'punct' and v == '{' and depth <= 0:
                    c = self.match_close(j, '{', '}')
                    if not saw_eq and not is_let:
                        inner = [x for x in t[j + 1:c] if x[0] != 'nl']
                        if not inner or inner[0][1] not in ('willSet', 'didSet'):
                            stored = False
                    if saw_eq and c + 1 < end and t[c + 1][1] == '(':
                        c = self.match_close(c + 1, '(', ')')
                    j = c + 1
                    continue
                if k == 'nl' and depth <= 0:
                    # continuation if next line starts with operator or previous token is operator
                    nxt = j + 1
                    while nxt < end and t[nxt][0] == 'nl': nxt += 1
                    if nxt < end and t[nxt][0] == 'punct' and t[nxt][1] in '.?:+-*&|=' and t[j - 1][1] not in '{}':
                        j = nxt; continue
                    if t[j - 1][0] == 'punct' and t[j - 1][1] in '=,(+-*&|:[':
                        j = nxt; continue
                    break
                if k == 'punct' and v == ';' and depth <= 0:
                    break
                if k == 'punct' and v == '}' and depth <= 0:
                    break
                if k == 'punct' and v == ',' and depth <= 0:
                    break
                j += 1
            if j < end and t[j][1] == ',':
                j += 1
                continue
            break
        if not static and stored:
            lazy = 'lazy' in mods
            for nm in names:
                typ['props'].append({'name': nm, 'let': is_let, 'lazy': lazy,
                                     'init': False})
        return j

    def cases(self, i, end, typ):
        t = self.t
        j = i + 1
        while j < end:
            if t[j][0] != 'id':
                break
            c = {'name': t[j][1], 'raw': None, 'assoc': None}
            j += 1
            if j < end and t[j][1] == '(':
                close = self.match_close(j, '(', ')')
                # split params at depth-1 commas
                params, cur, depth = [], [], 0
                for k, v, _ in t[j + 1:close]:
                    if v in '([<': depth += 1
                    elif v in ')]>': depth -= 1
                    if v == ',' and depth == 0:
                        params.append(cur); cur = []
                    elif k != 'nl':
                        cur.append((k, v))
                if cur: params.append(cur)
                labels = []
                for idx, p in enumerate(params):
                    if len(p) >= 2 and p[0][0] == 'id' and p[1][1] == ':':
                        labels.append(p[0][1] if p[0][1] != '_' else '_%d' % idx)
                    elif len(p) >= 3 and p[0][1] == '_' and p[2][1] == ':':
                        labels.append('_%d' % idx)
                    else:
                        labels.append('_%d' % idx)
                c['assoc'] = labels
                j = close + 1
            if j < end and t[j][1] == '=':
                j += 1
                raw = []
                while j < end and t[j][1] not in (',',) and t[j][0] != 'nl' and t[j][1] != '}':
                    raw.append(t[j]); j += 1
                if raw and raw[0][0] == 'str':
                    c['raw'] = {'s': raw[0][1]}
                else:
                    c['raw'] = {'x': ''.join(x[1] for x in raw)}
            typ['cases'].append(c)
            if j < end and t[j][1] == ',':
                j += 1
                while j < end and t[j][0] == 'nl': j += 1
                continue
            break
        return j



ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIST = os.path.join(ROOT, 'Werkzeuge', 'codable-keys.tsv')
DIRS = {'Kit': 'Packages/JellyfinKit/Sources', 'Apple': 'Sources', 'Linux': 'Linux/Sources',
        'Android': 'Android/core/swift/Sources'}


def collect():
    types = []
    for module, rel in DIRS.items():
        base = os.path.join(ROOT, rel)
        for dp, dn, fn in os.walk(base):
            dn[:] = sorted(d for d in dn if not d.startswith('.') and d != 'build')
            for f in sorted(fn):
                if not f.endswith('.swift'):
                    continue
                p = os.path.join(dp, f)
                src = open(p, encoding='utf-8', errors='replace').read()
                for t in Parser(lex(src), os.path.relpath(p, ROOT)).parse():
                    t['module'] = module
                    types.append(t)
    return types


def effective(types):
    protos = {t['path'].split('.')[-1]: t['inherits'] for t in types if t['kind'] == 'protocol'}

    def conforms(name, want, seen=()):
        b = name.split('.')[-1].split('<')[0]
        if b in want:
            return True
        return b in protos and b not in seen and any(conforms(x, want, seen + (b,)) for x in protos[b])

    by_path = collections.defaultdict(list)
    extensions = collections.defaultdict(list)
    for t in types:
        by_path[(t['module'], t['path'])].append(t)
        if t['kind'] == 'extension':
            # an extension in the app may add conformance to a package type
            extensions[t['path']].append(t)

    def raws(rec):
        return [c['raw'].get('s', c['raw'].get('x')) if c['raw'] is not None else c['name']
                for c in rec['cases']]

    out = {}
    for t in types:
        if t['kind'] in ('extension', 'protocol'):
            continue
        recs = [t] + extensions[t['path']]
        inh = [i for x in recs for i in x['inherits']]
        enc = any(conforms(i, {'Codable', 'Encodable'}) for i in inh)
        dec = any(conforms(i, {'Codable', 'Decodable'}) for i in inh)
        synth = (enc and not any(x['customEncode'] for x in recs)) or \
                (dec and not any(x['customDecode'] for x in recs))
        codingkey = any(i.split('.')[-1] == 'CodingKey' for i in inh)
        rawtype = t['inherits'][0] if t['kind'] == 'enum' and t['inherits'] else None
        keys, kind = None, None
        if t['kind'] == 'enum':
            if rawtype == 'String' or codingkey:
                keys, kind = raws(t), ('codingkey' if codingkey else 'raw')
            elif synth and not rawtype:
                keys = [c['name'] + ('(' + ','.join(c['assoc']) + ')' if c['assoc'] else '')
                        for c in t['cases']]
                kind = 'cases'
        elif synth:
            ck = [x for x in by_path[(t['module'], t['path'] + '.CodingKeys')] if x['kind'] == 'enum']
            keys = raws(ck[0]) if ck else [p['name'] for x in recs for p in x['props']]
            kind = 'codable'
        if keys is None:
            continue
        name = t['path']
        if sum(1 for x in by_path[(t['module'], t['path'])] if x['kind'] != 'extension') > 1:
            name += '@' + os.path.basename(t['file'])
        out[(t['module'], name)] = (kind, sorted(set(keys)), t['file'], t['line'])
    return out


def main():
    current = effective(collect())
    if '--update' in sys.argv:
        with open(LIST, 'w', encoding='utf-8') as f:
            f.write('# module\ttype\tkind\tkeys -- written by Werkzeuge/codable-keys-check.py --update\n')
            for (module, name), (kind, keys, _, _) in sorted(current.items()):
                f.write(f"{module}\t{name}\t{kind}\t{','.join(keys)}\n")
        print(f'{len(current)} types recorded in {os.path.relpath(LIST, ROOT)}')
        return 0
    recorded = {}
    for line in open(LIST, encoding='utf-8'):
        if line.startswith('#') or not line.strip():
            continue
        module, name, kind, keys = line.rstrip('\n').split('\t')
        recorded[(module, name)] = (kind, keys.split(',') if keys else [])
    # A renamed type keeps its keys; it is found by them.
    sets = [(k[0], kind, set(keys)) for k, (kind, keys, _, _) in current.items()]
    errors, renamed = [], 0
    for k, (kind, keys) in sorted(recorded.items()):
        now = current.get(k)
        if now is None:
            if any(m == k[0] and kd == kind and set(keys) <= ks for m, kd, ks in sets):
                renamed += 1
            else:
                errors.append(f'{k[0]} {k[1]}: gone, and no type in {k[0]} carries its keys {keys}')
            continue
        missing = sorted(set(keys) - set(now[1]))
        if missing:
            errors.append(f'{k[0]} {k[1]} ({now[2]}:{now[3]}): keys gone: {missing}')
    new = [k for k in current if k not in recorded]
    if errors:
        print('Codable keys changed -- stored or exchanged data would no longer read:')
        for e in errors:
            print('   ', e)
        print('Keep the old key: `case newName = "oldKey"` in CodingKeys, `= "oldValue"` on an enum case.')
        print('Only if the change is deliberate: Werkzeuge/codable-keys-check.py --update')
        return 1
    extra = (f', {renamed} renamed' if renamed else '') + \
            (f', {len(new)} new not yet recorded (--update)' if new else '')
    print(f'{len(recorded)} types, all recorded keys still there{extra}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
