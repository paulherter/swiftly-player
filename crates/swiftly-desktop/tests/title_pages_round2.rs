//! Title pages, round 2: the rail's paging arrows, the corner marks and progress bars of rail tiles.

use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn desktop_detail() -> (DetailScreen, f64) {
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut s = DetailScreen::new(env, Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    for _ in 0..120 {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    (s, now)
}

/// Scrolls the page until the keyed node is on the screen; returns its frame.
fn bring_into_view(s: &mut DetailScreen, key: &str, now: &mut f64) -> [f32; 4] {
    for _ in 0..60 {
        let f = s
            .frame_of(key)
            .unwrap_or_else(|| panic!("{key} has a frame"));
        if f[1] > 60.0 && f[1] + f[3] < 760.0 {
            return f;
        }
        s.wheel_scroll(640.0, 400.0, 0.0, 180.0, *now);
        for _ in 0..12 {
            *now += FRAME_MS;
            let _ = s.frame(*now);
        }
    }
    panic!("{key} never came into view");
}

#[test]
fn a_rail_shows_its_paging_arrow_only_while_the_pointer_is_on_it_and_there_is_more_to_fetch() {
    let (mut s, mut now) = desktop_detail();
    let rail = bring_into_view(&mut s, "similar", &mut now);
    assert!(
        s.frame_of("page.r:similar").is_none(),
        "no arrow while the pointer is elsewhere"
    );
    s.pointer_move(rail[0] + 300.0, rail[1] + 120.0, now);
    for _ in 0..30 {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    assert!(
        s.frame_of("page.l:similar").is_none(),
        "nothing to fetch on the left at the left edge"
    );
    let right = s.frame_of("page.r:similar");
    // The row of the demo is wider than the window, so the right arrow shows over the images.
    let right = right.expect("the right arrow shows on hover");
    assert!(
        (right[2] - 34.0).abs() < 0.5 && (right[3] - 34.0).abs() < 0.5,
        "34 x 34"
    );
    s.pointer_leave(now);
    for _ in 0..30 {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    assert!(
        s.frame_of("page.r:similar").is_none(),
        "the arrow leaves with the pointer"
    );
}
