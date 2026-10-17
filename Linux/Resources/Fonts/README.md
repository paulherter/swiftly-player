# Inter

The UI typeface, bundled instead of expected from the system.

**Why it is bundled.** On the Mac the UI font is SF Pro, which exists only
there. Inter is its closest relative: same construction, same stroke weights,
open license. It is often already installed on Linux; on Windows never, where
the UI would fall back to Segoe UI and look clearly different from the Mac.
Since all platforms should look the same, the app ships the font itself.

Two files are enough: `InterVariable.ttf` covers all weights, the italic file
covers emphasis.

`Inter-SemiBold.ttf` (static, Inter 18pt SemiBold) is the subtitle font.
libVLC 3 looks up fonts with its own fontconfig session and only chooses
between regular and bold; a static file with its own family name is found
reliably (`Untertitelstil` in `Player.swift`).

**License:** SIL Open Font License 1.1, see `OFL.txt`. Redistribution is
allowed, including bundled in a program; the license text must accompany it,
which is why it is here.

Version 4.1, from <https://github.com/rsms/inter>.
