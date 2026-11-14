//! The right-click menu of a search result carries "Gemeinsam schauen" and "Abspielen auf ..." to the host as
//! `TileRequest`s, like the tile menus of the pages and rails (`pump_tile_requests` in the suite).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::browse::Scenario;
use swiftly_desktop::home::Form;
use swiftly_desktop::search_screen::SearchScreen;
use swiftly_desktop::tile_menu::{Entry, demo_cx, entries};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};
use swiftly_vm::TileRequest;

fn open_menu() -> (SearchScreen, String, Vec<Entry>, f64) {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = SearchScreen::new(env, Cx::deterministic(), Scenario::Ready, &[]);
    let mut now = 0.0;
    for _ in 0..10 {
        now += 16.0;
        let _ = s.frame(now);
    }
    s.type_text("Nord");
    std::thread::sleep(std::time::Duration::from_millis(50));
    SearchScreen::settle(s.vm());
    for _ in 0..20 {
        now += 16.0;
        let _ = s.frame(now);
    }
    // The first title that is not a series (a series has neither entry): its place in the result order names its node.
    let (at, tile) = s
        .vm()
        .results()
        .groups
        .iter()
        .flat_map(|g| g.tiles.iter())
        .enumerate()
        .find(|(_, t)| {
            !t.facts
                .kind
                .as_deref()
                .is_some_and(|k| k.eq_ignore_ascii_case("series"))
        })
        .map(|(i, t)| (i, t.clone()))
        .expect("a result that is not a series");
    let [x, y, w, h] = s
        .frame_of(&format!("h:{at}"))
        .expect("the tile is on the page");
    assert!(
        s.secondary_click(x + w / 2.0, y + h / 2.0, now),
        "right click hits the tile"
    );
    let _ = s.frame(now + 16.0);
    assert!(s.menu_open());
    let list = entries(Form::Desktop, &demo_cx(false), Some(&tile));
    (s, tile.id, list, now + 32.0)
}

fn key(s: &mut SearchScreen, k: NavKey, now: &mut f64) {
    *now += 16.0;
    s.nav_key(k, true, *now);
    let _ = s.frame(*now);
}

fn choose(s: &mut SearchScreen, row: usize, now: &mut f64) {
    for _ in 0..=row {
        key(s, NavKey::Arrow(Dir::Down), now);
    }
    key(s, NavKey::Enter, now);
}

#[test]
fn together_goes_to_the_host() {
    let (mut s, id, list, mut now) = open_menu();
    let row = list
        .iter()
        .position(|e| *e == Entry::Together)
        .expect("the entry is offered");
    choose(&mut s, row, &mut now);
    assert_eq!(s.take_requests(), vec![TileRequest::Together { id }]);
    assert!(!s.menu_open());
}

#[test]
fn play_on_opens_the_devices_and_sends_the_pick() {
    let (mut s, id, list, mut now) = open_menu();
    let row = list
        .iter()
        .position(|e| *e == Entry::PlayOn)
        .expect("the entry is offered");
    choose(&mut s, row, &mut now);
    assert!(s.menu_open(), "the device list is up");
    assert!(s.take_requests().is_empty());
    choose(&mut s, 0, &mut now);
    assert_eq!(
        s.take_requests(),
        vec![TileRequest::PlayOn {
            id,
            device: "tv-1".into()
        }]
    );
}
