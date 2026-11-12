//! Navigation probe/flow: sidebar pages, panels and transitions through the real `Suite` (demo, software renderer).
#![allow(clippy::unwrap_used)]

use swiftly_desktop::a11y_bridge;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;
const SIZE: (f32, f32) = (1280.0, 800.0);

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn tap_label(s: &mut Suite, now: &mut f64, label: &str) -> bool {
    let (title, tree) = s.a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    let id = built
        .update
        .nodes
        .iter()
        .find(|(_, x)| x.label() == Some(label))
        .map(|(i, _)| i.0);
    let Some(&(x, y)) = id.and_then(|i| built.centres.get(&i)) else {
        return false;
    };
    s.touch_down(x, y, *now);
    s.touch_up(x, y, *now + 40.0);
    *now += 80.0;
    true
}

fn dump(s: &mut Suite, now: f64, dir: &str, name: &str) {
    if std::env::var("NAV_FRAMES").is_err() {
        return;
    }
    let (list, _) = s.frame(now);
    let img = s.render_software(&list);
    let _ = std::fs::create_dir_all(dir);
    let _ = img.write_png(std::path::Path::new(&format!("{dir}/{name}.png")));
}

fn app() -> (Suite, f64) {
    let env = Env::new(Size::new(SIZE.0, SIZE.1), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 400.0);
    (s, now)
}

#[test]
fn sidebar_pages_are_sections_with_the_right_highlight() {
    use swiftly_desktop::nav_machine::Selected;
    let (mut s, mut now) = app();
    for (label, tab, sel) in [
        ("Merkliste", 4, Selected::Watchlist),
        ("Filme", 1, Selected::Tab(1)),
        ("Serien", 2, Selected::Tab(2)),
        ("Suche", 3, Selected::Tab(3)),
        ("Start", 0, Selected::Tab(0)),
    ] {
        assert!(tap_label(&mut s, &mut now, label), "{label}");
        run_for(&mut s, &mut now, 700.0);
        assert_eq!(
            (s.tab(), s.top_kind(), s.selected()),
            (tab, None, sel),
            "{label}"
        );
    }
    // Downloads: a page, no slide, highlighted; leaving it brings the tab back without a stuck page.
    assert!(tap_label(&mut s, &mut now, "Downloads"));
    for _ in 0..4 {
        now += STEP;
        let _ = s.frame(now);
        assert!(!s.sliding(), "Downloads must not slide in");
        assert_eq!(
            s.below_shift(),
            0.0,
            "the page behind Downloads must not move"
        );
    }
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(
        (s.form_open(), s.selected()),
        (Some("downloads"), Selected::Downloads)
    );
    assert!(tap_label(&mut s, &mut now, "Filme"));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(
        (s.form_open(), s.tab(), s.selected()),
        (None, 1, Selected::Tab(1))
    );
}

#[test]
fn settings_slide_in_selected_and_slide_out_to_the_right_for_every_page() {
    use swiftly_desktop::nav_machine::Selected;
    for (label, tab) in [
        ("Start", 0),
        ("Filme", 1),
        ("Serien", 2),
        ("Suche", 3),
        ("Merkliste", 4),
        ("Downloads", 5),
    ] {
        let (mut s, mut now) = app();
        assert!(tap_label(&mut s, &mut now, "Konto"));
        run_for(&mut s, &mut now, 700.0);
        assert_eq!(
            (s.form_open(), s.selected()),
            (Some("settings"), Selected::Settings),
            "{label}"
        );
        assert!(tap_label(&mut s, &mut now, label));
        // The highlight moves at once; the panel is still on its way out to the right and the page behind travels in.
        now += STEP;
        let _ = s.frame(now);
        assert_ne!(s.selected(), Selected::Settings, "{label}: highlight");
        let mut shifts = Vec::new();
        let mut frames = 0;
        while s.form_open().is_some() && frames < 90 {
            now += STEP;
            let _ = s.frame(now);
            shifts.push(s.below_shift());
            frames += 1;
            if frames == 10 {
                dump(
                    &mut s,
                    now,
                    "target/nav-frames",
                    &format!("panel-out-{tab}-f10"),
                );
            }
        }
        if tab != 5 {
            assert_eq!(s.form_open(), None, "{label}: the panel must leave");
            assert_eq!(s.tab(), tab, "{label}");
            assert!(
                shifts.iter().any(|d| *d < -1.0),
                "{label}: the page behind must travel in from the left ({shifts:?})"
            );
            assert!(
                shifts.windows(2).all(|w| w[1] >= w[0] - 0.5),
                "{label}: it moves left to right only"
            );
        } else {
            run_for(&mut s, &mut now, 900.0);
            assert_eq!(
                (s.form_open(), s.selected()),
                (Some("downloads"), Selected::Downloads)
            );
        }
    }
}

