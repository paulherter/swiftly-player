#![allow(unused_assignments)]
//! Mac-parity flows of the Detail, Series and the new pages (headless, software renderer, fixed clock): the More panel and
//! the season list are anchored popovers, a right click opens the menu at the pointer, hover shows a tooltip, Esc closes
//! a panel before it goes back, and the new pages (person, playlist, genre, collection, Seerr) have goldens.
//! `UPDATE_GOLDENS=1` rewrites the goldens in `swiftly-ui/tests/golden`; tolerance as in `detail_frames`.

use std::path::PathBuf;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::pages_screen::{Kind, PageScreen};
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn env() -> Env {
    Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop)
}

const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, _) = img.diff(&golden);
    assert!(max <= TOLERANCE, "golden {name} differs by {max}");
}

macro_rules! settle {
    ($s:expr, $now:expr, $to:expr) => {{
        while $now + FRAME_MS < $to {
            $now += FRAME_MS;
            let _ = $s.frame($now);
        }
        $now = $to;
        $s.frame($to)
    }};
}

#[test]
fn detail_more_is_an_anchored_popover_and_escape_closes_it_first() {
    let mut s = DetailScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let _ = settle!(s, now, 1200.0);
    let f = s.frame_of("more").expect("more button");
    let (x, y) = (f[0] + f[2] * 0.5, f[1] + f[3] * 0.5);
    s.touch_down(x, y, now);
    s.touch_up(x, y, now + 40.0);
    now += 40.0;
    let _ = settle!(s, now, 1500.0);
    assert!(s.menu_open(), "a tap on More opens the panel");
    assert_eq!(s.sheet_kind(), 0, "no bottom sheet on the Mac");
    let (list, _) = s.frame(1600.0);
    check("detail_desktop_more_popover", &s.render_software(&list));
    s.nav_key(NavKey::Escape, true, 1700.0);
    assert!(!s.menu_open(), "Esc closes the panel");
    assert!(s.is_open(), "and the page stays");
}

#[test]
fn detail_hover_shows_the_tooltip_and_the_play_button_takes_a_right_click() {
    let mut s = DetailScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let _ = settle!(s, now, 1200.0);
    let f = s.frame_of("watched").expect("watched button");
    s.pointer_move(f[0] + 10.0, f[1] + 10.0, now);
    let _ = settle!(s, now, 2000.0);
    let tip = s.visible_tooltip(2000.0).expect("tooltip after the delay");
    assert!(tip.0.to_lowercase().contains("gesehen"), "{tip:?}");
    let p = s.frame_of("play").expect("play");
    assert!(
        s.secondary_click(p[0] + 20.0, p[1] + 20.0, now),
        "right click on play"
    );
    assert!(s.menu_open());
}

#[test]
fn series_season_list_toggles_under_its_tab_and_selecting_closes_it() {
    let mut s = SeriesScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let _ = settle!(s, now, 1200.0);
    assert!(s.vm().seasons().seasons.len() > 1);
    let f = s.frame_of("tab:0").expect("tab");
    s.touch_down(f[0] + 4.0, f[1] + 4.0, now);
    s.touch_up(f[0] + 4.0, f[1] + 4.0, now + 30.0);
    now += 30.0;
    let (list, _) = settle!(s, now, 1500.0);
    assert!(s.menu_open(), "the first tab opens the season list");
    check("series_desktop_seasons_popover", &s.render_software(&list));
    s.nav_key(NavKey::Arrow(Dir::Down), true, now);
    s.nav_key(NavKey::Enter, true, now + 10.0);
    assert!(!s.menu_open(), "a choice closes the list");
}

#[test]
fn series_episode_right_click_opens_the_menu_and_no_more_button_exists() {
    let mut s = SeriesScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let _ = settle!(s, now, 1200.0);
    assert!(
        s.frame_of("more-episodes").is_none(),
        "the Mac has no 'Mehr Folgen' button"
    );
    let f = s.frame_of("ep:0").expect("first episode row");
    assert!(
        (f[3] - 110.0).abs() < 0.5,
        "an episode row is 110 high, got {}",
        f[3]
    );
    assert!(s.secondary_click(f[0] + 300.0, f[1] + 30.0, now));
    assert!(s.menu_open());
}

