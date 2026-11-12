//! Focus-plan tests: pure, no render. They drive the shared focus engine over hand-built maps and state the tvOS rules
//! (nearest in direction with overlap preference, remembered column, edges, tab bar to content and back, trapped
//! sheets, long press, keyboard). `cargo xtask check-all` runs them for every target that shares the engine.

use swiftly_ui::focus::{BackOutcome, Dir, Focus, FocusId, FocusMap, NavKey, Outcome, ScopeSpec};
use swiftly_ui::{Action, tuning};

fn id(s: &str) -> FocusId {
    FocusId::from(s)
}

/// Moves and returns the new focus, or `None` when the move failed.
fn go(f: &mut Focus, m: &FocusMap, d: Dir) -> Option<FocusId> {
    match f.move_dir(m, d) {
        Outcome::Moved { to, .. } => Some(to),
        Outcome::Failed(got) => {
            assert_eq!(got, d);
            None
        }
        other => panic!("unexpected {other:?}"),
    }
}

fn row(map: FocusMap, scope: Option<FocusId>, name: &str, y: f32, xs: &[(f32, f32)]) -> FocusMap {
    xs.iter().enumerate().fold(map, |m, (i, &(x, w))| {
        m.item(format!("{name}{i}").as_str(), scope, (x, y, w, 100.0))
    })
}

fn named(name: &str, i: usize) -> FocusId {
    id(&format!("{name}{i}"))
}

#[test]
fn poster_row_moves_by_one_and_stops_at_the_ends() {
    let xs: Vec<(f32, f32)> = (0..5).map(|i| (i as f32 * 240.0, 200.0)).collect();
    let m = row(FocusMap::new(), None, "p", 0.0, &xs);
    let mut f = Focus::new();
    f.sync(&m);
    assert_eq!(
        f.current(),
        Some(named("p", 0)),
        "first item without a default"
    );
    for i in 1..5 {
        assert_eq!(go(&mut f, &m, Dir::Right), Some(named("p", i)));
    }
    assert_eq!(
        go(&mut f, &m, Dir::Right),
        None,
        "no wrap past the last tile"
    );
    assert_eq!(
        f.current(),
        Some(named("p", 4)),
        "a failed move leaves focus where it was"
    );
    assert_eq!(go(&mut f, &m, Dir::Down), None);
    assert_eq!(go(&mut f, &m, Dir::Up), None);
    assert_eq!(go(&mut f, &m, Dir::Left), Some(named("p", 3)));
}

#[test]
fn the_default_item_gets_focus_first() {
    let mut m = FocusMap::new();
    for (i, x) in [0.0, 240.0, 480.0].into_iter().enumerate() {
        let mut it = swiftly_ui::focus::Item::new(
            format!("d{i}").as_str(),
            swiftly_layout::Rect::new(x, 0.0, 200.0, 100.0),
        );
        it.default = i == 1;
        m.add_item(it);
    }
    let mut f = Focus::new();
    f.sync(&m);
    assert_eq!(f.current(), Some(named("d", 1)));
}

#[test]
fn rail_stack_keeps_the_column_through_rows_of_other_widths() {
    // Rail A: four tiles; rail B: one wide tile right of the middle; rail C: six tiles.
    let a: Vec<(f32, f32)> = (0..4).map(|i| (i as f32 * 150.0, 100.0)).collect();
    let c: Vec<(f32, f32)> = (0..6).map(|i| (i as f32 * 150.0, 100.0)).collect();
    let mut m = FocusMap::new()
        .scope(ScopeSpec::section("A"), None)
        .scope(ScopeSpec::section("B"), None)
        .scope(ScopeSpec::section("C"), None);
    m = row(m, Some(id("A")), "a", 0.0, &a);
    m = row(m, Some(id("B")), "b", 140.0, &[(420.0, 400.0)]);
    m = row(m, Some(id("C")), "c", 280.0, &c);
    let mut f = Focus::new();
    f.set(&m, named("a", 3));
    assert_eq!(go(&mut f, &m, Dir::Down), Some(named("b", 0)));
    // From the wide tile (centre 620) the nearest tile of C would be c4; the remembered column 500 gives c3.
    assert_eq!(go(&mut f, &m, Dir::Down), Some(named("c", 3)));
    assert_eq!(go(&mut f, &m, Dir::Up), Some(named("b", 0)));
    assert_eq!(go(&mut f, &m, Dir::Up), Some(named("a", 3)));
    // A sideways move sets a new column; a row with nothing in that column is skipped, as on tvOS.
    assert_eq!(go(&mut f, &m, Dir::Left), Some(named("a", 2)));
    assert_eq!(go(&mut f, &m, Dir::Down), Some(named("c", 2)));
    assert_eq!(go(&mut f, &m, Dir::Up), Some(named("a", 2)));
}

