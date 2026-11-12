//! Round 3 remnants: headless frames of the breathing busy mark on the sign-in kind cards at two time points, with and
//! without Reduce Motion.

use swiftly_desktop::login_screen::{LoginScreen, Start};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn shot(reduce: bool, at: &[f64]) -> Vec<RgbaImage> {
    let mut env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    env.reduce_motion = reduce;
    let mut l = LoginScreen::new(env, Cx::deterministic(), Start::Kind);
    let mut now = 0.0;
    while now < 400.0 {
        now += FRAME_MS;
        let _ = l.frame(now);
    }
    l.set_kind_busy(Some(0));
    let t0 = now;
    let mut out = Vec::new();
    for &t in at {
        while now + FRAME_MS < t0 + t {
            now += FRAME_MS;
            let _ = l.frame(now);
        }
        now = t0 + t;
        let _ = l.frame(now);
        let (list, _) = l.frame(now);
        out.push(l.render_software(&list));
    }
    out
}

#[test]
fn busy_mark_breathes_between_full_and_dim() {
    // 0.9 s per leg: the dim end sits at 900 ms, the full end at 1800 ms.
    let f = shot(false, &[100.0, 900.0, 1800.0]);
    let (start, dim, full) = (&f[0], &f[1], &f[2]);
    assert!(start.diff(dim).0 > 8, "the mark dims over 0.9 s");
    assert!(dim.diff(full).0 > 8, "and comes back");
}

#[test]
fn busy_mark_stays_still_with_reduce_motion() {
    let f = shot(true, &[300.0, 900.0]);
    assert!(f[0].diff(&f[1]).0 <= 2, "no breathing under Reduce Motion");
}
