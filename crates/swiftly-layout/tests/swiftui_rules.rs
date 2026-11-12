//! Unit tests that reproduce SwiftUI's documented layout behaviour. Each test name carries the rule it checks:
//! `apple_*` is stated in Apple's documentation, `objc_*` is the reverse-engineered behaviour (objc.io, community).

use swiftly_layout::{
    AdaptiveGrid, Align, Alignment, Axes, Axis, ContentMode, EdgeInsets, FlexFrame, Items,
    LazyStack, Node, Proposal, Rect, Size, adaptive_columns, layout, size_that_fits,
};

/// A text stand-in: one line of `ideal_w` x `line_h`; wraps to fit a proposed width but never narrower than 20.
fn text(ideal_w: f32, line_h: f32) -> Node {
    Node::measured(move |p| match p.w {
        None => Size::new(ideal_w, line_h),
        Some(w) if w >= ideal_w => Size::new(ideal_w, line_h),
        Some(w) => {
            let w = w.max(20.0);
            Size::new(w, (ideal_w / w).ceil() * line_h)
        }
    })
}

fn hstack(spacing: f32, kids: Vec<Node>) -> Node {
    Node::hstack(Align::Center, Some(spacing), kids)
}

fn vstack(align: Align, spacing: f32, kids: Vec<Node>) -> Node {
    Node::vstack(align, Some(spacing), kids)
}

fn near(a: f32, b: f32) -> bool {
    (a - b).abs() < 0.01
}

#[test]
fn apple_stack_with_nil_proposal_is_as_big_as_the_ideal_sizes_together() {
    let s = size_that_fits(
        &hstack(10.0, vec![Node::fixed(50.0, 20.0), text(100.0, 18.0)]),
        Proposal::NIL,
    );
    assert_eq!(s, Size::new(160.0, 20.0));
}

#[test]
fn objc_hstack_flexible_child_takes_what_the_fixed_child_leaves() {
    let p = layout(
        &hstack(0.0, vec![Node::fixed(100.0, 40.0), Node::flexible()]),
        Size::new(300.0, 40.0),
    );
    assert!(near(p.children[0].frame.w, 100.0));
    assert!(near(p.children[1].frame.w, 200.0));
    assert!(near(p.children[1].frame.x, 100.0));
}

#[test]
fn objc_hstack_two_flexible_children_split_the_width_after_the_spacing() {
    let p = layout(
        &hstack(10.0, vec![Node::flexible(), Node::flexible()]),
        Size::new(300.0, 40.0),
    );
    assert!(near(p.children[0].frame.w, 145.0));
    assert!(near(p.children[1].frame.w, 145.0));
    assert!(near(p.children[1].frame.x, 155.0));
}

#[test]
fn objc_hstack_offers_space_to_the_least_flexible_child_first() {
    // The fixed-width label is asked first and keeps its 30 pt, so the long text can use all the rest and wraps at 270.
    let p = layout(
        &hstack(0.0, vec![text(400.0, 20.0), Node::fixed(30.0, 20.0)]),
        Size::new(300.0, 100.0),
    );
    assert!(near(p.children[1].frame.w, 30.0));
    assert!(near(p.children[0].frame.w, 270.0));
}

#[test]
fn objc_hstack_gives_a_short_text_its_ideal_width_and_the_rest_to_the_rectangle() {
    let p = layout(
        &hstack(0.0, vec![Node::flexible(), text(60.0, 20.0)]),
        Size::new(300.0, 20.0),
    );
    assert!(near(p.children[1].frame.w, 60.0));
    assert!(near(p.children[0].frame.w, 240.0));
}

#[test]
fn apple_spacer_expands_along_the_stack_axis() {
    let p = layout(
        &hstack(
            0.0,
            vec![
                Node::fixed(50.0, 20.0),
                Node::spacer_min(0.0),
                Node::fixed(50.0, 20.0),
            ],
        ),
        Size::new(300.0, 20.0),
    );
    assert!(near(p.children[1].frame.w, 200.0));
    assert!(near(p.children[2].frame.x, 250.0));
    assert!(near(p.children[1].frame.h, 0.0));
}

#[test]
fn apple_spacer_in_a_vstack_expands_vertically() {
    let p = layout(
        &vstack(
            Align::Center,
            0.0,
            vec![
                Node::fixed(50.0, 20.0),
                Node::spacer_min(0.0),
                Node::fixed(50.0, 20.0),
            ],
        ),
        Size::new(100.0, 300.0),
    );
    assert!(near(p.children[1].frame.h, 260.0));
    assert!(near(p.children[2].frame.y, 280.0));
}

