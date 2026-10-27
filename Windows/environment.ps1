# The environment for a build: MSVC and Swift.
#
# **Why this is here and not in the system environment.** Swift needs the
# headers and link libraries of MSVC (`INCLUDE`, `LIB`), and only
# `vcvars64.bat` sets them. Skipping it produces a list of missing symbols at
# link time that looks like an error in our own code.
#
# Dot-source it:  . .\environment.ps1

param(
    [string]$SwiftWurzel = "$env:LOCALAPPDATA\Programs\Swift",
    [string]$SwiftFassung = '6.3.3',
    [string]$BuildTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
)

$vcvars = Join-Path $BuildTools 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat fehlt: $vcvars" }

# `cmd` runs the batch script and prints the environment afterwards; the lines
# are read back here. There is no other way to get at the result of a batch
# script.
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
