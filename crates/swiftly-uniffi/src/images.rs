//! The picture loader the host draws from: memory cache, disk plate, fetch through the host's own HTTP
//! (so the Apple binary carries no TLS stack), decode off the UI thread, de-duplication, cancel and
//! priority. The host asks per address (`request`), hears finished work with `poll`, and uploads the
//! RGBA pixels itself. Tone and mood maths for the pictures are in `visual.rs`.

use std::path::PathBuf;
use std::sync::Arc;

use swiftly_images::{
    Decoded, Device, DiskCache, FolderPlate, ImageLoader as Loader, LoadError, Priority, Slot,
    Trim, TrimLevel, Url, border_for,
};

use crate::transport::ForeignTransport;

/// Which kind of device the budgets are for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ImageDevice {
    /// macOS and the desktop shells.
    Mac,
    /// tvOS and Android TV.
    Tv,
    /// iPhone, iPad, Android.
    Phone,
}

impl ImageDevice {
    fn device(self) -> Device {
        match self {
            Self::Mac => Device::Mac,
            Self::Tv => Device::Tv,
            Self::Phone => Device::Phone,
        }
    }
}

/// Who wants the picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ImagePriority {
    /// On screen: goes first.
    Visible,
    /// Rows that are not on screen yet.
    Ahead,
    /// Warm-up for the next screen (same line as `Ahead`; dropped by `cancel_ahead`).
    Prefetch,
}

impl ImagePriority {
    fn priority(self) -> Priority {
        match self {
            Self::Visible => Priority::Visible,
            Self::Ahead | Self::Prefetch => Priority::Ahead,
        }
    }
}

/// Decoded pixels, straight RGBA, 8 bit, row by row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImagePixels {
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
    /// `width * height * 4` bytes.
    pub rgba: Vec<u8>,
}

fn pixels_of(d: &Decoded) -> ImagePixels {
    ImagePixels {
        width: d.width,
        height: d.height,
        rgba: d.rgba.clone(),
    }
}

/// What the host sees for one address.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ImageSlot {
    /// Queued or running; `poll` names it when it is done.
    Loading,
    /// Decoded and in memory.
    Ready {
        /// The picture.
        image: ImagePixels,
    },
    /// Loading failed; show the symbol. `retry` forgets the failure.
    Failed {
        /// `network`, `status` or `decode`.
        kind: String,
        /// The HTTP status for `status`.
        status: Option<u16>,
    },
}

fn failed(kind: &str, status: Option<u16>) -> ImageSlot {
    ImageSlot::Failed {
        kind: kind.to_owned(),
        status,
    }
}

fn slot_of(slot: Slot) -> ImageSlot {
    match slot {
        Slot::Loading => ImageSlot::Loading,
        Slot::Ready(d) => ImageSlot::Ready {
            image: pixels_of(&d),
        },
        Slot::Failed(LoadError::Network) => failed("network", None),
        Slot::Failed(LoadError::Status(s)) => failed("status", Some(s)),
        Slot::Failed(LoadError::Decode(_)) => failed("decode", None),
    }
}

/// Counters of the loader (debug line, tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ImageStats {
    /// Pictures read from the disk plate.
    pub disk_hits: u64,
    /// Requests that went to the host's HTTP.
    pub fetches: u64,
    /// Decodes finished.
    pub decodes: u64,
    /// Requests dropped before the result was used.
    pub cancelled: u64,
    /// Pictures in memory.
    pub in_memory: u64,
    /// Bytes of the pictures in memory.
    pub memory_bytes: u64,
}

/// One loader per app. Obtained from `Core::image_loader`.
#[derive(uniffi::Object)]
pub struct ImageLoader {
    inner: Arc<Loader<ForeignTransport>>,
    device: Device,
}

impl ImageLoader {
    pub(crate) fn build(
        transport: ForeignTransport,
        cache_dir: Option<String>,
        device: ImageDevice,
    ) -> Arc<Self> {
        let device = device.device();
        let disk = cache_dir.filter(|d| !d.is_empty()).map(|dir| {
            let folder = PathBuf::from(dir).join("images");
            Arc::new(FolderPlate::new(folder, device.disk_limit())) as Arc<dyn DiskCache>
        });
        Arc::new(Self {
            inner: Arc::new(Loader::new(Arc::new(transport), disk, device)),
            device,
        })
    }

