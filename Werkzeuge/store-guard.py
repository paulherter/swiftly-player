#!/usr/bin/env python3
"""Does a store build carry anything that points to paying outside the store?

**Why this exists.** Store builds take tips through the App Store only. The
direct builds (Linux, Windows, the APK from GitHub) sell supporter keys on the
website, and that code lives in its own module (`SupportKeyKit`) which store
builds must not link. A wrong dependency, a copied text or a shared file is
enough to bring a link or the word into the store binary, and App Review rejects
that (guideline 3.1.1). No build and no test notices it: the app runs fine.

So this reads the built bundles themselves, every file in them: executables,
frameworks, compiled string tables, plists, asset catalogs. Strings are searched
as UTF-8 and UTF-16, since compiled `.strings` files may hold either.

    Werkzeuge/store-guard.py                 newest Apple builds from DerivedData
    Werkzeuge/store-guard.py <bundle> ...    these bundles

Exit code 0: nothing found. 1: something found. 2: no bundle to check.
"""
import pathlib
import sys

# (text, case-sensitive). "Stripe" only as written: "stripe" appears in video
# filter names of the media framework and means something else there.
FORBIDDEN = [
    ("pay.paulherter", False),
    ("swiftlyplayer.com/supporter", False),
    ("Stripe", True),
    ("supporter key", False),
    ("SupporterKey", False),
    ("SupportKeyKit", False),
]

# The three Apple app bundles, as Xcode names the products.
APPLE_PRODUCTS = ["Swiftly-iOS.app", "Swiftly-tvOS.app", "Swiftly.app"]


def needles():
    """Every forbidden text in every encoding, with its case rule."""
    result = []
    for text, sensitive in FORBIDDEN:
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            raw = text.encode(encoding)
            result.append((text, raw if sensitive else raw.lower(), sensitive))
    return result


def newest_apple_bundles():
    """The most recently built bundle per product, from Xcode's DerivedData."""
    derived = pathlib.Path.home() / "Library/Developer/Xcode/DerivedData"
    found = []
    for product in APPLE_PRODUCTS:
        candidates = [p for p in derived.glob(f"Swiftly-*/Build/Products/*/{product}")
                      if p.is_dir()]
        if candidates:
            found.append(max(candidates, key=lambda p: p.stat().st_mtime))
    return found


def check_apple(bundles):
    """Searches every file in each bundle. Returns a list of (bundle, file, text)."""
    hits = []
    patterns = needles()
    for bundle in bundles:
        for path in sorted(bundle.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            try:
                data = path.read_bytes()
            except OSError:
                continue
            lowered = data.lower()
            for text, raw, sensitive in patterns:
                if raw in (data if sensitive else lowered):
                    hits.append((bundle, path.relative_to(bundle), text))
    # One line per file and text, whatever the encoding was.
    return sorted(set(hits), key=lambda h: (str(h[0]), str(h[1]), h[2]))


def main(arguments):
    bundles = [pathlib.Path(a) for a in arguments] if arguments else newest_apple_bundles()
    bundles = [b for b in bundles if b.is_dir()]
    if not bundles:
        print("Kein Apple-Bundle gefunden (erst bauen).")
        return 2
    hits = check_apple(bundles)
    for bundle in bundles:
        mine = [h for h in hits if h[0] == bundle]
        state = f"{len(mine)} Funde" if mine else "sauber"
        print(f"{bundle.name:<20} {state}")
        for _, file, text in mine:
            print(f"      {file}: {text}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
