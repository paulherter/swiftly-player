# Windows release in the VM: build, pack, verify, build the installer, send it back.
# ASCII only (PowerShell 5.1 reads UTF-8 without BOM as ANSI).
$w = 'http://10.0.2.2:8097'
$bericht = "$env:USERPROFILE\release-bericht.txt"
function Notiz($t) { Write-Host $t -ForegroundColor Cyan; Add-Content $bericht $t }
Set-Content $bericht "Release-Bericht $(Get-Date -Format s)"
Set-Location C:\swiftly\Windows

Notiz "== Release bauen =="
.\build.ps1 -Konfiguration release
if ($LASTEXITCODE -ne 0) { Notiz "BAU FEHLGESCHLAGEN $LASTEXITCODE" }

Notiz "== Packen =="
.\Install\package.ps1
# The name depends on the toolchain: .resources up to Swift 6.3, .bundle from 6.4.
$buendel = @('.resources', '.bundle') |
    ForEach-Object { ".\Output\Swiftly\bin\SwiftlyWindows_SwiftlyWindows$_" } |
    Where-Object { Test-Path $_ }
if ($buendel) { Notiz ("Buendel in der Ablage: " + ($buendel -join ', ')) }
else { Notiz "Buendel in der Ablage: KEINS" }

# The actual check: remove the build folder so Bundle.module cannot fall back
# to it; that is exactly what has hidden the error so far.
Notiz "== Probe ohne Bauordner =="
$bau = "C:\swiftly\Windows\.build"
Rename-Item $bau "$bau-weg" -ErrorAction SilentlyContinue
$log = "$env:APPDATA\Swiftly\swiftly.log"
Remove-Item $log -ErrorAction SilentlyContinue
$p = Start-Process ".\Output\Swiftly\Swiftly.exe" -PassThru
Start-Sleep -Seconds 20
$laeuft = -not $p.HasExited
Notiz ("App laeuft nach 20 s: " + $laeuft)
if (Test-Path $log) { Get-Content $log -Tail 8 | ForEach-Object { Notiz "  log: $_" } }
Get-Process SwiftlyWindows,Swiftly -ErrorAction SilentlyContinue | Stop-Process -Force
Rename-Item "$bau-weg" $bau -ErrorAction SilentlyContinue

Notiz "== Installer =="
& "C:\Program Files\Inno Setup 7\ISCC.exe" .\Install\Swiftly.iss | Select-Object -Last 3
$exe = Get-ChildItem .\Output\Swiftly-*-Setup.exe | Sort-Object LastWriteTime | Select-Object -Last 1
Notiz ("Installer: " + $exe.Name + " " + $exe.Length)
if ($exe) { Invoke-WebRequest "$w/$($exe.Name)" -Method Put -InFile $exe.FullName -UseBasicParsing | Out-Null }
Invoke-WebRequest "$w/release-bericht.txt" -Method Put -InFile $bericht -UseBasicParsing | Out-Null
Notiz "== RELEASE ENDE =="
