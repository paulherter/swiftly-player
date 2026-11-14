//! The panel of watching together and continuing elsewhere: frame goldens of the four panels (software renderer,
//! bundled Inter) and what a click, Return and Escape choose. PNGs live in `swiftly-ui/tests/golden`.

use std::path::PathBuf;
use swiftly_desktop::together_ui::{
    Act, ExitPlan, ExitStill, Mode, PickRow, PickTarget, TogetherUi,
};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::GroupRow;

// The goldens are written on Linux (CI runs Linux and macOS). The vector rasteriser (swiftly-ui `icons.rs`, f32 edge
// coverage with arcs flattened through the system libm sin/cos/atan2) rounds a few edge pixels differently per OS:
// measured 2026-11-13 on macOS against the Linux goldens, 0.001-0.010 % of the pixels differ by up to 13 levels, all on
// icon edges (plug, chevrons, search glass, clock), never on text or fills. So on macOS a difference above 2 levels may
// touch at most 0.05 % of the pixels and none may exceed 16 levels (a real layout change moves far more pixels and
// fails). Other systems keep the 12 level tolerance (seen: up to 10 levels from font hinting) without a pixel limit.
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 16 } else { 12 };
const MAC_PIXEL_SHARE: f64 = 0.0005;

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, share) = img.diff(&golden);
    if let (true, Some(dir)) = (max > 0, std::env::var_os("GOLDEN_ACTUAL_DIR")) {
        let _ = img.write_png(&PathBuf::from(dir).join(format!("{name}.png")));
    }
    let share_ok = !cfg!(target_os = "macos") || max <= 2 || share <= MAC_PIXEL_SHARE;
    assert!(
        max <= TOLERANCE && share_ok,
        "golden {name} differs by {max} ({:.3} % of the pixels, in {})",
        share * 100.0,
        diff_box(img, &golden)
    );
}

/// Bounding box `x0,y0..x1,y1` of the pixels that differ, to see at a glance whether it is an edge or a region.
fn diff_box(a: &RgbaImage, b: &RgbaImage) -> String {
    let w = a.width;
    let (mut x0, mut y0, mut x1, mut y1) = (usize::MAX, usize::MAX, 0, 0);
    for (i, (p, q)) in a
        .pixels
        .as_chunks::<4>()
        .0
        .iter()
        .zip(b.pixels.as_chunks::<4>().0)
        .enumerate()
    {
        if p != q {
            let (x, y) = (i % w, i / w);
            (x0, y0, x1, y1) = (x0.min(x), y0.min(y), x1.max(x), y1.max(y));
        }
    }
    format!("{x0},{y0}..{x1},{y1}")
}

fn env() -> Env {
    Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop)
}

fn group() -> GroupRow {
    GroupRow {
        id: "g1".into(),
        name: "Filmabend".into(),
        who: "Anna und Ben schauen gerade".into(),
        state_text: Some("L\u{e4}uft gerade".into()),
    }
}

fn rows() -> Vec<PickRow> {
    vec![
        PickRow {
            target: PickTarget::Session("s1".into()),
            symbol: "television".into(),
            title: "Wohnzimmer".into(),
            under: "Nordlicht".into(),
        },
        PickRow {
            target: PickTarget::Group(group()),
            symbol: "users.fill".into(),
            title: "Filmabend".into(),
            under: "Anna und Ben schauen gerade".into(),
        },
    ]
}

/// Runs frames until the animations settle and returns the picture.
fn settle(ui: &mut TogetherUi, from: f64) -> (RgbaImage, f64) {
    let mut now = from;
    for _ in 0..120 {
        now += 1000.0 / 60.0;
        let _ = ui.frame(now);
    }
    let (list, _) = ui.frame(now + 1000.0 / 60.0);
    (ui.render_software(&list), now)
}

fn center(ui: &TogetherUi, key: &str) -> (f32, f32) {
    let [x, y, w, h] = ui.frame_of(key).unwrap_or_else(|| panic!("no node {key}"));
    (x + w / 2.0, y + h / 2.0)
}

fn press(ui: &mut TogetherUi, key: &str, now: f64) {
    let (x, y) = center(ui, key);
    ui.touch_down(x, y, now);
    ui.touch_up(x, y, now + 40.0);
}

#[test]
fn create_asks_for_the_name_and_opens_the_group() {
    let mut ui = TogetherUi::new(env(), Cx::deterministic());
    ui.show(Mode::Create {
        title_id: "m1".into(),
        line: "Nordlicht".into(),
    });
    let (img, now) = settle(&mut ui, 0.0);
    check("together_create_desktop", &img);
    assert!(ui.wants_text());
    assert_eq!(ui.name(), "Filmabend");
    ui.type_text("e");
    ui.backspace();
    press(&mut ui, "tg:open", now + 100.0);
    assert_eq!(
        ui.take_acts(),
        vec![Act::Create {
            name: "Filmabend".into(),
            title_id: "m1".into()
        }]
    );
    // Return in the field does the same, and a busy channel waits.
    ui.confirm();
    assert_eq!(ui.take_acts().len(), 1);
    ui.set_works(true);
    ui.confirm();
    assert!(ui.take_acts().is_empty());
}

