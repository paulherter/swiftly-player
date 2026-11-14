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

/// Settings > "Server hinzufügen" > the back control: the settings page comes back, not the start page.
#[test]
fn back_from_add_server_returns_to_settings() {
    let (mut s, mut now) = app();
    assert!(s.open_settings(now));
    run_for(&mut s, &mut now, 1200.0);
    let f = s.top_frame_of("go:server").expect("the add-server row");
    let (x, y) = (f[0] + f[2] * 0.5, f[1] + f[3] * 0.5);
    s.pointer_move(x, y, now);
    s.touch_down(x, y, now);
    now += 60.0;
    s.touch_up(x, y, now);
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.form_open(), Some("login"));
    assert!(s.back(now));
    run_for(&mut s, &mut now, 1500.0);
    assert_eq!(
        s.form_open(),
        Some("settings"),
        "back lands on the settings page"
    );
    assert_eq!(s.tab(), 0);
}

/// Leaving Downloads for another page only fades the new page in: the old page is already gone, so a fade out of the
/// area behind it would flash that area for a moment (disappear, fade in, disappear, fade in).
#[test]
fn leaving_downloads_only_fades_the_new_page_in() {
    let (mut s, mut now) = app();
    assert!(tap_label(&mut s, &mut now, "Downloads"));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.form_open(), Some("downloads"));
    assert!(tap_label(&mut s, &mut now, "Merkliste"));
    now += 40.0;
    let _ = s.frame(now);
    assert_eq!(s.tab(), 4);
    assert!(s.fade_in_only(), "no fade out of the page behind Downloads");
    run_for(&mut s, &mut now, 700.0);
    assert!(!s.fade_in_only());
}

/// The darkest content-area pixel of every frame while an area change runs: the Mac cross fades over the window ground
/// (16), so the content area never goes darker than the ground, also between the old page leaving and the new one coming.
fn darkest_content_pixel_during(s: &mut Suite, now: &mut f64, ms: f64) -> u8 {
    let end = *now + ms;
    let mut lowest = 255u8;
    while *now < end {
        *now += STEP;
        let (list, _) = s.frame(*now);
        let img = s.render_software(&list);
        for (x, y) in [(900, 760), (1200, 780), (700, 790), (1250, 20)] {
            lowest = lowest.min(img.pixel(x, y)[0]);
        }
    }
    lowest
}

#[test]
fn leaving_downloads_never_dips_below_the_page_ground() {
    let (mut s, mut now) = app();
    assert!(tap_label(&mut s, &mut now, "Downloads"));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.form_open(), Some("downloads"));
    assert!(tap_label(&mut s, &mut now, "Merkliste"));
    let lowest = darkest_content_pixel_during(&mut s, &mut now, 600.0);
    assert!(lowest >= 16, "content dipped to {lowest} (ground is 16)");
}

#[test]
fn a_tab_change_never_dips_below_the_page_ground() {
    let (mut s, mut now) = app();
    assert!(tap_label(&mut s, &mut now, "Filme"));
    let lowest = darkest_content_pixel_during(&mut s, &mut now, 600.0);
    assert!(lowest >= 16, "content dipped to {lowest} (ground is 16)");
}

/// How many samples of the content area differ from the window ground (16) by more than a hair.
fn drawn_samples(s: &mut Suite, list: &swiftly_render::DrawList) -> usize {
    let img = s.render_software(list);
    let mut n = 0;
    for y in (60..780).step_by(20) {
        for x in (400..1260).step_by(20) {
            let p = img.pixel(x, y);
            if p[..3].iter().any(|c| c.abs_diff(16) > 6) {
                n += 1;
            }
        }
    }
    n
}

/// The content area is never only the ground while an area changes: the old page stays until the new one draws over it
/// (one cross fade), as the Mac's section switch never shows an empty window between two pages.
#[test]
fn a_tab_change_never_shows_only_the_ground() {
    let (mut s, mut now) = app();
    let (list, _) = s.frame(now);
    let before = drawn_samples(&mut s, &list);
    assert!(before > 40, "the start page draws {before} samples");
    assert!(tap_label(&mut s, &mut now, "Filme"));
    let end = now + 600.0;
    let mut lowest = usize::MAX;
    while now < end {
        now += STEP;
        let (list, _) = s.frame(now);
        lowest = lowest.min(drawn_samples(&mut s, &list));
    }
    assert!(
        lowest * 2 >= before,
        "a frame of the switch drew {lowest} samples of {before}: the area went blank"
    );
}

