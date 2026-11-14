//! The page below stays drawn while a page is pushed or popped, at every depth (the Mac's navigation stack): a cast
//! tile on a title page pushes the person page over the title page, not over the tab; the account pages are pushed over
//! the profile page, and back leads to it without a slide from the tab.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;
const SIZE: (f32, f32) = (1280.0, 800.0);

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn shot(s: &mut Suite, now: &mut f64) -> RgbaImage {
    *now += STEP;
    let (list, _) = s.frame(*now);
    s.render_software(&list)
}

/// With `PAGE_FRAMES=<dir>` every recorded frame is also written there (`<what>-<n>.png`), for a contact sheet.
fn keep(frames: &[RgbaImage], what: &str) {
    let Ok(dir) = std::env::var("PAGE_FRAMES") else {
        return;
    };
    let _ = std::fs::create_dir_all(&dir);
    for (i, f) in frames.iter().enumerate() {
        let _ = f.write_png(std::path::Path::new(&format!("{dir}/{what}-{i:02}.png")));
    }
}

/// Mean absolute difference of the content column over the pixels that differ from `front` (the page in front at
/// rest): what a page sliding in or out has uncovered. `None` while it uncovers (almost) nothing.
fn uncovered(img: &RgbaImage, front: &RgbaImage, reference: &RgbaImage) -> Option<f64> {
    let (mut sum, mut n, mut all) = (0.0, 0.0, 0.0);
    for y in (80..760).step_by(4) {
        for x in (320..1260).step_by(4) {
            all += 1.0;
            let (p, f, r) = (img.pixel(x, y), front.pixel(x, y), reference.pixel(x, y));
            if (0..3).any(|i| p[i].abs_diff(f[i]) > 12) {
                sum += (0..3).map(|i| f64::from(p[i].abs_diff(r[i]))).sum::<f64>();
                n += 3.0;
            }
        }
    }
    (n / 3.0 > all * 0.3).then(|| sum / n)
}

fn record(s: &mut Suite, now: &mut f64, ms: f64) -> Vec<RgbaImage> {
    let end = *now + ms;
    let mut frames = Vec::new();
    while *now < end {
        frames.push(shot(s, now));
    }
    frames
}

/// During a push or pop the pixels the page in front leaves free show the page below, never the tab. The page below
/// moves back and dims while the page slides in, so only the frames where it is (nearly) at rest are compared with its
/// resting picture: the first ones of a push, the last ones of a pop.
fn assert_below(
    frames: &[RgbaImage],
    front: &RgbaImage,
    below: &RgbaImage,
    tab: &RgbaImage,
    what: &str,
) {
    let mut judged = 0;
    let (from, to) = if what == "push" {
        (0, frames.len() * 2 / 5)
    } else {
        (frames.len() * 3 / 5, frames.len())
    };
    for (i, img) in frames.iter().enumerate().take(to).skip(from) {
        if let (Some(to_below), Some(to_tab)) =
            (uncovered(img, front, below), uncovered(img, front, tab))
        {
            judged += 1;
            eprintln!("{what} frame {i}: below {to_below:.1} tab {to_tab:.1}");
            assert!(
                to_below < to_tab,
                "{what} frame {i}: the uncovered part shows the tab ({to_tab:.1}) instead of the page below ({to_below:.1})"
            );
        }
    }
    assert!(
        judged >= 3,
        "{what}: only {judged} frames uncovered anything"
    );
}

fn open_title(s: &mut Suite, now: &mut f64) {
    assert!(s.goto_tab(1, *now));
    run_for(s, now, 500.0);
    for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                SIZE.0 * (0.30 + 0.05 * xi as f32),
                SIZE.1 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, *now);
            s.touch_up(x, y, *now + 40.0);
            *now += 80.0;
            run_for(s, now, 100.0);
            if s.title_open() {
                run_for(s, now, 900.0);
                return;
            }
        }
    }
    panic!("no tile opened a title page");
}

fn tap(s: &mut Suite, now: &mut f64, f: [f32; 4]) {
    let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
    s.pointer_move(x, y, *now);
    s.touch_down(x, y, *now);
    *now += 60.0;
    s.touch_up(x, y, *now);
}

