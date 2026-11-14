//! Title pages, round 3: the person page's biography grows with the leap, the title page's text follows the Mac.

use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::pages_screen::{Kind, PageScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn person() -> (PageScreen, f64) {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut p = PageScreen::new(env, Cx::deterministic(), Kind::Person, Scenario::Ready);
    let mut now = 0.0;
    let _ = p.frame(0.0);
    p.open(0.0);
    for _ in 0..90 {
        now += FRAME_MS;
        let _ = p.frame(now);
    }
    (p, now)
}

#[test]
fn the_biography_opens_with_the_leap_so_the_toggle_slides_down_instead_of_jumping() {
    let (mut p, mut now) = person();
    let start = p.frame_of("bio-toggle").expect("Mehr").y;
    let f = p.frame_of("bio-toggle").unwrap();
    p.touch_down(f.x + 4.0, f.y + 4.0, now);
    p.touch_up(f.x + 4.0, f.y + 4.0, now + 30.0);
    now += 30.0;
    let mut seen = Vec::new();
    for _ in 0..90 {
        now += FRAME_MS;
        let _ = p.frame(now);
        seen.push(p.frame_of("bio-toggle").expect("the toggle stays").y);
    }
    let end = *seen.last().unwrap();
    assert!(
        end > start + 10.0,
        "the full text is taller: {start} -> {end}"
    );
    assert!(
        seen.iter().any(|y| *y > start + 2.0 && *y < end - 2.0),
        "the toggle passes through the heights between: {seen:?}"
    );
}

#[test]
fn the_season_list_carries_the_pages_own_tone_instead_of_a_neutral_grey() {
    use swiftly_desktop::series_screen::SeriesScreen;
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = SeriesScreen::new(env, Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    for _ in 0..90 {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    let f = s.frame_of("tab:0").expect("tab");
    s.touch_down(f[0] + 4.0, f[1] + 4.0, now);
    s.touch_up(f[0] + 4.0, f[1] + 4.0, now + 30.0);
    now += 30.0;
    let mut list = None;
    for _ in 0..60 {
        now += FRAME_MS;
        list = Some(s.frame(now).0);
    }
    assert!(s.menu_open());
    let img = s.render_software(&list.unwrap());
    // Inside the panel, at its right end of the second row, away from the labels and the check mark.
    let (x, y) = (
        (f[0] + 205.0) as usize,
        (f[1] + f[3] + 6.0 + 28.0 + 14.0) as usize,
    );
    let i = (y * img.width + x) * 4;
    let (r, g, b) = (
        i32::from(img.pixels[i]),
        i32::from(img.pixels[i + 1]),
        i32::from(img.pixels[i + 2]),
    );
    let spread = r.max(g).max(b) - r.min(g).min(b);
    assert!(
        spread >= 4,
        "the panel is tinted by the page, got {r},{g},{b}"
    );
}
