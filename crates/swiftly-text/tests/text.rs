// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Golden images through the software renderer, plus measurement tests.
//!
//! `UPDATE_GOLDENS=1 cargo test -p swiftly-text` rewrites `tests/golden/*.png`. The Latin goldens use only the
//! bundled Inter and are machine independent. The Arabic and Japanese goldens depend on the system fonts of the
//! Mac they were made on: they are compared on macOS only and skip with a note when no fallback font exists.

use std::path::PathBuf;

use swiftly_design::tokens::{colour, touch};
use swiftly_render::{Color, DrawList, RgbaImage, SoftwareRenderer, Sources};
use swiftly_text::{Align, FontSystem, GlyphAtlas, TextLayout, TextStyle};

fn c(x: swiftly_design::Colour) -> Color {
    Color::new(x.r, x.g, x.b, x.a)
}

fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.png"))
}

/// Compares with the golden; text edges are float math in swash, so a few levels of difference are allowed.
fn check_golden(name: &str, img: &RgbaImage) {
    let path = golden_path(name);
    if std::env::var_os("UPDATE_GOLDENS").is_some() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path)
        .unwrap_or_else(|e| panic!("golden {name}: {e} (run with UPDATE_GOLDENS=1)"));
    let (max, share) = img.diff(&golden);
    println!(
        "golden {name}: max diff {max}, differing pixels {:.4} %",
        share * 100.0
    );
    assert!(
        max <= 3 && share < 0.01,
        "golden {name} differs by {max} on {:.3} % of pixels",
        share * 100.0
    );
}

struct Canvas {
    list: DrawList,
    atlas: GlyphAtlas,
    y: f32,
}

impl Canvas {
    fn new(w: f32, h: f32, scale: f32) -> Canvas {
        let mut atlas = GlyphAtlas::new(1024);
        atlas.begin_frame();
        Canvas {
            list: DrawList::new(w, h, scale),
            atlas,
            y: 8.0,
        }
    }

    /// Draws a layout at the left margin and moves down.
    fn put(&mut self, t: &TextLayout, x: f32) {
        self.atlas
            .draw(t, &mut self.list, x, self.y, c(colour::FONT));
        self.y += t.height() + 6.0;
    }

    fn render(&self, name: &str) -> RgbaImage {
        let src = Sources {
            glyphs: Some(&self.atlas),
            images: None,
        };
        let img = SoftwareRenderer::render(&self.list, c(colour::AREA), &src);
        check_golden(name, &img);
        img
    }
}

fn ink(img: &RgbaImage) -> usize {
    let bg = img.pixel(0, 0);
    (0..img.height)
        .flat_map(|y| (0..img.width).map(move |x| (x, y)))
        .filter(|(x, y)| img.pixel(*x, *y) != bg)
        .count()
}

#[test]
fn latin_title_in_every_weight_of_the_ladder() {
    let mut fonts = FontSystem::bundled_only();
    let mut cv = Canvas::new(330.0, 330.0, 2.0);
    for w in [400u16, 500, 600, 700, 800] {
        let t = fonts.layout(
            "Frieren: Beyond Journey",
            &TextStyle::new(22.0, w),
            None,
            None,
            Align::Start,
        );
        cv.put(&t, 10.0);
    }
    for style in [
        touch::text::TITLE_LARGE,
        touch::text::RAIL,
        touch::text::GROUP,
        touch::text::BADGE,
    ] {
        let t = fonts.layout("Swiftly Player", &style.into(), None, None, Align::Start);
        cv.put(&t, 10.0);
    }
    let img = cv.render("ladder_weights");
    assert!(ink(&img) > 2000, "text was drawn");
}

#[test]
fn german_umlauts() {
    let mut fonts = FontSystem::bundled_only();
    let mut cv = Canvas::new(300.0, 90.0, 2.0);
    let a = fonts.layout(
        "Größe, Übergänge und Ärger",
        &touch::text::CATEGORY.into(),
        None,
        None,
        Align::Start,
    );
    assert_eq!(a.missing_glyphs(), 0);
    cv.put(&a, 10.0);
    let b = fonts.layout(
        "Äpfel öffnen für Müßiggänger",
        &touch::text::BODY.into(),
        None,
        None,
        Align::Start,
    );
    assert_eq!(b.missing_glyphs(), 0);
    cv.put(&b, 10.0);
    cv.render("german_umlauts");
}

