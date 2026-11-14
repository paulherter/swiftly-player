//! A screen that a page at rest covers (the tab under a title page) fills free room in the picture region but never
//! pushes the pictures of the page in front out. Before, two screens that evicted each other's pictures on every build
//! left the pictures of the page in front grey (a film page's "Ähnliches" row) and both screens rebuilding on every frame.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use swiftly_desktop::hub::{HubSlot, HubSlotExt, ImageHub, RemoteSlot};
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader, Priority};
use swiftly_ui::Cx;
use swiftly_vm::{ImageKind, ImageRef};

fn picture(id: &str) -> ImageRef {
    ImageRef {
        address: format!("http://fixture.test/Items/{id}/Images/Backdrop?tag=t&maxWidth=640"),
        kind: ImageKind::Backdrop,
        wanted_width: 640,
        wanted_height: 360,
    }
}

fn screen(hub: &Rc<ImageHub>) -> HubSlot {
    let slot: HubSlot = Rc::new(RefCell::new(None));
    slot.attach(Rc::clone(hub));
    slot
}

fn build(slot: &HubSlot, hub: &ImageHub, ids: &[&str]) -> Vec<RemoteSlot> {
    slot.begin_build();
    let shown = ids
        .iter()
        .map(|id| hub.slot(Some(&picture(id)), 640.0, 360.0, Priority::Visible))
        .collect();
    slot.finish(&mut swiftly_render::DrawList::new(100.0, 100.0, 1.0));
    shown
}

fn ready(s: &[RemoteSlot]) -> usize {
    s.iter()
        .filter(|s| matches!(s, RemoteSlot::Ready { .. }))
        .count()
}

#[test]
fn the_tab_under_a_page_never_pushes_the_pages_pictures_out() {
    let cx = Cx::deterministic().with_image_page(4096);
    let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
    // One band of six pictures (640 x 360 each): the page in front shows four, the tab below four more.
    let hub = ImageHub::with_region_height(Box::new(loader), &cx, 1.0, Device::Mac, 360);
    let (tab, page) = (screen(&hub), screen(&hub));
    let (front, behind) = (["p1", "p2", "p3", "p4"], ["t1", "t2", "t3", "t4"]);

    build(&page, &hub, &front);
    build(&tab, &hub, &behind);
    hub.settle(1000.0);
    hub.set_hidden(Some(Rc::downgrade(&tab)));

    assert_eq!(ready(&build(&page, &hub, &front)), 4);
    // The hidden tab gets the two places that are free and nothing else.
    assert_eq!(ready(&build(&tab, &hub, &behind)), 2);
    let stamp = hub.stamp();
    for _ in 0..5 {
        assert_eq!(
            ready(&build(&page, &hub, &front)),
            4,
            "the tab below pushed a picture of the page in front out"
        );
        assert_eq!(ready(&build(&tab, &hub, &behind)), 2);
    }
    assert_eq!(
        hub.stamp(),
        stamp,
        "the tab below keeps asking for a rebuild"
    );
    assert_eq!(hub.stale_total(), 0);

    // The page closes: the tab is no longer hidden and takes its room back from what the page leaves.
    hub.set_hidden(None);
    assert!(
        hub.stamp() != stamp,
        "the tab must build anew when it shows again"
    );
}
