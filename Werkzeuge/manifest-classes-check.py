#!/usr/bin/env python3
"""Does every class named in the APK's manifest exist in its DEX files?

    python3 Werkzeuge/manifest-classes-check.py [path/to/app.apk]

**Why this exists.** The identifier rename left the Android manifest pointing at
the old class names. `android:name` is a *string*, so neither the compiler nor
the unit tests notice: the build is green and the app dies at startup with a
`ClassNotFoundException`. This reads the manifest of the *built* APK (after the
manifest merger, so classes from libraries count as well), takes every
`android:name` of an application, activity, service, receiver and provider element
and the `android:targetActivity` of every activity-alias (the alias name itself is
only a label), and looks each class up in the DEX files.

Without an argument it takes the newest `Android/phone/build/outputs/apk/**/*.apk`.
Needs `aapt2` and `dexdump` from the Android SDK build tools (ANDROID_HOME or
~/Library/Android/sdk). Exit 1 if a class is missing.
"""
import os, re, subprocess, sys, tempfile, zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sdk = Path(os.environ.get("ANDROID_HOME") or Path.home() / "Library/Android/sdk")

def tool(name):
    found = sorted(sdk.glob(f"build-tools/*/{name}"), key=lambda p: [int(x) for x in re.findall(r"\d+", p.parent.name)])
    if not found:
        sys.exit(f"{name} not found under {sdk}/build-tools")
    return str(found[-1])

def newest_apk():
    apks = sorted((root / "Android/phone/build/outputs/apk").rglob("*.apk"), key=lambda p: p.stat().st_mtime)
    if not apks:
        sys.exit("No APK under Android/phone/build/outputs/apk; build one first (:phone:assembleDebug).")
    return apks[-1]

apk = Path(sys.argv[1]) if len(sys.argv) > 1 else newest_apk()

# --- manifest: package and the component names -------------------------------------------------
xml = subprocess.run([tool("aapt2"), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
                     capture_output=True, text=True, check=True).stdout
package = re.search(r'package="([^"]+)"', xml).group(1)
wanted = []   # (element, name)
element = None
aliases = []  # (alias name, target) -- the alias name is no class, its target must be one
alias_name = None
for line in xml.splitlines():
    m = re.match(r"\s*E: (\S+)", line)
    if m:
        element = m.group(1)
        alias_name = None
        continue
    m = re.search(r'A: http://schemas.android.com/apk/res/android:name\([^)]*\)="([^"]+)"', line)
    if m and element == "activity-alias":
        alias_name = m.group(1)
        continue
    if m and element in ("application", "activity", "service", "receiver", "provider"):
        wanted.append((element, m.group(1)))
    # **activity-alias** (supporter app icons): `android:name` is only a label, `targetActivity` is a
    # class name as a string and must exist, exactly like `android:name` elsewhere.
    m = re.search(r'A: http://schemas.android.com/apk/res/android:targetActivity\([^)]*\)="([^"]+)"', line)
    if m and element == "activity-alias":
        wanted.append(("alias→", m.group(1)))
        aliases.append((alias_name or "?", m.group(1)))

def qualified(name):
    if name.startswith("."):
        return package + name
    return name if "." in name else package + "." + name

# --- DEX: every defined class -------------------------------------------------------------------
classes = set()
with tempfile.TemporaryDirectory() as tmp:
    with zipfile.ZipFile(apk) as z:
        dexes = [n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)]
        z.extractall(tmp, dexes)
    for dex in dexes:
        out = subprocess.run([tool("dexdump"), "-f", str(Path(tmp) / dex)], capture_output=True).stdout
        classes.update(m.decode("utf-8", "replace") for m in re.findall(rb"Class descriptor\s*:\s*'L([^;]+);'", out))

missing = []
for element, name in wanted:
    q = qualified(name)
    ok = q.replace(".", "/") in classes
    print(f"  {'ok     ' if ok else 'MISSING'} {element:<9} {q}")
    if not ok:
        missing.append(q)

for alias, target in aliases:
    print(f"  alias     {qualified(alias)} -> {qualified(target)}")
print(f"{len(wanted)} classes in the manifest of {apk.name} ({len(aliases)} aliases), {len(classes)} classes in {len(dexes)} DEX file(s).")
if missing:
    print("Missing in the DEX: " + ", ".join(missing))
    sys.exit(1)
