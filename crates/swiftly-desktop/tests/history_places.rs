//! The window history is a record of places (section and page stack), like the Mac's `Navigator`: forward opens a
//! closed page again, back and forward cross sections, the profile does not stay in the section left, and a click on the
//! open section's row closes its pages down to the root.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::pages_screen::Kind;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn suite() -> Suite {
    Suite::new(
        Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop),
        Cx::new(),
    )
}

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

#[test]
fn forward_opens_a_closed_page_again() {
    let mut s = suite();
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    s.open_page(Kind::Genre, now);
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.top_kind(), Some("page"));
    assert!(s.back(now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.top_kind(), None);
    assert_eq!(s.can_step(), (false, true), "forward is the closed page");
    assert!(s.forward(now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.top_kind(), Some("page"), "the page opened again");
    assert!(!s.can_step().1);
}

#[test]
fn back_across_sections_brings_the_page_left_behind() {
    let mut s = suite();
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    s.open_page(Kind::Genre, now);
    run_for(&mut s, &mut now, 700.0);
    assert!(s.goto_tab(1, now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!((s.tab(), s.top_kind()), (1, None));
    assert!(s.back(now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!((s.tab(), s.top_kind()), (0, Some("page")));
    assert!(s.forward(now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.tab(), 1);
}

#[test]
fn the_profile_does_not_stay_in_the_section_left_but_history_brings_it_back() {
    let mut s = suite();
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    assert!(s.open_settings(now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.form_open(), Some("settings"));
    assert!(s.goto_tab(1, now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.form_open(), None);
    assert!(s.goto_tab(0, now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.form_open(), None, "the profile was not parked");
    // Back twice: Start again, then the profile that lay on it.
    assert!(s.back(now));
    run_for(&mut s, &mut now, 700.0);
    assert!(s.back(now));
    run_for(&mut s, &mut now, 700.0);
    assert_eq!((s.tab(), s.form_open()), (0, Some("settings")));
}

#[test]
fn the_row_of_the_open_section_closes_its_pages_to_the_root() {
    let mut s = suite();
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    s.open_page(Kind::Genre, now);
    run_for(&mut s, &mut now, 700.0);
    assert!(s.goto_tab(0, now), "the row of the open section acts");
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.top_kind(), None);
    assert!(s.can_step().1, "the closed page can come back");
}

fn flat(nodes: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<swiftly_ui::a11y::A11yNode>) {
    for n in nodes {
        out.push(n.clone());
        flat(&n.children, out);
    }
}

fn picture(s: &mut Suite, now: &mut f64) -> Vec<[f32; 4]> {
    run_for(s, now, 1500.0);
    let (list, _) = s.frame(*now + STEP);
    list.quads()
        .iter()
        .map(|q| [q.rect.x, q.rect.y, q.rect.w, q.rect.h])
        .collect()
}

/// The pointer moves while a page is open over a section; the tile it left keeps no hover when the page closes (it kept
/// it for seconds, the section was never told the pointer had gone), and the tile now under the pointer takes it.
#[test]
fn hover_follows_the_pointer_after_a_page_closes() {
    let mut s = suite();
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    assert!(s.goto_tab(1, now));
    run_for(&mut s, &mut now, 900.0);
    let mut all = Vec::new();
    flat(&s.a11y_nodes().1, &mut all);
    let mut tiles: Vec<[f32; 4]> = all
        .iter()
        .filter_map(|n| n.bounds)
        .filter(|b| b[2] > 90.0 && b[3] > 90.0 && b[0] > 220.0 && b[1] > 100.0 && b[1] < 700.0)
        .collect();
    tiles.sort_by(|a, b| a[0].total_cmp(&b[0]));
    let a = tiles[0];
    let b = *tiles
        .iter()
        .find(|t| t[0] > a[0] + a[2] + 4.0)
        .expect("a second tile");
    let centre = |t: [f32; 4]| (t[0] + t[2] / 2.0, t[1] + t[3] / 2.0);
    // The picture with the pointer on tile B only.
    s.pointer_move(centre(b).0, centre(b).1, now);
    let want = picture(&mut s, &mut now);
    // Hover A, open a page, move to B while the page is up, close it.
    s.pointer_move(centre(a).0, centre(a).1, now);
    let hovered_a = picture(&mut s, &mut now);
    assert_ne!(want, hovered_a, "hover changes nothing here");
    s.open_page(Kind::Genre, now);
    run_for(&mut s, &mut now, 900.0);
    s.pointer_move(centre(b).0 + 1.0, centre(b).1, now);
    run_for(&mut s, &mut now, 300.0);
    assert!(s.back(now));
    let after = picture(&mut s, &mut now);
    assert_eq!(s.top_kind(), None);
    assert_eq!(after, want, "the tile the pointer left kept its hover");
}

/// A page that was closed is on its way out under the page behind it: the window title and the reading list are the page
/// behind's from the moment of the close (they stayed on the closed page, with no nodes).
#[test]
fn the_title_follows_the_page_shown_while_a_page_slides_out() {
    let mut s = suite();
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    s.open_page(Kind::Genre, now);
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.a11y_nodes().0, "Genre");
    assert!(s.back(now));
    run_for(&mut s, &mut now, 3.0 * STEP);
    assert_eq!(s.top_kind(), Some("page"), "the page is still sliding out");
    assert_eq!(s.a11y_nodes().0, "Start");
    run_for(&mut s, &mut now, 700.0);
    assert_eq!(s.top_kind(), None);
    assert_eq!(s.a11y_nodes().0, "Start");
}

fn glyph_rects(list: &swiftly_render::DrawList, min_opacity: f32) -> Vec<[i32; 4]> {
    list.quads()
        .iter()
        .filter(|q| q.kind == swiftly_render::QuadKind::Glyph && q.opacity > min_opacity)
        .map(|q| {
            [
                q.rect.x.round() as i32,
                q.rect.y.round() as i32,
                q.rect.w.round() as i32,
                q.rect.h.round() as i32,
            ]
        })
        .collect()
}

/// Leaving an empty Downloads page: the old page leaves under the new one within a few frames, and the section opened
/// has its grid (no skeleton tiles) because its libraries were read while it waited behind.
#[test]
fn leaving_an_empty_downloads_page_leaves_no_ghost_of_it() {
    use swiftly_desktop::downloads_screen::{DownloadsScreen, Scenario};
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    // What the section looks like when it has settled.
    let mut base = suite();
    let mut t = 0.0;
    run_for(&mut base, &mut t, 600.0);
    assert!(base.goto_tab(2, t));
    run_for(&mut base, &mut t, 1500.0);
    let settled = glyph_rects(&base.frame(t + STEP).0, 0.0);

    let mut s = suite();
    let mut now = 0.0;
    run_for(&mut s, &mut now, 600.0);
    s.show_downloads(DownloadsScreen::new(env, Cx::new(), Scenario::Empty), now);
    run_for(&mut s, &mut now, 900.0);
    // The glyphs only the Downloads page has.
    let old: Vec<[i32; 4]> = glyph_rects(&s.frame(now + STEP).0, 0.0)
        .into_iter()
        .filter(|r| !settled.contains(r))
        .collect();
    assert!(old.len() > 10, "the empty Downloads page draws text");
    assert!(s.goto_tab(2, now));
    for frame in 1..=6 {
        now += STEP;
        let (list, _) = s.frame(now);
        let ghost = glyph_rects(&list, 0.1)
            .into_iter()
            .filter(|r| old.contains(r))
            .count();
        if frame >= 4 {
            assert_eq!(
                ghost, 0,
                "frame {frame}: the old page still shows ({ghost} glyphs)"
            );
        }
    }
}
