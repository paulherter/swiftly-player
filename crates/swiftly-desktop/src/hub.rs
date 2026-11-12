//! The bridge between the image loader and the screens (`NetworkImage` in Swift): resolves an `ImageRef` of a view
//! model tile to a placeholder, a fading-in picture or the error symbol; uploads decoded pictures into a region of
//! the shared image page (the software renderer samples it, the wgpu renderer uploads its dirty rectangle); asks
//! for visible tiles first and cancels what scrolled away; hands out mood-colour hues.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;
use swiftly_images::decode::downscale;
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Decoded, Device, ImageLoader, Priority, Slot, Url, image_key};
use swiftly_layout::Alignment;
use swiftly_net::HttpTransport;
use swiftly_render::{Atlas, DrawList, QuadKind};
use swiftly_ui::icons::Icons;
use swiftly_ui::view::{Node, Paint};
use swiftly_ui::{Cx, ImageId};
use swiftly_vm::ImageRef;

/// How long a picture takes to fade in: `Theme.reveal`, `easeInOut(0.28)` (`NetworkImage.swift:523`).
pub const REVEAL_MS: f64 = swiftly_ui::feel::REVEAL_SECONDS * 1000.0;

/// Opacity of a picture `age_ms` after it arrived: the catalogued `reveal` curve (easeInOut), not a linear ramp.
pub fn reveal_alpha(age_ms: f64) -> f32 {
    swiftly_motion::catalogue::Id::Reveal
        .curve()
        .progress(age_ms / 1000.0)
        .clamp(0.0, 1.0) as f32
}

/// What a view draws for one picture.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RemoteSlot {
    /// Nothing yet: the tile background shows (Swift draws nothing while loading).
    Loading,
    /// Decoded and uploaded; `alpha` runs 0 to 1 while it fades in.
    Ready {
        /// The part of the page, already cropped to fill the tile.
        image: ImageId,
        /// Fade-in opacity.
        alpha: f32,
    },
    /// No address or loading failed: the symbol shows.
    Failed,
}

/// Draws a [`RemoteSlot`]: nothing while loading, the picture with its fade, or `symbol` centred.
pub fn remote_node(
    slot: RemoteSlot,
    w: f32,
    h: f32,
    radius: f32,
    symbol: impl FnOnce() -> Node,
) -> Node {
    match slot {
        RemoteSlot::Loading => Node::fixed(w, h),
        RemoteSlot::Ready { image, alpha } => {
            let mut n = Node::image(image, w, h, radius);
            for p in &mut n.paint {
                if let Paint::Image { tint, .. } = p {
                    tint.a = alpha.clamp(0.0, 1.0);
                }
            }
            n
        }
        RemoteSlot::Failed => Node::fixed(w, h).overlay(symbol(), Alignment::CENTER),
    }
}

/// The loader without its transport type.
pub trait Backend {
    /// See `ImageLoader::request`.
    fn request(&self, url: &Url, border: u32, priority: Priority) -> Slot;
    /// See `ImageLoader::cancel`.
    fn cancel(&self, url: &Url);
    /// See `ImageLoader::poll`.
    fn poll(&self) -> Vec<String>;
    /// See `ImageLoader::tones`.
    fn tones(&self, url: &Url) -> Option<Vec<f64>>;
    /// Blocks until idle (headless goldens).
    fn settle(&self);
}

impl<T: HttpTransport + 'static> Backend for ImageLoader<T> {
    fn request(&self, url: &Url, border: u32, priority: Priority) -> Slot {
        ImageLoader::request(self, url, border, priority)
    }
    fn cancel(&self, url: &Url) {
        ImageLoader::cancel(self, url);
    }
    fn poll(&self) -> Vec<String> {
        ImageLoader::poll(self)
    }
    fn tones(&self, url: &Url) -> Option<Vec<f64>> {
        ImageLoader::tones(self, url)
    }
    fn settle(&self) {
        ImageLoader::settle(self);
    }
}

/// One picture in the region, cut to the size of the tile it was made for.
struct Entry {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// The exact rectangle handed to views; carries a generation in its sub-texel offset.
    uv: [f32; 4],
    /// View run in which a tile last asked for it; entries of the current run are never evicted.
    epoch: u64,
    /// Order of use for least-recently-used eviction.
    used: u64,
}

/// Where pictures live in the shared page. Bands of equal-ish height, least recently used out first; every
/// handed-out rectangle has a unique generation in its sub-texel offset so a stale one is recognised at draw time.
struct Region {
    x0: u32,
    y0: u32,
    w: u32,
    h: u32,
    page_w: u32,
    page_h: u32,
    entries: HashMap<String, Entry>,
    live: HashMap<[u32; 4], String>,
    clock: u64,
    gen_counter: u32,
}

