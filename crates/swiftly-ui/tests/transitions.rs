//! Insert and removal transitions with a translation (`.move(edge:)`) and animated frame sizes (`.frame(width: open ? 96 : 0)`),
//! sampled every 8 ms against the catalogued curve.

use swiftly_layout::{Align, Alignment};
use swiftly_motion::catalogue::Id;
use swiftly_render::{Color, QuadKind};
use swiftly_ui::{Cx, Env, Idiom, Motion, Node, Ui};

fn env() -> Env {
    Env::new(swiftly_layout::Size::new(400.0, 300.0), 1.0, Idiom::Desktop)
}

fn run(u: &mut Ui<bool>, from: f64, to: f64) {
    let mut t = from;
    while t < to {
        t += 8.0;
        let _ = u.frame(t.min(to));
    }
}

fn first_quad_y(list: &swiftly_render::DrawList, w: f32) -> Option<(f32, f32)> {
    list.quads()
        .iter()
        .find(|q| q.kind == QuadKind::Shape && (q.rect.w - w).abs() < 0.5)
        .map(|q| (q.rect.y, q.opacity))
}

#[test]
fn a_node_slides_in_and_out_like_move_edge_bottom_plus_opacity() {
    let leap = Id::Leap.curve();
    let view = |on: &bool, _: &Env, _: &Cx| {
        let toast = Node::rect(Color::new(1.0, 1.0, 1.0, 1.0), 8.0)
            .frame(Some(120.0), Some(40.0), Alignment::TOP_LEADING)
            .appear_from(1.0, 0.0)
            .appear_offset(0.0, 60.0)
            .exit_to(1.0, 0.0)
            .exit_offset(0.0, 60.0)
            .offset(0.0, 0.0, Motion::of(Id::Leap))
            .opacity(1.0, Motion::of(Id::Leap))
            .key("toast");
        let kids = if *on { vec![toast] } else { vec![] };
        Node::zstack(Alignment::TOP_LEADING, kids).frame(
            Some(400.0),
            Some(300.0),
            Alignment::TOP_LEADING,
        )
    };
    let mut u = Ui::new(view, false, env(), Cx::deterministic());
    let _ = u.frame(0.0);
    u.set_parts(true);
    // In: y goes from 60 to 0 with leap, opacity 0 to 1.
    let mut worst: f32 = 0.0;
    for ms in (8..=300).step_by(8) {
        let list = u.frame(f64::from(ms));
        let (y, o) = first_quad_y(&list, 120.0).expect("drawn");
        let p = leap.progress(f64::from(ms) / 1000.0) as f32;
        worst = worst
            .max((y - 60.0 * (1.0 - p)).abs())
            .max((o - p).abs() * 60.0);
    }
    assert!(worst < 0.5, "slide in off by {worst}");
    run(&mut u, 300.0, 1500.0);
    // Out: the node stays drawn while it slides down and fades; then it is gone.
    u.set_parts(false);
    let mut worst: f32 = 0.0;
    let mut seen = 0;
    for ms in (8..=300).step_by(8) {
        let list = u.frame(1500.0 + f64::from(ms));
        if let Some((y, o)) = first_quad_y(&list, 120.0) {
            seen += 1;
            let p = leap.progress(f64::from(ms) / 1000.0) as f32;
            worst = worst
                .max((y - 60.0 * p).abs())
                .max((o - (1.0 - p)).abs() * 60.0);
        }
    }
    assert!(seen > 10, "stays drawn during the exit ({seen} frames)");
    assert!(worst < 0.5, "slide out off by {worst}");
    run(&mut u, 1800.0, 2600.0);
    assert!(
        first_quad_y(&u.frame(2600.0), 120.0).is_none(),
        "gone afterwards"
    );
    assert!(!u.needs_frame());
}

#[test]
fn an_animated_frame_pushes_its_neighbour_with_the_curve() {
    let curve = Id::ControlsIn.curve();
    let view = |open: &bool, _: &Env, _: &Cx| {
        let slot = Node::rect(Color::new(0.0, 1.0, 0.0, 1.0), 0.0).animated_frame(
            Some(if *open { 96.0 } else { 0.0 }),
            Some(30.0),
            Alignment::LEADING,
            Motion::of(Id::ControlsIn),
        );
        let btn = Node::rect(Color::new(0.0, 0.0, 1.0, 1.0), 0.0).frame(
            Some(30.0),
            Some(30.0),
            Alignment::LEADING,
        );
        Node::hstack(Align::Start, Some(0.0), vec![slot, btn]).frame(
            Some(400.0),
            Some(300.0),
            Alignment::TOP_LEADING,
        )
    };
    let mut u = Ui::new(view, false, env(), Cx::deterministic());
    let _ = u.frame(0.0);
    let x_of_button = |list: &swiftly_render::DrawList| {
        list.quads()
            .iter()
            .find(|q| q.kind == QuadKind::Shape && (q.color.b - 1.0).abs() < 1e-3)
            .map(|q| q.rect.x)
    };
    assert_eq!(x_of_button(&u.frame(8.0)), Some(0.0));
    u.set_parts(true);
    let mut worst: f32 = 0.0;
    for ms in (16..=300).step_by(8) {
        let list = u.frame(8.0 + f64::from(ms));
        let x = x_of_button(&list).expect("button drawn");
        let want = 96.0 * curve.progress(f64::from(ms) / 1000.0) as f32;
        worst = worst.max((x - want).abs());
    }
    // The change was seen at the first frame after `set_parts` (t = 24 ms), so allow one frame of offset.
    assert!(worst < 96.0 * 0.06, "frame width off by {worst}");
    run(&mut u, 400.0, 1200.0);
    assert_eq!(x_of_button(&u.frame(1200.0)), Some(96.0));
    assert!(!u.needs_frame());
}
