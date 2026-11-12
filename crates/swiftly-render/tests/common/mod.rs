// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Fixture scenes shared by the golden and benchmark tests. Colours and sizes come from `swiftly-design`.

#![allow(dead_code)]

use std::path::PathBuf;
use swiftly_design::tokens::{colour, common::shadow, touch};
use swiftly_render::{
    Atlas, AtlasFormat, Border, Color, Corners, DrawList, LinearGradient, PixelPage, Rect,
    RgbaImage, ShadowStyle, Sources,
};

/// A design colour as a render colour.
pub fn c(x: swiftly_design::Colour) -> Color {
    Color::new(x.r, x.g, x.b, x.a)
}

/// A scene: the list, the pages it samples and the clear colour.
pub struct Scene {
    pub name: &'static str,
    pub list: DrawList,
    pub glyphs: Option<PixelPage>,
    pub images: Option<PixelPage>,
    pub clear: Color,
}

impl Scene {
    pub fn sources(&self) -> Sources<'_> {
        Sources {
            glyphs: self.glyphs.as_ref().map(|p| p as &dyn Atlas),
            images: self.images.as_ref().map(|p| p as &dyn Atlas),
        }
    }
}

/// A made-up 116x174 "poster": diagonal teal to violet with a few discs and stripes.
fn poster_pixels() -> Vec<u8> {
    let (w, h) = (touch::TILE_WIDTH as usize, touch::TILE_HEIGHT as usize);
    let mut px = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        for x in 0..w {
            let t = (x as f32 / w as f32 + y as f32 / h as f32) / 2.0;
            let mut rgb = [0.12 + 0.55 * t, 0.62 - 0.35 * t, 0.70 + 0.15 * t];
            let (dx, dy) = (x as f32 - 60.0, y as f32 - 70.0);
            if dx * dx + dy * dy < 30.0 * 30.0 {
                rgb = [0.95, 0.80, 0.30];
            }
            if (y / 6) % 2 == 0 && y > 130 {
                rgb = rgb.map(|v| v * 0.6);
            }
            px.extend_from_slice(&[
                (rgb[0] * 255.0) as u8,
                (rgb[1] * 255.0) as u8,
                (rgb[2] * 255.0) as u8,
                255,
            ]);
        }
    }
    px
}

/// Poster tile 116x174, radius 10, 1 pt edge, with a progress bar, at 1x.
pub fn poster() -> Scene {
    let (w, h) = (touch::TILE_WIDTH, touch::TILE_HEIGHT);
    let mut images = PixelPage::new(256, 256, AtlasFormat::Rgba8);
    images.put(4, 4, w as u32, h as u32, &poster_pixels());
    let uv = images.uv(4, 4, w as u32, h as u32);
    let mut list = DrawList::new(w + 24.0, h + 24.0, 1.0);
    let tile = Rect::new(12.0, 12.0, w, h);
    let r = touch::CORNER_TILE;
    list.image(tile, uv, Color::WHITE, r);
    list.push_clip(tile);
    let bar = Rect::new(tile.x + 8.0, tile.max_y() - 12.0, w - 16.0, 4.0);
    list.fill(bar, c(colour::BAR_REASON), 2.0);
    list.fill(
        Rect::new(bar.x, bar.y, (w - 16.0) * 0.4, 4.0),
        c(colour::MARK_ACCENT),
        2.0,
    );
    list.pop_clip();
    list.stroke(tile, c(colour::MARGIN), 1.0, r);
    Scene {
        name: "poster",
        list,
        glyphs: None,
        images: Some(images),
        clear: c(colour::REASON),
    }
}

