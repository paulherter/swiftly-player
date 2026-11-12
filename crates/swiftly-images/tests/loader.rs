#![allow(clippy::unwrap_used, clippy::expect_used)]
//! The loader: memory and disk hits, eviction, cancel, priority, gates and decode errors, over the fixture server.

use std::sync::{Arc, Condvar, Mutex};
use swiftly_images::decode::{border_for, decode, downscale};
use swiftly_images::fixture::{self, FixtureImages};
use swiftly_images::loader::{DECODE_AT_ONCE, FETCH_AT_ONCE};
use swiftly_images::{Device, ImageLoader, Limits, LoadError, MemoryPlate, Priority, Slot};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use url::Url;

fn url(id: &str) -> Url {
    Url::parse(&format!(
        "http://fixture.test/Items/{id}/Images/Primary?tag=t&ApiKey=secret"
    ))
    .unwrap()
}

/// The fixture server that holds every answer until opened, and records the order requests arrive in.
struct Gate {
    open: Mutex<bool>,
    cv: Condvar,
    order: Mutex<Vec<String>>,
}
impl Gate {
    fn new(open: bool) -> Arc<Self> {
        Arc::new(Self {
            open: Mutex::new(open),
            cv: Condvar::new(),
            order: Mutex::new(Vec::new()),
        })
    }
    fn open(&self) {
        *self.open.lock().unwrap() = true;
        self.cv.notify_all();
    }
}
struct Held(Arc<Gate>);
impl HttpTransport for Held {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        self.0
            .order
            .lock()
            .unwrap()
            .push(request.url.path().to_owned());
        {
            let mut open = self.0.open.lock().unwrap();
            while !*open {
                open = self.0.cv.wait(open).unwrap();
            }
        }
        FixtureImages.send(request).await
    }
}

fn loader() -> ImageLoader<FixtureImages> {
    ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac)
}

fn load_one(l: &ImageLoader<FixtureImages>, id: &str) -> Slot {
    let u = url(id);
    l.request(&u, 400, Priority::Visible);
    l.settle();
    l.poll();
    l.request(&u, 400, Priority::Visible)
}

#[test]
fn a_loaded_picture_is_a_memory_hit_the_second_time() {
    let l = loader();
    assert!(matches!(load_one(&l, "a"), Slot::Ready(_)));
    assert_eq!(l.stats().fetches, 1);
    assert!(matches!(
        l.request(&url("a"), 400, Priority::Visible),
        Slot::Ready(_)
    ));
    assert_eq!(l.stats().fetches, 1);
    // The credential is not part of the key: the same picture under another token is the same entry.
    let other =
        Url::parse("http://fixture.test/Items/a/Images/Primary?tag=t&ApiKey=other").unwrap();
    assert!(l.cached(&other).is_some());
}

#[test]
fn the_decoded_picture_is_cut_to_the_wanted_edge() {
    let l = loader();
    let u = url("big");
    l.request(&u, 100, Priority::Visible);
    l.settle();
    l.poll();
    let Slot::Ready(img) = l.request(&u, 100, Priority::Visible) else {
        panic!("not ready")
    };
    assert_eq!(img.width.max(img.height), 100);
    assert_eq!(img.rgba.len(), img.width as usize * img.height as usize * 4);
}

#[test]
fn the_disk_cache_serves_a_second_loader_without_the_network() {
    let disk: Arc<MemoryPlate> = Arc::new(MemoryPlate::new(10_000_000));
    let first = ImageLoader::new(
        Arc::new(FixtureImages),
        Some(Arc::clone(&disk) as Arc<dyn swiftly_images::DiskCache>),
        Device::Phone,
    );
    first.request(&url("d"), 300, Priority::Visible);
    first.settle();
    first.poll();
    assert_eq!(disk.len(), 1);
    let second = ImageLoader::new(Arc::new(FixtureImages), Some(disk), Device::Phone);
    second.request(&url("d"), 300, Priority::Visible);
    second.settle();
    second.poll();
    let s = second.stats();
    assert_eq!((s.fetches, s.disk_hits), (0, 1));
    assert!(matches!(
        second.request(&url("d"), 300, Priority::Visible),
        Slot::Ready(_)
    ));
}

