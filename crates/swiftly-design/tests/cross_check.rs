//! Cross-check of the generated tokens against `data/system.json` (kit snapshot) and the values quoted in
//! the measured values of the Apple screens.
//!
//! Every row names a token, the value the document quotes and the generated value (if the design file has one).
//! Differences are not hidden: they are listed in `KNOWN_MISMATCHES` / `KNOWN_GAPS` below and in `NOTES.md`.
//! A new difference, or a fixed one that is still listed, fails the test.

// Test helpers may panic on a broken fixture.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::path::{Path, PathBuf};

use serde_json::Value;
use swiftly_design::tokens::{colour, common, desktop, touch, tv};

fn manifest() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn system() -> Value {
    let text =
        std::fs::read_to_string(manifest().join("data/system.json")).expect("data/system.json");
    serde_json::from_str(&text).expect("system.json is JSON")
}

/// `white N %` as 0xRRGGBBAA.
fn white(pct: f32) -> u32 {
    0xFFFF_FF00 | (pct * 2.55).round() as u32
}

fn opaque(rgb: u32) -> u32 {
    (rgb << 8) | 0xFF
}

/// Value of `system.json` at `section.entry[.mode]`, as text for colours.
fn sys_colour(system: &Value, entry: &str, mode: &str) -> u32 {
    let text = system["color"][entry][mode]
        .as_str()
        .unwrap_or_else(|| panic!("color.{entry}.{mode}"));
    let prim = |name: &str| -> u32 {
        match name {
            "white" => 0xFFFF_FFFF,
            "black" => 0x0000_00FF,
            n => {
                let hex = system["primitive"][n]
                    .as_str()
                    .unwrap_or_else(|| panic!("primitive {n}"));
                opaque(u32::from_str_radix(hex.trim_start_matches('#'), 16).expect("hex"))
            }
        }
    };
    match text.split_once(' ') {
        Some((base, pct)) => {
            let p: f32 = pct.trim_end_matches('%').parse().expect("percent");
            (prim(base) & 0xFFFF_FF00) | (p * 2.55).round() as u32
        }
        None => prim(text),
    }
}

/// A number from `system.json`: `path` like `size.poster`, `mode`, optional index into an array.
fn sys_num(system: &Value, path: &str, mode: &str, idx: Option<usize>) -> f32 {
    let mut v = system;
    for p in path.split('.') {
        v = &v[p];
    }
    v = &v[mode];
    if let Some(i) = idx {
        v = &v[i];
    }
    v.as_f64()
        .unwrap_or_else(|| panic!("{path}.{mode}{idx:?} is not a number")) as f32
}

struct NumRow {
    label: &'static str,
    path: &'static str,
    mode: &'static str,
    idx: Option<usize>,
    /// Value quoted in apple-screens.md section 1.
    doc: f32,
    /// Generated value, `None` when the design file has no such variable.
    got: Option<f32>,
}

fn n(
    label: &'static str,
    path: &'static str,
    mode: &'static str,
    idx: Option<usize>,
    doc: f32,
    got: Option<f32>,
) -> NumRow {
    NumRow {
        label,
        path,
        mode,
        idx,
        doc,
        got,
    }
}

