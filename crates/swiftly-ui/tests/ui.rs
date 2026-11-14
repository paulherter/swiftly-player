//! Behaviour of the retained UI with synthetic touch traces. Test names state the rule; values come from
//! `swiftly-ui::tuning` and `swiftly-motion::tuning` (sources there).

mod common;

use common::{button_harness, check_golden, parts, rail_harness};
use swiftly_motion::scroll::rubber_band;
use swiftly_render::{Color, QuadKind};
use swiftly_ui::harness::Trace;
use swiftly_ui::{Action, Idiom, Phase, UiEvent, classes};

const ROW_Y: f32 = 150.0;

fn offset(h: &swiftly_ui::harness::Harness<common::Parts>) -> f64 {
    h.ui.scroll_offsets().first().copied().unwrap_or(f64::NAN)
}

#[test]
fn view_runs_only_when_the_parts_or_the_env_change() {
    let mut h = rail_harness(12);
    assert_eq!(h.ui.view_runs(), 1);
    assert!(!h.ui.set_parts(parts(12)), "same parts: no run");
    let _ = h.frame_at(100.0);
    assert_eq!(h.ui.view_runs(), 1, "frames never run the view");
    let mut other = parts(12);
    other.title = "Neu".into();
    assert!(h.ui.set_parts(other));
    assert_eq!(h.ui.view_runs(), 2);
    let env = *h.ui.env();
    assert!(!h.ui.set_env(env));
    let mut wide = env;
    wide.size.w = 430.0;
    assert!(h.ui.set_env(wide));
    assert_eq!(h.ui.view_runs(), 3);
}

#[test]
fn a_drag_moves_the_row_one_to_one_after_the_ten_point_hysteresis() {
    let mut h = rail_harness(12);
    // 5 pt per 8 ms sample: the first sample beyond 10 pt is 15 pt, from there the content follows the finger.
    h.play(&Trace::new().drag(10.0, 96.0, 8.0, (300.0, ROW_Y), (240.0, ROW_Y)));
    let o = offset(&h);
    assert!(
        (o - 45.0).abs() < 1.5,
        "60 pt drag - 15 pt hysteresis = 45 pt, got {o}"
    );
    assert!(h.events.is_empty(), "a scroll reports no tap");
}

#[test]
fn eight_points_of_movement_is_still_a_tap() {
    let mut h = rail_harness(12);
    h.play(
        &Trace::new()
            .down(10.0, 60.0, ROW_Y)
            .move_to(30.0, 66.0, ROW_Y)
            .move_to(50.0, 68.0, ROW_Y)
            .up(70.0, 68.0, ROW_Y),
    );
    assert_eq!(offset(&h), 0.0);
    assert_eq!(
        h.events,
        vec![UiEvent::Tap(Action(1000))],
        "tile 0 was tapped"
    );
}

#[test]
fn a_vertical_drag_on_a_horizontal_row_does_not_scroll_it() {
    let mut h = rail_harness(12);
    h.play(
        &Trace::new()
            .drag(10.0, 96.0, 8.0, (200.0, 100.0), (200.0, 200.0))
            .up(110.0, 200.0, 200.0),
    );
    assert_eq!(offset(&h), 0.0);
    assert!(h.events.is_empty());
}

#[test]
fn a_fling_glides_and_the_poster_row_snaps_to_an_item_start() {
    let mut h = rail_harness(40);
    let step = 128.0;
    // 300 pt in 100 ms = 3000 pt/s release speed.
    h.play(
        &Trace::new()
            .drag(10.0, 100.0, 8.0, (360.0, ROW_Y), (60.0, ROW_Y))
            .up(110.0, 60.0, ROW_Y),
    );
    let mut last = offset(&h);
    let mut grew = true;
    for k in 1..=40 {
        h.advance_to(110.0 + f64::from(k) * 25.0);
        let o = offset(&h);
        grew &= o >= last - 1e-6;
        last = o;
    }
    assert!(grew, "the offset never goes back while gliding");
    h.advance_to(6000.0);
    let end = offset(&h);
    assert!(end > 400.0, "a fast flick travels far, got {end}");
    assert!(
        ((end / step).round() * step - end).abs() < 0.2,
        "ends on an item start, got {end}"
    );
    assert!(!h.ui.needs_frame(), "the loop pauses when everything rests");
}