#[test]
fn arabic_and_hebrew() {
    let mut fonts = FontSystem::new();
    let t = fonts.layout(
        "مرحبا بكم في تطبيق سويفتلي",
        &touch::text::CATEGORY.into(),
        None,
        None,
        Align::Start,
    );
    if t.missing_glyphs() > 0 {
        println!("SKIP arabic: no fallback font on this machine");
        return;
    }
    assert!(t.is_rtl(), "the paragraph runs right to left");
    let h = fonts.layout(
        "שלום עולם",
        &touch::text::CATEGORY.into(),
        None,
        None,
        Align::Start,
    );
    let mut cv = Canvas::new(300.0, 90.0, 2.0);
    cv.put(&t, 10.0);
    if h.missing_glyphs() == 0 {
        cv.put(&h, 10.0);
    } else {
        println!("note: no Hebrew fallback font");
    }
    if cfg!(target_os = "macos") {
        cv.render("arabic_hebrew");
    }
}

#[test]
fn japanese() {
    let mut fonts = FontSystem::new();
    let t = fonts.layout(
        "葬送のフリーレン 進撃の巨人",
        &touch::text::CATEGORY.into(),
        None,
        None,
        Align::Start,
    );
    if t.missing_glyphs() > 0 {
        println!("SKIP japanese: no fallback font on this machine");
        return;
    }
    let mut cv = Canvas::new(300.0, 130.0, 2.0);
    cv.put(&t, 10.0);
    // CJK has no spaces: it must still break inside the run.
    let wrapped = fonts.layout(
        "葬送のフリーレンは魔王を倒した勇者一行の後日譚",
        &touch::text::BODY.into(),
        Some(120.0),
        None,
        Align::Start,
    );
    assert!(
        wrapped.line_count() >= 2,
        "CJK breaks without spaces ({} lines)",
        wrapped.line_count()
    );
    assert!(wrapped.width() <= 120.5);
    cv.put(&wrapped, 10.0);
    // The CJK glyphs come from the system fallback font, which differs between macOS releases: CI runners skip the picture.
    if cfg!(target_os = "macos") && std::env::var_os("CI").is_none() {
        cv.render("japanese");
    }
}

#[test]
fn ellipsis_truncation() {
    let mut fonts = FontSystem::bundled_only();
    let style: TextStyle = touch::text::CATEGORY.into();
    let long = "A very long title that cannot possibly fit into one line of the tile";
    let one = fonts.layout(long, &style, Some(140.0), Some(1), Align::Start);
    assert!(one.truncated());
    assert!(one.text().ends_with('\u{2026}'));
    assert_eq!(one.line_count(), 1);
    assert!(one.width() <= 140.0 + 0.01, "fits: {}", one.width());
    // It is the longest prefix that fits: one more character would not.
    let kept = one.text().trim_end_matches('\u{2026}').len();
    let more = format!(
        "{}\u{2026}",
        &long[..long
            .char_indices()
            .map(|(i, _)| i)
            .find(|i| *i > kept)
            .unwrap_or(long.len())]
    );
    let probe = fonts.layout(&more, &style, None, None, Align::Start);
    assert!(
        probe.width() > 140.0,
        "the next prefix would be {} wide",
        probe.width()
    );

    let two = fonts.layout(long, &style, Some(140.0), Some(2), Align::Start);
    assert!(two.truncated());
    assert_eq!(two.line_count(), 2);
    let short = fonts.layout("Short", &style, Some(140.0), Some(1), Align::Start);
    assert!(!short.truncated());
    assert_eq!(short.text(), "Short");

    let mut cv = Canvas::new(180.0, 120.0, 2.0);
    cv.put(&one, 10.0);
    cv.put(&two, 10.0);
    cv.put(&short, 10.0);
    cv.render("ellipsis");
}