#[rustfmt::skip]
fn number_rows() -> Vec<NumRow> {
    vec![
        // Spacing
        n("page margin touch", "space.page", "ios", None, 18.0, Some(touch::EDGE_SPACING)),
        n("page margin desktop", "space.page", "macos", None, 36.0, Some(desktop::EDGE_SPACING)),
        n("page margin tv", "space.page", "tvos", None, 80.0, None),
        n("content top desktop", "space.contentTop", "macos", None, 58.0, Some(desktop::CONTENT_TOP)),
        n("content top tv", "space.contentTop", "tvos", None, 196.0, Some(tv::CONTENT_TOP)),
        n("header top touch", "space.headerTop", "ios", None, 28.0, Some(touch::HEADER_TOP)),
        n("header top tv", "space.headerTop", "tvos", None, 60.0, None),
        n("tile gap touch", "space.tileGap", "ios", None, 12.0, Some(touch::TILE_SPACING)),
        n("tile gap desktop", "space.tileGap", "macos", None, 16.0, Some(desktop::TILE_SPACING)),
        n("tile gap tv", "space.tileGap", "tvos", None, 40.0, Some(tv::TILE_SPACING)),
        n("rail gap touch", "space.railGap", "ios", None, 40.0, Some(touch::RAILS_SPACING)),
        n("rail gap desktop", "space.railGap", "macos", None, 40.0, Some(desktop::RAILS_SPACING)),
        n("rail gap tv", "space.railGap", "tvos", None, 72.0, Some(tv::RAILS_SPACING)),
        n("sheet inset touch", "space.sheet", "all", None, 24.0, Some(touch::SHEET_INSET)),
        n("sheet inset desktop", "space.sheet", "all", None, 24.0, Some(desktop::SHEET_INSET)),
        n("sheet inset tv", "space.sheet", "all", None, 24.0, None),
        n("grid row touch", "space.gridRow", "ios", None, 32.0, Some(touch::GRID_ROW_GAP)),
        n("grid row desktop", "space.gridRow", "macos", None, 24.0, None),
        n("grid row tv", "space.gridRow", "tvos", None, 58.0, Some(tv::LATTICE_ROW)),
        n("group top touch", "space.groupTop", "ios", None, 48.0, Some(touch::GROUP_TOP)),
        n("group top desktop", "space.groupTop", "macos", None, 18.0, None),
        n("group top tv", "space.groupTop", "tvos", None, 36.0, None),
        n("card gap touch", "space.cardGap", "ios", None, 32.0, Some(touch::CARD_GAP)),
        n("card gap desktop", "space.cardGap", "macos", None, 14.0, None),
        n("separator card touch", "space.separatorCard", "ios", None, 34.0, None),
        n("separator card desktop", "space.separatorCard", "macos", None, 52.0, Some(desktop::SEPARATOR_INSET_CARD)),
        n("title gap tv", "space.titleGap", "tvos", None, 28.0, Some(tv::TITLE_SPACING)),
        n("top bar tv", "space.topBar", "tvos", None, 68.0, Some(tv::TAB_HEIGHT)),
        n("settings columns tv", "space.settingsColumns", "tvos", None, 72.0, None),
        // Radii
        n("radius small touch", "radius.small", "ios", None, 8.0, Some(touch::CORNER_SMALL)),
        n("radius small desktop", "radius.small", "macos", None, 8.0, Some(common::THEME_CORNER_SMALL)),
        n("radius small tv", "radius.small", "tvos", None, 14.0, None),
        n("radius control touch", "radius.control", "ios", None, 10.0, Some(touch::CORNER)),
        n("radius control desktop", "radius.control", "macos", None, 10.0, Some(desktop::CORNER)),
        n("radius control tv", "radius.control", "tvos", None, 16.0, None),
        n("radius tile touch", "radius.tile", "ios", None, 10.0, Some(touch::CORNER_TILE)),
        n("radius tile desktop", "radius.tile", "macos", None, 10.0, Some(desktop::CORNER_TILE)),
        n("radius tile tv", "radius.tile", "tvos", None, 18.0, None),
        n("radius field touch", "radius.field", "ios", None, 10.0, Some(touch::CORNER_FIELD)),
        n("radius field desktop", "radius.field", "macos", None, 12.0, Some(desktop::CORNER_FIELD)),
        n("radius card touch", "radius.card", "ios", None, 16.0, Some(touch::CORNER_CARD)),
        n("radius card desktop", "radius.card", "macos", None, 14.0, Some(desktop::CORNER_CARD)),
        n("radius card tv", "radius.card", "tvos", None, 16.0, None),
        n("radius area touch", "radius.area", "ios", None, 16.0, Some(touch::CORNER_AREA)),
        n("radius area desktop", "radius.area", "macos", None, 16.0, Some(desktop::CORNER_AREA)),
        n("radius area tv", "radius.area", "tvos", None, 24.0, None),
        n("radius sheet touch", "radius.sheet", "all", None, 28.0, Some(touch::CORNER_SHEET)),
        n("radius sheet desktop", "radius.sheet", "all", None, 28.0, Some(desktop::CORNER_SHEET)),
        n("radius panel desktop", "radius.panel", "macos", None, 12.0, None),
        // Sizes
        n("poster width touch", "size.poster", "ios", Some(0), 116.0, Some(touch::TILE_WIDTH)),
        n("poster height touch", "size.poster", "ios", Some(1), 174.0, Some(touch::TILE_HEIGHT)),
        n("poster width desktop", "size.poster", "macos", Some(0), 150.0, Some(desktop::TILE_WIDTH)),
        n("poster height desktop", "size.poster", "macos", Some(1), 225.0, Some(desktop::TILE_HEIGHT)),
        n("poster width tv", "size.poster", "tvos", Some(0), 208.0, Some(tv::POSTER_WIDTH)),
        n("poster height tv", "size.poster", "tvos", Some(1), 312.0, Some(tv::POSTER_HEIGHT)),
        n("landscape width touch", "size.landscape", "ios", Some(0), 280.0, Some(touch::HERO_ROW_WIDTH)),
        n("landscape height touch", "size.landscape", "ios", Some(1), 158.0, Some(touch::HERO_ROW_HEIGHT)),
        n("landscape width desktop", "size.landscape", "macos", Some(0), 280.0, Some(desktop::LANDSCAPE_WIDTH)),
        n("landscape height desktop", "size.landscape", "macos", Some(1), 158.0, Some(desktop::LANDSCAPE_HEIGHT)),
        n("landscape width tv", "size.landscape", "tvos", Some(0), 448.0, Some(tv::LANDSCAPE_WIDTH)),
        n("landscape height tv", "size.landscape", "tvos", Some(1), 252.0, Some(tv::LANDSCAPE_HEIGHT)),
        n("hero touch", "size.hero", "ios", None, 350.0, Some(touch::HERO_HEIGHT_VALUE)),
        n("hero desktop (detail image)", "size.hero", "macos", None, 454.0, Some(desktop::DETAIL_HERO_IMAGE)),
        n("hero tv", "size.hero", "tvos", None, 510.0, Some(tv::HERO_HEIGHT)),
        n("control touch", "size.control", "ios", None, 56.0, Some(touch::CONTROL_HEIGHT)),
        n("control desktop", "size.control", "macos", None, 40.0, Some(desktop::BUTTON_FIELD)),
        n("control tv", "size.control", "tvos", None, 56.0, Some(tv::CHIP_HEIGHT)),
        n("primary desktop", "size.primary", "macos", None, 48.0, Some(desktop::PRIMARY_BUTTON_HEIGHT)),
        n("primary tv", "size.primary", "tvos", None, 76.0, Some(tv::BUTTON_HEIGHT)),
        n("primary touch", "size.primary", "ios", None, 56.0, None),
        n("row touch", "size.row", "ios", None, 60.0, Some(touch::ROW_HEIGHT)),
        n("row desktop", "size.row", "macos", None, 52.0, None),
        n("row tv", "size.row", "tvos", None, 84.0, None),
        n("row icon touch", "size.rowIcon", "all", None, 20.0, Some(touch::ROW_SYMBOL_SIZE)),
        n("row icon desktop", "size.rowIcon", "all", None, 20.0, Some(desktop::ROW_SYMBOL_SIZE)),
        n("progress touch", "size.progress", "ios", None, 4.0, Some(common::TIME_SLIDER_THICKNESS)),
        n("progress dragging", "size.progress", "dragging", None, 6.0, Some(common::TIME_SLIDER_THICKNESS_RAISED)),
        n("progress tv", "size.progress", "tvos", None, 8.0, None),
        n("sidebar desktop", "size.sidebar", "macos", None, 220.0, Some(desktop::SIDEBAR_WIDTH)),
        n("toolbar desktop", "size.toolbar", "macos", None, 52.0, Some(desktop::TOOLBAR_HEIGHT)),
        n("window min width", "size.window", "macos", Some(0), 900.0, Some(desktop::WINDOW_MIN_WIDTH)),
        n("window min height", "size.window", "macos", Some(1), 560.0, Some(desktop::WINDOW_MIN_HEIGHT)),
        n("chip touch", "size.chip", "ios", None, 30.0, None),
        n("chip desktop", "size.chip", "macos", None, 30.0, None),
        n("chip tv", "size.chip", "tvos", None, 56.0, Some(tv::CHIP_HEIGHT)),
        n("tab tv", "size.tab", "tvos", None, 68.0, Some(tv::TAB_HEIGHT)),
        n("player icon touch", "size.iconButton", "player", None, 44.0, None),
        n("player icon tv", "size.iconButton", "tvosPlayer", None, 88.0, Some(tv::PLAYER_BUTTON)),
        n("search key tv", "size.searchKey", "tvos", None, 64.0, None),
        n("read width touch", "size.readWidth", "all", None, 700.0, Some(touch::READ_WIDTH)),
        n("read width desktop", "size.readWidth", "all", None, 700.0, Some(desktop::READ_WIDTH)),
        n("form width touch", "size.formWidth", "all", None, 420.0, Some(touch::FORM_WIDTH)),
        n("form width desktop", "size.formWidth", "all", None, 420.0, Some(desktop::FORM_WIDTH)),
        n("episode card width", "size.episodeCard", "all", None, 600.0, None),
        n("toggle width touch", "size.toggle", "ios", Some(0), 46.0, None),
        n("toggle width desktop", "size.toggle", "macos", Some(0), 38.0, None),
        n("toggle width tv", "size.toggle", "tvos", Some(0), 84.0, None),
        // Tracking (design file: `lock*`; kit: type ladder)
        n("title tracking touch", "type.titleLarge.ios", "tracking", None, -0.7, Some(touch::LOCK_TITLE)),
        n("title tracking desktop", "type.titleLarge.macos", "tracking", None, -0.5, Some(desktop::LOCK_TITLE)),
        n("title tracking tv", "type.titleLarge.tvos", "tracking", None, -1.176, Some(tv::LOCK_TITLE)),
        n("subpage tracking touch", "type.subpage.ios", "tracking", None, -0.4, Some(touch::LOCK_SUBPAGE)),
        n("subpage tracking desktop", "type.subpage.macos", "tracking", None, -0.6, Some(desktop::LOCK_SUBPAGE)),
        n("subpage tracking tv", "type.subpage.tvos", "tracking", None, -0.616, Some(tv::LOCK_SUBPAGE)),
        n("section tracking touch", "type.section.ios", "tracking", None, -0.308, Some(touch::LOCK_SECTION)),
        n("section tracking desktop", "type.section.macos", "tracking", None, -0.484, Some(desktop::LOCK_SECTION)),
        n("section tracking tv", "type.section.tvos", "tracking", None, -0.528, Some(tv::LOCK_SECTION)),
        n("rail tracking touch", "type.rail.ios", "tracking", None, -0.24, Some(touch::LOCK_RAIL)),
        n("rail tracking desktop", "type.rail.macos", "tracking", None, -0.24, Some(desktop::LOCK_RAIL)),
        n("rail tracking tv", "type.rail.tvos", "tracking", None, -0.528, Some(tv::LOCK_RAIL)),
        n("category tracking touch", "type.category.ios", "tracking", None, -0.136, Some(touch::LOCK_CATEGORY)),
        n("category tracking desktop", "type.category.macos", "tracking", None, -0.136, Some(desktop::LOCK_CATEGORY)),
        n("category tracking tv", "type.category.tvos", "tracking", None, -0.272, Some(tv::LOCK_CATEGORY)),
        n("group tracking touch", "type.group.ios", "tracking", None, 1.54, Some(touch::LOCK_GROUP)),
        n("group tracking desktop", "type.group.macos", "tracking", None, 1.54, Some(desktop::LOCK_GROUP)),
        n("group tracking tv", "type.group.tvos", "tracking", None, 3.08, Some(tv::LOCK_GROUP)),
        n("player title tracking tv", "type.playerTitle.tvos", "tracking", None, -1.2, Some(tv::PLAYER_TITLE_TRACKING)),
    ]
}

