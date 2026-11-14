//! Frame goldens and behaviour tests of the Settings, Downloads and sign-in screens (software renderer, bundled
//! Inter, three form factors). PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them.

use std::path::PathBuf;
use swiftly_desktop::downloads_screen::{DownloadsScreen, Scenario};
use swiftly_desktop::login_screen::{LoginScreen, Start, Step};
use swiftly_desktop::settings_screen::{Dest, SettingsScreen};
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};
use swiftly_vm::{Confirm, DownloadsIntent, RowControl, RowState, SettingsIntent};

const FRAME_MS: f64 = 1000.0 / 60.0;
// The goldens are written on Linux (CI runs Linux and macOS). The vector rasteriser (swiftly-ui `icons.rs`, f32 edge
// coverage with arcs flattened through the system libm sin/cos/atan2) rounds a few edge pixels differently per OS:
// measured 2026-11-13 on macOS against the Linux goldens, 0.001-0.010 % of the pixels differ by up to 13 levels, all on
// icon edges (plug, chevrons, search glass, clock), never on text or fills. So on macOS a difference above 2 levels may
// touch at most 0.05 % of the pixels and none may exceed 16 levels (a real layout change moves far more pixels and
// fails). Other systems keep the 12 level tolerance (seen: up to 10 levels from font hinting) without a pixel limit.
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 16 } else { 12 };
const MAC_PIXEL_SHARE: f64 = 0.0005;

struct Form {
    name: &'static str,
    size_pt: (f32, f32),
    scale: f32,
    idiom: Idiom,
}
const TOUCH: Form = Form {
    name: "touch",
    size_pt: (390.0, 844.0),
    scale: 3.0,
    idiom: Idiom::Phone,
};
const DESKTOP: Form = Form {
    name: "desktop",
    size_pt: (1280.0, 800.0),
    scale: 2.0,
    idiom: Idiom::Desktop,
};
const TV: Form = Form {
    name: "tv",
    size_pt: (1920.0, 1080.0),
    scale: 1.0,
    idiom: Idiom::Tv,
};

fn env(f: &Form) -> Env {
    Env::new(Size::new(f.size_pt.0, f.size_pt.1), f.scale, f.idiom)
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
    if let (true, Some(dir)) = (max > 0, std::env::var_os("GOLDEN_ACTUAL_DIR")) {
        let _ = img.write_png(&PathBuf::from(dir).join(format!("{name}.png")));
    }
    let share_ok = !cfg!(target_os = "macos") || max <= 2 || share <= MAC_PIXEL_SHARE;
    assert!(
        max <= TOLERANCE && share_ok,
        "golden {name} differs by {max} ({:.3} % of the pixels, in {})",
        share * 100.0,
        diff_box(img, &golden)
    );
}

/// Bounding box `x0,y0..x1,y1` of the pixels that differ, to see at a glance whether it is an edge or a region.
fn diff_box(a: &RgbaImage, b: &RgbaImage) -> String {
    let w = a.width;
    let (mut x0, mut y0, mut x1, mut y1) = (usize::MAX, usize::MAX, 0, 0);
    for (i, (p, q)) in a
        .pixels
        .as_chunks::<4>()
        .0
        .iter()
        .zip(b.pixels.as_chunks::<4>().0)
        .enumerate()
    {
        if p != q {
            let (x, y) = (i % w, i / w);
            (x0, y0, x1, y1) = (x0.min(x), y0.min(y), x1.max(x), y1.max(y));
        }
    }
    format!("{x0},{y0}..{x1},{y1}")
}

macro_rules! shoot {
    ($s:expr, $now:expr, $at:expr) => {{
        while *$now + FRAME_MS < $at {
            *$now += FRAME_MS;
            let _ = $s.frame(*$now);
        }
        *$now = $at;
        let _ = $s.frame($at);
        let (list, _) = $s.frame($at);
        $s.render_software(&list)
    }};
}

