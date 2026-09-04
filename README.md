<div align="center">

<img src=".github/bilder/banner.png" alt="Swiftly for Jellyfin" width="100%">

<br>

[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS%20%7C%20tvOS%20%7C%20macOS%20%7C%20Linux-0B0B0D?style=flat-square&labelColor=0B0B0D&color=5CD1C2)](#-platforms)
[![License](https://img.shields.io/badge/license-MPL--2.0-0B0B0D?style=flat-square&labelColor=0B0B0D&color=5CD1C2)](LICENSE)
[![Jellyfin](https://img.shields.io/badge/Jellyfin-10.10%2B-0B0B0D?style=flat-square&labelColor=0B0B0D&color=5CD1C2)](https://jellyfin.org)

<br>

[![Join the beta on TestFlight](https://img.shields.io/badge/TestFlight-Join%20the%20beta-0B0B0D?style=for-the-badge&labelColor=0B0B0D&color=5CD1C2&logo=apple&logoColor=0B0B0D)](https://testflight.apple.com/join/MqeP2cnj)
&nbsp;
[![Discord](https://img.shields.io/badge/Discord-Bugs%20%26%20feedback-0B0B0D?style=for-the-badge&labelColor=0B0B0D&color=5865F2&logo=discord&logoColor=white)](https://discord.gg/MeGwfv3UwN)

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
| 🪟 Windows | planned |

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
echo "deb [arch=amd64 trusted=yes] https://paulherter.github.io/swiftly-for-jellyfin/deb ./" | sudo tee /etc/apt/sources.list.d/swiftly.list
sudo apt update && sudo apt install swiftly-jellyfin
```

**Fedora, Nobara, RHEL, Rocky, AlmaLinux**

```sh
sudo tee /etc/yum.repos.d/swiftly.repo <<'EOF'
[swiftly]
name=Swiftly for Jellyfin
baseurl=https://paulherter.github.io/swiftly-for-jellyfin/rpm
enabled=1
gpgcheck=0
EOF
sudo dnf install swiftly-jellyfin
```

**Arch, CachyOS, Manjaro, EndeavourOS, Garuda**

```sh
sudo tee -a /etc/pacman.conf <<'EOF'

[swiftly]
SigLevel = Optional TrustAll
Server = https://paulherter.github.io/swiftly-for-jellyfin/arch
EOF
sudo pacman -Sy swiftly-jellyfin
```

**openSUSE Tumbleweed**

```sh
sudo zypper addrepo -f -G https://paulherter.github.io/swiftly-for-jellyfin/rpm swiftly
sudo zypper install swiftly-jellyfin
```

**Anything else** — build it yourself. Same script, one flag:
`… | bash -s -- --aus-quelle`. It pulls the dependencies from your
distribution, fetches Swift into `$HOME`, and builds.

</details>

**Requirements: GTK 4.14 and libVLC.** That is what rules out the older
releases — Debian 12 ships GTK 4.8 and could not draw the app at all. The
packages are built against Ubuntu 24.04 for glibc, which is the same floor
GTK already sets, so it costs nothing.

**Why packages and not a Flatpak.** Measured, not assumed: the GNOME 48
runtime carries GTK 4 but not a single libVLC library. A Flatpak would have
to compile VLC itself — and VLC's demuxers are exactly what "never
transcodes" rests on.

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