#[test]
fn join_shows_the_group_and_its_state() {
    let mut ui = TogetherUi::new(env(), Cx::deterministic());
    ui.show(Mode::Join(group()));
    let (img, now) = settle(&mut ui, 0.0);
    check("together_join_desktop", &img);
    press(&mut ui, "tg:join", now + 100.0);
    assert_eq!(ui.take_acts(), vec![Act::Join(group())]);
}

#[test]
fn the_picker_lists_devices_and_groups() {
    let mut ui = TogetherUi::new(env(), Cx::deterministic());
    ui.set_origin(110.0, 700.0);
    ui.set_rows(rows());
    ui.show(Mode::Pick);
    let (img, now) = settle(&mut ui, 0.0);
    check("together_pick_desktop", &img);
    press(&mut ui, "tg:pick:0", now + 100.0);
    press(&mut ui, "tg:pick:1", now + 300.0);
    assert_eq!(
        ui.take_acts(),
        vec![Act::Take("s1".into()), Act::Join(group())]
    );
    press(&mut ui, "tg:cancel", now + 500.0);
    assert_eq!(ui.take_acts(), vec![Act::Cancel]);
    ui.escape();
    assert_eq!(ui.take_acts(), vec![Act::Cancel]);
}

#[test]
fn the_picture_leaves_as_a_card() {
    let mut ui = TogetherUi::new(env(), Cx::deterministic());
    ui.show(Mode::Exit {
        title: "Nordlicht".into(),
        line: "Staffel 1 \u{b7} Folge 3".into(),
        device: "Wohnzimmer".into(),
        still: Some(still()),
        top: true,
    });
    // The card hovers over its rest with the two lines under it (0.12 s stand, then the zoom spring, then the float).
    let (img, _) = at_second(&mut ui, 0.8);
    check("together_exit_desktop", &img);
}

/// A 16:9 still frame: red left half, blue right half.
fn still() -> ExitStill {
    let (w, h) = (320_u32, 180_u32);
    let mut px = Vec::new();
    for _ in 0..h {
        for x in 0..w {
            px.extend_from_slice(if x < w / 2 {
                &[200, 0, 0, 255]
            } else {
                &[0, 0, 200, 255]
            });
        }
    }
    ExitStill {
        w,
        h,
        rgba: std::sync::Arc::new(px),
    }
}

/// Frames up to `seconds` after the first one (60 per second) and the picture of the last.
fn at_second(ui: &mut TogetherUi, seconds: f64) -> (RgbaImage, f64) {
    let mut now = 1000.0;
    let _ = ui.frame(now);
    for _ in 0..(seconds * 60.0).round() as usize {
        now += 1000.0 / 60.0;
        let _ = ui.frame(now);
    }
    let (list, _) = ui.frame(now);
    (ui.render_software(&list), now)
}

fn pixel(img: &RgbaImage, x: usize, y: usize) -> [u8; 4] {
    let i = (y * img.width + x) * 4;
    [
        img.pixels[i],
        img.pixels[i + 1],
        img.pixels[i + 2],
        img.pixels[i + 3],
    ]
}

#[test]
fn the_exit_starts_as_the_still_of_the_video_and_leaves_through_the_top() {
    let mut ui = TogetherUi::new(env(), Cx::deterministic());
    ui.show(Mode::Exit {
        title: "Nordlicht".into(),
        line: String::new(),
        device: "Wohnzimmer".into(),
        still: Some(still()),
        top: true,
    });
    // The first frame: the video as it stood, filling the window (the left half red, the right half blue).
    let (img, _) = at_second(&mut ui, 0.0);
    let e = env();
    let (sx, sy) = (img.width as f32 / e.size.w, img.height as f32 / e.size.h);
    let at = |fx: f32, fy: f32| {
        pixel(
            &img,
            (e.size.w * fx * sx) as usize,
            (e.size.h * fy * sy) as usize,
        )
    };
    assert!(
        at(0.25, 0.5)[0] > 150 && at(0.25, 0.5)[2] < 60,
        "left half is red"
    );
    assert!(
        at(0.75, 0.5)[2] > 150 && at(0.75, 0.5)[0] < 60,
        "right half is blue"
    );
    assert!(!ui.exit_over());
    // At the end nothing is left of the picture: the card is out through the top edge, the grounds gone.
    let (plan, _) = ui.exit_plan().expect("an exit runs");
    assert!(
        plan.out() > 1.0 && plan.out() < 3.0,
        "out after {}",
        plan.out()
    );
    let mut later = TogetherUi::new(env(), Cx::deterministic());
    later.show(Mode::Exit {
        title: "Nordlicht".into(),
        line: String::new(),
        device: "Wohnzimmer".into(),
        still: Some(still()),
        top: true,
    });
    let (end, _) = at_second(&mut later, plan.total() + 0.1);
    assert!(later.exit_over());
    assert_eq!(
        pixel(&end, 10, 10)[0],
        pixel(&end, 10, 10)[2],
        "no picture left"
    );
}

