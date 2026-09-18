# Änderungen an VLCKit

Swiftly liefert eine **geänderte** Fassung von VLCKit aus. Die LGPL verlangt
dafür, dass die Änderungen offenliegen — deshalb steht der Patch hier und
nicht nur auf einem Rechner.

| | |
|---|---|
| Grundlage | VLCKit **4.0.0-a23** |
| VLC-Stand | der von VLCKit gepinnte `TESTEDHASH` |
| Patches | `0028-mkv-…`, `0030-vout-clock-…`, `0031-ios-…`, `0032-input_clock-…`, `VLCKit-pause-ohne-warteschlange.patch` |

## Wofür

Eine Matroska, deren Cues sich nicht auswerten lassen, war über HTTP nicht
vorwärts spulbar: jeder Sprung landete am Dateianfang, und der Demuxer las
sich von dort zur Zielstelle vor — bei einer 718-MB-Datei 30 bis 90 Sekunden.
VLC 3 spielt dieselbe Datei aus derselben Quelle und springt sofort.

**Die zwei Teile sind unabhängig, und nur einer ist belegt.** Gewirkt hat
Teil 2 — `index_range()` ohne `b_fastseekable`. Teil 1 (`b_cues` nicht setzen,
wenn nichts geladen wurde) löst bei der gemessenen Datei gar nicht aus: ihre
Cues brechen zwar am `EBMLCrc32` ab, aber vorher werden genug Punkte geladen,
dass der Index nicht leer ist. Der Teil ist für sich vertretbar, behebt aber
nichts Gemessenes.

Hier stand vorher, die beiden wirkten „nur zusammen". Das war falsch und kam
so zustande: der Bau, an dem Teil 2 allein geprüft wurde, enthielt ihn
höchstwahrscheinlich gar nicht — das Bauskript setzt den VLC-Baum bei jedem
Lauf zurück, und der Patch lag damals von Hand auf dem Baum. Geprüft wurde mit
Zeitstempeln, und die belegen nur, **dass** neu übersetzt wurde, nicht
**womit**. Widerlegt hat es die iOS-Sitzung: mit beiden Teilen springt die
Datei sofort, und die Warnzeile aus Teil 1 taucht im Protokoll nie auf.

## Anwenden

Der Patch gehört in VLCKits eigenes Patchverzeichnis, nicht auf den
ausgecheckten VLC-Baum. Das Bauskript macht bei **jedem** Lauf

```sh
git reset --hard ${TESTEDHASH} && git am libvlc/patches/*.patch
```

Ein von Hand aufgelegter Patch überlebt das nicht.

```sh
cp Werkzeuge/vlckit-patches/0028-*.patch <VLCKit>/libvlc/patches/
cd <VLCKit> && ./compileAndBuildVLCKit.sh -t -f    # tvOS
```

Das Bauskript verträgt **keine Leerzeichen im Pfad**.

## Ziel

Der Patch gehört zu VideoLAN eingereicht. Sobald er dort ist, können wir
wieder auf die offiziellen Fassungen zurück.

## Pause greift sofort — drei Patches, alle gemessen

Gemeldet auf dem Mac, betrifft aber jede Plattform: zwischen dem Druck auf
Pause und dem stehenden Bild vergingen bis zu **125 Millisekunden**. Bei
120 Hz sind das rund vierzehn Bilder.

**Erst gemessen, dann gepatcht** — und das hat einen Baulauf gespart: der
erste Verdacht galt `ControlPause` in `src/input/input.c`. Eingebaute
Wegmarken zeigten, dass der ganze Abschnitt dort **157 bis 216 Mikrosekunden**
braucht. libvlcs Pausepfad war nie das Problem.

| Abschnitt | vorher | Abhilfe |
|---|---|---|
| VLCKit reiht `pause` in eine serielle Schlange | 17–25 ms | `VLCKit-pause-ohne-warteschlange.patch` |
| libvlc: Befehl bis Uhren stehen | 0,2 ms | — nichts zu tun |
| Uhr weckt Wartende beim Pausieren nicht | bis 41 ms | `0030`, erste Hälfte |
| Anzeigeschleife wartet `VOUT_REDISPLAY_DELAY` (80 ms) | bis 80 ms | `0030`, zweite Hälfte |

Danach: Pause und Fortsetzen greifen nach etwa einem Bild.

### VLCKit-Patch, nicht libvlc

`VLCKit-pause-ohne-warteschlange.patch` fasst `Sources/Playback/VLCMediaPlayer.m`
an und liegt damit **nicht** in `libvlc/patches/` — das Bauskript setzt nur
den vlc-Baum zurück, VLCKits eigene Quellen überleben. Er muss deshalb von
Hand aufgelegt werden. **Vor jedem Bau prüfen**, dass er drin ist; sonst
fehlt er unbemerkt, und genau diese Sorte Fehler hat beim `0028`-Durchgang
schon einmal eine Stunde gekostet.

`play` bleibt absichtlich auf der Schlange, **außer** beim Fortsetzen aus der
Pause: der erste Start öffnet das Medium und kann ans Netz gehen, der darf
den Aufrufer nicht blockieren.

## Gemessene Bauzeiten

Auf einem MacBook Pro (M1 Pro, 10 Kerne), contribs bereits gebaut:

| Lauf | Dauer |
|---|---|
| macOS, jeder weitere Lauf | **4–5 min** |
| iOS + Simulator, Release | **7 min** |
| tvOS + Simulator, Release | **4,5 min** |

