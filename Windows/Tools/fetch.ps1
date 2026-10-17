# Fetch sources from the host and build. Delivered by `bridge.sh`.
#
# TWO RULES FOR EVERY .ps1 THAT LANDS HERE:
#
# 1. **ASCII only.** PowerShell 5.1 reads a UTF-8 file without BOM as ANSI. A
#    dash then becomes three characters and breaks the string it sits in; the
#    parser reports the error at a place where nothing is wrong. The same trap
#    hits `Select-String`: a pattern with an umlaut does not find a line that is
#    there, which once looked like a missing translation bundle and was not.
#    When checking file contents, pass `-Encoding UTF8`.
#
# 2. **Write nothing to C:\.** Without administrator rights the root is not
#    writable; `Invoke-WebRequest -OutFile C:\x` aborts with "Access to the
#    path is denied". Everything goes under $env:USERPROFILE.
$w = 'http://10.0.2.2:8099'
$heim = $env:USERPROFILE
Write-Host "== Hole Quellen ==" -ForegroundColor Cyan
Invoke-WebRequest "$w/quellen.zip" -OutFile "$heim\quellen.zip" -UseBasicParsing

# **Clear first, then unpack.** `Expand-Archive -Force` overlays and removes
# nothing. If a file is renamed or deleted, both end up in the VM, and
# `build.ps1` mirrors whatever is there. That once left 54 Swift files instead
# of 24, and the build broke on a file that did not exist in the delivered
# state.
#
# Only the mirror source is cleared, not the whole checkout: it holds `.build`
# and the fetched tools, and fetching them again takes minutes.
$quelle = "C:\swiftly\Linux\Sources"
if (Test-Path $quelle) { Remove-Item -Recurse -Force $quelle }

Expand-Archive "$heim\quellen.zip" -DestinationPath C:\swiftly -Force

# **AppleDouble is dropped.** macOS creates a `._name` next to every file once
# it passes through a foreign filesystem. They match `*.swift`, get mirrored
# along and end up in the build.
Get-ChildItem C:\swiftly -Recurse -Force -Filter "._*" -ErrorAction SilentlyContinue |
  Remove-Item -Force -ErrorAction SilentlyContinue
Write-Host "== Baue ==" -ForegroundColor Cyan
Set-Location C:\swiftly\Windows
& .\build.ps1 *>&1 | Tee-Object "$heim\bau.log" | Out-Null
Write-Host "== Ergebnis ==" -ForegroundColor Cyan
$treffer = Select-String -Path "$heim\bau.log" -Pattern 'error:|Build complete|Fertig:|FEHLT|Abgebrochen|denied' |
           Select-Object -First 18 | ForEach-Object { $_.Line.Trim() }
if ($treffer) { $treffer } else { Get-Content "$heim\bau.log" -Tail 12 }
Write-Host "== Ende ==" -ForegroundColor Cyan
