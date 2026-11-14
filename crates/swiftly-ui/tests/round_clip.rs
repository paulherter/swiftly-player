//! `Node::clipped_rounded`: the children of a node are cut to its frame as one rounded card.
#![allow(clippy::unwrap_used)]

use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment};
use swiftly_ui::components::color;
use swiftly_ui::{Cx, Env, Idiom, Node, Ui};

fn list(radius: f32, scale: f32) -> swiftly_render::DrawList {
    let mut env = Env::new(
        swiftly_layout::Size::new(200.0, 200.0),
        scale,
        Idiom::Desktop,
    );
    env.reduce_motion = true;
    let mut u = Ui::new(
        move |_: &(), _: &Env, _: &Cx| {
            let cell = || {
                Node::rect(color(colour::AREA), 0.0).frame(
                    Some(39.0),
                    Some(80.0),
                    Alignment::CENTER,
                )
            };
            let card = Node::hstack(Align::Start, Some(2.0), vec![cell(), cell()]).frame(
                Some(80.0),
                Some(80.0),
                Alignment::TOP_LEADING,
            );
            let card = if radius > 0.0 {
                card.clipped_rounded(radius)
            } else {
                card.clipped()
            };
            card.frame(Some(200.0), Some(200.0), Alignment::TOP_LEADING)
        },
        (),
        env,
        Cx::deterministic(),
    );
    u.frame(100.0)
}

#[test]
fn a_rounded_clip_reaches_every_quad_inside() {
    let l = list(14.0, 1.5);
    let rounded: Vec<_> = l.quads().iter().filter(|q| q.round_clip[4] > 0.0).collect();
    assert!(rounded.len() >= 2, "both cells carry the rounded clip");
    let q = rounded[0];
    assert_eq!(q.round_clip[4], 14.0, "radius in points");
    assert_eq!(q.round_clip[0], 0.0);
    assert!(
        (q.round_clip[2] - 80.0).abs() < 0.01,
        "the card's own frame"
    );
    let plain = list(0.0, 1.5);
    assert!(plain.quads().iter().all(|q| q.round_clip[4] == 0.0));
}
