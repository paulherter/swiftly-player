# rlottie fuer Windows bauen — dieselbe Bibliothek wie unter Linux, nur mit
# MSVC statt g++ und als statische Bibliothek statt als DLL.
#
# **Ohne Faeden, aus demselben Grund wie auf Linux.** Mit LOTTIE_THREAD_SUPPORT
# legt rlottie einen Fadenpool an, der dauerhaft leer weiterdreht. Fuer eine
# Marke von 360 Punkten, die einmal beim Start laeuft, ist ein Faden genug.
$ErrorActionPreference = 'Continue'
$log = 'C:\Werkzeuge\rlottie.log'
function Sag($t) { "$(Get-Date -Format HH:mm:ss)  $t" | Tee-Object -FilePath $log -Append }

$quelle = 'C:\Werkzeuge\rlottie-quelle'
$ziel = 'C:\Werkzeuge\rlottie'
$env:Path = 'C:\Program Files\Git\cmd;' + $env:Path

if (-not (Test-Path $quelle)) {
    Sag 'rlottie holen'
    git clone --depth 1 https://github.com/Samsung/rlottie.git $quelle 2>&1 | Out-Null
}

# `RLOTTIE_BUILD` schaltet die Schnittstelle von dllimport auf dllexport.
# Ohne das erklaert rlottie seine eigenen Funktionen fuer eingefuehrt und
# lehnt ihre Definition ab — dieselbe Angabe braucht spaeter auch, wer die
# statische Bibliothek benutzt.
Sag 'config.h schreiben'
@'
#define LOTTIE_IMAGE_MODULE_PLUGIN ""
#define LOTTIE_CACHE
#define LOTTIE_CACHE_SUPPORT
'@ | Set-Content "$quelle\src\vector\config.h" -Encoding ascii

. C:\swiftly\Windows\umgebung.ps1
Set-Location $quelle
$obj = "$quelle\obj"
Remove-Item -Recurse -Force $obj -EA SilentlyContinue
New-Item -ItemType Directory -Force -Path $obj | Out-Null

$inc = @('inc','src\vector','src\vector\freetype','src\vector\pixman','src\vector\stb','src\lottie','src\binding') |
       ForEach-Object { "/I$quelle\$_" }
$quellen = Get-ChildItem "$quelle\src" -Recurse -Filter *.cpp |
           Where-Object { $_.FullName -notmatch 'wasm' } | ForEach-Object { $_.FullName }
Sag ("$($quellen.Count) Quelldateien")

Push-Location $obj
$ErrorActionPreference = 'Continue'
& cl /nologo /c /std:c++14 /O2 /EHsc /MD /W0 /DNDEBUG /D_CRT_SECURE_NO_WARNINGS /DRLOTTIE_BUILD @inc @quellen 2>&1 |
    Select-Object -Last 3
Sag "Uebersetzt mit $LASTEXITCODE"
$objekte = Get-ChildItem "$obj\*.obj" | ForEach-Object { $_.FullName }
Sag ("$($objekte.Count) Objekte")
New-Item -ItemType Directory -Force -Path "$ziel\lib","$ziel\include" | Out-Null
& lib /nologo /OUT:"$ziel\lib\rlottie.lib" @objekte 2>&1 | Select-Object -Last 2
Sag "Archiv mit $LASTEXITCODE"
Pop-Location
Copy-Item "$quelle\inc\rlottie_capi.h","$quelle\inc\rlottiecommon.h" "$ziel\include" -Force
Sag ('rlottie.lib: ' + (Test-Path "$ziel\lib\rlottie.lib"))