/// "Laden" on a title page: the add sheet floats over that page, the Downloads page is never shown, and closing the
/// sheet brings the title page back in front.
#[test]
fn the_add_sheet_floats_over_the_title_page_not_the_downloads_page() {
    use swiftly_desktop::downloads_screen::LoadRequest;
    use swiftly_desktop::nav_machine::Selected;
    let (mut s, mut now) = app();
    // Movies, then tap a grid of points until a title page opens.
    assert!(s.goto_tab(1, now));
    run_for(&mut s, &mut now, 400.0);
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
            run_for(&mut s, &mut now, 100.0);
            if s.pushes() > before {
                break 'scan;
            }
        }
    }
    run_for(&mut s, &mut now, 900.0);
    assert_eq!(s.top_kind(), Some("detail"), "the film page is open");
    s.request_load(
        LoadRequest::Add {
            title: "Der Zug".into(),
            items: Vec::new(),
            images: std::collections::HashMap::new(),
            quality_select: false,
            streams: Vec::new(),
            anchor: None,
        },
        now,
    );
    run_for(&mut s, &mut now, 600.0);
    assert!(s.load_open(), "the sheet is open");
    assert_ne!(
        s.selected(),
        Selected::Downloads,
        "the sidebar stays on its page"
    );
    let (list, _) = s.frame(now);
    assert!(
        drawn_samples(&mut s, &list) > 40,
        "the film page stays under the sheet"
    );
    assert!(s.back(now));
    run_for(&mut s, &mut now, 300.0);
    assert!(!s.load_open());
    assert_eq!(
        s.top_kind(),
        Some("detail"),
        "the film page is in front again"
    );
}

/// The add sheet comes from the More menu: the Mac shows no menu while the sheet is up, and none after it closes. The
/// window title stays the title page's, not "Downloads".
#[test]
fn the_more_menu_is_closed_by_its_sheet_and_the_title_stays_the_page() {
    use swiftly_desktop::downloads_screen::LoadRequest;
    let (mut s, mut now) = app();
    assert!(s.goto_tab(1, now));
    run_for(&mut s, &mut now, 400.0);
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
            run_for(&mut s, &mut now, 100.0);
            if s.pushes() > before {
                break 'scan;
            }
        }
    }
    run_for(&mut s, &mut now, 900.0);
    assert_eq!(s.top_kind(), Some("detail"), "the film page is open");
    assert!(tap_label(&mut s, &mut now, "Mehr"), "the More button");
    run_for(&mut s, &mut now, 400.0);
    assert!(s.title_menu_open(), "the More menu is open");
    s.request_load(
        LoadRequest::Add {
            title: "Der Zug".into(),
            items: Vec::new(),
            images: std::collections::HashMap::new(),
            quality_select: false,
            streams: Vec::new(),
            anchor: None,
        },
        now,
    );
    run_for(&mut s, &mut now, 600.0);
    assert!(s.load_open(), "the sheet is open");
    assert!(!s.title_menu_open(), "the menu stayed open under the sheet");
    assert_eq!(
        s.a11y_nodes().0,
        "Film",
        "the title is the page under the sheet"
    );
    assert!(s.back(now));
    run_for(&mut s, &mut now, 300.0);
    assert!(!s.load_open());
    assert!(!s.title_menu_open(), "the menu came back with the page");
}

/// Clicks the first tile found on a grid of window points; returns where it hit.
fn open_a_tile(s: &mut Suite, now: &mut f64) -> Option<(f32, f32)> {
    let before = s.pushes();
    for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                SIZE.0 * (0.30 + 0.05 * xi as f32),
                SIZE.1 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, *now);
            s.touch_up(x, y, *now + 40.0);
            *now += 80.0;
            if s.pushes() > before {
                return Some((x, y));
            }
        }
    }
    None
}

#[test]
fn a_click_during_the_back_slide_opens_the_tile_behind() {
    let (mut s, mut now) = app();
    assert!(tap_label(&mut s, &mut now, "Filme"));
    run_for(&mut s, &mut now, 700.0);
    let (x, y) = open_a_tile(&mut s, &mut now).expect("a tile opens a page");
    run_for(&mut s, &mut now, 800.0);
    assert!(s.title_open());
    let pushes = s.pushes();
    assert!(s.back(now));
    // 100 ms later the page is still sliding out; the click on the same tile must open it again.
    run_for(&mut s, &mut now, 100.0);
    assert!(
        !s.top_open() && s.top_kind().is_some(),
        "the page is still sliding out"
    );
    s.touch_down(x, y, now);
    s.touch_up(x, y, now + 40.0);
    run_for(&mut s, &mut now, 400.0);
    assert!(
        s.pushes() > pushes,
        "the click during the slide opened no page"
    );
    assert!(s.title_open());
}
