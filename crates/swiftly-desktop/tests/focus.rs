//! The shared focus engine inside the `Ui`: keys move focus over real laid-out tiles, the lift is a spring, the tile
//! scrolls into view, Enter and long Enter reach the app as the same events a tap and a long press give.

use swiftly_desktop::focus_scene::{self, button_id, tile_id};
use swiftly_layout::Size;
use swiftly_ui::{Action, BackOutcome, Cx, Dir, Env, Idiom, NavKey, Outcome, Ui, UiEvent, tuning};

fn tv() -> Ui<()> {
    focus_scene::ui(
        Env::new(Size::new(1920.0, 1080.0), 1.0, Idiom::Tv),
        Cx::deterministic(),
    )
}

fn press(ui: &mut Ui<()>, k: NavKey, t: f64) -> Outcome {
    ui.nav_key(k, true, t)
}

#[test]
fn tv_starts_with_the_default_button_focused_and_visible() {
    let ui = tv();
    assert!(ui.focus_visible());
    assert_eq!(ui.focused(), Some(button_id(0)));
}

#[test]
fn arrows_move_over_the_laid_out_scene() {
    let mut ui = tv();
    assert!(matches!(
        press(&mut ui, NavKey::Arrow(Dir::Right), 0.0),
        Outcome::Moved { .. }
    ));
    assert_eq!(ui.focused(), Some(button_id(1)));
    press(&mut ui, NavKey::Arrow(Dir::Left), 5.0);
    press(&mut ui, NavKey::Arrow(Dir::Down), 10.0);
    assert_eq!(
        ui.focused(),
        Some(tile_id(0, 0)),
        "the tile under the buttons"
    );
    for i in 1..6 {
        press(&mut ui, NavKey::Arrow(Dir::Right), 20.0);
        assert_eq!(ui.focused(), Some(tile_id(0, i)));
    }
    press(&mut ui, NavKey::Arrow(Dir::Down), 30.0);
    assert_eq!(
        ui.focused(),
        Some(tile_id(1, 5)),
        "the same column in the next rail"
    );
    press(&mut ui, NavKey::Arrow(Dir::Up), 40.0);
    assert_eq!(ui.focused(), Some(tile_id(0, 5)), "back in the first rail");
    press(&mut ui, NavKey::Arrow(Dir::Up), 50.0);
    assert!(
        [button_id(0), button_id(1), button_id(2)].contains(&ui.focused().unwrap_or(tile_id(9, 9))),
        "up from the first rail lands on a button"
    );
    assert_eq!(
        press(&mut ui, NavKey::Arrow(Dir::Up), 60.0),
        Outcome::Failed(Dir::Up),
        "top edge"
    );
}

#[test]
fn the_rail_follows_focus_so_the_tile_is_always_on_screen() {
    let mut ui = tv();
    press(&mut ui, NavKey::Arrow(Dir::Down), 0.0);
    for i in 1..30 {
        press(
            &mut ui,
            NavKey::Arrow(Dir::Right),
            f64::from(i as u32) * 120.0,
        );
        let _ = ui.frame(f64::from(i as u32) * 120.0);
        assert_eq!(
            ui.focused(),
            Some(tile_id(0, i)),
            "tile {i} exists and takes focus"
        );
    }
    let _ = ui.frame(120.0 * 30.0 + tuning::FOCUS_SCROLL_SECONDS * 1000.0 + 50.0);
    let off = ui.scroll_offsets();
    assert!(
        off.iter().any(|o| *o > 1000.0),
        "the rail scrolled: {off:?}"
    );
}

#[test]
fn the_lift_is_the_swift_ease_out_of_014_seconds_without_overshoot() {
    let mut ui = tv();
    press(&mut ui, NavKey::Arrow(Dir::Down), 0.0);
    let id = tile_id(0, 0);
    let _ = ui.frame(70.0);
    let half = ui.focus_amount(id).unwrap_or(0.0);
    assert!(
        half > 0.5 && half < 0.95,
        "ease-out is past half way at half the time, got {half}"
    );
    let mut last = half;
    let mut t = 70.0;
    while t < 1000.0 {
        t += 1000.0 / 120.0;
        let _ = ui.frame(t);
        let v = ui.focus_amount(id).unwrap_or(0.0);
        assert!(
            v >= last - 1e-9 && v <= 1.0 + 1e-9,
            "monotonic, no overshoot: {v}"
        );
        last = v;
    }
    assert!((last - 1.0).abs() < 1e-9);
    assert!(!ui.needs_frame(), "settled: no more frames");
    assert!(
        ui.focus_amount(button_id(0)).unwrap_or(1.0) < 1e-9,
        "the old button let go"
    );
}

#[test]
fn reduce_motion_makes_the_lift_linear_and_short() {
    let mut env = Env::new(Size::new(1920.0, 1080.0), 1.0, Idiom::Tv);
    env.reduce_motion = true;
    let mut ui = focus_scene::ui(env, Cx::deterministic());
    let _ = ui.frame(500.0);
    press(&mut ui, NavKey::Arrow(Dir::Down), 1000.0);
    let id = tile_id(0, 0);
    let _ = ui.frame(1000.0 + tuning::FOCUS_REDUCE_SECONDS * 500.0);
    let half = ui.focus_amount(id).unwrap_or(0.0);
    assert!(
        (half - 0.5).abs() < 0.1,
        "linear: half way at half the time, got {half}"
    );
    let _ = ui.frame(1000.0 + tuning::FOCUS_REDUCE_SECONDS * 1000.0 + 10.0);
    assert!((ui.focus_amount(id).unwrap_or(0.0) - 1.0).abs() < 1e-6);
}

#[test]
fn enter_is_a_tap_and_a_held_enter_is_a_long_press() {
    let mut ui = tv();
    press(&mut ui, NavKey::Arrow(Dir::Down), 0.0);
    let _ = ui.take_events();
    ui.nav_key(NavKey::Enter, true, 100.0);
    ui.nav_key(NavKey::Enter, false, 150.0);
    assert_eq!(
        ui.take_events(),
        vec![UiEvent::Tap(Action::from("open0-0"))]
    );
    ui.nav_key(NavKey::Enter, true, 1000.0);
    let _ = ui.frame(1000.0 + tuning::LONG_PRESS_MS + 1.0);
    ui.nav_key(NavKey::Enter, false, 1700.0);
    assert_eq!(
        ui.take_events(),
        vec![UiEvent::LongPress(Action::from("menu0-0"))]
    );
}

#[test]
fn desktop_shows_focus_on_the_first_key_and_hides_it_on_touch() {
    let mut ui = focus_scene::ui(
        Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop),
        Cx::deterministic(),
    );
    assert!(!ui.focus_visible());
    assert_eq!(
        press(&mut ui, NavKey::Arrow(Dir::Right), 0.0),
        Outcome::Shown(button_id(0))
    );
    assert_eq!(
        ui.focused(),
        Some(button_id(0)),
        "the first key only shows focus"
    );
    assert!(matches!(
        press(&mut ui, NavKey::Arrow(Dir::Right), 10.0),
        Outcome::Moved { .. }
    ));
    ui.touch_down(5.0, 5.0, 20.0);
    assert!(!ui.focus_visible(), "a click hides the ring");
    ui.touch_cancel(30.0);
}

#[test]
fn escape_walks_back_out_of_the_screen() {
    let mut ui = tv();
    press(&mut ui, NavKey::Arrow(Dir::Down), 0.0);
    assert_eq!(
        press(&mut ui, NavKey::Escape, 10.0),
        Outcome::Back(BackOutcome::Pop)
    );
}
