#!/bin/bash
# Builds the **direct** release APK with Gradle (signed with our upload key) and attaches it
# to the GitHub release `v<version>` as `Swiftly-<version>-upload-signed.apk`.
#
#     bash Werkzeuge/sideload-apk.sh [--dry-run]
#
# **Two flavors, two artifacts** (dimension `distribution` in `Android/phone/build.gradle.kts`,
# same applicationId, same versionCode):
#   - `play`   -> `./gradlew :phone:bundlePlayRelease`
#                 -> Android/phone/build/outputs/bundle/playRelease/phone-play-release.aab
#                 Google Play only (`Werkzeuge/play.mjs hochladen <aab>`), and Google's own
#                 universal APK from it (`play.mjs apk-anhaengen`, the plain `Swiftly-<version>.apk`).
#                 Tips through Play Billing; no website link, no supporter key.
#   - `direct` -> `./gradlew :phone:assembleDirectRelease` (this script)
#                 -> Android/phone/build/outputs/apk/direct/release/phone-direct-release.apk
#                 GitHub/Obtainium. No Billing, no BILLING permission; "Support on the website"
#                 and the supporter key.
# Before uploading, `Werkzeuge/store-guard-android.py` proves the Play build carries nothing of
# the direct one and the direct build no Billing; this script runs it on its own APK.
# The direct build refuses to go out while the supporter key check still uses the published
# test key (`SupporterKey.publicKeyBase64` in the package, mirrored in `SupporterKeyCheck.kt`):
# anyone could sign keys for it. --dry-run builds anyway.
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
# A beta release is tagged `v<version>-beta`; the final one `v<version>` wins when both exist.
tag="v$version"
gh release view "$tag" >/dev/null 2>&1 || ! gh release view "$tag-beta" >/dev/null 2>&1 || tag="$tag-beta"
name="Swiftly-$version-upload-signed.apk"

# shellcheck disable=SC1091
source "$root/Werkzeuge/android-environment.sh" >/dev/null
sdk="$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)"

gh release view "$tag" --json assets -q '.assets[].name' | grep -qx "$name" \
  && { echo "$name is already attached to $tag, nothing replaced." >&2; exit 1; }

keyfile="$root/Android/phone/src/direct/java/de/paulherter/swiftly/support/SupporterKeyCheck.kt"
release_key=$(sed -n 's/.*const val PUBLIC_KEY_BASE64 = "\(.*\)".*/\1/p' "$keyfile")
test_key=$(sed -n 's/.*const val TEST_PUBLIC_KEY_BASE64 = "\(.*\)".*/\1/p' "$keyfile")
if [ -z "$release_key" ] || [ "$release_key" = "$test_key" ]; then
  if [ "$dry" = 1 ]; then
    echo "Warning: the supporter key check still uses the test key (fine for --dry-run only)." >&2
  else
    echo "The supporter key check still uses the published test key; set the release key first." >&2
    exit 1
  fi
fi

(cd "$root/Android" && ./gradlew -q :phone:assembleDirectRelease)
built="$root/Android/phone/build/outputs/apk/direct/release/phone-direct-release.apk"
[ -f "$built" ] || { echo "no direct release APK at $built" >&2; exit 1; }
# No Billing and no BILLING permission in this one.
python3 "$root/Werkzeuge/store-guard-android.py" --direct-only "$built" || { echo "Store guard failed, refusing." >&2; exit 1; }

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