/// Primary pill, secondary pill with edge, and a pressed (group opacity) pill, at 2x.
pub fn pill_button() -> Scene {
    let mut list = DrawList::new(232.0, 232.0, 2.0);
    let h = touch::CONTROL_HEIGHT;
    list.fill(
        Rect::new(16.0, 16.0, 200.0, h),
        c(colour::MARK_ACCENT),
        Corners::all(999.0),
    );
    let secondary = Rect::new(16.0, 16.0 + h + 16.0, 200.0, h);
    list.fill(secondary, c(colour::SELECTED), Corners::all(999.0));
    list.stroke(secondary, c(colour::MARGIN), 1.0, Corners::all(999.0));
    list.push_opacity(0.5);
    let pressed = Rect::new(16.0, 16.0 + 2.0 * (h + 16.0), 200.0, h);
    list.fill(pressed, c(colour::MARK_ACCENT), Corners::all(999.0));
    list.stroke(
        pressed,
        c(colour::ORIGINAL_ON_ACCENT),
        2.0,
        Corners::all(999.0),
    );
    list.pop_opacity();
    Scene {
        name: "pill_button",
        list,
        glyphs: None,
        images: None,
        clear: c(colour::REASON),
    }
}

/// Card with the `card` shadow token and a sheet-like card with per-corner radii, at 2x.
pub fn card_shadow() -> Scene {
    let mut list = DrawList::new(260.0, 300.0, 2.0);
    let card = Rect::new(40.0, 30.0, 180.0, 100.0);
    let s = shadow::CARD;
    let style = ShadowStyle {
        color: c(s.colour),
        dx: 0.0,
        dy: s.y,
        blur: s.blur,
        spread: 0.0,
    };
    list.shadow(card, style, touch::CORNER_CARD);
    list.fill(card, c(colour::RAISED), touch::CORNER_CARD);
    list.stroke(card, c(colour::MARGIN), 1.0, touch::CORNER_CARD);

    let sheet = Rect::new(40.0, 170.0, 180.0, 110.0);
    let radii = Corners::new(touch::CORNER_SHEET, touch::CORNER_SHEET, 4.0, 4.0);
    let s = shadow::SHEET;
    list.shadow(
        sheet,
        ShadowStyle {
            color: c(s.colour),
            dx: 0.0,
            dy: s.y,
            blur: s.blur,
            spread: 0.0,
        },
        radii,
    );
    list.fill(sheet, c(colour::AREA), radii);
    list.stroke(sheet, c(colour::MARGIN), 1.0, radii);
    Scene {
        name: "card_shadow",
        list,
        glyphs: None,
        images: None,
        clear: c(colour::PRESSED_AREA),
    }
}

/// Horizontal progress bar, a scrim fade and a diagonal gradient card, at 2x.
pub fn gradient_bar() -> Scene {
    let mut list = DrawList::new(300.0, 200.0, 2.0);
    let bar = Rect::new(10.0, 14.0, 280.0, 8.0);
    list.fill(
        bar,
        LinearGradient::horizontal(c(colour::ORIGINAL_ACCENT_QUIET), c(colour::MARK_ACCENT)),
        4.0,
    );
    let scrim_base = Rect::new(10.0, 40.0, 280.0, 70.0);
    list.fill(scrim_base, c(colour::ORIGINAL_ACCENT_LIGHT), 12.0);
    list.fill(
        scrim_base,
        LinearGradient::vertical(Color::CLEAR, c(colour::SHADE)),
        12.0,
    );
    let diag = Rect::new(10.0, 124.0, 280.0, 64.0);
    let g = LinearGradient {
        start: c(colour::MARK_ACCENT),
        end: c(colour::ORIGINAL_WARNING),
        from: [0.0, 0.0],
        to: [1.0, 1.0],
    };
    list.rect(
        diag,
        g,
        Some(Border {
            color: c(colour::MARGIN),
            width: 1.0,
        }),
        touch::CORNER_CARD,
    );
    Scene {
        name: "gradient_bar",
        list,
        glyphs: None,
        images: None,
        clear: c(colour::REASON),
    }
}

