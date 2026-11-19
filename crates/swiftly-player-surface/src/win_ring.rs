//! Bookkeeping of the Windows GPU way that needs no operating system call, so it is tested on every host: the ring
//! numbers, the host's table of ring images, the owner of a Win32 handle and the retry delays after a failure.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

static GENERATION: AtomicU64 = AtomicU64::new(0);

/// A ring number no other ring of this process has had or will have. The host looks rings up by it, so two engines
/// (title A, then title B) must never use the same number.
pub fn next_generation() -> u64 {
    GENERATION.fetch_add(1, Ordering::Relaxed) + 1
}

/// One image of the ring as the host's Vulkan device made it. It owns the Win32 handle of its memory: dropping the
/// image closes the handle, unless the engine took it over with [`WinImage::take_handle`] to import it.
pub struct WinImage {
    handle: usize,
    /// Size of the memory allocation in bytes.
    pub mem_size: u64,
    /// Whether the memory was allocated as dedicated to the image.
    pub dedicated: bool,
    closer: fn(usize),
}

impl WinImage {
    /// An image whose handle is closed by `closer` (the platform's `CloseHandle`) when it is dropped.
    pub fn with_closer(handle: usize, mem_size: u64, dedicated: bool, closer: fn(usize)) -> Self {
        WinImage {
            handle,
            mem_size,
            dedicated,
            closer,
        }
    }

    /// The handle, for as long as the image still owns it (0 after [`WinImage::take_handle`]).
    pub fn handle(&self) -> usize {
        self.handle
    }

    /// Hands the handle (and the duty to close it) to the caller.
    pub fn take_handle(&mut self) -> usize {
        std::mem::take(&mut self.handle)
    }
}

impl Drop for WinImage {
    fn drop(&mut self) {
        if self.handle != 0 {
            (self.closer)(self.handle);
        }
    }
}

/// The host's table of the rings the engines asked for, by ring number.
pub struct RingBook<T> {
    rings: Vec<(u64, Vec<T>)>,
}

impl<T> Default for RingBook<T> {
    fn default() -> Self {
        RingBook { rings: Vec::new() }
    }
}

impl<T> RingBook<T> {
    pub const fn new() -> Self {
        RingBook { rings: Vec::new() }
    }

    pub fn insert(&mut self, generation: u64, items: Vec<T>) {
        self.rings.push((generation, items));
    }

    /// The engine freed this ring (or its engine ended): forget it.
    pub fn release(&mut self, generation: u64) {
        self.rings.retain(|(g, _)| *g != generation);
    }

    pub fn get(&self, generation: u64) -> Option<&[T]> {
        self.rings
            .iter()
            .find(|(g, _)| *g == generation)
            .map(|(_, items)| items.as_slice())
    }

    pub fn len(&self) -> usize {
        self.rings.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rings.is_empty()
    }
}

/// Delays between the attempts to make a ring after a failure: 0.25 s, doubling, then the way gives up until the
/// wanted size changes.
#[derive(Default)]
pub struct Backoff {
    failures: u32,
}

const BACKOFF_FIRST: Duration = Duration::from_millis(250);
const BACKOFF_TRIES: u32 = 5;

impl Backoff {
    /// A try failed: how long to wait before the next one, `None` when it is time to give up.
    pub fn failed(&mut self) -> Option<Duration> {
        self.failures += 1;
        (self.failures <= BACKOFF_TRIES).then(|| BACKOFF_FIRST * (1 << (self.failures - 1)))
    }

    pub fn succeeded(&mut self) {
        self.failures = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static CLOSED: Mutex<Vec<usize>> = Mutex::new(Vec::new());

    fn record(h: usize) {
        CLOSED.lock().unwrap().push(h);
    }

    #[test]
    fn ring_numbers_are_unique_across_threads() {
        let all: Vec<u64> = (0..4)
            .map(|_| std::thread::spawn(|| (0..50).map(|_| next_generation()).collect::<Vec<_>>()))
            .flat_map(|t| t.join().unwrap())
            .collect();
        let mut sorted = all.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            all.len(),
            "a ring number was handed out twice"
        );
    }

    #[test]
    fn title_b_never_finds_title_a_ring() {
        // Two engines one after the other: each asks for its first ring.
        let mut book = RingBook::new();
        let a = next_generation();
        book.insert(a, vec!["A frame 0", "A frame 1"]);
        let b = next_generation();
        assert_ne!(a, b);
        book.insert(b, vec!["B frame 0", "B frame 1"]);
        assert_eq!(book.get(b), Some(&["B frame 0", "B frame 1"][..]));
        // Engine A ends: its ring is gone, B's stays.
        book.release(a);
        assert!(book.get(a).is_none());
        assert_eq!(book.get(b).map(<[_]>::len), Some(2));
        assert_eq!(book.len(), 1);
    }

    #[test]
    fn a_partial_ring_closes_every_handle_it_took() {
        // The host made two images, the third failed: the early return drops the vector.
        let before = CLOSED.lock().unwrap().len();
        {
            let images = vec![
                WinImage::with_closer(101, 1, true, record),
                WinImage::with_closer(102, 1, true, record),
            ];
            assert_eq!(images[0].handle(), 101);
        }
        let closed = CLOSED.lock().unwrap();
        assert_eq!(&closed[before..], &[101, 102]);
    }

    #[test]
    fn a_taken_handle_is_not_closed_by_the_image() {
        let before = CLOSED.lock().unwrap().len();
        let mut image = WinImage::with_closer(201, 1, true, record);
        let handle = image.take_handle();
        assert_eq!(handle, 201);
        assert_eq!(image.handle(), 0);
        drop(image);
        assert_eq!(CLOSED.lock().unwrap().len(), before);
    }

    #[test]
    fn retries_slow_down_then_give_up() {
        let mut b = Backoff::default();
        let delays: Vec<_> = (0..6).map(|_| b.failed()).collect();
        let ms = |d: Option<Duration>| d.map(|d| d.as_millis());
        assert_eq!(
            delays.into_iter().map(ms).collect::<Vec<_>>(),
            [
                Some(250),
                Some(500),
                Some(1000),
                Some(2000),
                Some(4000),
                None
            ]
        );
        b.succeeded();
        assert_eq!(b.failed(), Some(BACKOFF_FIRST));
    }
}
