#!/usr/bin/env python3
"""Does the Play build carry anything of the direct build? (And the direct build any Billing?)

    python3 Werkzeuge/store-guard-android.py                 newest play release AAB/APK + direct APK
    python3 Werkzeuge/store-guard-android.py <play.aab|.apk> [--direct <direct.apk>]
    python3 Werkzeuge/store-guard-android.py --build         builds bundlePlayRelease and
                                                             assembleDirectRelease first
    python3 Werkzeuge/store-guard-android.py --direct-only <direct.apk>   (sideload-apk.sh)

**Why this exists.** Google Play refuses apps that point to payment outside Play Billing
(AnkiDroid, 2026: a donation link alone). The Play flavor (`src/play`) must therefore contain
no link to the website's supporter page, no checkout, and no supporter key check; those live
only in `src/direct`. Gradle keeps the source sets apart, but a shared text table, a constant in
the Swift core or a comment turned into a string would slip through every compiler. This looks at
the **built** artifact: every DEX file, the resource table, the manifest, every asset and every
native library (`.so`, including the Swift core), as UTF-8 and as UTF-16.

Forbidden in the Play build: `pay.paulherter`, `swiftlyplayer.com/supporter`, `Stripe`,
`supporter key` (any case), `SupporterKey`. A hit is an error.

The direct APK is checked the other way round: no `com.android.vending.BILLING` permission and
no `com.android.billingclient` classes (Google's policy applies to Play, but the direct build
must not depend on Play either).

Without arguments it takes the newest `bundle/playRelease/*.aab` (or `apk/play/release/*.apk`)
and the newest `apk/direct/release/*.apk` under `Android/phone/build/outputs`. Exit 1 on any hit
or when no Play artifact exists.
"""
import os, re, subprocess, sys, zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
outputs = root / "Android/phone/build/outputs"
sdk = Path(os.environ.get("ANDROID_HOME") or Path.home() / "Library/Android/sdk")

WORDS = [("pay.paulherter", False), ("swiftlyplayer.com/supporter", False), ("Stripe", False),
         ("supporter key", True), ("SupporterKey", False)]

def tool(name):
    found = sorted(sdk.glob(f"build-tools/*/{name}"), key=lambda p: [int(x) for x in re.findall(r"\d+", p.parent.name)])
    return str(found[-1]) if found else None

def newest(pattern):
    found = sorted(outputs.glob(pattern), key=lambda p: p.stat().st_mtime)
    return found[-1] if found else None

# "Stripe" counts as a word only: Guava's `Striped64` and `CompactStriped` are no checkout.
WHOLE_WORD = {"Stripe"}

def needles():
    out = []
    for word, ignore_case in WORDS:
        for encoding in ("utf-8", "utf-16-le"):
            flags = re.IGNORECASE if ignore_case else 0
            body = re.escape(word.encode(encoding))
            if word in WHOLE_WORD:
                z = b"\\x00" if encoding == "utf-16-le" else b""
                body = b"(?<![A-Za-z]" + z + b")" + body + b"(?![a-z0-9]" + z + b")"
            out.append((word, encoding, re.compile(body, flags)))
    return out

def scan(artifact: Path):
    """Every entry of the archive that is code, resources, manifest, assets or a library."""
    hits = []
    checked = 0
    with zipfile.ZipFile(artifact) as z:
        for name in z.namelist():
            if name.endswith("/"):
                continue
            if not (name.endswith((".dex", ".so", ".arsc", ".pb", ".xml", ".json", ".txt"))
                    or "/assets/" in f"/{name}" or name.startswith("assets/")):
                continue
            data = z.read(name)
            checked += 1
            for word, encoding, rx in needles():
                for m in rx.finditer(data):
                    start = max(0, m.start() - 40)
                    context = data[start:m.end() + 40].decode(encoding, "replace").replace("\n", " ")
                    context = re.sub(r"[^\x20-\x7e -￿]", "·", context)
                    hits.append(f"{name}: {word!r} ({encoding}) …{context}…")
                    break
    return checked, hits

def manifest_text(apk: Path) -> str:
    aapt2 = tool("aapt2")
    if not aapt2:
        sys.exit("aapt2 not found under the Android SDK build tools")
    return subprocess.run([aapt2, "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
                          capture_output=True, text=True, check=True).stdout

def check_direct(apk: Path) -> list:
    problems = []
    if "com.android.vending.BILLING" in manifest_text(apk):
        problems.append("BILLING permission in the manifest")
    with zipfile.ZipFile(apk) as z:
        for name in z.namelist():
            if re.fullmatch(r"classes\d*\.dex", name) and b"Lcom/android/billingclient/" in z.read(name):
                problems.append(f"Billing classes in {name}")
    return problems

def main():
    args = sys.argv[1:]
    if "--build" in args:
        args.remove("--build")
        env = dict(os.environ)
        r = subprocess.run(["bash", "-c", f"source '{root}/Werkzeuge/android-environment.sh' >/dev/null && cd '{root}/Android' "
                            "&& ./gradlew -q :phone:bundlePlayRelease :phone:assembleDirectRelease"], env=env)
        if r.returncode != 0:
            sys.exit("Build failed.")
    if "--direct-only" in args:
        i = args.index("--direct-only")
        apk = Path(args[i + 1])
        problems = check_direct(apk)
        print(f"Direct build {apk.name}: " + ("no Billing." if not problems else "; ".join(problems)))
        sys.exit(1 if problems else 0)
    direct = None
    if "--direct" in args:
        i = args.index("--direct")
        direct = Path(args[i + 1])
        del args[i:i + 2]
    play = Path(args[0]) if args else (newest("bundle/playRelease/*.aab") or newest("apk/play/release/*.apk"))
    if direct is None and not args:
        direct = newest("apk/direct/release/*.apk")
    if play is None or not play.exists():
        sys.exit("No play release build under Android/phone/build/outputs; run with --build "
                 "(:phone:bundlePlayRelease).")

    error = False
    checked, hits = scan(play)
    print(f"Play build {play.name}: {checked} entries searched for {', '.join(w for w, _ in WORDS)}.")
    if hits:
        error = True
        print(f"  {len(hits)} forbidden string(s):")
        for h in hits[:40]:
            print(f"    {h}")
    else:
        print("  clean.")
    if direct is not None and direct.exists():
        problems = check_direct(direct)
        print(f"Direct build {direct.name}: " + ("no Billing." if not problems else "; ".join(problems)))
        error = error or bool(problems)
    else:
        print("Direct build: none found, not checked.")
    sys.exit(1 if error else 0)

if __name__ == "__main__":
    main()
