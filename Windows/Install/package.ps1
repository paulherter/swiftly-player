# Pack Swiftly into a layout that runs without any environment set.
#
#     .\Install\package.ps1 [-Konfiguration release]
#
# **Why this structure and no other.** GTK derives the location of its data
# files from the location of its DLL: a DLL in `<root>\bin` means `<root>\share`
# and `<root>\lib` to GTK. That is why everything lies like this and not flat in
# one directory. With DLLs next to the `.exe` the app does not start; it aborts
# at the first window, with an access violation in `gtk_settings_get_default()`.
#
# libVLC also looks for its modules next to itself, i.e. under `bin\plugins`.
# Our own resources are found by ``Plattform.mitgeliefert`` one level above the
# `.exe`, i.e. under `<root>\Resources`.

param(
    [string]$Konfiguration = 'release',
    [string]$Ziel = '',
    [string]$Gtk = 'C:\Werkzeuge\gtk4',
    [string]$VlcLaufzeit = 'C:\Werkzeuge\vlc\vlc-3.0.21',
    [string]$SwiftLaufzeit = 'C:\Swift\Runtimes\6.2.1\usr\bin'
)

$ErrorActionPreference = 'Stop'
$hier = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Ziel) { $Ziel = Join-Path $hier 'Output\Swiftly' }
function Sag($t) { Write-Host "==> $t" -ForegroundColor Green }

$bau = Join-Path $hier ".build\$Konfiguration"
# **On Windows SwiftPM does not always create the short path.** Then the result
# lies only under `.build\<target>\<configuration>`. `build.ps1` looks there
# already; this script only checked the short path and aborted with "Erst
# bauen".
if (-not (Test-Path (Join-Path $bau 'SwiftlyWindows.exe'))) {
    $treffer = Get-ChildItem -Path (Join-Path $hier '.build') -Recurse -Filter 'SwiftlyWindows.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\$Konfiguration\*" } | Select-Object -First 1
    if ($treffer) { $bau = $treffer.DirectoryName }
}
if (-not (Test-Path (Join-Path $bau 'SwiftlyWindows.exe'))) {
    throw "Erst bauen: .\build.ps1 -Konfiguration $Konfiguration"
}

Sag 'Ablage anlegen'
if (Test-Path $Ziel) { Remove-Item -Recurse -Force $Ziel }
New-Item -ItemType Directory -Force -Path "$Ziel\bin","$Ziel\share","$Ziel\lib" | Out-Null

Sag 'Programm'
Copy-Item (Join-Path $bau 'SwiftlyWindows.exe') "$Ziel\bin\Swiftly.exe"

# **The launcher sits one level above `bin`** and starts `bin\Swiftly.exe` from
# there. Shortcuts point to it, not to the app; otherwise nothing is shown for
# 20 s on first start.
$startprogramm = Join-Path $hier '.build\launcher\Swiftly.exe'
if (-not (Test-Path $startprogramm)) { throw "Startprogramm fehlt: erst .\build.ps1" }
Copy-Item $startprogramm "$Ziel\Swiftly.exe"

Sag 'GTK'
Copy-Item "$Gtk\bin\*.dll" "$Ziel\bin" -Force
Copy-Item "$Gtk\share\glib-2.0" "$Ziel\share" -Recurse -Force
Copy-Item "$Gtk\share\icons" "$Ziel\share" -Recurse -Force
if (Test-Path "$Gtk\share\gtk-4.0") { Copy-Item "$Gtk\share\gtk-4.0" "$Ziel\share" -Recurse -Force }
Copy-Item "$Gtk\lib\gdk-pixbuf-2.0" "$Ziel\lib" -Recurse -Force
# **`etc` belongs in it.** It holds the fontconfig configuration. Without it
# Pango finds no font and GTK aborts at the first window, with the same access
# violation that a missing schema file also causes.
if (Test-Path "$Gtk\etc") { Copy-Item "$Gtk\etc" "$Ziel\etc" -Recurse -Force }
foreach ($m in @('fontconfig','locale','themes','mime')) {
    if (Test-Path "$Gtk\share\$m") { Copy-Item "$Gtk\share\$m" "$Ziel\share" -Recurse -Force }
}

