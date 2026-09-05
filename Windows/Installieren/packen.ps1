# Swiftly zu einer Ablage schnueren, die ohne gesetzte Umgebung laeuft.
#
#     .\Installieren\packen.ps1 [-Konfiguration release]
#
# **Warum diese Struktur und keine andere.** GTK leitet aus dem Ort seiner DLL
# ab, wo seine Datendateien liegen: eine DLL in `<wurzel>\bin` bedeutet fuer
# GTK `<wurzel>\share` und `<wurzel>\lib`. Genau deshalb liegt hier alles so
# und nicht flach in einem Verzeichnis — mit DLLs neben der `.exe` startet die
# App nicht, sie bricht beim ersten Fenster ab. Gemessen, mit Zugriffsverletzung
# in `gtk_settings_get_default()`.
#
# libVLC sucht seine Module ebenfalls neben sich, also unter `bin\plugins`. Und
# unsere eigenen Mittel findet ``Plattform.mitgeliefert`` eine Ebene ueber der
# `.exe`, also unter `<wurzel>\Ressourcen`.

param(
    [string]$Konfiguration = 'release',
    [string]$Ziel = '',
    [string]$Gtk = 'C:\Werkzeuge\gtk4',
    [string]$VlcLaufzeit = 'C:\Werkzeuge\vlc\vlc-3.0.21',
    [string]$SwiftLaufzeit = 'C:\Swift\Runtimes\6.2.1\usr\bin'
)

$ErrorActionPreference = 'Stop'
$hier = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Ziel) { $Ziel = Join-Path $hier 'Ablage\Swiftly' }
function Sag($t) { Write-Host "==> $t" -ForegroundColor Green }

$bau = Join-Path $hier ".build\$Konfiguration"
if (-not (Test-Path (Join-Path $bau 'SwiftlyWindows.exe'))) {
    throw "Erst bauen: .\bauen.ps1 -Konfiguration $Konfiguration"
}

Sag 'Ablage anlegen'
if (Test-Path $Ziel) { Remove-Item -Recurse -Force $Ziel }
New-Item -ItemType Directory -Force -Path "$Ziel\bin","$Ziel\share","$Ziel\lib" | Out-Null

Sag 'Programm'
Copy-Item (Join-Path $bau 'SwiftlyWindows.exe') "$Ziel\bin\Swiftly.exe"

Sag 'GTK'
Copy-Item "$Gtk\bin\*.dll" "$Ziel\bin" -Force
Copy-Item "$Gtk\share\glib-2.0" "$Ziel\share" -Recurse -Force
Copy-Item "$Gtk\share\icons" "$Ziel\share" -Recurse -Force
if (Test-Path "$Gtk\share\gtk-4.0") { Copy-Item "$Gtk\share\gtk-4.0" "$Ziel\share" -Recurse -Force }
Copy-Item "$Gtk\lib\gdk-pixbuf-2.0" "$Ziel\lib" -Recurse -Force
# **`etc` gehoert dazu.** Dort liegt die Einstellung von fontconfig. Ohne sie
# findet Pango keine Schrift, und GTK bricht beim ersten Fenster ab — gemessen,
# mit derselben Zugriffsverletzung, die auch eine fehlende Schemadatei erzeugt.
if (Test-Path "$Gtk\etc") { Copy-Item "$Gtk\etc" "$Ziel\etc" -Recurse -Force }
foreach ($m in @('fontconfig','locale','themes','mime')) {
    if (Test-Path "$Gtk\share\$m") { Copy-Item "$Gtk\share\$m" "$Ziel\share" -Recurse -Force }
}

Sag 'Swift-Laufzeit'
Copy-Item "$SwiftLaufzeit\*.dll" "$Ziel\bin" -Force

Sag 'libVLC samt Modulen'
Copy-Item "$VlcLaufzeit\libvlc.dll","$VlcLaufzeit\libvlccore.dll" "$Ziel\bin" -Force
Copy-Item "$VlcLaufzeit\plugins" "$Ziel\bin" -Recurse -Force

Sag 'Eigene Mittel'
Copy-Item (Join-Path $hier 'Ressourcen') "$Ziel\Ressourcen" -Recurse -Force

# Eine Verknuepfung eine Ebene hoeher, damit niemand in `bin` suchen muss.
Sag 'Verknuepfung'
$wsh = New-Object -ComObject WScript.Shell
$vk = $wsh.CreateShortcut((Join-Path $Ziel 'Swiftly.lnk'))
$vk.TargetPath = "$Ziel\bin\Swiftly.exe"
$vk.WorkingDirectory = "$Ziel\bin"
$vk.IconLocation = "$Ziel\bin\Swiftly.exe,0"
$vk.Description = 'Jellyfin-Client, der niemals transkodiert'
$vk.Save()

$groesse = [math]::Round(((Get-ChildItem $Ziel -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
Sag "fertig: $Ziel ($groesse MB)"
