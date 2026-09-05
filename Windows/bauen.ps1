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
    [string]$VlcLaufzeit = 'C:\Werkzeuge\vlc\vlc-3.0.21'
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
)
$ccFlaggen = @()
foreach ($e in $einschluesse) { $ccFlaggen += @('-Xcc', "-I$e") }

$binderFlaggen = @('-Xlinker', "/LIBPATH:$Gtk\lib", '-Xlinker', "/LIBPATH:$Vlc\lib")

# ---------------------------------------------------------------- Bauen

Sag "Bauen ($Konfiguration)"
Push-Location $hier
try {
    & swift build -c $Konfiguration @ccFlaggen @binderFlaggen
    if ($LASTEXITCODE -ne 0) { throw "Bau fehlgeschlagen ($LASTEXITCODE)" }
} finally { Pop-Location }

# ------------------------------------------------------- Danebenlegen
#
# Windows sucht DLLs neben dem Programm, nicht ueber einen Suchpfad wie
# `LD_LIBRARY_PATH`. Also kommen GTK und libVLC dorthin — und VLCs Module
# gleich mit, sonst startet der Abspieler ohne einen einzigen Dekoder.

$bau = Join-Path $hier ".build\$Konfiguration"
Sag 'Bibliotheken danebenlegen'
Copy-Item "$Gtk\bin\*.dll" $bau -Force -EA SilentlyContinue
Copy-Item "$VlcLaufzeit\libvlc.dll", "$VlcLaufzeit\libvlccore.dll" $bau -Force -EA SilentlyContinue
if (-not (Test-Path "$bau\plugins")) {
    Copy-Item "$VlcLaufzeit\plugins" $bau -Recurse -Force -EA SilentlyContinue
}

Sag "fertig: $bau\SwiftlyWindows.exe"
if ($Starten) { & "$bau\SwiftlyWindows.exe" }
