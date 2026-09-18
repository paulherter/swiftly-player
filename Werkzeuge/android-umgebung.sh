#!/bin/bash
# Setzt die Umgebung fuer den Android-Bau und prueft, ob alles da ist.
#
#     source Werkzeuge/android-umgebung.sh     in die eigene Schale laden
#     bash Werkzeuge/android-umgebung.sh       nur pruefen
#
# **Warum ein eigenes Skript.** Vier Werkzeuge muessen zusammenpassen, und
# keines davon steht im Suchpfad: JDK 21 (das Android-Gradle-Plugin 9 braucht
# mindestens 17, auf dem Mac liegt sonst nur 11), das Android SDK samt NDK,
# die offene Swift-Toolchain aus swiftly (die aus Xcode kann nicht fuer
# Android uebersetzen) und das Swift SDK for Android. Eine spaetere Sitzung
# soll nicht erst suchen muessen. Siehe Notizen/Android/PLAN.md.

export JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null)"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
NDK_ORDNER=$(ls -d "$ANDROID_HOME"/ndk/27.* 2>/dev/null | sort -V | tail -1)
export ANDROID_NDK_HOME="$NDK_ORDNER"
export PATH="$HOME/.swiftly/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"
# Die Xcode-Toolchain darf hier nicht greifen.
unset DEVELOPER_DIR

fehler=0
pruef() { if eval "$2" >/dev/null 2>&1; then printf '  ok    %s\n' "$1"; else printf '  FEHLT %s\n' "$1"; fehler=1; fi; }
echo "Android-Umgebung"
pruef "JDK 21            ($JAVA_HOME)"            '[ -x "$JAVA_HOME/bin/java" ]'
pruef "Android SDK       ($ANDROID_HOME)"        '[ -d "$ANDROID_HOME/platforms" ]'
pruef "NDK 27            (${ANDROID_NDK_HOME:-—})" '[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]'
pruef "adb"                                       'command -v adb'
pruef "Emulator + AVDs   (swiftly-handy, swiftly-tv)" 'emulator -list-avds | grep -q swiftly-handy && emulator -list-avds | grep -q swiftly-tv'
pruef "Swift 6.3.3 (swiftly)"                     'swift --version 2>&1 | grep -q "6.3.3"'
pruef "Swift SDK for Android"                     'swift sdk list | grep -q android'
pruef "Swift SDK mit NDK verknuepft"              '[ -e "$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle/swift-android/ndk-sysroot/usr/include" ]'
[ "$fehler" = 0 ] && echo "Alles da." || echo "Etwas fehlt — siehe Notizen/Android/PLAN.md, Phase 0."
