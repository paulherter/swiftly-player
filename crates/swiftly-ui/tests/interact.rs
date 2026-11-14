//! Pointer interaction of the engine: hover, the three press styles, secondary click, cursor, tooltip, disabled and selected,
//! wheel and keyboard scrolling, popover menus. Numbers are the Mac's (`swiftly_ui::feel`); goldens are written on first run
//! (`UPDATE_GOLDENS=1` rewrites them).

mod common;

use common::check_golden;
use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets, Point, Rect};
use swiftly_render::{Color, QuadKind};
use swiftly_ui::components::color;
use swiftly_ui::popover::{
    Anchor, DISMISS, MenuController, MenuEntry, MenuItem, MenuKey, MenuOutcome,
};
use swiftly_ui::shortcuts::ScrollKey;
use swiftly_ui::{Action, Cursor, Cx, Env, Idiom, Node, PressStyle, Ui, UiEvent};

const CLEAR: Color = Color {
    r: 0.0627451,
    g: 0.0627451,
    b: 0.0627451,
    a: 1.0,
};

#[derive(Clone, PartialEq)]
struct Scene {
    menu: MenuController,
}

fn block(w: f32, h: f32, fill: Option<Color>) -> Node {
    match fill {
        Some(c) => Node::rect(c, 10.0).frame(Some(w), Some(h), Alignment::TOP_LEADING),
        None => Node::flexible().frame(Some(w), Some(h), Alignment::TOP_LEADING),
    }
}

fn view(scene: &Scene, env: &Env, cx: &Cx) -> Node {
    let raised = color(colour::RAISED);
    let tall = Node::vstack(
        Align::Start,
        Some(0.0),
        vec![Node::rect(Color::new(0.2, 0.3, 0.5, 1.0), 0.0).frame(
            Some(300.0),
            Some(1000.0),
            Alignment::TOP_LEADING,
        )],
    );
    // Rows never overlap, so the layout is the hit map: padding 20, rows 16 apart.
    let row = |items: Vec<Node>| Node::hstack(Align::Start, Some(20.0), items);
    let items = vec![
        row(vec![
            block(120.0, 80.0, Some(raised))
                .hover_scale(1.04)
                .on_hover("tile-hover")
                .on_hover_rest("tile-rest")
                .on_tap("tile")
                .key("tile"),
            block(300.0, 44.0, None)
                .hover_area()
                .press_style(PressStyle::Row)
                .on_tap("row")
                .key("row"),
        ]),
        row(vec![
            block(120.0, 44.0, Some(raised))
                .on_tap("button")
                .key("button"),
            block(80.0, 30.0, Some(raised))
                .on_tap("text")
                .press_style(PressStyle::Text)
                .key("text"),
            block(120.0, 44.0, Some(raised))
                .on_tap("off")
                .hover_scale(1.04)
                .disabled(true)
                .key("off"),
        ]),
        row(vec![
            block(200.0, 30.0, Some(raised))
                .cursor(Cursor::Text)
                .key("field"),
            block(44.0, 44.0, Some(raised))
                .tooltip("Abspielen")
                .key("tip"),
            block(100.0, 44.0, Some(raised))
                .on_secondary("ctx")
                .key("sec"),
            block(100.0, 44.0, None)
                .hover_area()
                .selected(true)
                .key("sel"),
        ]),
        Node::scroll(Axis::Vertical, None, tall)
            .frame(Some(300.0), Some(150.0), Alignment::TOP_LEADING)
            .key("scroll"),
    ];
    let page = Node::vstack(Align::Start, Some(16.0), items).padding(EdgeInsets {
        top: 20.0,
        leading: 20.0,
        bottom: 20.0,
        trailing: 20.0,
    });
    let mut layers = vec![page];
    if let Some(o) = scene.menu.overlay(cx, env) {
        layers.push(o);
    }
    Node::zstack(Alignment::TOP_LEADING, layers).frame(
        Some(env.size.w),
        Some(env.size.h),
        Alignment::TOP_LEADING,
    )
}

