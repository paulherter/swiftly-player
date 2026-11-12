//! The player UI over a synthetic video frame, three form factors: the golden proves that the controls compose over
//! a picture the same way on every host (software renderer, bundled Inter, fixed clock). A second test draws the same
//! scene with the GPU video layer and compares it with the software oracle (skipped without a wgpu adapter).
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::arc_with_non_send_sync
)]

use std::path::PathBuf;
use std::sync::Arc;
use swiftly_desktop::frame_surface::{FrameSurface, GpuSurface};
use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen, VideoSurface};
use swiftly_layout::Size;
use swiftly_render::{Color, GpuContext, RgbaImage, Sources, VideoFit, WgpuRenderer};
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

struct Form {
    name: &'static str,
    size: (f32, f32),
    scale: f32,
    idiom: Idiom,
}

const FORMS: [Form; 3] = [
    Form {
        name: "touch",
        size: (844.0, 390.0),
        scale: 3.0,
        idiom: Idiom::Phone,
    },
    Form {
        name: "desktop",
        size: (1280.0, 800.0),
        scale: 2.0,
        idiom: Idiom::Desktop,
    },
    Form {
        name: "tv",
        size: (1920.0, 1080.0),
        scale: 1.0,
        idiom: Idiom::Tv,
    },
];

/// A 16:9 test picture: colour bars on top, a luma ramp below, a bright disc, a dark frame around it.
fn synthetic(w: u32, h: u32) -> Vec<u8> {
    let bars = [
        [191, 191, 191],
        [191, 191, 0],
        [0, 191, 191],
        [0, 191, 0],
        [191, 0, 191],
        [191, 0, 0],
        [0, 0, 191],
    ];
    let mut out = Vec::with_capacity(w as usize * h as usize * 4);
    for y in 0..h {
        for x in 0..w {
            let (fx, fy) = (x as f32 / w as f32, y as f32 / h as f32);
            let mut c = if fy < 0.6 {
                bars[((fx * 7.0) as usize).min(6)]
            } else {
                let g = (fx * 255.0) as u8;
                [g, g, g]
            };
            let (dx, dy) = (fx - 0.5, (fy - 0.5) * h as f32 / w as f32);
            if dx * dx + dy * dy < 0.02 {
                c = [250, 230, 120];
            }
            if x < 4 || y < 4 || x + 4 >= w || y + 4 >= h {
                c = [20, 20, 40];
            }
            out.extend_from_slice(&[c[0], c[1], c[2], 255]);
        }
    }
    out
}

mod common;

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, share) = img.diff(&golden);
    assert!(
        common::golden_ok(max, share),
        "golden {name} differs by {max} ({:.4} % of the pixels)",
        share * 100.0
    );
}

fn run_to(s: &mut PlayerScreen, ms: f64) -> swiftly_render::DrawList {
    let mut now = 0.0;
    while now + FRAME_MS < ms {
        now += FRAME_MS;
        let _ = s.frame(now);
    }
    s.frame(ms).0
}

fn env(f: &Form) -> Env {
    Env::new(Size::new(f.size.0, f.size.1), f.scale, f.idiom)
}

#[test]
fn player_controls_over_video_goldens() {
    for f in &FORMS {
        let cx = Cx::deterministic();
        let frames = Arc::new(FrameSurface::new(cx.clone()));
        frames.push(640, 360, &synthetic(640, 360));
        #[allow(clippy::arc_with_non_send_sync)]
        let surface: Arc<dyn VideoSurface> = frames;
        let mut s = PlayerScreen::with_surface(env(f), cx, PlayerScenario::Playing, 0.0, surface);
        let _ = s.frame(0.0);
        let list = run_to(&mut s, 1000.0);
        check(
            &format!("player_video_{}", f.name),
            &s.render_software(&list),
        );
    }
}

/// The GPU video layer under the same UI equals the software picture when the frame has the size of the target.
#[test]
fn gpu_layer_matches_software() {
    let Ok(ctx) = GpuContext::headless() else {
        eprintln!("no wgpu adapter: skipped");
        return;
    };
    let f = Form {
        name: "hd",
        size: (1280.0, 720.0),
        scale: 1.0,
        idiom: Idiom::Desktop,
    };
    let pixels = synthetic(1280, 720);
    // Software oracle: the frame through the image page.
    let cx = Cx::deterministic();
    let frames = Arc::new(FrameSurface::new(cx.clone()));
    frames.push(1280, 720, &pixels);
    #[allow(clippy::arc_with_non_send_sync)]
    let surface: Arc<dyn VideoSurface> = frames;
    let mut soft = PlayerScreen::with_surface(env(&f), cx, PlayerScenario::Playing, 0.0, surface);
    let _ = soft.frame(0.0);
    let list = run_to(&mut soft, 1000.0);
    let oracle = soft.render_software(&list);
    // GPU: transparent UI area, the frame is the renderer's bottom layer.
    let cx = Cx::deterministic();
    #[allow(clippy::arc_with_non_send_sync)]
    let surface: Arc<dyn VideoSurface> = Arc::new(GpuSurface);
    let mut gpu =
        PlayerScreen::with_surface(env(&f), cx.clone(), PlayerScenario::Playing, 0.0, surface);
    let _ = gpu.frame(0.0);
    let list = run_to(&mut gpu, 1000.0);
    let mut renderer = WgpuRenderer::new(&ctx, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    renderer.upload_video(1280, 720, &pixels, VideoFit::Fit);
    let (ts, im) = (cx.text.borrow(), cx.images.borrow());
    let img = renderer
        .render_to_image(
            &list,
            Color::BLACK,
            &Sources {
                glyphs: Some(&ts.atlas),
                images: Some(&im.page),
            },
        )
        .unwrap();
    assert_eq!((img.width, img.height), (oracle.width, oracle.height));
    let (max, mean) = img.diff(&oracle);
    println!(
        "gpu vs software on {}: max {max}, mean {mean:.4}",
        ctx.adapter_info().name
    );
    assert!(max <= 6, "gpu video layer differs from the oracle by {max}");
}
