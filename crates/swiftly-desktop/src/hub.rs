//! The bridge between the image loader and the screens (`NetworkImage` in Swift): resolves an `ImageRef` of a view
//! model tile to a placeholder, a fading-in picture or the error symbol; uploads decoded pictures into a region of
//! the shared image page (the software renderer samples it, the wgpu renderer uploads its dirty rectangle); asks
//! for visible tiles first and cancels what scrolled away; hands out mood-colour hues.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;
use swiftly_images::decode::{downscale, downscale_to};
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

/// The picture of a profile circle for a slot: nothing but the ground while it loads, the picture fading in when it is
/// ready, and the initial (`letter`) only when there is no picture or loading failed (`ProfileCharacter`: the letter is
/// a fallback, never a base layer, so it never flashes under a picture that is on its way).
pub fn avatar_for_slot(slot: RemoteSlot, size: f32, letter: impl FnOnce() -> Node) -> Node {
    remote_node(slot, size, size, size / 2.0, letter)
}

/// The edge of a user picture (`AppModel.userImageEdge`): one address, one cache entry for every spot.
pub const AVATAR_EDGE: u32 = 480;

/// The user picture at `address` as a `ImageRef`, as the Mac asks for it.
pub fn avatar_ref(address: &str) -> ImageRef {
    ImageRef {
        address: address.to_owned(),
        kind: swiftly_vm::ImageKind::Poster,
        wanted_width: AVATAR_EDGE,
        wanted_height: AVATAR_EDGE,
    }
}