fn ui_sized(w: f32, h: f32, reduce: bool) -> Ui<Scene> {
    let mut env = Env::new(swiftly_layout::Size::new(w, h), 1.0, Idiom::Desktop);
    env.reduce_motion = reduce;
    Ui::new(
        view,
        Scene {
            menu: MenuController::new(),
        },
        env,
        Cx::deterministic(),
    )
}

fn ui() -> Ui<Scene> {
    ui_sized(640.0, 420.0, false)
}

fn run(u: &mut Ui<Scene>, from: f64, to: f64) {
    let mut t = from;
    while t < to {
        t += 8.0;
        let _ = u.frame(t.min(to));
    }
}

fn px(u: &mut Ui<Scene>, t: f64, x: usize, y: usize) -> u8 {
    let list = u.frame(t);
    u.render(&list, CLEAR).pixel(x, y)[0]
}

fn menu_entries() -> Vec<MenuEntry> {
    vec![
        MenuEntry::Item(MenuItem::new("play", "Abspielen").shortcut("Enter")),
        MenuEntry::Item(MenuItem::new("info", "Info").shortcut("Ctrl+I")),
        MenuEntry::Item(
            MenuItem::new("later", "Merken")
                .shortcut("Ctrl+D")
                .checked(true),
        ),
        MenuEntry::Separator,
        MenuEntry::Item(MenuItem::new("del", "Aus Weiterschauen entfernen").destructive()),
    ]
}

#[test]
fn a_hovered_tile_grows_to_1_04_in_120_ms_ease_out_and_returns() {
    let mut u = ui();
    let _ = u.frame(0.0);
    u.pointer_move(50.0, 50.0, 0.0);
    let _ = u.frame(0.0);
    let _ = u.frame(30.0);
    let early = u.node_values("tile").unwrap().scale;
    assert!(early > 1.0 && early < 1.04, "moving: {early}");
    assert!(
        early > 1.0 + 0.04 * 0.3,
        "ease-out is ahead of linear at 30 ms: {early}"
    );
    let _ = u.frame(130.0);
    assert!((u.node_values("tile").unwrap().scale - 1.04).abs() < 1e-6);
    u.pointer_leave(200.0);
    let _ = u.frame(200.0);
    let _ = u.frame(330.0);
    assert!((u.node_values("tile").unwrap().scale - 1.0).abs() < 1e-6);
    assert!(!u.needs_frame(), "idle again");
}

#[test]
fn reduce_motion_makes_hover_linear_014() {
    let mut u = ui_sized(640.0, 420.0, true);
    let _ = u.frame(0.0);
    u.pointer_move(50.0, 50.0, 0.0);
    let _ = u.frame(70.0);
    let mid = u.node_values("tile").unwrap().scale;
    assert!((mid - 1.02).abs() < 1e-3, "half of 0.14 s: {mid}");
}

#[test]
fn the_hover_surface_is_white_6_percent_and_follows_the_pointer() {
    let mut u = ui();
    let rest = px(&mut u, 0.0, 170, 25);
    assert_eq!(rest, 16, "ground #101010");
    u.pointer_move(200.0, 40.0, 10.0);
    let on = px(&mut u, 300.0, 170, 25);
    assert!((29..=32).contains(&on), "16 + 239 x 0.06 = 30: {on}");
    u.pointer_leave(400.0);
    assert_eq!(px(&mut u, 700.0, 170, 25), 16);
}