    /// The loader as a memory-pressure sink (the registry keeps only a weak reference).
    pub(crate) fn trim_sink(&self) -> Arc<dyn Trim> {
        Arc::clone(&self.inner) as Arc<dyn Trim>
    }
}

fn parse(url: &str) -> Option<Url> {
    Url::parse(url).ok()
}

#[uniffi::export]
impl ImageLoader {
    /// The state of an address; starts a load when nothing is known. `border` is the longest edge to
    /// decode to (`border_for`). Asking again with a higher priority moves a queued job forward.
    pub fn request(&self, url: String, border: u32, priority: ImagePriority) -> ImageSlot {
        match parse(&url) {
            Some(u) => slot_of(self.inner.request(&u, border, priority.priority())),
            None => failed("network", None),
        }
    }

    /// The picture if it is in memory. Never starts a load.
    pub fn cached(&self, url: String) -> Option<ImagePixels> {
        let u = parse(&url)?;
        self.inner.cached(&u).map(|d| pixels_of(&d))
    }

    /// The tile scrolled away: a queued job is dropped, a running one is flagged and its result discarded.
    pub fn cancel(&self, url: String) {
        if let Some(u) = parse(&url) {
            self.inner.cancel(&u);
        }
    }

    /// Warm-up hint: the pictures of the next screen, at the lowest priority.
    pub fn prefetch(&self, urls: Vec<String>, border: u32) {
        let urls: Vec<Url> = urls.iter().filter_map(|u| parse(u)).collect();
        self.inner.prefetch(&urls, border);
    }

    /// The list flies (or stopped): while it flies only pictures on screen start, newest first.
    pub fn set_fast_scroll(&self, fast: bool) {
        self.inner.set_fast_scroll(fast);
    }

    /// The screen changed: queued warm-up jobs are dropped. Returns how many.
    pub fn cancel_ahead(&self) -> u32 {
        u32::try_from(self.inner.cancel_ahead()).unwrap_or(u32::MAX)
    }

    /// A blurred stand-in from the server's blur hash, ready to draw while the picture loads.
    pub fn placeholder(
        &self,
        url: String,
        hash: String,
        width: u32,
        height: u32,
    ) -> Option<ImagePixels> {
        let u = parse(&url)?;
        self.inner
            .placeholder(&u, &hash, width, height)
            .map(|d| pixels_of(&d))
    }

    /// Counts up whenever a picture leaves memory; a tile that sees it change asks again.
    pub fn generation(&self) -> u64 {
        self.inner.generation()
    }

    /// Forgets a failure so the next `request` tries again.
    pub fn retry(&self, url: String) {
        if let Some(u) = parse(&url) {
            self.inner.retry(&u);
        }
    }

    /// Takes finished work into memory; returns the cache keys that became ready or failed.
    pub fn poll(&self) -> Vec<String> {
        self.inner.poll()
    }

    /// The mood hues of a loaded picture (`None` while it is not in memory).
    pub fn tones(&self, url: String) -> Option<Vec<f64>> {
        let u = parse(&url)?;
        self.inner.tones(&u)
    }

    /// Memory warning: `0` keeps a quarter of the budget, anything else drops every picture.
    /// The disk plate is never touched.
    pub fn trim(&self, level: u8) {
        self.inner.trim(TrimLevel::from_code(level));
    }

    /// Drops every picture from memory.
    pub fn wipe(&self) {
        self.inner.wipe();
    }

    /// The longest edge to decode to for a tile of `display_edge_points` (3.2 per point, capped by the
    /// device); without an edge the device limit.
    pub fn border_for(&self, display_edge_points: Option<f32>) -> u32 {
        border_for(display_edge_points, self.device)
    }

