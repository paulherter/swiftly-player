# Windows-Release in der VM: bauen, packen, pruefen, Installer schnueren, zurueckschicken.
# Nur ASCII (PowerShell 5.1 liest UTF-8 ohne BOM als ANSI).
$w = 'http://10.0.2.2:8097'
$bericht = "$env:USERPROFILE\release-bericht.txt"
function Notiz($t) { Write-Host $t -ForegroundColor Cyan; Add-Content $bericht $t }
Set-Content $bericht "Release-Bericht $(Get-Date -Format s)"
Set-Location C:\swiftly\Windows

Notiz "== Release bauen =="
.\bauen.ps1 -Konfiguration release
if ($LASTEXITCODE -ne 0) { Notiz "BAU FEHLGESCHLAGEN $LASTEXITCODE" }

Notiz "== Packen =="
.\Installieren\packen.ps1
$buendel = ".\Ablage\Swiftly\bin\SwiftlyWindows_SwiftlyWindows.resources"
Notiz ("Buendel in der Ablage: " + (Test-Path $buendel))

# Die eigentliche Probe: den Bauordner wegnehmen, damit Bundle.module nicht
# darauf zurueckfallen kann - genau das hat den Fehler bisher verdeckt.
Notiz "== Probe ohne Bauordner =="
$bau = "C:\swiftly\Windows\.build"
Rename-Item $bau "$bau-weg" -ErrorAction SilentlyContinue
$log = "$env:APPDATA\Swiftly\swiftly.log"
Remove-Item $log -ErrorAction SilentlyContinue
$p = Start-Process ".\Ablage\Swiftly\Swiftly.exe" -PassThru
Start-Sleep -Seconds 20
$laeuft = -not $p.HasExited
Notiz ("App laeuft nach 20 s: " + $laeuft)
if (Test-Path $log) { Get-Content $log -Tail 8 | ForEach-Object { Notiz "  log: $_" } }
Get-Process SwiftlyWindows,Swiftly -ErrorAction SilentlyContinue | Stop-Process -Force
Rename-Item "$bau-weg" $bau -ErrorAction SilentlyContinue

Notiz "== Installer =="
& "C:\Program Files\Inno Setup 7\ISCC.exe" .\Installieren\Swiftly.iss | Select-Object -Last 3
$exe = Get-ChildItem .\Ablage\Swiftly-*-Setup.exe | Sort-Object LastWriteTime | Select-Object -Last 1
Notiz ("Installer: " + $exe.Name + " " + $exe.Length)
if ($exe) { Invoke-WebRequest "$w/$($exe.Name)" -Method Put -InFile $exe.FullName -UseBasicParsing | Out-Null }
Invoke-WebRequest "$w/release-bericht.txt" -Method Put -InFile $bericht -UseBasicParsing | Out-Null
Notiz "== RELEASE ENDE =="
