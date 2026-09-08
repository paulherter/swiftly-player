# Swiftly für Windows

Dieselbe Oberfläche wie unter Linux — nicht eine zweite.

## Warum GTK4 und nicht Win32

GTK4 gibt es für Windows als MSVC-Bau, samt `pkg-config.exe` und den
`.pc`-Dateien: **gvsbuild**. Damit spricht der Windows-Bau dieselbe
C-Schnittstelle an wie der Linux-Bau, und die 8 900 Zeilen der Oberfläche
gelten für beide.

Der Gegenentwurf wäre Win32 mit Direct2D gewesen. Er hätte nichts eingebracht:
die App zeichnet ohnehin fast alles selbst — Kacheln, Regler, Sprungzeichen,
den ganzen Player —, weil das Design auf allen Plattformen gleich sein soll.
„Nativ aussehen" ist hier kein Ziel, das die Mühe rechtfertigt; identisch
aussehen ist eines.

## Wie der geteilte Quelltext hierher kommt

Er liegt genau einmal im Repo, unter `Linux/Sources/SwiftlyLinux`.

SwiftPM erlaubt keine Ziele ausserhalb des Paketverzeichnisses — nachgemessen,
die Meldung lautet *„target … is outside the package root"*. Also spiegelt
`bauen.ps1` die Dateien vor jedem Bau nach `Sources/SwiftlyWindows`, und die
Spiegelung ist gitignoriert. Im Repo gibt es keine zweite Fassung, die
auseinanderlaufen könnte.

Was sich zwischen den Plattformen unterscheidet, steht als `#if` **in diesen
geteilten Dateien** — nicht in einer Kopie:

| Wo | Was | Warum |
|---|---|---|
| `Plattform.swift` | Binärpfad, Ort der Mittel, Einstellungsordner | `/proc/self/exe` und `XDG_CONFIG_HOME` gibt es hier nicht |
| `Zeichenwerk.swift` | `.desktop`-Eintrag nur auf Linux | Wayland nimmt das Fenstersymbol aus der Datei; Windows nicht |
| `Speicher.swift` | Unix-Rechte nur auf Linux | `%APPDATA%` ist über die Zugriffsliste ohnehin privat |
| `Abspieler.swift` | `--no-xlib` weg, `VLC_PLUGIN_PATH` gesetzt | libVLC findet seine Module hier nicht von selbst |
| `bildbruecke.c` | SRWLOCK statt pthread | `pthread` gibt es unter MSVC nicht |
| `Stil.swift` | Segoe UI in der Schriftkette | ohne `#if`: was ein System nicht hat, überspringt es |

## Was auf dem Rechner liegen muss

