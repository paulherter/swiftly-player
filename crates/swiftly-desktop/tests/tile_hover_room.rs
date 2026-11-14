//! A tile of a sideways row grows on hover (the Mac scales the picture to 1.04); the row must leave room for it. Before the
//! row padded its content, the grown picture was cut off at the top by the row's own clip.

use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_render::QuadKind;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

#[test]
fn a_hovered_similar_tile_is_not_cut_by_its_row() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.5, Idiom::Desktop);
    let mut s = DetailScreen::new(env, Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    let _ = s.frame(0.0);
    s.open(0.0);
    for _ in 0..90 {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    // Scroll the page until the similar row is on screen.
    let mut tile = s.frame_of("similar:1");
    for _ in 0..80 {
        if tile.is_some_and(|t| t[1] > 120.0 && t[1] + t[3] < 760.0) {
            break;
        }
        s.wheel_scroll(640.0, 400.0, 0.0, 120.0, now);
        for _ in 0..12 {
            now += FRAME_MS;
            let _ = s.frame(now);
        }
        tile = s.frame_of("similar:1");
    }
    let t = tile.expect("the similar row has tiles");
    assert!(t[1] > 120.0 && t[1] + t[3] < 760.0, "row on screen: {t:?}");
    s.pointer_move(t[0] + t[2] / 2.0, t[1] + 40.0, now);
    for _ in 0..40 {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    let (list, _) = s.frame(now + FRAME_MS);
    let grown: Vec<_> = list
        .quads()
        .iter()
        .filter(|q| {
            q.kind == QuadKind::Image
                && (q.rect.x + q.rect.w / 2.0 - (t[0] + t[2] / 2.0)).abs() < 3.0
                && q.rect.w > t[2] * 1.02
                && q.rect.w < t[2] * 1.07
        })
        .collect();
    assert!(!grown.is_empty(), "the hovered picture grew past {t:?}");
    for q in grown {
        assert!(
            q.rect.y >= q.clip[1] - 0.01 && q.rect.max_y() <= q.clip[3] + 0.01,
            "grown picture {:?} is cut by its clip {:?}",
            q.rect,
            q.clip
        );
    }
}