#[test]
fn going_back_moves_the_page_behind_from_left_to_right() {
    let (mut s, mut now) = app();
    assert!(tap_label(&mut s, &mut now, "Filme"));
    run_for(&mut s, &mut now, 700.0);
    let before = s.pushes();
    'scan: for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                SIZE.0 * (0.30 + 0.05 * xi as f32),
                SIZE.1 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, now);
            s.touch_up(x, y, now + 40.0);
            now += 80.0;
            if s.pushes() > before {
                break 'scan;
            }
        }
    }
    assert!(s.title_open());
    let mut enter = Vec::new();
    for i in 0..40 {
        now += STEP;
        let _ = s.frame(now);
        enter.push(s.below_shift());
        if i == 12 {
            dump(&mut s, now, "target/nav-frames", "push-f12");
        }
    }
    run_for(&mut s, &mut now, 800.0);
    assert!(s.back(now));
    let mut leave = Vec::new();
    for i in 0..40 {
        now += STEP;
        let _ = s.frame(now);
        leave.push(s.below_shift());
        if i == 12 {
            dump(&mut s, now, "target/nav-frames", "pop-f12");
        }
    }
    eprintln!("enter dx {enter:?}\nleave dx {leave:?}");
    assert!(
        enter.iter().any(|d| *d < -50.0),
        "the page behind moves back on push"
    );
    assert!(
        leave.iter().any(|d| *d < -50.0),
        "the page behind must travel on pop: {leave:?}"
    );
    let moving: Vec<f32> = leave.iter().copied().filter(|d| *d != 0.0).collect();
    assert!(
        moving.windows(2).all(|w| w[1] >= w[0] - 0.5),
        "left to right only: {moving:?}"
    );
}

#[test]
fn clicking_the_active_account_does_nothing_harmful() {
    let (mut s, mut now) = app();
    assert!(tap_label(&mut s, &mut now, "Konto"));
    run_for(&mut s, &mut now, 700.0);
    let pushes = s.pushes();
    let (title, tree) = s.a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    // The demo has one account row, shown above the plus row; tapping it keeps the panel open and the app where it is.
    let id = built
        .update
        .nodes
        .iter()
        .find(|(_, x)| x.label().is_some_and(|l| l.contains("Konto hinzuf")))
        .map(|(i, _)| i.0);
    assert!(id.is_some(), "the plus row ends the account list");
    run_for(&mut s, &mut now, 300.0);
    assert_eq!((s.form_open(), s.pushes()), (Some("settings"), pushes));
}

#[test]
fn probe() {
    let env = Env::new(Size::new(SIZE.0, SIZE.1), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 400.0);
    for label in ["Merkliste", "Downloads", "Filme", "Merkliste", "Start"] {
        let ok = tap_label(&mut s, &mut now, label);
        run_for(&mut s, &mut now, 700.0);
        eprintln!(
            "tap {label}: found={ok} tab={} top={:?} form={:?} pushes={}",
            s.tab(),
            s.top_kind(),
            s.form_open(),
            s.pushes()
        );
    }
}

/// Labels of the sidebar entries the screen reader reports as selected (what the eye sees highlighted).
fn selected_labels(s: &Suite) -> Vec<String> {
    let (title, tree) = s.a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    let mut out: Vec<String> = built
        .update
        .nodes
        .iter()
        .filter(|(_, n)| {
            n.is_selected() == Some(true)
                && matches!(n.role(), accesskit::Role::Tab | accesskit::Role::Button)
        })
        .filter_map(|(_, n)| n.label().map(str::to_owned))
        .collect();
    out.sort();
    out
}

#[test]
fn the_rendered_sidebar_follows_the_machine_for_settings() {
    for (label, other) in [
        ("Start", "Start"),
        ("Filme", "Filme"),
        ("Serien", "Serien"),
        ("Merkliste", "Merkliste"),
        ("Downloads", "Downloads"),
    ] {
        let (mut s, mut now) = app();
        assert!(tap_label(&mut s, &mut now, label));
        run_for(&mut s, &mut now, 700.0);
        assert!(
            selected_labels(&s).contains(&other.to_owned()),
            "{label}: before settings {:?}",
            selected_labels(&s)
        );
        assert!(tap_label(&mut s, &mut now, "Konto"));
        run_for(&mut s, &mut now, 700.0);
        assert_eq!(
            selected_labels(&s),
            ["Konto"],
            "{label}: with the settings open only the account card is selected"
        );
        // Back out through the account card (a second tap closes the panel) and the page row is selected again.
        assert!(tap_label(&mut s, &mut now, label));
        run_for(&mut s, &mut now, 900.0);
        assert!(
            selected_labels(&s).contains(&other.to_owned()),
            "{label}: after settings {:?}",
            selected_labels(&s)
        );
        assert!(
            !selected_labels(&s).contains(&"Konto".to_owned()),
            "{label}: the card must not stay selected"
        );
    }
}
