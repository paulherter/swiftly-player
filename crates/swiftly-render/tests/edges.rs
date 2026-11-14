// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Edge quality at a fractional scale (1.5 on a 4K Linux desktop): rims of neighbouring pictures, seams between gradient
//! bands, half-covered edge pixels and banding. Each check fails on the renderer before these fixes.

use swiftly_render::{
    Atlas, AtlasFormat, Color, DrawList, GpuContext, PixelPage, Rect, RgbaImage, SoftwareRenderer,
    Sources, WgpuRenderer,
};

fn solid(w: u32, h: u32, rgb: [u8; 3]) -> Vec<u8> {
    (0..w * h)
        .flat_map(|_| [rgb[0], rgb[1], rgb[2], 255])
        .collect()
}

/// Two pictures packed edge to edge in one page, like the app's image page: red on the left, blue right of it and a
/// green one below. Returns the page and the uv of the blue picture.
fn page_with_neighbours() -> (PixelPage, [f32; 4]) {
    let mut page = PixelPage::new(64, 64, AtlasFormat::Rgba8);
    assert!(page.put(0, 0, 16, 16, &solid(16, 16, [255, 0, 0])));
    assert!(page.put(16, 0, 16, 16, &solid(16, 16, [0, 0, 255])));
    assert!(page.put(16, 16, 16, 16, &solid(16, 16, [0, 255, 0])));
    let uv = page.uv(16, 0, 16, 16);
    (page, uv)
}

fn render_image(page: &PixelPage, list: &DrawList, clear: Color) -> RgbaImage {
    SoftwareRenderer::render(
        list,
        clear,
        &Sources {
            glyphs: None,
            images: Some(page as &dyn Atlas),
        },
    )
}

#[test]
fn a_picture_never_shows_its_neighbour_in_the_page() {
    let (page, uv) = page_with_neighbours();
    for scale in [1.0_f32, 1.5, 2.0] {
        let mut list = DrawList::new(60.0, 40.0, scale);
        // Odd, fractional place and size: edges between device pixels.
        list.image(Rect::new(10.3, 7.2, 21.3, 21.3), uv, Color::WHITE, 0.0);
        let img = render_image(&page, &list, Color::BLACK);
        let mut worst = 0u8;
        for y in 0..img.height {
            for x in 0..img.width {
                let p = img.pixel(x, y);
                // Red or green would be the neighbours; black is the page behind the picture.
                worst = worst.max(p[0]).max(p[1]);
            }
        }
        assert_eq!(
            worst, 0,
            "scale {scale}: a neighbour of the picture leaks in (max {worst})"
        );
    }
}

#[test]
fn a_generation_offset_in_the_uv_does_not_blur_or_leak() {
    // The app hands out rectangles whose left and top edge carry a sub-texel offset (up to 0.4 texel) as a generation
    // mark; it must not show.
    let (page, mut uv) = page_with_neighbours();
    uv[0] += 0.4 / 64.0;
    uv[1] += 0.4 / 64.0;
    let mut list = DrawList::new(40.0, 40.0, 1.0);
    list.image(Rect::new(4.0, 4.0, 16.0, 16.0), uv, Color::WHITE, 0.0);
    let img = render_image(&page, &list, Color::BLACK);
    for y in 4..20 {
        for x in 4..20 {
            assert_eq!(img.pixel(x, y), [0, 0, 255, 255], "pixel {x},{y}");
        }
    }
}

#[test]
fn pictures_cover_whole_device_pixels_at_a_fractional_scale() {
    let mut page = PixelPage::new(16, 16, AtlasFormat::Rgba8);
    assert!(page.put(0, 0, 16, 16, &solid(16, 16, [255, 255, 255])));
    let mut list = DrawList::new(30.0, 30.0, 1.5);
    list.image(
        Rect::new(3.3, 3.3, 10.1, 10.1),
        page.uv(0, 0, 16, 16),
        Color::WHITE,
        0.0,
    );
    let img = render_image(&page, &list, Color::BLACK);
    for y in 0..img.height {
        for x in 0..img.width {
            let p = img.pixel(x, y)[0];
            assert!(p == 0 || p == 255, "pixel {x},{y} is half covered ({p})");
        }
    }
}