/// Rows where the generated value differs from the quoted/kit value. See NOTES.md.
const KNOWN_MISMATCHES: &[&str] = &["section tracking touch"];

/// Rows the design file has no variable for (the code needs these from the kit). See NOTES.md.
const KNOWN_GAPS: &[&str] = &[
    "page margin tv",
    "header top tv",
    "sheet inset tv",
    "grid row desktop",
    "group top desktop",
    "group top tv",
    "card gap desktop",
    "separator card touch",
    "settings columns tv",
    "radius small tv",
    "radius control tv",
    "radius tile tv",
    "radius card tv",
    "radius area tv",
    "radius panel desktop",
    "primary touch",
    "row desktop",
    "row tv",
    "progress tv",
    "chip touch",
    "chip desktop",
    "player icon touch",
    "search key tv",
    "episode card width",
    "toggle width touch",
    "toggle width desktop",
    "toggle width tv",
];

fn near(a: f32, b: f32) -> bool {
    (a - b).abs() < 1e-4
}

#[test]
fn numbers_match_the_kit_and_apple_screens() {
    let system = system();
    let mut mismatches = Vec::new();
    let mut gaps = Vec::new();
    for r in number_rows() {
        let (path, mode) = (r.path, r.mode);
        let kit = if path.starts_with("type.") {
            // `type.<name>.<set>` + `tracking`
            let mut v = &system;
            for p in path.split('.') {
                v = &v[p];
            }
            v[mode].as_f64().unwrap_or_else(|| panic!("{path}.{mode}")) as f32
        } else {
            sys_num(&system, path, mode, r.idx)
        };
        // The document and the kit snapshot must agree with each other first.
        assert!(
            near(kit, r.doc),
            "{}: kit {kit} but apple-screens.md says {}",
            r.label,
            r.doc
        );
        match r.got {
            None => gaps.push(r.label),
            Some(g) if !near(g, r.doc) => {
                eprintln!("MISMATCH {}: expected {}, generated {g}", r.label, r.doc);
                mismatches.push(r.label);
            }
            Some(_) => {}
        }
    }
    for g in &gaps {
        eprintln!("GAP (not in design file): {g}");
    }
    let mut want_m: Vec<&str> = KNOWN_MISMATCHES.to_vec();
    want_m.sort_unstable();
    mismatches.sort_unstable();
    assert_eq!(
        mismatches, want_m,
        "mismatches changed; update KNOWN_MISMATCHES and NOTES.md"
    );
    let mut want_g: Vec<&str> = KNOWN_GAPS.to_vec();
    want_g.sort_unstable();
    gaps.sort_unstable();
    assert_eq!(gaps, want_g, "gaps changed; update KNOWN_GAPS and NOTES.md");
}

