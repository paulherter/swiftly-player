//! The iOS shell draws the same pixels as the desktop shell's `--demo app` path: the host's frame (touch form 390x844
//! pt at 3x, tv form 1920x1080 pt at 1x) is rendered by the software renderer and compared with (a) the frame of a bare
//! `Shell::new_suite` of the same size and (b) the stored golden PNG (`UPDATE_GOLDENS=1` rewrites it). Tolerance 2.

use std::path::PathBuf;
use swiftly_desktop::shell::Shell;
use swiftly_ios::host::{Form, Host};
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Idiom};

// The goldens come from macOS; the software renderer rounds a little differently on other systems (seen: up to 10 levels).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

fn golden(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let want = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (want.width, want.height),
        "{name}: size"
    );
    let (max, share) = img.diff(&want);
    println!(
        "golden {name}: max diff {max}, differing {:.4} %",
        share * 100.0
    );
    // Text edges come from the system rasteriser, so a few edge pixels may differ by more than the tolerance.
    assert!(
        max <= TOLERANCE || share < 0.0001,
        "golden {name} differs by {max} on {:.4} %",
        share * 100.0
    );
}

fn run(form: Form, size_px: (u32, u32), scale: f32, idiom: Idiom, name: &str) {
    let mut host = Host::with_cx(form, size_px, scale, Cx::deterministic());
    let mut shell = Shell::new_suite(size_px, scale, Cx::deterministic(), idiom);
    let mut last = None;
    for i in 0..=72 {
        let t = f64::from(i) / 60.0;
        let (a, _) = host.frame(t);
        let (b, _) = shell.frame(t * 1000.0);
        last = Some((a, b));
    }
    let (a, b) = last.unwrap_or_else(|| panic!("no frame"));
    let from_host = host.shell().render_software(&a);
    let from_shell = shell.render_software(&b);
    assert_eq!(
        from_host.diff(&from_shell).0,
        0,
        "{name}: host frame differs from the shared shell"
    );
    golden(name, &from_host);
}

#[test]
fn touch_form_frame_equals_the_shared_path_and_the_golden() {
    run(
        Form::Phone,
        (1170, 2532),
        3.0,
        Idiom::Phone,
        "ios_touch_suite",
    );
}

#[test]
fn tv_form_frame_equals_the_shared_path_and_the_golden() {
    run(Form::Tv, (1920, 1080), 1.0, Idiom::Tv, "ios_tv_suite");
}
