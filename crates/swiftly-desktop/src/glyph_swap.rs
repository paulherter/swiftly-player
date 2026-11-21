//! The play/pause glyph of the centre row (`SymbolEffect.replace.offUp`, `PlayerScreen.swift:2222`): the old glyph is
//! gone at once, the new one comes in over the catalogue's `SymbolReplace` curve.

use swiftly_ui::Node;

/// Scale the new glyph starts from.
pub const START_SCALE: f32 = 0.7;
/// Opacity the new glyph starts from. The old glyph is removed at once, so a start at 0 left the button empty: the curve
/// stays at 0 for the first 33 ms and is at 0.38 after 50 ms (measured with the test below). The Mac shows a glyph in
/// the frame of the key press, so the new one starts half visible and is whole after 0.2 s.
pub const START_OPACITY: f32 = 0.5;

/// The curve of the swap, in one place.
pub fn motion() -> swiftly_ui::Motion {
    swiftly_ui::feel::of(swiftly_motion::catalogue::Id::SymbolReplace)
}

/// `glyph` as the centre button's picture: keyed by what it shows, so a swap is a new node that grows in.
pub fn replace(glyph: Node, playing: bool) -> Node {
    glyph
        .key(if playing { "glyph-pause" } else { "glyph-play" })
        .scaled(1.0, motion())
        .appear_from(START_SCALE, START_OPACITY)
        .opacity(1.0, motion())
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_layout::Alignment;
    use swiftly_render::{Color, QuadKind};
    use swiftly_ui::{Cx, Env, Idiom, Ui};

    fn glyph_opacity(list: &swiftly_render::DrawList) -> f32 {
        list.quads()
            .iter()
            .filter(|q| q.kind == QuadKind::Shape && q.rect.w > 20.0 && q.rect.w < 41.0)
            .map(|q| q.opacity)
            .fold(0.0, f32::max)
    }

    /// Opacity of the centre glyph at each of `ms` after the film was paused (0 is the frame drawn at the key).
    fn after_pause(ms: &[u32]) -> Vec<(u32, f32)> {
        let view = |playing: &bool, _: &Env, _: &Cx| {
            let stand_in = Node::rect(Color::new(1.0, 1.0, 1.0, 1.0), 4.0).frame(
                Some(40.0),
                Some(40.0),
                Alignment::CENTER,
            );
            Node::zstack(Alignment::CENTER, vec![replace(stand_in, *playing)]).frame(
                Some(400.0),
                Some(300.0),
                Alignment::CENTER,
            )
        };
        let env = Env::new(swiftly_layout::Size::new(400.0, 300.0), 1.0, Idiom::Desktop);
        let mut u = Ui::new(view, true, env, Cx::deterministic());
        let _ = u.frame(1000.0);
        let _ = u.frame(1100.0);
        u.set_parts(false);
        ms.iter()
            .map(|&t| (t, glyph_opacity(&u.frame(1100.0 + f64::from(t)))))
            .collect()
    }

    #[test]
    fn the_button_is_never_empty_after_a_pause() {
        let row = after_pause(&[0, 8, 16, 33, 50, 100, 200, 400]);
        assert!(
            row[0].1 >= 0.5,
            "the frame of the key press shows the new glyph: {row:?}"
        );
        assert!(
            row.windows(2).all(|w| w[1].1 >= w[0].1 - 1e-6),
            "the glyph only grows: {row:?}"
        );
        assert!(row[6].1 > 0.999, "whole after 200 ms: {row:?}");
    }
}
