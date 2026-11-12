//! Shared services a view reads while it builds: fonts and the glyph atlas, the text layout cache, the image page.

use std::cell::RefCell;
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
}

/// Largest video frame the image page carries (the player asks the engine for at most this).
pub const VIDEO_MAX: (u32, u32) = (1280, 720);

impl ImageStore {
    /// An empty `size x size` page.
    pub fn new(size: u32) -> ImageStore {
        ImageStore {
            page: PixelPage::new(size, size, AtlasFormat::Rgba8),
            x: 0,
            y: 0,
            row_h: 0,
            video_at: None,
        }
    }

    /// The shelf cursor `(x, y, row height)` (tests, measuring how full the page is).
    pub fn cursor(&self) -> (u32, u32, u32) {
        (self.x, self.y, self.row_h)
    }

    /// Copies a `w x h` straight-alpha RGBA picture into the page. `None` when the page is full.
    pub fn add(&mut self, w: u32, h: u32, rgba: &[u8]) -> Option<ImageId> {
        let (pw, ph) = self.page.size();
        if self.x + w > pw {
            self.x = 0;
            self.y += self.row_h;
            self.row_h = 0;
        }
        if self.y + h > ph || w > pw {
            return None;
        }
        if !self.page.put(self.x, self.y, w, h, rgba) {
            return None;
        }
        let uv = self.page.uv(self.x, self.y, w, h);
        self.x += w;
        self.row_h = self.row_h.max(h);
        Some(ImageId { uv })
    }
}

impl ImageStore {
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
