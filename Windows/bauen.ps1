# Swiftly fuer Windows bauen.
#
#     .\bauen.ps1            bauen
#     .\bauen.ps1 -Starten   bauen und starten
#
# **Was hier passiert und warum.** Der Quelltext der Oberflaeche liegt genau
# einmal im Repo, unter `Linux/Sources/SwiftlyLinux`. SwiftPM erlaubt keine
# Ziele ausserhalb des Paketverzeichnisses, also wird er vor jedem Bau
# hereingespiegelt. Alles, was sich zwischen den Plattformen unterscheidet,
# steht als `#if os(Windows)` in diesen geteilten Dateien — es gibt keine
# zweite Fassung, die auseinanderlaufen koennte.

param(
    [switch]$Starten,
    [string]$Konfiguration = 'debug',
    [string]$Gtk = 'C:\Werkzeuge\gtk4',
    [string]$Vlc = 'C:\Werkzeuge\vlcsdk',
    [string]$VlcLaufzeit = 'C:\Werkzeuge\vlc\vlc-3.0.21',
    [string]$SwiftLaufzeit = 'C:\Swift\Runtimes\6.2.1\usr\bin',
    [string]$Rlottie = 'C:\Werkzeuge\rlottie'
)

$ErrorActionPreference = 'Stop'
$hier = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $hier 'umgebung.ps1')
$quelle = Join-Path (Split-Path -Parent $hier) 'Linux\Sources\SwiftlyLinux'
$ziel = Join-Path $hier 'Sources\SwiftlyWindows'

function Sag($t) { Write-Host "==> $t" -ForegroundColor Green }

# ------------------------------------------------------------- Spiegeln

Sag 'Geteilte Quellen spiegeln'
if (-not (Test-Path $quelle)) { throw "Quellen fehlen: $quelle" }
if (Test-Path $ziel) { Remove-Item -Recurse -Force $ziel }
New-Item -ItemType Directory -Force -Path $ziel | Out-Null
Copy-Item -Path (Join-Path $quelle '*.swift') -Destination $ziel
Copy-Item -Path (Join-Path $quelle 'Resources') -Destination $ziel -Recurse
Write-Host ("    " + (Get-ChildItem $ziel -Filter *.swift).Count + " Dateien")

# Die Bruecke zu VLC ist dieselbe C-Datei; nur die Modulzuordnungen
# unterscheiden sich, weil die Bindenamen anders lauten.
$bruecke = Join-Path $hier 'Sources\CBildbruecke'
if (Test-Path $bruecke) { Remove-Item -Recurse -Force $bruecke }
New-Item -ItemType Directory -Force -Path (Join-Path $bruecke 'include') | Out-Null
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CBildbruecke\bildbruecke.c') $bruecke
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CBildbruecke\include\bildbruecke.h') (Join-Path $bruecke 'include')

# Die Medientasten sind ebenfalls derselbe C-Code.
$tasten = Join-Path $hier 'Sources\CMedientasten'
if (Test-Path $tasten) { Remove-Item -Recurse -Force $tasten }
New-Item -ItemType Directory -Force -Path (Join-Path $tasten 'include') | Out-Null
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CMedientasten\medientasten.c') $tasten
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CMedientasten\include\medientasten.h') (Join-Path $tasten 'include')

# Symbol und Startanimation liegen genauso nur einmal im Repo.
$mittel = Join-Path (Split-Path -Parent $hier) 'Linux\Ressourcen'
$mittelZiel = Join-Path $hier 'Ressourcen'
if (Test-Path $mittelZiel) { Remove-Item -Recurse -Force $mittelZiel }
Copy-Item -Path $mittel -Destination $mittelZiel -Recurse

# ------------------------------------------------------------- Suchpfade
#
# GTK verteilt seine Kopfdateien auf ein Dutzend Verzeichnisse, und zwei davon
# liegen unter `lib`, nicht unter `include` — dort steht, was beim Bau der
# Bibliothek entschieden wurde (`glibconfig.h`, `graphene-config.h`).

