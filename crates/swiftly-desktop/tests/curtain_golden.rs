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
