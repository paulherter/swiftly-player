#!/bin/bash
# Builds the FFmpeg audio extension for Media3 (androidx/media "decoder_ffmpeg") for Android, LGPL only.
#   - FFmpeg 6.0.1 from the official release tarball (ffmpeg.org), as shared libraries (libavcodec-60.so …)
#     so a user can swap them; NOT --enable-gpl, NOT --enable-nonfree, no external codec libraries.
#   - The JNI wrapper (ffmpeg_jni.cc, Apache-2.0, from androidx/media at the Media3 tag) is its own libffmpegJNI.so.
#   - Output: Android/ffmpeg/src/main/jniLibs/<abi>/*.so and Android/ffmpeg/src/main/java (the Java classes of the
#     extension, Apache-2.0). Both are produced here, the jniLibs are not committed (see Android/ffmpeg/.gitignore).
# Usage: Werkzeuge/media3-ffmpeg-bauen.sh [abi ...]   (default: arm64-v8a armeabi-v7a x86_64)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(dirname "$here")"
MEDIA3_TAG="1.9.4"                       # keep equal to `media3` in Android/gradle/libs.versions.toml
FFMPEG_VER="6.0.1"
FFMPEG_SHA256="9b16b8731d78e596b4be0d720428ca42df642bb2d78342881ff7f5bc29fc9623"
API=28                                    # minSdk of :phone
DECODERS=(ac3 eac3 truehd mlp dca flac opus vorbis aac mp3 alac)
source "$here/android-environment.sh" >/dev/null 2>&1 || true
NDK="${ANDROID_NDK_HOME:?ANDROID_NDK_HOME missing}"
case "$(uname -s)" in Darwin) HOST=darwin-x86_64;; *) HOST=linux-x86_64;; esac
TC="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
work="${FFMPEG_WORK:-$root/build/media3-ffmpeg}"; mkdir -p "$work"; cd "$work"
out="$root/Android/ffmpeg/src/main"
abis=("$@"); [ ${#abis[@]} -gt 0 ] || abis=(arm64-v8a armeabi-v7a x86_64)

[ -d media ] || git clone -q --depth 1 --branch "$MEDIA3_TAG" https://github.com/androidx/media.git media
[ -f ffmpeg-$FFMPEG_VER.tar.xz ] || curl -fsSLO https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz
echo "$FFMPEG_SHA256  ffmpeg-$FFMPEG_VER.tar.xz" | shasum -a 256 -c -
ext=media/libraries/decoder_ffmpeg/src/main
mkdir -p "$out/java" && rm -rf "$out/java/androidx" && cp -R "$ext/java/androidx" "$out/java/"

for abi in "${abis[@]}"; do
  case $abi in
    arm64-v8a)   arch=aarch64; cpu=armv8-a; triple=aarch64-linux-android$API; extra=();;
    armeabi-v7a) arch=arm;     cpu=armv7-a; triple=armv7a-linux-androideabi$API; extra=(--extra-cflags="-march=armv7-a -mfloat-abi=softfp");;
    x86_64)      arch=x86_64;  cpu=x86-64;  triple=x86_64-linux-android$API; extra=(--disable-asm);;
    *) echo "unknown abi $abi"; exit 1;;
  esac
  src="$work/src-$abi"; rm -rf "$src"; mkdir -p "$src"; tar -xf ffmpeg-$FFMPEG_VER.tar.xz -C "$src" --strip-components=1
  ( cd "$src"
    opts=(--target-os=android --enable-shared --disable-static --disable-doc --disable-programs --disable-everything
          --disable-avdevice --disable-avformat --disable-swscale --disable-postproc --disable-avfilter --disable-symver
          --enable-swresample --disable-v4l2-m2m --disable-vulkan --disable-network
          --extra-ldflags="-Wl,-z,max-page-size=16384")
    for d in "${DECODERS[@]}"; do opts+=(--enable-decoder=$d); done
    ./configure --prefix="$src/install" --arch=$arch --cpu=$cpu --cc="$TC/$triple-clang" --cross-prefix="$TC/llvm-" \
      --nm="$TC/llvm-nm" --ar="$TC/llvm-ar" --ranlib="$TC/llvm-ranlib" --strip="$TC/llvm-strip" \
      ${extra[@]+"${extra[@]}"} "${opts[@]}" >configure.log 2>&1 || { tail -30 configure.log; exit 1; }
    # License gate: the build must be LGPL, never GPL or non-free.
    grep -q "define CONFIG_GPL 0" config.h && grep -q "define CONFIG_NONFREE 0" config.h && grep -q "define CONFIG_VERSION3 0" config.h || { echo "NOT LGPL-2.1 ONLY"; exit 1; }
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >make.log 2>&1 || { tail -30 make.log; exit 1; }
    make install >/dev/null 2>&1
  )
  dst="$out/jniLibs/$abi"; mkdir -p "$dst"; rm -f "$dst"/*.so
  for l in avutil swresample avcodec; do cp "$src/install/lib/lib$l.so" "$dst/"; done
  linkflags=(-Wl,-z,max-page-size=16384 -Wl,--no-undefined); [ $abi = arm64-v8a ] && linkflags+=(-Wl,-Bsymbolic)
  "$TC/$triple-clang++" -shared -fPIC -std=c++11 -O2 -I"$src/install/include" "$ext/jni/ffmpeg_jni.cc" -o "$dst/libffmpegJNI.so" \
    "$dst/libswresample.so" "$dst/libavcodec.so" "$dst/libavutil.so" -landroid -llog "${linkflags[@]}"
  "$TC/llvm-strip" --strip-unneeded "$dst"/*.so
  echo "$abi: $(du -ch "$dst"/*.so | tail -1)"
done
echo "FFmpeg $FFMPEG_VER, LGPL-2.1+, decoders: ${DECODERS[*]}" >"$out/jniLibs/BUILD-INFO.txt"