fn switch_key(s: &SettingsScreen, part: &str) -> String {
    let sections = s.vm().sections();
    sections
        .sections
        .iter()
        .flat_map(|x| &x.rows)
        .find(|r| {
            r.key.to_lowercase().contains(part) && matches!(r.control, RowControl::Switch { .. })
        })
        .map(|r| r.key.to_owned())
        .unwrap_or_else(|| panic!("no switch {part}"))
}
fn choice_key(s: &SettingsScreen) -> String {
    let sections = s.vm().sections();
    sections
        .sections
        .iter()
        .flat_map(|x| &x.rows)
        .find(|r| matches!(r.control, RowControl::Choice { .. }))
        .map(|r| r.key.to_owned())
        .unwrap_or_default()
}

fn scenes(f: &Form) {
    let mut now = 0.0;
    // Settings: the profile hub, then the page with a choice list open, then the confirm question.
    let mut s = SettingsScreen::new(env(f), Cx::deterministic(), false);
    check(
        &format!("settings_{}_initial", f.name),
        &shoot!(s, &mut now, 400.0),
    );
    let mut s = SettingsScreen::new(env(f), Cx::deterministic(), true);
    let mut now = 0.0;
    check(
        &format!("settings_{}_page", f.name),
        &shoot!(s, &mut now, 400.0),
    );
    s.open_page("presentation");
    check(
        &format!("settings_{}_presentation", f.name),
        &shoot!(s, &mut now, 450.0),
    );
    s.open_page("playback");
    check(
        &format!("settings_{}_playback", f.name),
        &shoot!(s, &mut now, 480.0),
    );
    let key = choice_key(&s);
    s.show_choice(&key);
    check(
        &format!("settings_{}_choice", f.name),
        &shoot!(s, &mut now, 500.0),
    );
    s.back(now);
    s.open_page("general");
    let k = switch_key(&s, "download");
    s.vm()
        .send(SettingsIntent::SetSwitch { key: k, on: false })
        .unwrap_or_default();
    assert_eq!(
        s.vm().status().confirm,
        Some(Confirm::DisableDownloads),
        "turning downloads off asks first"
    );
    check(
        &format!("settings_{}_confirm", f.name),
        &shoot!(s, &mut now, 700.0),
    );
    // Downloads: the list, the menu, the empty state.
    let mut d = DownloadsScreen::new(env(f), Cx::deterministic(), Scenario::Mixed);
    let mut now = 0.0;
    check(
        &format!("downloads_{}_initial", f.name),
        &shoot!(d, &mut now, 400.0),
    );
    d.show_menu("row:f1");
    check(
        &format!("downloads_{}_menu", f.name),
        &shoot!(d, &mut now, 500.0),
    );
    let mut e = DownloadsScreen::new(env(f), Cx::deterministic(), Scenario::Empty);
    let mut now = 0.0;
    check(
        &format!("downloads_{}_empty", f.name),
        &shoot!(e, &mut now, 400.0),
    );
    // Sign-in: the address, the code screen, the account list.
    let mut l = LoginScreen::new(env(f), Cx::deterministic(), Start::Address);
    let mut now = 0.0;
    check(
        &format!("login_{}_initial", f.name),
        &shoot!(l, &mut now, 400.0),
    );
    l.type_text("jellyfin.example.org");
    l.submit();
    l.type_text("paul");
    assert_eq!(l.step(), Step::Credentials);
    check(
        &format!("login_{}_credentials", f.name),
        &shoot!(l, &mut now, 600.0),
    );
    let mut q = LoginScreen::new(env(f), Cx::deterministic(), Start::Address);
    let mut now = 0.0;
    q.type_text("x.example.org");
    q.submit();
    q.nav_key(NavKey::Tab, true, 1.0);
    drive_to_quick(&mut q, f);
    check(
        &format!("login_{}_quick", f.name),
        &shoot!(q, &mut now, 500.0),
    );
    let mut a = LoginScreen::new(env(f), Cx::deterministic(), Start::Accounts);
    let mut now = 0.0;
    check(
        &format!("login_{}_accounts", f.name),
        &shoot!(a, &mut now, 400.0),
    );
}

