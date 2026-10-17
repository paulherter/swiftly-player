#!/bin/bash
# Sets up the environment for the Android build and checks that everything is present.
#
#     source Werkzeuge/android-environment.sh     load into the current shell
#     bash Werkzeuge/android-environment.sh       check only
#
# **Why a dedicated script.** Four tools must fit together and none of them
# is on the default PATH: JDK 21 (Android Gradle Plugin 9 needs at least 17,
# and the Mac otherwise only has 11), the Android SDK with NDK, the open
# Swift toolchain from swiftly (the one in Xcode cannot compile for Android)
# and the Swift SDK for Android.

export JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null)"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
NDK_FOLDER=$(ls -d "$ANDROID_HOME"/ndk/27.* 2>/dev/null | sort -V | tail -1)
export ANDROID_NDK_HOME="$NDK_FOLDER"
export PATH="$HOME/.swiftly/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"
# The Xcode toolchain must not take effect here.
unset DEVELOPER_DIR

error=0
check() { if eval "$2" >/dev/null 2>&1; then printf '  ok    %s\n' "$1"; else printf '  FEHLT %s\n' "$1"; error=1; fi; }
echo "Android-Umgebung"
check "JDK 21            ($JAVA_HOME)"            '[ -x "$JAVA_HOME/bin/java" ]'
check "Android SDK       ($ANDROID_HOME)"        '[ -d "$ANDROID_HOME/platforms" ]'
check "NDK 27            (${ANDROID_NDK_HOME:-—})" '[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]'
check "adb"                                       'command -v adb'
check "Emulator + AVDs   (swiftly-handy, swiftly-tv)" 'emulator -list-avds | grep -q swiftly-handy && emulator -list-avds | grep -q swiftly-tv'
check "Swift 6.3.3 (swiftly)"                     'swift --version 2>&1 | grep -q "6.3.3"'
check "Swift SDK for Android"                     'swift sdk list | grep -q android'
check "Swift SDK mit NDK verknuepft"              '[ -e "$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle/swift-android/ndk-sysroot/usr/include" ]'
[ "$error" = 0 ] && echo "Alles da." || echo "Etwas fehlt — siehe oben."