#[test]
fn a_hundred_thousand_items_build_only_the_window() {
    let mut h = rail_harness(100_000);
    assert!(h.ui.built_items() <= 6, "got {}", h.ui.built_items());
    let list = h.frame_at(0.0);
    let images = list
        .quads()
        .iter()
        .filter(|q| q.kind == QuadKind::Image)
        .count();
    assert!(
        (3..=5).contains(&images),
        "three or four posters are visible, got {images}"
    );
    for k in 0..6 {
        let t = 6000.0 * f64::from(k);
        h.play(
            &Trace::new()
                .drag(t + 10.0, 80.0, 8.0, (380.0, ROW_Y), (20.0, ROW_Y))
                .up(t + 90.0, 20.0, ROW_Y),
        );
        h.advance_to(t + 5000.0);
    }
    assert!(offset(&h) > 2000.0, "got {}", offset(&h));
    assert!(h.ui.built_items() <= 8, "got {}", h.ui.built_items());
}

#[test]
fn pulling_past_the_start_follows_the_rubber_band_and_springs_back() {
    let mut h = rail_harness(12);
    h.play(&Trace::new().drag(10.0, 120.0, 8.0, (100.0, ROW_Y), (250.0, ROW_Y)));
    // 150 pt of finger in 10 pt samples, 20 pt hysteresis sample: 130 pt past the edge in a 390 pt viewport.
    let o = offset(&h);
    let expect = -rubber_band(130.0, 390.0);
    assert!((o - expect).abs() < 3.0, "expected about {expect}, got {o}");
    assert!(o > -130.0 * 0.7, "the band is harder than the finger");
    h.play(&Trace::new().up(135.0, 250.0, ROW_Y));
    h.advance_to(135.0 + 700.0);
    assert!(
        offset(&h).abs() < 0.5,
        "settled back at 0, got {}",
        offset(&h)
    );
}

#[test]
fn a_touch_during_a_fling_stops_it_without_a_jump_and_without_a_tap() {
    let mut h = rail_harness(40);
    h.play(
        &Trace::new()
            .drag(10.0, 100.0, 8.0, (360.0, ROW_Y), (60.0, ROW_Y))
            .up(110.0, 60.0, ROW_Y),
    );
    h.advance_to(300.0);
    let before = offset(&h);
    h.play(&Trace::new().down(300.0, 200.0, ROW_Y));
    let at_touch = offset(&h);
    assert!(
        (at_touch - before).abs() < 1.0,
        "frozen where it was: {before} vs {at_touch}"
    );
    h.advance_to(500.0);
    assert!((offset(&h) - at_touch).abs() < 1e-6, "no more movement");
    h.play(&Trace::new().up(520.0, 200.0, ROW_Y));
    assert!(
        h.events.iter().all(|e| !matches!(e, UiEvent::Tap(_))),
        "{:?}",
        h.events
    );
}

#[test]
fn press_inside_a_scroll_view_shows_after_150_ms_and_outside_on_the_first_frame() {
    let mut rail = rail_harness(12);
    rail.play(&Trace::new().down(10.0, 60.0, ROW_Y));
    rail.advance_to(60.0);
    let v = rail.ui.node_values(0_usize).expect("tile 0");
    assert_eq!(v.scale, 1.0, "50 ms in: not shown yet");
    rail.advance_to(170.0);
    let v = rail.ui.node_values(0_usize).expect("tile 0");
    assert!(
        (v.scale - 0.97).abs() < 1e-9 && (v.opacity - 0.85).abs() < 1e-9,
        "{v:?}"
    );

    let mut b = button_harness(false);
    b.play(&Trace::new().down(10.0, 60.0, 50.0));
    let _ = b.frame_at(10.0 + 1000.0 / 120.0);
    let v = b.ui.node_values("play").expect("button");
    assert!(
        (v.scale - 0.97).abs() < 1e-9 && (v.opacity - 0.85).abs() < 1e-9,
        "first frame: {v:?}"
    );
}

#[test]
fn moving_more_than_ten_points_cancels_the_press() {
    let mut b = button_harness(false);
    b.play(
        &Trace::new()
            .down(10.0, 60.0, 50.0)
            .move_to(30.0, 75.0, 50.0),
    );
    b.advance_to(30.0 + 130.0);
    let v = b.ui.node_values("play").expect("button");
    assert!(
        (v.scale - 1.0).abs() < 1e-9 && !v.pressed,
        "released: {v:?}"
    );
    b.play(&Trace::new().up(200.0, 75.0, 50.0));
    assert!(b.events.is_empty(), "no tap after moving away");
}

