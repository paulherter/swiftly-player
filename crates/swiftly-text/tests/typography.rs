// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Mac typography rules: `monospacedDigit()` (tabular figures) and `lineSpacing(n)` (metrics plus points).

use swiftly_text::{Align, FontSystem, LineHeight, TextStyle};

fn width(fonts: &mut FontSystem, s: &str, style: &TextStyle) -> f32 {
    fonts.layout(s, style, None, None, Align::Start).width()
}

#[test]
fn tabular_figures_give_every_digit_the_same_advance() {
    let mut fonts = FontSystem::bundled_only();
    let plain = TextStyle::new(15.0, 400);
    let tab = plain.with_tabular();
    let (a, b) = (
        width(&mut fonts, "1111", &plain),
        width(&mut fonts, "0000", &plain),
    );
    assert!(
        (a - b).abs() > 0.5,
        "proportional digits differ: {a} vs {b}"
    );
    let (a, b) = (
        width(&mut fonts, "1111", &tab),
        width(&mut fonts, "0000", &tab),
    );
    assert!((a - b).abs() < 0.01, "tabular digits are equal: {a} vs {b}");
    let (a, b) = (
        width(&mut fonts, "12:08", &tab),
        width(&mut fonts, "00:00", &tab),
    );
    assert!((a - b).abs() < 0.01, "a clock does not jitter: {a} vs {b}");
}

#[test]
fn line_spacing_adds_points_to_the_font_height() {
    let mut fonts = FontSystem::bundled_only();
    let base = TextStyle::new(17.0, 400);
    let h0 = fonts
        .layout("Zeile", &base, Some(200.0), None, Align::Start)
        .height();
    // SwiftUI at 17 pt: 20.569 pt (Inter 1.21 em), see crates/swiftly-text/NOTES.md.
    assert!((h0 - 20.569).abs() < 0.05, "natural height {h0}");
    for extra in [2.0, 3.0, 4.5] {
        let s = base.with_line_spacing(extra);
        assert_eq!(s.line_height, LineHeight::MetricsPlus(extra));
        let h = fonts
            .layout("Zeile", &s, Some(200.0), None, Align::Start)
            .height();
        assert!(
            (h - (h0 + extra)).abs() < 0.05,
            "{extra}: {h} vs {}",
            h0 + extra
        );
    }
}