#[test]
fn the_three_press_styles() {
    let mut u = ui();
    let _ = u.frame(0.0);
    // PressButton: 0.97 and 0.85 at once, released over 0.12 s.
    u.touch_down(60.0, 130.0, 10.0);
    let _ = u.frame(10.0);
    let v = u.node_values("button").unwrap();
    assert!((v.scale - 0.97).abs() < 1e-9 && (v.opacity - 0.85).abs() < 1e-9 && v.pressed);
    u.touch_up(60.0, 130.0, 60.0);
    assert_eq!(u.take_events(), vec![UiEvent::Tap(Action::from("button"))]);
    let _ = u.frame(60.0);
    let _ = u.frame(190.0);
    let v = u.node_values("button").unwrap();
    assert!((v.scale - 1.0).abs() < 1e-9 && (v.opacity - 1.0).abs() < 1e-9);
    // PressText: opacity 0.6, no scale.
    u.touch_down(180.0, 125.0, 300.0);
    let _ = u.frame(300.0);
    let v = u.node_values("text").unwrap();
    assert!((v.scale - 1.0).abs() < 1e-9 && (v.opacity - 0.6).abs() < 1e-9);
    u.touch_up(180.0, 125.0, 320.0);
    let _ = u.take_events();
    // PressRow: the white 6 % surface, no scale and no opacity change.
    let _ = u.frame(500.0);
    u.touch_down(170.0, 25.0, 600.0);
    let on = px(&mut u, 600.0, 170, 25);
    assert!((29..=32).contains(&on), "{on}");
    let v = u.node_values("row").unwrap();
    assert!((v.scale - 1.0).abs() < 1e-9 && (v.opacity - 1.0).abs() < 1e-9);
    u.touch_up(170.0, 25.0, 650.0);
    assert_eq!(px(&mut u, 900.0, 170, 25), 16, "released");
}

#[test]
fn hover_events_and_the_150_ms_rest_hint() {
    let mut u = ui();
    let _ = u.frame(0.0);
    u.pointer_move(50.0, 50.0, 0.0);
    assert_eq!(
        u.take_events(),
        vec![UiEvent::HoverChanged {
            action: Action::from("tile-hover"),
            entered: true
        }]
    );
    let _ = u.frame(100.0);
    assert!(u.take_events().is_empty(), "not rested yet");
    u.pointer_move(52.0, 52.0, 120.0);
    let _ = u.frame(149.0);
    assert!(
        u.take_events().is_empty(),
        "moving inside the node keeps the rest running from the first entry"
    );
    let _ = u.frame(151.0);
    assert_eq!(
        u.take_events(),
        vec![UiEvent::HoverRest(Action::from("tile-rest"))]
    );
    let _ = u.frame(400.0);
    assert!(u.take_events().is_empty(), "once");
    u.pointer_leave(500.0);
    assert_eq!(
        u.take_events(),
        vec![UiEvent::HoverChanged {
            action: Action::from("tile-hover"),
            entered: false
        }]
    );
}

#[test]
fn a_disabled_node_is_dim_takes_no_tap_and_no_hover() {
    let mut u = ui();
    let _ = u.frame(0.0);
    let v = u.node_values("off").unwrap();
    assert!((v.opacity - 0.4).abs() < 1e-9);
    u.pointer_move(300.0, 130.0, 0.0);
    let _ = u.frame(200.0);
    assert!((u.node_values("off").unwrap().scale - 1.0).abs() < 1e-9);
    u.touch_down(300.0, 130.0, 300.0);
    u.touch_up(300.0, 130.0, 340.0);
    assert!(u.take_events().is_empty());
}

#[test]
fn cursor_shapes_follow_the_node_and_the_arrow_is_the_default() {
    let mut u = ui();
    let _ = u.frame(0.0);
    assert_eq!(u.cursor(), Cursor::Arrow);
    u.pointer_move(50.0, 190.0, 0.0);
    assert_eq!(u.cursor(), Cursor::Text);
    u.pointer_move(50.0, 50.0, 10.0);
    assert_eq!(
        u.cursor(),
        Cursor::Arrow,
        "the Mac never sets the pointing hand"
    );
    u.set_tap_cursor(Some(Cursor::Pointer));
    u.pointer_move(51.0, 50.0, 20.0);
    assert_eq!(
        u.cursor(),
        Cursor::Pointer,
        "opt-in hand over tappable nodes"
    );
    u.pointer_leave(30.0);
    assert_eq!(u.cursor(), Cursor::Arrow);
}

