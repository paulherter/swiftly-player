#!/usr/bin/env python3
"""Sheet guard: no floating bottom sheets on iPhone and iPad.

Apple's `.sheet` with a partial height floats on iOS 26 (margin all around, the page
showing under it, a strip above the home indicator). The app's own `.sheet(opened:)`
(Sources/Shared/Style.swift, `SheetModifier`) sits flush with the screen's edge. Rule:

  * `.sheet(isPresented:)` / `.sheet(item:)` in Sources/Shared and Sources/iOS must be
    full height (`.presentationDetents([.large])` within the next 30 lines) or carry the
    word `flush-ok` (with a reason) on the line or one of the three lines above.
  * `.presentationDetents` with `.height`, `.medium`, `.fraction` or `.custom` needs the
    same `flush-ok`.

  * **Sheets travel as a whole.** In a file that hangs a `.sheet(opened:)`, no
    `.animation(nil`, no `.transaction { $0.animation = nil }` and no own
    `.transition(.move(edge: .bottom` (a background or content with its own transition
    next to the card): that cuts the content off from the card's slide-up. The card
    (`SheetModifier`) moves everything in one view. Exception: `sheet-anim-ok` plus a reason.

  * **Sheets open complete.** A sheet's rows must stand in its first frame and ride up with the
    card. A `.task(id: opened)` (or any `.task(id: …Open…)`) in a file that hangs a sheet loads after
    the slide-up began, so what it brings pops in mid-slide (the request sheet's quality and folder
    rows, the download sheet's seasons). Such a file must fill the rows before opening (`prime`, a
    prefetch, a core cache, placeholders of final size) and say so with `sheet-complete-ok` plus how.
  * **Sheet lists fade.** A list capped at `Theme.sheetListMax` scrolls; it must carry
    `.sheetListFade()` within the next three lines (a hard edge looks like the end of the list).

Exit code 1 lists the places. Notes: Notizen/Fallen/swiftui.md, "Apples sheet seit iOS 26".
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYSTEM_SHEET = re.compile(r"\.sheet\((?!opened:)")
DECOUPLE = re.compile(r"\.animation\(nil|\$0\.animation\s*=\s*nil|\.transition\(\.move\(edge:\s*\.bottom")
LATE_LOAD = re.compile(r"\.task\(id:\s*[\w.]*[oO]pen")
PARTIAL = re.compile(r"\.presentationDetents\(\[[^\]]*\.(height|medium|fraction|custom)")


def marked(lines, i):
    return any("flush-ok" in lines[j] for j in range(max(0, i - 3), i + 1))


def main() -> int:
    problems = []
    for folder in ("Sources/Shared", "Sources/iOS"):
        for path in sorted((ROOT / folder).rglob("*.swift")):
            lines = path.read_text().splitlines()
            hangs_sheet = any(".sheet(opened:" in l or "SheetModifier" in l for l in lines)
            if hangs_sheet and path.name != "Style.swift":
                for i, line in enumerate(lines):
                    code = line.split("//")[0]
                    if DECOUPLE.search(code) and not any(
                            "sheet-anim-ok" in lines[j] for j in range(max(0, i - 3), i + 1)):
                        problems.append((path, i + 1, "cuts a sheet's content off from its slide-up: "
                                         "let SheetModifier move the whole card (or sheet-anim-ok)"))
            for i, line in enumerate(lines):
                code = line.split("//")[0]
                if hangs_sheet and LATE_LOAD.search(code) and not any(
                        "sheet-complete-ok" in lines[j] for j in range(max(0, i - 3), min(len(lines), i + 4))):
                    problems.append((path, i + 1, "loads after the sheet opened: fill its rows before opening "
                                     "(prime / prefetch / placeholders) and mark sheet-complete-ok"))
                if "Theme.sheetListMax" in code and not any(
                        ".sheetListFade()" in lines[j] for j in range(i, min(len(lines), i + 4))):
                    problems.append((path, i + 1, "a scrolling sheet list without .sheetListFade() (hard edge)"))
                if SYSTEM_SHEET.search(code):
                    if marked(lines, i):
                        continue
                    ahead = "\n".join(lines[i:i + 30])
                    if ".presentationDetents([.large])" in ahead:
                        continue
                    problems.append((path, i + 1, "system sheet that may float: use .sheet(opened:) or full height"))
                elif PARTIAL.search(code) and not marked(lines, i):
                    problems.append((path, i + 1, "partial detent floats on iOS 26: use .sheet(opened:)"))
    # The exported title screen must only forward to the shared `swiftly_vm::SeerrTitleScreen`. A second copy of its
    # reads once lacked the request choices' prefetch: the sheet opened without its values and they arrived while the
    # card slid up (they do not ride along with it).
    exported = ROOT / "crates/swiftly-uniffi/src/seerr_title_screen.rs"
    if exported.exists():
        for i, line in enumerate(exported.read_text().splitlines()):
            if re.search(r"\bc\.(title|related|service_servers|service_detail)\(", line):
                problems.append((exported, i + 1, "own Seerr reads: forward to swiftly_vm::SeerrTitleScreen (prefetch lives there)"))
    for path, number, why in problems:
        print(f"      {path.relative_to(ROOT)}:{number}  {why}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