#[test]
fn memory_evicts_the_least_recently_used_picture() {
    // Room for two 232 x 348 pictures (322,944 bytes each) but not three.
    let l = ImageLoader::with_budget(Arc::new(FixtureImages), None, 700_000);
    for id in ["p1", "p2"] {
        load_one(&l, id);
    }
    assert!(l.cached(&url("p1")).is_some()); // p1 is now the most recently used
    load_one(&l, "p3");
    assert!(l.cached(&url("p2")).is_none(), "p2 was the longest unused");
    assert!(l.cached(&url("p1")).is_some());
    assert!(l.cached(&url("p3")).is_some());
    let (n, bytes) = l.memory_use();
    assert_eq!(n, 2);
    assert!(bytes <= 700_000);
}

#[test]
fn failures_become_error_slots_and_are_not_retried_until_asked() {
    let l = loader();
    assert!(matches!(
        load_one(&l, "missing1"),
        Slot::Failed(LoadError::Status(404))
    ));
    assert!(matches!(
        load_one(&l, "corrupt1"),
        Slot::Failed(LoadError::Decode(_))
    ));
    assert!(matches!(
        load_one(&l, "broken1"),
        Slot::Failed(LoadError::Network)
    ));
    let fetches = l.stats().fetches;
    assert_eq!(fetches, 3);
    load_one(&l, "missing1");
    assert_eq!(l.stats().fetches, fetches, "a failure is remembered");
    l.retry(&url("missing1"));
    load_one(&l, "missing1");
    assert_eq!(l.stats().fetches, fetches + 1);
}

#[test]
fn only_four_fetches_run_at_once_and_a_queued_cancel_never_fetches() {
    let gate = Gate::new(false);
    let l = ImageLoader::new(Arc::new(Held(Arc::clone(&gate))), None, Device::Mac);
    let ids: Vec<String> = (0..7).map(|i| format!("q{i}")).collect();
    for id in &ids {
        l.request(&url(id), 200, Priority::Visible);
    }
    while gate.order.lock().unwrap().len() < FETCH_AT_ONCE {
        std::thread::yield_now();
    }
    l.cancel(&url("q6")); // still queued
    gate.open();
    l.settle();
    let done = l.poll();
    assert_eq!(done.len(), 6);
    let s = l.stats();
    assert_eq!(s.fetches, 6);
    assert!(
        s.peak_fetching <= FETCH_AT_ONCE
            && s.peak_decoding <= Limits::for_device(Device::Mac).decode.max(DECODE_AT_ONCE)
    );
    assert!(s.cancelled >= 1);
    assert!(l.cached(&url("q6")).is_none());
}

#[test]
fn a_cancelled_running_job_is_dropped_and_visible_beats_ahead() {
    let gate = Gate::new(false);
    let l = ImageLoader::new(Arc::new(Held(Arc::clone(&gate))), None, Device::Mac);
    for i in 0..4 {
        l.request(&url(&format!("r{i}")), 200, Priority::Visible);
    }
    while gate.order.lock().unwrap().len() < FETCH_AT_ONCE {
        std::thread::yield_now();
    }
    l.request(&url("ahead"), 200, Priority::Ahead);
    l.request(&url("seen"), 200, Priority::Visible);
    l.cancel(&url("r0")); // running: flagged, result dropped
    gate.open();
    l.settle();
    l.poll();
    let order = gate.order.lock().unwrap().clone();
    let pos = |id: &str| order.iter().position(|p| p.contains(id)).unwrap();
    assert!(pos("seen") < pos("ahead"), "{order:?}");
    assert!(l.cached(&url("r0")).is_none());
    assert!(l.cached(&url("r1")).is_some());
}

#[test]
fn tones_come_from_the_loaded_picture() {
    let l = loader();
    assert!(l.tones(&url("t")).is_none());
    load_one(&l, "t");
    let tones = l.tones(&url("t")).unwrap();
    assert!(!tones.is_empty() && tones.len() <= 5);
    assert_eq!(l.tones(&url("t")).unwrap(), tones);
}