#[test]
fn an_overlapping_item_beats_a_nearer_one_that_only_touches_the_corner() {
    // Focus on the left; a small item right-below (corner) and a tall one right (overlapping) at a larger gap.
    let m = FocusMap::new()
        .item("me", None, (0.0, 0.0, 100.0, 100.0))
        .item("corner", None, (110.0, 120.0, 40.0, 40.0))
        .item("side", None, (160.0, 0.0, 100.0, 100.0));
    let mut f = Focus::new();
    f.set(&m, id("me"));
    assert_eq!(go(&mut f, &m, Dir::Right), Some(id("side")));
}

#[test]
fn grid_moves_in_four_directions_and_lands_on_the_nearest_in_a_short_last_row() {
    // 4 columns x 3 rows; the last row has only two items.
    let mut m = FocusMap::new();
    for r in 0..3 {
        for c in 0..4 {
            if r == 2 && c >= 2 {
                continue;
            }
            m = m.item(
                format!("g{r}{c}").as_str(),
                None,
                (c as f32 * 120.0, r as f32 * 160.0, 100.0, 140.0),
            );
        }
    }
    let g = |r: usize, c: usize| id(&format!("g{r}{c}"));
    let mut f = Focus::new();
    f.set(&m, g(0, 3));
    assert_eq!(go(&mut f, &m, Dir::Down), Some(g(1, 3)));
    assert_eq!(
        go(&mut f, &m, Dir::Down),
        Some(g(2, 1)),
        "no item below: the nearest of the short row"
    );
    assert_eq!(
        go(&mut f, &m, Dir::Up),
        Some(g(1, 3)),
        "the column comes back"
    );
    assert_eq!(go(&mut f, &m, Dir::Right), None, "right edge");
    assert_eq!(go(&mut f, &m, Dir::Left), Some(g(1, 2)));
    assert_eq!(go(&mut f, &m, Dir::Up), Some(g(0, 2)));
    assert_eq!(go(&mut f, &m, Dir::Up), None, "top edge");
}

fn bar_and_content() -> FocusMap {
    // Tab bar on top (three tabs), content below: two rails of five tiles.
    let mut m = FocusMap::new()
        .scope(ScopeSpec::bar("bar"), None)
        .scope(ScopeSpec::section("content").remembering(), None)
        .scope(ScopeSpec::section("r0"), Some(id("content")))
        .scope(ScopeSpec::section("r1"), Some(id("content")));
    m = row(
        m,
        Some(id("bar")),
        "tab",
        0.0,
        &[(400.0, 150.0), (560.0, 150.0), (720.0, 150.0)],
    );
    let tiles: Vec<(f32, f32)> = (0..5).map(|i| (i as f32 * 240.0, 200.0)).collect();
    m = row(m, Some(id("r0")), "t", 200.0, &tiles);
    row(m, Some(id("r1")), "u", 400.0, &tiles)
}

