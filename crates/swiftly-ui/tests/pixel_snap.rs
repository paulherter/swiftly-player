//! A cover's ground and border land on the same whole device pixels as its picture, so no grey column of the ground
//! peeks out beside it (scale 1.5, tiles at fractional offsets).
#![allow(clippy::unwrap_used)]

use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment, EdgeInsets};
use swiftly_render::{Color, QuadKind};
use swiftly_ui::components::color;
use swiftly_ui::{Cx, Env, Idiom, Node, Paint, Ui};

const GROUND: Color = Color {
    r: 0.0627451,
    g: 0.0627451,
    b: 0.0627451,
    a: 1.0,
};

fn tile(cx: &Cx, snapped: bool) -> Node {
    let id = cx.add_image(2, 2, &[255; 16]).unwrap();
    let ground = Node::rect(color(colour::AREA), 12.0);
    let ground = if snapped {
        ground.pixel_snapped()
    } else {
        ground
    };
    let n = ground
        .frame(Some(133.0), Some(200.0), Alignment::CENTER)
        .overlay(Node::image(id, 133.0, 200.0, 12.0), Alignment::CENTER)
        .paint(Paint::Stroke {
            color: color(colour::TILE_BORDER),
            width: 1.0,
            radius: 12.0,
        });
    if snapped { n.pixel_snapped() } else { n }
}

/// Counts the pixels just outside the picture's straight edges that differ from the page ground.
fn rim_pixels(x: f32, y: f32, snapped: bool) -> usize {
    let mut env = Env::new(swiftly_layout::Size::new(400.0, 300.0), 1.5, Idiom::Desktop);
    env.reduce_motion = true;
    let mut u = Ui::new(
        move |_: &(), _: &Env, cx: &Cx| {
            Node::vstack(Align::Start, None, vec![tile(cx, snapped)])
                .padding(EdgeInsets {
                    top: y,
                    leading: x,
                    bottom: 0.0,
                    trailing: 0.0,
                })
                .frame(Some(400.0), Some(300.0), Alignment::TOP_LEADING)
        },
        (),
        env,
        Cx::deterministic(),
    );
    let list = u.frame(100.0);
    let pic = list
        .quads()
        .iter()
        .find(|q| q.kind == QuadKind::Image)
        .unwrap()
        .rect;
    let s = 1.5;
    let (x0, y0) = ((pic.x * s).round() as i32, (pic.y * s).round() as i32);
    let (x1, y1) = (
        ((pic.x + pic.w) * s).round() as i32,
        ((pic.y + pic.h) * s).round() as i32,
    );
    let img = u.render(&list, GROUND);
    let mut bad = 0;
    // Straight parts only (the corners are rounded): away from the 12 pt radius.
    for t in ((y0 + 40)..(y1 - 40)).step_by(3) {
        for gx in [x0 - 1, x1] {
            bad += usize::from(img.pixel(gx as usize, t as usize)[0] != 16);
        }
    }
    for t in ((x0 + 40)..(x1 - 40)).step_by(3) {
        for gy in [y0 - 1, y1] {
            bad += usize::from(img.pixel(t as usize, gy as usize)[0] != 16);
        }
    }
    bad
}

#[test]
fn a_cover_never_shows_its_ground_beside_the_picture() {
    for (x, y) in [
        (20.0, 10.0),
        (20.4, 10.3),
        (20.6, 10.7),
        (21.2, 11.4),
        (22.9, 9.1),
    ] {
        assert_eq!(rim_pixels(x, y, true), 0, "grey rim at ({x}, {y})");
    }
}

#[test]
fn without_the_snap_the_ground_peeks_out() {
    let total: usize = [(20.4, 10.3), (20.6, 10.7), (21.2, 11.4)]
        .iter()
        .map(|&(x, y)| rim_pixels(x, y, false))
        .sum();
    assert!(
        total > 0,
        "the unsnapped ground is the bug this test guards"
    );
}
