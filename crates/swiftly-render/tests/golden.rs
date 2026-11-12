// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Golden images of the software renderer and the comparison of the wgpu renderer against it.

mod common;

use common::{all_scenes, check_golden};
use swiftly_render::{GpuContext, SoftwareRenderer, WgpuRenderer};

#[test]
fn software_matches_the_golden_pngs() {
    for scene in all_scenes() {
        let img = SoftwareRenderer::render(&scene.list, scene.clear, &scene.sources());
        check_golden(scene.name, &img);
    }
}

#[test]
fn goldens_have_the_expected_content() {
    let poster = common::poster();
    assert_eq!(poster.list.pixel_size(), (140, 198));
    let img = SoftwareRenderer::render(&poster.list, poster.clear, &poster.sources());
    assert_eq!(img.pixel(12, 12)[3], 255);
    assert_ne!(
        img.pixel(12 + 58, 12 + 87),
        img.pixel(0, 0),
        "the tile shows the picture"
    );
    assert_eq!(
        img.pixel(12, 12),
        img.pixel(0, 0),
        "the rounded corner is cut away (background shows)"
    );
}

/// Skips (with a note) when the machine has no GPU adapter.
fn gpu() -> Option<GpuContext> {
    match GpuContext::headless() {
        Ok(ctx) => {
            let info = ctx.adapter_info();
            println!(
                "GPU: {} ({:?}, {:?})",
                info.name, info.backend, info.device_type
            );
            Some(ctx)
        }
        Err(e) => {
            println!("SKIP: no GPU adapter ({e}); software renderer only");
            None
        }
    }
}

#[test]
fn wgpu_matches_software_on_the_fixture_scenes() {
    let Some(ctx) = gpu() else { return };
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    for scene in all_scenes() {
        let soft = SoftwareRenderer::render(&scene.list, scene.clear, &scene.sources());
        let gpu = renderer
            .render_to_image(&scene.list, scene.clear, &scene.sources())
            .unwrap();
        let (max, share) = soft.diff(&gpu);
        println!(
            "{:<18} max diff {max:>2} levels, {:.3} % of pixels differ",
            scene.name,
            share * 100.0
        );
        assert!(
            max <= 4,
            "{}: wgpu differs from software by {max} levels",
            scene.name
        );
    }
}

#[test]
fn wgpu_matches_software_at_fractional_scale_and_bgra() {
    let Some(ctx) = gpu() else { return };
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Bgra8Unorm).unwrap();
    let mut scene = common::card_shadow();
    scene.list = scene.list.with_scale(1.5);
    let soft = SoftwareRenderer::render(&scene.list, scene.clear, &scene.sources());
    let gpu = renderer
        .render_to_image(&scene.list, scene.clear, &scene.sources())
        .unwrap();
    let (max, share) = soft.diff(&gpu);
    println!(
        "card_shadow @1.5x BGRA: max diff {max}, {:.3} % differ",
        share * 100.0
    );
    assert!(max <= 4);
}

#[test]
fn wgpu_blur_matches_software() {
    let Some(ctx) = gpu() else { return };
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Bgra8Unorm).unwrap();
    let mut scene = common::card_shadow();
    let (w, h) = (scene.list.width(), scene.list.height());
    scene.list.backdrop_blur(
        swiftly_render::Rect::new(w * 0.2, h * 0.2, w * 0.6, h * 0.6),
        14.0,
        swiftly_render::Color::new(0.1, 0.1, 0.1, 0.4),
        12.0,
    );
    let soft = SoftwareRenderer::render(&scene.list, scene.clear, &scene.sources());
    let gpu = renderer
        .render_to_image(&scene.list, scene.clear, &scene.sources())
        .unwrap();
    let (max, _) = soft.diff(&gpu);
    assert!(max <= 4, "blur differs by {max} levels");
}

#[test]
fn atlas_dirty_rect_update_reaches_the_gpu() {
    let Some(ctx) = gpu() else { return };
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    let mut scene = common::glyphs_and_clip();
    let first = renderer
        .render_to_image(&scene.list, scene.clear, &scene.sources())
        .unwrap();
    if let Some(page) = scene.glyphs.as_mut() {
        page.put(0, 0, 8, 8, &[255; 64]);
    }
    let second = renderer
        .render_to_image(&scene.list, scene.clear, &scene.sources())
        .unwrap();
    let soft = SoftwareRenderer::render(&scene.list, scene.clear, &scene.sources());
    assert_ne!(first, second, "the changed glyph page shows up");
    assert!(soft.diff(&second).0 <= 4);
}

#[test]
#[ignore = "timing; run: cargo test -p swiftly-render --release -- --ignored --nocapture bench"]
fn bench_5k_quads() {
    use std::time::Instant;
    let scene = common::many_quads(5000);
    let src = scene.sources();
    let _ = SoftwareRenderer::render(&scene.list, scene.clear, &src);
    let t = Instant::now();
    let runs = 5;
    let mut soft = SoftwareRenderer::render(&scene.list, scene.clear, &src);
    for _ in 1..runs {
        soft = SoftwareRenderer::render(&scene.list, scene.clear, &src);
    }
    println!(
        "software, 5000 quads, 1280x720: {:.1} ms/frame",
        t.elapsed().as_secs_f64() * 1000.0 / runs as f64
    );
    let Some(ctx) = gpu() else { return };
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    let gpu_img = renderer
        .render_to_image(&scene.list, scene.clear, &src)
        .unwrap();
    let (max, share) = soft.diff(&gpu_img);
    println!(
        "5000 quads: max diff {max} levels, {:.2} % of pixels differ",
        share * 100.0
    );
    // Frame without readback: build the instances, draw, wait for the GPU.
    let size = scene.list.pixel_size();
    let tex = ctx.device().create_texture(&wgpu::TextureDescriptor {
        label: None,
        size: wgpu::Extent3d {
            width: size.0,
            height: size.1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        view_formats: &[],
    });
    let view = tex.create_view(&Default::default());
    let t = Instant::now();
    let runs = 50;
    for _ in 0..runs {
        renderer.draw(&scene.list, &view, size, scene.clear, &src);
        renderer.wait().unwrap();
    }
    println!(
        "wgpu draw + wait, 5000 quads: {:.2} ms/frame",
        t.elapsed().as_secs_f64() * 1000.0 / runs as f64
    );
    let t = Instant::now();
    for _ in 0..runs {
        renderer
            .render_to_image(&scene.list, scene.clear, &src)
            .unwrap();
    }
    println!(
        "wgpu draw + readback, 5000 quads: {:.2} ms/frame",
        t.elapsed().as_secs_f64() * 1000.0 / runs as f64
    );
}