#[test]
fn releasing_a_press_eases_out_in_120_ms() {
    let mut b = button_harness(false);
    b.play(&Trace::new().down(10.0, 60.0, 50.0).up(100.0, 60.0, 50.0));
    assert_eq!(b.events, vec![UiEvent::Tap(Action(7))]);
    b.advance_to(100.0 + 60.0);
    let mid = b.ui.node_values("play").expect("button").scale;
    assert!(mid > 0.97 && mid < 1.0, "halfway back, got {mid}");
    b.advance_to(100.0 + 130.0);
    assert_eq!(b.ui.node_values("play").expect("button").scale, 1.0);
}

#[test]
fn reduce_motion_makes_the_release_linear_over_140_ms() {
    let mut b = button_harness(true);
    b.play(&Trace::new().down(10.0, 60.0, 50.0).up(100.0, 60.0, 50.0));
    b.advance_to(100.0 + 70.0);
    let mid = b.ui.node_values("play").expect("button").scale;
    assert!(
        (mid - 0.985).abs() < 0.001,
        "linear midpoint of 0.97..1.0, got {mid}"
    );
    b.advance_to(100.0 + 145.0);
    assert_eq!(b.ui.node_values("play").expect("button").scale, 1.0);
}

#[test]
fn a_long_press_fires_after_half_a_second_and_cancels_the_tap() {
    let mut b = button_harness(false);
    // The grey block starts after the button (label width + 48 + gap 16); find it by tapping far right of the button.
    let x = 200.0;
    b.play(&Trace::new().down(10.0, x, 50.0));
    b.advance_to(400.0);
    assert!(b.events.is_empty());
    b.advance_to(520.0);
    assert_eq!(b.events, vec![UiEvent::LongPress(Action(9))]);
    b.play(&Trace::new().up(600.0, x, 50.0));
    assert_eq!(b.events.len(), 1, "no tap after the long press");
}

#[test]
fn an_edge_pan_begins_in_the_edge_strip_and_reports_progress() {
    let mut b = button_harness(false);
    b.play(
        &Trace::new()
            .drag(10.0, 120.0, 8.0, (4.0, 200.0), (124.0, 200.0))
            .up(130.0, 124.0, 200.0),
    );
    let pans: Vec<(Phase, f32)> = b
        .events
        .iter()
        .filter_map(|e| match e {
            UiEvent::EdgePan {
                phase, progress, ..
            } => Some((*phase, *progress)),
            _ => None,
        })
        .collect();
    assert_eq!(pans.first().map(|p| p.0), Some(Phase::Began));
    assert_eq!(pans.last().map(|p| p.0), Some(Phase::Ended));
    let end = pans.last().map_or(0.0, |p| p.1);
    assert!(
        (end - 120.0 / 390.0).abs() < 0.01,
        "progress is the share of the width, got {end}"
    );
    // The same drag from the middle of the screen is no edge pan.
    let mut c = button_harness(false);
    c.play(
        &Trace::new()
            .drag(10.0, 120.0, 8.0, (100.0, 200.0), (220.0, 200.0))
            .up(130.0, 220.0, 200.0),
    );
    assert!(
        c.events
            .iter()
            .all(|e| !matches!(e, UiEvent::EdgePan { .. }))
    );
}

#[test]
fn a_spring_driven_value_keeps_its_velocity_across_a_rebuild() {
    let mut h = rail_harness(12);
    let mut p = parts(12);
    p.flag = true;
    h.ui.set_parts(p.clone());
    h.advance_to(100.0);
    let mid = h.ui.node_values("marker").expect("marker").scale;
    assert!(mid > 1.0 && mid < 1.5, "springing, got {mid}");
    let n = h.ui.state_count();
    p.title = "Anders".into();
    h.ui.set_parts(p);
    assert_eq!(h.ui.state_count(), n, "same identities, same states");
    let after = h.ui.node_values("marker").expect("marker").scale;
    assert!(
        (after - mid).abs() < 1e-9,
        "the rebuild does not reset the spring"
    );
    h.advance_to(110.0);
    let later = h.ui.node_values("marker").expect("marker").scale;
    assert!(later > mid, "still moving toward 1.5");
    h.advance_to(2000.0);
    assert!((h.ui.node_values("marker").expect("marker").scale - 1.5).abs() < 1e-6);
}

