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

**Die zwei Teile des Patches wirken nur zusammen.** Wer einen davon allein
aufspielt, sieht keine Änderung und hält die Ursache für falsch — genau das ist
uns beim Suchen passiert. Die Begründung steht vollständig in der
Commit-Nachricht des Patches.

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
