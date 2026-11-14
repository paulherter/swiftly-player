//! Live resize: while the window is dragged to a new size the content must follow at once, on the very frame of the new
//! size, not a spring or a few frames later. Every step of a drag is measured against the picture the same size settles
//! to (an animation that chases the size shows as a difference between the two).

use swiftly_desktop::shell::Shell;
use swiftly_render::DrawList;
use swiftly_ui::{Cx, Idiom};

const SCALE: f32 = 1.5;

fn px(pt: (f32, f32)) -> (u32, u32) {
    ((pt.0 * SCALE).round() as u32, (pt.1 * SCALE).round() as u32)
}

fn bytes(list: &DrawList) -> Vec<Vec<u8>> {
    list.quads()
        .iter()
        .map(|q| {
            let mut b = Vec::new();
            q.write_bytes(&mut b);
            b
        })
        .collect()
}

/// How many quads of `a` differ from the same index of `b` (all of `a` when the counts differ).
fn differing(a: &DrawList, b: &DrawList) -> usize {
    let (a, b) = (bytes(a), bytes(b));
    if a.len() != b.len() {
        return a.len().max(b.len());
    }
    a.iter().zip(&b).filter(|(x, y)| x != y).count()
}

fn settle(shell: &mut Shell, t: &mut f64) -> DrawList {
    let mut list = shell.frame(*t).0;
    for _ in 0..240 {
        *t += 16.0;
        list = shell.frame(*t).0;
    }
    list
}

#[test]
fn every_step_of_a_window_drag_shows_the_final_picture_of_that_size_at_once() {
    let mut shell = Shell::new_suite(
        px((1280.0, 800.0)),
        SCALE,
        Cx::deterministic(),
        Idiom::Desktop,
    );
    let mut t = 0.0;
    settle(&mut shell, &mut t);
    let mut stale_steps = Vec::new();
    // A drag of the right and bottom edge: small steps of 6 pt, one frame each (the compositor sends one per refresh).
    for step in 1..=24 {
        let size = (1280.0 + 6.0 * step as f32, 800.0 + 4.0 * step as f32);
        shell.resize(px(size), SCALE);
        t += 8.0;
        let at_once = shell.frame(t).0;
        // The same size, run to rest.
        let mut probe_t = t;
        let rest = settle(&mut shell, &mut probe_t);
        t = probe_t;
        let n = differing(&at_once, &rest);
        if n > 0 {
            stale_steps.push((step, n));
        }
    }
    assert!(
        stale_steps.is_empty(),
        "{} of 24 drag steps drew a picture that still moved after the size was set: (step, quads that differ) {stale_steps:?}",
        stale_steps.len()
    );
}