#[test]
fn apple_spacer_min_length_is_never_undercut() {
    let s = size_that_fits(
        &hstack(
            0.0,
            vec![
                Node::fixed(50.0, 20.0),
                Node::spacer_min(30.0),
                Node::fixed(50.0, 20.0),
            ],
        ),
        Proposal::value(Size::new(100.0, 20.0)),
    );
    assert!(near(s.w, 130.0));
}

#[test]
fn apple_two_spacers_share_the_room_equally() {
    let p = layout(
        &hstack(
            0.0,
            vec![
                Node::spacer_min(0.0),
                Node::fixed(40.0, 10.0),
                Node::spacer_min(0.0),
            ],
        ),
        Size::new(240.0, 10.0),
    );
    assert!(near(p.children[1].frame.x, 100.0));
}

#[test]
fn apple_spacer_outside_a_stack_expands_on_both_axes() {
    let s = size_that_fits(
        &Node::spacer_min(0.0),
        Proposal::value(Size::new(100.0, 50.0)),
    );
    assert_eq!(s, Size::new(100.0, 50.0));
}

#[test]
fn apple_layout_priority_lets_the_higher_priority_view_claim_space_first() {
    let kids = |prio: f32| vec![text(200.0, 20.0), text(200.0, 20.0).layout_priority(prio)];
    let even = layout(&hstack(0.0, kids(0.0)), Size::new(300.0, 100.0));
    assert!(
        near(even.children[0].frame.w, 150.0),
        "same priority: equal shares"
    );
    let first = layout(&hstack(0.0, kids(1.0)), Size::new(300.0, 100.0));
    assert!(
        near(first.children[1].frame.w, 200.0),
        "priority 1 keeps its ideal width"
    );
    assert!(
        near(first.children[0].frame.w, 100.0),
        "the other one wraps in the rest"
    );
}

#[test]
fn apple_vstack_aligns_children_on_the_cross_axis_and_applies_spacing() {
    let p = layout(
        &vstack(
            Align::End,
            6.0,
            vec![Node::fixed(30.0, 10.0), Node::fixed(80.0, 10.0)],
        ),
        Size::new(200.0, 100.0),
    );
    // The stack is 80 x 26, centered in the 200 x 100 container.
    assert!(near(p.frame.x, 60.0) && near(p.frame.y, 37.0));
    assert!(
        near(p.children[0].frame.x, 50.0),
        "trailing aligned in the 80 pt column"
    );
    assert!(near(p.children[1].frame.y, 16.0), "10 + spacing 6");
}

#[test]
fn apple_zstack_is_as_big_as_its_biggest_child_and_aligns_the_rest() {
    let z = Node::zstack(
        Alignment::BOTTOM_TRAILING,
        vec![Node::fixed(100.0, 60.0), Node::fixed(20.0, 20.0)],
    );
    let p = layout(&z, Size::new(100.0, 60.0));
    assert_eq!(p.frame.size(), Size::new(100.0, 60.0));
    assert!(near(p.children[1].frame.x, 80.0) && near(p.children[1].frame.y, 40.0));
}

#[test]
fn apple_fixed_frame_reports_its_size_and_centers_the_child() {
    let n = Node::fixed(20.0, 20.0).frame(Some(100.0), Some(50.0), Alignment::CENTER);
    let p = layout(&n, Size::new(400.0, 400.0));
    assert_eq!(p.frame.size(), Size::new(100.0, 50.0));
    assert!(near(p.children[0].frame.x, 40.0) && near(p.children[0].frame.y, 15.0));
}

#[test]
fn apple_fixed_frame_alignment_top_leading() {
    let n = Node::fixed(20.0, 20.0).frame(Some(100.0), Some(50.0), Alignment::TOP_LEADING);
    let p = layout(&n, Size::new(100.0, 50.0));
    assert_eq!((p.children[0].frame.x, p.children[0].frame.y), (0.0, 0.0));
}

#[test]
fn apple_fixed_frame_proposes_its_length_to_the_child() {
    // A text in `frame(width: 50)` wraps at 50 although 400 is offered.
    let n = text(200.0, 20.0).frame(Some(50.0), None, Alignment::CENTER);
    let s = size_that_fits(&n, Proposal::value(Size::new(400.0, 400.0)));
    assert!(near(s.w, 50.0));
    assert!(near(s.h, 80.0), "200 / 50 = 4 lines of 20");
}

