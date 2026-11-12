//! The icons of screens that open late (settings rows, account rows) still draw after the picture hub has taken its
//! region of the shared image page: the run-time bug was an empty icon column because the hub's region used the whole page
//! (goldens have no hub, so they never showed it).
#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use swiftly_desktop::hub::ImageHub;
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader};
use swiftly_ui::Cx;
use swiftly_ui::icons::Icons;

fn hub(cx: &Cx, scale: f32) -> std::rc::Rc<ImageHub> {
    ImageHub::new(
        Box::new(ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac)),
        cx,
        scale,
        Device::Mac,
    )
}

fn drew(cx: &Cx, icons: &Icons, name: &str, pt: f32) -> bool {
    let n = icons.node(name, pt, true, swiftly_render::Color::WHITE);
    let _ = cx;
    n.paint
        .iter()
        .any(|p| matches!(p, swiftly_ui::view::Paint::Image { .. }))
}

#[test]
fn icons_added_after_the_hub_still_find_room() {
    for scale in [1.0_f32, 1.5, 2.0, 3.0] {
        // Worst case: the hub is the first thing on an empty page (a fresh app that starts straight into a live account).
        let cx = Cx::new();
        let _hub = hub(&cx, scale);
        let icons = Icons::new(&cx, scale);
        for name in [
            "play.fill",
            "gauge",
            "clock",
            "speaker-high",
            "subtitles",
            "heart.fill",
            "sign-out",
            "plus",
            "hard-drive",
            "key",
        ] {
            assert!(
                drew(&cx, &icons, name, 20.0),
                "{name} at scale {scale}: no room left on the image page"
            );
        }
    }
}
