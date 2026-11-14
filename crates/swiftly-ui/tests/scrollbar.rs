//! The overlay scroll bar of vertical scroll views: shows while scrolling or near the right edge, fades after about a
//! second, the thumb drags 1:1, a click in the track pages, and the bar never takes part of a finger scroll.

use swiftly_design::tokens::colour;
use swiftly_layout::{Align, Alignment, Axis, FlexFrame};
use swiftly_ui::components::color;
use swiftly_ui::harness::{Harness, Trace};
use swiftly_ui::{Cx, Env, Node, Ui};

#[derive(Clone, PartialEq)]
struct P;

/// A 390 x 800 window holding one vertical list of 40 rows of 50 pt.
fn list() -> Harness<P> {
    let view = |_: &P, _: &Env, _: &Cx| {
        let rows: Vec<Node> = (0..40)
            .map(|i| {
                Node::rect(color(colour::RAISED), 6.0)
                    .frame(Some(300.0), Some(50.0), Alignment::CENTER)
                    .key(i as u64)
            })
            .collect();
        let column = Node::vstack(Align::Start, Some(0.0), rows);
        Node::scroll(Axis::Vertical, None, column).flex_frame(FlexFrame {
            max_w: Some(f32::INFINITY),
            max_h: Some(f32::INFINITY),
            align: Some(Alignment::TOP_LEADING),
            ..FlexFrame::default()
        })
    };
    // The Mac table: the bar and its timing are the Mac's behaviour, whatever OS the test runs on.
    let mut ui = Ui::new(
        view,
        P,
        Env::new(
            swiftly_layout::Size::new(390.0, 800.0),
            2.0,
            swiftly_ui::Idiom::Desktop,
        ),
        Cx::deterministic(),
    );
    ui.set_scroll_tuning(swiftly_motion::ScrollTuning::for_os(
        swiftly_motion::Os::MacOs,
    ));
    Harness::new(ui)
}

#[test]
fn the_bar_shows_while_scrolling_and_fades_after_a_second() {
    let mut h = list();
    h.advance_to(300.0);
    assert!(
        h.ui.scroll_bar().is_some_and(|(_, a)| a == 0.0),
        "hidden at rest"
    );
    h.ui.wheel_scroll(200.0, 300.0, 0.0, -80.0, h.now);
    h.advance_to(h.now + 100.0);
    assert!(h.ui.scroll_bar().unwrap().1 > 0.99, "shown while scrolling");
    h.advance_to(h.now + 1000.0);
    assert!(
        h.ui.scroll_bar().unwrap().1 > 0.0,
        "still visible just after the first second"
    );
    h.advance_to(h.now + 1500.0);
    assert_eq!(h.ui.scroll_bar().unwrap().1, 0.0, "gone after the fade");
    assert!(!h.ui.needs_frame(), "no frames once it has faded");
}

#[test]
fn the_pointer_near_the_right_edge_wakes_the_bar_and_leaving_lets_it_fade() {
    let mut h = list();
    h.advance_to(300.0);
    let w = h.ui.env().size.w;
    h.ui.pointer_move(w - 6.0, 300.0, h.now);
    h.advance_to(h.now + 3000.0);
    assert_eq!(
        h.ui.scroll_bar().unwrap().1,
        1.0,
        "stays while the pointer is near"
    );
    h.ui.pointer_move(w / 2.0, 300.0, h.now);
    h.advance_to(h.now + 1500.0);
    assert_eq!(h.ui.scroll_bar().unwrap().1, 0.0);
}

#[test]
fn dragging_the_thumb_moves_the_page_in_proportion() {
    let mut h = list();
    h.advance_to(300.0);
    let w = h.ui.env().size.w;
    h.ui.pointer_move(w - 6.0, 300.0, h.now);
    h.advance_to(h.now + 50.0);
    let (thumb, _) = h.ui.scroll_bar().unwrap();
    let (off0, max, view) = {
        let v = h.ui.scroll_offsets();
        (v[0], 0.0, v.len())
    };
    let _ = (max, view);
    let x = thumb.x + thumb.w / 2.0;
    let y0 = thumb.y + thumb.h / 2.0;
    h.play(
        &Trace::new()
            .down(h.now + 10.0, x, y0)
            .move_to(h.now + 30.0, x, y0 + 50.0)
            .move_to(h.now + 50.0, x, y0 + 100.0)
            .up(h.now + 60.0, x, y0 + 100.0),
    );
    let (t1, _) = h.ui.scroll_bar().unwrap();
    assert!(
        (t1.y - thumb.y - 100.0).abs() < 1.5,
        "thumb follows the pointer: {} -> {}",
        thumb.y,
        t1.y
    );
    assert!(
        h.ui.scroll_offsets()[0] > off0 + 100.0,
        "the page moved further than the thumb"
    );
    assert!(h.events.is_empty(), "no tap from a bar drag");
}

#[test]
fn a_click_in_the_track_pages_towards_the_click() {
    let mut h = list();
    h.advance_to(300.0);
    let w = h.ui.env().size.w;
    h.ui.pointer_move(w - 6.0, 600.0, h.now);
    h.advance_to(h.now + 50.0);
    let (thumb, _) = h.ui.scroll_bar().unwrap();
    let below = thumb.y + thumb.h + 60.0;
    h.play(&Trace::new().down(h.now + 10.0, thumb.x + 2.0, below).up(
        h.now + 40.0,
        thumb.x + 2.0,
        below,
    ));
    h.advance_to(h.now + 600.0);
    let o = h.ui.scroll_offsets()[0];
    let view = h.ui.env().size.h as f64;
    assert!(o > view * 0.5 && o < view, "paged by about one view: {o}");
}

#[test]
fn a_finger_beside_the_thumb_scrolls_instead_of_paging() {
    let mut h = list();
    h.advance_to(300.0);
    h.ui.wheel_scroll(200.0, 300.0, 0.0, -80.0, h.now);
    h.advance_to(h.now + 300.0);
    let (thumb, a) = h.ui.scroll_bar().unwrap();
    assert!(a > 0.5);
    let before = h.ui.scroll_offsets()[0];
    let x = thumb.x + 2.0;
    // Finger 400 pt below the thumb, dragged up 40 pt: the page moves about 40 pt, not a page.
    h.ui.pointer_leave(h.now);
    h.play(&Trace::new().drag(h.now + 10.0, 80.0, 8.0, (x, 700.0), (x, 660.0)));
    h.ui.touch_up(x, 660.0, h.now + 120.0);
    let moved = h.ui.scroll_offsets()[0] - before;
    assert!(
        moved > 10.0 && moved < 80.0,
        "finger moved the page by {moved}"
    );
}