#[test]
fn a_person_page_slides_over_the_title_page_and_back_shows_it_again() {
    let env = Env::new(Size::new(SIZE.0, SIZE.1), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 400.0);
    let tab = shot(&mut s, &mut now);
    open_title(&mut s, &mut now);
    let title = shot(&mut s, &mut now);

    let f = s.detail_frame_of("cast:0").expect("a cast tile");
    tap(&mut s, &mut now, f);
    let push = record(&mut s, &mut now, 700.0);
    keep(&push, "person-push");
    run_for(&mut s, &mut now, 500.0);
    assert_eq!(s.top_kind(), Some("page"));
    let person = shot(&mut s, &mut now);
    assert_below(&push, &person, &title, &tab, "push");

    assert!(s.back(now));
    let pop = record(&mut s, &mut now, 700.0);
    keep(&pop, "person-pop");
    assert_below(&pop, &person, &title, &tab, "pop");
    run_for(&mut s, &mut now, 500.0);
    let again = shot(&mut s, &mut now);
    assert!(
        uncovered(&again, &title, &tab).is_none(),
        "the title page rests where it was"
    );
}

#[test]
fn the_account_pages_slide_over_the_profile_page_and_back_shows_it_again() {
    let env = Env::new(Size::new(SIZE.0, SIZE.1), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 400.0);
    let tab = shot(&mut s, &mut now);
    assert!(s.open_settings(now));
    run_for(&mut s, &mut now, 1200.0);
    let profile = shot(&mut s, &mut now);

    let f = s.top_frame_of("go:server").expect("the add-server row");
    tap(&mut s, &mut now, f);
    let push = record(&mut s, &mut now, 700.0);
    keep(&push, "login-push");
    run_for(&mut s, &mut now, 500.0);
    assert_eq!(s.form_open(), Some("login"));
    let login = shot(&mut s, &mut now);
    assert_below(&push, &login, &profile, &tab, "push");

    assert!(s.back(now));
    let pop = record(&mut s, &mut now, 700.0);
    keep(&pop, "login-pop");
    assert_below(&pop, &login, &profile, &tab, "pop");
    run_for(&mut s, &mut now, 500.0);
    assert_eq!(s.form_open(), Some("settings"));
    let again = shot(&mut s, &mut now);
    assert!(
        uncovered(&again, &profile, &tab).is_none(),
        "the profile page rests where it was"
    );
}

/// A title page opened from Home shows only its own ground in the content column at rest: nothing of Home's rows lies
/// under it (before, the tab was drawn whole below a page whose backdrop was still loading, and its tiles showed through
/// the top of the page). Judged on the draw list: every quad drawn before the page's ground belongs to the sidebar.
#[test]
fn a_title_page_opened_from_home_hides_the_home_rows_at_rest() {
    let env = Env::new(Size::new(SIZE.0, SIZE.1), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    assert_eq!(s.tab(), 0, "the suite starts on Home");
    let mut opened = false;
    'find: for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                SIZE.0 * (0.30 + 0.05 * xi as f32),
                SIZE.1 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, now);
            s.touch_up(x, y, now + 40.0);
            now += 80.0;
            run_for(&mut s, &mut now, 100.0);
            if s.player_open() {
                // Home's Continue rail resumes playback at once: close the player and look further.
                let _ = s.nav_key(swiftly_ui::NavKey::Escape, true, now);
                let _ = s.nav_key(swiftly_ui::NavKey::Escape, false, now);
                run_for(&mut s, &mut now, 1200.0);
            }
            if s.title_open() {
                run_for(&mut s, &mut now, 900.0);
                opened = true;
                break 'find;
            }
        }
    }
    assert!(opened, "no tile of Home opened a title page");
    assert_eq!(s.tab(), 0);
    now += STEP;
    let (list, _) = s.frame(now);
    let side = swiftly_design::tokens::desktop::SIDEBAR_WIDTH;
    let ground = list
        .quads()
        .iter()
        .position(|q| {
            q.kind == swiftly_render::QuadKind::Shape
                && (q.rect.x - side).abs() <= 0.5
                && q.rect.w >= SIZE.0 - side - 1.0
                && q.rect.h >= SIZE.1 - 1.0
                && q.color.a >= 0.999
                && q.clip[0] <= side + 0.5
        })
        .expect("the content column starts with an opaque ground");
    for (i, q) in list.quads().iter().enumerate().take(ground) {
        assert!(
            q.clip[2] <= side + 0.5,
            "quad {i} below the page's ground reaches into the content column: {:?}",
            q.rect
        );
    }
}