#[test]
fn decode_reads_png_jpeg_and_rejects_garbage() {
    let png = fixture::png("x", 64, 48);
    let img = decode(&png, 1200).unwrap();
    assert_eq!((img.width, img.height), (64, 48));
    assert_eq!(img.rgba, fixture::pixels("x", 64, 48), "PNG is lossless");

    let rgb: Vec<u8> = fixture::pixels("x", 64, 48)
        .chunks(4)
        .flat_map(|p| [p[0], p[1], p[2]])
        .collect();
    let mut jpeg = Vec::new();
    jpeg_encoder::Encoder::new(&mut jpeg, 95)
        .encode(&rgb, 64, 48, jpeg_encoder::ColorType::Rgb)
        .unwrap();
    let back = decode(&jpeg, 1200).unwrap();
    assert_eq!((back.width, back.height), (64, 48));
    let worst = back
        .rgba
        .iter()
        .zip(&img.rgba)
        .map(|(a, b)| a.abs_diff(*b))
        .max()
        .unwrap();
    assert!(worst < 40, "JPEG is lossy but close: {worst}");

    assert!(decode(b"", 100).is_err());
    assert!(decode(b"GIF89a....", 100).is_err());
    assert!(decode(&png[..png.len() / 2], 100).is_err(), "truncated PNG");
    assert!(decode(&jpeg[..20], 100).is_err(), "truncated JPEG");
}

#[test]
fn downscale_keeps_the_ratio_and_never_scales_up() {
    let img = decode(&fixture::png("s", 300, 200), 1200).unwrap();
    let small = downscale(img.clone(), 150);
    assert_eq!((small.width, small.height), (150, 100));
    assert_eq!(downscale(img.clone(), 5000), img);
    // Border: tile edge times 3.2, capped by the device, device cap without a tile.
    assert_eq!(border_for(Some(100.0), Device::Phone), 320);
    assert_eq!(border_for(Some(900.0), Device::Phone), 1200);
    assert_eq!(border_for(Some(900.0), Device::Mac), 1600);
    assert_eq!(border_for(None, Device::Tv), 1200);
}

#[test]
fn a_one_pixel_webp_decodes() {
    // 1 x 1 lossless WebP (base64 UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==).
    let bytes: [u8; 34] = [
        0x52, 0x49, 0x46, 0x46, 0x1a, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c,
        0x0d, 0, 0, 0, 0x2f, 0, 0, 0, 0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07, 0,
    ];
    let img = decode(&bytes, 100).unwrap();
    assert_eq!((img.width, img.height, img.rgba.len()), (1, 1, 4));
}

/// A JPEG of 40 x 20 pixels, left half red and right half blue, with an EXIF orientation segment.
fn jpeg_with_orientation(o: u8) -> Vec<u8> {
    let rgb: Vec<u8> = (0..20)
        .flat_map(|_| (0..40).flat_map(|x| if x < 20 { [255, 0, 0] } else { [0, 0, 255] }))
        .collect();
    let mut jpeg = Vec::new();
    jpeg_encoder::Encoder::new(&mut jpeg, 100)
        .encode(&rgb, 40, 20, jpeg_encoder::ColorType::Rgb)
        .unwrap();
    let mut exif = b"Exif\0\0MM\0*\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01".to_vec();
    exif.extend_from_slice(&[0, o, 0, 0, 0, 0, 0, 0]);
    let mut out = vec![0xFF, 0xD8, 0xFF, 0xE1];
    out.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(&exif);
    out.extend_from_slice(&jpeg[2..]);
    out
}

#[test]
fn exif_orientation_turns_the_picture() {
    let plain = decode(&jpeg_with_orientation(1), 1200).unwrap();
    assert_eq!((plain.width, plain.height), (40, 20));
    assert!(plain.pixel_is_red(5, 10) && !plain.pixel_is_red(35, 10));
    // 6: turn 90 clockwise. The left (red) half ends up on top of a 20 x 40 picture.
    let six = decode(&jpeg_with_orientation(6), 1200).unwrap();
    assert_eq!((six.width, six.height), (20, 40));
    assert!(six.pixel_is_red(10, 5) && !six.pixel_is_red(10, 35));
    // 8: counter-clockwise, red at the bottom.
    let eight = decode(&jpeg_with_orientation(8), 1200).unwrap();
    assert!(!eight.pixel_is_red(10, 5) && eight.pixel_is_red(10, 35));
    // 3: turn 180, red on the right. 2: mirror, red on the right.
    assert!(
        decode(&jpeg_with_orientation(3), 1200)
            .unwrap()
            .pixel_is_red(35, 10)
    );
    assert!(
        decode(&jpeg_with_orientation(2), 1200)
            .unwrap()
            .pixel_is_red(35, 10)
    );
}

trait RedProbe {
    fn pixel_is_red(&self, x: usize, y: usize) -> bool;
}
impl RedProbe for swiftly_images::Decoded {
    fn pixel_is_red(&self, x: usize, y: usize) -> bool {
        let i = (y * self.width as usize + x) * 4;
        self.rgba[i] > 200 && self.rgba[i + 2] < 60
    }
}
