# Build Swiftly for Windows.
#
#     .\build.ps1            build
#     .\build.ps1 -Starten   build and start
#
# **What happens here and why.** The UI source exists exactly once in the
# repo, under `Linux/Sources/SwiftlyLinux`. SwiftPM does not allow targets
# outside the package directory, so it is mirrored in before every build.
# Everything that differs between platforms is a `#if os(Windows)` in these
# shared files; there is no second version that could drift apart.

param(
    [switch]$Starten,
    [string]$Konfiguration = 'debug',
    [string]$Gtk = 'C:\Werkzeuge\gtk4',
    [string]$Vlc = 'C:\Werkzeuge\vlcsdk',
    [string]$VlcLaufzeit = 'C:\Werkzeuge\vlc\vlc-3.0.21',
    [string]$SwiftLaufzeit = 'C:\Swift\Runtimes\6.2.1\usr\bin',
    [string]$Rlottie = 'C:\Werkzeuge\rlottie',
    # **Symbols for looking up crashes.** Without them no PDB is produced, and an
    # offset from the event log cannot be resolved to a function name. That is
    # exactly where the search for a startup crash first failed.
    [switch]$Symbole
)

$ErrorActionPreference = 'Stop'
$hier = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $hier 'environment.ps1')
$quelle = Join-Path (Split-Path -Parent $hier) 'Linux\Sources\SwiftlyLinux'
$ziel = Join-Path $hier 'Sources\SwiftlyWindows'

function Sag($t) { Write-Host "==> $t" -ForegroundColor Green }

# ------------------------------------------------------------- Mirroring

Sag 'Geteilte Quellen spiegeln'
if (-not (Test-Path $quelle)) { throw "Quellen fehlen: $quelle" }
if (Test-Path $ziel) { Remove-Item -Recurse -Force $ziel }
New-Item -ItemType Directory -Force -Path $ziel | Out-Null
Copy-Item -Path (Join-Path $quelle '*.swift') -Destination $ziel
Copy-Item -Path (Join-Path $quelle 'Resources') -Destination $ziel -Recurse
Write-Host ("    " + (Get-ChildItem $ziel -Filter *.swift).Count + " Dateien")

