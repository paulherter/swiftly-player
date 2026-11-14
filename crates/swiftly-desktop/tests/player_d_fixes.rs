//! Desktop acceptance D: the Mac look of the player's scrim and loader, measured on software frames at 1280 x 800, scale 1.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn screen() -> PlayerScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let _ = s.frame(0.0);
    s
}

fn frame_at(s: &mut PlayerScreen, from: f64, to: f64) -> RgbaImage {
    let mut now = from;
    while now + STEP < to {
        now += STEP;
        let _ = s.frame(now);
    }
    let (list, _) = s.frame(to);
    s.render_software(&list)
}

fn luma(img: &RgbaImage, x: usize, y: usize) -> f32 {
    let p = img.pixel(x, y);
    0.299 * f32::from(p[0]) + 0.587 * f32::from(p[1]) + 0.114 * f32::from(p[2])
}

/// The top shade fades from .72 black to clear over 200 pt: its last row is as bright as the picture below it. A black base
/// fill under the gradient kept the whole band dark and cut the film at the band's lower edge.
#[test]
fn the_top_shade_fades_out_instead_of_cutting_the_picture() {
    let mut s = screen();
    let img = frame_at(&mut s, 0.0, 1500.0);
    assert!(s.vm().controls().visible);
    let mut worst = 0.0_f32;
    let mut darkest_top = 255.0_f32;
    for x in [300_usize, 420, 520] {
        let (inside, below) = (luma(&img, x, 199), luma(&img, x, 203));
        worst = worst.max((below - inside).abs());
        darkest_top = darkest_top.min(luma(&img, x, 4));
    }
    assert!(
        worst <= 14.0,
        "the shade's lower edge is a step of {worst} levels"
    );
    let reference = luma(&img, 420, 203);
    assert!(
        darkest_top < reference * 0.5,
        "the top still darkens the picture ({darkest_top} vs {reference})"
    );
}

/// The loader is the Mac ring: radius 17 pt (stroke 3, so 15.5 .. 18.5) around the centre of the picture, at every angle.
#[test]
fn the_loader_turns_around_the_centre_of_its_ring() {
    let s0 = screen();
    drop(s0);
    let mut s = screen();
    let (cx, cy) = (640.0_f32, 400.0_f32);
    let mut seen = 0;
    for i in 0..8 {
        let t = 40.0 + f64::from(i) * 90.0;
        let (list, _) = s.frame(t);
        let img = s.render_software(&list);
        if s.vm().transport().picture_shown {
            continue;
        }
        let mut n = 0;
        for y in 340..460_usize {
            for x in 580..700_usize {
                let p = img.pixel(x, y);
                if p[1] > 120 && p[2] > 120 && p[0] < 140 {
                    let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
                    assert!(
                        (14.6..=19.4).contains(&d),
                        "frame {i}: accent pixel at ({x},{y}) is {d:.1} pt from the centre"
                    );
                    n += 1;
                }
            }
        }
        assert!(n > 60, "frame {i}: only {n} accent pixels, no loader?");
        seen += 1;
    }
    assert!(seen >= 3, "the loading screen was seen in {seen} frames");
}
