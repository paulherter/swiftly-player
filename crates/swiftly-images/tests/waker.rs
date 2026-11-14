#![allow(clippy::unwrap_used, clippy::expect_used)]
//! A finished load calls the shell's waker, so a picture that lands while the app is idle gets a frame.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use swiftly_images::fixture::FixtureImages;
use swiftly_images::loader::set_arrival_waker;
use swiftly_images::{Device, ImageLoader, Priority};
use url::Url;

#[test]
fn a_finished_load_wakes_the_shell() {
    let woken = Arc::new(AtomicUsize::new(0));
    let w = Arc::clone(&woken);
    set_arrival_waker(Arc::new(move || {
        w.fetch_add(1, Ordering::SeqCst);
    }));
    let l = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
    let url =
        Url::parse("http://fixture.test/Items/w1/Images/Primary?tag=t&ApiKey=secret").unwrap();
    let _ = l.request(&url, 0, Priority::Visible);
    let start = std::time::Instant::now();
    while woken.load(Ordering::SeqCst) == 0 && start.elapsed().as_secs() < 5 {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert!(
        woken.load(Ordering::SeqCst) >= 1,
        "no wake after the load finished"
    );
}