Sag 'Swift-Laufzeit'
Copy-Item "$SwiftLaufzeit\*.dll" "$Ziel\bin" -Force

# **The resource bundle without which the app does not start.**
#
# SwiftPM puts images and translations not into the .exe but into a folder
# `<target>_<target>.resources` next to it. Bundle.module looks for it next to
# the program and otherwise falls back to the build folder, which exists only
# on a development machine. Without the folder the app fails at startup:
#   could not load resource bundle: from C:/Program Files/Swiftly/bin/...
#   exit code 0xC000001D, last stage: oberflaeche
# It worked on the test machine because the build folder was there. So the
# bundle is now copied, and packing aborts if it is missing instead of shipping
# a package that crashes on every clean machine.
Sag 'Ressourcenbuendel'
# **All of them, not just our own.** Every SwiftPM target with resources brings
# its own bundle; JellyfinKit too (its translations). Copying only
# SwiftlyWindows_SwiftlyWindows.resources made a run without the build folder
# die one line later on JellyfinKit_JellyfinKit.resources.
# **And the name depends on the toolchain.** Up to Swift 6.3 a bundle is called
# <target>_<target>.resources, from 6.4 <target>_<target>.bundle; the generated
# Bundle.module accessor looks for exactly the name it was built with. On Linux
# the same hard-coded name shipped a pacman package without any bundle. So both
# names are handled.
$pflicht = 'SwiftlyWindows_SwiftlyWindows', 'JellyfinKit_JellyfinKit'
foreach ($name in $pflicht) {
    $da = @('.resources', '.bundle') | Where-Object { Test-Path (Join-Path $bau ($name + $_)) }
    if (-not $da) {
        throw "Ressourcenbuendel fehlt: $name - erst build.ps1 laufen lassen."
    }
}
$kopiert = 0
Get-ChildItem $bau -Directory | Where-Object { $_.Name -match '\.(resources|bundle)$' } | ForEach-Object {
    Copy-Item $_.FullName "$Ziel\bin" -Recurse -Force
    Sag ('  ' + $_.Name)
    $kopiert++
}
if ($kopiert -eq 0) { throw "Kein Ressourcenbuendel in $bau" }

Sag 'libVLC samt Modulen'
Copy-Item "$VlcLaufzeit\libvlc.dll","$VlcLaufzeit\libvlccore.dll" "$Ziel\bin" -Force
Copy-Item "$VlcLaufzeit\plugins" "$Ziel\bin" -Recurse -Force

# **What is never loaded does not ship.** The GTK and Swift folders contain
# DLLs nobody here needs (gtkmm, protobuf, gettext, parts of the Swift
# runtime). Each one is one more file for Defender to check at first start and a
# few MB more in the installer. Measured: only 51 of 101 DLLs in `bin`
# are loaded by the app, the libVLC modules or the gdk-pixbuf loaders; none
# more were loaded at runtime.
#
# So no fixed list but the closure: everything reachable via imports (including
# delayed ones) from `Swiftly.exe`, `bin\plugins` and `lib` stays. If `dumpbin`
# is missing, everything stays.
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
Copy-Item (Join-Path $hier 'Resources') "$Ziel\Resources" -Recurse -Force
# **No license texts, no package.** libVLC (LGPL-2.1-or-later) requires text,
# author and source reference; the app shows them from Resources\Licenses,
# and build.ps1 puts them there.
foreach ($l in 'components.json','LGPL-2.1-or-later.txt') {
    if (-not (Test-Path "$Ziel\Resources\Licenses\$l")) { throw "Lizenzdatei fehlt: Resources\Licenses\$l - erst build.ps1 laufen lassen." }
}
Copy-Item (Join-Path (Split-Path -Parent $hier) 'THIRD-PARTY-NOTICES.md') "$Ziel\THIRD-PARTY-NOTICES.md" -Force
Copy-Item (Join-Path (Split-Path -Parent $hier) 'LICENSE') "$Ziel\LICENSE.txt" -Force

# A shortcut one level up, so nobody has to look in `bin`.
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
