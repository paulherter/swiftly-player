#!/bin/bash
# Builds the Rust core for Android: libswiftly_uniffi.so for arm64-v8a, armeabi-v7a and x86_64 (16 KB page aligned),
# the Kotlin bindings, and the macOS cdylib the Gradle unit tests load through JNA.
#   Werkzeuge/rust-kern-android.sh [libs|bindings|host|all] [play|direct|both]
# Per flavor (build/android-core/<flavor>/{jniLibs,host,kotlin}): the Play core is built WITHOUT the direct-only `supporter-key`
# feature, and its Kotlin bindings are generated from a lib without it (UniFFI checks every symbol at load, so a Play binding set
# that names `legacy_support_key_status` would die with UnsatisfiedLinkError). The direct flavor has the feature everywhere.
# `pruefe-play-ohne-schluessel.sh` stays strict.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
source Werkzeuge/android-environment.sh >/dev/null 2>&1
source Werkzeuge/lastgrenze.sh
BASE=build/android-core
mode="${1:-all}"
flavors="${2:-both}"; [[ $flavors == both ]] && flavors="play direct"
# ANDROID_ABIS="x86_64" builds only the emulator ABI (default: all three).
ABI_ARGS=""; for a in ${ANDROID_ABIS:-arm64-v8a armeabi-v7a x86_64}; do ABI_ARGS="$ABI_ARGS -t $a"; done
FLAGS=(-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384)
for flavor in $flavors; do
  OUT=$BASE/$flavor
  KEYFEATURE=(); [[ $flavor == direct ]] && KEYFEATURE=(--features supporter-key)
  if [[ $mode == libs || $mode == all ]]; then
    mkdir -p "$OUT/jniLibs"
    schwer cargo ndk $ABI_ARGS -P 28 -o "$OUT/jniLibs" \
      rustc -p swiftly-uniffi --lib --release ${KEYFEATURE[@]+"${KEYFEATURE[@]}"} --crate-type cdylib -- "${FLAGS[@]}"
    for so in "$OUT"/jniLibs/*/libswiftly_uniffi.so; do
      echo "$so: LOAD alignments $("$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-readelf -lW "$so" | awk '$1=="LOAD"{print $NF}' | sort -u | tr '\n' ' ') (0x4000 = 16 KB)"
    done
  fi
  if [[ $mode == host || $mode == all || $mode == bindings ]]; then
    if [[ $mode != bindings || ! -f $OUT/host/libswiftly_uniffi.dylib ]]; then
      mkdir -p "$OUT/host"
      schwer cargo rustc -p swiftly-uniffi --lib --release ${KEYFEATURE[@]+"${KEYFEATURE[@]}"} --crate-type cdylib
      cp target/release/libswiftly_uniffi.dylib "$OUT/host/"
    fi
  fi
  if [[ $mode == bindings || $mode == all ]]; then
    rm -rf "$OUT/kotlin"; mkdir -p "$OUT/kotlin"
    schwer cargo run -q -p xtask --bin uniffi-bindgen -- generate "$OUT/host/libswiftly_uniffi.dylib" --language kotlin --no-format --out-dir "$OUT/kotlin"
    # JNA on ART does not see `@JvmField internal` fields of Structure subclasses (the app died with "Structure.getFieldOrder()
    # ... do not match declared field names" on the first foreign async call); public fields work.
    sed -i '' 's/@JvmField internal var/@JvmField var/g' "$OUT"/kotlin/de/paulherter/swiftly/rustcore/*.kt
  fi
done
