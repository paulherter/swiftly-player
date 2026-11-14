//! Every picture slot is requested and decoded at least as large as it is drawn on the device.
//!
//! The server (here a stand-in that resizes like Jellyfin: `maxWidth` / `maxHeight` fit the box, never above the
//! original) only sends what the request names, and the loader decodes down to a border. A request or a border below the
//! device pixels of the slot shows as a soft picture: the GPU stretches it.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use swiftly_desktop::hub::{Backend, HubSlot, HubSlotExt, ImageHub, RemoteSlot};
use swiftly_images::{Device, ImageLoader, Priority, Slot, Url};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_ui::Cx;
use swiftly_vm::{ImageKind, ImageRef};

/// A server that holds `original` pictures and answers like Jellyfin's resizer.
struct Resizing;

/// The original of an item: ids starting with `still` are 16:9 Full HD, `back` 4K backdrops, the rest 2:3 posters.
fn original(id: &str) -> (u32, u32) {
    if id.starts_with("back") {
        (3840, 2160)
    } else if id.starts_with("still") {
        (1920, 1080)
    } else {
        (2000, 3000)
    }
}

fn fit(original: (u32, u32), max_w: Option<u32>, max_h: Option<u32>) -> (u32, u32) {
    let k = [
        max_w.map(|w| f64::from(w) / f64::from(original.0)),
        max_h.map(|h| f64::from(h) / f64::from(original.1)),
        Some(1.0),
    ]
    .into_iter()
    .flatten()
    .fold(f64::MAX, f64::min);
    (
        (f64::from(original.0) * k).round() as u32,
        (f64::from(original.1) * k).round() as u32,
    )
}

impl HttpTransport for Resizing {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        let id = request
            .url
            .path_segments()
            .and_then(|mut s| s.nth(1))
            .unwrap_or("x")
            .to_owned();
        let ask = |k: &str| {
            request
                .url
                .query_pairs()
                .find(|(n, _)| n == k)
                .and_then(|(_, v)| v.parse::<u32>().ok())
        };
        let (w, h) = fit(original(&id), ask("maxWidth"), ask("maxHeight"));
        Ok(
            HttpResponse::new(200, swiftly_images::fixture::png(&id, w, h))
                .with_header("Content-Type", "image/png"),
        )
    }
}

/// The loader, noting for every ready picture what it decoded to.
struct Noting {
    inner: ImageLoader<Resizing>,
    decoded: Rc<RefCell<Vec<(String, u32, u32)>>>,
}

impl Backend for Noting {
    fn request(&self, url: &Url, border: u32, priority: Priority) -> Slot {
        let slot = self.inner.request(url, border, priority);
        if let Slot::Ready(img) = &slot {
            self.decoded
                .borrow_mut()
                .push((url.to_string(), img.width, img.height));
        }
        slot
    }
    fn cancel(&self, url: &Url) {
        self.inner.cancel(url);
    }
    fn poll(&self) -> Vec<String> {
        self.inner.poll()
    }
    fn tones(&self, url: &Url) -> Option<Vec<f64>> {
        self.inner.tones(url)
    }
    fn settle(&self) {
        self.inner.settle();
    }
}

/// What the app asks for in each slot (the addresses are those the core builds) and how large the slot is in points.
struct Case {
    name: &'static str,
    address: &'static str,
    points: (f32, f32),
}

const CASES: [Case; 6] = [
    Case {
        name: "poster tile",
        address: "http://h/Items/poster1/Images/Primary?tag=t&maxHeight=360&quality=90",
        points: (150.0, 225.0),
    },
    Case {
        name: "large poster (detail page)",
        address: "http://h/Items/poster1/Images/Primary?tag=t&maxHeight=360&quality=90",
        points: (260.0, 390.0),
    },
    Case {
        name: "landscape tile",
        address: "http://h/Items/back1/Images/Backdrop?tag=t&maxWidth=640&quality=90",
        points: (280.0, 158.0),
    },
    Case {
        name: "header backdrop",
        address: "http://h/Items/back1/Images/Backdrop?tag=t&maxWidth=1200&quality=90",
        points: (1451.0, 454.0),
    },
    Case {
        name: "full-width header backdrop",
        address: "http://h/Items/back1/Images/Backdrop?tag=t&maxWidth=1200&quality=90",
        points: (1920.0, 600.0),
    },
    Case {
        name: "episode still",
        address: "http://h/Items/still1/Images/Primary?tag=t&maxHeight=280&quality=90",
        points: (240.0, 135.0),
    },
];

#[test]
fn no_slot_is_decoded_smaller_than_it_is_drawn() {
    let mut worst = Vec::new();
    for scale in [1.0_f32, 1.5, 2.0] {
        for case in &CASES {
            let cx = Cx::deterministic().with_image_page(4096);
            let decoded = Rc::new(RefCell::new(Vec::new()));
            let loader = ImageLoader::new(Arc::new(Resizing), None, Device::Mac);
            let backend = Noting {
                inner: loader,
                decoded: Rc::clone(&decoded),
            };
            let hub = ImageHub::new(Box::new(backend), &cx, scale, Device::Mac);
            let screen: HubSlot = Rc::new(RefCell::new(None));
            screen.attach(Rc::clone(&hub));
            let image = ImageRef {
                address: case.address.to_owned(),
                kind: ImageKind::Poster,
                wanted_width: case.points.0 as u32,
                wanted_height: case.points.1 as u32,
            };
            let (w, h) = case.points;
            let mut ready = false;
            for round in 0..3 {
                screen.begin_build();
                let slot = hub.slot(Some(&image), w, h, Priority::Visible);
                screen.finish(&mut swiftly_render::DrawList::new(100.0, 100.0, 1.0));
                ready = matches!(slot, RemoteSlot::Ready { .. });
                if ready {
                    break;
                }
                hub.settle(1000.0 * f64::from(round + 1));
            }
            assert!(ready, "{} at {scale}x never became ready", case.name);
            let (_, dw, dh) = decoded.borrow().last().cloned().expect("a decoded picture");
            // The picture covers the slot (`.fill`): the scale that fits the slot's device size into it, cut to its aspect.
            let (tw, th) = ((w * scale).round(), (h * scale).round());
            let cover = (tw / dw as f32).max(th / dh as f32);
            // A picture the server holds only smaller than the slot (the original) cannot be better.
            let id = case.address.split('/').nth(4).unwrap_or("x");
            let orig = original(id);
            let at_original = (dw, dh) == orig;
            if cover > 1.02 && !at_original {
                worst.push(format!(
                    "{} at {scale}x: drawn {tw}x{th} px, decoded {dw}x{dh} (stretched {cover:.2}x)",
                    case.name
                ));
            }
        }
    }
    assert!(worst.is_empty(), "stretched slots:\n{}", worst.join("\n"));
}