# The bridge to VLC is the same C file; only the module maps differ, because
# the binding names differ.
$bruecke = Join-Path $hier 'Sources\CImageBridge'
if (Test-Path $bruecke) { Remove-Item -Recurse -Force $bruecke }
New-Item -ItemType Directory -Force -Path (Join-Path $bruecke 'include') | Out-Null
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CImageBridge\*.c') $bruecke
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CImageBridge\include\*.h') (Join-Path $bruecke 'include')
# When a header is added, SwiftPM does not notice in the old build folder: the
# remembered build plan and module description stay as before, and Swift does
# not find the new names. So the build plan and folder of this one module are
# regenerated; everything else stays in the cache.
if (Test-Path (Join-Path $hier '.build')) {
    Get-ChildItem (Join-Path $hier '.build') -Recurse -Directory -Filter 'CImageBridge.build' -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem (Join-Path $hier '.build') -Recurse -File -Include 'debug.yaml','release.yaml','description.json' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# The media keys are also the same C code.
$tasten = Join-Path $hier 'Sources\CMediaKeys'
if (Test-Path $tasten) { Remove-Item -Recurse -Force $tasten }
New-Item -ItemType Directory -Force -Path (Join-Path $tasten 'include') | Out-Null
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CMediaKeys\mediakeys.c') $tasten
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CMediaKeys\include\mediakeys.h') (Join-Path $tasten 'include')

# And so is the registration of the bundled font.
$schrift = Join-Path $hier 'Sources\CFonts'
if (Test-Path $schrift) { Remove-Item -Recurse -Force $schrift }
New-Item -ItemType Directory -Force -Path (Join-Path $schrift 'include') | Out-Null
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CFonts\fonts.c') $schrift
Copy-Item (Join-Path (Split-Path -Parent $hier) 'Linux\Sources\CFonts\include\fonts.h') (Join-Path $schrift 'include')

# Icon and startup animation likewise exist only once in the repo.
$mittel = Join-Path (Split-Path -Parent $hier) 'Linux\Resources'
$mittelZiel = Join-Path $hier 'Resources'
if (Test-Path $mittelZiel) { Remove-Item -Recurse -Force $mittelZiel }
Copy-Item -Path $mittel -Destination $mittelZiel -Recurse

# The license texts (LICENSES\ in the repo, the single source) go next to the
# program under Resources\Licenses; the app reads components.json and the full
# texts there. libVLC is LGPL, so nothing may ship without these files.
$lizenzen = Join-Path (Split-Path -Parent $hier) 'LICENSES'
if (-not (Test-Path (Join-Path $lizenzen 'components.json'))) { throw "LICENSES\components.json fehlt: $lizenzen" }
Copy-Item -Path $lizenzen -Destination (Join-Path $mittelZiel 'Lizenzen') -Recurse

# ------------------------------------------------------------- Search paths
#
# GTK spreads its headers over a dozen directories, and two of them are under
# `lib`, not `include`: they hold what was decided when the library was built
# (`glibconfig.h`, `graphene-config.h`).

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
# Otherwise rlottie declares its interface as imported (dllimport) and the
# linker looks for `__imp_` symbols, which a static library does not have.
$ccFlaggen += @('-Xcc', '-DRLOTTIE_BUILD')

# ------------------------------------------------------------- Icon
#
# Windows takes the program icon from a resource in the binary, not from a
# file next to it. `rc.exe` compiles the `.rc`, and the resulting `.res` is
# linked in like a library.
$res = Join-Path $hier 'Assets\swiftly.res'
& rc.exe /nologo /fo $res (Join-Path $hier 'Assets\swiftly.rc') | Out-Null

# **List first, then append.** The `.res` used to be appended *before* this
# assignment, which threw it away every time, so no build contained the
# program icon.
$binderFlaggen = @('-Xlinker', "/LIBPATH:$Gtk\lib", '-Xlinker', "/LIBPATH:$Vlc\lib",
                   '-Xlinker', "/LIBPATH:$Rlottie\lib")
if (Test-Path $res) { $binderFlaggen += @('-Xlinker', $res) }

if ($Symbole) {
    $ccFlaggen += @('-Xswiftc', '-g', '-Xswiftc', '-debug-info-format=codeview')
    $binderFlaggen += @('-Xlinker', '/DEBUG')
}

# **No console window in the shipped build.** Otherwise Swift builds a console
# program, and a double-click would show a black window beside it. The debug
# build keeps it: there you want to see what is on stderr.
if ($Konfiguration -eq 'release') {
    $binderFlaggen += @('-Xlinker', '/SUBSYSTEM:WINDOWS', '-Xlinker', '/ENTRY:mainCRTStartup')
}

# ---------------------------------------------------------------- Build

# **A running app holds its own .exe.**
#
# Windows locks the program while it runs; the linker then fails with
# `failed to write output ... permission denied`, which reads like a
# permission problem on the directory. It is not; it is the previous version
# still being open.
$laeuft = Get-Process -Name 'SwiftlyWindows' -ErrorAction SilentlyContinue
if ($laeuft) {
    Sag "laufende Fassung beenden ($($laeuft.Count))"
    $laeuft | Stop-Process -Force
    # `Stop-Process` returns before the handle is really closed.
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Get-Process -Name 'SwiftlyWindows' -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 100
    }
}

Sag "Bauen ($Konfiguration)"
Push-Location $hier
try {
    # The log stays: on failure the cause is otherwise only in the window, and
    # someone calling the build from a script does not see it.
    $protokoll = Join-Path $hier 'bau.log'
    # **A warning from swift.exe must not abort the build.**
    #
    # The chain was unpleasantly indirect: without developer mode Windows does not
    # allow symlinks, so SwiftPM cannot create `.build\debug` and writes a
    # *warning* to stderr (Win32Error 1314). `$ErrorActionPreference = 'Stop'`
    # turns every stderr line of a foreign program into a terminating error, so
    # the script ended right after the build, never wrote the starter and started
    # nothing. It looked as if the app did not start; in fact it was never called.
    #
    # `SilentlyContinue` applies only to this one call. Whether the build worked is
    # told by `$LASTEXITCODE`, which is checked right after.
    $vorher = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & swift build -c $Konfiguration @ccFlaggen @binderFlaggen 2>&1 |
        Tee-Object -FilePath $protokoll
    $ErrorActionPreference = $vorher
    if ($LASTEXITCODE -ne 0) {
        Write-Host "--- Fehler aus $protokoll ---" -ForegroundColor Red
        Select-String -Path $protokoll -Pattern 'error:' |
            ForEach-Object { $_.Line.Trim() } | Select-Object -Unique -First 10
        throw "Bau fehlgeschlagen ($LASTEXITCODE)"
    }
} finally { Pop-Location }