#[test]
fn two_line_wrapping() {
    let mut fonts = FontSystem::bundled_only();
    let t = fonts.layout(
        "Frieren: Beyond Journey's End",
        &touch::text::LIST_TITLE.into(),
        Some(150.0),
        Some(2),
        Align::Start,
    );
    assert_eq!(t.line_count(), 2);
    assert!(!t.truncated());
    let lines = t.lines();
    assert!(lines[1].top > lines[0].top);
    let mut cv = Canvas::new(180.0, 70.0, 2.0);
    cv.put(&t, 10.0);
    let centred = fonts.layout(
        "Centred over\ntwo lines",
        &touch::text::LIST_TITLE.into(),
        Some(150.0),
        None,
        Align::Center,
    );
    cv.put(&centred, 10.0);
    cv.render("two_lines");
}

#[test]
fn width_grows_with_size_and_tracking_is_applied() {
    let mut fonts = FontSystem::bundled_only();
    let mut last = 0.0;
    for size in [10.0, 12.0, 15.0, 17.0, 22.0, 28.0, 34.0] {
        let w = fonts
            .layout(
                "Swiftly Player",
                &TextStyle::new(size, 600),
                None,
                None,
                Align::Start,
            )
            .width();
        assert!(w > last, "width {w} at {size} pt should exceed {last}");
        last = w;
    }
    let plain = TextStyle::new(17.0, 600);
    let spaced = TextStyle {
        tracking: 2.0,
        ..plain
    };
    let a = fonts
        .layout("Swiftly", &plain, None, None, Align::Start)
        .width();
    let b = fonts
        .layout("Swiftly", &spaced, None, None, Align::Start)
        .width();
    assert!(
        (b - a - 7.0 * 2.0).abs() < 0.01,
        "7 letters x 2 pt: {a} -> {b}"
    );
    let up = fonts.layout(
        "swiftly",
        &TextStyle {
            uppercase: true,
            ..plain
        },
        None,
        None,
        Align::Start,
    );
    assert_eq!(up.text(), "SWIFTLY");
}

#[test]
fn scale_does_not_change_the_measure_or_the_breaks() {
    let mut fonts = FontSystem::bundled_only();
    let t = fonts.layout(
        "Measured in points, not pixels",
        &TextStyle::new(15.0, 400),
        Some(100.0),
        None,
        Align::Start,
    );
    let (w, h) = t.size();
    let mut pixels = Vec::new();
    for scale in [1.0, 1.5, 2.0, 3.0] {
        let mut atlas = GlyphAtlas::new(1024);
        let mut list = DrawList::new(120.0, 60.0, scale);
        atlas.draw(&t, &mut list, 4.0, 4.0, Color::WHITE);
        assert!(!list.quads().is_empty());
        pixels.push(list.quads().len());
    }
    assert!(
        pixels.windows(2).all(|p| p[0] == p[1]),
        "same glyphs at every scale: {pixels:?}"
    );
    assert!(w > 50.0 && h > 15.0);
}

#[test]
fn hit_test_and_caret_are_consistent() {
    let mut fonts = FontSystem::bundled_only();
    let t = fonts.layout(
        "Hello world",
        &TextStyle::new(17.0, 400),
        None,
        None,
        Align::Start,
    );
    assert_eq!(t.hit_test(-5.0, 5.0), 0);
    assert_eq!(t.hit_test(t.width() + 50.0, 5.0), t.text().len());
    let mut last = -1.0;
    for i in 0..=t.text().len() {
        let r = t.caret_rect(i, 1.0);
        assert!(
            r.x > last - 0.001,
            "caret moves right: {i} {} after {last}",
            r.x
        );
        last = r.x;
        if i > 0 && i < t.text().len() {
            assert_eq!(
                t.hit_test(r.x + 0.2, r.y + r.h / 2.0),
                i,
                "round trip at {i}"
            );
        }
    }
    let sel = t.selection_rects(0..5);
    assert_eq!(sel.len(), 1);
    assert!((sel[0].w - t.caret_rect(5, 1.0).x).abs() < 0.5);
}

