//! HiDPI at the Windows scale steps 125, 150 and 175 percent (and 100, 200 as controls), without touching the OS setting:
//! the shell runs headless at that scale and the glyphs must be rasterised at the physical size, one bitmap texel per
//! screen pixel, not rasterised small and stretched. There is no golden at these scales (the goldens are 2x and 3x,
//! see `golden.rs`); the check is the relation between the quads and the atlas, which is what blurry text breaks.

use swiftly_desktop::shell::Shell;
use swiftly_render::{DrawList, QuadKind};
use swiftly_ui::{Cx, Idiom};

const SIZE_PT: (f32, f32) = (1280.0, 800.0);

fn frame_at(scale: f32) -> (Shell, DrawList) {
    let size_px = (
        (SIZE_PT.0 * scale).round() as u32,
        (SIZE_PT.1 * scale).round() as u32,
    );
    let mut shell = Shell::new_suite(size_px, scale, Cx::deterministic(), Idiom::Desktop);
    let mut list = shell.frame(0.0).0;
    for i in 1..6 {
        list = shell.frame(f64::from(i) * 16.0).0;
    }
    (shell, list)
}

/// Glyph quads as (width px, height px, texel width of the bitmap it samples, texel height).
fn glyphs(shell: &Shell, list: &DrawList) -> Vec<(f32, f32, f32, f32)> {
    let (aw, ah) = shell.with_sources(|s| s.glyphs.map_or((1, 1), |a| a.size()));
    assert!(aw > 1, "a glyph page exists");
    let scale = list.scale();
    list.quads()
        .iter()
        .filter(|q| q.kind == QuadKind::Glyph)
        .map(|q| {
            (
                q.rect.w * scale,
                q.rect.h * scale,
                (q.uv[2] - q.uv[0]) * aw as f32,
                (q.uv[3] - q.uv[1]) * ah as f32,
            )
        })
        .collect()
}

fn median(mut v: Vec<f32>) -> f32 {
    v.sort_by(f32::total_cmp);
    v[v.len() / 2]
}

#[test]
fn text_is_rasterised_at_physical_size_at_every_windows_scale() {
    let mut heights = Vec::new();
    for scale in [1.0_f32, 1.25, 1.5, 1.75, 2.0] {
        let (shell, list) = frame_at(scale);
        assert!(
            (list.scale() - scale).abs() < 1e-6,
            "the draw list carries the scale"
        );
        let g = glyphs(&shell, &list);
        assert!(g.len() > 50, "scale {scale}: only {} glyphs drawn", g.len());
        for &(w, h, tw, th) in &g {
            assert!(
                (w - tw).abs() < 0.05 && (h - th).abs() < 0.05,
                "scale {scale}: a glyph of {w}x{h} px samples a {tw}x{th} bitmap (stretched)"
            );
            assert!(
                (w - w.round()).abs() < 0.05 && (h - h.round()).abs() < 0.05,
                "scale {scale}: glyph box not on whole pixels"
            );
        }
        heights.push((scale, median(g.iter().map(|x| x.1).collect())));
    }
    // The typical glyph grows with the scale (it is re-rasterised, not scaled): within 15 % of the ratio.
    let base = heights[0].1;
    for (scale, h) in &heights {
        let ratio = h / base;
        assert!(
            (ratio / scale - 1.0).abs() < 0.15,
            "median glyph height at {scale}x is {h} px, {ratio:.2} of the 1x height"
        );
    }
}

#[test]
fn the_software_picture_has_the_physical_size() {
    for scale in [1.25_f32, 1.5, 1.75] {
        let (shell, list) = frame_at(scale);
        let img = shell.render_software(&list);
        assert_eq!(
            (img.width as f32, img.height as f32),
            ((SIZE_PT.0 * scale).round(), (SIZE_PT.1 * scale).round())
        );
    }
}

#[test]
fn a_scale_change_while_running_resizes_the_layout() {
    let mut shell = Shell::new_suite((1280, 800), 1.0, Cx::deterministic(), Idiom::Desktop);
    let _ = shell.frame(0.0);
    shell.resize((1600, 1000), 1.25);
    assert_eq!(
        shell.size_pt(),
        (1280.0, 800.0),
        "same points at a new scale"
    );
    let list = shell.frame(16.0).0;
    assert!((list.scale() - 1.25).abs() < 1e-6);
    assert_eq!(list.width(), 1280.0);
}