/// A profile circle of `size` points: the picture at `address` through `hub`, else (no hub, no address, or a failed
/// load) the `letter`.
pub fn avatar_node(
    hub: &HubSlot,
    address: Option<&str>,
    size: f32,
    letter: impl FnOnce() -> Node,
) -> Node {
    let hub = hub.borrow().clone();
    match (hub, address) {
        (Some(hub), Some(address)) => {
            let slot = hub.slot(Some(&avatar_ref(address)), size, size, Priority::Visible);
            avatar_for_slot(slot, size, letter)
        }
        _ => letter(),
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
    /// What each screen's last build asked for. Screens share one hub (home under a title page), so a build of one
    /// must never cancel what another screen still shows: that was the title page's backdrop, cancelled by every
    /// rebuild of the page below and never asked for again once the page stood still.
    last: Vec<(HubOwner, Vec<(String, Url)>)>,
    /// The screen that is covered by a page at rest: nothing of it shows but its sidebar. Its builds may use and fill free
    /// room, but never push another screen's pictures out (two screens that evict each other's pictures on every build
    /// left the page in front grey and both of them rebuilding on every frame).
    hidden: Option<HubOwner>,
    /// The view run in progress belongs to the hidden screen.
    building_hidden: bool,
    /// Pictures cut to a tile and uploaded so far (each is a copy and a downscale of the decoded picture).
    cuts: u64,
}

/// The screen a build belongs to: its [`HubSlot`], held weakly so a closed screen does not keep anything alive.
pub type HubOwner = std::rc::Weak<RefCell<Option<Rc<ImageHub>>>>;

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
        let hub = self.borrow().clone();
        if let Some(h) = hub {
            h.begin_build_for(&Rc::downgrade(self));
        }
    }
    fn finish(&self, list: &mut DrawList) -> usize {
        let hub = self.borrow().clone();
        hub.map_or(0, |h| {
            h.after_build(&Rc::downgrade(self));
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
        // The rows kept at the bottom for the preview and the stills are not free (the reserve was counted from the
        // whole page before, so the hub's region took the rows the icons needed and the first screens drew none).
        let free = cx.images.borrow().shelf_free();
        let mut h = rows.min(free.saturating_sub(ICON_RESERVE_ROWS));
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
            // The largest height that still fits (the rows kept for the preview and the stills come off the page).
            h -= 128;
        }
        if trace_images() {
            eprintln!(
                "swiftly-desktop: picture region: {} x {} rows of a {} x {} page",
                region.as_ref().map_or(0, |r| r.w),
                region.as_ref().map_or(0, |r| r.h),
                page.0,
                page.1
            );
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
                hidden: None,
                building_hidden: false,
                cuts: 0,
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
        let mut s = self.state.borrow_mut();
        s.epoch += 1;
        s.building_hidden = false;
    }

    /// [`begin_build`](Self::begin_build) for the screen `owner`: a hidden screen's run never evicts.
    pub fn begin_build_for(&self, owner: &HubOwner) {
        let mut s = self.state.borrow_mut();
        s.epoch += 1;
        s.building_hidden = s.hidden.as_ref().is_some_and(|h| h.ptr_eq(owner));
    }

    /// Names the screen a page at rest covers (`None`: none is covered). When it shows again it builds anew, so its
    /// pictures are asked for and placed.
    pub fn set_hidden(&self, owner: Option<HubOwner>) {
        let mut s = self.state.borrow_mut();
        let same = match (&s.hidden, &owner) {
            (Some(a), Some(b)) => a.ptr_eq(b),
            (None, None) => true,
            _ => false,
        };
        if !same {
            s.hidden = owner;
            s.arrivals += 1;
        }
    }

    /// Cancels loads of tiles that were in the last build of `owner` but not in this one (they scrolled away) and that
    /// no other screen's last build shows either. A frame without a rebuild changes nothing.
    pub fn after_build(&self, owner: &HubOwner) {
        let mut guard = self.state.borrow_mut();
        let s = &mut *guard;
        s.building_hidden = false;
        if s.touched.is_empty() {
            return;
        }
        let touched = std::mem::take(&mut s.touched);
        let seen: HashSet<&String> = touched.iter().map(|(k, _)| k).collect();
        // Screens that are gone give up their pictures as well.
        let mut gone: Vec<(String, Url)> = Vec::new();
        s.last.retain_mut(|(o, l)| {
            let alive = o.strong_count() > 0;
            if !alive {
                gone.append(l);
            }
            alive
        });
        let at = s.last.iter().position(|(o, _)| o.ptr_eq(owner));
        let mut dropped = at.map_or_else(Vec::new, |i| std::mem::take(&mut s.last[i].1));
        dropped.append(&mut gone);
        match at {
            Some(i) => s.last[i].1 = touched.clone(),
            None => s.last.push((std::rc::Weak::clone(owner), touched.clone())),
        }
        for (k, url) in &dropped {
            let wanted =
                seen.contains(k) || s.last.iter().any(|(_, l)| l.iter().any(|(k2, _)| k2 == k));
            if !wanted && s.waiting.remove(k) {
                if trace_images() {
                    eprintln!("swiftly-desktop: picture {k}: cancelled, it left the view");
                }
                self.backend.borrow().cancel(url);
            }
        }
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

    /// How many pictures were cut to a tile and uploaded so far (tests: a window drag must not cut them again and again).
    pub fn cuts(&self) -> u64 {
        self.state.borrow().cuts
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
        self.node_with_symbol(image, w, h, radius, "film-strip")
    }

    /// [`ImageHub::node`] with the symbol `symbol` (an icon name) for a title without a picture.
    pub fn node_with_symbol(
        &self,
        image: Option<&ImageRef>,
        w: f32,
        h: f32,
        radius: f32,
        symbol: &str,
    ) -> Node {
        use swiftly_design::tokens::colour;
        use swiftly_ui::components::color;
        // The ground, the picture and the border (painted on this node by the caller) share one pixel rectangle.
        let ground = Node::rect(color(colour::AREA), radius)
            .pixel_snapped()
            .frame(Some(w), Some(h), Alignment::CENTER);
        let slot = self.slot(image, w, h, Priority::Visible);
        ground
            .overlay(
                remote_node(slot, w, h, radius, || {
                    self.icons.node(symbol, 22.0, true, color(colour::FONT))
                }),
                Alignment::CENTER,
            )
            .pixel_snapped()
    }

    /// The slot for `image` shown at `w x h` points. Starts the load on first sight, uploads on arrival.
    pub fn slot(&self, image: Option<&ImageRef>, w: f32, h: f32, priority: Priority) -> RemoteSlot {
        let Some(image) = image else {
            return RemoteSlot::Failed;
        };
        let Ok(url) = Url::parse(&image.address) else {
            return RemoteSlot::Failed;
        };
        let (tw, th) = (
            (w * self.scale).round().max(1.0) as u32,
            (h * self.scale).round().max(1.0) as u32,
        );
        let url = sized_for_device(&url, tw, th);
        let key = image_key(&url);
        let border = decode_border(w, h, tw, th, self.device);
        let mut guard = self.state.borrow_mut();
        let s = &mut *guard;
        s.touched.push((key.clone(), url.clone()));
        match self.backend.borrow().request(&url, border, priority) {
            Slot::Loading => {
                if trace_images() && s.waiting.insert(key.clone()) {
                    eprintln!("swiftly-desktop: picture {key}: asked for");
                }
                s.waiting.insert(key);
                RemoteSlot::Loading
            }
            Slot::Failed(_) => {
                s.waiting.remove(&key);
                RemoteSlot::Failed
            }
            Slot::Ready(img) => {
                let entry_key = format!("{key}@{tw}x{th}");
                let may_evict = !s.building_hidden;
                let Some(uv) = self.entry_uv(s, &entry_key, &img, tw, th, may_evict) else {
                    if !may_evict {
                        return RemoteSlot::Loading;
                    }
                    if trace_images() {
                        eprintln!(
                            "swiftly-desktop: picture {entry_key}: no room in the page ({} placed)",
                            s.region.as_ref().map_or(0, |r| r.entries.len())
                        );
                    }
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
        may_evict: bool,
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
        if trace_images() {
            // Source (decoded) size against the device size it is drawn at: a source below the target is stretched.
            eprintln!(
                "swiftly-desktop: picture {entry_key}: source {}x{}, uploaded {}x{}, drawn {tw}x{th}{}",
                img.width,
                img.height,
                small.width,
                small.height,
                if small.width < tw || small.height < th {
                    " (STRETCHED)"
                } else {
                    ""
                }
            );
        }
        let (w, h) = (small.width, small.height);
        if w > region.w || h > region.h {
            return None;
        }
        let at = loop {
            if let Some(at) = region.place(w, h) {
                break at;
            }
            if !may_evict || !region.evict(epoch) {
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
        s.cuts += 1;
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

/// `SWIFTLY_DESKTOP_TRACE_IMAGES` is set: the hub says what it asks for, cancels and cannot place.
fn trace_images() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SWIFTLY_DESKTOP_TRACE_IMAGES").is_some())
}

/// The longest edge a picture of the slot (`w x h` points, `tw x th` device pixels) is decoded to. The Mac's rule is
/// 3.2 x the edge in points, held at the device limit (1600): on a 4K window at scale 1.5 that limit is below the pixels
/// of a wide header, so the decoded picture was stretched by the GPU. The device pixels (with the margin the Mac's
/// 3.2 gives at 2x for a picture cut to the slot's aspect) come first, up to the largest size the server is asked for.
pub fn decode_border(w: f32, h: f32, tw: u32, th: u32, device: Device) -> u32 {
    let mac = swiftly_images::border_for(Some(w.max(h)), device);
    let device_edge = (f64::from(tw.max(th)) * 1.6).ceil() as u32;
    mac.max(device_edge.min(ASK_STEPS[ASK_STEPS.len() - 1]))
}

/// Sizes a Jellyfin picture address asks the server for, in steps so a window drag does not ask for a new picture on every
/// pixel of growth.
const ASK_STEPS: [u32; 8] = [360, 640, 960, 1280, 1920, 2560, 3200, 3840];

/// `url` with `maxWidth` / `maxHeight` raised to cover the device pixels the picture is drawn at (`tw x th`). The core asks
/// for sizes in points at 1x (a 1200 wide backdrop); drawn across a 1.5x window that is stretched by the GPU and soft.
/// Never lowers a size and leaves any other address alone.
pub(crate) fn sized_for_device(url: &Url, tw: u32, th: u32) -> Url {
    let raised = |asked: u32, px: u32| {
        if px <= asked {
            asked
        } else {
            ASK_STEPS
                .iter()
                .copied()
                .find(|s| *s >= px)
                .unwrap_or(3840)
                .max(asked)
        }
    };
    let mut changed = false;
    // A box to fill (`fillWidth` + `fillHeight`: profile pictures, Plex's 16:9 boxes) grows as a whole, keeping its aspect.
    let fill: Option<(u32, u32)> = {
        let get = |name: &str| {
            url.query_pairs()
                .find(|(k, _)| k == name)
                .and_then(|(_, v)| v.parse::<u32>().ok())
        };
        let has_min = url.query_pairs().any(|(k, _)| k == "minSize");
        get("fillWidth")
            .zip(get("fillHeight"))
            .or_else(|| has_min.then(|| get("width").zip(get("height"))).flatten())
    };
    let fill_to = fill.and_then(|(fw, fh)| {
        let (kw, kh) = (
            f64::from(tw) / f64::from(fw.max(1)),
            f64::from(th) / f64::from(fh.max(1)),
        );
        let k = kw.max(kh);
        if k <= 1.0 {
            return None;
        }
        let edge = ((f64::from(fw.max(fh)) * k).ceil() as u32).max(1);
        let edge = ASK_STEPS
            .iter()
            .copied()
            .find(|s| *s >= edge)
            .unwrap_or(3840);
        let r = f64::from(edge) / f64::from(fw.max(fh));
        Some((
            (f64::from(fw) * r).round() as u32,
            (f64::from(fh) * r).round() as u32,
        ))
    });
    let pairs: Vec<(String, String)> = url
        .query_pairs()
        .map(|(k, v)| {
            let px = match k.as_ref() {
                "maxWidth" | "width" => Some(tw),
                "maxHeight" | "height" => Some(th),
                _ => None,
            };
            if let (Some((nw, nh)), "fillWidth" | "fillHeight" | "width" | "height") =
                (fill_to, k.as_ref())
            {
                changed = true;
                let n = if k == "fillWidth" || k == "width" {
                    nw
                } else {
                    nh
                };
                return (k.into_owned(), n.to_string());
            }
            match (px, v.parse::<u32>()) {
                (Some(px), Ok(asked)) if raised(asked, px) != asked => {
                    changed = true;
                    (k.into_owned(), raised(asked, px).to_string())
                }
                _ => (k.into_owned(), v.into_owned()),
            }
        })
        .collect();
    if !changed {
        return url.clone();
    }
    let mut out = url.clone();
    out.query_pairs_mut().clear().extend_pairs(pairs);
    out
}

/// The picture cut to the aspect of a `tw x th` tile (centred, `.fill`) and scaled down to at most that size.
pub(crate) fn fit_fill(img: &Decoded, tw: u32, th: u32) -> Decoded {
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
    // Exactly the quad's device size when the picture is larger (never up: a smaller picture is stretched by the GPU).
    if cut.width >= tw && cut.height >= th {
        downscale_to(cut, tw, th)
    } else {
        downscale(cut, tw.max(th))
    }
}

#[cfg(test)]
mod avatar_tests {
    use super::*;
    use std::cell::Cell;

    fn is_image(n: &Node) -> bool {
        n.paint.iter().any(|p| matches!(p, Paint::Image { .. }))
    }

    #[test]
    fn a_ready_picture_replaces_the_letter_and_fades_in() {
        let called = Cell::new(false);
        let slot = RemoteSlot::Ready {
            image: ImageId {
                uv: [0.0, 0.0, 1.0, 1.0],
            },
            alpha: 0.5,
        };
        let n = avatar_for_slot(slot, 28.0, || {
            called.set(true);
            Node::fixed(1.0, 1.0)
        });
        assert!(is_image(&n), "the node is the picture");
        assert!(!called.get(), "no letter under or over a picture");
        assert!(
            n.paint
                .iter()
                .any(|p| matches!(p, Paint::Image { tint, .. } if (tint.a - 0.5).abs() < 1e-6))
        );
    }

    #[test]
    fn the_letter_shows_only_when_there_is_no_picture() {
        let called = Cell::new(false);
        let _ = avatar_for_slot(RemoteSlot::Loading, 28.0, || {
            called.set(true);
            Node::fixed(1.0, 1.0)
        });
        assert!(!called.get(), "while it loads only the ground shows");
        let _ = avatar_for_slot(RemoteSlot::Failed, 28.0, || {
            called.set(true);
            Node::fixed(1.0, 1.0)
        });
        assert!(
            called.get(),
            "a failed or missing picture falls back to the letter"
        );
    }

    #[test]
    fn without_a_hub_or_an_address_the_letter_is_drawn() {
        let hub: HubSlot = HubSlot::default();
        let called = Cell::new(0);
        let letter = || {
            called.set(called.get() + 1);
            Node::fixed(1.0, 1.0)
        };
        let _ = avatar_node(&hub, Some("https://h/Users/u/Images/Primary"), 28.0, letter);
        let _ = avatar_node(&hub, None, 28.0, letter);
        assert_eq!(called.get(), 2);
    }

    #[test]
    fn the_avatar_ref_is_the_macs_480_edge() {
        let r = avatar_ref("https://h/x");
        assert_eq!((r.wanted_width, r.wanted_height), (480, 480));
    }
}

#[cfg(test)]
mod sized_tests {
    use super::{decode_border, sized_for_device};
    use swiftly_images::{Device, Url};

    #[test]
    fn a_box_to_fill_and_the_plex_scaler_grow_with_the_device_size() {
        // A profile picture box of 480 stays; a 16:9 Plex box grows as a whole to cover a 1920 px slot.
        let avatar =
            Url::parse("http://h/Users/u/Images/Primary?fillWidth=480&fillHeight=480&quality=90")
                .unwrap();
        assert_eq!(sized_for_device(&avatar, 84, 84), avatar);
        let plex = Url::parse("http://h/photo/:/transcode?url=%2Fa&upscale=0&width=640&height=360&quality=90&minSize=1").unwrap();
        let q = sized_for_device(&plex, 1900, 1069)
            .query()
            .unwrap()
            .to_owned();
        assert!(q.contains("width=1920") && q.contains("height=1080"), "{q}");
        let thumb = Url::parse(
            "http://h/photo/:/transcode?url=%2Fa&upscale=0&width=4096&height=360&quality=90",
        )
        .unwrap();
        let q = sized_for_device(&thumb, 300, 450)
            .query()
            .unwrap()
            .to_owned();
        assert!(q.contains("width=4096") && q.contains("height=640"), "{q}");
    }

    #[test]
    fn the_decode_border_covers_the_device_pixels_of_the_slot() {
        // The Mac's limit is 1600; a header across a 4K window at scale 1.5 is 2176 px wide.
        assert!(decode_border(1451.0, 454.0, 2176, 681, Device::Mac) >= 2176);
        assert!(decode_border(1920.0, 600.0, 3840, 1200, Device::Mac) >= 3840);
        // A small tile keeps the Mac's rule.
        assert_eq!(decode_border(150.0, 225.0, 225, 338, Device::Mac), 720);
    }

    #[test]
    fn a_backdrop_asked_at_1200_is_raised_for_a_wide_window_and_a_poster_that_fits_is_left_alone() {
        let back =
            Url::parse("http://h/Items/a/Images/Backdrop?tag=b&maxWidth=1200&quality=90").unwrap();
        assert!(
            sized_for_device(&back, 2176, 681)
                .query()
                .unwrap()
                .contains("maxWidth=2560")
        );
        assert_eq!(sized_for_device(&back, 1000, 300), back);
        let poster =
            Url::parse("http://h/Items/a/Images/Primary?tag=p&maxHeight=360&quality=90").unwrap();
        assert_eq!(sized_for_device(&poster, 225, 338), poster);
        assert!(
            sized_for_device(&poster, 300, 450)
                .query()
                .unwrap()
                .contains("maxHeight=640")
        );
    }
}
