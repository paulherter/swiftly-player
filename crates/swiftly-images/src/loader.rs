//! The asynchronous loader behind every picture of the Rust UI (`ImageCache.load` in `NetworkImage.swift`):
//! memory cache (least recently used), disk cache, fetch through the [`HttpTransport`] seam with at most
//! four requests at once, decode with at most two at once, in-flight de-duplication, cancel, and priority.
//!
//! The UI thread only calls [`ImageLoader::request`], [`ImageLoader::poll`] and [`ImageLoader::cancel`]; fetch and
//! decode run on a small thread pool and never block it.

use crate::decode::{Decoded, PixelDecoder, RustDecoder};
use crate::memory::{Device, MemoryImageCache};
use crate::slab::{DiskCache, name};
use crate::tone::{ToneCache, tones_from_rgba};
use futures_executor::ThreadPool;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use swiftly_net::{HttpRequest, HttpTransport, Method};
use url::Url;

/// Requests in flight at once (`ImageCache.concurrent`).
pub const FETCH_AT_ONCE: usize = 4;
/// Decodes at once (`ImageCache.convertSimultaneously`).
pub const DECODE_AT_ONCE: usize = 2;

/// How many fetches and decodes may run at once.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Requests in flight.
    pub fetch: usize,
    /// Decodes running.
    pub decode: usize,
}

impl Limits {
    /// Fetches stay at the 4 of `ImageCache` (no network measurement says more helps). Decodes follow the cores:
    /// the 200-tile scroll bench on 8 cores took 825 ms with 2 decodes, 580 ms with 3 and 510 ms with 4, so a
    /// desktop uses half its cores (2 to 4), a phone 3 when it has 6 cores or more, a TV box stays at 2 (little
    /// memory, the picture on screen must not stutter).
    pub fn for_device(device: Device) -> Self {
        let cores = std::thread::available_parallelism().map_or(2, std::num::NonZero::get);
        let decode = match device {
            Device::Mac => (cores / 2).clamp(DECODE_AT_ONCE, 4),
            Device::Phone if cores >= 6 => 3,
            Device::Phone | Device::Tv => DECODE_AT_ONCE,
        };
        Self {
            fetch: FETCH_AT_ONCE,
            decode,
        }
    }
}

/// Who wants the picture. Higher goes first; `Visible` also skips the line the way `preRank` does in Swift.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Priority {
    /// Warm-up for rows that are not on screen yet.
    Ahead,
    /// On screen.
    Visible,
}

/// Why a picture is not there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError {
    /// The request did not get through.
    Network,
    /// The server answered with a status other than 200.
    Status(u16),
    /// The answer is not a readable picture.
    Decode(String),
}

/// What the UI sees for one address.
#[derive(Debug, Clone)]
pub enum Slot {
    /// Not loaded yet (queued or running).
    Loading,
    /// Decoded and in memory.
    Ready(Arc<Decoded>),
    /// Loading failed; the UI shows the symbol.
    Failed(LoadError),
}

struct Job {
    key: String,
    url: Url,
    border: u32,
    priority: Priority,
    seq: u64,
    cancel: Arc<AtomicBool>,
}

struct Running {
    cancel: Arc<AtomicBool>,
}

struct State {
    memory: MemoryImageCache<Arc<Decoded>>,
    tones: ToneCache,
    failed: HashMap<String, LoadError>,
    queue: Vec<Job>,
    running: HashMap<String, Running>,
    fetching: usize,
    decoding: usize,
    done: Vec<(String, Result<Arc<Decoded>, LoadError>)>,
    seq: u64,
    stats: Stats,
    /// The list is flying: only pictures on screen are started, newest first.
    fast: bool,
    placeholders: HashMap<String, Arc<Decoded>>,
}

/// Counters for tests and the debug line.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    /// Pictures read from disk.
    pub disk_hits: u64,
    /// Requests that went to the transport.
    pub fetches: u64,
    /// Decodes that finished (ok or not).
    pub decodes: u64,
    /// Requests dropped before they started or before the result was used.
    pub cancelled: u64,
    /// Most fetches seen at once.
    pub peak_fetching: usize,
    /// Most decodes seen at once.
    pub peak_decoding: usize,
}

struct Shared<T> {
    transport: Arc<T>,
    disk: Option<Arc<dyn DiskCache>>,
    pool: ThreadPool,
    decoder: Arc<dyn PixelDecoder>,
    limits: Limits,
    state: Mutex<State>,
    changed: Condvar,
}

/// The loader. Cheap to clone (shared inside).
pub struct ImageLoader<T: HttpTransport + 'static> {
    shared: Arc<Shared<T>>,
}

impl<T: HttpTransport + 'static> Clone for ImageLoader<T> {
    fn clone(&self) -> Self {
        Self {
            shared: Arc::clone(&self.shared),
        }
    }
}