| | Ort | Woher |
|---|---|---|
| GTK4 (MSVC) | `C:\Werkzeuge\gtk4` | [gvsbuild-Release](https://github.com/wingtk/gvsbuild/releases), `GTK4_Gvsbuild_*_x64.zip` |
| libVLC-SDK | `C:\Werkzeuge\vlcsdk` | `vlc-3.0.21-win64.7z`, Ordner `sdk` |
| libVLC-Laufzeit | `C:\Werkzeuge\vlc\vlc-3.0.21` | `vlc-3.0.21-win64.zip` |
| Build Tools | — | `vs_BuildTools.exe --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64` |
| Swift | — | swift.org, Windows-Installer |

Andere Orte gehen auch; `bauen.ps1` nimmt sie als Parameter.

## Bauen

```powershell
.\bauen.ps1            # bauen
.\bauen.ps1 -Starten   # bauen und starten
.\bauen.ps1 -Symbole   # zusaetzlich eine PDB erzeugen
```

**`-Symbole`, wenn etwas abstuerzt.** Ohne Debug-Informationen entsteht keine
PDB, und das Windows-Ereignisprotokoll meldet einen Absturz nur als Versatz
in der Binaerdatei. Mit PDB laesst er sich aufloesen:

```powershell
# Versatz aus dem Ereignis („Fault offset") plus Bildbasis 0x140000000
'0x1401b1f84' | & llvm-symbolizer.exe --obj=.build\debug\SwiftlyWindows.exe --demangle
```

Genau so wurde am 05.09.2026 der Startabsturz gefunden, der jeden dritten bis
vierten Start traf: `rlottie::Animation::renderSync` auf freigegebenem
Speicher. Sieben Vermutungen davor waren alle falsch — die PDB hat es in
einem Durchgang beantwortet.

## Die Pakettests laufen hier

```powershell
cd ..\Packages\JellyfinKit
swift test
```

**194 Tests in 35 Suiten, alle gruen** (05.09.2026, `908a097`). Das ist mehr
als eine Formalie: `JellyfinKit` ist damit auf einer dritten Plattform
*belegt* und nicht nur uebersetzt. Wer Logik ins Paket hebt, statt sie in die
Ansicht zu schreiben, kann sie hier ohne Oberflaeche pruefen — auf Windows
genauso wie auf dem Mac.

Das Skript spiegelt die geteilten Quellen, baut, und legt anschliessend GTK,
libVLC und **VLCs Module** neben das Programm. Das letzte ist kein Beiwerk:
Windows sucht DLLs neben der ausführbaren Datei, nicht über einen Suchpfad,
und ohne die Module startet der Abspieler ohne einen einzigen Dekoder.

## Ausliefern

```powershell
.\bauen.ps1 -Konfiguration release
.\Installieren\packen.ps1
& "C:\Program Files\Inno Setup 7\ISCC.exe" .\Installieren\Swiftly.iss
```

Heraus kommt `Ablage\Swiftly-1.0.0-Setup.exe` — rund 80 MB, aus 356 MB Ablage.
Der Installer legt Startmenü-Eintrag, wahlweise Desktop-Symbol und eine
Deinstallation an; ohne Adminrechte installiert er in den eigenen Ordner, mit
in „Programme".

**Er ist nicht signiert.** Windows zeigt beim ersten Start eine
SmartScreen-Warnung. Das lässt sich nur mit einem gekauften Zertifikat
abstellen, nicht durch etwas im Skript.

## Was noch fehlt

- **Die Wiedergabekachel im Infobereich.** Die Medientasten der Tastatur
  gehen (`8544ab0`); die Kachel mit Titel und Bild braucht die *System Media
  Transport Controls* und damit WinRT — eigener Vorgang.
- **Keine automatischen Updates.** Linux bekommt sie über die Paketquelle;
  für Windows gibt es bisher nur den Installer.

## Wenn Windows in einer VM läuft

Auf dem Entwicklungsrechner ist Windows eine libvirt-VM auf dem Linux-Host
(`swiftly-win`). Sie hat **keinen geteilten Ordner** — nur CD-ROMs, und die
gehen nur in eine Richtung. Übrig bleibt QEMUs Nutzernetz: der Wirt ist im
Gast unter `10.0.2.2` erreichbar.

```bash
Windows/Werkzeuge/bruecke.sh ~/swiftly    # packen, ausliefern, bauen lassen
```

Der Wirt stellt die Quellen hin, tippt **eine** Zeile in ein frisches
PowerShell-Fenster, und die VM holt sich den Rest selbst. Das Ergebnis kommt
über `virsh screenshot` zurück.

**Warum ein frisches Fenster.** `virsh send-key` tippt dorthin, wo die
Tastatur gerade hinzeigt, und das sieht man von außen nicht. Zweimal ist ein
Befehl in irgendeinem vorderen Fenster gelandet und dort stillschweigend
verschwunden; aufgefallen ist es erst, als ein `Test-Path` zeigte, dass nie
etwas angekommen war. `Win+R` führt immer zu demselben bekannten Zustand.

**Zwei Regeln für jede `.ps1`, die dorthin geht** — beide haben je einen
Fehlversuch gekostet:

- **Nur ASCII.** PowerShell 5.1 liest eine UTF-8-Datei ohne BOM als ANSI.
  Ein Gedankenstrich wird zu drei Zeichen und zerlegt den String, in dem er
  steht — der Parser meldet den Fehler dann an einer Stelle, an der nichts
  falsch ist. Dieselbe Falle trifft `Select-String`: ein Muster mit Umlaut
  findet eine Zeile nicht, die dasteht. Das sah einmal wie ein fehlendes
  Übersetzungsbündel aus und war keines. Wer Dateiinhalte prüft, gibt
  `-Encoding UTF8` mit.
- **Nichts nach `C:\` schreiben.** Ohne Administrator ist die Wurzel nicht
  beschreibbar; `-OutFile C:\x` bricht mit „Access to the path is denied"
  ab. Alles unter `$env:USERPROFILE`.