/// Glyph quads from a made-up R8 page, a clip cut through an image quad and a tinted image, at 1x.
pub fn glyphs_and_clip() -> Scene {
    let mut glyphs = PixelPage::new(16, 16, AtlasFormat::R8);
    let ring: Vec<u8> = (0..64)
        .map(|i| {
            let (x, y) = ((i % 8) as f32 - 3.5, (i / 8) as f32 - 3.5);
            let d = (x * x + y * y).sqrt();
            ((1.0 - (d - 2.5).abs()).clamp(0.0, 1.0) * 255.0) as u8
        })
        .collect();
    glyphs.put(0, 0, 8, 8, &ring);
    let mut images = PixelPage::new(16, 16, AtlasFormat::Rgba8);
    let checker: Vec<u8> = (0..64)
        .flat_map(|i| {
            if (i % 8 + i / 8) % 2 == 0 {
                [255, 255, 255, 255]
            } else {
                [40, 40, 90, 255]
            }
        })
        .collect();
    images.put(8, 8, 8, 8, &checker);
    let uv_g = glyphs.uv(0, 0, 8, 8);
    let uv_i = images.uv(8, 8, 8, 8);
    let mut list = DrawList::new(96.0, 48.0, 1.0);
    for i in 0..3 {
        list.glyph(
            Rect::new(4.0 + 10.0 * i as f32, 4.0, 8.0, 8.0),
            uv_g,
            c(colour::FONT),
        );
    }
    list.glyph(
        Rect::new(4.0, 16.0, 32.0, 32.0),
        uv_g,
        c(colour::MARK_ACCENT),
    );
    list.push_clip(Rect::new(50.0, 0.0, 22.0, 48.0));
    list.image(Rect::new(44.0, 8.0, 40.0, 32.0), uv_i, Color::WHITE, 6.0);
    list.pop_clip();
    list.image(
        Rect::new(74.0, 4.0, 16.0, 16.0),
        uv_i,
        c(colour::ORIGINAL_WARNING),
        0.0,
    );
    Scene {
        name: "glyphs_and_clip",
        list,
        glyphs: Some(glyphs),
        images: Some(images),
        clear: c(colour::REASON),
    }
}

/// Every golden scene.
pub fn all_scenes() -> Vec<Scene> {
    vec![
        poster(),
        pill_button(),
        card_shadow(),
        gradient_bar(),
        glyphs_and_clip(),
    ]
}

/// `n` quads of mixed kinds on a 1280x720 canvas at 1x (deterministic), for timing.
pub fn many_quads(n: usize) -> Scene {
    let mut images = PixelPage::new(256, 256, AtlasFormat::Rgba8);
    images.put(4, 4, 116, 174, &poster_pixels());
    let uv = images.uv(4, 4, 116, 174);
    let mut list = DrawList::new(1280.0, 720.0, 1.0);
    let mut seed = 0x2545_F491u32;
    let mut rnd = move || {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        (seed >> 8) as f32 / (1u32 << 24) as f32
    };
    for i in 0..n {
        let (x, y) = (rnd() * 1180.0, rnd() * 620.0);
        let (w, h) = (20.0 + rnd() * 80.0, 20.0 + rnd() * 80.0);
        let r = Rect::new(x, y, w, h);
        let col = Color::new(rnd(), rnd(), rnd(), 0.4 + rnd() * 0.6);
        match i % 5 {
            0 => list.fill(r, col, 8.0),
            1 => list.rect(
                r,
                col,
                Some(Border {
                    color: Color::WHITE.with_alpha(0.3),
                    width: 1.0,
                }),
                10.0,
            ),
            2 => list.fill(
                r,
                LinearGradient::vertical(col, Color::BLACK.with_alpha(0.7)),
                Corners::new(4.0, 12.0, 4.0, 12.0),
            ),
            3 => list.image(r, uv, Color::WHITE.with_alpha(0.9), 10.0),
            _ => list.shadow(
                r,
                ShadowStyle {
                    color: Color::BLACK.with_alpha(0.4),
                    dx: 0.0,
                    dy: 4.0,
                    blur: 8.0,
                    spread: 0.0,
                },
                8.0,
            ),
        }
    }
    Scene {
        name: "many_quads",
        list,
        glyphs: None,
        images: Some(images),
        clear: c(colour::REASON),
    }
}

/// Path of a golden PNG.
pub fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.png"))
}

/// Compares `img` with its golden (max channel difference of 1 allowed: libm differences between machines flip a
/// rounding). `UPDATE_GOLDENS=1` rewrites the file instead.
pub fn check_golden(name: &str, img: &RgbaImage) {
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
    assert!(max <= 1, "golden {name} differs by {max}");
}
