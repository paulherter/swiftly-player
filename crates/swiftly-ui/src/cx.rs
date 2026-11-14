//! Shared services a view reads while it builds: fonts and the glyph atlas, the text layout cache, the image page.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use swiftly_layout::{Proposal, Size};
use swiftly_render::{Atlas, AtlasFormat, PixelPage};
use swiftly_text::{Align, FontSystem, GlyphAtlas, TextLayout, TextStyle};

/// A picture in the image page: its normalised source rectangle.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ImageId {
    /// `[u0, v0, u1, v1]` in the page.
    pub uv: [f32; 4],
}

/// Picture sets by name (see [`Cx::memo`]).
pub type PictureSets = HashMap<&'static str, Vec<ImageId>>;
/// Rasterised icons by `(name, pixel size)`.
pub type IconCache = HashMap<(String, u32), Option<ImageId>>;

/// The RGBA image page with shelf packing.
pub struct ImageStore {
    /// The page the renderer samples.
    pub page: PixelPage,
    x: u32,
    y: u32,
    row_h: u32,
    /// Top-left of the region kept for video frames (reserved once, reused by every play).
    video_at: Option<(u32, u32)>,
    /// Top-left of the region kept at the bottom of the page for the trickplay still (see [`ImageStore::keep_preview`]).
    preview_at: Option<(u32, u32)>,
    /// Rows at the bottom of the page the shelf must not use.
    kept_rows: u32,
    /// The kept shelf for the player's episode stills (see [`ImageStore::keep_preview`]).
    stills: Option<StillShelf>,
}

/// A bump shelf of its own for the episode stills of the player's layer: it is emptied as a whole when the layer takes
/// a new set of cards, so a long session that filled the shared shelf still shows every card its picture.
struct StillShelf {
    y0: u32,
    h: u32,
    x: u32,
    y: u32,
    row_h: u32,
}

/// Largest video frame the image page carries (the player asks the engine for at most this).
pub const VIDEO_MAX: (u32, u32) = (1280, 720);

/// Largest trickplay still the page keeps room for (the server's tile at the 320 px target is 320 x 180).
pub const PREVIEW_MAX: (u32, u32) = (640, 360);

/// Rows the page keeps for the episode stills of the player's layer (about two rows of ten cards at 4K).
pub const STILL_ROWS: u32 = 640;

impl ImageStore {
    /// An empty `size x size` page.
    pub fn new(size: u32) -> ImageStore {
        ImageStore {
            page: PixelPage::new(size, size, AtlasFormat::Rgba8),
            x: 0,
            y: 0,
            row_h: 0,
            video_at: None,
            preview_at: None,
            kept_rows: 0,
            stills: None,
        }
    }

    /// The shelf cursor `(x, y, row height)` (tests, measuring how full the page is).
    pub fn cursor(&self) -> (u32, u32, u32) {
        (self.x, self.y, self.row_h)
    }

    /// Copies a `w x h` straight-alpha RGBA picture into the page. `None` when the page is full.
    ///
    /// The picture sits in a one texel frame that repeats its own edge texels (what `ClampToEdge` gives a picture on
    /// its own), so the bilinear sampling of a quad's first and last pixel rows never reads the neighbouring picture:
    /// without it every icon and cover next to another in the page shows a thin line of that neighbour on its edge.
    pub fn add(&mut self, w: u32, h: u32, rgba: &[u8]) -> Option<ImageId> {
        let (pw, ph) = self.page.size();
        // A picture as wide as the page (the hub's region of its own) has no room for the frame and is placed bare.
        let pad = u32::from(w + 2 <= pw);
        let (fw, fh) = (w + 2 * pad, h + 2 * pad);
        if self.x + fw > pw {
            self.x = 0;
            self.y += self.row_h;
            self.row_h = 0;
        }
        if self.y + fh > ph - self.kept_rows || fw > pw || rgba.len() < w as usize * h as usize * 4
        {
            return None;
        }
        let (w_us, h_us) = (w as usize, h as usize);
        let mut framed = vec![0_u8; fw as usize * fh as usize * 4];
        for row in 0..fh as usize {
            let src_row = row.saturating_sub(pad as usize).min(h_us.saturating_sub(1));
            for col in 0..fw as usize {
                let src_col = col.saturating_sub(pad as usize).min(w_us.saturating_sub(1));
                let from = (src_row * w_us + src_col) * 4;
                let to = (row * fw as usize + col) * 4;
                framed[to..to + 4].copy_from_slice(&rgba[from..from + 4]);
            }
        }
        if !self.page.put(self.x, self.y, fw, fh, &framed) {
            return None;
        }
        let uv = self.page.uv(self.x + pad, self.y + pad, w, h);
        self.x += fw;
        self.row_h = self.row_h.max(fh);
        Some(ImageId { uv })
    }
}