fn lock<'a>(m: &'a Mutex<State>) -> MutexGuard<'a, State> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl<T: HttpTransport + 'static> ImageLoader<T> {
    /// A loader with the memory budget of `device` and an optional disk cache. `None` for the pool means a
    /// pool of four worker threads.
    pub fn new(transport: Arc<T>, disk: Option<Arc<dyn DiskCache>>, device: Device) -> Self {
        Self::build(
            transport,
            disk,
            device.memory_limit(),
            Limits::for_device(device),
            Arc::new(RustDecoder),
        )
    }

    /// Like [`new`](Self::new) with an explicit memory budget in bytes (tests).
    pub fn with_budget(transport: Arc<T>, disk: Option<Arc<dyn DiskCache>>, limit: usize) -> Self {
        Self::build(
            transport,
            disk,
            limit,
            Limits::for_device(Device::Phone),
            Arc::new(RustDecoder),
        )
    }

    /// Everything explicit: budget, parallelism and the decoder (a shell may pass ImageIO or BitmapFactory).
    pub fn build(
        transport: Arc<T>,
        disk: Option<Arc<dyn DiskCache>>,
        limit: usize,
        limits: Limits,
        decoder: Arc<dyn PixelDecoder>,
    ) -> Self {
        let limits = Limits {
            fetch: limits.fetch.max(1),
            decode: limits.decode.max(1),
        };
        let pool = ThreadPool::builder()
            // A decode holds its thread, so fetches keep their own places.
            .pool_size(limits.fetch + limits.decode)
            .name_prefix("swiftly-image-")
            .create()
            .unwrap_or_else(|_| {
                // A pool is needed; a failure here means the OS refused threads at start-up.
                std::process::abort()
            });
        Self {
            shared: Arc::new(Shared {
                transport,
                disk,
                pool,
                decoder,
                limits,
                state: Mutex::new(State {
                    memory: MemoryImageCache::new(limit),
                    tones: ToneCache::new(),
                    failed: HashMap::new(),
                    queue: Vec::new(),
                    running: HashMap::new(),
                    fetching: 0,
                    decoding: 0,
                    done: Vec::new(),
                    seq: 0,
                    stats: Stats::default(),
                    fast: false,
                    placeholders: HashMap::new(),
                }),
                changed: Condvar::new(),
            }),
        }
    }

    /// The decoded picture if it is in memory (a hit counts as use). Never starts a load.
    pub fn cached(&self, url: &Url) -> Option<Arc<Decoded>> {
        let mut s = lock(&self.shared.state);
        let key = s.memory.key_for(url);
        s.memory.get(&key).cloned()
    }

    /// The state of `url`; starts a load when nothing is known (de-duplicated by cache key). `border` is the
    /// longest edge to decode to (see [`crate::decode::border_for`]). Asking again with a higher priority
    /// moves a queued job forward; asking for a job that was cancelled but has not stopped yet revives it.
    pub fn request(&self, url: &Url, border: u32, priority: Priority) -> Slot {
        let mut s = lock(&self.shared.state);
        let key = s.memory.key_for(url);
        if let Some(hit) = s.memory.get(&key) {
            return Slot::Ready(Arc::clone(hit));
        }
        if let Some(err) = s.failed.get(&key) {
            return Slot::Failed(err.clone());
        }
        // Finished but not yet taken over by `poll`: the picture is on its way into the memory cache, a second
        // fetch and decode would be a waste (and `poll` would count it twice).
        if s.done.iter().any(|(k, _)| *k == key) {
            return Slot::Loading;
        }
        if let Some(run) = s.running.get(&key) {
            run.cancel.store(false, Ordering::SeqCst);
            if let Some(job) = s.queue.iter_mut().find(|j| j.key == key) {
                job.priority = job.priority.max(priority);
            }
            return Slot::Loading;
        }
        s.seq += 1;
        let cancel = Arc::new(AtomicBool::new(false));
        let job = Job {
            key: key.clone(),
            url: url.clone(),
            border,
            priority,
            seq: s.seq,
            cancel: Arc::clone(&cancel),
        };
        s.running.insert(key, Running { cancel });
        s.queue.push(job);
        self.pump(&mut s);
        Slot::Loading
    }

    /// The tile scrolled away: a queued job is dropped, a running one is flagged and its result discarded.
    pub fn cancel(&self, url: &Url) {
        let mut s = lock(&self.shared.state);
        let key = s.memory.key_for(url);
        if let Some(run) = s.running.get(&key) {
            run.cancel.store(true, Ordering::SeqCst);
        }
        if let Some(i) = s.queue.iter().position(|j| j.key == key) {
            s.queue.remove(i);
            s.running.remove(&key);
            s.stats.cancelled += 1;
            self.shared.changed.notify_all();
        }
    }

    /// Warm-up hint from a view model: the pictures of the next screen. Each is asked for at `Ahead` priority,
    /// so anything on screen goes first; already loaded or running ones cost nothing.
    pub fn prefetch(&self, urls: &[Url], border: u32) {
        for url in urls {
            self.request(url, border, Priority::Ahead);
        }
    }

    /// The list scrolls fast (or stopped again): while it flies, only on-screen pictures start, newest first, and
    /// warm-up waits. Stopping starts the held jobs.
    pub fn set_fast_scroll(&self, fast: bool) {
        let mut s = lock(&self.shared.state);
        s.fast = fast;
        self.pump(&mut s);
    }

    /// The screen changed: queued warm-up jobs that nobody asked to show are dropped (running ones finish and
    /// stay cached). Returns how many were dropped.
    pub fn cancel_ahead(&self) -> usize {
        let mut s = lock(&self.shared.state);
        let State { queue, running, .. } = &mut *s;
        let before = queue.len();
        queue.retain(|j| {
            let keep = j.priority != Priority::Ahead;
            if !keep {
                running.remove(&j.key);
            }
            keep
        });
        let dropped = before - queue.len();
        s.stats.cancelled += dropped as u64;
        self.shared.changed.notify_all();
        dropped
    }

    /// A blurred stand-in from the server's blur hash (`ImageBlurHashes`), `width` x `height` pixels, ready to
    /// draw while the real picture loads. Remembered per picture; `None` for a hash that does not parse.
    pub fn placeholder(
        &self,
        url: &Url,
        hash: &str,
        width: u32,
        height: u32,
    ) -> Option<Arc<Decoded>> {
        let mut s = lock(&self.shared.state);
        let id = format!("{}|{hash}|{width}x{height}", s.memory.key_for(url));
        if let Some(found) = s.placeholders.get(&id) {
            return Some(Arc::clone(found));
        }
        let made = Arc::new(crate::blurhash::decode(hash, width, height)?);
        if s.placeholders.len() >= 512 {
            s.placeholders.clear();
        }
        s.placeholders.insert(id, Arc::clone(&made));
        Some(made)
    }

    /// Counts up whenever a picture leaves the memory cache. A tile that remembers the number next to its key
    /// and sees it change asks again instead of drawing a texture slot that may now belong to another tile.
    pub fn generation(&self) -> u64 {
        lock(&self.shared.state).memory.generation()
    }

    /// Forget a failure so the next [`request`](Self::request) tries again (pull to refresh).
    pub fn retry(&self, url: &Url) {
        let mut s = lock(&self.shared.state);
        let key = s.memory.key_for(url);
        s.failed.remove(&key);
    }

    /// Takes finished work into the caches. Returns the keys that became ready or failed since the last call,
    /// so the UI knows to upload and redraw.
    pub fn poll(&self) -> Vec<String> {
        let mut s = lock(&self.shared.state);
        let done = std::mem::take(&mut s.done);
        let mut keys = Vec::new();
        for (key, result) in done {
            match result {
                Ok(img) => {
                    s.memory.insert(&key, Arc::clone(&img), img.cost());
                }
                Err(e) => {
                    s.failed.insert(key.clone(), e);
                }
            }
            keys.push(key);
        }
        keys
    }

    /// Release on a memory warning.
    pub fn wipe(&self) {
        lock(&self.shared.state).memory.wipe();
    }

    /// Memory-warning hook: `Moderate` keeps a quarter of the budget, `Critical` drops every decoded picture.
    /// The disk cache is never touched, so pictures come back from disk without a network trip.
    pub fn trim(&self, level: crate::trim::TrimLevel) {
        let mut state = lock(&self.shared.state);
        match level {
            crate::trim::TrimLevel::Moderate => {
                let keep = state.memory.limit() / 4;
                state.memory.trim_to(keep);
            }
            crate::trim::TrimLevel::Critical => state.memory.wipe(),
        }
    }

    /// The mood-colour hues of a loaded picture (`ImageTone.audioOut`): downscaled to at most 48 pixels,
    /// remembered per cache key. `None` while the picture is not in memory.
    pub fn tones(&self, url: &Url) -> Option<Vec<f64>> {
        let mut s = lock(&self.shared.state);
        let key = s.memory.key_for(url);
        if let Some(t) = s.tones.remembered(&key) {
            return Some(t.to_vec());
        }
        let img = s.memory.get(&key).cloned()?;
        let small = crate::decode::downscale((*img).clone(), 48);
        let t = tones_from_rgba(&small.rgba);
        s.tones.insert(&key, t.clone());
        Some(t)
    }

    /// Blocks until nothing is queued or running. For tests and the headless goldens only.
    pub fn settle(&self) {
        let mut s = lock(&self.shared.state);
        while !s.running.is_empty() || !s.queue.is_empty() {
            s = self
                .shared
                .changed
                .wait(s)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }

    /// Counters.
    pub fn stats(&self) -> Stats {
        lock(&self.shared.state).stats
    }

    /// Number of pictures in memory and the bytes they cost.
    pub fn memory_use(&self) -> (usize, usize) {
        let s = lock(&self.shared.state);
        (s.memory.len(), s.memory.used())
    }

    /// Starts queued jobs while a fetch place is free, highest priority first, then the oldest request.
    fn pump(&self, s: &mut State) {
        while s.fetching < self.shared.limits.fetch && !s.queue.is_empty() {
            // Calm: highest priority, then the oldest ask. Flying: only what is on screen, newest first (the
            // oldest tiles are the ones about to leave the screen).
            let fast = s.fast;
            let best = s
                .queue
                .iter()
                .enumerate()
                .filter(|(_, j)| !(fast && j.priority == Priority::Ahead))
                .max_by_key(|(_, j)| (j.priority, if fast { j.seq } else { u64::MAX - j.seq }))
                .map(|(i, _)| i);
            let Some(i) = best else { break };
            let job = s.queue.remove(i);
            s.fetching += 1;
            s.stats.peak_fetching = s.stats.peak_fetching.max(s.fetching);
            let this = self.clone();
            self.shared.pool.spawn_ok(async move {
                this.run(job).await;
            });
        }
    }

    fn cancelled(job: &Job) -> bool {
        job.cancel.load(Ordering::SeqCst)
    }

    async fn run(&self, mut job: Job) {
        let outcome = self.work(&job).await;
        let mut s = lock(&self.shared.state);
        s.running.remove(&job.key);
        if let Some(result) = outcome {
            if Self::cancelled(&job) {
                s.stats.cancelled += 1;
            } else {
                s.done.push((job.key.clone(), result));
            }
        } else if Self::cancelled(&job) {
            s.stats.cancelled += 1;
        } else {
            // The job stopped because it was cancelled, but the picture was asked for again (`request` revived it)
            // after the worker had looked at the flag for the last time: nobody else would start it, so it runs again.
            s.seq += 1;
            job.seq = s.seq;
            s.running.insert(
                job.key.clone(),
                Running {
                    cancel: Arc::clone(&job.cancel),
                },
            );
            s.queue.push(job);
        }
        self.pump(&mut s);
        self.shared.changed.notify_all();
    }

    /// `None` when cancelled before a result existed.
    async fn work(&self, job: &Job) -> Option<Result<Arc<Decoded>, LoadError>> {
        let slab = name(&job.url);
        let from_disk = slab
            .as_deref()
            .and_then(|n| self.shared.disk.as_ref().and_then(|d| d.read(n)));
        let data = if let Some(bytes) = from_disk {
            lock(&self.shared.state).stats.disk_hits += 1;
            self.release_fetch();
            bytes
        } else {
            if Self::cancelled(job) {
                self.release_fetch();
                return None;
            }
            lock(&self.shared.state).stats.fetches += 1;
            let mut request = HttpRequest::new(Method::Get, job.url.clone());
            request.set_header("Accept", "image/*");
            let answer = self.shared.transport.send(request).await;
            self.release_fetch();
            match answer {
                Err(_) => return Some(Err(LoadError::Network)),
                Ok(r) if r.status != 200 => return Some(Err(LoadError::Status(r.status))),
                Ok(r) => {
                    if let (Some(n), Some(d)) = (slab.as_deref(), self.shared.disk.as_ref()) {
                        d.write(&r.body, n);
                    }
                    r.body
                }
            }
        };
        if Self::cancelled(job) {
            return None;
        }
        self.gate_decode();
        let result = self.shared.decoder.decode(&data, job.border);
        self.leave_decode();
        Some(match result {
            Ok(img) => Ok(Arc::new(img)),
            Err(e) => Err(LoadError::Decode(e.to_string())),
        })
    }

    /// A fetch place becomes free, and the next queued job may start.
    fn release_fetch(&self) {
        let mut s = lock(&self.shared.state);
        s.fetching = s.fetching.saturating_sub(1);
        self.pump(&mut s);
    }

    fn gate_decode(&self) {
        let mut s = lock(&self.shared.state);
        while s.decoding >= self.shared.limits.decode {
            s = self
                .shared
                .changed
                .wait(s)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
        }
        s.decoding += 1;
        s.stats.peak_decoding = s.stats.peak_decoding.max(s.decoding);
    }

    fn leave_decode(&self) {
        let mut s = lock(&self.shared.state);
        s.decoding -= 1;
        s.stats.decodes += 1;
        self.shared.changed.notify_all();
    }
}