#[test]
fn hit_test_in_arabic_runs_right_to_left() {
    let mut fonts = FontSystem::new();
    let t = fonts.layout(
        "مرحبا بكم",
        &TextStyle::new(17.0, 400),
        None,
        None,
        Align::Start,
    );
    if t.missing_glyphs() > 0 {
        println!("SKIP arabic hit test: no fallback font");
        return;
    }
    let start = t.caret_rect(0, 1.0).x;
    let end = t.caret_rect(t.text().len(), 1.0).x;
    assert!(
        start > end,
        "logical start is on the right: {start} vs {end}"
    );
    assert_eq!(t.hit_test(start + 3.0, 5.0), 0);
}

#[test]
fn atlas_dirty_rect_and_cache() {
    use swiftly_render::Atlas;
    let mut fonts = FontSystem::bundled_only();
    let t = fonts.layout("aaaa", &TextStyle::new(17.0, 400), None, None, Align::Start);
    let mut atlas = GlyphAtlas::new(256);
    assert!(atlas.take_dirty().is_some(), "a fresh page is fully dirty");
    assert!(atlas.take_dirty().is_none());
    let mut list = DrawList::new(100.0, 40.0, 2.0);
    atlas.draw(&t, &mut list, 0.0, 0.0, Color::WHITE);
    let first = atlas.stats();
    assert_eq!(list.quads().len(), 4);
    let d = atlas.take_dirty().expect("rasterising dirties the page");
    assert!(
        d.w * d.h < 256 * 256 / 4,
        "only the used part is dirty: {d:?}"
    );
    atlas.draw(&t, &mut list, 0.0, 20.0, Color::WHITE);
    assert!(
        atlas.take_dirty().is_none(),
        "second frame is all cache hits"
    );
    assert_eq!(atlas.stats().rasterised, first.rasterised);
    assert!(atlas.stats().hits > first.hits);
}

#[test]
fn full_atlas_drops_glyphs_and_recovers_next_frame() {
    let mut fonts = FontSystem::bundled_only();
    let mut atlas = GlyphAtlas::new(48);
    let t = fonts.layout(
        "Wagenburg Quiz",
        &TextStyle::new(34.0, 700),
        None,
        None,
        Align::Start,
    );
    let mut list = DrawList::new(400.0, 60.0, 2.0);
    atlas.begin_frame();
    atlas.draw(&t, &mut list, 0.0, 0.0, Color::WHITE);
    assert!(atlas.stats().dropped > 0);
    atlas.begin_frame();
    assert_eq!(atlas.stats().clears, 1);
    assert!(atlas.is_empty());
}

/// Widths from Core Text on a Mac (`tools/coretext_widths.swift`, Inter Variable, tracking 0): (string, size, 400, 600).
const CORE_TEXT: [(&str, f32, f32, f32); 6] = [
    ("Swiftly Player", 17.0, 106.861, 110.757),
    ("Größe, Übergänge und Ärger", 17.0, 229.912, 234.404),
    ("Frieren: Beyond Journey's End", 17.0, 242.833, 248.752),
    ("Swiftly Player", 22.0, 134.651, 140.573),
    ("Größe, Übergänge und Ärger", 22.0, 290.545, 297.699),
    ("Frieren: Beyond Journey's End", 22.0, 306.240, 315.272),
];

#[test]
fn widths_match_core_text_within_a_tenth_of_a_point() {
    let mut fonts = FontSystem::bundled_only();
    for (s, size, w400, w600) in CORE_TEXT {
        for (weight, want) in [(400, w400), (600, w600)] {
            let got = fonts.layout(s, &TextStyle::new(size, weight), None, None, Align::Start);
            assert!(
                (got.width() - want).abs() < 0.1,
                "{s:?} {size} pt w{weight}: {} vs Core Text {want}",
                got.width()
            );
            let h = if size == 17.0 { 20.569 } else { 26.619 };
            assert!(
                (got.height() - h).abs() < 0.01,
                "line height {} vs {h}",
                got.height()
            );
        }
    }
}
