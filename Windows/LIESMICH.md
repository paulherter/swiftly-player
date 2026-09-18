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
| `Startanimation.swift` | Platzhalter ohne rlottie | für Windows ist rlottie noch nicht gebaut |
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
```

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

- **Medientasten und die Wiedergabekachel.** Unter Linux macht das
  ``Medienleiste`` über MPRIS; Windows hat dafür die *System Media Transport
  Controls*, und die gibt es nur über WinRT. Der Code steigt ohne Sitzungsbus
  schon von selbst still aus, die App läuft also — sie meldet sich nur nicht
  beim System an.
- **Keine automatischen Updates.** Linux bekommt sie über die Paketquelle;
  für Windows gibt es bisher nur den Installer.
