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
# **Unter Windows legt SwiftPM den Kurzpfad nicht immer an** — dann liegt das
# Ergebnis nur unter `.build\<Ziel>\<Konfiguration>`. `bauen.ps1` sucht dort
# schon; hier stand nur der Kurzpfad, und das Packen brach mit "Erst bauen" ab.
if (-not (Test-Path (Join-Path $bau 'SwiftlyWindows.exe'))) {
    $treffer = Get-ChildItem -Path (Join-Path $hier '.build') -Recurse -Filter 'SwiftlyWindows.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\$Konfiguration\*" } | Select-Object -First 1
    if ($treffer) { $bau = $treffer.DirectoryName }
}
if (-not (Test-Path (Join-Path $bau 'SwiftlyWindows.exe'))) {
    throw "Erst bauen: .\bauen.ps1 -Konfiguration $Konfiguration"
}

Sag 'Ablage anlegen'
if (Test-Path $Ziel) { Remove-Item -Recurse -Force $Ziel }
New-Item -ItemType Directory -Force -Path "$Ziel\bin","$Ziel\share","$Ziel\lib" | Out-Null

Sag 'Programm'
Copy-Item (Join-Path $bau 'SwiftlyWindows.exe') "$Ziel\bin\Swiftly.exe"

# **Das Startprogramm liegt eine Ebene ueber `bin`** und startet von dort
# `bin\Swiftly.exe`. Verknuepfungen zeigen darauf, nicht auf die App - sonst
# steht beim ersten Start wieder 20 s lang gar nichts da.
$startprogramm = Join-Path $hier '.build\startprogramm\Swiftly.exe'
if (-not (Test-Path $startprogramm)) { throw "Startprogramm fehlt: erst .\bauen.ps1" }
Copy-Item $startprogramm "$Ziel\Swiftly.exe"

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

# **Das Ressourcenbuendel, ohne das die App nicht startet.**
#
# SwiftPM legt Bilder und Uebersetzungen nicht in die .exe, sondern in einen
# Ordner `<Ziel>_<Ziel>.resources` daneben. Bundle.module sucht ihn neben dem
# Programm - und faellt sonst auf den Bauordner zurueck, der nur auf einem
# Entwicklungsrechner existiert. Genau daran starb die 1.0.3 bei einem Tester:
#   could not load resource bundle: from C:/Program Files/Swiftly/bin/...
#   Exitcode 0xC000001D, letzte Stufe: oberflaeche
# Bei uns lief sie, weil in der Testmaschine der Bauordner lag. Deshalb wird
# er jetzt mitkopiert - und das Schnueren bricht ab, wenn er fehlt, statt ein
# Paket auszuliefern, das auf jedem sauberen Rechner abstuerzt.
Sag 'Ressourcenbuendel'
# **Alle, nicht nur das eigene.** Jedes SwiftPM-Ziel mit Ressourcen bringt ein
# eigenes Buendel mit - JellyfinKit auch (seine Uebersetzungen). Der erste
# Anlauf kopierte nur SwiftlyWindows_SwiftlyWindows.resources; die Probe ohne
# Bauordner starb dann eine Zeile spaeter an JellyfinKit_JellyfinKit.resources.
$pflicht = 'SwiftlyWindows_SwiftlyWindows.resources', 'JellyfinKit_JellyfinKit.resources'
foreach ($name in $pflicht) {
    if (-not (Test-Path (Join-Path $bau $name))) {
        throw "Ressourcenbuendel fehlt: $name - erst bauen.ps1 laufen lassen."
    }
}
Get-ChildItem $bau -Directory -Filter '*.resources' | ForEach-Object {
    Copy-Item $_.FullName "$Ziel\bin" -Recurse -Force
    Sag ('  ' + $_.Name)
}

Sag 'libVLC samt Modulen'
Copy-Item "$VlcLaufzeit\libvlc.dll","$VlcLaufzeit\libvlccore.dll" "$Ziel\bin" -Force
Copy-Item "$VlcLaufzeit\plugins" "$Ziel\bin" -Recurse -Force

# **Was nie geladen wird, kommt nicht mit.** Die GTK- und Swift-Ordner bringen
# DLLs mit, die niemand von uns braucht (gtkmm, protobuf, gettext, Teile der
# Swift-Laufzeit). Jede davon ist beim ersten Start eine Datei mehr, die der
# Defender prueft, und ein paar MB mehr im Installer. Gemessen am 16.09.2026
# an 1.0.2: 51 von 101 DLLs in `bin` werden von der App, den libVLC-Modulen
# oder den gdk-pixbuf-Ladern ueberhaupt eingebunden; zur Laufzeit kam keine
# weitere dazu.
#
# Deshalb keine feste Liste, sondern die Huelle: alles, was von `Swiftly.exe`,
# `bin\plugins` und `lib` aus ueber Importe (auch verzoegerte) erreichbar ist,
# bleibt. Fehlt `dumpbin`, bleibt alles liegen.
Sag 'Unbenutzte DLLs aussortieren'
$dumpbin = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC' -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like '*HostX64\x64*' } | Select-Object -First 1
if ($dumpbin) {
    $imBin = @{}
    Get-ChildItem "$Ziel\bin" -Filter *.dll | ForEach-Object { $imBin[$_.Name.ToLower()] = $_ }
    function Importe($datei) {
        (& $dumpbin.FullName /nologo /dependents $datei) |
            Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim().ToLower() }
    }
    $erreicht = @{}
    $offen = New-Object System.Collections.Queue
    $wurzeln = @("$Ziel\bin\Swiftly.exe")
    $wurzeln += (Get-ChildItem "$Ziel\bin\plugins","$Ziel\lib" -Recurse -Filter *.dll | ForEach-Object FullName)
    foreach ($w in $wurzeln) {
        foreach ($d in (Importe $w)) {
            if ($imBin.ContainsKey($d) -and -not $erreicht.ContainsKey($d)) { $erreicht[$d] = 1; $offen.Enqueue($d) }
        }
    }
    while ($offen.Count -gt 0) {
        $d = $offen.Dequeue()
        foreach ($e in (Importe $imBin[$d].FullName)) {
            if ($imBin.ContainsKey($e) -and -not $erreicht.ContainsKey($e)) { $erreicht[$e] = 1; $offen.Enqueue($e) }
        }
    }
    $weg = $imBin.Keys | Where-Object { -not $erreicht.ContainsKey($_) } | Sort-Object
    foreach ($d in $weg) { Remove-Item $imBin[$d].FullName -Force }
    Write-Host ("    " + $erreicht.Count + " bleiben, " + @($weg).Count + " entfernt: " + ($weg -join ', '))
} else {
    Write-Host '    dumpbin nicht gefunden - alle DLLs bleiben' -ForegroundColor Yellow
}

Sag 'Eigene Mittel'
Copy-Item (Join-Path $hier 'Ressourcen') "$Ziel\Ressourcen" -Recurse -Force

# Eine Verknuepfung eine Ebene hoeher, damit niemand in `bin` suchen muss.
Sag 'Verknuepfung'
$wsh = New-Object -ComObject WScript.Shell
$vk = $wsh.CreateShortcut((Join-Path $Ziel 'Swiftly.lnk'))
$vk.TargetPath = "$Ziel\Swiftly.exe"
$vk.WorkingDirectory = $Ziel
$vk.IconLocation = "$Ziel\Swiftly.exe,0"
$vk.Description = 'Jellyfin-Client, der niemals transkodiert'
$vk.Save()

$groesse = [math]::Round(((Get-ChildItem $Ziel -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
Sag "fertig: $Ziel ($groesse MB)"