struct ColourRow {
    label: &'static str,
    entry: &'static str,
    mode: &'static str,
    doc: u32,
    got: Option<u32>,
}

fn c(
    label: &'static str,
    entry: &'static str,
    mode: &'static str,
    doc: u32,
    got: Option<u32>,
) -> ColourRow {
    ColourRow {
        label,
        entry,
        mode,
        doc,
        got,
    }
}

fn colour_rows() -> Vec<ColourRow> {
    vec![
        c(
            "reason (ground)",
            "ground",
            "all",
            opaque(0x101010),
            Some(colour::REASON.rgba8),
        ),
        c(
            "groupsArea",
            "groupsArea",
            "all",
            opaque(0x1E1E1E),
            Some(colour::GROUPS_AREA.rgba8),
        ),
        c(
            "area",
            "area",
            "all",
            opaque(0x262626),
            Some(colour::AREA.rgba8),
        ),
        c(
            "raised",
            "raised",
            "all",
            opaque(0x303030),
            Some(colour::RAISED.rgba8),
        ),
        c(
            "pressedArea",
            "pressed",
            "all",
            opaque(0x3A3A3A),
            Some(colour::PRESSED_AREA.rgba8),
        ),
        c(
            "selected",
            "selected",
            "all",
            white(8.0),
            Some(colour::SELECTED.rgba8),
        ),
        c(
            "surfaceTranslucent",
            "translucent",
            "all",
            white(8.0),
            Some(colour::SURFACE_TRANSLUCENT.rgba8),
        ),
        c(
            "hoverArea",
            "hover",
            "macos",
            white(6.0),
            Some(colour::HOVER_AREA.rgba8),
        ),
        c("font", "font", "all", 0xFFFF_FFFF, Some(colour::FONT.rgba8)),
        c(
            "fontQuiet",
            "fontQuiet",
            "all",
            opaque(0xCCCCCC),
            Some(colour::FONT_QUIET.rgba8),
        ),
        c(
            "fontVeryQuiet",
            "fontVeryQuiet",
            "all",
            opaque(0x989898),
            Some(colour::FONT_VERY_QUIET.rgba8),
        ),
        c("line", "line", "all", white(7.0), Some(colour::LINE.rgba8)),
        c(
            "margin",
            "margin",
            "all",
            white(12.0),
            Some(colour::MARGIN.rgba8),
        ),
        c(
            "accent (original teal)",
            "accent",
            "all",
            opaque(0x50D5DA),
            Some(colour::ORIGINAL_ACCENT.rgba8),
        ),
        c(
            "accentLight",
            "accentLight",
            "all",
            opaque(0x7AE6EA),
            Some(colour::ORIGINAL_ACCENT_LIGHT.rgba8),
        ),
        c(
            "accentQuiet",
            "accentQuiet",
            "all",
            opaque(0x113435),
            Some(colour::ORIGINAL_ACCENT_QUIET.rgba8),
        ),
        c(
            "onAccent",
            "onAccent",
            "all",
            opaque(0x061212),
            Some(colour::ORIGINAL_ON_ACCENT.rgba8),
        ),
        c(
            "warning",
            "warning",
            "all",
            opaque(0xE8833A),
            Some(colour::ORIGINAL_WARNING.rgba8),
        ),
        c(
            "error",
            "error",
            "all",
            opaque(0xEF6567),
            Some(colour::ERROR.rgba8),
        ),
        c(
            "primaryButtonHovers",
            "primaryHover",
            "macos",
            white(88.0),
            Some(colour::PRIMARY_BUTTON_HOVERS.rgba8),
        ),
        c("focusArea", "focusArea", "tvos", white(12.0), None),
    ]
}

