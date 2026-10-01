# Third-party notices

Swiftly Player is published under the MPL-2.0 (see `LICENSE`). It contains and uses the third-party components listed here. Each keeps its own license; the license texts are in `LICENSES/`. This file is generated from `LICENSES/bausteine.json` (`Werkzeuge/lizenzen-erzeugen.py`); do not edit it by hand.

## VLCKit / libVLC — Source and your rights

**Swiftly Player uses VLCKit and libVLC by VideoLAN (LGPL-2.1 or later).**

### What is used

Swiftly Player plays video and audio with VLCKit and libVLC by VideoLAN, which are licensed under the GNU Lesser General Public License, version 2.1 or (at your option) any later version (LGPL-2.1-or-later). Copyright VideoLAN and VLC authors. The full license text is included in this app and in LICENSES/LGPL-2.1-or-later.txt.

On Apple platforms (iPhone, iPad, Mac, Apple TV) the app contains VLCKit 4.0.0-a23 as a dynamic framework (VLCKit.framework), built from VideoLAN's sources with the Swiftly patches listed below. VLCKit in turn contains libVLC and the libraries listed on the licenses page; those libraries carry their own licenses. VLC is built without its GPL modules (--disable-gpl); FFmpeg is built without --enable-gpl.

On Windows the app ships the official VLC 3.0.21 runtime with its plugins, as distributed by VideoLAN. libVLC and libvlccore are LGPL-2.1-or-later; some of the bundled plugins are GPL-2.0-or-later (see COPYING in the source archive below for which). On Linux the app does not bundle libVLC but uses the one of your system.

### Source code

Upstream VLCKit: https://code.videolan.org/videolan/VLCKit, tag 4.0.0-a23 (commit e3774eb2).

Upstream libVLC: https://code.videolan.org/videolan/vlc, commit 2cd8705589 (the commit VLCKit 4.0.0-a23 pins as TESTEDHASH).

Bundled libraries: the exact release tarballs are those of VLC's contrib system (libvlc/vlc/contrib/src/*), in the versions listed on the licenses page.

VLC for Windows: the source archive of VLC 3.0.21 at https://download.videolan.org/pub/videolan/vlc/3.0.21/ (vlc-3.0.21.tar.xz). Swiftly does not patch this runtime.

