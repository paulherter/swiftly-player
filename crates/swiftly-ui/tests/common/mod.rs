//! Shared scenes of the UI tests: a page with one poster rail, button and long-press scenes.

#![allow(dead_code)]

use std::path::PathBuf;
use swiftly_design::tokens::{colour, touch};
use swiftly_layout::{Align, Alignment, Size};
use swiftly_render::RgbaImage;
use swiftly_ui::components::{ButtonStyle, color, page, poster_tile, press_button, rail};
use swiftly_ui::harness::Harness;
use swiftly_ui::{Cx, Env, ImageId, Node, Ui};

pub const TITLES: [&str; 12] = [
    "Frieren",
    "Dune: Part Two",
    "Severance",
    "Arrival",
    "Dark Matter",
    "Spirited Away",
    "The Expanse",
    "Blade Runner 2049",
    "Andor",
    "Mushishi",
    "Ghost in the Shell",
    "Paprika",
];

/// A made-up poster: a diagonal gradient in a hue per index, a disc and stripes.
pub fn poster_pixels(i: usize) -> Vec<u8> {
    let (w, h) = (touch::TILE_WIDTH as usize, touch::TILE_HEIGHT as usize);
    let hue = (i as f32 * 0.137 + 0.05).fract();
    let ch = |off: f32| 0.35 + 0.35 * ((hue + off) * std::f32::consts::TAU).sin();
    let base = [ch(0.0), ch(0.33), ch(0.66)];
    let mut px = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        for x in 0..w {
            let t = (x as f32 / w as f32 + y as f32 / h as f32) / 2.0;
            let mut rgb = base.map(|c| c * (0.6 + 0.6 * t));
            let (dx, dy) = (x as f32 - 58.0, y as f32 - 66.0);
            if dx * dx + dy * dy < 26.0 * 26.0 {
                rgb = [0.95, 0.85, 0.5];
            }
            if y > 140 && (y / 5) % 2 == 0 {
                rgb = rgb.map(|v| v * 0.55);
            }
            px.extend_from_slice(&[
                (rgb[0].clamp(0.0, 1.0) * 255.0) as u8,
                (rgb[1].clamp(0.0, 1.0) * 255.0) as u8,
                (rgb[2].clamp(0.0, 1.0) * 255.0) as u8,
                255,
            ]);
        }
    }
    px
}

/// Parts of the rail page.
#[derive(Clone, PartialEq, Debug)]
pub struct Parts {
    pub items: usize,
    pub title: String,
    pub flag: bool,
}

pub fn parts(items: usize) -> Parts {
    Parts {
        items,
        title: "Weiterschauen".into(),
        flag: false,
    }
}

/// Adds twelve posters to the image page.
pub fn posters(cx: &Cx) -> Vec<ImageId> {
    (0..TITLES.len())
        .filter_map(|i| cx.add_image(116, 174, &poster_pixels(i)))
        .collect()
}

/// The rail page: ground colour, one rail with a header; the 13th item on repeats the 12 posters.
pub fn rail_page(ids: Vec<ImageId>) -> impl Fn(&Parts, &Env, &Cx) -> Node {
    move |p, env, cx| {
        let (c2, ids2) = (cx.clone(), ids.clone());
        let n = p.items;
        let rail = rail(cx, "rail", &p.title, n, move |i| {
            poster_tile(
                &c2,
                i,
                TITLES[i % TITLES.len()],
                ids2[i % ids2.len()],
                (i as u64) + 1000,
            )
        });
        let marker = Node::rect(color(colour::MARK_ACCENT), 4.0)
            .frame(Some(20.0), Some(20.0), Alignment::CENTER)
            .key("marker")
            .scaled(if p.flag { 1.5 } else { 1.0 }, spring());
        page(env, vec![rail, marker])
    }
}

pub fn spring() -> swiftly_ui::Motion {
    swiftly_ui::Motion::Spring(swiftly_motion::Spring::snappy())
}

pub const WINDOW: (f32, f32) = (390.0, 400.0);
pub const ROW_Y_FOR_BENCH: f32 = 150.0;

pub fn rail_harness(items: usize) -> Harness<Parts> {
    let cx = Cx::deterministic();
    let ids = posters(&cx);
    let env = Env::phone(WINDOW.0, WINDOW.1, 2.0);
    Harness::new(Ui::new(rail_page(ids), parts(items), env, cx))
}

/// Parts of the button scene.
#[derive(Clone, PartialEq, Debug)]
pub struct ButtonParts;

pub fn button_harness(reduce: bool) -> Harness<ButtonParts> {
    let cx = Cx::deterministic();
    let mut env = Env::phone(390.0, 300.0, 2.0);
    env.reduce_motion = reduce;
    let view = |_: &ButtonParts, env: &Env, cx: &Cx| {
        let b = press_button(cx, "play", "Abspielen", ButtonStyle::Primary, 7_u64);
        let long = Node::rect(color(colour::RAISED), 10.0)
            .frame(Some(100.0), Some(60.0), Alignment::CENTER)
            .key("long")
            .on_long_press(9_u64)
            .on_tap(8_u64);
        let row = Node::hstack(Align::Start, Some(16.0), vec![b, long]);
        page(env, vec![row]).on_edge_pan(swiftly_ui::Edge::Left, 11_u64)
    };
    Harness::new(Ui::new(view, ButtonParts, env, cx))
}

pub fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.png"))
}

/// Compares with the golden (1 level allowed), or writes it with `UPDATE_GOLDENS=1` or when it does not exist yet.
pub fn check_golden(name: &str, img: &RgbaImage) {
    let path = golden_path(name);
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    let (max, share) = img.diff(&golden);
    println!(
        "golden {name}: max diff {max}, differing {:.4} %",
        share * 100.0
    );
    assert!(max <= 1, "golden {name} differs by {max}");
}

pub fn size() -> Size {
    Size::new(WINDOW.0, WINDOW.1)
}
