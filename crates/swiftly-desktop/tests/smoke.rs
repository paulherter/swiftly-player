//! Window-less smoke tests: no window and no GPU, so they run on CI machines.

use std::path::PathBuf;
use swiftly_desktop::cli::Options;
use swiftly_desktop::demo::Route;
use swiftly_desktop::headless;
use swiftly_desktop::shell::{Command, Shell};
use swiftly_desktop::wheel::{WheelDelta, WheelPhase};
use swiftly_ui::Cx;

fn shell() -> Shell {
    Shell::new((1000, 700), 1.0, Cx::deterministic())
}

#[test]
fn headless_run_draws_the_home_page_and_writes_a_png() {
    let png: PathBuf = std::env::temp_dir().join("swiftly-desktop-smoke.png");
    let opts = Options {
        frames: Some(3),
        png: Some(png.clone()),
        size: (800, 600),
        ..Options::default()
    };
    let r = headless::run(&opts).unwrap_or_else(|e| panic!("headless: {e}"));
    assert_eq!(r.size_px, (800, 600));
    assert!(r.quads > 50, "{} quads", r.quads);
    assert!(r.ink > 0.2, "mostly blank: {}", r.ink);
    assert!(!r.still_moving, "an idle page must not ask for frames");
    assert!(png.exists());
    let _ = std::fs::remove_file(png);
}

#[test]
fn an_idle_page_asks_for_no_more_frames() {
    let mut s = shell();
    let (_, more) = s.frame(0.0);
    let (_, more2) = s.frame(16.0);
    assert!(!more && !more2);
    assert!(!s.wants_frame());
}

#[test]
fn clicking_a_tile_pushes_the_detail_page_and_back_pops_it() {
    let mut s = shell();
    s.frame(0.0);
    // The first poster of the first rail (margin 18, row below the title and rail header).
    s.cursor_moved((70.0, 200.0), 10.0);
    s.primary_button(true, 20.0);
    s.primary_button(false, 60.0);
    assert_eq!(s.demo().nav().depth(), 2, "tap pushed");
    assert!(s.wants_frame(), "the push animates");
    let mut t = 60.0;
    let mut frames = 0;
    while s.frame(t).1 && frames < 200 {
        t += 1000.0 / 60.0;
        frames += 1;
    }
    assert!(
        frames > 20 && frames < 40,
        "0.45 s at 60 Hz: {frames} frames"
    );
    assert!(matches!(
        s.demo().nav().top(),
        Some(Route::Detail { rail: 0, .. })
    ));
    assert!(!s.wants_frame(), "back to idle after the push");
    assert!(s.command(Command::Back, t + 10.0));
    let mut t2 = t + 10.0;
    while s.frame(t2).1 {
        t2 += 1000.0 / 60.0;
    }
    assert_eq!(s.demo().nav().depth(), 1);
    assert_eq!(s.demo().nav().pages().count(), 1);
    assert!(!s.command(Command::Back, t2 + 10.0), "no back at the root");
}

#[test]
fn wheel_scrolls_the_page_vertically_and_a_rail_horizontally() {
    let mut s = shell();
    s.frame(0.0);
    let before = s.demo().scroll_offsets();
    s.cursor_moved((500.0, 200.0), 1.0);
    let mut t = 2.0;
    s.wheel(WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Started), t);
    for _ in 0..20 {
        t += 8.0;
        s.wheel(WheelDelta::Points(-30.0, 0.0), Some(WheelPhase::Moved), t);
        s.frame(t);
    }
    t += 8.0;
    s.wheel(WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Ended), t);
    while s.frame(t).1 {
        t += 1000.0 / 60.0;
    }
    let after = s.demo().scroll_offsets();
    assert!(
        after
            .iter()
            .zip(&before)
            .any(|(a, b)| (a - b).abs() > 100.0),
        "a rail moved: {before:?} -> {after:?}"
    );
    // The page is taller than 700 pt: scrolling down moves the page scroll view.
    let mut t3 = t + 100.0;
    s.cursor_moved((500.0, 400.0), t3);
    s.wheel(WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Started), t3);
    for _ in 0..15 {
        t3 += 8.0;
        s.wheel(WheelDelta::Points(0.0, -30.0), Some(WheelPhase::Moved), t3);
        s.frame(t3);
    }
    t3 += 8.0;
    s.wheel(WheelDelta::Points(0.0, 0.0), Some(WheelPhase::Ended), t3);
    while s.frame(t3).1 {
        t3 += 1000.0 / 60.0;
    }
    let page = s.demo().scroll_offsets();
    assert!(
        page.first().copied().unwrap_or(0.0) > 50.0,
        "page scrolled: {page:?}"
    );
}

#[test]
fn the_rails_build_only_what_is_near_the_viewport() {
    let mut s = shell();
    s.frame(0.0);
    assert!(
        s.demo().built_items() < 100,
        "{} of 600 built",
        s.demo().built_items()
    );
}

#[test]
fn autoplay_runs_a_round_without_panicking_and_keeps_asking_for_frames() {
    let mut s = shell();
    s.enable_autoplay();
    let mut t = 0.0;
    let mut pushed = false;
    for _ in 0..(9000 / 16) {
        let (_, more) = s.frame(t);
        assert!(more);
        pushed |= s.demo().nav().depth() == 2;
        t += 16.0;
    }
    assert!(pushed, "the scripted click opened a detail page");
}

#[test]
fn a_press_after_a_lost_release_is_not_ignored() {
    let mut s = shell();
    s.frame(0.0);
    // A press whose release never arrives (Windows window drag, focus lost with the button down).
    s.cursor_moved((300.0, 5.0), 5.0);
    s.primary_button(true, 6.0);
    // The next click must work at its own position, not be swallowed.
    s.cursor_moved((70.0, 200.0), 10.0);
    s.primary_button(true, 20.0);
    s.primary_button(false, 60.0);
    assert_eq!(
        s.demo().nav().depth(),
        2,
        "the tap after the lost release pushed the title page"
    );
}