#[test]
fn a_tooltip_shows_after_half_a_second_of_hover_and_a_click_hides_it() {
    let mut u = ui();
    let _ = u.frame(0.0);
    u.pointer_move(250.0, 200.0, 0.0);
    assert_eq!(u.visible_tooltip(400.0), None);
    assert!(u.needs_frame(), "waits for the timer");
    let quiet = u.frame(400.0).quads().len();
    let shown = u.frame(500.0).quads().len();
    assert!(
        shown > quiet,
        "the panel and the text are drawn: {quiet} -> {shown}"
    );
    assert_eq!(u.visible_tooltip(500.0).unwrap().0, "Abspielen");
    u.touch_down(250.0, 200.0, 600.0);
    assert_eq!(u.visible_tooltip(700.0), None);
    u.touch_up(250.0, 200.0, 650.0);
    u.pointer_leave(800.0);
    u.pointer_move(250.0, 200.0, 900.0);
    assert_eq!(u.visible_tooltip(1000.0), None, "the delay starts again");
    assert!(u.visible_tooltip(1450.0).is_some());
}

#[test]
fn a_secondary_click_reports_its_place_and_ignores_nodes_without_one() {
    let mut u = ui();
    let _ = u.frame(0.0);
    assert!(u.secondary_click(320.0, 200.0, 10.0));
    assert_eq!(
        u.take_events(),
        vec![UiEvent::Secondary {
            action: Action::from("ctx"),
            x: 320.0,
            y: 200.0
        }]
    );
    assert!(!u.secondary_click(50.0, 50.0, 20.0));
    assert!(u.take_events().is_empty());
}

#[test]
fn a_selected_node_keeps_its_surface_on() {
    let mut u = ui();
    let p = px(&mut u, 300.0, 430, 185);
    assert!(
        (29..=32).contains(&p),
        "selected = hover surface at rest: {p}"
    );
}

#[test]
fn a_wheel_notch_scrolls_clamped_bounces_at_the_end_and_page_keys_animate() {
    let mut u = ui();
    let _ = u.frame(0.0);
    assert!(u.wheel_scroll(100.0, 300.0, 0.0, 100.0, 10.0));
    assert_eq!(u.scroll_offsets()[0], 100.0);
    assert!(
        !u.wheel_scroll(100.0, 50.0, 0.0, 100.0, 20.0),
        "nothing scrollable under the pointer"
    );
    assert!(u.wheel_scroll(100.0, 300.0, 0.0, 5000.0, 30.0));
    // The Mac's table gives at the end (28 pt bounce); Windows and Linux stop dead.
    let bounce = u.scroll_tuning().rubber_band;
    assert_eq!(
        u.scroll_offsets()[0],
        if bounce { 878.0 } else { 850.0 },
        "bounce: 1000 - 150 + 28, none: 1000 - 150"
    );
    run(&mut u, 30.0, 1000.0);
    assert!(
        (u.scroll_offsets()[0] - 850.0).abs() < 0.5,
        "springs back to the end: {}",
        u.scroll_offsets()[0]
    );
    assert!(u.scroll_key(ScrollKey::Home, 1100.0));
    run(&mut u, 1100.0, 1900.0);
    assert!(u.scroll_offsets()[0].abs() < 0.5);
    assert!(u.scroll_key(ScrollKey::PageDown, 2000.0));
    run(&mut u, 2000.0, 2800.0);
    assert!(
        (u.scroll_offsets()[0] - 110.0).abs() < 0.5,
        "150 - 40 overlap: {}",
        u.scroll_offsets()[0]
    );
    assert!(u.scroll_key(ScrollKey::End, 2900.0));
    run(&mut u, 2900.0, 3700.0);
    assert!((u.scroll_offsets()[0] - 850.0).abs() < 0.5);
}