# --------------------------------------------------------- Launcher
#
# **The loading window before the app.** On the first start of a new version
# Defender scans every unknown DLL before `Swiftly.exe` runs a line of our
# code: about 23 s without any window. The launcher only links against system
# libraries and appears immediately; what it does is described in
# `Launcher\launcher.c`.
#
# `/MT` links the C runtime in: `vcruntime140.dll` is not guaranteed on a fresh
# Windows, and that is exactly where the window must appear.
Sag 'Launcher'
$sp = Join-Path $hier 'Launcher'
$spZiel = Join-Path $hier '.build\launcher'
New-Item -ItemType Directory -Force -Path $spZiel | Out-Null
& rc.exe /nologo /fo (Join-Path $spZiel 'launcher.res') (Join-Path $sp 'launcher.rc') | Out-Null
if ($LASTEXITCODE -ne 0) { throw "rc.exe fuer das Startprogramm fehlgeschlagen ($LASTEXITCODE)" }
$vorher = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
& cl.exe /nologo /O1 /W4 /MT /utf-8 /DUNICODE /D_UNICODE `
    "/Fo$spZiel\" "/Fe$spZiel\Swiftly.exe" (Join-Path $sp 'launcher.c') `
    (Join-Path $spZiel 'launcher.res') `
    /link /SUBSYSTEM:WINDOWS /MANIFEST:NO user32.lib gdi32.lib comctl32.lib shell32.lib ole32.lib 2>&1 |
    Tee-Object -FilePath (Join-Path $spZiel 'bau.log') | Out-Null
$ErrorActionPreference = $vorher
if ($LASTEXITCODE -ne 0) {
    Get-Content (Join-Path $spZiel 'bau.log') | Select-Object -Last 15
    throw "Startprogramm fehlgeschlagen ($LASTEXITCODE)"
}
Select-String -Path (Join-Path $spZiel 'bau.log') -Pattern 'warning' | ForEach-Object { $_.Line.Trim() }

# --------------------------------------------------------------- Starter
#
# **Why a starter and not DLLs next to the program.**
#
# The obvious way would have been to put GTK next to the `.exe`, since Windows
# searches there first for DLLs. In practice the app then does not start. GTK
# derives the location of its data files (`../share` with the GSettings schemas
# and icons) from where its DLL is. Next to our program it finds nothing there
# and aborts as soon as the first window is created.
#
# The starter instead sets the paths and leaves GTK in its own directory. It
# also provides the Swift runtime; without it Windows only reports
# "Foundation.dll was not found", which looks like a bug in the program.

# **The convenient path is not always there.** `.build\debug` is a symlink
# created by SwiftPM, and without developer mode Windows does not allow that
# (Win32Error 1314). The result is then only under the full triple path, and a
# script that blindly points at `.build\debug` finds nothing and does not say
# why.
$bau = Join-Path $hier ".build\$Konfiguration"
if (-not (Test-Path (Join-Path $bau 'SwiftlyWindows.exe'))) {
    $treffer = Get-ChildItem -Path (Join-Path $hier '.build') -Recurse `
        -Filter 'SwiftlyWindows.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\$Konfiguration\*" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($treffer) {
        $bau = $treffer.DirectoryName
        Sag "ohne Symlink gebaut, Ergebnis unter $bau"
    } else {
        throw "SwiftlyWindows.exe nicht gefunden -- weder unter .build\$Konfiguration noch darunter."
    }
}

Sag 'Starter schreiben'
$starter = @"
@echo off
rem Erzeugt von build.ps1 — nicht von Hand aendern.
set "PATH=$Gtk\bin;$SwiftLaufzeit;$VlcLaufzeit;%PATH%"
set "GSETTINGS_SCHEMA_DIR=$Gtk\share\glib-2.0\schemas"
set "XDG_DATA_DIRS=$Gtk\share"
set "VLC_PLUGIN_PATH=$VlcLaufzeit\plugins"
start "" "%~dp0SwiftlyWindows.exe" %*
"@
Set-Content -Path (Join-Path $bau 'Swiftly.cmd') -Value $starter -Encoding ascii

Sag "fertig: $bau\Swiftly.cmd"
if ($Starten) { & (Join-Path $bau 'Swiftly.cmd') }