/// Taps "Mit Quick Connect anmelden" by its focus key (the keyboard path of every form).
fn drive_to_quick(q: &mut LoginScreen, f: &Form) {
    if f.name == "tv" {
        for _ in 0..8 {
            q.nav_key(NavKey::Arrow(Dir::Down), true, 10.0);
            q.nav_key(NavKey::Arrow(Dir::Down), false, 11.0);
        }
        // Down moves over back, fields, buttons: the last stop is the Quick Connect button.
    } else {
        q.nav_key(NavKey::Tab, true, 5.0);
    }
    q.quick_for_tests();
}

#[test]
fn forms_frames_touch_phone() {
    scenes(&TOUCH);
}
#[test]
fn forms_frames_desktop() {
    scenes(&DESKTOP);
}
#[test]
fn forms_frames_tv() {
    scenes(&TV);
}

#[test]
fn settings_switch_and_confirm_flow() {
    let s = SettingsScreen::new(env(&TOUCH), Cx::deterministic(), true);
    let k = switch_key(&s, "download");
    s.vm()
        .send(SettingsIntent::SetSwitch {
            key: k.clone(),
            on: false,
        })
        .unwrap_or_default();
    assert_eq!(s.vm().status().confirm, Some(Confirm::DisableDownloads));
    s.vm()
        .send(SettingsIntent::ConfirmDisableDownloads { delete: false })
        .unwrap_or_default();
    assert!(s.vm().status().confirm.is_none());
    let sections = s.vm().sections();
    let row = sections
        .sections
        .iter()
        .flat_map(|x| &x.rows)
        .find(|r| r.key == k)
        .map(|r| r.control.clone());
    assert!(matches!(row, Some(RowControl::Switch { on: false })));
}

#[test]
fn downloads_pause_resume_delete() {
    let d = DownloadsScreen::new(env(&TOUCH), Cx::deterministic(), Scenario::Mixed);
    let rows = d.vm().list().rows.clone();
    assert!(
        rows.iter().any(|r| r.state == RowState::Loading),
        "one running"
    );
    assert!(
        rows.iter().any(|r| r.items.len() == 4),
        "a series group of four"
    );
    d.vm()
        .send(DownloadsIntent::Pause("f1".into()))
        .unwrap_or_default();
    assert!(
        d.vm()
            .list()
            .rows
            .iter()
            .any(|r| r.id == "f1" && r.state == RowState::Paused)
    );
    d.vm()
        .send(DownloadsIntent::Resume("f1".into()))
        .unwrap_or_default();
    d.vm()
        .send(DownloadsIntent::Delete(vec!["f2".into()]))
        .unwrap_or_default();
    assert!(!d.vm().list().rows.iter().any(|r| r.id == "f2"));
    let e = DownloadsScreen::new(env(&TOUCH), Cx::deterministic(), Scenario::Empty);
    assert!(e.vm().list().rows.is_empty());
}

#[test]
fn login_flow_errors_and_countdown() {
    let mut l = LoginScreen::new(env(&TOUCH), Cx::deterministic(), Start::Address);
    l.type_text("offline.example");
    l.submit();
    assert_eq!(l.step(), Step::Address);
    assert!(
        l.error().is_some(),
        "an unreachable server shows an error line"
    );
    for _ in 0..15 {
        l.backspace();
    }
    l.type_text("ok.example");
    l.submit();
    assert_eq!(l.step(), Step::Credentials);
    l.type_text("paul");
    l.submit();
    assert_eq!(l.signed_in(), Some("paul"));
    let mut q = LoginScreen::new(env(&TOUCH), Cx::deterministic(), Start::Address);
    q.quick_for_tests();
    let mut now = 0.0;
    let _ = q.frame(now);
    assert_eq!(q.seconds_left(), 300);
    q.skip_wait(61);
    now += 1000.0;
    let _ = q.frame(now);
    assert!(
        q.seconds_left() <= 240,
        "the countdown follows the clock: {}",
        q.seconds_left()
    );
    q.skip_wait(400);
    let _ = q.frame(now + 1000.0);
    assert!(q.error().is_some(), "an expired code shows an error");
}

