//! The server marks are the Mac's drawings (bell, orbit, stack), not one shared drive symbol.

use swiftly_ui::icons::{path_data, rasterize_template};

fn coverage(asset: &str) -> f32 {
    let d = path_data(asset).unwrap_or_else(|| panic!("{asset} is in the icon set"));
    let px = rasterize_template(d, 100);
    px.chunks(4).map(|p| f32::from(p[3]) / 255.0).sum::<f32>() / (100.0 * 100.0)
}

#[test]
fn the_three_kinds_and_quick_connect_have_their_own_drawings() {
    let drive = coverage("hard-drives");
    let marks: Vec<f32> = ["kind-jellyfin", "kind-plex", "kind-emby", "quick-connect"]
        .iter()
        .map(|a| coverage(a))
        .collect();
    for (i, c) in marks.iter().enumerate() {
        assert!(*c > 0.04 && *c < 0.5, "mark {i} covers {c}");
        assert!(
            (c - drive).abs() > 0.001,
            "mark {i} is not the drive symbol"
        );
    }
    assert!(
        (marks[0] - marks[1]).abs() > 0.001 && (marks[1] - marks[2]).abs() > 0.001,
        "the marks differ: {marks:?}"
    );
}