#[test]
fn a_precision_touchpad_moves_1_to_1_and_stops_dead_at_the_ends() {
    let mut u = ui();
    let _ = u.frame(0.0);
    swiftly_ui::set_precise_wheel(true);
    assert!(u.wheel_scroll(100.0, 300.0, 0.0, 70.0, 10.0));
    assert_eq!(u.scroll_offsets()[0], 70.0);
    // Far past the end: the offset is the end (850), never past it, and it stays there when time passes.
    u.wheel_scroll(100.0, 300.0, 0.0, 5000.0, 20.0);
    swiftly_ui::set_precise_wheel(false);
    assert_eq!(u.scroll_offsets()[0], 850.0, "no rubber band");
    run(&mut u, 20.0, 600.0);
    assert_eq!(u.scroll_offsets()[0], 850.0);
    // Past the start likewise.
    swiftly_ui::set_precise_wheel(true);
    u.wheel_scroll(100.0, 300.0, 0.0, -5000.0, 700.0);
    swiftly_ui::set_precise_wheel(false);
    assert_eq!(u.scroll_offsets()[0], 0.0, "no rubber band at the start");
}

#[test]
fn the_desktop_scroll_table_has_no_rail_snapping_and_the_mac_glide() {
    let u = ui();
    assert!(!u.scroll_tuning().rail_snaps);
    assert_eq!(
        u.scroll_tuning().release,
        swiftly_motion::Glide::MacTrackpad
    );
    let phone = Ui::new(
        view,
        Scene {
            menu: MenuController::new(),
        },
        Env::phone(390.0, 600.0, 1.0),
        Cx::deterministic(),
    );
    assert!(phone.scroll_tuning().rail_snaps);
    assert_eq!(
        phone.scroll_tuning().release,
        swiftly_motion::Glide::Exponential(0.998)
    );
}

#[test]
fn a_popover_grows_out_of_its_corner_taps_choose_and_the_catcher_dismisses() {
    let mut u = ui();
    let _ = u.frame(0.0);
    let mut menu = MenuController::new();
    menu.open(
        menu_entries(),
        Anchor::Button(Rect::new(200.0, 60.0, 120.0, 34.0)),
        0.0,
        false,
    );
    assert!(menu.is_open());
    let _ = u.frame(1000.0);
    u.set_parts(Scene { menu: menu.clone() });
    let _ = u.frame(1000.0);
    let v0 = u.node_values("menu-panel").unwrap();
    assert!(
        (v0.scale - 0.94).abs() < 1e-6 && v0.opacity < 1e-6,
        "starts at 0.94 and clear: {v0:?}"
    );
    run(&mut u, 1000.0, 1100.0);
    let v1 = u.node_values("menu-panel").unwrap();
    assert!(v1.scale > 0.94 && v1.opacity > 0.3, "{v1:?}");
    run(&mut u, 1100.0, 1700.0);
    let v2 = u.node_values("menu-panel").unwrap();
    assert!((v2.scale - 1.0).abs() < 1e-3 && (v2.opacity - 1.0).abs() < 1e-3);
    // The second row ("Info") sits below the first: tap it.
    u.touch_down(220.0, 100.0 + 6.0 + 28.0 + 14.0, 1800.0);
    u.touch_up(220.0, 100.0 + 6.0 + 28.0 + 14.0, 1850.0);
    assert_eq!(u.take_events(), vec![UiEvent::Tap(Action::from("info"))]);
    // A click outside is the catcher.
    u.touch_down(500.0, 350.0, 1900.0);
    u.touch_up(500.0, 350.0, 1950.0);
    assert_eq!(u.take_events(), vec![UiEvent::Tap(DISMISS)]);
    // A right click outside dismisses too.
    assert!(u.secondary_click(500.0, 350.0, 2000.0));
    assert_eq!(
        u.take_events(),
        vec![UiEvent::Secondary {
            action: DISMISS,
            x: 500.0,
            y: 350.0
        }]
    );
}

