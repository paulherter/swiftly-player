//! The saved subtitle look (`utAussehen`) as the numbers the engine draws with. One mapping for Windows and Linux:
//! the text is `picture height * 0.0625 * 0.78 * size step` tall (the Apple overlay's rule), the outline is a share
//! of the text, the bottom margin is 16 points plus 7 % of the height when raised.

use swiftly_playback::engine::SubtitleTextStyle;
use swiftly_support::subtitle::{Position, SubtitleLook, base_scale};

/// The family libass finds in the bundled `Inter-SemiBold.ttf` (the same file the Apple apps ship).
pub const FONT: &str = "Inter 18pt SemiBold";

/// The height in points of the picture on screen: the source (aspect `source`, if known) fitted into a window of
/// `window` points; the whole window height when the source is not known yet. Letterbox bars are not part of it.
pub fn picture_pt(window: (f32, f32), source: Option<(u32, u32)>) -> f64 {
    let (w, h) = (f64::from(window.0.max(1.0)), f64::from(window.1.max(1.0)));
    match source {
        Some((sw, sh)) if sw > 0 && sh > 0 => h.min(w * f64::from(sh) / f64::from(sw)),
        _ => h,
    }
}

/// The look the engine draws. `picture_pt` is the picture's height in points ([`picture_pt`]): the 16 point margin
/// is measured above the picture's bottom edge at the window's UI scale.
pub fn style_of(look: &SubtitleLook, picture_pt: f64) -> SubtitleTextStyle {
    SubtitleTextStyle {
        font: FONT.to_owned(),
        text_share: base_scale::PICTURE_SHARE * look.text_scale_percent(base_scale::DESKTOP) as f64
            / 100.0,
        colour: look.colour.rgb(),
        outline_em: look.outline.thickness() as f64 / 100.0,
        shadow: look.shadow,
        background: look.background,
        margin_px: 16.0,
        picture_pt,
        margin_share: if look.position == Position::Raised {
            0.07
        } else {
            0.0
        },
        keep_file_style: look.keep_file_style,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_support::subtitle::{Colour, Outline, Size};

    #[test]
    fn the_default_look_is_the_apple_default() {
        let s = style_of(&SubtitleLook::STANDARD, 0.0);
        assert!((s.text_share - 0.0625 * 0.78).abs() < 1e-9);
        assert_eq!(
            (
                s.colour,
                s.outline_em,
                s.shadow,
                s.background,
                s.margin_share
            ),
            (0xFFFFFF, 0.03, false, false, 0.0)
        );
        assert!(s.keep_file_style);
    }

    #[test]
    fn every_field_of_the_look_reaches_the_style() {
        let look = SubtitleLook {
            size: Size::Huge,
            colour: Colour::Yellow,
            outline: Outline::Thin,
            shadow: true,
            background: true,
            position: Position::Raised,
            keep_file_style: false,
        };
        let s = style_of(&look, 0.0);
        assert!(
            (s.text_share - 0.0625 * 1.13).abs() < 1e-9,
            "113 percent on the desktop base: {}",
            s.text_share
        );
        assert_eq!(
            (s.colour, s.outline_em, s.shadow, s.background),
            (0xFFE45C, 0.02, true, true)
        );
        assert_eq!(
            (s.margin_px, s.margin_share, s.keep_file_style),
            (16.0, 0.07, false)
        );
    }

    #[test]
    fn the_picture_height_is_the_fitted_source_in_points() {
        assert_eq!(picture_pt((1280.0, 720.0), None), 720.0);
        assert_eq!(picture_pt((1280.0, 720.0), Some((1920, 1080))), 720.0);
        // 2.39:1 in a 16:9 window: bars above and below, the picture is 1280 / 2.39 tall.
        assert!((picture_pt((1280.0, 720.0), Some((1912, 800))) - 535.6).abs() < 0.1);
        // A tall window: the picture is as wide as the window.
        assert_eq!(picture_pt((500.0, 2000.0), Some((1000, 500))), 250.0);
        assert_eq!(style_of(&SubtitleLook::STANDARD, 535.6).picture_pt, 535.6);
    }
}