impl ImageStore {
    /// Keeps [`PREVIEW_MAX`] of room at the bottom of the page for the trickplay still, once, while the page is still
    /// empty enough. The shelf never grows into it, so a long session that filled the page with posters and icons still
    /// has room for the preview picture (`reserve` alone failed silently then and the scrub bar showed no picture).
    pub fn keep_preview(&mut self) {
        self.keep_stills();
        let (pw, ph) = self.page.size();
        if self.preview_at.is_some()
            || pw < PREVIEW_MAX.0
            || ph < PREVIEW_MAX.1 + self.kept_rows + self.y + self.row_h
        {
            return;
        }
        self.kept_rows += PREVIEW_MAX.1;
        self.preview_at = Some((0, ph - self.kept_rows));
    }

    /// Keeps [`STILL_ROWS`] of room for the player's episode stills, once, while the page is still empty enough (the
    /// same rule as the preview's). Without it the stills took what the posters and icons had left, which was nothing
    /// after a few screens, and every card past that stayed grey.
    fn keep_stills(&mut self) {
        let (pw, ph) = self.page.size();
        if self.stills.is_some()
            || ph < STILL_ROWS + PREVIEW_MAX.1 + self.y + self.row_h
            || pw < 512
        {
            return;
        }
        self.kept_rows += STILL_ROWS;
        self.stills = Some(StillShelf {
            y0: ph - self.kept_rows,
            h: STILL_ROWS,
            x: 0,
            y: 0,
            row_h: 0,
        });
    }

    /// Empties the kept still shelf: the stills handed out before are gone. The layer calls it before it takes a new set.
    pub fn reset_stills(&mut self) {
        if let Some(sh) = &mut self.stills {
            sh.x = 0;
            sh.y = 0;
            sh.row_h = 0;
        }
    }

    /// A black `w x h` region for an episode still: on the kept still shelf when there is one with room, else
    /// on the shared shelf like [`ImageStore::reserve`].
    pub fn reserve_still(&mut self, w: u32, h: u32) -> Option<ImageSlot> {
        let (pw, _) = self.page.size();
        if let Some(sh) = self.stills.as_mut() {
            let (fw, fh) = (w + 2, h + 2);
            if sh.x + fw > pw {
                sh.x = 0;
                sh.y += sh.row_h;
                sh.row_h = 0;
            }
            if fw <= pw && sh.y + fh <= sh.h {
                let (x, y) = (sh.x + 1, sh.y0 + sh.y + 1);
                sh.x += fw;
                sh.row_h = sh.row_h.max(fh);
                let black: Vec<u8> = [0, 0, 0, 255].repeat((fw * fh) as usize);
                if self.page.put(x - 1, y - 1, fw, fh, &black) {
                    return Some(ImageSlot {
                        id: ImageId {
                            uv: self.page.uv(x, y, w, h),
                        },
                        x,
                        y,
                        w,
                        h,
                    });
                }
            }
        }
        self.reserve(w, h)
    }

    /// A black `w x h` region for the trickplay still: the kept one when it fits ([`ImageStore::keep_preview`]), else a
    /// new one on the shelf (`None` when the page is full).
    pub fn reserve_preview(&mut self, w: u32, h: u32) -> Option<ImageSlot> {
        let (x, y) = match self.preview_at {
            Some(at) if w > 0 && h > 0 && w <= PREVIEW_MAX.0 && h <= PREVIEW_MAX.1 => at,
            _ => return self.reserve(w, h),
        };
        let black: Vec<u8> = [0, 0, 0, 255].repeat(w as usize * h as usize);
        self.page.put(x, y, w, h, &black).then(|| ImageSlot {
            id: ImageId {
                uv: self.page.uv(x, y, w, h),
            },
            x,
            y,
            w,
            h,
        })
    }