Swiftly's changes: the patch files are public in Swiftly Player's repository, in Werkzeuge/vlckit-patches/ (https://github.com/paulherter/swiftly-player). Nine patches against libVLC (0028, 0030 to 0034 and 0036 to 0038) and one against VLCKit itself (VLCKit-pause-ohne-warteschlange.patch, for Sources/Playback/VLCMediaPlayer.m). Patch 0035 is in the same directory but is not part of any shipped build.

How to rebuild: Documentation/VLCKit.md in the same repository describes the steps, and Documentation/Building.md describes how to build Swiftly against your own VLCKit.

### Your rights

You may modify the library and use your modified version with Swiftly Player. To do so, build VLCKit from the sources above (with or without our patches), assemble Vendor/VLCKit-gepatcht.xcframework from your build, and build and sign Swiftly Player from its published source code as described in Documentation/Building.md. Swiftly Player's own code is published under the MPL-2.0.

You may copy and pass on the library under the terms of the LGPL. You may reverse engineer the application as far as needed to debug modifications of the library.

### Written offer

On request we will provide the complete corresponding source code of VLCKit, libVLC (including the VLC 3.0.21 runtime and plugins shipped for Windows) and the bundled libraries of every version of Swiftly Player that we distribute, including the Swiftly patches and the scripts used to build it, on a data medium or as a download. The offer is valid for at least three years after the release of the respective version. We may charge no more than the cost of physically performing the delivery.

Send the request, with the version and platform you have, to info@swiftlyplayer.com.

## Player

| Component | Version | License (SPDX) | Copyright | Source | Platforms |
|---|---|---|---|---|---|
| VLCKit | 4.0.0-a23, built with Swiftly's patches | LGPL-2.1-or-later | VideoLAN and VLC authors | https://code.videolan.org/videolan/VLCKit | Apple (iPhone, iPad, Mac, Apple TV) |
| libVLC (VLC core, libvlccore and modules) | VLC 4.0 development snapshot 2cd8705589 (Apple); libvlc-all 3.6.3 (Android) | LGPL-2.1-or-later | VideoLAN and VLC authors | https://www.videolan.org/vlc/ | Apple (iPhone, iPad, Mac, Apple TV), Android, Android TV |
| VLC 3.0.21 runtime and plugins (Windows) | 3.0.21 | LGPL-2.1-or-later AND GPL-2.0-or-later | VideoLAN and VLC authors | https://download.videolan.org/pub/videolan/vlc/3.0.21/ | Windows |
| libVLC of the system | as installed by your distribution (package dependency vlc / libvlc5) | LGPL-2.1-or-later | VideoLAN and VLC authors | https://www.videolan.org/vlc/ | Linux |
| Android: libVLC contents (libvlc-all) | libvlc-all 3.6.3 | LGPL-2.1-or-later | VideoLAN and VLC authors | https://code.videolan.org/videolan/vlc-android | Android, Android TV |

Notes:

- **VLCKit** — Modified: Swiftly ships a VLCKit built with its own patches (see the written offer above).
- **libVLC (VLC core, libvlccore and modules)** — On Apple platforms built with --disable-gpl, without VLC's GPL modules.
- **VLC 3.0.21 runtime and plugins (Windows)** — The official VLC 3.0.21 runtime with its plugins folder, as distributed by VideoLAN. libVLC and libvlccore are LGPL-2.1-or-later; some of the bundled plugins are GPL-2.0-or-later. See COPYING in the source archive (vlc-3.0.21.tar.xz) for the modules.
- **libVLC of the system** — Not bundled: the app uses the libVLC that your system provides. Its source code comes from your distribution.

## Application and fonts

| Component | Version | License (SPDX) | Copyright | Source | Platforms |
|---|---|---|---|---|---|
| Lottie (lottie-ios) | 4.6.1 | Apache-2.0 | Airbnb, Inc. | https://github.com/airbnb/lottie-ios | Apple (iPhone, iPad, Mac, Apple TV) |
| Inter (typeface) | Inter-SemiBold.ttf (18pt SemiBold); on Linux and Windows also InterVariable.ttf | OFL-1.1 | The Inter Project Authors | https://github.com/rsms/inter | Apple (iPhone, iPad, Mac, Apple TV), Linux, Windows |
| Figtree (typeface of the website) | Webfont, see Website/schrift/ | OFL-1.1 | The Figtree Project Authors | https://github.com/erikdkennedy/figtree | Website |
| Coil | 3.0.4 | Apache-2.0 | Coil Contributors | https://github.com/coil-kt/coil | Android, Android TV |
| OkHttp and Okio (via coil-network-okhttp) | as resolved by Gradle | Apache-2.0 | Square, Inc. | https://square.github.io/okhttp/ | Android, Android TV |
| Lottie for Android | 6.5.2 | Apache-2.0 | Airbnb, Inc. | https://github.com/airbnb/lottie-android | Android, Android TV |
| Kotlin standard library and kotlinx.coroutines | Kotlin 2.0.21; coroutines 1.10.2 | Apache-2.0 | JetBrains s.r.o. and Kotlin Programming Language contributors | https://kotlinlang.org | Android, Android TV |
| AndroidX (core-ktx 1.16.0, lifecycle-runtime-ktx 2.9.2, activity-compose 1.10.1, tvprovider 1.0.0) and Jetpack Compose (BOM 2024.09.00: ui, foundation, material3) | see the parentheses in the name | Apache-2.0 | The Android Open Source Project | https://developer.android.com/jetpack/androidx | Android, Android TV |
| Google Play In-App Review (review-ktx) | 2.0.2 | LicenseRef-Google-Play-Terms | Google LLC | https://developer.android.com/guide/playcore/in-app-review | Android, Android TV |
| swift-java (swiftkit-core, JNI bridge) and the Swift runtime on Android | swift-java 0.6.0; swiftkit-core without a fixed version in Gradle | Apache-2.0 | Apple Inc. and the Swift.org project authors | https://github.com/swiftlang/swift-java | Android, Android TV |
| GTK 4 and its libraries (GLib, Pango, Cairo, GdkPixbuf, HarfBuzz, FreeType, libpng and others) | bundled GTK 4 runtime (gvsbuild) on Windows; system library on Linux | LGPL-2.1-or-later | The GTK Team, The GNOME Project and the authors of the bundled libraries | https://www.gtk.org | Windows, Linux |
| Swift runtime and Foundation | version of the toolchain used | Apache-2.0 | Apple Inc. and the Swift.org project authors | https://www.swift.org | Windows, Linux, Android, Android TV |
| rlottie | current main branch at build time (Werkzeuge/rlottie-bauen.sh) | MIT | Samsung Electronics Co., Ltd. and the rlottie authors | https://github.com/Samsung/rlottie | Windows, Linux |
| libepoxy | system library | MIT | The Khronos Group Inc., Intel Corporation and the libepoxy authors | https://github.com/anholt/libepoxy | Linux, Windows |

Notes:

- **Figtree (typeface of the website)** — Website only; the license text is in Website/schrift/OFL.txt.
- **Google Play In-App Review (review-ktx)** — Proprietary, under Google's terms for the Play Core SDK.
- **swift-java (swiftkit-core, JNI bridge) and the Swift runtime on Android** — The Swift runtime and Foundation are Apache-2.0 with the Runtime Library Exception.
- **GTK 4 and its libraries (GLib, Pango, Cairo, GdkPixbuf, HarfBuzz, FreeType, libpng and others)** — Every bundled library carries its own license, mostly LGPL-2.1+, MIT or BSD.
- **Swift runtime and Foundation** — With the Runtime Library Exception.
- **rlottie** — Some parts (for example freetype excerpts, pixman) carry other licenses upstream.

## Libraries built into VLCKit (Apple)

| Component | Version | License (SPDX) | Copyright | Source | Platforms |
|---|---|---|---|---|---|
| FFmpeg (libavcodec, libavformat, libavutil, libswscale) | 8.1.2 | LGPL-2.1-or-later | The FFmpeg developers | https://ffmpeg.org | Apple (iPhone, iPad, Mac, Apple TV) |
| dav1d | 1.5.4 | BSD-2-Clause | VideoLAN and dav1d authors | https://code.videolan.org/videolan/dav1d | Apple (iPhone, iPad, Mac, Apple TV) |
| FLAC (libFLAC) | 1.5.0 | BSD-3-Clause | Josh Coalson; Xiph.Org Foundation | https://xiph.org/flac/ | Apple (iPhone, iPad, Mac, Apple TV) |
| FluidLite | Commit b0f187b404e393ee0a495b277154d55d7d03cbeb | LGPL-2.1-or-later | FluidLite and FluidSynth authors | https://github.com/divideconcept/FluidLite | Apple (iPhone, iPad, Mac, Apple TV) |
| FreeType | 2.13.1 | FTL | The FreeType Project (David Turner, Robert Wilhelm, Werner Lemberg and others) | https://freetype.org | Apple (iPhone, iPad, Mac, Apple TV) |
| GNU FriBidi | 1.0.16 | LGPL-2.1-or-later | The FriBidi authors | https://github.com/fribidi/fribidi | Apple (iPhone, iPad, Mac, Apple TV) |
| GSM 06.10 (libgsm) | 1.0-pl22 | LicenseRef-GSM | Jutta Degener and Carsten Bormann, Technische Universität Berlin | http://www.quut.com/gsm/ | Apple (iPhone, iPad, Mac, Apple TV) |
| HarfBuzz | 14.2.1 | MIT | Google, Inc.; Ebrahim Byagowi and others (see COPYING upstream) | https://github.com/harfbuzz/harfbuzz | Apple (iPhone, iPad, Mac, Apple TV) |
| LAME (libmp3lame) | 3.100 | LGPL-2.0-or-later | The LAME Project | https://lame.sourceforge.io | Apple (iPhone, iPad, Mac, Apple TV) |
| libarchive | 3.8.8 | BSD-2-Clause | Tim Kientzle and others | https://www.libarchive.org | iPhone, iPad, Mac |
| libaribcaption | 1.1.1 | MIT | magicxqq | https://github.com/xqq/libaribcaption | Apple (iPhone, iPad, Mac, Apple TV) |
| libass | 0.17.5 | ISC | libass contributors | https://github.com/libass/libass | Apple (iPhone, iPad, Mac, Apple TV) |
| libdsm | 0.4.3 | LGPL-2.1-or-later | VideoLabs and VideoLAN | https://github.com/videolabs/libdsm | Apple (iPhone, iPad, Mac, Apple TV) |
| libdvbpsi | 1.3.3 | LGPL-2.1-or-later | VideoLAN | https://code.videolan.org/videolan/libdvbpsi | Apple (iPhone, iPad, Mac, Apple TV) |
| libebml | 1.4.6 | LGPL-2.1-only | Steve Lhomme, Moritz Bunkus and the libebml authors | https://github.com/Matroska-Org/libebml | Apple (iPhone, iPad, Mac, Apple TV) |
| libmatroska | 1.7.2 | LGPL-2.1-only | Steve Lhomme, Moritz Bunkus and the libmatroska authors | https://github.com/Matroska-Org/libmatroska | Apple (iPhone, iPad, Mac, Apple TV) |
| libebur128 | 1.2.6 | MIT | Jan Kokemüller | https://github.com/jiixyj/libebur128 | Apple (iPhone, iPad, Mac, Apple TV) |
| Libgcrypt | 1.12.2 | LGPL-2.1-or-later | g10 Code GmbH and the GnuPG contributors | https://gnupg.org/software/libgcrypt/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libgpg-error | 1.61 | LGPL-2.1-or-later | g10 Code GmbH and the GnuPG contributors | https://gnupg.org/software/libgpg-error/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libjpeg-turbo | 3.1.4.1 | IJG AND BSD-3-Clause AND Zlib | The Independent JPEG Group; D. R. Commander and the libjpeg-turbo contributors | https://libjpeg-turbo.org | Apple (iPhone, iPad, Mac, Apple TV) |
| libmodplug | 0.8.9.0 | LicenseRef-PublicDomain | Olivier Lapicque, Konstanty Bialkowski and others (public domain) | https://modplug-xmms.sourceforge.net | Apple (iPhone, iPad, Mac, Apple TV) |
| libmysofa | 1.2.1 | BSD-3-Clause | Symonics GmbH, Christian Hoene | https://github.com/hoene/libmysofa | Apple (iPhone, iPad, Mac, Apple TV) |
| libnfs | 6.0.2 | LGPL-2.1-or-later | Ronnie Sahlberg and the libnfs contributors | https://github.com/sahlberg/libnfs | Apple (iPhone, iPad, Mac, Apple TV) |
| libogg | 1.3.6 | BSD-3-Clause | Xiph.Org Foundation | https://xiph.org/ogg/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libplacebo | 5.264.1 | LGPL-2.1-or-later | The libplacebo authors | https://code.videolan.org/videolan/libplacebo | Apple (iPhone, iPad, Mac, Apple TV) |
| libpng | 1.6.58 | libpng-2.0 | The PNG Reference Library Authors | http://www.libpng.org/pub/png/libpng.html | Apple (iPhone, iPad, Mac, Apple TV) |
| librist | 0.2.20 | BSD-2-Clause | VideoLAN and librist authors | https://code.videolan.org/rist/librist | Apple (iPhone, iPad, Mac, Apple TV) |
| libshout | 2.4.6 | LGPL-2.0-or-later | Xiph.Org Foundation | https://icecast.org/download/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libsmb2 | 6.1 | LGPL-2.1-or-later | Ronnie Sahlberg and the libsmb2 contributors | https://github.com/sahlberg/libsmb2 | Apple (iPhone, iPad, Mac, Apple TV) |
| libssh2 | 1.11.1 | BSD-3-Clause | Sara Golemon, Daniel Stenberg and the libssh2 contributors | https://libssh2.org | Apple (iPhone, iPad, Mac, Apple TV) |
| libtasn1 | 4.21.0 | LGPL-2.1-or-later | Free Software Foundation, Inc. | https://www.gnu.org/software/libtasn1/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libtheora | 1.2.0 | BSD-3-Clause | Xiph.Org Foundation | https://theora.org | Apple (iPhone, iPad, Mac, Apple TV) |
| libvorbis | 1.3.7 | BSD-3-Clause | Xiph.Org Foundation | https://xiph.org/vorbis/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libvpx | 1.16.0 | BSD-3-Clause | The WebM Project authors | https://www.webmproject.org/code/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libxml2 | 2.15.3 | MIT | Daniel Veillard and the libxml2 contributors | https://gitlab.gnome.org/GNOME/libxml2 | Apple (iPhone, iPad, Mac, Apple TV) |
| LIVE555 Streaming Media | 2016.10.21 | LGPL-2.1-or-later | Live Networks, Inc. | http://www.live555.com/liveMedia/ | Apple (iPhone, iPad, Mac, Apple TV) |
| mpg123 | 1.33.6 | LGPL-2.1-only | Michael Hipp and others | https://www.mpg123.de | Apple (iPhone, iPad, Mac, Apple TV) |
| OpenAPV | 0.3.0.0 | BSD-3-Clause | Samsung Electronics Co., Ltd. | https://github.com/AcademySoftwareFoundation/openapv | Apple (iPhone, iPad, Mac, Apple TV) |
| OpenCV | 4.4.0 | BSD-3-Clause | Intel Corporation, Willow Garage, Itseez and the OpenCV contributors | https://opencv.org | Apple (iPhone, iPad, Mac, Apple TV) |
| OpenJPEG | 2.5.4 | BSD-2-Clause | Université catholique de Louvain; Professor Benoit Macq; and others (see upstream LICENSE) | https://www.openjpeg.org | Apple (iPhone, iPad, Mac, Apple TV) |
| Opus | 1.6.1 | BSD-3-Clause | Xiph.Org Foundation, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla, Amazon | https://opus-codec.org | Apple (iPhone, iPad, Mac, Apple TV) |
| Protocol Buffers | 3.21.1 | BSD-3-Clause | Google Inc. | https://github.com/protocolbuffers/protobuf | iPhone, iPad, Mac |
| RNNoise | 0.1.1 | BSD-3-Clause | Mozilla; Jean-Marc Valin; Xiph.Org Foundation | https://gitlab.xiph.org/xiph/rnnoise | Apple (iPhone, iPad, Mac, Apple TV) |
| SoX Resampler (libsoxr) | 0.1.3 | LGPL-2.1-or-later | robs@users.sourceforge.net | https://sourceforge.net/projects/soxr/ | Apple (iPhone, iPad, Mac, Apple TV) |
| libspatialaudio | 0.3.0 | LGPL-2.1-or-later | Videolabs and the libspatialaudio authors | https://github.com/videolabs/libspatialaudio | Apple (iPhone, iPad, Mac, Apple TV) |
| Speex and SpeexDSP | 1.2.1 | BSD-3-Clause | Xiph.Org Foundation; Jean-Marc Valin | https://www.speex.org | Apple (iPhone, iPad, Mac, Apple TV) |
| TagLib | 2.3 | LGPL-2.1-only | Scott Wheeler, Lukáš Lalinský and the TagLib contributors | https://taglib.org | Apple (iPhone, iPad, Mac, Apple TV) |
| TwoLAME | 0.4.0 | LGPL-2.1-or-later | The TwoLAME project | https://www.twolame.org | iPhone, iPad, Apple TV |
| libupnp (pupnp) | 1.14.31 | BSD-3-Clause | Intel Corporation, Ricardo Rosales Hernandez, Todd Carmichael, Marcelo Roberto Jimenez and others | https://pupnp.github.io/pupnp/ | Apple (iPhone, iPad, Mac, Apple TV) |
| zlib | 1.3.2 | Zlib | Jean-loup Gailly and Mark Adler | https://zlib.net | Apple (iPhone, iPad, Mac, Apple TV) |
| ZVBI (libzvbi) | 0.2.44 | LGPL-2.0-or-later AND GPL-2.0-or-later AND BSD-2-Clause AND MIT | Michael H. Schimek, Iñaki García Etxebarria, Martin Buck, Edgar Toernig, Paul Ortyl and others | https://github.com/zapping-vbi/zvbi | Apple (iPhone, iPad, Mac, Apple TV) |
| glslang | 12.3.1 | BSD-3-Clause AND BSD-2-Clause AND MIT AND Apache-2.0 | The Khronos Group Inc., Google Inc., LunarG, NVIDIA, Advanced Micro Devices and others | https://github.com/KhronosGroup/glslang | Apple (iPhone, iPad, Mac, Apple TV) |
| glad | 2.0.4 | MIT | David Herberth | https://github.com/Dav1dde/glad | Apple (iPhone, iPad, Mac, Apple TV) |
| AOMedia AV1 (libaom) | 3.14.1 | BSD-2-Clause | Alliance for Open Media | https://aomedia.googlesource.com/aom/ | Mac |
| GNU libiconv | 1.18 | LGPL-2.0-or-later | Free Software Foundation, Inc. | https://www.gnu.org/software/libiconv/ | Mac |

Notes:

- **FFmpeg (libavcodec, libavformat, libavutil, libswscale)** — Built without --enable-gpl (license of the build: LGPL version 2.1 or later).
- **FreeType** — FreeType is available under the FreeType License or the GPL-2.0; Swiftly uses it under the FreeType License. Portions of this software are copyright The FreeType Project (www.freetype.org). All rights reserved.
- **HarfBuzz** — The "Old MIT" license; some parts carry other licenses, see COPYING upstream.
- **LAME (libmp3lame)** — The source states "LGPL, version 2 or later"; used under LGPL-2.1.
- **libarchive** — Not in the tvOS slice.
- **libmodplug** — The source declares libmodplug to be in the public domain; there is no license text.
- **libnfs** — The library is LGPL-2.1+; some protocol files are BSD-2-Clause.
- **libshout** — The source states the "Library GPL, version 2"; used under LGPL-2.1.
- **libsmb2** — The library is LGPL-2.1+; some files are BSD-2-Clause.
- **libtasn1** — The library is LGPL; the package's tools are GPL and are not bundled.
- **OpenCV** — Only the modules core, imgproc, imgcodecs, features2d, calib3d, flann and objdetect are built in.
- **Protocol Buffers** — Not in the tvOS slice.
- **TagLib** — TagLib is available under LGPL-2.1 or MPL-1.1; Swiftly uses it under LGPL-2.1.
- **TwoLAME** — Not in the macOS slice.
- **ZVBI (libzvbi)** — Mixed licensing; the library parts are LGPL-2.0+.
- **glslang** — Individual files carry different licenses; see LICENSE.txt upstream.
- **glad** — Generated OpenGL loader used by VLC's video output.
- **AOMedia AV1 (libaom)** — macOS slice only. Used together with the AOM Patent License 1.0 of the upstream project.
- **GNU libiconv** — macOS slice only.

## License texts

- [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)
- [`LICENSES/BSD-2-Clause.txt`](LICENSES/BSD-2-Clause.txt)
- [`LICENSES/BSD-3-Clause.txt`](LICENSES/BSD-3-Clause.txt)
- [`LICENSES/FTL.txt`](LICENSES/FTL.txt)
- [`LICENSES/GPL-2.0-or-later.txt`](LICENSES/GPL-2.0-or-later.txt)
- [`LICENSES/GSM.txt`](LICENSES/GSM.txt)
- [`LICENSES/ISC.txt`](LICENSES/ISC.txt)
- [`LICENSES/LGPL-2.1-or-later.txt`](LICENSES/LGPL-2.1-or-later.txt)
- [`LICENSES/MIT.txt`](LICENSES/MIT.txt)
- [`LICENSES/OFL-1.1-Inter.txt`](LICENSES/OFL-1.1-Inter.txt)
- [`LICENSES/PNG-libpng-2.txt`](LICENSES/PNG-libpng-2.txt)
- [`LICENSES/Zlib.txt`](LICENSES/Zlib.txt)
- [`LICENSES/libjpeg-turbo.txt`](LICENSES/libjpeg-turbo.txt)
