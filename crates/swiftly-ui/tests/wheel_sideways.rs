//! A wheel that only turns up and down moves a horizontal scroll view with no vertical one around it (the player's episode
//! strip); with a vertical one under the pointer the wheel still scrolls that.

use swiftly_layout::{Align, Alignment, Axis, Size};
use swiftly_render::Color;
use swiftly_ui::{Cx, Env, Idiom, Node, Ui};

#[derive(Clone, PartialEq)]
struct Scene {
    with_page: bool,
}

fn strip() -> Node {
    let wide = Node::hstack(
        Align::Start,
        Some(10.0),
        (0..10)
            .map(|_| {
                Node::rect(Color::new(0.2, 0.3, 0.5, 1.0), 0.0).frame(
                    Some(100.0),
                    Some(80.0),
                    Alignment::TOP_LEADING,
                )
            })
            .collect(),
    );
    Node::scroll(Axis::Horizontal, None, wide).frame(
        Some(300.0),
        Some(80.0),
        Alignment::TOP_LEADING,
    )
}

fn view(scene: &Scene, env: &Env, _cx: &Cx) -> Node {
    let body = if scene.with_page {
        let page = Node::vstack(
            Align::Start,
            Some(0.0),
            vec![
                strip(),
                Node::rect(Color::new(0.5, 0.3, 0.2, 1.0), 0.0).frame(
                    Some(300.0),
                    Some(2000.0),
                    Alignment::TOP_LEADING,
                ),
            ],
        );
        Node::scroll(Axis::Vertical, None, page).frame(
            Some(300.0),
            Some(300.0),
            Alignment::TOP_LEADING,
        )
    } else {
        strip()
    };
    Node::zstack(Alignment::TOP_LEADING, vec![body]).frame(
        Some(env.size.w),
        Some(env.size.h),
        Alignment::TOP_LEADING,
    )
}

fn ui(with_page: bool) -> Ui<Scene> {
    let env = Env::new(Size::new(400.0, 400.0), 1.0, Idiom::Desktop);
    Ui::new(view, Scene { with_page }, env, Cx::deterministic())
}

#[test]
fn a_vertical_wheel_moves_a_horizontal_strip_sideways() {
    let mut u = ui(false);
    let _ = u.frame(0.0);
    assert!(
        u.wheel_scroll(100.0, 40.0, 0.0, 120.0, 10.0),
        "the strip takes the notch"
    );
    assert!(u.scroll_offsets()[0] > 0.0, "{:?}", u.scroll_offsets());
    // And the other way back.
    let before = u.scroll_offsets()[0];
    assert!(u.wheel_scroll(100.0, 40.0, 0.0, -60.0, 20.0));
    assert!(u.scroll_offsets()[0] < before);
}

#[test]
fn a_vertical_page_around_the_strip_still_gets_the_wheel() {
    let mut u = ui(true);
    let _ = u.frame(0.0);
    assert!(u.wheel_scroll(100.0, 40.0, 0.0, 120.0, 10.0));
    let offsets = u.scroll_offsets();
    // Offsets are in tree order: the page first, then the strip.
    assert!(offsets[0] > 0.0, "the page scrolled: {offsets:?}");
    assert_eq!(offsets.get(1).copied().unwrap_or(0.0), 0.0, "{offsets:?}");
}