    /// Writes a video frame (`w x h`, at most [`VIDEO_MAX`]) into the region kept for video and returns what to draw.
    /// The region is reserved on the first frame and reused by every later frame and every later play, so a long
    /// session never runs the page out of room. `None` when the frame is too big or the page has no room left.
    pub fn put_video(&mut self, w: u32, h: u32, rgba: &[u8]) -> Option<ImageId> {
        if w == 0 || h == 0 || w > VIDEO_MAX.0 || h > VIDEO_MAX.1 {
            return None;
        }
        let (x, y) = match self.video_at {
            Some(at) => at,
            None => {
                // Transparent around the frame, like an empty page: a smaller frame has no black fringe from its neighbours.
                let empty = vec![0_u8; VIDEO_MAX.0 as usize * VIDEO_MAX.1 as usize * 4];
                let id = self.add(VIDEO_MAX.0, VIDEO_MAX.1, &empty)?;
                let (pw, ph) = self.page.size();
                let at = (
                    (id.uv[0] * pw as f32).round() as u32,
                    (id.uv[1] * ph as f32).round() as u32,
                );
                self.video_at = Some(at);
                at
            }
        };
        self.page.put(x, y, w, h, rgba).then(|| ImageId {
            uv: self.page.uv(x, y, w, h),
        })
    }
}

/// A reserved region of the image page whose pixels are rewritten in place (a video frame).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ImageSlot {
    /// The picture to draw.
    pub id: ImageId,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
}

impl ImageStore {
    /// Reserves a `w x h` region (black, opaque) that [`ImageStore::rewrite`] fills later.
    pub fn reserve(&mut self, w: u32, h: u32) -> Option<ImageSlot> {
        let black: Vec<u8> = [0, 0, 0, 255].repeat(w as usize * h as usize);
        let id = self.add(w, h, &black)?;
        let (pw, ph) = self.page.size();
        let (x, y) = (
            (id.uv[0] * pw as f32).round() as u32,
            (id.uv[1] * ph as f32).round() as u32,
        );
        Some(ImageSlot { id, x, y, w, h })
    }

    /// Overwrites the region a picture sits in (its `id` from [`ImageStore::reserve`]) with a `w x h` picture of the
    /// same size; `false` if the size differs or the region is not on the page.
    pub fn rewrite_in(&mut self, id: &ImageId, w: u32, h: u32, rgba: &[u8]) -> bool {
        let (pw, ph) = self.page.size();
        let (x, y) = (
            (id.uv[0] * pw as f32).round() as u32,
            (id.uv[1] * ph as f32).round() as u32,
        );
        let wanted = self.page.uv(x, y, w, h);
        wanted == id.uv && self.page.put(x, y, w, h, rgba)
    }

    /// Overwrites a reserved region with a `w x h` picture of the same size; `false` if the size differs.
    pub fn rewrite(&mut self, slot: &ImageSlot, w: u32, h: u32, rgba: &[u8]) -> bool {
        w == slot.w && h == slot.h && self.page.put(slot.x, slot.y, w, h, rgba)
    }
}

/// Fonts, glyph atlas and a cache of text layouts.
pub struct TextSystem {
    /// Font database.
    pub fonts: FontSystem,
    /// Glyph atlas.
    pub atlas: GlyphAtlas,
    cache: HashMap<String, Rc<TextLayout>>,
}

impl TextSystem {
    /// A layout of `text`, cached by every parameter. Memory is bounded by clearing the cache when it grows large.
    pub fn layout(
        &mut self,
        text: &str,
        style: &TextStyle,
        width: Option<f32>,
        lines: Option<usize>,
        align: Align,
    ) -> Rc<TextLayout> {
        let key = format!("{style:?}|{width:?}|{lines:?}|{align:?}|{text}");
        if let Some(l) = self.cache.get(&key) {
            return Rc::clone(l);
        }
        if self.cache.len() > 4096 {
            self.cache.clear();
        }
        let l = Rc::new(self.fonts.layout(text, style, width, lines, align));
        self.cache.insert(key, Rc::clone(&l));
        l
    }
}

/// What a host that draws video on the GPU tells the player screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GpuVideo {
    /// The window in pixels: the biggest picture that is ever shown.
    pub window: (u32, u32),
    /// The biggest texture side the GPU takes.
    pub max_side: u32,
}

/// A decoded frame on its way to the host's GPU layer (straight RGBA, rows packed).
#[derive(Debug, Default)]
pub struct VideoFrame {
    /// Width in pixels.
    pub w: u32,
    /// Height in pixels.
    pub h: u32,
    /// `w * h * 4` bytes.
    pub rgba: Vec<u8>,
}

