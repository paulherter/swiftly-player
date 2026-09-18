#!/bin/bash
# Sucht Funktionen, die in mehreren Dateien fast oder ganz gleich dastehen.
#
# **Das Skript sagt, WO nachzusehen ist — nicht, WAS dort steht.** Jeder
# Treffer ist ein Hinweis, kein Urteil. Wer die Ausgabe als Befund liest
# und danach handelt, ohne die Stellen aufzuschlagen, macht denselben
# Fehler wie beim Abhaken von Aenderungen.md: die Liste sagt *dass*
# etwas ist, nicht *wie*.
#
# **Warum ueber die Struktur und nicht ueber grep.** „Eine kopierte Funktion
# ist ein Fehler" steht in CLAUDE.md, geprueft wurde es bisher mit Augen. So
# ist `nachladen()` durchgerutscht: einmal in Shared/HauptView.swift, einmal
# fast zeichengleich in tvOS/BibliothekView.swift — und beim Herausziehen
# zeigte sich, dass die Fassungen laengst auseinandergelaufen waren. Auf tvOS
# stand bei Serien „0 Min.", weil die Pruefung `sekunden > 0` fehlte.
#
# **Namensgleichheit allein taugt nicht.** `body()` und `makeBody()` stehen in
# jeder zweiten Datei, weil SwiftUI sie verlangt — ein erster Lauf meldete 28
# solche Gruppen, alle harmlos. Massgeblich ist deshalb die Aehnlichkeit der
# Ruempfe, nicht der Name. Zwei Faelle, und der zweite ist der schlimmere:
#
#   gleich       Zeichen fuer Zeichen dieselbe Funktion — gehoert nach Shared
#   auseinander  erkennbar dieselbe Funktion, aber schon abgedriftet. Genau
#                der nachladen()-Fall. Sieht nach Absicht aus, ist meist keine.
#
#   Werkzeuge/doppelte-finden.sh          beides
#   Werkzeuge/doppelte-finden.sh gleich   nur die exakten Kopien

set -u
cd "$(dirname "$0")/.." || exit 1
command -v ast-grep >/dev/null || { echo "ast-grep fehlt: brew install ast-grep"; exit 1; }

ast-grep run -p 'func $NAME($$$A) { $$$B }' -l swift --json=compact Sources Packages 2>/dev/null \
| python3 -c '
import json, sys, re, collections, difflib

was = sys.argv[1] if len(sys.argv) > 1 else "beides"
gruen, rot, gelb, grau, aus = "\033[32m", "\033[31m", "\033[33m", "\033[90m", "\033[0m"

# Was Rahmenwerke verlangen, ist keine Kopie.
VORGESCHRIEBEN = {
    "body", "makeBody", "makeCoordinator", "hash", "encode", "decode",
    "makeUIView", "updateUIView", "makeNSView", "updateNSView",
    "makeUIViewController", "updateUIViewController",
    "makeNSViewController", "updateNSViewController",
    "sizeThatFits", "placeholder", "snapshot", "timeline", "getSnapshot",
    "getTimeline", "dismantleUIView", "dismantleNSView",
}
MINDESTLAENGE = 80          # Einzeiler sagen nichts
AEHNLICH      = 0.60        # darunter sind es zufaellig gleichnamige Funktionen

def name(t):
    m = re.match(r"func\s+([A-Za-z_][A-Za-z0-9_]*)", t)
    return m.group(1) if m else None

def rumpf(t):
    ohne = re.sub(r"//[^\n]*", "", t)          # Kommentare zaehlen nicht mit
    return re.sub(r"\s+", " ", ohne).strip()

nach = collections.defaultdict(list)
gesamt = 0
for tr in json.load(sys.stdin):
    n = name(tr["text"])
    if not n or n in VORGESCHRIEBEN:
        continue
    gesamt += 1
    r = rumpf(tr["text"])
    if len(r) >= MINDESTLAENGE:
        nach[n].append((tr["file"], tr["range"]["start"]["line"] + 1, r))

gleich, drift = [], []
for n, stellen in sorted(nach.items()):
    if len({d for d, _, _ in stellen}) < 2:
        continue
    ruempfe = {r for _, _, r in stellen}
    if len(ruempfe) == 1:
        gleich.append((n, stellen, 1.0))
        continue
    paare = [(a, b) for i, a in enumerate(ruempfe) for b in list(ruempfe)[i + 1:]]
    naehe = max(difflib.SequenceMatcher(None, a, b).ratio() for a, b in paare)
    if naehe >= AEHNLICH:
        drift.append((n, stellen, naehe))

def zeigen(titel, farbe, gruppe, mit_naehe):
    print(f"{farbe}── {titel} ({len(gruppe)}){aus}")
    for n, stellen, naehe in sorted(gruppe, key=lambda g: -g[2]):
        zusatz = f"  {grau}{naehe:.0%} gleich{aus}" if mit_naehe else ""
        print(f"  {n}(){zusatz}")
        for d, z, _ in sorted(stellen):
            print(f"      {d}:{z}")
    if not gruppe:
        print(f"  {grau}nichts{aus}")
    print()

if was != "gleich":
    zeigen("Dieselbe Funktion, schon auseinandergelaufen", rot, drift, True)
zeigen("Wortgleich an mehreren Stellen — gehoert nach Shared", gelb, gleich, False)
print(f"{grau}{gesamt} Funktionen geprueft, {len(nach)} Namen ueber der Mindestlaenge.{aus}")
print(f"{grau}Das sagt, wo nachzusehen ist — nicht, was dort steht. Stellen aufschlagen.{aus}")
' "${1:-beides}"
