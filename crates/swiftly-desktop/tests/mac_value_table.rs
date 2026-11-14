//! The Mac value table of the desktop motion, pinned on both sides. The Mac side is read from `Sources/` (the SwiftUI
//! text must still be there); the desktop side is the value the Rust code runs with. If either side moves, this fails:
//! a change of a Mac curve must be taken over on purpose, and a desktop value cannot drift away from the Mac.
//! The values come from measurements of the Mac app.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_motion::catalogue::Id;
use swiftly_motion::profile::{Glide, Os, ScrollTuning};
use swiftly_motion::{scroll, tuning};
use swiftly_ui::nav::tuning as nav;

fn mac(file: &str) -> String {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    std::fs::read_to_string(root.join(file)).unwrap_or_else(|e| panic!("{file}: {e}"))
}

/// The Mac side: (file, text that must stand in it). Everything the desktop page, panel and section motion copies.
const MAC_TEXT: &[(&str, &str)] = &[
    (
        "Sources/macOS/Style.swift",
        "static let durationPagesPush: Double = 0.45",
    ),
    (
        "Sources/macOS/Style.swift",
        "static let timePagesPush = Animation.easeInOut(duration: durationPagesPush)",
    ),
    ("Sources/macOS/Style.swift", ".snappy(duration: 0.22)"),
    ("Sources/macOS/Style.swift", "static let timeFloat"),
    (
        "Sources/macOS/MainView.swift",
        "let withGait = -width * 0.3",
    ),
    (
        "Sources/macOS/MainView.swift",
        "Theme.reason.opacity(shown && !uppermost ? 0.28 : 0)",
    ),
    (
        "Sources/macOS/MainView.swift",
        "LinearGradient(colors: [Theme.reason.opacity(0.45), .clear]",
    ),
    ("Sources/macOS/MainView.swift", ".frame(width: 28)"),
    (
        "Sources/Shared/Transitions.swift",
        ".spring(response: 0.35, dampingFraction: 0.9)",
    ),
    (
        "Sources/Shared/Motion.swift",
        ".spring(response: 0.35, dampingFraction: 0.86)",
    ),
    (
        "Packages/JellyfinKit/Sources/JellyfinKit/FadeTimes.swift",
        "public static let pageToOut = 0.12",
    ),
    (
        "Packages/JellyfinKit/Sources/JellyfinKit/FadeTimes.swift",
        "public static let pageFromIn = 0.22",
    ),
];

#[test]
fn the_mac_side_of_the_table_is_still_in_the_sources() {
    for (file, text) in MAC_TEXT {
        assert!(
            mac(file).contains(text),
            "{file} no longer contains `{text}`: take the new Mac value over (table and Rust)"
        );
    }
}

fn spring(id: Id) -> (f64, f64) {
    let s = id
        .curve()
        .as_spring()
        .unwrap_or_else(|| panic!("{id:?} is not a spring"));
    (s.stiffness, s.damping)
}

#[test]
fn page_push_pop_and_the_layer_below() {
    // Mac: easeInOut 0.45 s, page below -0.3 x width, scrim 28 %, 28 pt edge gradient from 45 % (MainView.swift:417,571-580).
    assert_eq!(nav::DESKTOP_PUSH_SECONDS, 0.45);
    assert_eq!(nav::DESKTOP_BELOW_SHIFT, 0.30);
    assert_eq!(nav::DESKTOP_DIM, 0.28);
    assert_eq!(nav::DESKTOP_EDGE_WIDTH, 28.0);
    assert_eq!(nav::DESKTOP_EDGE_ALPHA, 0.45);
    let c = Id::PagesPush.curve();
    assert_eq!(c.settle_seconds(), 0.45);
    // easeInOut (0.42, 0, 0.58, 1): half the distance in half the time, and no overshoot.
    assert!(
        (c.progress(0.225) - 0.5).abs() < 0.01,
        "{}",
        c.progress(0.225)
    );
    assert!(c.progress(0.45) <= 1.0 + 1e-9);
}

