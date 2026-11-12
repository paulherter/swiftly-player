// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Prints text widths for comparison with Core Text and times layout and rasterising.
//! `cargo run --release -p swiftly-text --example measure`

use std::time::Instant;

use swiftly_render::{Color, DrawList};
use swiftly_text::{Align, FontSystem, GlyphAtlas, TextStyle};

const STRINGS: [&str; 3] = [
    "Swiftly Player",
    "Größe, Übergänge und Ärger",
    "Frieren: Beyond Journey's End",
];

fn main() {
    let mut fonts = FontSystem::new();
    println!("widths in points (weight 400 | 600), no tracking; optical size automatic (= size)");
    for size in [17.0, 22.0] {
        for s in STRINGS {
            let a = fonts.layout(s, &TextStyle::new(size, 400), None, None, Align::Start);
            let b = fonts.layout(s, &TextStyle::new(size, 600), None, None, Align::Start);
            println!(
                "{size:>4} pt  {:<34} {:>8.3} | {:>8.3}   h {:.3}",
                s,
                a.width(),
                b.width(),
                b.height()
            );
        }
    }

    // 200 short strings: titles of a grid, mixed lengths, one and two lines.
    let words = [
        "Frieren",
        "Beyond",
        "Journey's",
        "End",
        "Kleine",
        "Hexe",
        "Stranger",
        "Things",
        "Der",
        "Pate",
        "Dune",
        "Part",
        "Two",
        "Arcane",
        "Lighthouse",
        "Larry",
    ];
    let texts: Vec<String> = (0..200)
        .map(|i| {
            let n = 1 + i % 4;
            (0..n)
                .map(|k| words[(i * 7 + k * 3) % words.len()])
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect();
    let style = TextStyle::new(13.0, 500);
    // Warm: first call builds shaper caches.
    let _ = fonts.layout("warm", &style, Some(116.0), Some(2), Align::Start);
    let mut best = f64::MAX;
    let mut layouts = Vec::new();
    for _ in 0..5 {
        let t0 = Instant::now();
        layouts = texts
            .iter()
            .map(|t| fonts.layout(t, &style, Some(116.0), Some(2), Align::Start))
            .collect();
        best = best.min(t0.elapsed().as_secs_f64());
    }
    println!(
        "layout of 200 short strings (13 pt, 116 pt wide, 2 lines): {:.2} ms best of 5 ({:.1} us each)",
        best * 1e3,
        best * 1e6 / 200.0
    );

    let t0 = Instant::now();
    let mut cold = FontSystem::new();
    let _ = cold.layout("x", &style, None, None, Align::Start);
    println!(
        "FontSystem::new + first layout (system font scan, Inter registration): {:.1} ms",
        t0.elapsed().as_secs_f64() * 1e3
    );

    // Cold atlas: rasterise every glyph of those layouts at 2x.
    let mut atlas = GlyphAtlas::new(1024);
    let mut list = DrawList::new(1280.0, 720.0, 2.0);
    let t0 = Instant::now();
    for (i, l) in layouts.iter().enumerate() {
        atlas.draw(
            l,
            &mut list,
            (i % 10) as f32 * 120.0,
            (i / 10) as f32 * 36.0,
            Color::WHITE,
        );
    }
    let cold_t = t0.elapsed().as_secs_f64();
    let st = atlas.stats();
    println!(
        "cold atlas, 200 strings at 2x: {:.2} ms, {} glyph images rasterised ({:.1} us each), {} quads",
        cold_t * 1e3,
        st.rasterised,
        cold_t * 1e6 / st.rasterised.max(1) as f64,
        list.quads().len()
    );
    list.clear();
    let t0 = Instant::now();
    for (i, l) in layouts.iter().enumerate() {
        atlas.draw(
            l,
            &mut list,
            (i % 10) as f32 * 120.0,
            (i / 10) as f32 * 36.0,
            Color::WHITE,
        );
    }
    println!(
        "warm atlas, same 200 strings: {:.3} ms",
        t0.elapsed().as_secs_f64() * 1e3
    );
}
