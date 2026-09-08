# Swiftly für Jellyfin Web

Ein Thema, das die Jellyfin-Weboberfläche auf das Erscheinungsbild von
Swiftly bringt — genauer: auf das der **macOS-Fassung**. Gleiche Maus,
gleiches Fenster, gleicher Schwebezustand.

Damit sieht der Browser aus wie die App auf dem Mac, dem iPhone, dem
iPad und dem Fernseher.

---

## Einbauen — eine Zeile

**Einstellungen → Anzeige → Benutzerdefiniertes CSS** (gilt nur für dich)
oder **Dashboard → Allgemein → Branding → Benutzerdefiniertes CSS** (gilt
für alle am Server). Dort hinein, ganz nach oben:

```css
@import url("https://cdn.jsdelivr.net/gh/paulherter/swiftly-player@main/Jellyfin-Theme/swiftly.css");
```

Speichern, Seite neu laden. Fertig.

> **Vorher das alte Thema herausnehmen.** Steht in demselben Feld schon
> ein `@import` — auf `tv.paulherter.de` war es am 08.09.2026
> **ElegantFin**, server-weit unter Dashboard → Allgemein —, dann muss
> diese Zeile weg. Zwei Themen uebereinander kaempfen um jede Farbe, und
> wer gewinnt, haengt an der Reihenfolge der Regeln. Eine Zeile ersetzen,
> nicht eine dazuschreiben.

**Warum jsDelivr und nicht `raw.githubusercontent.com`.** GitHub liefert
Rohdateien als `text/plain` aus, und ein `@import` mit falschem Inhaltstyp
wird vom Browser stillschweigend verworfen — die Zeile steht dann da und
tut nichts. jsDelivr liefert `text/css`.

**Wer nichts von außen laden will**, fügt stattdessen den Inhalt von
[`swiftly.css`](swiftly.css) direkt in dasselbe Feld ein. Gleiches
Ergebnis, keine fremde Adresse, aber kein selbsttätiges Nachziehen.

> jsDelivr hält `@main` rund zwölf Stunden vor. Nach einer Änderung im
> Repo dauert es also bis zu einem halben Tag, bis sie ankommt.

### Wieder loswerden

Die Zeile löschen und speichern. Es wird nichts am Server verändert —
das Thema ist nur ein Stilblatt.

---

## Wogegen es geprüft ist

Jellyfin **10.11** (`jellyfin-web` 10.11). Die Klassennamen sind nicht
geraten: sie stammen aus den ausgelieferten Stilblättern des Servers,
alle 143 Stücke heruntergeladen und durchsucht. Ältere Fassungen sollten
weitgehend passen — 10.11 hat mit der MUI-Palette (`--jf-palette-*`)
aber einen Teil der Farben umgestellt, und genau die nutzt dieses Thema.

Das Thema setzt auf **Dunkel** auf. In den Anzeige-Einstellungen sollte
„Dark" als Thema stehen; alles andere kämpft dagegen.

---

## Was übernommen ist

Die Werte stammen nicht aus dem Augenmaß. Jede Zahl steht so im Code der
App — die Quelle ist im Stilblatt an der jeweiligen Stelle vermerkt.

