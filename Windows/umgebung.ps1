# Die Umgebung fuer einen Bau — MSVC und Swift.
#
# **Warum das hier steht und nicht in der Systemumgebung.** Swift braucht die
# Kopfdateien und Bindebibliotheken von MSVC (`INCLUDE`, `LIB`), und die setzt
# erst `vcvars64.bat`. Wer das ueberspringt, bekommt beim Binden eine Liste
# fehlender Symbole, die nach einem Fehler im eigenen Code aussieht.
#
# Punktweise einbinden:  . .\umgebung.ps1

param(
    [string]$SwiftWurzel = 'C:\Swift',
    [string]$SwiftFassung = '6.2.1',
    [string]$BuildTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
)

$vcvars = Join-Path $BuildTools 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat fehlt: $vcvars" }

# `cmd` fuehrt das Stapelskript aus und gibt die Umgebung danach aus; die
# Zeilen werden hier zurueckgelesen. Anders kommt man an das Ergebnis eines
# Stapelskripts nicht heran.
cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:$($matches[1])" -Value $matches[2] -ErrorAction SilentlyContinue
    }
}

$toolchain = Join-Path $SwiftWurzel "Toolchains\$SwiftFassung+Asserts\usr\bin"
$laufzeit  = Join-Path $SwiftWurzel "Runtimes\$SwiftFassung\usr\bin"
$sdk       = Join-Path $SwiftWurzel "Platforms\$SwiftFassung\Windows.platform\Developer\SDKs\Windows.sdk"
if (-not (Test-Path $toolchain)) { throw "Swift fehlt: $toolchain" }

$env:SDKROOT = $sdk
$env:Path = "$toolchain;$laufzeit;" + $env:Path
