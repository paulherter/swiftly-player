//! Regression for issue #42 (iPhone/iPad: only the far-left edge of a poster opened it, the centre opened the next
//! title). A tap anywhere inside a poster of the library grid must open that poster's title, so across one row the
//! opened ids form wide contiguous runs, each id once (software renderer, fixed clock).

use swiftly_desktop::browse::Scenario;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn run_to(s: &mut LibraryScreen, now: &mut f64, to: f64) {
    while *now + FRAME_MS < to {
        *now += FRAME_MS;
        let _ = s.frame(*now);
    }
    *now = to;
    let _ = s.frame(to);
}

#[test]
fn a_tap_inside_a_poster_opens_that_poster_not_its_neighbour() {
    let (w, h) = (390.0_f32, 844.0_f32);
    let env = Env::new(Size::new(w, h), 3.0, Idiom::Phone);
    let mut s = LibraryScreen::new(env, Cx::deterministic(), &Kind::Movies, Scenario::Ready);
    let mut t = 0.0;
    run_to(&mut s, &mut t, 600.0);
    // Several rows; the rows between the header and the bottom are posters.
    let mut checked_rows = 0;
    for yi in 0..8 {
        let y = h * (0.35 + 0.07 * yi as f32);
        let mut runs: Vec<(String, f32, f32)> = Vec::new(); // id, first x, last x
        let mut x = 6.0_f32;
        while x < w - 30.0 {
            let before = s.opened().len();
            t += 100.0;
            s.touch_down(x, y, t);
            s.touch_up(x, y, t + 30.0);
            t += 60.0;
            let to = t + 60.0;
            run_to(&mut s, &mut t, to);
            if s.opened().len() > before {
                let id = s.opened().last().cloned().unwrap_or_default();
                match runs.last_mut() {
                    Some(r) if r.0 == id => r.2 = x,
                    _ => runs.push((id, x, x)),
                }
            }
            x += 4.0;
        }
        if runs.len() < 2 {
            continue; // a row between posters or a caption line
        }
        checked_rows += 1;
        let mut seen: Vec<&str> = Vec::new();
        for (id, a, b) in &runs {
            assert!(
                !seen.contains(&id.as_str()),
                "row {yi}: {id} opens in two separate places: {runs:?}"
            );
            seen.push(id);
            // First and last run may be cut by the screen edge; inner runs span a whole poster.
            if *a > 30.0 && *b < w - 60.0 {
                assert!(
                    b - a >= 60.0,
                    "row {yi}: {id} opens only on a thin strip ({a}..{b}): {runs:?}"
                );
            }
        }
    }
    assert!(checked_rows >= 1, "no row of posters answered a tap");
}
