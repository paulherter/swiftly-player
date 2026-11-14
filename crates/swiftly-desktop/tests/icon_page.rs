//! The image page of the real app keeps room for icons after the poster region took its rows. The release app drew no
//! server marks, no wordmark and no player centre buttons: the icon names were fine, but the poster region sat on the
//! rows the kept still and preview rows had already claimed, and the icons asked for next found the page full.

use std::sync::Arc;
use swiftly_desktop::frame_surface::app_cx;
use swiftly_desktop::hub::ImageHub;
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader};
use swiftly_render::Color;
use swiftly_ui::icons::Icons;
use swiftly_ui::{Node, Paint};

fn has_picture(n: &Node) -> bool {
    n.paint.iter().any(|p| matches!(p, Paint::Image { .. }))
}

/// What the first screens add before the picture region exists (the server marks, the wordmark and the sidebar come
/// later; measured: a first start had used 998 rows of a 4096 page, 720 of them the subtitle sample's room).
fn first_screens(cx: &swiftly_ui::Cx) {
    let _ = cx.add_image(4000, 276, &vec![255; 4000 * 276 * 4]);
}

#[test]
fn icons_asked_for_after_the_picture_region_still_find_room() {
    for scale in [1.0_f32, 1.5, 2.0] {
        let cx = app_cx();
        first_screens(&cx);
        let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
        let _hub = ImageHub::new(Box::new(loader), &cx, scale, Device::Mac);
        let icons = Icons::new(&cx, scale);
        let white = Color::new(1.0, 1.0, 1.0, 1.0);
        let mut missing = Vec::new();
        // The server marks (first start, "Server hinzufügen"), the player's centre buttons and rings, the big empty-state
        // symbols, and a sweep of the usual sizes with both stroke weights of an outline.
        for (name, pt, outlined, template) in [
            ("kind-jellyfin", 34.0, false, true),
            ("kind-plex", 34.0, false, true),
            ("kind-emby", 34.0, false, true),
            ("play.fill", 38.0, false, false),
            ("pause.fill", 38.0, false, false),
            ("arrow-counter-clockwise", 44.0, true, true),
            ("arrow-clockwise", 44.0, true, true),
            ("hard-drives", 88.0, true, false),
        ] {
            let n = if template {
                icons.node_template(name, pt, outlined, white)
            } else {
                icons.node(name, pt, outlined, white)
            };
            if !has_picture(&n) {
                missing.push(format!("{name} at {pt} pt, scale {scale}"));
            }
        }
        for name in [
            "house",
            "magnifying-glass",
            "gear",
            "caret-right",
            "check",
            "x",
        ] {
            for pt in [11.0_f32, 13.0, 15.0, 18.0, 22.0, 28.0, 44.0] {
                if !has_picture(&icons.node(name, pt, true, white)) {
                    missing.push(format!("{name} at {pt} pt, scale {scale}"));
                }
            }
        }
        assert!(missing.is_empty(), "no room on the page for {missing:?}");
    }
}

#[test]
fn the_picture_region_leaves_the_icon_reserve_free() {
    let cx = app_cx();
    first_screens(&cx);
    let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
    let _hub = ImageHub::new(Box::new(loader), &cx, 1.5, Device::Mac);
    let free = cx.images.borrow().shelf_free();
    assert!(
        free >= swiftly_desktop::hub::ICON_RESERVE_ROWS,
        "{free} rows left for icons"
    );
}
