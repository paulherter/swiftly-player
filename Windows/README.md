# Swiftly for Windows

The same UI as on Linux, not a second one.

## Why GTK4 and not Win32

GTK4 is available for Windows as an MSVC build, including `pkg-config.exe` and
the `.pc` files: **gvsbuild**. The Windows build therefore talks to the same C
interface as the Linux build, and the ~8,900 lines of UI code apply to both.

The alternative would have been Win32 with Direct2D. It would have gained
nothing: the app draws almost everything itself (tiles, sliders, skip icons,
the whole player) because the design should be identical on every platform.
Looking native is not a goal worth the effort here; looking identical is.

## How the shared source gets here

It exists exactly once in the repo, under `Linux/Sources/SwiftlyLinux`.

SwiftPM does not allow targets outside the package directory (the error reads
*"target ... is outside the package root"*). So `build.ps1` mirrors the files
to `Sources/SwiftlyWindows` before every build, and the mirror is gitignored.
There is no second copy in the repo that could drift apart.

Whatever differs between the platforms is written as `#if` **inside these
shared files**, not in a copy:

| Where | What | Why |
|---|---|---|
| `Platform.swift` | binary path, resource location, settings folder | `/proc/self/exe` and `XDG_CONFIG_HOME` do not exist here |
| `CharacterItem.swift` | `.desktop` entry only on Linux | Wayland takes the window icon from that file; Windows does not |
| `Cache.swift` | Unix permissions only on Linux | `%APPDATA%` is private through its ACL anyway |
| `Player.swift` | `--no-xlib` removed, `VLC_PLUGIN_PATH` set | libVLC does not find its modules by itself here |
| `imagebridge.c` | SRWLOCK instead of pthread | `pthread` does not exist under MSVC |
| `Style.swift` | Segoe UI in the font chain | no `#if` needed: a system skips fonts it does not have |

## What must be on the machine

