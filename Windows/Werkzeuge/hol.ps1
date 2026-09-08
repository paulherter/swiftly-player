# Quellen vom Wirt holen und bauen. Wird von `bruecke.sh` ausgeliefert.
#
# ZWEI REGELN FUER JEDE .ps1, DIE HIER LANDET:
#
# 1. **Nur ASCII.** PowerShell 5.1 liest eine UTF-8-Datei ohne BOM als
#    ANSI. Ein Gedankenstrich wird dann zu drei Zeichen und zerlegt den
#    String, in dem er steht; der Parser meldet den Fehler an einer Stelle,
#    an der nichts falsch ist. Dieselbe Falle trifft `Select-String`:
#    ein Muster mit Umlaut findet eine Zeile nicht, die dasteht - was
#    einmal wie ein fehlendes Uebersetzungsbuendel aussah und keines war.
#    Wer Dateiinhalte prueft, gibt `-Encoding UTF8` mit.
#
# 2. **Nichts nach C:\ schreiben.** Ohne Administrator ist die Wurzel nicht
#    beschreibbar; `Invoke-WebRequest -OutFile C:\x` bricht mit "Access to
#    the path is denied" ab. Alles unter $env:USERPROFILE.
$w = 'http://10.0.2.2:8099'
$heim = $env:USERPROFILE
Write-Host "== Hole Quellen ==" -ForegroundColor Cyan
Invoke-WebRequest "$w/quellen.zip" -OutFile "$heim\quellen.zip" -UseBasicParsing
Expand-Archive "$heim\quellen.zip" -DestinationPath C:\swiftly -Force
Write-Host "== Baue ==" -ForegroundColor Cyan
Set-Location C:\swiftly\Windows
& .\bauen.ps1 *>&1 | Tee-Object "$heim\bau.log" | Out-Null
Write-Host "== Ergebnis ==" -ForegroundColor Cyan
$treffer = Select-String -Path "$heim\bau.log" -Pattern 'error:|Build complete|Fertig:|FEHLT|Abgebrochen|denied' |
           Select-Object -First 18 | ForEach-Object { $_.Line.Trim() }
if ($treffer) { $treffer } else { Get-Content "$heim\bau.log" -Tail 12 }
Write-Host "== Ende ==" -ForegroundColor Cyan
