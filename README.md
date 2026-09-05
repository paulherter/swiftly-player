<div align="center">

<img src=".github/bilder/wortmarke.svg" alt="Swiftly" width="300">

<br>

[![Plattformen](https://img.shields.io/badge/iOS_·_iPadOS_·_tvOS_·_macOS_·_Linux_·_Windows-1E1E22?style=flat-square&labelColor=1E1E22)](#-platforms)
&nbsp;
[![Lizenz](https://img.shields.io/badge/MPL--2.0-1E1E22?style=flat-square&labelColor=1E1E22)](LICENSE)
&nbsp;
[![Jellyfin](https://img.shields.io/badge/Jellyfin_10.10+-1E1E22?style=flat-square&labelColor=1E1E22)](https://jellyfin.org)

<br>

[![Join the beta on TestFlight](https://img.shields.io/badge/Join_the_beta-5CD1C2?style=for-the-badge&logo=apple&logoColor=FFFFFF)](https://testflight.apple.com/join/MqeP2cnj)
&nbsp;
[![Download for Windows](https://img.shields.io/badge/Windows-1E1E22?style=for-the-badge&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxyZWN0IHg9IjMiIHk9IjMiIHdpZHRoPSI4IiBoZWlnaHQ9IjgiIHJ4PSIxIi8%2BPHJlY3QgeD0iMTMiIHk9IjMiIHdpZHRoPSI4IiBoZWlnaHQ9IjgiIHJ4PSIxIi8%2BPHJlY3QgeD0iMyIgeT0iMTMiIHdpZHRoPSI4IiBoZWlnaHQ9IjgiIHJ4PSIxIi8%2BPHJlY3QgeD0iMTMiIHk9IjEzIiB3aWR0aD0iOCIgaGVpZ2h0PSI4IiByeD0iMSIvPjwvc3ZnPg%3D%3D&logoColor=5CD1C2)](#-windows)
&nbsp;
[![Install on Linux](https://img.shields.io/badge/Linux-1E1E22?style=for-the-badge&logo=linux&logoColor=5CD1C2)](#-linux)
&nbsp;
[![Bugs and feedback on Discord](https://img.shields.io/badge/Discord-1E1E22?style=for-the-badge&logo=discord&logoColor=5CD1C2)](https://discord.gg/MeGwfv3UwN)

<br>

</div>

<br>

**Swiftly for Jellyfin is a client for your own Jellyfin server. It is meant to
be plain, and to just work.**

There is no long feature list here, and that is deliberate. It opens, it finds
your library, it plays. Resume where you stopped, subtitles, Picture in
Picture — the ordinary things, done properly, instead of a hundred switches
nobody ever touches.

Underneath, it works hard not to make your server transcode, so the picture
stays untouched and your CPU stays cool. You should never have to think about
that, which is rather the point.

<br>

## 📸 Screenshots

<table>
<tr>
<td width="25%"><img src=".github/bilder/startseite.png" alt="Home"></td>
<td width="25%"><img src=".github/bilder/detail-spritefright.png" alt="Detail"></td>
<td width="25%"><img src=".github/bilder/player-quer.png" alt="Player"></td>
<td width="25%"><img src=".github/bilder/bild-im-bild.png" alt="Picture in Picture"></td>
</tr>
<tr>
<td align="center"><sub>Home</sub></td>
<td align="center"><sub>Detail</sub></td>
<td align="center"><sub>Player</sub></td>
<td align="center"><sub>Picture in Picture</sub></td>
</tr>
</table>

<br>

## 🌟 Features

- 🎯 **Never transcode**: the device profile declares containers, codecs and
  every subtitle format, so the server has no reason to re-encode. Undeclared
  subtitles are the most common cause of a needless transcode, and they are
  all declared here.
- 🪟 **Picture in Picture** on iPhone and iPad — the one thing that sent me
  looking for another client in the first place.
- ⏯️ **Resume** exactly where you stopped, with the next episode following on
  its own.
- 🔑 **Quick Connect**, so you never type a password on a television remote.
- 🎧 **Audio and subtitle tracks** switch while the film keeps running.
- 📚 **Several libraries** of the same kind, and the app remembers which one
  you were in.
- 🚫 **No account, no subscription, no ads, no tracking.** Nothing leaves your
  device except the requests to the server you enter yourself.

<br>

## 📱 Platforms

One app, one design, sized for the screen you are on. The logic — server
access, device profile, playback timing — is shared; only the views differ,
and only where distance, input or window size demand it.

| Platform | State |
|---|---|
| 📱 iPhone | **1.0.0 (9)** · beta on TestFlight |
| 📲 iPad | **1.0.0 (9)** · ships with the iPhone app |
| 📺 Apple TV | **1.0.0 (9)** · beta on TestFlight |
| 💻 Mac | **1.0.0 (9)** · beta on TestFlight |
| 🐧 Linux | **1.0.0** · GTK4, native, same shared logic · [install](#-linux) |
| 🪟 Windows | **1.0.0** · GTK4 like Linux, **the same source** · [download](#-windows) |

**The beta is open.** [Join on TestFlight](https://testflight.apple.com/join/MqeP2cnj)
— one link for iPhone, iPad, Apple TV and Mac. What each build wants tested is
written in its release notes, and it is usually five specific things rather
than "have a look around".

<br>

## 🐧 Linux

One command. It works out which distribution you are on, adds the Swiftly
package source, and installs from it — so **updates arrive with your normal
system update**, like any other program.

```sh
curl -fsSL https://raw.githubusercontent.com/paulherter/swiftly-for-jellyfin/main/Linux/Installieren/swiftly-installieren.sh | bash
```

<details>
<summary>Or add the source yourself</summary>

**Debian, Ubuntu, Linux Mint, Pop!_OS, elementary, Zorin**

```sh
sudo install -d -m755 /etc/apt/keyrings
curl -fsSL https://paulherter.github.io/swiftly-for-jellyfin/swiftly.gpg | sudo tee /etc/apt/keyrings/swiftly.asc >/dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/swiftly.asc] https://paulherter.github.io/swiftly-for-jellyfin/deb ./" | sudo tee /etc/apt/sources.list.d/swiftly.list
sudo apt update && sudo apt install swiftly-jellyfin
```

**Fedora, Nobara, RHEL, Rocky, AlmaLinux**

```sh
sudo tee /etc/yum.repos.d/swiftly.repo <<'EOF'
[swiftly]
name=Swiftly for Jellyfin
baseurl=https://paulherter.github.io/swiftly-for-jellyfin/rpm
enabled=1
gpgcheck=1
gpgkey=https://paulherter.github.io/swiftly-for-jellyfin/swiftly.gpg
EOF
sudo dnf install swiftly-jellyfin
```

**Arch, CachyOS, Manjaro, EndeavourOS, Garuda**

```sh
curl -fsSL https://paulherter.github.io/swiftly-for-jellyfin/swiftly.gpg | sudo pacman-key --add -
sudo pacman-key --lsign-key 705D676A71BF0121804A90BAC8589885A042FB8B
sudo tee -a /etc/pacman.conf <<'EOF'

[swiftly]
SigLevel = Required DatabaseOptional
Server = https://paulherter.github.io/swiftly-for-jellyfin/arch
EOF
sudo pacman -Sy swiftly-jellyfin
```

**openSUSE Tumbleweed**

```sh
sudo rpm --import https://paulherter.github.io/swiftly-for-jellyfin/swiftly.gpg
sudo zypper addrepo -f https://paulherter.github.io/swiftly-for-jellyfin/rpm swiftly
sudo zypper install swiftly-jellyfin
```

**Anything else** — build it yourself. Same script, one flag:
`… | bash -s -- --aus-quelle`. It pulls the dependencies from your
distribution, fetches Swift into `$HOME`, and builds.

</details>

The packages are signed; the key's fingerprint is
`705D 676A 71BF 0121 804A  90BA C858 9885 A042 FB8B`.

**Requirements: GTK 4.14 and libVLC.** That is what rules out the older
releases — Debian 12 ships GTK 4.8 and could not draw the app at all. The
packages are built against Ubuntu 24.04 for glibc, which is the same floor
GTK already sets, so it costs nothing.

**Why packages and not a Flatpak.** Measured, not assumed: the GNOME 48
runtime carries GTK 4 but not a single libVLC library. A Flatpak would have
to compile VLC itself — and VLC's demuxers are exactly what "never
transcodes" rests on.

<br>

## 🪟 Windows

**[Download Swiftly-1.0.0-Setup.exe](https://github.com/paulherter/swiftly-for-jellyfin/releases/download/v1.0.0/Swiftly-1.0.0-Setup.exe)** — 80 MB, Windows 10 and 11, 64-bit.

The installer puts Swiftly where it belongs: Program Files (or your own folder
if you run it without admin rights — you choose in the dialog), a Start menu
entry, an optional desktop icon, and a proper uninstall. No unpacking a zip and
wondering where the folder should go.

**Windows will warn you the first time.** SmartScreen shows a blue box saying
the publisher is unknown: click **More info**, then **Run anyway**. That warning
is not about this app being unsafe — it means the installer carries no paid
code-signing certificate. Jellyfin's own desktop app is in exactly the same
position. The checksum below is there so you can verify what you downloaded:

```
SHA256  2a8a30616de1399fb5643fa8ae0118f9c828eb352b1a6cd7f0e6c3dbc9899b3f
```

**It is the same program as on Linux** — the same 8,900 lines of interface,
mirrored into the Windows build; what differs sits behind seven `#if` marks in
those same files. GTK 4, libVLC and the Swift runtime all ship inside the
installer, so there is nothing else to install.

<br>

## 📖 Documentation

- 🛠️ [Building](Documentation/Building.md) — clone, fetch VLCKit, generate the
  project, run the tests
- 🎬 [VLCKit](Documentation/VLCKit.md) — why this app ships a patched build,
  with the measurements
- 📐 [Device profile](Packages/JellyfinKit/Sources/JellyfinKit/DeviceProfile.swift)
  — the file that decides whether your server transcodes, with the reasoning
  in its comments

<br>

## ✅ Requirements

- Your own Jellyfin server, **10.10 or newer**. Swiftly for Jellyfin hosts
  nothing and has no account of its own — you sign in with the credentials you
  already have.
- iOS 18, tvOS 18 or macOS 15 — or a Linux desktop with GTK 4 and libVLC,
  which the installer takes care of.

<br>

## 🐞 Reporting bugs

The Discord is the fastest way: **https://discord.gg/MeGwfv3UwN** — there are
channels for bug reports and feature requests, and a beta chat.

If you are on the TestFlight build, the release notes name the handful of
things that changed since the last one. Reports against those are worth the
most, because they can be traced to a specific change.

The single most useful report is one where **the server transcoded when it
should not have.** If your Jellyfin dashboard says *Transcoding* instead of
*Direct Play* or *Direct Stream*, please include the container, video codec,
audio codec and subtitle format of that file.

<br>

## 🤖 Built with Claude

Swiftly for Jellyfin was written together with Anthropic's Claude, and the
commit history says so — every commit carries a `Co-Authored-By` line. The
decisions, the testing and the responsibility are mine; a good deal of the
typing was not. It seemed more honest to say that here than to let someone
work it out.

<br>

## 📄 License

The code is licensed under the **Mozilla Public License 2.0** — see
[LICENSE](LICENSE). In short: you may use, change and redistribute it, and if
you change these files you publish your changes too.

**The name and the artwork are not covered by that license.** "Swiftly for
Jellyfin", the wordmark and the app icon remain the author's. You are welcome
to fork the code; please do not ship the result under this name or with this
icon.

Playback uses [VLCKit](https://code.videolan.org/videolan/VLCKit) under the
**LGPL-2.1-or-later** — see [Documentation/VLCKit.md](Documentation/VLCKit.md).

The screenshots show films by the [Blender
Foundation](https://studio.blender.org/films/) — *Big Buck Bunny*, *Sintel*,
*Agent 327*, *Sprite Fright* and others — released under Creative Commons
Attribution.