fn bits(uv: [f32; 4]) -> [u32; 4] {
    uv.map(f32::to_bits)
}

impl Region {
    fn place(&self, w: u32, h: u32) -> Option<(u32, u32)> {
        let mut bands: std::collections::BTreeMap<u32, (u32, Vec<(u32, u32)>)> =
            std::collections::BTreeMap::new();
        for e in self.entries.values() {
            let b = bands.entry(e.y).or_insert((0, Vec::new()));
            b.0 = b.0.max(e.h);
            b.1.push((e.x, e.x + e.w));
        }
        for (y, (bh, spans)) in &mut bands {
            if *bh < h || *bh > h + h / 3 {
                continue;
            }
            spans.sort_unstable();
            let mut cursor = 0;
            for (s, e) in spans.iter() {
                if s - cursor.min(*s) >= w && *s >= cursor + w {
                    return Some((cursor, *y));
                }
                cursor = cursor.max(*e);
            }
            if self.w - cursor.min(self.w) >= w {
                return Some((cursor, *y));
            }
        }
        let mut cursor = 0;
        for (y, (bh, _)) in &bands {
            if *y >= cursor + h {
                return Some((0, cursor));
            }
            cursor = cursor.max(y + bh);
        }
        (self.h >= cursor + h).then_some((0, cursor))
    }

    /// Frees the least recently used entry of an older view run. `false` when everything is in use.
    fn evict(&mut self, epoch: u64) -> bool {
        let victim = self
            .entries
            .iter()
            .filter(|(_, e)| e.epoch < epoch)
            .min_by_key(|(_, e)| e.used)
            .map(|(k, _)| k.clone());
        let Some(k) = victim else { return false };
        if let Some(e) = self.entries.remove(&k) {
            self.live.remove(&bits(e.uv));
        }
        true
    }

    fn next_uv(&mut self, x: u32, y: u32, w: u32, h: u32) -> [f32; 4] {
        self.gen_counter += 1;
        let g = self.gen_counter;
        // Up to 0.4 texel from the left and top edge: 2^20 distinct rectangles per place, invisible when sampled.
        let sx = (g & 1023) as f32 / 1024.0 * 0.4;
        let sy = ((g >> 10) & 1023) as f32 / 1024.0 * 0.4;
        let (pw, ph) = (self.page_w as f32, self.page_h as f32);
        [
            (x as f32 + sx) / pw,
            (y as f32 + sy) / ph,
            (x + w) as f32 / pw,
            (y + h) as f32 / ph,
        ]
    }

    /// Whether `uv` lies in this region's rows.
    fn covers(&self, uv: [f32; 4]) -> bool {
        let ph = self.page_h as f32;
        uv[1] >= self.y0 as f32 / ph - 1e-6 && uv[3] <= (self.y0 + self.h) as f32 / ph + 1e-6
    }
}

struct State {
    region: Option<Region>,
    waiting: HashSet<String>,
    born: HashMap<String, f64>,
    now: f64,
    arrivals: u64,
    epoch: u64,
    blocked: bool,
    stale_total: u64,
    touched: Vec<(String, Url)>,
    last: Vec<(String, Url)>,
}

/// The hub. One per screen set; shares the `Cx` image page.
pub struct ImageHub {
    backend: RefCell<Box<dyn Backend>>,
    cx: Cx,
    scale: f32,
    device: Device,
    icons: Icons,
    state: RefCell<State>,
}

/// The slot a screen keeps; empty means "demo art".
pub type HubSlot = Rc<RefCell<Option<Rc<ImageHub>>>>;

/// Per-screen glue so every screen hooks the hub the same way.
pub trait HubSlotExt {
    /// Attaches a hub.
    fn attach(&self, hub: Rc<ImageHub>);
    /// Start of a frame: takes finished loads.
    fn frame(&self, now_ms: f64);
    /// Value for the screen's `Parts`; changes when a rebuild is needed.
    fn stamp(&self) -> u64;
    /// Start of a view run.
    fn begin_build(&self);
    /// After the frame: cancels what scrolled away and blanks any stale rectangle. Returns stale quads blanked.
    fn finish(&self, list: &mut DrawList) -> usize;
    /// A load or fade is running.
    fn busy(&self) -> bool;
    /// Waits for every load (headless goldens).
    fn settle(&self, now_ms: f64);
}

