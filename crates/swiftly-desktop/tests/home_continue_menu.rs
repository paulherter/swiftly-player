//! Right click on a "Weiterschauen" tile opens the tile menu of the Mac (`TileMenuMac.swift`), "Aus Weiterschauen
//! entfernen" included; the same title in another row gets no such entry (the action says which row was clicked).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_ui::popover::MenuKey;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::RailKind;

const STEP: f64 = 1000.0 / 60.0;

fn home() -> (HomeScreen, f64) {
    let env = Env::new(Size::new(1280.0, 3200.0), 1.0, Idiom::Desktop);
    let mut s = HomeScreen::new(env, Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    while now < 600.0 {
        now += STEP;
        let _ = s.frame(now);
    }
    (s, now)
}

fn right_click(s: &mut HomeScreen, now: &mut f64, rail: &str, i: usize) -> bool {
    let f = s
        .frame_of(&format!("{rail}:{i}"))
        .unwrap_or_else(|| panic!("no tile {rail}:{i} on the page"));
    let hit = s.secondary_click(f[0] + f[2] / 2.0, f[1] + f[3] / 2.0, *now);
    *now += STEP;
    let _ = s.frame(*now);
    hit
}

fn continue_rail(s: &HomeScreen) -> (String, String) {
    let rails = s.vm().rails().rails.clone();
    let rail = rails
        .iter()
        .find(|r| r.kind == RailKind::ContinueWatching)
        .expect("the Continue Watching row");
    (rail.id.clone(), rail.tiles[0].id.clone())
}

#[test]
fn a_right_click_on_a_continue_tile_opens_the_menu() {
    let (mut s, mut now) = home();
    let (rail, _) = continue_rail(&s);
    assert!(
        right_click(&mut s, &mut now, &rail, 0),
        "the right click finds the tile"
    );
    assert!(s.menu_open(), "the tile menu is open");
}

#[test]
fn the_continue_menu_removes_the_title_from_the_row() {
    let (mut s, mut now) = home();
    let (rail, id) = continue_rail(&s);
    assert!(right_click(&mut s, &mut now, &rail, 0));
    assert!(s.menu_open());
    // "Aus Weiterschauen entfernen" is the last row of the menu; the core takes the title out of the row at once.
    now += STEP;
    s.menu_key(MenuKey::End, now);
    now += STEP;
    s.menu_key(MenuKey::Enter, now);
    assert!(!s.menu_open());
    let still_there = |s: &HomeScreen| {
        s.vm()
            .rails()
            .rails
            .iter()
            .filter(|r| r.kind == RailKind::ContinueWatching)
            .any(|r| r.tiles.iter().any(|t| t.id == id))
    };
    let began = std::time::Instant::now();
    while still_there(&s) && began.elapsed() < std::time::Duration::from_secs(5) {
        now += STEP;
        let _ = s.frame(now);
    }
    assert!(!still_there(&s), "the title left the Continue Watching row");
}

#[test]
fn the_same_title_in_another_row_has_no_remove_entry() {
    let (mut s, mut now) = home();
    let rails = s.vm().rails().rails.clone();
    let resumable: Vec<&str> = rails
        .iter()
        .filter(|r| r.kind == RailKind::ContinueWatching)
        .flat_map(|r| r.tiles.iter().map(|t| t.id.as_str()))
        .collect();
    let (rail, i, id) = rails
        .iter()
        .filter(|r| r.kind != RailKind::ContinueWatching)
        .find_map(|r| {
            r.tiles
                .iter()
                .position(|t| resumable.contains(&t.id.as_str()))
                .map(|i| (r.id.clone(), i, r.tiles[i].id.clone()))
        })
        .expect("a title that is in the Continue Watching row and in another row");
    assert!(right_click(&mut s, &mut now, &rail, i));
    assert!(s.menu_open());
    now += STEP;
    s.menu_key(MenuKey::End, now);
    now += STEP;
    s.menu_key(MenuKey::Enter, now);
    assert!(
        !s.take_requests().contains(&format!("Remove:{id}")),
        "the last row of this menu is not a remove"
    );
}