#[test]
fn the_scroll_offset_survives_a_rebuild() {
    let mut h = rail_harness(40);
    h.play(&Trace::new().drag(10.0, 96.0, 8.0, (300.0, ROW_Y), (200.0, ROW_Y)));
    let o = offset(&h);
    let mut p = parts(40);
    p.title = "Anders".into();
    h.ui.set_parts(p);
    assert_eq!(offset(&h), o);
}

#[test]
fn the_draw_list_of_the_rail_at_rest_has_the_ground_posters_edges_and_glyphs() {
    let mut h = rail_harness(12);
    let list = h.frame_at(0.0);
    let q = list.quads();
    assert_eq!(q[0].kind, QuadKind::Shape, "the ground comes first");
    assert_eq!((q[0].rect.w, q[0].rect.h), (390.0, 400.0));
    let posters: Vec<_> = q.iter().filter(|q| q.kind == QuadKind::Image).collect();
    assert!(posters.len() >= 3);
    let p0 = posters[0];
    assert_eq!((p0.rect.x, p0.rect.w, p0.rect.h), (18.0, 116.0, 174.0));
    assert_eq!(p0.radii.tl, 10.0);
    assert_eq!(posters[1].rect.x, 18.0 + 128.0, "tile pitch is 116 + 12");
    let edges = q
        .iter()
        .filter(|q| q.kind == QuadKind::Shape && q.border_width == 1.0)
        .count();
    assert_eq!(edges, posters.len(), "one 1 pt edge per poster");
    assert!(
        q.iter().any(|q| q.kind == QuadKind::Glyph),
        "titles are drawn"
    );
    assert!(
        q.iter().all(|q| q.opacity == 1.0),
        "nothing is faded at rest"
    );
}

#[test]
fn a_pressed_tile_is_drawn_smaller_and_faded() {
    let mut h = rail_harness(12);
    let rest = h.frame_at(0.0);
    let p_rest = rest
        .quads()
        .iter()
        .find(|q| q.kind == QuadKind::Image)
        .map(|q| q.rect);
    h.play(&Trace::new().down(100.0, 60.0, ROW_Y));
    let list = h.frame_at(300.0);
    let img = list
        .quads()
        .iter()
        .find(|q| q.kind == QuadKind::Image)
        .expect("poster");
    let r = p_rest.expect("poster at rest");
    // Edges snap to device pixels, so the width is the 0.97 scale within one pixel.
    assert!((img.rect.w - r.w * 0.97).abs() <= 1.0);
    assert!((img.opacity - 0.85).abs() < 1e-6);
}

#[test]
fn size_classes_follow_the_research_table() {
    use swiftly_layout::Size;
    use swiftly_ui::SizeClass::{Compact, Regular};
    assert_eq!(
        classes(Size::new(390.0, 844.0), Idiom::Phone, 390.0),
        (Compact, Regular)
    );
    assert_eq!(
        classes(Size::new(932.0, 430.0), Idiom::Phone, 932.0),
        (Regular, Compact),
        "Pro Max landscape"
    );
    assert_eq!(
        classes(Size::new(852.0, 393.0), Idiom::Phone, 852.0),
        (Compact, Compact),
        "iPhone 15 landscape"
    );
    assert_eq!(
        classes(Size::new(320.0, 1024.0), Idiom::Pad, 1024.0).0,
        Compact,
        "a third split"
    );
    assert_eq!(
        classes(Size::new(1024.0, 768.0), Idiom::Pad, 1024.0),
        (Regular, Regular)
    );
}

#[test]
fn goldens_poster_rail_at_rest_mid_drag_and_mid_fling() {
    let clear = Color::new(0.0, 0.0, 0.0, 1.0);
    let rest = {
        let mut h = rail_harness(12);
        h.render_at(0.0, clear)
    };
    check_golden("rail_rest", &rest);
    let drag = {
        let mut h = rail_harness(12);
        h.play(&Trace::new().drag(10.0, 112.0, 8.0, (330.0, ROW_Y), (130.0, ROW_Y)));
        assert!(offset(&h) > 150.0);
        h.render_at(122.0, clear)
    };
    check_golden("rail_mid_drag", &drag);
    let fling = {
        let mut h = rail_harness(12);
        h.play(
            &Trace::new()
                .drag(10.0, 112.0, 8.0, (360.0, ROW_Y), (130.0, ROW_Y))
                .up(122.0, 130.0, ROW_Y),
        );
        h.advance_to(122.0 + 180.0);
        assert!(h.ui.needs_frame(), "still gliding");
        h.render_at(122.0 + 180.0, clear)
    };
    check_golden("rail_mid_fling", &fling);
}
