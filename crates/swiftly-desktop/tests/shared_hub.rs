//! Screens that share one image hub (the start page under a title page) must not cancel each other's pictures.
//!
//! Every rebuild of the start page used to cancel what the title page's last build had asked for, because the hub
//! compared a build only with the previous build of any screen. The backdrop of the film page was cancelled while it
//! loaded; once the page stood still nothing asked for it again, so it stayed a flat gradient until the next input.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;
use swiftly_desktop::hub::{HubSlot, HubSlotExt, ImageHub, RemoteSlot};
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader, Priority};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_ui::Cx;
use swiftly_vm::{ImageKind, ImageRef};

/// The fixture's pictures after a pause, like a server that renders a large backdrop.
struct Slow;

impl HttpTransport for Slow {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        std::thread::sleep(Duration::from_millis(300));
        FixtureImages.send(request).await
    }
}

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

/// One build of `slot`'s screen that shows `ids`.
fn build(slot: &HubSlot, hub: &ImageHub, ids: &[&str]) -> Vec<RemoteSlot> {
    slot.begin_build();
    let shown = ids
        .iter()
        .map(|id| hub.slot(Some(&picture(id)), 640.0, 360.0, Priority::Visible))
        .collect();
    slot.finish(&mut swiftly_render::DrawList::new(100.0, 100.0, 1.0));
    shown
}

fn ready(s: &RemoteSlot) -> bool {
    matches!(s, RemoteSlot::Ready { .. })
}

#[test]
fn a_rebuild_of_the_page_below_does_not_cancel_the_title_pages_backdrop() {
    let cx = Cx::deterministic().with_image_page(4096);
    let loader = ImageLoader::new(Arc::new(Slow), None, Device::Mac);
    let hub = ImageHub::new(Box::new(loader), &cx, 1.0, Device::Mac);
    let home = screen(&hub);
    let title = screen(&hub);

    assert!(!ready(&build(&home, &hub, &["h1"])[0]));
    assert!(!ready(&build(&title, &hub, &["backdrop"])[0]));
    // Pictures of the start page arrive while the backdrop still loads: the page below rebuilds, twice.
    for _ in 0..2 {
        build(&home, &hub, &["h1", "h2"]);
    }
    // Nothing asks for the backdrop again: it must have kept loading and be ready by itself.
    hub.settle(1000.0);
    assert!(
        ready(&build(&title, &hub, &["backdrop"])[0]),
        "the backdrop was cancelled by a rebuild of the page below"
    );
}

#[test]
fn a_picture_leaves_when_no_screen_shows_it_any_more() {
    let cx = Cx::deterministic().with_image_page(4096);
    let loader = ImageLoader::new(Arc::new(Slow), None, Device::Mac);
    let hub = ImageHub::new(Box::new(loader), &cx, 1.0, Device::Mac);
    let home = screen(&hub);
    let title = screen(&hub);
    build(&home, &hub, &["h1", "shared"]);
    build(&title, &hub, &["shared", "gone"]);
    // The page below stops showing "h1" (scrolled away) and the title page stops showing both of its own.
    build(&home, &hub, &["shared"]);
    build(&title, &hub, &["shared"]);
    hub.settle(1000.0);
    // "shared" is still on screen, so it finished and is ready; the two that nobody shows were cancelled, so asking
    // for them again starts a new load instead of finding a result.
    assert!(ready(&build(&home, &hub, &["shared"])[0]));
    let again = build(&home, &hub, &["h1", "gone"]);
    assert!(
        again.iter().all(|s| !ready(s)),
        "a dropped picture finished anyway"
    );
}

#[test]
fn a_closed_screen_gives_up_its_pictures() {
    let cx = Cx::deterministic().with_image_page(4096);
    let loader = ImageLoader::new(Arc::new(Slow), None, Device::Mac);
    let hub = ImageHub::new(Box::new(loader), &cx, 1.0, Device::Mac);
    let home = screen(&hub);
    let title = screen(&hub);
    build(&home, &hub, &["h1"]);
    build(&title, &hub, &["backdrop"]);
    drop(title);
    // The next build of the page below is the first to notice the title page is gone.
    build(&home, &hub, &["h1", "h2"]);
    hub.settle(1000.0);
    let again = build(&home, &hub, &["backdrop"]);
    assert!(
        !ready(&again[0]),
        "the closed page's picture was kept loading"
    );
}