#[test]
fn new_pages_goldens() {
    for (kind, name) in [
        (Kind::Person, "person"),
        (Kind::Playlist, "playlist"),
        (Kind::Genre, "genre"),
        (Kind::Collection, "collection"),
        (Kind::SeerrSearch, "seerr_search"),
        (Kind::SeerrDetail, "seerr_detail"),
    ] {
        for (state, scenario) in [
            ("initial", Scenario::Ready),
            ("loading", Scenario::Loading),
            ("offline", Scenario::Offline),
            ("empty", Scenario::Empty),
        ] {
            let mut s = PageScreen::new(env(), Cx::deterministic(), kind, scenario);
            let mut now = 0.0;
            let _ = s.frame(0.0);
            s.open(0.0);
            assert!(s.is_open());
            let (list, _) = settle!(s, now, 1200.0);
            check(
                &format!("{name}_desktop_{state}"),
                &s.render_software(&list),
            );
        }
    }
}

#[test]
fn collection_pills_open_a_dropdown_and_genre_has_none() {
    let mut s = PageScreen::new(
        env(),
        Cx::deterministic(),
        Kind::Collection,
        Scenario::Ready,
    );
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let _ = settle!(s, now, 1200.0);
    let f = s.frame_of("pill:filter").expect("filter pill");
    s.touch_down(f.x + 4.0, f.y + 4.0, now);
    s.touch_up(f.x + 4.0, f.y + 4.0, now + 30.0);
    assert!(s.menu_open());
    let mut g = PageScreen::new(env(), Cx::deterministic(), Kind::Genre, Scenario::Ready);
    let _ = g.frame(0.0);
    g.open(0.0);
    let _ = g.frame(1200.0);
    assert!(
        g.frame_of("pill:filter").is_none() && g.frame_of("pill:sort").is_none(),
        "the genre page has no filter or sort row"
    );
}

#[test]
fn playlist_play_starts_the_first_entry_and_person_biography_toggles() {
    let mut s = PageScreen::new(env(), Cx::deterministic(), Kind::Playlist, Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let _ = settle!(s, now, 1200.0);
    let f = s.frame_of("play").expect("play");
    s.touch_down(f.x + 10.0, f.y + 10.0, now);
    s.touch_up(f.x + 10.0, f.y + 10.0, now + 30.0);
    assert_eq!(s.take_play().map(|p| p.item_id), Some("t0".to_owned()));
    let mut p = PageScreen::new(env(), Cx::deterministic(), Kind::Person, Scenario::Ready);
    let mut now = 0.0;
    let _ = p.frame(0.0);
    p.open(0.0);
    let _ = settle!(p, now, 1200.0);
    let f = p.frame_of("bio-toggle").expect("Mehr");
    p.touch_down(f.x + 4.0, f.y + 4.0, now);
    p.touch_up(f.x + 4.0, f.y + 4.0, now + 30.0);
    let _ = settle!(p, now, 1600.0);
    assert!(
        p.frame_of("bio-toggle").is_some(),
        "the toggle is still there (Weniger)"
    );
}

#[test]
fn seerr_detail_offers_the_request_button() {
    let mut s = PageScreen::new(
        env(),
        Cx::deterministic(),
        Kind::SeerrDetail,
        Scenario::Ready,
    );
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let _ = settle!(s, now, 1200.0);
    assert!(
        s.frame_of("press").is_some(),
        "the request button is there for a requestable title"
    );
}

/// Layout-only render for `cargo xtask swiftui-parity`: pictures blank, written to `$PARITY_OUT` when it is set.
#[test]
fn detail_layout_only_render() {
    let mut s = DetailScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    s.blank_pictures();
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    let (list, _) = settle!(s, now, 1200.0);
    let img = s.render_software(&list);
    if let Some(dir) = std::env::var_os("PARITY_OUT") {
        img.write_png(&std::path::PathBuf::from(dir).join("detail_desktop_initial.png"))
            .unwrap();
    }
}