    /// Counters.
    pub fn stats(&self) -> ImageStats {
        let s = self.inner.stats();
        let (n, bytes) = self.inner.memory_use();
        ImageStats {
            disk_hits: s.disk_hits,
            fetches: s.fetches,
            decodes: s.decodes,
            cancelled: s.cancelled,
            in_memory: n as u64,
            memory_bytes: bytes as u64,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::{HttpClient, HttpFailure, NetHeader, NetRequest, NetResponse};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Fake {
        calls: AtomicUsize,
    }

    #[async_trait::async_trait]
    impl HttpClient for Fake {
        async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if request.url.contains("/missing/") {
                return Ok(NetResponse {
                    status: 404,
                    headers: Vec::new(),
                    body: Vec::new(),
                    url: None,
                });
            }
            Ok(NetResponse {
                status: 200,
                headers: vec![NetHeader {
                    name: "Content-Type".into(),
                    value: "image/png".into(),
                }],
                body: swiftly_images::fixture::png("abc", 32, 48),
                url: None,
            })
        }
    }

    fn loader(dir: Option<String>) -> (Arc<ImageLoader>, Arc<Fake>) {
        let fake = Arc::new(Fake {
            calls: AtomicUsize::new(0),
        });
        let client: Arc<dyn HttpClient> = Arc::clone(&fake) as _;
        (
            ImageLoader::build(ForeignTransport(client), dir, ImageDevice::Phone),
            fake,
        )
    }

    /// Asks until the slot is no longer loading.
    fn settled(l: &ImageLoader, url: &str) -> ImageSlot {
        for _ in 0..500 {
            l.poll();
            let s = l.request(url.to_owned(), 1200, ImagePriority::Visible);
            if s != ImageSlot::Loading {
                return s;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        ImageSlot::Loading
    }

    #[test]
    fn loads_decodes_and_keeps_one_fetch_for_two_asks() {
        let (l, fake) = loader(None);
        let url = "https://example.test/Items/abc/Images/Primary";
        assert_eq!(
            l.request(url.into(), 1200, ImagePriority::Visible),
            ImageSlot::Loading
        );
        l.prefetch(vec![url.into()], 1200);
        let ImageSlot::Ready { image } = settled(&l, url) else {
            panic!("not ready")
        };
        assert_eq!((image.width, image.height), (32, 48));
        assert_eq!(image.rgba.len(), 32 * 48 * 4);
        assert_eq!(fake.calls.load(Ordering::SeqCst), 1);
        assert!(l.cached(url.into()).is_some());
        assert!(l.tones(url.into()).is_some());
        assert_eq!(l.stats().in_memory, 1);
        l.trim(1);
        assert!(l.cached(url.into()).is_none());
    }

    #[test]
    fn a_missing_picture_fails_with_its_status_and_retry_asks_again() {
        let (l, fake) = loader(None);
        let url = "https://example.test/missing/Items/x/Images/Primary";
        l.request(url.into(), 1200, ImagePriority::Visible);
        assert_eq!(settled(&l, url), failed("status", Some(404)));
        l.retry(url.into());
        assert_eq!(
            l.request(url.into(), 1200, ImagePriority::Visible),
            ImageSlot::Loading
        );
        assert_eq!(settled(&l, url), failed("status", Some(404)));
        assert_eq!(fake.calls.load(Ordering::SeqCst), 2);
        assert_eq!(
            l.request("not a url".into(), 600, ImagePriority::Visible),
            failed("network", None)
        );
    }

    #[test]
    fn the_disk_plate_answers_a_second_loader_without_a_fetch() {
        let dir = std::env::temp_dir().join(format!("swiftly-images-test-{}", std::process::id()));
        let path = dir.to_string_lossy().into_owned();
        // Only addresses with a `tag` (Jellyfin's fingerprint) go to disk.
        let url = "https://example.test/Items/abc/Images/Primary?tag=t1";
        let (first, f1) = loader(Some(path.clone()));
        assert!(matches!(settled(&first, url), ImageSlot::Ready { .. }));
        assert_eq!(f1.calls.load(Ordering::SeqCst), 1);
        let (second, f2) = loader(Some(path));
        assert!(matches!(settled(&second, url), ImageSlot::Ready { .. }));
        assert_eq!(f2.calls.load(Ordering::SeqCst), 0);
        assert_eq!(second.stats().disk_hits, 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn warm_up_is_dropped_while_the_list_flies_and_border_follows_the_device() {
        let (l, _) = loader(None);
        l.set_fast_scroll(true);
        l.prefetch(
            vec!["https://example.test/Items/p1/Images/Primary".into()],
            300,
        );
        assert_eq!(l.cancel_ahead(), 1);
        assert_eq!(l.border_for(Some(100.0)), 320);
        assert_eq!(l.border_for(None), 1200);
    }
}