#[test]
fn panels_sheets_and_the_section_switch() {
    // leap: snappy(0.22) -> k 815.7, c 48.55; sheet: spring(0.35, 0.86) -> k 322.3, c 30.88; picker: spring(0.35, 0.9) -> c 32.31.
    let (k, c) = spring(Id::Leap);
    assert!(
        (k - 815.7).abs() < 0.1 && (c - 48.55).abs() < 0.05,
        "{k} {c}"
    );
    let (k, c) = spring(Id::Sheet);
    assert!(
        (k - 322.3).abs() < 0.1 && (c - 30.88).abs() < 0.05,
        "{k} {c}"
    );
    let (k, c) = spring(Id::AccountPicker);
    assert!(
        (k - 322.3).abs() < 0.1 && (c - 32.31).abs() < 0.05,
        "{k} {c}"
    );
    // Section switch: the old section leaves in 0.12 s (easeIn), the new one arrives in 0.22 s (easeOut) after it.
    assert_eq!(Id::SectionOut.curve().settle_seconds(), 0.12);
    let e = Id::SectionIn.entry();
    assert_eq!(
        (e.delay, Id::SectionIn.curve().settle_seconds()),
        (0.12, 0.22 + 0.12)
    );
    // Hover and press: easeOut 0.12 s.
    assert_eq!(Id::Float.curve().settle_seconds(), 0.12);
    assert_eq!(Id::PressRelease.curve().settle_seconds(), 0.12);
    // The panel in and out of the settings page uses the AppKit sheet time (0.2 s) on the desktop.
    assert_eq!(Id::SheetNative.curve().settle_seconds(), 0.2);
}

#[test]
fn scroll_feel_of_the_desktop() {
    // The Mac has no scroll code of its own (plain ScrollView, AppKit momentum); these are the documented public values of that
    // feel: WebKit's re-creation of the AppKit curve, Chromium's Windows notch, UIKit's rubber band. Community grade, not Mac source.
    let w = ScrollTuning::for_os(Os::Windows);
    assert_eq!(w.release, Glide::MacTrackpad);
    assert_eq!(
        (
            tuning::MAC_MOMENTUM_DECAY_FAST,
            tuning::MAC_MOMENTUM_DECAY_SLOW
        ),
        (0.975, 0.91)
    );
    assert_eq!(
        (
            tuning::MAC_MOMENTUM_SLOW_BELOW,
            tuning::MAC_MOMENTUM_STEP_MS
        ),
        (250.0, 8.0)
    );
    assert_eq!(w.velocity_stale_ms, 100.0);
    assert_eq!(w.min_fling_speed, 120.0);
    assert_eq!(w.notch_px, 100.0);
    assert_eq!(w.notch_smoothing_ms, 140.0);
    assert_eq!(w.touchpad_gain, 1.0);
    // Windows and Linux desktop apps never bounce; the Mac and touch do.
    assert!(!w.rubber_band && !w.rail_snaps);
    assert!(ScrollTuning::for_os(Os::MacOs).rubber_band && ScrollTuning::touch().rubber_band);
    assert_eq!(tuning::RUBBER_COEFFICIENT, 0.55);
    assert_eq!(tuning::BACK_SETTLE_SECONDS, 0.45);
    // The rubber band at 100 pt past the edge of a 800 pt viewport: (1 - 1 / (100 x 0.55 / 800 + 1)) x 800 = 51.46 pt.
    assert!(
        (scroll::rubber_band(100.0, 800.0) - 51.46).abs() < 0.1,
        "{}",
        scroll::rubber_band(100.0, 800.0)
    );
    // The Mac's poster rails page by 3 x (150 + 16) pt with easeInOut 0.28 s (`Reveal`).
    assert_eq!(Id::Reveal.curve().settle_seconds(), 0.28);
}