Gemessen in der Nacht zum 3.9., alle drei nacheinander, contribs vorhanden.
Ein voller Durchgang über alle drei Plattformen ist damit rund eine
Viertelstunde — nicht die Stunden, mit denen wir geplant hatten.

Ein Bau ohne `-r` ist ein **Debug**-Bau, und darin bricht der OpenGL-Ausgang
mit `Assertion failed: (!"GL_INVALID_OPERATION") … vout_helper.c:164` ab. Der
Fehler steckt auch in der ausgelieferten Fassung, dort ist die Zusicherung nur
wegkompiliert. Zum Messen also **immer `-r`**.

## Bekannt und nicht behoben: Flackern beim Ziehen am Fensterrand

Nur macOS, nur beim Ziehen, **älter als diese Patches** — eine Fassung ohne
sie flackert identisch. `reshape` in `modules/video_output/macosx.m` führt nur
die Maße nach und löst kein Neuzeichnen aus; bis das nächste Bild kommt, zeigt
der Fensterserver den alten, anders skalierten Puffer. Im pausierten Zustand
kommt nie eines, deshalb ist es dort am schlimmsten.

VLCs eigene Gegenmaßnahme steht in `renewGState` — und ihr eigener Kommentar
sagt, dass `disableScreenUpdatesUntilFlush` **seit macOS 10.13 ein Nichtstuer**
ist.

Ein Versuch, in `reshape` bei `inLiveResize` synchron mit `[self display]`
neu zu zeichnen, **wurde verworfen**: das Flackern war weg, dafür lief das
Ziehen mit rund zwei Bildern je Sekunde. `reshape` feuert beim Ziehen dutzende
Male je Sekunde, und jeder Aufruf malt das ganze Bild und wartet auf den
Puffertausch. Die richtige Abhilfe wäre, beim Ziehen etwas **Billiges** zu
zeichnen — genau das, wozu Apples Dokumentation bei `inLiveResize` rät.

## Vor dem Ausliefern einmal **ohne** `-r` bauen

Zum Messen ist `-r` Pflicht (siehe oben). Vor dem Ausliefern gehört ein Patch
aber genau einmal **ohne** gebaut und gestartet — sonst liefern wir Code aus,
dessen Zusicherungen nie gelaufen sind.

Zweimal in einer Nacht hat das etwas verdeckt:

- Der OpenGL-Ausgang bricht beim Öffnen des Players mit
  `Assertion failed: (!"GL_INVALID_OPERATION") … vout_helper.c:164` ab. Der
  Fehler steckt auch in der ausgelieferten Fassung, dort ist die Zusicherung
  nur wegkompiliert. Er ist damit nicht behoben, sondern unbeobachtet.
- Ein erster Entwurf von `0031` entfernte den `WillResignActive`-Zweig, liess
  aber die **Anmeldung auf die Meldung** stehen. Sie fiel damit in den
  `else`-Zweig, der auf `assert(… DidBecomeActive …)` endet. Im Debug ein
  Abbruch beim Aufziehen der Mitteilungszentrale, im Release still
  `_appActive = YES` — beim *Verlassen* des aktiven Zustands, also falsch
  herum und unsichtbar.

Daraus die Regel, die dabei entstanden ist: **wer eine Meldung nicht
behandelt, soll sie auch nicht bestellen.** Der Debug-Bau ist die Stelle, an
der so etwas auffällt.


## Uhrspruenge: die App starb an einer Datei mit weiten Zeitstempeln

`0032-input_clock-raise-CR_MAX_GAP-back-to-60-seconds.patch`

Eine Folge auf Pauls Server hat die App auf dem Apple TV nach rund zwei
Minuten umgebracht. Kein Absturz — das Geraet hatte keinen Bericht —, sondern
verbrannter Prozessor.

**Gemessen im Geraeteprotokoll:**

```
clock gap, unexpected stream discontinuity: system_diff: 34 stream_diff: 320666
feeding synchro with a new reference point trying to recover from clock gap
new clock context(1) … (2642)
```

5276 davon in 72 Sekunden, 35 bis 70 neue Uhrkontexte je Sekunde. Ueber 2638
Stichproben: `stream_diff` min 303 ms, Median 490 ms, max 1001 ms — **jeder
einzelne Wert knapp ueber der Schwelle von 300 ms**.

**Es lag nicht an der Datei allein.** Neun Titel im Protokoll, sechs davon
stundenlang: null Uhrspruenge. Nur diese eine. Und dieselbe Datei laeuft in
Swiftfin auf demselben Apple TV — das sitzt auf VLCKit **3**.

Das war der Hinweis. In VLC 4 hat `input_clock: finer discontinuity handling`
`CR_MAX_GAP` von **60 Sekunden auf 300 ms** gesenkt, zusammen mit einem
besseren Vergleich: ein grosser `stream_diff` ist in Ordnung, solange
`system_diff` mitwaechst.

Der Vergleich gilt aber nur, wenn die Quelle ihr eigenes Tempo bestimmt.
Bestimmen **wir** es — eine Datei ueber HTTP —, liest der Demuxer so schnell
er kann, `system_diff` ist praktisch null, und jeder Zeitstempelabstand ueber
300 ms gilt als Bruch. Die Uhr setzt dann bei jeder Aktualisierung ihren
Bezugspunkt neu.

Der Patch hebt die Schwelle zurueck auf 60 Sekunden. Der verbesserte
Vergleich bleibt, und `stream_diff < 0` faengt echte Rueckspruenge weiterhin
ab, unabhaengig von diesem Wert.

**Gehoert zu VideoLAN gemeldet** — der Fall trifft jeden Client, der Dateien
ueber HTTP abspielt, nicht nur uns.