/// The hand-over between the player screen and a host that draws the video as its bottom layer (the wgpu window of
/// the desktop app). With `gpu` unset the screen copies frames into the image page instead (the CPU path), so every
/// host without a GPU layer keeps working. Frames are handed over by swapping buffers, never copied.
#[derive(Debug, Default)]
pub struct VideoHandoff {
    /// Set by the host that draws the layer; `None` = the CPU path.
    pub gpu: Option<GpuVideo>,
    /// The newest frame the host has not drawn yet.
    pub pending: Option<VideoFrame>,
    /// The host's empty buffer for the next frame (swapped with the engine's).
    pub spare: Vec<u8>,
    /// A frame of the current play has been handed over, so the host's layer holds a picture.
    pub shown: bool,
    /// The player screen ran since the host last drew; without it the host removes its layer.
    pub alive: bool,
    /// A new play starts: the host drops the picture of the old one.
    pub reset: bool,
}

impl VideoHandoff {
    /// A new play begins: forget the old picture.
    pub fn begin(&mut self) {
        self.pending = None;
        self.shown = false;
        self.reset = true;
    }
}

/// The services passed to `view(parts, env, cx)`. Cloning is cheap (shared handles).
#[derive(Clone)]
pub struct Cx {
    /// Text.
    pub text: Rc<RefCell<TextSystem>>,
    /// Images.
    pub images: Rc<RefCell<ImageStore>>,
    /// Picture sets added once per services (demo posters and heroes) and shared by every screen, so the page is not
    /// filled again for each screen.
    pub memo: Rc<RefCell<PictureSets>>,
    /// Rasterised icons by `(name, pixel size)`, see `memo` for the idea.
    pub icon_cache: Rc<RefCell<IconCache>>,
    /// The video hand-over to a host with a GPU layer.
    pub video: Rc<RefCell<VideoHandoff>>,
    /// Pixels per point of the surface the icons are rasterised for. The window's scale can change after the screens
    /// exist (a Wayland compositor announces its fractional scale after the first frame, a window moves to another
    /// monitor); every screen's `Icons` reads it from here, so the next layout rasterises at the new scale instead of
    /// stretching 1x pictures.
    pub scale: Rc<Cell<f32>>,
}

impl Cx {
    /// With system fonts discovered (production).
    pub fn new() -> Cx {
        Cx::with_fonts(FontSystem::new())
    }

    /// With the bundled Inter only (deterministic tests and goldens).
    pub fn deterministic() -> Cx {
        Cx::with_fonts(FontSystem::bundled_only())
    }

    fn with_fonts(fonts: FontSystem) -> Cx {
        Cx {
            text: Rc::new(RefCell::new(TextSystem {
                fonts,
                atlas: GlyphAtlas::new(1024),
                cache: HashMap::new(),
            })),
            images: Rc::new(RefCell::new(ImageStore::new(2048))),
            memo: Rc::new(RefCell::new(HashMap::new())),
            icon_cache: Rc::new(RefCell::new(HashMap::new())),
            video: Rc::new(RefCell::new(VideoHandoff::default())),
            scale: Rc::new(Cell::new(1.0)),
        }
    }

    /// The same services with a `size x size` image page (call before anything is added). Screens that show real
    /// pictures use 4096 so a window full of posters fits next to the icons.
    pub fn with_image_page(mut self, size: u32) -> Cx {
        self.images = Rc::new(RefCell::new(ImageStore::new(size)));
        self.icon_cache = Rc::new(RefCell::new(HashMap::new()));
        self.memo = Rc::new(RefCell::new(HashMap::new()));
        self
    }

    /// Adds a picture to the image page.
    pub fn add_image(&self, w: u32, h: u32, rgba: &[u8]) -> Option<ImageId> {
        self.images.borrow_mut().add(w, h, rgba)
    }

    /// The size text takes for a proposal: `nil` = one line at natural width, a value wraps (and truncates after
    /// `lines`), zero measures at one point (longest word / ellipsis), infinity = natural width.
    pub fn measure_text(
        &self,
        text: &str,
        style: &TextStyle,
        lines: Option<usize>,
        p: Proposal,
    ) -> Size {
        let width = p.w.filter(|w| w.is_finite()).map(|w| w.max(1.0));
        let l = self
            .text
            .borrow_mut()
            .layout(text, style, width, lines, Align::Start);
        let (w, h) = l.size();
        Size::new(w, h)
    }
}

impl Default for Cx {
    fn default() -> Cx {
        Cx::new()
    }
}
