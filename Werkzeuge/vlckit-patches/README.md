# Änderungen an VLCKit

Swiftly liefert eine **geänderte** Fassung von VLCKit aus. Die LGPL verlangt
dafür, dass die Änderungen offenliegen — deshalb steht der Patch hier und
nicht nur auf einem Rechner.

| | |
|---|---|
| Grundlage | VLCKit **4.0.0-a23** |
| VLC-Stand | der von VLCKit gepinnte `TESTEDHASH` |
| Patch | `0028-mkv-allow-index_range-without-fastseek-and-never-cla.patch` |

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
