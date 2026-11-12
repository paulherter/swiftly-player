#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Speed features of the loader and the stores: scroll priority, warm-up, placeholders, generation, the disk index,
//! the pluggable decoder, and the memory cache against a plain model.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use swiftly_images::decode::{DecodeError, Decoded, PixelDecoder};
use swiftly_images::fixture::{self, FixtureImages};
use swiftly_images::{
    DiskCache, FolderPlate, ImageLoader, Limits, MemoryImageCache, Priority, Slot,
};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use url::Url;

fn url(id: &str) -> Url {
    Url::parse(&format!(
        "http://fixture.test/Items/{id}/Images/Primary?tag=t&ApiKey=secret"
    ))
    .unwrap()
}

/// Holds every answer until opened and records the order requests arrive in.
struct Held {
    open: Mutex<bool>,
    cv: Condvar,
    order: Mutex<Vec<String>>,
}
impl Held {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            open: Mutex::new(false),
            cv: Condvar::new(),
            order: Mutex::new(Vec::new()),
        })
    }
    fn open(&self) {
        *self.open.lock().unwrap() = true;
        self.cv.notify_all();
    }
    fn seen(&self) -> Vec<String> {
        self.order
            .lock()
            .unwrap()
            .iter()
            .map(|p| p.split('/').nth(2).unwrap().to_owned())
            .collect()
    }
    fn wait_for(&self, n: usize) {
        while self.order.lock().unwrap().len() < n {
            std::thread::yield_now();
        }
    }
}
struct Gated(Arc<Held>);
impl HttpTransport for Gated {
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

fn one_at_a_time(t: &Arc<Held>) -> ImageLoader<Gated> {
    ImageLoader::build(
        Arc::new(Gated(Arc::clone(t))),
        None,
        1 << 28,
        Limits {
            fetch: 1,
            decode: 1,
        },
        Arc::new(swiftly_images::RustDecoder),
    )
}

#[test]
fn while_the_list_flies_the_newest_visible_tile_goes_first_and_warm_up_waits() {
    let t = Held::new();
    let l = one_at_a_time(&t);
    l.request(&url("a"), 100, Priority::Visible);
    t.wait_for(1);
    l.set_fast_scroll(true);
    l.request(&url("b"), 100, Priority::Visible);
    l.request(&url("c"), 100, Priority::Visible);
    l.prefetch(&[url("d")], 100);
    t.open();
    t.wait_for(3);
    std::thread::sleep(std::time::Duration::from_millis(60));
    assert_eq!(t.seen(), ["a", "c", "b"], "newest first, warm-up held");
    l.set_fast_scroll(false);
    l.settle();
    assert_eq!(t.seen(), ["a", "c", "b", "d"]);
}

#[test]
fn calm_scrolling_keeps_ask_order_and_visible_beats_warm_up() {
    let t = Held::new();
    let l = one_at_a_time(&t);
    l.request(&url("a"), 100, Priority::Visible);
    t.wait_for(1);
    l.prefetch(&[url("w1"), url("w2")], 100);
    l.request(&url("b"), 100, Priority::Visible);
    l.request(&url("c"), 100, Priority::Visible);
    // A warm-up job that becomes visible joins the visible ones at the age of its first ask.
    l.request(&url("w2"), 100, Priority::Visible);
    t.open();
    l.settle();
    assert_eq!(
        t.seen(),
        ["a", "w2", "b", "c", "w1"],
        "visible by age of the ask, warm-up last"
    );
}

#[test]
fn leaving_the_screen_drops_queued_warm_up_but_not_visible_work() {
    let t = Held::new();
    let l = one_at_a_time(&t);
    l.request(&url("a"), 100, Priority::Visible);
    t.wait_for(1);
    l.prefetch(&[url("w1"), url("w2")], 100);
    l.request(&url("b"), 100, Priority::Visible);
    assert_eq!(l.cancel_ahead(), 2);
    t.open();
    l.settle();
    l.poll();
    assert_eq!(t.seen(), ["a", "b"]);
    // Dropped work can be asked for again later.
    assert!(matches!(
        l.request(&url("w1"), 100, Priority::Visible),
        Slot::Loading
    ));
    l.settle();
    l.poll();
    assert!(matches!(
        l.request(&url("w1"), 100, Priority::Visible),
        Slot::Ready(_)
    ));
}

#[test]
fn a_placeholder_comes_from_the_blur_hash_and_is_remembered() {
    let l = ImageLoader::with_budget(Arc::new(FixtureImages), None, 1 << 20);
    let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    let a = l.placeholder(&url("p"), hash, 32, 32).unwrap();
    assert_eq!((a.width, a.height, a.rgba.len()), (32, 32, 32 * 32 * 4));
    let b = l.placeholder(&url("p"), hash, 32, 32).unwrap();
    assert!(Arc::ptr_eq(&a, &b));
    assert!(l.placeholder(&url("p"), "not a hash!", 32, 32).is_none());
}

#[test]
fn generation_rises_when_a_picture_leaves_memory() {
    let one = 100 * 150 * 4;
    let l = ImageLoader::with_budget(Arc::new(FixtureImages), None, one + one / 2);
    let g0 = l.generation();
    for id in ["x", "y"] {
        l.request(&url(id), 150, Priority::Visible);
        l.settle();
        l.poll();
    }
    assert!(
        l.generation() > g0,
        "the second picture pushed the first out"
    );
    assert!(l.cached(&url("x")).is_none() || l.cached(&url("y")).is_none());
    let g1 = l.generation();
    l.wipe();
    assert!(l.generation() > g1);
}

struct Counted(AtomicUsize);
impl PixelDecoder for Counted {
    fn decode(&self, bytes: &[u8], border: u32) -> Result<Decoded, DecodeError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        swiftly_images::decode::decode(bytes, border)
    }
}

