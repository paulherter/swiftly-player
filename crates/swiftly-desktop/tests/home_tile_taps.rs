//! Only the Continue Watching row plays on a tap (the Mac's `continueWatchingRow`); every other tile opens its page,
//! also when the same title sits in the Continue Watching row as well (a film with a resume position that was just added).
#![allow(clippy::unwrap_used)]

use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::RailKind;

const STEP: f64 = 1000.0 / 60.0;

fn tap_tile(s: &mut HomeScreen, now: &mut f64, rail: &str, i: usize) {
    let f = s
        .frame_of(&format!("{rail}:{i}"))
        .unwrap_or_else(|| panic!("no tile {rail}:{i} on the page"));
    let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
    s.touch_down(x, y, *now);
    *now += 40.0;
    s.touch_up(x, y, *now);
    *now += STEP;
    let _ = s.frame(*now);
}

fn home() -> (HomeScreen, f64) {
    // Tall enough for every rail to be on screen.
    let env = Env::new(Size::new(1280.0, 3200.0), 1.0, Idiom::Desktop);
    let mut s = HomeScreen::new(env, Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    while now < 600.0 {
        now += STEP;
        let _ = s.frame(now);
    }
    (s, now)
}

#[test]
fn a_recently_added_tile_with_a_resume_position_only_opens_its_page() {
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
    tap_tile(&mut s, &mut now, &rail, i);
    assert!(
        s.take_resumed().is_empty(),
        "the tile of {id} in row {rail} played"
    );
    assert_eq!(s.opened(), [id], "it opens its page");
}

#[test]
fn a_continue_watching_tile_resumes_and_opens_no_page() {
    let (mut s, mut now) = home();
    let rails = s.vm().rails().rails.clone();
    let rail = rails
        .iter()
        .find(|r| r.kind == RailKind::ContinueWatching)
        .expect("the Continue Watching row");
    let id = rail.tiles[0].id.clone();
    tap_tile(&mut s, &mut now, &rail.id, 0);
    assert_eq!(s.take_resumed(), vec![id]);
    assert!(s.opened().is_empty(), "no page opens beside the play");
}