impl HubSlotExt for HubSlot {
    fn attach(&self, hub: Rc<ImageHub>) {
        *self.borrow_mut() = Some(hub);
    }
    fn frame(&self, now_ms: f64) {
        if let Some(h) = self.borrow().as_ref() {
            h.frame(now_ms);
        }
    }
    fn stamp(&self) -> u64 {
        self.borrow().as_ref().map_or(0, |h| h.stamp())
    }
    fn begin_build(&self) {
        if let Some(h) = self.borrow().as_ref() {
            h.begin_build();
        }
    }
    fn finish(&self, list: &mut DrawList) -> usize {
        let hub = self.borrow().clone();
        hub.map_or(0, |h| {
            h.after_build();
            h.sanitize(list)
        })
    }
    fn busy(&self) -> bool {
        self.borrow().as_ref().is_some_and(|h| h.busy())
    }
    fn settle(&self, now_ms: f64) {
        let hub = self.borrow().clone();
        if let Some(h) = hub {
            h.settle(now_ms);
        }
    }
}

/// Rows of the shared image page the hub's picture region leaves free for icons and other small images added later.
pub const ICON_RESERVE_ROWS: u32 = 512;

impl ImageHub {
    /// A hub over `backend`, uploading into a region of `cx`'s page (as tall as fits).
    pub fn new(backend: Box<dyn Backend>, cx: &Cx, scale: f32, device: Device) -> Rc<ImageHub> {
        ImageHub::with_region_height(backend, cx, scale, device, 2048)
    }

    /// Like [`new`](Self::new) with the wanted region height (tests use a small one to force eviction).
    pub fn with_region_height(
        backend: Box<dyn Backend>,
        cx: &Cx,
        scale: f32,
        device: Device,
        rows: u32,
    ) -> Rc<ImageHub> {
        let page = cx.images.borrow().page.size();
        let mut region = None;
        // The region never takes the whole page: icons, glyphs and animations that appear later (settings rows, the
        // player) are added to the same page and need room (an empty icon column in the real app otherwise).
        let used = {
            let (_, y, row_h) = cx.images.borrow().cursor();
            y + row_h
        };
        let mut h = rows.min(page.1.saturating_sub(used + ICON_RESERVE_ROWS));
        while h >= 128 {
            let black = vec![0_u8; (page.0 * h * 4) as usize];
            if let Some(id) = cx.add_image(page.0, h, &black) {
                let x0 = (id.uv[0] * page.0 as f32).round() as u32;
                let y0 = (id.uv[1] * page.1 as f32).round() as u32;
                region = Some(Region {
                    x0,
                    y0,
                    w: page.0,
                    h,
                    page_w: page.0,
                    page_h: page.1,
                    entries: HashMap::new(),
                    live: HashMap::new(),
                    clock: 0,
                    gen_counter: 0,
                });
                break;
            }
            h = if h > 1024 { 1024 } else { h - 128 };
        }
        Rc::new(ImageHub {
            backend: RefCell::new(backend),
            cx: cx.clone(),
            scale,
            device,
            icons: Icons::new(cx, scale),
            state: RefCell::new(State {
                region,
                waiting: HashSet::new(),
                born: HashMap::new(),
                now: 0.0,
                arrivals: 1,
                epoch: 1,
                blocked: false,
                stale_total: 0,
                touched: Vec::new(),
                last: Vec::new(),
            }),
        })
    }

    /// The pixel scale the hub was made for.
    pub fn scale(&self) -> f32 {
        self.scale
    }

    /// Points the hub at another account's loader and forgets every picture of the old one. The hub keeps its rows of
    /// the shared page (a new hub per account would claim new rows each time, and the page is never given back, so the
    /// third account would have no room left and every poster would stay grey).
    pub fn rebind(&self, backend: Box<dyn Backend>) {
        *self.backend.borrow_mut() = backend;
        let mut guard = self.state.borrow_mut();
        let s = &mut *guard;
        if let Some(r) = s.region.as_mut() {
            r.entries.clear();
            r.live.clear();
        }
        s.waiting.clear();
        s.born.clear();
        s.touched.clear();
        s.last.clear();
        s.blocked = false;
        s.epoch += 1;
        s.arrivals += 1;
    }

    /// The demo hub: the fixture image server, no disk cache.
    pub fn fixture(cx: &Cx, scale: f32, device: Device) -> Rc<ImageHub> {
        let loader = ImageLoader::new(Arc::new(FixtureImages), None, device);
        ImageHub::new(Box::new(loader), cx, scale, device)
    }

