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
# Same kind of seam for the signed-in account: `AppModel.session` is `private(set)`; the sidebar footer (name, server)
# and everything that asks "who is signed in" needs a session in the fixture.
am_src = open(os.path.join(root, "Sources/Shared/AppModel.swift")).read()
assert "    private(set) var session: Session? {" in am_src
am_shim = am_src.replace("    private(set) var session: Session? {", "    var session: Session? {", 1)
# The landscape picture of the "continue watching" row goes through the same picture hook as the posters.
land = "    func landscapeImageURL(for item: Item, width: Int = 600) -> URL? {\n"
assert land in am_shim
am_shim = am_shim.replace(land + "        landscapeImage(", land + "        if let stand = Self.snapshotImageURL { return stand(item, false) }\n        return landscapeImage(", 1)
open(os.path.join(shim_dir, "AppModel.swift"), "w").write(am_shim)
out = [("      - path: build/parity/Shim/AppModel.swift" if l.strip() == "- path: Sources/Shared/AppModel.swift" else l) for l in out]
# test sources and settings
i = out.index("    sources:") + 1
out.insert(i, "      - path: Tests/SwiftUIParity")
j = out.index("    settings:")
out[j + 1:j + 2] = ["      base:", "        GENERATE_INFOPLIST_FILE: YES", "        PRODUCT_NAME: SwiftlyParityTests",
                    "        PRODUCT_BUNDLE_IDENTIFIER: de.paulherter.swiftly.paritytests", "        ENABLE_TESTING_SEARCH_PATHS: YES"] if out[j + 1].strip() == "base:" else ["      base:"]
# The tests run inside a tiny host app, because SwiftUI's `Image("name")`, string catalogs, `Bundle.main` and the bundled
# font all look into the MAIN bundle: in a plain `xctest` run that is the xctest tool, so every asset-catalog icon, every
# translation and Inter were missing. The host carries the same resources as the Mac app and starts in German; it contains
# no app code (just an `NSApplication` run loop for XCTest to attach to).
host_dir = os.path.join(root, "build", "parity", "Host")
os.makedirs(host_dir, exist_ok=True)
open(os.path.join(host_dir, "main.swift"), "w").write("""import AppKit
// German like the Mac app a German user runs, set before anything reads the bundle's localisations.
UserDefaults.standard.set(["de"], forKey: "AppleLanguages")
UserDefaults.standard.set("de_DE", forKey: "AppleLocale")
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
""")
k = out.index("    dependencies:")
out.insert(k + 1, "      - target: SwiftlyParityHost")
j = out.index("    settings:")
out.insert(j + 2, "        TEST_HOST: $(BUILT_PRODUCTS_DIR)/SwiftlyParityHost.app/Contents/MacOS/SwiftlyParityHost")
out.insert(j + 3, "        BUNDLE_LOADER: $(TEST_HOST)")
open(os.path.join(host_dir, "Info.plist"), "w").write("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SwiftlyParityHost</string>
<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
<key>ATSApplicationFontsPath</key><string>.</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
""")
host = """
  SwiftlyParityHost:
    type: application
    platform: macOS
    sources:
      - path: build/parity/Host/main.swift
      - path: Sources/macOS/Assets.xcassets
      - path: Sources/iOS/Icons.xcassets
      - path: Sources/Shared/Assets
      - path: Sources/Shared/Localizable.xcstrings
      - path: Sources/Shared/InfoPlist.xcstrings
      - path: Sources/iOS/Fonts/InterVariable.ttf
        buildPhase: resources
    settings:
      base:
        PRODUCT_NAME: SwiftlyParityHost
        PRODUCT_BUNDLE_IDENTIFIER: de.paulherter.swiftly.parityhost
        GENERATE_INFOPLIST_FILE: NO
        INFOPLIST_FILE: Host/Info.plist
        SWIFT_EMIT_LOC_STRINGS: NO
"""
spec = "\n".join(lines[:head_end] + ["targets:"] + out) + "\n" + host
spec = spec.replace("name: Swiftly\n", "name: SwiftlyParity\n", 1)
dest = os.path.join(root, "build", "parity")
os.makedirs(dest, exist_ok=True)
open(os.path.join(dest, "spec.yml"), "w").write(spec)
print(os.path.join(dest, "spec.yml"))