#[test]
fn gradient_bands_leave_no_seam() {
    // Seven opaque white bands across a fractional rectangle on black: any dark pixel inside is a seam.
    let stops: Vec<(f32, Color)> = [0.0_f32, 0.15, 0.29, 0.45, 0.57, 0.7, 0.85, 1.0]
        .iter()
        .map(|&p| (p, Color::WHITE))
        .collect();
    for scale in [1.5_f32, 1.25, 1.75] {
        for vertical in [false, true] {
            let mut list = DrawList::new(80.0, 60.0, scale);
            let r = Rect::new(5.3, 4.7, 61.7, 41.9);
            list.fill_stops(r, vertical, &stops, 0.0);
            let img = SoftwareRenderer::render(&list, Color::BLACK, &Sources::default());
            // Whole device pixels strictly inside the rectangle.
            let (x0, x1) = (
                (r.x * scale).ceil() as usize,
                (r.max_x() * scale).floor() as usize,
            );
            let (y0, y1) = (
                (r.y * scale).ceil() as usize,
                (r.max_y() * scale).floor() as usize,
            );
            for y in y0..y1 {
                for x in x0..x1 {
                    // One level of dither noise is allowed; a seam would be far darker.
                    assert!(
                        img.pixel(x, y)[0] >= 254,
                        "scale {scale} vertical {vertical}: seam at {x},{y}"
                    );
                }
            }
        }
    }
}

#[test]
fn a_slow_ramp_is_dithered_and_keeps_its_mean() {
    // 0.20 to 0.22 over 300 rows is 5 levels: without noise every row is one flat value and the steps show as bands.
    let mut list = DrawList::new(400.0, 300.0, 1.0);
    list.rect(
        Rect::new(0.0, 0.0, 400.0, 300.0),
        swiftly_render::LinearGradient::vertical(
            Color::rgb(0.20, 0.20, 0.20),
            Color::rgb(0.22, 0.22, 0.22),
        ),
        None,
        0.0,
    );
    let img = SoftwareRenderer::render(&list, Color::BLACK, &Sources::default());
    let mut mixed_rows = 0;
    let mut err = 0.0_f64;
    for y in 0..300usize {
        let row: Vec<u8> = (0..400).map(|x| img.pixel(x, y)[0]).collect();
        let (min, max) = (row.iter().min().unwrap(), row.iter().max().unwrap());
        if max > min {
            mixed_rows += 1;
        }
        assert!(max - min <= 1, "noise stays within one level");
        let mean = row.iter().map(|&v| f64::from(v)).sum::<f64>() / 400.0;
        let ideal = (0.20 + 0.02 * ((y as f64 + 0.5) / 300.0)) * 255.0;
        err += (mean - ideal).abs();
    }
    assert!(
        mixed_rows > 200,
        "only {mixed_rows} of 300 rows are dithered"
    );
    assert!(
        err / 300.0 < 0.1,
        "mean level drifts by {} levels",
        err / 300.0
    );
}

#[test]
fn the_gpu_agrees_with_software_on_clamped_images_and_dither() {
    let Ok(ctx) = GpuContext::headless() else {
        println!("SKIP: no GPU adapter");
        return;
    };
    let (page, uv) = page_with_neighbours();
    let mut list = DrawList::new(60.0, 40.0, 1.5);
    list.image(Rect::new(10.3, 7.2, 21.3, 21.3), uv, Color::WHITE, 0.0);
    list.rect(
        Rect::new(2.0, 30.0, 50.0, 8.0),
        swiftly_render::LinearGradient::horizontal(
            Color::rgb(0.2, 0.2, 0.2),
            Color::rgb(0.23, 0.2, 0.2),
        ),
        None,
        0.0,
    );
    let sources = Sources {
        glyphs: None,
        images: Some(&page as &dyn Atlas),
    };
    let soft = SoftwareRenderer::render(&list, Color::BLACK, &sources);
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    let gpu = renderer
        .render_to_image(&list, Color::BLACK, &sources)
        .unwrap();
    let (max, _) = soft.diff(&gpu);
    assert!(max <= 2, "gpu and software differ by {max} levels");
    // The picture's edge pixels on the GPU carry no neighbour colour either.
    for y in 0..gpu.height {
        for x in 0..gpu.width {
            let p = gpu.pixel(x, y);
            assert!(
                p[0] == 0 && p[1] <= 1 || y >= 45,
                "neighbour on the gpu at {x},{y}: {p:?}"
            );
        }
    }
}

