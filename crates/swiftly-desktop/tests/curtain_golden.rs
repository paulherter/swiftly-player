//! The launch curtain plays the Mac's `startanimation.json`: frames 0, 20, 26, 40, 60 and 79 as goldens
//! (`start_curtain_<frame>`), plus the checks that the shapes really move (the letters start at frame 26).
#![allow(clippy::unwrap_used)]

use std::path::PathBuf;
use swiftly_desktop::shell::Shell;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Idiom};

fn path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"))
}

fn check(name: &str, img: &RgbaImage) {
    let p = path(name);
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !p.exists() {
        img.write_png(&p).unwrap();
        return;
    }
    let golden = RgbaImage::read_png(&p).unwrap();
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "{name}: size"
    );
    let (max, _) = img.diff(&golden);
    assert!(max <= 2, "golden {name} differs by {max}");
}

fn frame_at(shell: &mut Shell, frame: f64) -> RgbaImage {
    let ms = frame * 1000.0 / 60.0;
    let list = shell.frame(ms).0;
    shell.render_software(&list)
}

#[test]
fn the_start_curtain_plays_the_lottie_frames() {
    let mut s = Shell::new_suite(
        (1280, 800),
        1.0,
        Cx::deterministic().with_image_page(4096),
        Idiom::Desktop,
    );
    s.suite_mut().unwrap().enable_curtain();
    let _ = s.frame(0.0);
    let mut shots = Vec::new();
    for f in [0.0, 20.0, 26.0, 40.0, 60.0, 79.0] {
        let img = frame_at(&mut s, f);
        check(&format!("start_curtain_{}", f as u32), &img);
        shots.push(img);
    }
    // The picture changes while the animation runs: frame 0 (only the play mark) differs from frame 60 (the letters in).
    assert!(
        shots[0].diff(&shots[4]).0 > 100,
        "frames 0 and 60 look the same"
    );
    assert!(
        shots[2].diff(&shots[3]).0 > 50,
        "nothing moves between frames 26 and 40"
    );
}

/// With `START_ANIM_DUMP=<dir>`: writes frames 0, 20, 40, 60 and 79 of the curtain at device scale 1.5 and 2 as PNGs
/// (`<mode>_s<scale>_f<frame>.png`), once for a window that has its scale from the start (`native`) and once for a
/// window that gets its scale after the curtain was built (`late`, a Wayland compositor announces it after the first
/// frame). Nothing happens without the variable.
#[test]
fn the_start_curtain_frames_can_be_dumped_at_device_scales() {
    let Some(dir) = std::env::var_os("START_ANIM_DUMP").map(PathBuf::from) else {
        return;
    };
    std::fs::create_dir_all(&dir).unwrap();
    for scale in [1.5_f32, 2.0] {
        let px = ((1280.0 * scale) as u32, (800.0 * scale) as u32);
        for mode in ["native", "late"] {
            let first = if mode == "late" { 1.0 } else { scale };
            let first_px = ((1280.0 * first) as u32, (800.0 * first) as u32);
            let mut s = Shell::new_suite(
                first_px,
                first,
                Cx::deterministic().with_image_page(4096),
                Idiom::Desktop,
            );
            s.suite_mut().unwrap().enable_curtain();
            let _ = s.frame(0.0);
            if mode == "late" {
                s.resize(px, scale);
            }
            for f in [0.0, 20.0, 40.0, 60.0, 79.0] {
                let img = frame_at(&mut s, f);
                img.write_png(&dir.join(format!("{mode}_s{scale}_f{}.png", f as u32)))
                    .unwrap();
            }
        }
    }
}

/// Soft edges: the share of partly covered pixels among the covered ones of the play mark at frame 20 (it is drawn at
/// 780 % of its 100 % size there). A crisp antialiased edge leaves a few percent; the stretched picture of the old
/// player left 27 % at scale 1.5 and 42 % when the scale arrived after the curtain was built.
fn soft_share(img: &RgbaImage) -> f64 {
    let bg = img.pixel(5, 5);
    let dist = |p: [u8; 4]| -> i32 {
        (0..3)
            .map(|c| (i32::from(p[c]) - i32::from(bg[c])).abs())
            .sum()
    };
    let (mut max, mut all) = (0, Vec::new());
    for y in 0..img.height {
        for x in 0..img.width {
            let d = dist(img.pixel(x, y));
            max = max.max(d);
            all.push(d);
        }
    }
    let part = all
        .iter()
        .filter(|&&d| d * 10 > max && d * 10 < max * 9)
        .count();
    let full = all.iter().filter(|&&d| d * 10 >= max * 9).count();
    part as f64 / full.max(1) as f64
}

#[test]
fn the_start_curtain_mark_stays_crisp_when_it_swells_at_any_scale() {
    for scale in [1.5_f32, 2.0] {
        for late in [false, true] {
            let first = if late { 1.0 } else { scale };
            let mut s = Shell::new_suite(
                ((1280.0 * first) as u32, (800.0 * first) as u32),
                first,
                Cx::deterministic().with_image_page(4096),
                Idiom::Desktop,
            );
            s.suite_mut().unwrap().enable_curtain();
            let _ = s.frame(0.0);
            if late {
                s.resize(((1280.0 * scale) as u32, (800.0 * scale) as u32), scale);
            }
            let share = soft_share(&frame_at(&mut s, 20.0));
            assert!(
                share < 0.06,
                "scale {scale}, scale announced late {late}: {:.1} % of the mark's pixels are soft",
                share * 100.0
            );
        }
    }
}