#[test]
fn tab_bar_to_content_and_back_remembers_both_sides() {
    let m = bar_and_content();
    let mut f = Focus::new();
    f.set(&m, named("tab", 0));
    assert_eq!(go(&mut f, &m, Dir::Right), Some(named("tab", 1)));
    // Down from tab 1: no memory in the content yet, so the nearest tile.
    let first = go(&mut f, &m, Dir::Down).expect("content below the bar");
    assert_eq!(
        first,
        named("t", 2),
        "tab 1 sits above the tile that overlaps it most"
    );
    assert_eq!(go(&mut f, &m, Dir::Right), Some(named("t", 3)));
    assert_eq!(go(&mut f, &m, Dir::Right), Some(named("t", 4)));
    assert_eq!(go(&mut f, &m, Dir::Down), Some(named("u", 4)));
    // Up out of the content: the tab bar remembers tab 1, although tab 2 is nearer to tile 4's column.
    assert_eq!(go(&mut f, &m, Dir::Up), Some(named("t", 4)));
    assert_eq!(go(&mut f, &m, Dir::Up), Some(named("tab", 1)));
    // Down again: the content hands focus back to where it was, not to the nearest tile.
    assert_eq!(go(&mut f, &m, Dir::Down), Some(named("t", 4)));
    // Back from content goes to the bar first (Menu), then pops.
    assert_eq!(
        f.back(&m),
        Outcome::Back(BackOutcome::ToBar(named("tab", 1)))
    );
    assert_eq!(f.current(), Some(named("tab", 1)));
    assert_eq!(f.back(&m), Outcome::Back(BackOutcome::Pop));
}

fn with_sheet(open: bool) -> FocusMap {
    let mut m = FocusMap::new().scope(ScopeSpec::section("page"), None);
    m = row(
        m,
        Some(id("page")),
        "bg",
        0.0,
        &[(0.0, 200.0), (240.0, 200.0), (480.0, 200.0)],
    );
    if open {
        m = m.scope(ScopeSpec::trap("sheet"), None);
        m = m.item("ok", Some(id("sheet")), (100.0, 300.0, 200.0, 80.0));
        m = m.item("cancel", Some(id("sheet")), (340.0, 300.0, 200.0, 80.0));
    }
    m
}

#[test]
fn a_sheet_traps_focus_and_returns_it_to_the_opener() {
    let closed = with_sheet(false);
    let mut f = Focus::new();
    f.set(&closed, named("bg", 1));
    let open = with_sheet(true);
    f.sync(&open);
    assert_eq!(f.current(), Some(id("ok")), "focus moves into the sheet");
    // The background tiles lie above the sheet's buttons but cannot be reached.
    assert_eq!(go(&mut f, &open, Dir::Up), None);
    assert_eq!(go(&mut f, &open, Dir::Right), Some(id("cancel")));
    assert_eq!(go(&mut f, &open, Dir::Right), None);
    assert_eq!(go(&mut f, &open, Dir::Down), None);
    // Tab stays inside and wraps.
    assert_eq!(
        f.tab(&open, false),
        Outcome::Moved {
            from: id("cancel"),
            to: id("ok")
        }
    );
    // Back asks the app to close the sheet.
    assert_eq!(
        f.back(&open),
        Outcome::Back(BackOutcome::CloseTrap(id("sheet")))
    );
    f.sync(&closed);
    assert_eq!(
        f.current(),
        Some(named("bg", 1)),
        "focus returns to the tile that opened the sheet"
    );
}

#[test]
fn a_remembering_trap_reopens_on_its_last_item() {
    let closed = with_sheet(false);
    let open = with_sheet(true);
    let mut f = Focus::new();
    f.set(&closed, named("bg", 0));
    f.sync(&open);
    assert_eq!(go(&mut f, &open, Dir::Right), Some(id("cancel")));
    f.sync(&closed);
    f.sync(&open);
    assert_eq!(f.current(), Some(id("cancel")));
}

#[test]
fn a_removed_focused_item_falls_back_to_the_first() {
    let m = row(
        FocusMap::new(),
        None,
        "x",
        0.0,
        &[(0.0, 100.0), (150.0, 100.0)],
    );
    let mut f = Focus::new();
    f.set(&m, named("x", 1));
    let smaller = row(FocusMap::new(), None, "x", 0.0, &[(0.0, 100.0)]);
    f.sync(&smaller);
    assert_eq!(f.current(), Some(named("x", 0)));
}