$einschluesse = @(
    "$Gtk\include\gtk-4.0"
    "$Gtk\include\glib-2.0"
    "$Gtk\lib\glib-2.0\include"
    "$Gtk\include\cairo"
    "$Gtk\include\pango-1.0"
    "$Gtk\include\harfbuzz"
    "$Gtk\include\gdk-pixbuf-2.0"
    "$Gtk\include\graphene-1.0"
    "$Gtk\lib\graphene-1.0\include"
    "$Gtk\include\gio-win32-2.0"
    "$Gtk\include\fribidi"
    "$Gtk\include\epoxy"
    "$Gtk\include\libpng16"
    "$Gtk\include\pixman-1"
    "$Gtk\include\freetype2"
    "$Gtk\include"
    "$Vlc\include"
    "$Rlottie\include"
)
$ccFlaggen = @()
foreach ($e in $einschluesse) { $ccFlaggen += @('-Xcc', "-I$e") }
# rlottie erklaert seine Schnittstelle sonst fuer eingefuehrt (dllimport) und
# der Binder sucht `__imp_`-Symbole, die es in einer statischen Bibliothek
# nicht gibt.
$ccFlaggen += @('-Xcc', '-DRLOTTIE_BUILD')

# ------------------------------------------------------------- Symbol
#
# Windows nimmt das Programmsymbol aus einer Ressourcendatei im Binaerprogramm,
# nicht aus einer Datei daneben. `rc.exe` uebersetzt die `.rc`, und die
# entstandene `.res` wird wie eine Bibliothek dazugebunden.
$res = Join-Path $hier 'Mittel\swiftly.res'
& rc.exe /nologo /fo $res (Join-Path $hier 'Mittel\swiftly.rc') | Out-Null
if (Test-Path $res) { $binderFlaggen += @('-Xlinker', $res) }

$binderFlaggen = @('-Xlinker', "/LIBPATH:$Gtk\lib", '-Xlinker', "/LIBPATH:$Vlc\lib",
                   '-Xlinker', "/LIBPATH:$Rlottie\lib")

# **Kein Konsolenfenster im ausgelieferten Bau.** Swift baut sonst ein
# Konsolenprogramm, und beim Doppelklick stuende ein schwarzes Fenster daneben.
# Im Fehlersuchbau bleibt es: dort will man sehen, was auf stderr steht.
if ($Konfiguration -eq 'release') {
    $binderFlaggen += @('-Xlinker', '/SUBSYSTEM:WINDOWS', '-Xlinker', '/ENTRY:mainCRTStartup')
}

# ---------------------------------------------------------------- Bauen

Sag "Bauen ($Konfiguration)"
Push-Location $hier
try {
    # Das Protokoll bleibt liegen: bei einem Fehlschlag steht die Ursache
    # sonst nur im Fenster, und wer den Bau aus einem Skript ruft, sieht sie
    # nicht.
    $protokoll = Join-Path $hier 'bau.log'
    & swift build -c $Konfiguration @ccFlaggen @binderFlaggen 2>&1 |
        Tee-Object -FilePath $protokoll
    if ($LASTEXITCODE -ne 0) {
        Write-Host "--- Fehler aus $protokoll ---" -ForegroundColor Red
        Select-String -Path $protokoll -Pattern 'error:' |
            ForEach-Object { $_.Line.Trim() } | Select-Object -Unique -First 10
        throw "Bau fehlgeschlagen ($LASTEXITCODE)"
    }
} finally { Pop-Location }

# --------------------------------------------------------------- Starter
#
# **Warum ein Starter und keine DLLs neben dem Programm.**
#
# Der naheliegende Weg waere gewesen, GTK einfach neben die `.exe` zu legen —
# Windows sucht DLLs ja dort zuerst. Gemessen: dann startet die App nicht.
# GTK leitet aus dem Ort seiner DLL ab, wo seine Datendateien liegen (`../share`
# mit den GSettings-Schemata und den Symbolen). Neben unserem Programm findet es
# dort nichts und bricht ab, sobald das erste Fenster entstehen soll.
#
# Der Starter setzt stattdessen die Pfade und laesst GTK in seinem eigenen
# Verzeichnis. Dazu die Swift-Laufzeit — ohne sie meldet Windows nur
# „Foundation.dll was not found", was nach einem Fehler im Programm aussieht.

$bau = Join-Path $hier ".build\$Konfiguration"
Sag 'Starter schreiben'
$starter = @"
@echo off
rem Erzeugt von bauen.ps1 — nicht von Hand aendern.
set "PATH=$Gtk\bin;$SwiftLaufzeit;$VlcLaufzeit;%PATH%"
set "GSETTINGS_SCHEMA_DIR=$Gtk\share\glib-2.0\schemas"
set "XDG_DATA_DIRS=$Gtk\share"
set "VLC_PLUGIN_PATH=$VlcLaufzeit\plugins"
start "" "%~dp0SwiftlyWindows.exe" %*
"@
Set-Content -Path (Join-Path $bau 'Swiftly.cmd') -Value $starter -Encoding ascii

Sag "fertig: $bau\Swiftly.cmd"
if ($Starten) { & (Join-Path $bau 'Swiftly.cmd') }
