//! One motion tour per main screen (Start, Library, Detail, Series, Settings, Player). Each tour triggers the animations the
//! screen has (hover in and out, press, context menu opening and fading out, dropdown panels, scrolling, paging, controls
//! fading, volume compartment, skip indicator, sheets) with the motion catalogue in strict mode: a curve outside
//! `swiftly_motion::catalogue` panics at the screen that started it. Every tour also checks that something really moved.

use swiftly_desktop::browse::Scenario as BrowseScenario;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::library_screen::LibraryScreen;
use swiftly_desktop::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_layout::Size;
use swiftly_motion::catalogue::{self, Id};
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};

const STEP: f64 = 1000.0 / 60.0;
const SIZE: (f32, f32) = (1280.0, 800.0);

fn env() -> Env {
    Env::new(Size::new(SIZE.0, SIZE.1), 1.0, Idiom::Desktop)
}

fn strict() {
    catalogue::set_strict(true);
    catalogue::clear_off_catalogue();
}

/// Checks the tour of `what`: no curve outside the table, something moved, and every curve in `expect` ran.
fn verdict(what: &str, frames_that_changed: usize, expect: &[Id]) {
    let off = catalogue::off_catalogue();
    let used = catalogue::used();
    catalogue::set_strict(false);
    for id in expect {
        assert!(
            used.contains(id),
            "{what}: {id:?} never ran; the tour used {used:?}"
        );
    }
    assert!(
        off.is_empty(),
        "{what}: curves outside the catalogue: {off:?}"
    );
    assert!(
        frames_that_changed > 10,
        "{what}: the tour moved nothing ({frames_that_changed} changing frames)"
    );
}

/// Runs the frames of `ms` and counts how many differ from the previous one.
macro_rules! run {
    ($s:ident, $now:ident, $changed:ident, $last:ident, $ms:expr) => {{
        let end = $now + $ms;
        while $now < end {
            $now += STEP;
            let (list, _) = $s.frame($now);
            let sum: f64 = list
                .quads()
                .iter()
                .map(|q| f64::from(q.rect.x + q.rect.y + q.rect.w + q.opacity * 100.0))
                .sum();
            if (sum - $last).abs() > 1e-6 {
                $changed += 1;
            }
            $last = sum;
        }
    }};
}

/// The pointer walks over a grid, rests, a right click opens a context menu at the pointer, the menu is dismissed (it fades out),
/// the wheel and the keys scroll. Shared by the four content screens.
macro_rules! content_tour {
    ($name:literal, $s:ident, $keys:expr, $expect:expr) => {{
        strict();
        let (mut now, mut changed, mut last) = (0.0_f64, 0_usize, 0.0_f64);
        run!($s, now, changed, last, 700.0);
        for yi in 0..7 {
            for xi in 0..7 {
                let (x, y) = (
                    SIZE.0 * (0.14 + 0.12 * xi as f32),
                    SIZE.1 * (0.18 + 0.11 * yi as f32),
                );
                $s.pointer_move(x, y, now);
                run!($s, now, changed, last, 60.0);
            }
        }
        $s.pointer_leave(now);
        run!($s, now, changed, last, 300.0);
        // Press and release on a spread of points (press feedback in and out).
        for (fx, fy) in [(0.3, 0.4), (0.5, 0.5), (0.7, 0.6)] {
            $s.touch_down(SIZE.0 * fx, SIZE.1 * fy, now);
            run!($s, now, changed, last, 80.0);
            $s.touch_up(SIZE.0 * fx, SIZE.1 * fy, now);
            run!($s, now, changed, last, 400.0);
        }
        // Context menu at the pointer: opens at once, fades out when dismissed with Escape.
        for (fx, fy) in [(0.3, 0.45), (0.5, 0.55), (0.25, 0.7)] {
            if $s.secondary_click(SIZE.0 * fx, SIZE.1 * fy, now) {
                run!($s, now, changed, last, 300.0);
                let _ = $s.nav_key(NavKey::Escape, true, now);
                let _ = $s.nav_key(NavKey::Escape, false, now + 10.0);
                run!($s, now, changed, last, 500.0);
                break;
            }
        }
        // Wheel and keys (scrolling, glide, paging).
        for _ in 0..6 {
            $s.wheel_scroll(SIZE.0 * 0.5, SIZE.1 * 0.5, 0.0, -90.0, now);
            run!($s, now, changed, last, 120.0);
        }
        for k in $keys {
            let _ = $s.nav_key(k, true, now);
            let _ = $s.nav_key(k, false, now + 10.0);
            run!($s, now, changed, last, 250.0);
        }
        run!($s, now, changed, last, 1200.0);
        verdict($name, changed, &$expect);
    }};
}

#[test]
fn start_tour() {
    let mut s = HomeScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    content_tour!(
        "start",
        s,
        [
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Right),
            NavKey::Arrow(Dir::Right),
            NavKey::Arrow(Dir::Up)
        ],
        [Id::Float, Id::NativeFade, Id::Arrow]
    );
}

#[test]
fn start_loading_tour_pulses_the_placeholders() {
    strict();
    let mut s = HomeScreen::new(env(), Cx::deterministic(), Scenario::Loading);
    let (mut now, mut changed, mut last) = (0.0_f64, 0_usize, 0.0_f64);
    run!(s, now, changed, last, 2000.0);
    // The placeholders pulse: the picture changes for as long as the page waits.
    verdict("start loading", changed, &[Id::Pulse]);
}