#[test]
fn wrapping_scopes_wrap_and_others_do_not() {
    let xs = [(0.0, 100.0), (150.0, 100.0), (300.0, 100.0)];
    let m = row(
        FocusMap::new().scope(ScopeSpec::section("w").wrapping(), None),
        Some(id("w")),
        "w",
        0.0,
        &xs,
    );
    let mut f = Focus::new();
    f.set(&m, named("w", 2));
    assert_eq!(go(&mut f, &m, Dir::Right), Some(named("w", 0)));
    assert_eq!(go(&mut f, &m, Dir::Left), Some(named("w", 2)));
}

#[test]
fn tab_walks_in_tree_order_and_wraps() {
    let m = row(
        FocusMap::new(),
        None,
        "k",
        0.0,
        &[(0.0, 100.0), (150.0, 100.0), (300.0, 100.0)],
    );
    let mut f = Focus::new();
    f.sync(&m);
    let mut seen = vec![];
    for _ in 0..4 {
        f.key(&m, NavKey::Tab, true, 0.0);
        seen.push(f.current());
    }
    assert_eq!(seen, [1, 2, 0, 1].map(|i| Some(named("k", i))));
    f.key(&m, NavKey::ShiftTab, true, 0.0);
    assert_eq!(f.current(), Some(named("k", 0)));
}

#[test]
fn keyboard_keys_map_onto_the_same_moves() {
    let m = row(
        FocusMap::new(),
        None,
        "k",
        0.0,
        &[(0.0, 100.0), (150.0, 100.0)],
    );
    let mut f = Focus::new();
    f.sync(&m);
    assert!(matches!(
        f.key(&m, NavKey::Arrow(Dir::Right), true, 0.0),
        Outcome::Moved { .. }
    ));
    assert_eq!(
        f.key(&m, NavKey::Arrow(Dir::Right), false, 0.0),
        Outcome::None,
        "key up does nothing"
    );
    assert_eq!(
        f.key(&m, NavKey::Arrow(Dir::Right), true, 0.0),
        Outcome::Failed(Dir::Right)
    );
    assert_eq!(
        f.key(&m, NavKey::Escape, true, 0.0),
        Outcome::Back(BackOutcome::Pop)
    );
}

#[test]
fn a_short_press_activates_and_a_long_press_fires_once() {
    let mut m = FocusMap::new();
    let mut it =
        swiftly_ui::focus::Item::new("tile", swiftly_layout::Rect::new(0.0, 0.0, 100.0, 100.0));
    it.tap = Some(Action::from("open"));
    it.long = Some(Action::from("menu"));
    m.add_item(it);
    let mut f = Focus::new();
    f.sync(&m);
    // Short.
    f.key(&m, NavKey::Enter, true, 0.0);
    assert_eq!(f.tick(&m, tuning::LONG_PRESS_MS - 1.0), Outcome::None);
    assert_eq!(
        f.key(&m, NavKey::Enter, false, tuning::LONG_PRESS_MS - 1.0),
        Outcome::Activated(id("tile"), Some(Action::from("open")))
    );
    // Long: fires at the threshold, once, and the release does not also activate.
    f.key(&m, NavKey::Enter, true, 1000.0);
    assert_eq!(
        f.tick(&m, 1000.0 + tuning::LONG_PRESS_MS),
        Outcome::LongPressed(id("tile"), Some(Action::from("menu")))
    );
    assert_eq!(f.tick(&m, 3000.0), Outcome::None);
    assert_eq!(f.key(&m, NavKey::Enter, false, 3000.0), Outcome::None);
}

#[test]
fn without_a_long_action_a_long_press_still_activates_on_release() {
    let mut m = FocusMap::new();
    let mut it =
        swiftly_ui::focus::Item::new("b", swiftly_layout::Rect::new(0.0, 0.0, 100.0, 100.0));
    it.tap = Some(Action::from("go"));
    m.add_item(it);
    let mut f = Focus::new();
    f.sync(&m);
    f.key(&m, NavKey::Enter, true, 0.0);
    assert_eq!(f.tick(&m, 900.0), Outcome::None);
    assert_eq!(
        f.key(&m, NavKey::Enter, false, 900.0),
        Outcome::Activated(id("b"), Some(Action::from("go")))
    );
}