#[test]
fn the_gpu_agrees_with_software_on_a_rounded_clip() {
    let Ok(ctx) = GpuContext::headless() else {
        println!("SKIP: no GPU adapter");
        return;
    };
    let mut list = DrawList::new(60.0, 50.0, 1.5);
    list.push_round_clip(Rect::new(5.3, 4.1, 50.0, 40.0), 12.0);
    list.fill(Rect::new(0.0, 0.0, 28.0, 50.0), Color::WHITE, 0.0);
    list.fill(
        Rect::new(30.0, 0.0, 30.0, 50.0),
        Color::rgb(0.9, 0.3, 0.2),
        0.0,
    );
    list.pop_clip();
    let soft = SoftwareRenderer::render(&list, Color::BLACK, &Sources::default());
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    let gpu = renderer
        .render_to_image(&list, Color::BLACK, &Sources::default())
        .unwrap();
    let (max, _) = soft.diff(&gpu);
    assert!(max <= 2, "gpu and software differ by {max} levels");
    assert_eq!(
        gpu.pixel(9, 8),
        [0, 0, 0, 255],
        "the corner is cut on the gpu"
    );
    assert!(gpu.pixel(40, 40)[0] > 200, "the card's middle is drawn");
}

#[test]
fn the_gpu_agrees_with_software_on_a_radial_gradient() {
    let Ok(ctx) = GpuContext::headless() else {
        println!("SKIP: no GPU adapter");
        return;
    };
    let mut list = DrawList::new(80.0, 40.0, 1.5);
    let w = |a: f32| Color::new(0.4, 0.6, 1.0, a);
    list.radial_stops(
        Rect::new(0.0, 0.0, 80.0, 40.0),
        [40.0, 0.0],
        [40.0, 30.0],
        &[(0.0, w(0.5)), (0.35, w(0.3)), (0.7, w(0.1)), (1.0, w(0.0))],
    );
    let soft = SoftwareRenderer::render(&list, Color::BLACK, &Sources::default());
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    let gpu = renderer
        .render_to_image(&list, Color::BLACK, &Sources::default())
        .unwrap();
    let (max, _) = soft.diff(&gpu);
    assert!(max <= 2, "gpu and software differ by {max} levels");
}

/// A glyph page with a colour page behind it, as the text atlas hands to the renderer.
struct GlyphsWithColor {
    coverage: PixelPage,
    color: PixelPage,
}

impl Atlas for GlyphsWithColor {
    fn size(&self) -> (u32, u32) {
        self.coverage.size()
    }
    fn format(&self) -> AtlasFormat {
        self.coverage.format()
    }
    fn pixels(&self) -> &[u8] {
        self.coverage.pixels()
    }
    fn take_dirty(&self) -> Option<swiftly_render::DirtyRect> {
        self.coverage.take_dirty()
    }
    fn color_page(&self) -> Option<&dyn Atlas> {
        Some(&self.color)
    }
}