    /// Takes finished loads and the clock of this frame. Call once per frame before the view is rebuilt.
    pub fn frame(&self, now_ms: f64) {
        let arrived = self.backend.borrow().poll();
        let mut guard = self.state.borrow_mut();
        let s = &mut *guard;
        s.now = now_ms;
        s.arrivals += arrived.len() as u64;
        s.born.retain(|_, t| now_ms - *t < REVEAL_MS);
        // A tile was denied room: once an older entry can go, rebuild so it asks again.
        if s.blocked
            && s.region
                .as_ref()
                .is_some_and(|r| r.entries.values().any(|e| e.epoch < s.epoch))
        {
            s.blocked = false;
            s.arrivals += 1;
        }
    }

    /// A view run starts: entries asked for from now on belong to it and are safe from eviction until the next run.
    pub fn begin_build(&self) {
        self.state.borrow_mut().epoch += 1;
    }

    /// Cancels loads of tiles that were in the last build but not in this one (they scrolled away). A frame
    /// without a rebuild changes nothing.
    pub fn after_build(&self) {
        let mut guard = self.state.borrow_mut();
        let s = &mut *guard;
        if s.touched.is_empty() {
            return;
        }
        let seen: HashSet<&String> = s.touched.iter().map(|(k, _)| k).collect();
        for (k, url) in &s.last {
            if !seen.contains(k) && s.waiting.remove(k) {
                self.backend.borrow().cancel(url);
            }
        }
        s.last = std::mem::take(&mut s.touched);
    }

    /// Blanks every picture quad of the page region whose rectangle is not a live one (a node that outlived its
    /// entry) and asks for a rebuild. A tile can therefore show its own picture or nothing, never another's.
    /// Returns how many quads were blanked.
    pub fn sanitize(&self, list: &mut DrawList) -> usize {
        let mut guard = self.state.borrow_mut();
        let s = &mut *guard;
        let Some(region) = s.region.as_ref() else {
            return 0;
        };
        let mut stale = 0;
        for q in list.quads_mut() {
            if q.kind == QuadKind::Image
                && region.covers(q.uv)
                && !region.live.contains_key(&bits(q.uv))
            {
                q.color.a = 0.0;
                stale += 1;
            }
        }
        if stale > 0 {
            s.arrivals += 1;
            s.stale_total += stale as u64;
        }
        stale
    }

    /// The cache key of the picture drawn with `uv`, if the rectangle is live (tests).
    pub fn owner_of(&self, uv: [f32; 4]) -> Option<String> {
        let s = self.state.borrow();
        s.region.as_ref()?.live.get(&bits(uv)).cloned()
    }

    /// Whether `uv` is a rectangle of the region at all (tests).
    pub fn in_region(&self, uv: [f32; 4]) -> bool {
        self.state
            .borrow()
            .region
            .as_ref()
            .is_some_and(|r| r.covers(uv))
    }

    /// How many stale quads were ever blanked (tests: must stay 0 when eviction is safe by itself).
    pub fn stale_total(&self) -> u64 {
        self.state.borrow().stale_total
    }

    /// Pictures currently placed (tests).
    pub fn placed(&self) -> usize {
        self.state
            .borrow()
            .region
            .as_ref()
            .map_or(0, |r| r.entries.len())
    }

    /// A number that changes whenever a view must be rebuilt for pictures: a load finished, a rectangle went stale,
    /// or a fade is running (one step per 16 ms).
    pub fn stamp(&self) -> u64 {
        let s = self.state.borrow();
        let fade = s
            .born
            .values()
            .map(|t| ((s.now - t) / 16.0) as u64 + 1)
            .max()
            .unwrap_or(0);
        (s.arrivals << 32) | fade
    }

    /// Whether a fade or a load is in progress (the screen wants more frames).
    pub fn busy(&self) -> bool {
        let s = self.state.borrow();
        !s.born.is_empty() || !s.waiting.is_empty()
    }

    /// Waits for every load and applies it. Headless goldens only.
    pub fn settle(&self, now_ms: f64) {
        self.backend.borrow().settle();
        self.frame(now_ms);
    }

    /// Mood-colour hues of a loaded picture (`ImageTone`); `None` until it is loaded.
    pub fn tones(&self, image: &ImageRef) -> Option<Vec<f64>> {
        self.backend
            .borrow()
            .tones(&Url::parse(&image.address).ok()?)
    }

    /// A finished picture node: the tile ground, then the picture (fading in) or the symbol when it failed.
    pub fn node(&self, image: Option<&ImageRef>, w: f32, h: f32, radius: f32) -> Node {
        use swiftly_design::tokens::colour;
        use swiftly_ui::components::color;
        let ground =
            Node::rect(color(colour::AREA), radius).frame(Some(w), Some(h), Alignment::CENTER);
        let slot = self.slot(image, w, h, Priority::Visible);
        ground.overlay(
            remote_node(slot, w, h, radius, || {
                self.icons
                    .node("film-strip", 22.0, true, color(colour::FONT))
            }),
            Alignment::CENTER,
        )
    }