#[test]
fn the_exit_follows_the_curves_of_the_core() {
    use swiftly_playback::handoff_card as hc;
    let window = (1280.0_f32, 720.0_f32);
    let up = ExitPlan::new(window, 16.0 / 9.0, true, false);
    let down = ExitPlan::new(window, 16.0 / 9.0, false, false);
    // t = 0: the picture stands where the video stood.
    let first = up.look(0.0);
    assert!((first.width - 1280.0).abs() < 0.5 && (first.y - 360.0).abs() < 0.5);
    assert_eq!((first.black, first.rows, first.ground), (1.0, 0.0, 1.0));
    // The black goes while the card shrinks; the lines come in when it is small.
    assert!(up.look(hc::EXIT_START + hc::BLACK_DURATION + 0.01).black < 0.01);
    assert!(up.look(hc::EXIT_START + 0.7).rows > 0.99);
    // The card rests in the middle, then flies out: up leaves by the top, down by the bottom.
    let (u, d) = (up.look(up.out() + 0.02), down.look(down.out() + 0.02));
    assert!(
        u.y + u.height / 2.0 < 0.0,
        "up: card above the window, y {}",
        u.y
    );
    assert!(
        d.y - d.height / 2.0 > 720.0,
        "down: card below the window, y {}",
        d.y
    );
    // The app ground holds 0.5 s after the card is out, then fades over 0.2 s.
    assert_eq!(up.look(up.out() + 0.49).ground, 1.0);
    assert!(up.look(up.out() + 0.65).ground < 1.0);
    assert!(!up.look(up.out() + 0.6).over && up.look(up.total()).over);
    // Reduced motion: the picture and the black fade out in place, no flight.
    let calm = ExitPlan::new(window, 16.0 / 9.0, true, true);
    assert_eq!(calm.out(), hc::FADE_OUT);
    let mid = calm.look(hc::FADE_OUT / 2.0);
    assert!((mid.picture - 0.5).abs() < 1e-9 && mid.y == 360.0 && mid.rows == 0.0);
}

#[test]
fn the_create_panel_names_the_episode_like_the_mac() {
    use swiftly_desktop::together_ui::{parse_code, title_line};
    assert_eq!(
        title_line(true, "Frieren", Some(2), Some(7), "Das Fest"),
        "Frieren \u{b7} Staffel 2 \u{b7} Folge 7"
    );
    assert_eq!(
        title_line(true, "Frieren", None, None, "Das Fest"),
        "Frieren \u{b7} Das Fest"
    );
    assert_eq!(
        title_line(false, "Nordlicht", None, None, "Nordlicht"),
        "Nordlicht"
    );
    assert_eq!(parse_code("S2 \u{b7} F7"), Some((2, 7)));
    assert_eq!(parse_code("3 neue Folgen"), None);
}

#[test]
fn the_card_carries_a_second_line_only_for_episodes() {
    use swiftly_desktop::together_ui::exit_line;
    assert_eq!(exit_line("S1 \u{b7} F3"), "Staffel 1 \u{b7} Folge 3");
    assert_eq!(
        exit_line("Staffel 2 \u{b7} Folge 7"),
        "Staffel 2 \u{b7} Folge 7"
    );
    assert_eq!(exit_line("2015 \u{b7} 112 Min. \u{b7} Drama"), "");
}

#[test]
fn a_failed_takeover_says_why() {
    let mut ui = TogetherUi::new(env(), Cx::deterministic());
    ui.show(Mode::Failed(
        "Der Titel l\u{e4}sst sich hier gerade nicht abspielen.".into(),
    ));
    let (img, _) = settle(&mut ui, 0.0);
    check("together_failed_desktop", &img);
}

#[test]
fn the_open_panel_is_reachable_by_name() {
    fn names(nodes: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<String>) {
        for n in nodes {
            out.push(n.label.clone());
            names(&n.children, out);
        }
    }
    let mut ui = TogetherUi::new(env(), Cx::deterministic());
    ui.show(Mode::Create {
        title_id: "m1".into(),
        line: "Nordlicht".into(),
    });
    let _ = settle(&mut ui, 0.0);
    let mut all = Vec::new();
    names(&ui.a11y_nodes(), &mut all);
    assert!(all.iter().any(|n| n == "Gruppe \u{f6}ffnen"), "{all:?}");
    assert!(all.iter().any(|n| n == "Abbrechen"), "{all:?}");
}