#[test]
fn library_tour() {
    let mut s = LibraryScreen::new(
        env(),
        Cx::deterministic(),
        &swiftly_desktop::library_screen::Kind::Movies,
        BrowseScenario::Ready,
    );
    content_tour!(
        "library",
        s,
        [
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Right)
        ],
        [Id::Float]
    );
}

#[test]
fn detail_tour() {
    let mut s = DetailScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    content_tour!(
        "detail",
        s,
        [
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Down)
        ],
        [Id::Float]
    );
}

#[test]
fn series_tour() {
    let mut s = SeriesScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    content_tour!(
        "series",
        s,
        [
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Down),
            NavKey::Arrow(Dir::Down)
        ],
        [Id::Float]
    );
}

#[test]
fn settings_tour_includes_choice_list_and_the_confirmation_sheet() {
    use swiftly_desktop::settings_screen::SettingsScreen;
    use swiftly_vm::{Confirm, RowControl, SettingsIntent};
    strict();
    let mut s = SettingsScreen::new(env(), Cx::deterministic(), true);
    let (mut now, mut changed, mut last) = (0.0_f64, 0_usize, 0.0_f64);
    run!(s, now, changed, last, 600.0);
    for yi in 0..12 {
        for xi in 0..6 {
            s.pointer_move(
                SIZE.0 * (0.25 + 0.1 * xi as f32),
                SIZE.1 * (0.12 + 0.07 * yi as f32),
                now,
            );
            run!(s, now, changed, last, 30.0);
        }
    }
    s.pointer_leave(now);
    run!(s, now, changed, last, 300.0);
    // A choice list opens and closes (the dropdown panel, `leap`).
    s.open_page("playback");
    run!(s, now, changed, last, 500.0);
    let choice = s
        .vm()
        .sections()
        .sections
        .iter()
        .flat_map(|x| &x.rows)
        .find(|r| matches!(r.control, RowControl::Choice { .. }))
        .map(|r| r.key.to_owned())
        .unwrap_or_default();
    s.show_choice(&choice);
    run!(s, now, changed, last, 600.0);
    s.back(now);
    run!(s, now, changed, last, 600.0);
    // Turning downloads off asks first: the sheet slides down, a choice slides it back up.
    s.open_page("general");
    run!(s, now, changed, last, 500.0);
    let key = s
        .vm()
        .sections()
        .sections
        .iter()
        .flat_map(|x| &x.rows)
        .find(|r| {
            r.key.to_lowercase().contains("download")
                && matches!(r.control, RowControl::Switch { .. })
        })
        .map(|r| r.key.to_owned())
        .expect("a downloads switch");
    s.vm()
        .send(SettingsIntent::SetSwitch { key, on: false })
        .unwrap_or_default();
    run!(s, now, changed, last, 700.0);
    assert_eq!(s.vm().status().confirm, Some(Confirm::DisableDownloads));
    s.vm()
        .send(SettingsIntent::ConfirmDisableDownloads { delete: false })
        .unwrap_or_default();
    run!(s, now, changed, last, 700.0);
    verdict("settings", changed, &[Id::Float, Id::SheetNative, Id::Leap]);
}

#[test]
fn player_tour() {
    strict();
    let mut s = PlayerScreen::new(env(), Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let (mut now, mut changed, mut last) = (0.0_f64, 0_usize, 0.0_f64);
    run!(s, now, changed, last, 1000.0);
    // The controls come with the pointer and go after 4 s idle (fade in easeOut 0.18, out easeInOut 0.34).
    s.pointer_move(SIZE.0 * 0.5, SIZE.1 * 0.5, now);
    run!(s, now, changed, last, 600.0);
    for i in 0..10 {
        s.pointer_move(SIZE.0 * (0.4 + 0.02 * i as f32), SIZE.1 * 0.5, now);
        run!(s, now, changed, last, 100.0);
    }
    run!(s, now, changed, last, 5500.0);
    // The rail buttons light up under the pointer (`timeFloat`).
    for i in 0..14 {
        s.pointer_move(SIZE.0 - 60.0 - 40.0 * i as f32, 44.0, now);
        run!(s, now, changed, last, 120.0);
    }
    // Skip indicator, volume, mute, pause, fullscreen, layers.
    s.pointer_move(SIZE.0 * 0.5, SIZE.1 * 0.5, now);
    run!(s, now, changed, last, 400.0);
    for key in [
        PlayerKey::Right,
        PlayerKey::Right,
        PlayerKey::Left,
        PlayerKey::Up,
        PlayerKey::Down,
        PlayerKey::Char('m'),
        PlayerKey::Char('m'),
        PlayerKey::Space,
        PlayerKey::Space,
        PlayerKey::Char('f'),
        PlayerKey::Char('f'),
    ] {
        let _ = s.key(key, now);
        run!(s, now, changed, last, 350.0);
    }
    // The volume compartment: the wheel over the speaker opens it (width 0 to 96), it closes on its own.
    s.volume_wheel(SIZE.0 - 330.0, 44.0, -3.0, false, now);
    run!(s, now, changed, last, 600.0);
    run!(s, now, changed, last, 2500.0);
    // Layers: the track list opens and closes (easeInOut 0.2).
    let _ = s.key(PlayerKey::Char('t'), now);
    run!(s, now, changed, last, 600.0);
    let _ = s.key(PlayerKey::Escape, now);
    run!(s, now, changed, last, 600.0);
    verdict(
        "player",
        changed,
        &[
            Id::ControlsIn,
            Id::ControlsOut,
            Id::SkipDisplay,
            Id::VolumeOpen,
            Id::PlayerLayer,
            Id::Float,
        ],
    );
}