const KNOWN_COLOUR_GAPS: &[&str] = &["focusArea"];

#[test]
fn colours_match_the_kit_and_apple_screens() {
    let system = system();
    let mut gaps = Vec::new();
    for r in colour_rows() {
        let kit = sys_colour(&system, r.entry, r.mode);
        assert_eq!(
            kit, r.doc,
            "{}: kit {kit:#010X} but apple-screens.md says {:#010X}",
            r.label, r.doc
        );
        match r.got {
            None => gaps.push(r.label),
            Some(g) => assert_eq!(
                g, r.doc,
                "{}: generated {g:#010X}, expected {:#010X}",
                r.label, r.doc
            ),
        }
    }
    assert_eq!(gaps, KNOWN_COLOUR_GAPS);
}

#[test]
fn headline_values_from_apple_screens() {
    // The ones quoted most often, spelled out so a wrong mapping cannot hide in the tables above.
    assert_eq!(colour::AREA.rgba8, 0x2626_26FF);
    assert_eq!(colour::ORIGINAL_ACCENT.rgba8, 0x50D5_DAFF);
    assert_eq!((touch::EDGE_SPACING, desktop::EDGE_SPACING), (18.0, 36.0));
    assert_eq!((touch::TILE_WIDTH, touch::TILE_HEIGHT), (116.0, 174.0));
    assert_eq!((desktop::TILE_WIDTH, desktop::TILE_HEIGHT), (150.0, 225.0));
    assert_eq!((tv::POSTER_WIDTH, tv::POSTER_HEIGHT), (208.0, 312.0));
}

#[test]
fn snapshot_equals_the_kit_file() {
    let Some(home) = std::env::var_os("HOME") else {
        eprintln!("skipped: HOME is not set");
        return;
    };
    let kit = Path::new(&home).join("Documents/Design-Kits/swiftly/tokens/system.json");
    let Ok(kit_text) = std::fs::read_to_string(&kit) else {
        eprintln!("skipped: {} not found", kit.display());
        return;
    };
    let mine = std::fs::read_to_string(manifest().join("data/system.json")).expect("snapshot");
    assert_eq!(
        mine, kit_text,
        "data/system.json differs from the kit; copy the kit file and regenerate"
    );
}
