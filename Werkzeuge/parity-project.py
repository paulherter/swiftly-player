#!/usr/bin/env python3
"""Writes build/parity/spec.yml: the Mac app's sources compiled straight into a macOS unit-test bundle
(no host app, nothing is launched; the `@main` entry is compiled but never run), plus Tests/SwiftUIParity. Used by `cargo xtask swiftui-parity`.
The source list is read from the Swiftly-macOS target of project.yml, so it never drifts."""
import os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lines = open(os.path.join(root, "project.yml")).read().split("\n")
head_end = lines.index("targets:")
start = lines.index("  Swiftly-macOS:")
end = next((n for n in range(start + 1, len(lines)) if re.match(r"^  [A-Za-z][\w-]*:\s*$", lines[n])), len(lines))
block = lines[start:end]
out, skip = [], None
for l in block:
    if skip is not None:
        if l.strip() == "" or len(l) - len(l.lstrip()) > skip:
            continue
        skip = None
    ind = len(l) - len(l.lstrip())
    if ind == 4 and re.match(r"(scheme|info):", l.strip()):
        skip = 4
        continue
    if l.strip().startswith(("CODE_SIGN_ENTITLEMENTS", "ASSETCATALOG_COMPILER_APPICON_NAME", "PRODUCT_NAME", "PRODUCT_BUNDLE_IDENTIFIER")):
        continue
    if l.strip() in ("- path: LICENSES", "type: folder"):
        continue
    if l.strip() == "type: application":
        l = "    type: bundle.unit-test"
    out.append(l)
out[0] = "  SwiftlyParityTests:"
# Harness-only seam: a copy of DownloadManager with a writable `entries`, so the Downloads page can be rendered with sample
# rows. The app source stays untouched; only the parity bundle compiles the copy instead of the original.
dm_src = open(os.path.join(root, "Sources/Shared/DownloadManager.swift")).read()
assert "private(set) var entries: [DownloadItem]" in dm_src
shim_dir = os.path.join(root, "build", "parity", "Shim")
os.makedirs(shim_dir, exist_ok=True)
img_line = "    func image(for p: DownloadItem, asGroup: Bool = false) -> URL? {\n"
assert img_line in dm_src
dm_shim = dm_src.replace("private(set) var entries: [DownloadItem]", "var entries: [DownloadItem]", 1)
# The saved poster of a row comes from the parity fixture instead of the download folder.
dm_shim = dm_shim.replace(img_line, "    static var snapshotImage: ((DownloadItem, Bool) -> URL?)?\n" + img_line + "        if let hook = Self.snapshotImage { return hook(p, asGroup) }\n", 1)
open(os.path.join(shim_dir, "DownloadManager.swift"), "w").write(dm_shim)
out = [("      - path: build/parity/Shim/DownloadManager.swift" if l.strip() == "- path: Sources/Shared/DownloadManager.swift" else l) for l in out]
# test sources and settings
i = out.index("    sources:") + 1
out.insert(i, "      - path: Tests/SwiftUIParity")
j = out.index("    settings:")
out[j + 1:j + 2] = ["      base:", "        GENERATE_INFOPLIST_FILE: YES", "        PRODUCT_NAME: SwiftlyParityTests",
                    "        PRODUCT_BUNDLE_IDENTIFIER: de.paulherter.swiftly.paritytests", "        ENABLE_TESTING_SEARCH_PATHS: YES"] if out[j + 1].strip() == "base:" else ["      base:"]
spec = "\n".join(lines[:head_end] + ["targets:"] + out) + "\n"
spec = spec.replace("name: Swiftly\n", "name: SwiftlyParity\n", 1)
dest = os.path.join(root, "build", "parity")
os.makedirs(dest, exist_ok=True)
open(os.path.join(dest, "spec.yml"), "w").write(spec)
print(os.path.join(dest, "spec.yml"))
