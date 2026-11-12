//! Frames for the SwiftUI parity measurement (`cargo xtask swiftui-parity`): the same page and fixture as
//! `Tests/SwiftUIParity/ParitySnapshots.swift`, in the same 1280x800 @2x window. Settings and Downloads are shot inside
//! the full suite (sidebar, divider, content column) like the Mac window; the sign-in page has no sidebar on either
//! side. PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them.
//!
//! The older goldens (`settings_desktop_initial` = profile hub, `downloads_desktop_empty` = bare page, `login_desktop_initial`
//! = address page) stay in the measurement as history lines; these `*_suite_*` and `login_desktop_signin` ones are fair.
#![allow(clippy::unwrap_used)]

use std::path::PathBuf;
use swiftly_desktop::downloads_screen::{DownloadsScreen, Scenario};
use swiftly_desktop::login_screen::{LoginScreen, Start, Step};
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;
mod common;

fn env() -> Env {
    Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop)
}

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, share) = img.diff(&golden);
    assert!(
        common::golden_ok(max, share),
        "golden {name} differs by {max} ({:.4} % of the pixels)",
        share * 100.0
    );
}

/// Runs the suite for `ms` and returns the settled frame.
fn settle(s: &mut Suite, now: &mut f64, ms: f64) -> RgbaImage {
    let end = *now + ms;
    while *now < end {
        *now += FRAME_MS;
        let _ = s.frame(*now);
    }
    let (list, _) = s.frame(*now);
    s.render_software(&list)
}

fn suite() -> (Suite, f64) {
    let mut s = Suite::new(env(), Cx::deterministic());
    let mut now = 0.0;
    let _ = settle(&mut s, &mut now, 300.0);
    (s, now)
}

/// Settings > Allgemein (the page the Mac window shows) inside the suite.
#[test]
fn settings_general_in_the_suite() {
    swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
    let (mut s, mut now) = suite();
    assert!(s.open_settings(now));
    let _ = settle(&mut s, &mut now, 900.0);
    s.settings().unwrap().open_page("general");
    check("settings_suite_general", &settle(&mut s, &mut now, 600.0));
}

/// Downloads with nothing stored, inside the suite.
#[test]
fn downloads_empty_in_the_suite() {
    swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
    let (mut s, mut now) = suite();
    // The page shares the suite's text context: its shaped text is drawn by the suite's renderer.
    let screen = DownloadsScreen::new(env(), s.cx().clone(), Scenario::Empty);
    s.show_downloads(screen, now);
    check("downloads_suite_empty", &settle(&mut s, &mut now, 1200.0));
}

/// Downloads with the sample rows of `ParitySnapshots.testDownloadsFilled` (loading, waiting, failed, a series of eight,
/// one film), inside the suite. The Rust side follows the Swift fixture (`Scenario::Parity` mirrors it).
#[test]
fn downloads_filled_in_the_suite() {
    swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
    let (mut s, mut now) = suite();
    let screen = DownloadsScreen::new(env(), s.cx().clone(), Scenario::Parity);
    s.show_downloads(screen, now);
    check("downloads_suite_filled", &settle(&mut s, &mut now, 1200.0));
}

/// The same fixture in a taller window (1280x1100): the 1280x800 parity window cuts off after the fourth row on both sides
/// (the Swift render is a 1280x800 scroll view too), so this frame shows all five rows, the series `Die Nachbarn` included.
#[test]
fn downloads_filled_tall_in_the_suite() {
    swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
    let tall = || Env::new(Size::new(1280.0, 1100.0), 2.0, Idiom::Desktop);
    let mut s = Suite::new(tall(), Cx::deterministic());
    let mut now = 0.0;
    let _ = settle(&mut s, &mut now, 300.0);
    let screen = DownloadsScreen::new(tall(), s.cx().clone(), Scenario::Parity);
    s.show_downloads(screen, now);
    check(
        "downloads_suite_filled_tall",
        &settle(&mut s, &mut now, 1200.0),
    );
}

/// The sign-in page of the Mac (`SignInView`): server name, no user typed, no Quick Connect.
#[test]
fn login_sign_in_page() {
    let mut l = LoginScreen::new(env(), Cx::deterministic(), Start::Address);
    l.type_text("demo.swiftly.test");
    l.submit();
    assert_eq!(l.step(), Step::Credentials);
    let mut now = 0.0;
    while now < 900.0 {
        now += FRAME_MS;
        let _ = l.frame(now);
    }
    let (list, _) = l.frame(now);
    check("login_desktop_signin", &l.render_software(&list));
}