#[test]
fn menu_keys_through_the_controller() {
    let mut menu = MenuController::new();
    menu.open(
        menu_entries(),
        Anchor::Button(Rect::new(10.0, 10.0, 100.0, 34.0)),
        190.0,
        true,
    );
    assert_eq!(menu.highlighted(), Some(0));
    assert_eq!(menu.key(MenuKey::Down, 0.0), MenuOutcome::Highlight(1));
    assert_eq!(menu.key(MenuKey::End, 0.0), MenuOutcome::Highlight(4));
    assert_eq!(
        menu.key(MenuKey::Enter, 0.0),
        MenuOutcome::Activate(Action::from("del"))
    );
    assert!(!menu.is_open(), "a choice closes it");
    menu.open(
        menu_entries(),
        Anchor::Pointer(Point::new(0.0, 0.0)),
        0.0,
        true,
    );
    assert_eq!(menu.key(MenuKey::Escape, 0.0), MenuOutcome::Close);
    assert!(!menu.is_open());
}

fn shot(name: &str, mut u: Ui<Scene>, t: f64) {
    let list = u.frame(t);
    check_golden(name, &u.render(&list, CLEAR));
}

#[test]
fn frame_goldens_hover_pressed_and_tooltip() {
    let mut u = ui();
    let _ = u.frame(0.0);
    u.pointer_move(200.0, 40.0, 0.0);
    let _ = u.frame(300.0);
    u.pointer_move(50.0, 50.0, 310.0);
    let list = u.frame(600.0);
    check_golden("interact_hover", &u.render(&list, CLEAR));

    let mut u = ui();
    let _ = u.frame(0.0);
    u.touch_down(60.0, 130.0, 10.0);
    u.touch_down(170.0, 25.0, 20.0);
    let list = u.frame(30.0);
    check_golden("interact_pressed", &u.render(&list, CLEAR));

    let mut u = ui();
    let _ = u.frame(0.0);
    u.pointer_move(250.0, 200.0, 0.0);
    let list = u.frame(600.0);
    check_golden("interact_tooltip", &u.render(&list, CLEAR));
}

#[test]
fn frame_goldens_popover_in_three_window_sizes() {
    for (w, h, name) in [
        (1280.0, 800.0, "interact_popover_1280x800"),
        (900.0, 600.0, "interact_popover_900x600"),
        (640.0, 420.0, "interact_popover_640x420"),
    ] {
        let mut u = ui_sized(w, h, false);
        let _ = u.frame(0.0);
        let mut menu = MenuController::new();
        // Near the lower right corner: the menu flips up and left in the small windows.
        let anchor = Point::new(w - 150.0, h - 120.0);
        menu.open(menu_entries(), Anchor::Pointer(anchor), 0.0, true);
        u.set_parts(Scene { menu });
        let _ = u.frame(100.0);
        run(&mut u, 100.0, 900.0);
        shot(name, u, 900.0);
    }
}

#[test]
fn quads_of_an_idle_frame_do_not_grow_with_hover_support() {
    // Both pictures are taken after the animations of the first frames have run (a surface that is still at alpha 0
    // is not drawn, so a frame at time 0 is not comparable with a later one).
    let mut u = ui();
    let _ = u.frame(0.0);
    let list = u.frame(500.0);
    let shapes = list
        .quads()
        .iter()
        .filter(|q| q.kind == QuadKind::Shape)
        .count();
    let mut u2 = ui();
    u2.pointer_move(50.0, 50.0, 0.0);
    let _ = u2.frame(0.0);
    let list2 = u2.frame(500.0);
    let shapes2 = list2
        .quads()
        .iter()
        .filter(|q| q.kind == QuadKind::Shape)
        .count();
    assert_eq!(
        shapes, shapes2,
        "hover adds no quad to a tile without a surface"
    );
}

/// Opacity and width of the menu panel's background quad (radius 12) in a frame, if it is drawn.
fn panel_quad(list: &swiftly_render::DrawList) -> Option<(f32, f32)> {
    list.quads()
        .iter()
        .filter(|q| q.kind == QuadKind::Shape && (11.0..12.01).contains(&q.radii.tl))
        .max_by(|a, b| a.rect.w.total_cmp(&b.rect.w))
        .map(|q| (q.opacity, q.rect.w))
}

