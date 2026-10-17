#!/bin/bash
# Builds the release APK directly with Gradle (signed with our upload key) and attaches it
# to the GitHub release `v<version>` as `Swiftly-<version>-upload-signed.apk`.
#
#     bash Werkzeuge/sideload-apk.sh [--dry-run]
#
# **Why a second APK.** `play.mjs apk-anhaengen` attaches the universal APK that Google
# generates and signs with the Play app signing key, as `Swiftly-<version>.apk`. It carries
# Play metadata (`com.android.stamp.*`, `com.android.vending.splits`). This one has
# neither: it is the plain Gradle build with the upload key. The two signatures differ,
# so one cannot be installed over the other (uninstall first).
#
# The version comes from `Android/phone/build.gradle.kts`. The key lives outside the repo
# (`~/.swiftly-android/swiftly-upload.jks`), the password in the macOS keychain; Gradle reads
# it, nothing is written to a file or printed. The release must already exist; an APK of the
# same name is not replaced. With --dry-run nothing is uploaded.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
version=$(sed -n 's/^ *versionName = "\(.*\)".*/\1/p' "$root/Android/phone/build.gradle.kts" | head -1)
[ -n "$version" ] || { echo "versionName not found" >&2; exit 1; }
tag="v$version"
name="Swiftly-$version-upload-signed.apk"

# shellcheck disable=SC1091
source "$root/Werkzeuge/android-environment.sh" >/dev/null
sdk="$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)"

gh release view "$tag" --json assets -q '.assets[].name' | grep -qx "$name" \
  && { echo "$name is already attached to $tag, nothing replaced." >&2; exit 1; }

(cd "$root/Android" && ./gradlew -q :phone:assembleRelease)
built="$root/Android/phone/build/outputs/apk/release/phone-release.apk"
[ -f "$built" ] || { echo "no release APK at $built" >&2; exit 1; }

# Must be signed (an unsigned build means the keychain entry was missing) and free of Play metadata.
"$sdk/apksigner" verify --print-certs "$built" | grep -E "SHA-256|Verified"
if "$sdk/aapt2" dump xmltree --file AndroidManifest.xml "$built" | grep -qE "com.android.stamp|com.android.vending.splits|derived.apk"; then
  echo "APK carries Play metadata, refusing." >&2; exit 1
fi

out="$(mktemp -d)/$name"
cp "$built" "$out"
echo "Built: $out ($(du -m "$out" | cut -f1) MB)"
if [ "$dry" = 1 ]; then echo "--dry-run: nothing uploaded."; exit 0; fi
gh release upload "$tag" "$out"
echo "Attached $name to $tag."