| Aus GESTALTUNG.md | Was im Web daraus wird |
|---|---|
| **A · Farbe** | `grund` `#0B0B0D`, `flaeche` `#161619`, `erhoeht` `#1E1E22`, Akzent `#5CD1C2`, Warnung `#E8833A`, Schrift weiß / 62 % / 38 %, Haarlinie 7 %, Rand 12 % |
| **A · Der Akzent trägt nie eine Fläche** | Auswahl in der Seitenleiste färbt Schrift und Zeichen, darunter liegen 10 % Akzent — keine gefüllte Zeile mehr |
| **B · Eckenskala** | 10 Knöpfe/Kacheln/Plakate · 12 Felder · 16 Blätter und Tafeln · Kapsel für Chips · 9 Kachelmarke · 8 Plakette |
| **C · Schrift** | SF Pro, wo es sie gibt; 28/20/17/15/14/12/11/10 mit den Schnitten und Sperrungen der App |
| **C · Köpfe sind linksbündig** | Auch Blattrubriken und Reihentitel |
| **D · Kein Glas** | Die Kopfleiste ist deckend in `grund` mit einer Haarlinie; über einem Bild steht stattdessen der schwache Verlauf 0,7 → 0 des `Detailkopf` |
| **E · Bewegung** | Schweben 0,12 s · Umschalten 0,10 s · Einblenden 0,28 s easeInOut · Seitenwechsel 0,18 s — und `prefers-reduced-motion` schaltet alles ab |
| **E · Nichts erscheint hart** | Bilder blenden mit `einblenden` ein statt mit Jellyfins 0,5 s |
| **F · Blätter** | Dialoge in `flaeche`, Ecke 16, Haarlinienrand; der Schleier steht auf 0,55 wie in der App |
| **G · Kein Ladering** | Der seitenweite Ring ist weg; an seiner Stelle pulsiert die Kachelfläche in der Form dessen, was kommt |
| **H · Drei Zustände, drei Zeichen** | Plakette weiß auf Dunkel mit Haarlinienrand statt Akzentkreis; Fortschritt 3 px Akzent in der Maske |
| **I · Chips** | Kapsel mit Haarlinie, aktiv weiß mit dunkler Schrift — dieselbe Form wie der Hauptknopf, eine Nummer kleiner |
| **I · Ein gefüllter Knopf je Seite** | Der Hauptknopf ist weiß auf dunkler Schrift, 48 hoch; alles daneben ist Weiß 14 % oder ein nacktes Zeichen |
| **Detailseite** | Titel 34 fett, Sperrung −0,8; Aktionsknöpfe als Kreis 44 mit Beschriftung darunter in 11 auf 75 % |
| **Die Kulisse** | Das Hintergrundbild bekommt die Doppelmaske aus `Kulissenblende` — rechts stehend, nach links und unten auslaufend, wie auf dem Mac und dem Fernseher |
| **Der Schalter** | Kapsel 38 × 22 mit Knopf 16, Akzent wenn an, Knopf dann dunkel — Jellyfins Häkchen wird zum Swiftly-Schalter |
| **Die React-Seiten** | Anmeldung und Teile des Dashboards baut 10.11 mit MUI. Sie ziehen ihre Farben aus derselben Palette; die Formen, die MUI selbst mitbringt, sind auf die Eckenskala gebracht |

---

## Drei Stellen, an denen bewusst abgewichen ist

**Rollbalken bleiben sichtbar.** Die App blendet sie ganz aus, weil macOS
sie einblendet, sobald man scrollt. Im Browser gibt es das nicht, und eine
Maus ohne Rad hätte dann nichts zum Greifen. Sie sind stattdessen schmal
und in Weiß 18 % — so nah an macOS wie es geht.

**Der Ladering ist ausgeschaltet, nicht ersetzt.** GESTALTUNG G verlangt
ein Ladefeld in der Form des kommenden Inhalts. Das kann ein Stilblatt
nicht bauen — es kann nur färben, was da ist. Die Kacheln, die Jellyfin
ohnehin schon anlegt, pulsieren deshalb; der seitenweite Ring fällt weg.
Wer ihn zurück will, kommentiert im Stilblatt den Block `.docspinner` aus.

**Kein Bild-im-Bild und keine Direct-Play-Auskunft.** Beides ist Verhalten,
kein Aussehen. Ein Thema kann dem Web nicht beibringen, was der Player der
App tut.

---

## Grenzen

Ein Thema färbt und formt, was die Weboberfläche ohnehin zeichnet. Was es
**nicht** kann:

- **Den Aufbau ändern.** Jellyfin stellt die Merkliste woanders hin als
  Swiftly, hat keine Reihe „Nächste Folge" und keine Staffelwahl als
  Überschrift. Das bleibt so.
- **Fehlende Bausteine nachliefern.** Kein Technikschild, keine
  Übernahmezeile, kein Seerr-Block.
- **Die Bewegungen der App nachbauen.** Federn mit Dämpfung 0,86 gibt es
  in CSS nicht; die Zeiten und Kurven sind so nah wie möglich gewählt,
  aber es sind Kurven, keine Federn.

---

## Ändern

Alles Wichtige steht als Variable ganz oben in `swiftly.css` unter
`:root` — Farben, Ecken, Zeiten. Wer den Akzent anders will, ändert dort
`--sw-akzent` **und** `--sw-akzent-kanal` (dieselbe Farbe als drei Zahlen,
für die Stellen, an denen Jellyfin sie mit einer eigenen Deckkraft
mischt).

---

Teil von [Swiftly](https://github.com/paulherter/swiftly-player).
Lizenz wie das Hauptprojekt.