    /// The slot for `image` shown at `w x h` points. Starts the load on first sight, uploads on arrival.
    pub fn slot(&self, image: Option<&ImageRef>, w: f32, h: f32, priority: Priority) -> RemoteSlot {
        let Some(image) = image else {
            return RemoteSlot::Failed;
        };
        let Ok(url) = Url::parse(&image.address) else {
            return RemoteSlot::Failed;
        };
        let key = image_key(&url);
        let (tw, th) = (
            (w * self.scale).ceil().max(1.0) as u32,
            (h * self.scale).ceil().max(1.0) as u32,
        );
        let border = swiftly_images::border_for(Some(w.max(h)), self.device);
        let mut guard = self.state.borrow_mut();
        let s = &mut *guard;
        s.touched.push((key.clone(), url.clone()));
        match self.backend.borrow().request(&url, border, priority) {
            Slot::Loading => {
                s.waiting.insert(key);
                RemoteSlot::Loading
            }
            Slot::Failed(_) => {
                s.waiting.remove(&key);
                RemoteSlot::Failed
            }
            Slot::Ready(img) => {
                let entry_key = format!("{key}@{tw}x{th}");
                let Some(uv) = self.entry_uv(s, &entry_key, &img, tw, th) else {
                    s.blocked = true;
                    return RemoteSlot::Loading;
                };
                if s.waiting.remove(&key) {
                    let now = s.now;
                    s.born.insert(key.clone(), now);
                }
                let alpha = s.born.get(&key).map_or(1.0, |t| reveal_alpha(s.now - t));
                RemoteSlot::Ready {
                    image: ImageId { uv },
                    alpha,
                }
            }
        }
    }

    /// The rectangle of `entry_key`, uploading (and evicting older entries) when it is not there yet.
    fn entry_uv(
        &self,
        s: &mut State,
        entry_key: &str,
        img: &Decoded,
        tw: u32,
        th: u32,
    ) -> Option<[f32; 4]> {
        let (epoch, now_clock) = (s.epoch, s.region.as_ref().map_or(0, |r| r.clock) + 1);
        let region = s.region.as_mut()?;
        region.clock = now_clock;
        if let Some(e) = region.entries.get_mut(entry_key) {
            e.epoch = epoch;
            e.used = now_clock;
            return Some(e.uv);
        }
        let small = fit_fill(img, tw, th);
        let (w, h) = (small.width, small.height);
        if w > region.w || h > region.h {
            return None;
        }
        let at = loop {
            if let Some(at) = region.place(w, h) {
                break at;
            }
            if !region.evict(epoch) {
                return None;
            }
        };
        let (px, py) = (region.x0 + at.0, region.y0 + at.1);
        if !self
            .cx
            .images
            .borrow_mut()
            .page
            .put(px, py, w, h, &small.rgba)
        {
            return None;
        }
        let uv = region.next_uv(px, py, w, h);
        region.live.insert(bits(uv), entry_key.to_owned());
        region.entries.insert(
            entry_key.to_owned(),
            Entry {
                x: at.0,
                y: at.1,
                w,
                h,
                uv,
                epoch,
                used: now_clock,
            },
        );
        Some(uv)
    }
}

/// The picture cut to the aspect of a `tw x th` tile (centred, `.fill`) and scaled down to at most that size.
fn fit_fill(img: &Decoded, tw: u32, th: u32) -> Decoded {
    let (w, h) = (img.width as u64, img.height as u64);
    let (tw64, th64) = (u64::from(tw), u64::from(th));
    // Keep the largest centred part with the tile's aspect: compare w * th with h * tw.
    let (cw, ch) = if w * th64 > h * tw64 {
        ((h * tw64 / th64).max(1), h)
    } else {
        (w, (w * th64 / tw64).max(1))
    };
    let (x0, y0) = ((w - cw) / 2, (h - ch) / 2);
    let mut rgba = Vec::with_capacity((cw * ch * 4) as usize);
    for y in 0..ch {
        let start = (((y0 + y) * w + x0) * 4) as usize;
        rgba.extend_from_slice(&img.rgba[start..start + (cw * 4) as usize]);
    }
    let cut = Decoded {
        width: cw as u32,
        height: ch as u32,
        rgba,
    };
    downscale(cut, tw.max(th))
}