#[test]
fn the_loader_decodes_through_the_decoder_it_was_given() {
    let dec = Arc::new(Counted(AtomicUsize::new(0)));
    let l = ImageLoader::build(
        Arc::new(FixtureImages),
        None,
        1 << 26,
        Limits {
            fetch: 2,
            decode: 2,
        },
        Arc::clone(&dec) as Arc<dyn PixelDecoder>,
    );
    for id in ["u", "v", "w"] {
        l.request(&url(id), 100, Priority::Visible);
    }
    l.settle();
    l.poll();
    assert_eq!(dec.0.load(Ordering::SeqCst), 3);
    for id in ["u", "v", "w"] {
        let want = swiftly_images::decode::decode(
            &fixture::png(id, fixture::POSTER.0, fixture::POSTER.1),
            100,
        )
        .unwrap();
        assert_eq!(*l.cached(&url(id)).unwrap(), want);
    }
}

#[test]
fn the_disk_index_follows_writes_and_reads_without_listing_the_folder_again() {
    let dir = std::env::temp_dir().join(format!("swiftly-disk-index-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let plate = FolderPlate::new(&dir, 300);
    plate.write(&[1; 100], "a");
    assert_eq!(plate.clean_up(), 0); // the index is built here, by the one scan
    // A file that appears behind the plate's back is not seen: nothing lists the folder a second time.
    std::fs::write(dir.join("stranger"), [9u8; 1000]).unwrap();
    for n in ["b", "c", "d"] {
        plate.write(&[2; 100], n);
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert!(
        plate.read("a").is_some(),
        "a hit refreshes the date in the index"
    );
    assert_eq!(plate.clean_up(), 2);
    assert!(plate.read("a").is_some() && plate.read("d").is_some());
    assert!(plate.read("b").is_none() && plate.read("c").is_none());
    assert!(dir.join("stranger").exists());
    // A file that vanished is dropped from the index on the next read.
    std::fs::remove_file(dir.join("d")).unwrap();
    assert!(plate.read("d").is_none());
    assert_eq!(plate.clean_up(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_memory_cache_agrees_with_a_plain_list_model_over_random_use() {
    let mut cache: MemoryImageCache<u32> = MemoryImageCache::new(1000);
    let mut model: Vec<(String, u32, usize)> = Vec::new(); // least recently used first
    let mut s = 12345u32;
    let mut next = || {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        s
    };
    for step in 0..5000u32 {
        let key = format!("k{}", next() % 40);
        if next() % 3 == 0 {
            let got = cache.get(&key).copied();
            let want = model.iter().position(|e| e.0 == key).map(|i| {
                let e = model.remove(i);
                model.push(e.clone());
                e.1
            });
            assert_eq!(got, want, "step {step}");
        } else {
            let cost = 20 + (next() % 200) as usize;
            cache.insert(&key, step, cost);
            if let Some(e) = model.iter_mut().find(|e| e.0 == key) {
                e.1 = step;
                e.2 = cost;
            } else {
                model.push((key.clone(), step, cost));
            }
            while model.iter().map(|e| e.2).sum::<usize>() > 1000 && !model.is_empty() {
                model.remove(0);
            }
        }
        assert_eq!(cache.len(), model.len(), "step {step}");
        assert_eq!(cache.used(), model.iter().map(|e| e.2).sum::<usize>());
    }
    let table: HashMap<_, _> = model.iter().map(|e| (e.0.clone(), e.1)).collect();
    for (k, v) in table {
        assert_eq!(cache.get(&k).copied(), Some(v));
    }
}