#[test]
fn a_closing_menu_plays_the_leap_exit_and_is_gone_afterwards() {
    use swiftly_motion::catalogue::Id;
    let mut u = ui_sized(800.0, 600.0, false);
    let _ = u.frame(0.0);
    let mut menu = MenuController::new();
    menu.open(
        menu_entries(),
        Anchor::Button(Rect::new(100.0, 60.0, 120.0, 34.0)),
        0.0,
        true,
    );
    u.set_parts(Scene { menu });
    run(&mut u, 0.0, 800.0);
    let (open_opacity, open_w) = panel_quad(&u.frame(800.0)).expect("the open menu is drawn");
    assert!((open_opacity - 1.0).abs() < 1e-3);
    // Close: the panel does not vanish, it shrinks to 0.94 and fades out with the `leap` curve.
    u.set_parts(Scene {
        menu: MenuController::new(),
    });
    let leap = Id::Leap.curve();
    let mut worst: f32 = 0.0;
    let mut saw_ghost = false;
    for ms in (8..=200).step_by(8) {
        let list = u.frame(800.0 + f64::from(ms));
        if let Some((o, w)) = panel_quad(&list) {
            saw_ghost = true;
            let want = leap.displacement(f64::from(ms) / 1000.0) as f32;
            worst = worst.max((o - want).abs());
            assert!(w <= open_w + 0.01, "the closing panel only shrinks");
        }
    }
    assert!(saw_ghost, "the panel stays drawn while it fades out");
    assert!(
        worst < 0.01,
        "exit opacity follows the leap curve, off by {worst}"
    );
    run(&mut u, 1000.0, 1800.0);
    assert!(
        panel_quad(&u.frame(1800.0)).is_none(),
        "the ghost is gone once the exit has run"
    );
    assert!(!u.needs_frame(), "nothing keeps animating");
}

#[test]
fn reopening_a_menu_during_its_exit_takes_the_ghost_over() {
    let mut u = ui_sized(800.0, 600.0, false);
    let _ = u.frame(0.0);
    let open = |p: Point| {
        let mut menu = MenuController::new();
        menu.open(menu_entries(), Anchor::Pointer(p), 0.0, true);
        Scene { menu }
    };
    u.set_parts(open(Point::new(100.0, 100.0)));
    run(&mut u, 0.0, 800.0);
    u.set_parts(Scene {
        menu: MenuController::new(),
    });
    let _ = u.frame(840.0);
    u.set_parts(open(Point::new(100.0, 100.0)));
    run(&mut u, 840.0, 1700.0);
    let (o, _) = panel_quad(&u.frame(1700.0)).expect("drawn");
    assert!((o - 1.0).abs() < 1e-3, "fully open again, one panel: {o}");
}

#[test]
fn a_context_menu_opens_at_once_and_fades_out_with_the_native_curve() {
    use swiftly_motion::catalogue::Id;
    let mut u = ui_sized(800.0, 600.0, false);
    let _ = u.frame(0.0);
    let mut menu = MenuController::new();
    menu.open(
        menu_entries(),
        Anchor::Pointer(Point::new(100.0, 100.0)),
        0.0,
        true,
    );
    u.set_parts(Scene { menu });
    // Opened by the system menu: fully there on the first frame, no scale-up.
    let (o, w) = panel_quad(&u.frame(8.0)).expect("drawn at once");
    assert!((o - 1.0).abs() < 1e-3, "opaque at once: {o}");
    run(&mut u, 8.0, 800.0);
    let (_, open_w) = panel_quad(&u.frame(800.0)).expect("open");
    assert!((w - open_w).abs() < 0.01, "full size at once");
    u.set_parts(Scene {
        menu: MenuController::new(),
    });
    let fade = Id::NativeFade.curve();
    let mut worst: f32 = 0.0;
    for ms in (8..=340).step_by(8) {
        let (o, w) = panel_quad(&u.frame(800.0 + f64::from(ms))).expect("still drawn");
        assert!(
            (w - open_w).abs() < 0.01,
            "a native menu fades, it does not shrink"
        );
        worst = worst.max((o - fade.displacement(f64::from(ms) / 1000.0) as f32).abs());
    }
    assert!(worst < 0.01, "fade off by {worst}");
}