#[test]
fn the_gpu_agrees_with_software_on_colour_glyphs() {
    let Ok(ctx) = GpuContext::headless() else {
        println!("SKIP: no GPU adapter");
        return;
    };
    // A 12 x 12 premultiplied picture: a red disc with a half-transparent blue rim on a clear ground.
    let mut texels = Vec::new();
    for y in 0..12 {
        for x in 0..12 {
            let (dx, dy) = (x as f32 - 5.5, y as f32 - 5.5);
            let d = (dx * dx + dy * dy).sqrt();
            texels.extend_from_slice(&if d < 4.0 {
                [255, 40, 0, 255]
            } else if d < 5.5 {
                [0, 0, 64, 128]
            } else {
                [0, 0, 0, 0]
            });
        }
    }
    let mut color = PixelPage::new(32, 32, AtlasFormat::Rgba8);
    assert!(color.put(1, 1, 12, 12, &texels));
    let uv = color.uv(1, 1, 12, 12);
    let glyphs = GlyphsWithColor {
        coverage: PixelPage::new(32, 32, AtlasFormat::R8),
        color,
    };
    let mut list = DrawList::new(60.0, 30.0, 1.5);
    // The text colour is green: it must not tint the picture. The second one is faded by its alpha.
    list.color_glyph(
        Rect::new(4.0, 4.0, 12.0, 12.0),
        uv,
        Color::rgb(0.0, 1.0, 0.0),
    );
    list.color_glyph(
        Rect::new(30.0, 4.0, 12.0, 12.0),
        uv,
        Color::new(0.0, 1.0, 0.0, 0.5),
    );
    let sources = Sources {
        glyphs: Some(&glyphs as &dyn Atlas),
        images: None,
    };
    let soft = SoftwareRenderer::render(&list, Color::BLACK, &sources);
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    let gpu = renderer
        .render_to_image(&list, Color::BLACK, &sources)
        .unwrap();
    let (max, _) = soft.diff(&gpu);
    assert!(max <= 2, "gpu and software differ by {max} levels");
    let p = gpu.pixel(15, 15);
    assert!(
        p[0] > 200 && p[1] < 80,
        "the disc stays red on the gpu, got {p:?}"
    );
    let faded = gpu.pixel(54, 15);
    assert!(faded[0] > 90 && faded[0] < 160, "half alpha, got {faded:?}");
}

/// A rounded window clears to transparent, so what no quad paints must still be the ground colour inside the outline: the
/// letterbox of a film, the player's bars once the controls are gone, the player before its first frame. Only the corners
/// stay transparent. On the renderer before the ground quad this showed the see-through desktop.
#[test]
fn a_rounded_window_is_opaque_ground_where_nothing_is_painted_and_clear_only_in_the_corners() {
    let Ok(ctx) = GpuContext::headless() else {
        println!("SKIP: no GPU adapter");
        return;
    };
    let ground = Color::rgb(0.5, 0.25, 0.75);
    let list = DrawList::new(80.0, 60.0, 1.5);
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    renderer.set_window_corner(24.0);
    let img = renderer
        .render_to_image(&list, ground, &Sources::default())
        .unwrap();
    let mid = img.pixel(img.width / 2, img.height / 2);
    assert!(
        (i32::from(mid[0]) - 128).abs() <= 1 && (i32::from(mid[2]) - 191).abs() <= 1,
        "the unpainted middle is the ground colour, got {mid:?}"
    );
    // The edge middles are inside the outline and opaque too, the very corner pixel is cut away.
    let top_middle = img.pixel(img.width / 2, 1);
    assert!(
        top_middle[0] > 120,
        "the edge between the corners is ground: {top_middle:?}"
    );
    assert_eq!(&img.pixel(0, 0)[..3], &[0, 0, 0], "the corner stays clear");
}

/// A film that fills the window (16:9 in a 16:9 window) must not paint over the transparent corners either.
#[test]
fn a_film_that_fills_a_rounded_window_leaves_its_corners_clear() {
    let Ok(ctx) = GpuContext::headless() else {
        println!("SKIP: no GPU adapter");
        return;
    };
    let list = DrawList::new(160.0, 90.0, 1.0);
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    renderer.set_window_corner(24.0);
    renderer.upload_video(
        16,
        9,
        &solid(16, 9, [255, 255, 255]),
        swiftly_render::VideoFit::Fit,
    );
    let img = renderer
        .render_to_image(&list, Color::BLACK, &Sources::default())
        .unwrap();
    assert_eq!(
        &img.pixel(80, 45)[..3],
        &[255, 255, 255],
        "the film is drawn"
    );
    assert_eq!(
        &img.pixel(0, 0)[..3],
        &[0, 0, 0],
        "the corner stays clear over the film"
    );
}