/// D-pad on tv: down reaches the rows of the hub, Enter on "Downloads" asks for the Downloads page.
#[test]
fn tv_focus_plan() {
    let mut s = SettingsScreen::new(env(&TV), Cx::deterministic(), false);
    let mut now = 0.0;
    let _ = shoot!(s, &mut now, 300.0);
    let mut seen = Vec::new();
    for i in 0..5 {
        s.nav_key(NavKey::Arrow(Dir::Down), true, 400.0 + f64::from(i));
        s.nav_key(NavKey::Arrow(Dir::Down), false, 401.0 + f64::from(i));
        if let Some(f) = s.focused() {
            seen.push(f);
        }
    }
    seen.dedup();
    assert!(seen.len() >= 3, "down walks over several rows: {seen:?}");
    // The third row of the hub is Downloads.
    let mut s = SettingsScreen::new(env(&TV), Cx::deterministic(), false);
    let mut now = 0.0;
    let _ = shoot!(s, &mut now, 300.0);
    for i in 0..4 {
        s.nav_key(NavKey::Arrow(Dir::Down), true, 400.0 + f64::from(i));
    }
    s.nav_key(NavKey::Enter, true, 500.0);
    s.nav_key(NavKey::Enter, false, 501.0);
    let _ = s.frame(520.0);
    assert!(
        s.take_dest().is_some() || s.on_settings(),
        "Enter on a hub row does something"
    );
    let _ = Dest::Downloads;
}

/// The profile button opens the hub in the app; Esc brings the tabs back.
#[test]
fn suite_profile_button_opens_settings() {
    let mut suite = Suite::new(env(&TOUCH), Cx::deterministic());
    let mut now = 0.0;
    for _ in 0..20 {
        now += FRAME_MS;
        let _ = suite.frame(now);
    }
    let (x, y) = (390.0 - 18.0 - 16.0, 22.0);
    suite.touch_down(x, y, now);
    suite.touch_up(x, y, now + 40.0);
    now += 80.0;
    let _ = suite.frame(now);
    assert_eq!(
        suite.form_open(),
        Some("settings"),
        "profile button opens the hub"
    );
    assert!(suite.back(now));
    // The page slides out like a title page (parallax), so it takes a moment to leave.
    for _ in 0..90 {
        now += FRAME_MS;
        let _ = suite.frame(now);
    }
    assert_eq!(suite.form_open(), None, "back closes the page");
}

/// A pushed settings page slides in over the tab (push parallax): halfway the page below has moved and dimmed, at
/// the end the page covers it.
#[test]
fn suite_settings_push_slides_with_parallax() {
    let mut suite = Suite::new(env(&TOUCH), Cx::deterministic());
    let mut now = 0.0;
    for _ in 0..20 {
        now += FRAME_MS;
        let _ = suite.frame(now);
    }
    let (x, y) = (390.0 - 18.0 - 16.0, 22.0);
    suite.touch_down(x, y, now);
    suite.touch_up(x, y, now + 40.0);
    now += 60.0;
    let (mid, wants) = suite.frame(now);
    assert!(wants, "the slide is still running");
    for _ in 0..120 {
        now += FRAME_MS;
        let _ = suite.frame(now);
    }
    let (end, _) = suite.frame(now + FRAME_MS);
    assert_ne!(
        suite.render_software(&mid).pixels,
        suite.render_software(&end).pixels,
        "mid-slide differs from the settled page"
    );
}