| | Location | Source |
|---|---|---|
| GTK4 (MSVC) | `C:\Werkzeuge\gtk4` | [gvsbuild release](https://github.com/wingtk/gvsbuild/releases), `GTK4_Gvsbuild_*_x64.zip` |
| libVLC SDK | `C:\Werkzeuge\vlcsdk` | `vlc-3.0.21-win64.7z`, folder `sdk` |
| libVLC runtime | `C:\Werkzeuge\vlc\vlc-3.0.21` | `vlc-3.0.21-win64.zip` |
| Build Tools | n/a | `vs_BuildTools.exe --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64` |
| Swift | n/a | swift.org, Windows installer |

Other locations work too; `build.ps1` takes them as parameters.

## Building

```powershell
.\build.ps1            # build
.\build.ps1 -Starten   # build and run
.\build.ps1 -Symbole   # additionally produce a PDB
```

**Use `-Symbole` when something crashes.** Without debug information no PDB is
produced, and the Windows event log reports a crash only as an offset into the
binary. With a PDB it can be resolved:

```powershell
# Offset from the event ("Fault offset") plus image base 0x140000000
'0x1401b1f84' | & llvm-symbolizer.exe --obj=.build\debug\SwiftlyWindows.exe --demangle
```

This is how a startup crash hitting every third or fourth launch was found:
`rlottie::Animation::renderSync` on freed memory. Seven guesses before it were
all wrong; the PDB answered it in one pass.

The script mirrors the shared sources, builds, and then places GTK, libVLC and
**VLC's modules** next to the program. The last part is not optional: Windows
looks for DLLs next to the executable, not via a search path, and without the
modules the player starts without a single decoder.

## Unverified paths

What builds here has not necessarily run. The difference is worth writing
down, otherwise the next session takes "compiled" for "verified".

- **Discord Rich Presence.** The chain is verified up to the pipe in the
  running program: with the switch on, the tick reports every second

      [Paket] [Discord] Stand: erlaubt=true dauer=6778 stelle=4233
                              laeuft=true titel=Beauty & The Nerd

  So the setting takes effect, VLC knows the duration (`guard dauer > 0`
  holds), the position advances, the title is right. **Only
  `CreateFileW`/`WriteFile` remain open**: the test machine has no Discord, so
  there is no `\\.\pipe\discord-ipc-*`. The framing itself is verified over a
  Unix socket on the Mac, and Linux uses the same path.

  **Careful when interpreting:** if `verbinden()` fails, it writes **nothing**
  (no error, no line). A log without a pipe entry therefore does not even prove
  that a connection was *attempted*.
- **The language switch** (`Textkatalog.systemsprachen()`,
  `GetUserPreferredUILanguages`). Builds and runs, but the decisive case is
  missing: the test Windows itself is set to English (`CurrentUICulture=en-US`),
  so "it shows English" proves nothing. Only a Windows set to German separates
  the cases.
- **Account switching.** Built, but never exercised; it needs a second
  Jellyfin account and its password.

- **An empty log does not mean nothing ran.** `Spur` writes through `print` to
  `stdout`, and `stdout` is block-buffered (about 4 KB) once redirected to a
  file. At one line per second that is around **thirty seconds** during which
  the file stays empty. A hard `Stop-Process` does **not** flush the buffer,
  and the lines are lost for good. Anyone who measures briefly and looks at the
  log takes a running process for dead. So: let it run long enough, and do not
  kill it.

## The package tests run here

```powershell
cd ..\Packages\JellyfinKit
swift test
```

All 194 tests in 35 suites pass. That is more than a formality: `JellyfinKit`
is thereby *verified* on a third platform, not just compiled. Logic moved into
the package instead of the view can be checked here without a UI, on Windows
just as on the Mac.

## Shipping

```powershell
.\build.ps1 -Konfiguration release
.\Install\package.ps1
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" .\Install\Swiftly.iss
```

The result is `Output\Swiftly-1.0.0-Setup.exe`, about 80 MB from 356 MB of
staged files. The installer creates a Start menu entry, optionally a desktop
icon, and an uninstaller; without admin rights it installs into the user's own
folder, with them into "Program Files".

**It is not signed.** Windows shows a SmartScreen warning when opening the
installer. Only a purchased certificate fixes that, not anything in the
script, and it cannot be explained in the installer window because there is
none yet. That is why this text appears in every release description:

> Windows may show "Windows protected your PC" because the installer isn't
> code-signed. Click **More info**, then **Run anyway**. The first launch
> after installing can take up to a minute while Windows checks the app; a
> small window shows what's happening in the meantime.

## Launcher and log

Shortcuts point to `Swiftly.exe` in the install folder, not to
`bin\Swiftly.exe`. That is the **launcher** (`Launcher/`, plain Win32 in
C, system libraries only). On the first start of a new version, Defender checks
every unknown DLL before a single line of the app runs; measured at 23 s
without any window. The launcher appears immediately, shows what is happening,
and closes as soon as the app has a window. If the app ends earlier, or no
window appears after two minutes, it stays open and offers "Open log".

The log is at `%APPDATA%\Swiftly\swiftly.log`, with the previous run's next to
it as `swiftly.alt.log`. It receives everything the app writes to stdout and
stderr (including GLib warnings), plus the launcher's `[Start]` lines and the
app's `[Stufe]` lines. Above 16 MB it is truncated. Starting `bin\Swiftly.exe`
directly produces no log.

**A new stage** is reported by the app with `Startstufe.melden("name")`; its
display text goes into `stufen[]` in `launcher.c`. Without an entry the
window shows the raw name.

**`package.ps1` leaves out DLLs nobody imports**, starting from
`bin\Swiftly.exe`, `bin\plugins` and `lib` over all imports. For 1.0.2 that
was 50 of 101.

## Still missing

- **The now-playing tile in the notification area.** The keyboard media keys
  work; the tile with title and artwork needs the *System Media Transport
  Controls* and therefore WinRT, which is a separate piece of work.
- **No automatic updates.** Linux gets them through the package repository;
  Windows only has the installer so far.

## When Windows runs in a VM

If Windows is a libvirt VM on a Linux host, it has **no shared
folder**, only CD-ROMs, and those work in one direction only. What remains is
QEMU's user networking: the host is reachable from the guest at `10.0.2.2`.

```bash
Windows/Tools/bridge.sh ~/swiftly    # pack, deliver, trigger the build
```

The host provides the sources, types **one** line into a fresh PowerShell
window, and the VM fetches the rest itself. The result comes back through
`virsh screenshot`.

**Why a fresh window.** `virsh send-key` types wherever the keyboard currently
points, which cannot be seen from outside. Twice a command landed in some
foreground window and silently vanished; it only showed when a `Test-Path`
revealed that nothing had ever arrived. `Win+R` always leads to the same known
state.

**Two rules for every `.ps1` that goes there**, each of which cost a failed
attempt:

- **ASCII only.** PowerShell 5.1 reads a UTF-8 file without BOM as ANSI. A
  dash becomes three characters and breaks the string it sits in; the parser
  then reports the error at a place where nothing is wrong. The same trap hits
  `Select-String`: a pattern with an umlaut fails to find a line that is there.
  Once this looked like a missing translation bundle and was not. When
  checking file contents, pass `-Encoding UTF8`.
- **Write nothing to `C:\`.** Without administrator rights the root is not
  writable; `-OutFile C:\x` fails with "Access to the path is denied".
  Everything goes under `$env:USERPROFILE`.