#[test]
fn objc_flexible_frame_with_infinite_max_width_is_as_wide_as_the_proposal() {
    let n = Node::fixed(30.0, 20.0).flex_frame(FlexFrame {
        max_w: Some(f32::INFINITY),
        ..FlexFrame::default()
    });
    let p = layout(&n, Size::new(300.0, 100.0));
    assert_eq!(p.frame.w, 300.0);
    assert_eq!(p.frame.h, 20.0, "height keeps the child's");
    assert!(near(p.children[0].frame.x, 135.0), "centered by default");
}

#[test]
fn apple_flexible_frame_maximum_caps_the_width() {
    let n = Node::flexible().flex_frame(FlexFrame {
        max_w: Some(200.0),
        ..FlexFrame::default()
    });
    assert_eq!(
        size_that_fits(&n, Proposal::value(Size::new(300.0, 50.0))).w,
        200.0
    );
    assert_eq!(
        size_that_fits(&n, Proposal::value(Size::new(120.0, 50.0))).w,
        120.0
    );
}

#[test]
fn apple_flexible_frame_minimum_height_raises_a_smaller_child() {
    let n = Node::fixed(60.0, 20.0).flex_frame(FlexFrame {
        min_h: Some(44.0),
        ..FlexFrame::default()
    });
    let s = size_that_fits(&n, Proposal::value(Size::new(300.0, 300.0)));
    assert_eq!(s, Size::new(60.0, 44.0));
}

#[test]
fn apple_flexible_frame_ideal_size_answers_a_nil_proposal() {
    let n = Node::flexible().flex_frame(FlexFrame {
        ideal_w: Some(120.0),
        ideal_h: Some(80.0),
        max_w: Some(f32::INFINITY),
        max_h: Some(f32::INFINITY),
        ..FlexFrame::default()
    });
    assert_eq!(size_that_fits(&n, Proposal::NIL), Size::new(120.0, 80.0));
}

#[test]
fn apple_padding_adds_the_insets_around_a_text() {
    let n = text(100.0, 20.0).padding(EdgeInsets::all(8.0));
    assert_eq!(size_that_fits(&n, Proposal::NIL), Size::new(116.0, 36.0));
    let p = layout(&n, Size::new(116.0, 36.0));
    assert_eq!((p.children[0].frame.x, p.children[0].frame.y), (8.0, 8.0));
}

#[test]
fn apple_padding_shrinks_the_proposal_so_the_text_wraps_inside() {
    // 60 offered, 16 taken by the padding: the 100 pt text wraps at 44 pt into 3 lines.
    let n = text(100.0, 20.0).padding(EdgeInsets::all(8.0));
    let s = size_that_fits(&n, Proposal::value(Size::new(60.0, 500.0)));
    assert!(near(s.w, 60.0));
    assert!(near(s.h, 3.0 * 20.0 + 16.0));
}

#[test]
fn apple_padding_leaves_a_zero_and_an_infinite_proposal_meaningful() {
    let n = Node::flexible().padding(EdgeInsets::symmetric(10.0, 5.0));
    assert_eq!(size_that_fits(&n, Proposal::ZERO), Size::new(20.0, 10.0));
    let inf = size_that_fits(&n, Proposal::INFINITY);
    assert!(inf.w.is_infinite() && inf.h.is_infinite());
}

#[test]
fn apple_background_and_overlay_take_the_size_of_the_primary_view() {
    let n = Node::fixed(100.0, 40.0)
        .background(Node::flexible(), Alignment::CENTER)
        .overlay(Node::fixed(10.0, 10.0), Alignment::BOTTOM_TRAILING);
    let p = layout(&n, Size::new(100.0, 40.0));
    assert_eq!(p.frame.size(), Size::new(100.0, 40.0));
    let bg = &p.children[0];
    assert_eq!(
        bg.children[1].frame.size(),
        Size::new(100.0, 40.0),
        "background is proposed the primary's size"
    );
    assert!(near(p.children[1].frame.x, 90.0) && near(p.children[1].frame.y, 30.0));
}

#[test]
fn apple_aspect_ratio_fit_stays_inside_the_proposal() {
    let n = Node::flexible().aspect_ratio(Some(16.0 / 9.0), ContentMode::Fit);
    let s = size_that_fits(&n, Proposal::value(Size::new(320.0, 320.0)));
    assert!(near(s.w, 320.0) && near(s.h, 180.0));
}

#[test]
fn apple_aspect_ratio_fill_covers_the_proposal() {
    let n = Node::flexible().aspect_ratio(Some(16.0 / 9.0), ContentMode::Fill);
    let s = size_that_fits(&n, Proposal::value(Size::new(320.0, 320.0)));
    assert!(near(s.h, 320.0) && near(s.w, 320.0 * 16.0 / 9.0));
}

