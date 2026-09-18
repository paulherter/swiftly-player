# Download-Seiten

Erzeugt die eigenständigen Seiten unter `Website/download/` und `Website/android/`.
Die Website liegt auf einfachem Webspace: **kein Bauschritt beim Ausliefern**, die
fertigen HTML-Dateien stehen im Repo und werden so hochgeladen.

```bash
cd Werkzeuge/download-seiten
python3 seite_appstore.py   # /download/app-store/
python3 seite_testflight.py # /download/testflight/
python3 seite_windows.py    # /download/windows/
python3 seite_linux.py      # /download/linux/
python3 seite_android.py    # /android/
```

`teile.py` hält alles, was alle fünf Seiten teilen: Kopf mit Meta-Angaben und
JSON-LD, Fuß, Skizzen mit Zeiger und Tippring, die Liste der anderen Plattformen.
Die drei CSS-Dateien sind Bausteine, keine ausgelieferten Dateien: `stil-grund.css`
(Farben, Schrift, Raster), `skizzen.css` (Zeichnungen), `verhalten.css` (die **eine**
Bewegung für Knöpfe und Karten — `--hebung`, `--dauer`, `--kurve`, plus
`prefers-reduced-motion`).

**Eine Änderung am Aufbau gehört in `teile.py`, nicht in eine der fünf Seiten.**
Sonst laufen sie auseinander. Nach jedem Lauf `git diff Website/` lesen: die
Skripte erzeugen die Seiten vollständig neu, Änderungen von Hand am HTML gehen
dabei verloren.
