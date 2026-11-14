//! A cast tile on a title page opens the person page over it (the Mac's `navigator.openIt(.person)`), and back
//! returns to the title page it came from, not to the list below.

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

#[test]
fn a_cast_tile_opens_the_person_page_and_back_returns_to_the_title() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 300.0);
    assert!(s.goto_tab(1, now));
    run_for(&mut s, &mut now, 400.0);
    // Open the first title of the grid.
    'scan: for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                1280.0 * (0.30 + 0.05 * xi as f32),
                800.0 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, now);
            s.touch_up(x, y, now + 40.0);
            now += 80.0;
            run_for(&mut s, &mut now, 100.0);
            if s.title_open() {
                break 'scan;
            }
        }
    }
    assert!(s.title_open(), "a title page opened");
    run_for(&mut s, &mut now, 900.0);
    let kind = s.top_kind();
    let f = s
        .detail_frame_of("cast:0")
        .expect("the cast tile is on the page");
    let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
    s.touch_down(x, y, now);
    s.touch_up(x, y, now + 40.0);
    run_for(&mut s, &mut now, 900.0);
    assert_eq!(s.top_kind(), Some("page"), "the person page is in front");
    assert!(s.back(now), "back closes the person page");
    run_for(&mut s, &mut now, 900.0);
    assert_eq!(s.top_kind(), kind, "back returns to the title page");
}