#[test]
fn apple_aspect_ratio_with_one_open_axis_derives_it_from_the_ratio() {
    let n = Node::flexible().aspect_ratio(Some(2.0), ContentMode::Fit);
    assert_eq!(
        size_that_fits(&n, Proposal::new(Some(100.0), None)),
        Size::new(100.0, 50.0)
    );
    assert_eq!(
        size_that_fits(&n, Proposal::new(None, Some(30.0))),
        Size::new(60.0, 30.0)
    );
}

#[test]
fn apple_aspect_ratio_without_a_value_uses_the_ideal_size_of_the_content() {
    let n = Node::flexible()
        .frame(Some(200.0), Some(100.0), Alignment::CENTER)
        .aspect_ratio(None, ContentMode::Fit);
    let s = size_that_fits(&n, Proposal::value(Size::new(100.0, 100.0)));
    assert!(near(s.w, 100.0) && near(s.h, 50.0));
}

#[test]
fn apple_fixed_size_ignores_the_proposal_on_the_chosen_axes() {
    let n = text(200.0, 20.0).fixed_size(true, false);
    let s = size_that_fits(&n, Proposal::value(Size::new(50.0, 500.0)));
    assert_eq!(s, Size::new(200.0, 20.0));
    let both = text(200.0, 20.0).fixed_size(true, true);
    assert_eq!(
        size_that_fits(&both, Proposal::ZERO),
        Size::new(200.0, 20.0)
    );
}

fn picker() -> Node {
    Node::view_that_fits(
        Axes::HORIZONTAL,
        vec![
            Node::fixed(300.0, 40.0),
            Node::fixed(200.0, 40.0),
            Node::fixed(100.0, 40.0),
        ],
    )
}

#[test]
fn apple_view_that_fits_picks_the_first_child_that_fits() {
    let p = layout(&picker(), Size::new(250.0, 100.0));
    let shown: Vec<bool> = p.children.iter().map(|c| !c.hidden).collect();
    assert_eq!(
        shown,
        [false, true, false],
        "300 does not fit 250, 200 does"
    );
    let wide = layout(&picker(), Size::new(400.0, 100.0));
    assert!(
        !wide.children[0].hidden,
        "the first fits when there is room"
    );
}

#[test]
fn apple_view_that_fits_falls_back_to_the_last_child() {
    let p = layout(&picker(), Size::new(50.0, 100.0));
    let shown: Vec<bool> = p.children.iter().map(|c| !c.hidden).collect();
    assert_eq!(shown, [false, false, true]);
}

#[test]
fn apple_view_that_fits_tests_only_the_given_axes() {
    let v = Node::view_that_fits(
        Axes::VERTICAL,
        vec![Node::fixed(900.0, 300.0), Node::fixed(50.0, 50.0)],
    );
    // 900 wide would not fit 200, but only the height counts: 300 > 100 so the second is chosen; 400 allows the first.
    assert!(layout(&v, Size::new(200.0, 100.0)).children[0].hidden);
    assert!(!layout(&v, Size::new(200.0, 400.0)).children[0].hidden);
}

#[test]
fn apple_lazy_stack_takes_the_cross_axis_proposal_and_sums_the_main_axis() {
    let n = Node::lazy_stack(LazyStack {
        axis: Axis::Vertical,
        spacing: 10.0,
        items: Items::Uniform {
            count: 5,
            size: Size::new(100.0, 40.0),
        },
        inset_start: 0.0,
        inset_end: 0.0,
        align: Align::Start,
    });
    let s = size_that_fits(&n, Proposal::new(Some(320.0), None));
    assert_eq!(s, Size::new(320.0, 5.0 * 40.0 + 4.0 * 10.0));
}

#[test]
fn lazy_stack_windows_a_hundred_thousand_items_in_constant_time() {
    let stack = LazyStack {
        axis: Axis::Horizontal,
        spacing: 12.0,
        items: Items::Uniform {
            count: 100_000,
            size: Size::new(116.0, 220.0),
        },
        inset_start: 18.0,
        inset_end: 18.0,
        align: Align::Start,
    };
    let p = layout(&Node::lazy_stack(stack), Size::new(390.0, 220.0));
    let plan = p.lazy.as_ref().expect("a lazy node has a plan");
    assert_eq!(plan.count(), 100_000);
    assert!(near(
        plan.content_size().w,
        18.0 + 100_000.0 * 128.0 - 12.0 + 18.0
    ));
    let at = 50_000.0 * 128.0;
    let r = plan.visible(at, at + 390.0);
    assert!(
        r.len() <= 5,
        "only about 3 posters are on screen, got {}",
        r.len()
    );
    assert!(plan.item_frame(r.start).x <= at + 390.0 && plan.item_frame(r.end - 1).max_x() >= at);
    assert_eq!(plan.visible(0.0, 20.0), 0..1);
}

#[test]
fn lazy_stack_with_different_item_sizes_finds_the_window_by_prefix_sums() {
    let sizes: Vec<Size> = (0..1000)
        .map(|i| Size::new(100.0, 20.0 + (i % 3) as f32 * 10.0))
        .collect();
    let n = Node::lazy_stack(LazyStack {
        axis: Axis::Vertical,
        spacing: 0.0,
        items: Items::Sizes(sizes),
        inset_start: 0.0,
        inset_end: 0.0,
        align: Align::Start,
    });
    let p = layout(&n, Size::new(100.0, 400.0));
    let plan = p.lazy.as_ref().expect("plan");
    let r = plan.visible(5000.0, 5100.0);
    assert!(plan.item_frame(r.start).max_y() > 5000.0 && plan.item_frame(r.start).y <= 5000.0);
    assert!(
        plan.item_frame(r.end - 1).y < 5100.0
            && (r.end >= 1000 || plan.item_frame(r.end).y >= 5100.0)
    );
}

#[test]
fn adaptive_grid_columns_follow_floor_width_minus_margins_plus_gap_over_item_plus_gap() {
    // (390 - 36 + 12) / (116 + 12) = 2.86 -> 2; (430 - 36 + 12) / 128 = 3.17 -> 3; too narrow -> 1.
    assert_eq!(adaptive_columns(390.0, 18.0, 12.0, 116.0), 2);
    assert_eq!(adaptive_columns(430.0, 18.0, 12.0, 116.0), 3);
    assert_eq!(adaptive_columns(100.0, 18.0, 12.0, 116.0), 1);
    assert_eq!(adaptive_columns(1024.0, 36.0, 16.0, 150.0), 5);
}

#[test]
fn adaptive_grid_places_items_row_by_row_and_reports_the_content_height() {
    let g = Node::grid(AdaptiveGrid {
        count: 7,
        item: Size::new(116.0, 174.0),
        margin: 18.0,
        gap: 12.0,
        row_gap: 32.0,
        center: false,
    });
    let p = layout(&g, Size::new(430.0, 800.0));
    let plan = p.lazy.as_ref().expect("plan");
    assert_eq!(plan.columns(), 3);
    assert_eq!(
        plan.item_frame(4),
        Rect::new(18.0 + 128.0, 174.0 + 32.0, 116.0, 174.0)
    );
    assert!(
        near(plan.content_size().h, 3.0 * 174.0 + 2.0 * 32.0),
        "7 items in 3 columns = 3 rows"
    );
    assert_eq!(plan.visible(0.0, 100.0), 0..3, "first row only");
    assert_eq!(plan.visible(300.0, 500.0), 3..7);
}

#[test]
fn apple_scroll_view_offers_its_content_the_viewport_across_and_reports_the_content_size() {
    let content = vstack(
        Align::Start,
        0.0,
        (0..20).map(|_| Node::fixed(50.0, 50.0)).collect(),
    );
    let p = layout(
        &Node::scroll(Axis::Vertical, content),
        Size::new(390.0, 800.0),
    );
    assert_eq!(
        p.frame.size(),
        Size::new(390.0, 800.0),
        "takes the offered space"
    );
    assert_eq!(p.content, Some(Size::new(50.0, 1000.0)));
    assert_eq!(p.children[0].frame.y, 0.0);
}

#[test]
fn scroll_view_with_a_lazy_row_reports_the_row_length_as_content_width() {
    let row = Node::lazy_stack(LazyStack {
        axis: Axis::Horizontal,
        spacing: 12.0,
        items: Items::Uniform {
            count: 10,
            size: Size::new(116.0, 220.0),
        },
        inset_start: 18.0,
        inset_end: 18.0,
        align: Align::Start,
    });
    let p = layout(
        &Node::scroll(Axis::Horizontal, row),
        Size::new(390.0, 220.0),
    );
    let c = p.content.expect("content size");
    assert!(near(c.w, 18.0 + 10.0 * 116.0 + 9.0 * 12.0 + 18.0));
    assert!(near(c.h, 220.0), "cross axis is the viewport height");
}

#[test]
fn deep_nesting_stays_fast_because_answers_are_memoised() {
    let mut n = Node::fixed(10.0, 10.0);
    for _ in 0..22 {
        n = hstack(2.0, vec![n, Node::flexible()]);
    }
    let p = layout(&n, Size::new(500.0, 50.0));
    assert!(p.frame.w > 0.0);
}
