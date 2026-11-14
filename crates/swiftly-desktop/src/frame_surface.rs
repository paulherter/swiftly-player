//! The two ways the player screen shows a video frame, independent of any engine.
//!
//! * [`FrameSurface`]: the frame is rewritten into a reserved region of the image page and drawn as a picture. This is
//!   the CPU path (the software renderer, the goldens): it composes the same pixels on every host.
//! * [`GpuSurface`]: the UI leaves the area transparent and the wgpu renderer draws the frame as its bottom layer
//!   (`WgpuRenderer::upload_video`). Nothing is copied through the image page.

use crate::player_screen::VideoSurface;
use std::cell::{Cell, RefCell};
use swiftly_layout::Alignment;
use swiftly_render::Color;
use swiftly_ui::{Cx, ImageId, Node};

/// Draws the newest video frame as a picture; the frame lives in the region of the image page kept for video.
pub struct FrameSurface {
    cx: Cx,
    /// What to draw: the frame's rectangle in the page and its size.
    shown: RefCell<Option<(ImageId, u32, u32)>>,
    /// What the newest frame looks like (for the real-app checks: is the picture black or green?).
    last: Cell<Option<PictureStats>>,
}

/// A cheap summary of one video frame (every 7th pixel): mean colour and the shares of near-black and of
/// "broken YUV green" pixels. A healthy picture is neither mostly black nor mostly green.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PictureStats {
    /// Mean red, green, blue (0..255).
    pub mean: [f32; 3],
    /// Share of pixels with all channels below 12.
    pub black: f32,
    /// Share of pixels that are strongly green with little red and blue (a decoder writing zeroed planes).
    pub green: f32,
}

impl PictureStats {
    /// Measures an RGBA buffer; `None` when it holds no pixel.
    pub fn of(rgba: &[u8]) -> Option<PictureStats> {
        let (mut sum, mut n, mut black, mut green) = ([0u64; 3], 0u64, 0u64, 0u64);
        for p in rgba.as_chunks::<4>().0.iter().step_by(7) {
            let (r, g, b) = (p[0], p[1], p[2]);
            sum[0] += u64::from(r);
            sum[1] += u64::from(g);
            sum[2] += u64::from(b);
            n += 1;
            black += u64::from(r < 12 && g < 12 && b < 12);
            green += u64::from(g > 110 && r < 60 && b < 60);
        }
        if n == 0 {
            return None;
        }
        let f = n as f32;
        Some(PictureStats {
            mean: [sum[0] as f32 / f, sum[1] as f32 / f, sum[2] as f32 / f],
            black: black as f32 / f,
            green: green as f32 / f,
        })
    }

    /// Whether this looks like a real picture: not (nearly) all black and not mostly broken green.
    pub fn looks_fine(&self) -> bool {
        self.black < 0.9 && self.green < 0.6
    }
}

impl FrameSurface {
    /// A surface writing into the image page of `cx`.
    pub fn new(cx: Cx) -> FrameSurface {
        FrameSurface {
            cx,
            shown: RefCell::new(None),
            last: Cell::new(None),
        }
    }

    /// The summary of the newest frame pushed.
    pub fn last_stats(&self) -> Option<PictureStats> {
        self.last.get()
    }

    /// Writes a `w x h` RGBA frame (at most `swiftly_ui::VIDEO_MAX`) into the page.
    pub fn push(&self, w: u32, h: u32, rgba: &[u8]) {
        self.last.set(PictureStats::of(rgba));
        if let Some(id) = self.cx.images.borrow_mut().put_video(w, h, rgba) {
            *self.shown.borrow_mut() = Some((id, w, h));
        }
    }
}

impl VideoSurface for FrameSurface {
    fn node(&self, w: f32, h: f32, fill: bool, _position: f64) -> Node {
        // The host draws the picture under the UI (GPU path): leave the area transparent once it has a frame.
        {
            let v = self.cx.video.borrow();
            if v.gpu.is_some() && v.shown {
                return Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 0.0).frame(
                    Some(w),
                    Some(h),
                    Alignment::TOP_LEADING,
                );
            }
        }
        let black = Node::rect(Color::new(0.0, 0.0, 0.0, 1.0), 0.0).frame(
            Some(w),
            Some(h),
            Alignment::CENTER,
        );
        let Some((id, fw, fh)) = *self.shown.borrow() else {
            return black.frame(Some(w), Some(h), Alignment::TOP_LEADING);
        };
        let (fw, fh) = (fw as f32, fh as f32);
        let k = if fill {
            (w / fw).max(h / fh)
        } else {
            (w / fw).min(h / fh)
        };
        let pic = Node::image(id, fw * k, fh * k, 0.0);
        Node::zstack(Alignment::CENTER, vec![black, pic]).frame(
            Some(w),
            Some(h),
            Alignment::TOP_LEADING,
        )
    }
}

/// An empty (transparent) area: the GPU renderer draws the video under the UI.
pub struct GpuSurface;

impl VideoSurface for GpuSurface {
    fn node(&self, w: f32, h: f32, _fill: bool, _position: f64) -> Node {
        Node::rect(Color::new(0.0, 0.0, 0.0, 0.0), 0.0).frame(
            Some(w),
            Some(h),
            Alignment::TOP_LEADING,
        )
    }
}

/// Side of the app's image page. The poster hub takes up to 2048 rows of it and keeps 512 for icons; a 1280x720 video
/// frame needs 720 more, so the 2048 px default page left no room for the picture and the player stayed black.
pub const APP_IMAGE_PAGE: u32 = 4096;

/// The shared services of the real app: the image page that posters, icons and video frames live on.
pub fn app_cx() -> Cx {
    let cx = Cx::new().with_image_page(APP_IMAGE_PAGE);
    // Room for the trickplay still, kept from the start: a long session fills the rest of the page.
    cx.images.borrow_mut().keep_preview();
    // And for the sample picture of the subtitle page (it was added when the page opened, after the posters).
    crate::settings_pages::reserve_preview_room(&cx);
    cx
}

/// Host side of the GPU video layer: tells the player screen that the host draws the picture (window size, texture
/// limit) and moves the newest frame into the renderer's bottom layer.
pub struct GpuVideoHost {
    max_side: u32,
}

impl GpuVideoHost {
    /// `None` when the GPU path must not be used: the env switch `SWIFTLY_VIDEO_CPU=1`, or a texture limit below the
    /// 1280 px frame the CPU path already carries. The screen then keeps copying frames into the image page.
    pub fn new(max_texture_side: u32) -> Option<GpuVideoHost> {
        if std::env::var_os("SWIFTLY_VIDEO_CPU").is_some_and(|v| v != "0")
            || max_texture_side < 1280
        {
            return None;
        }
        Some(GpuVideoHost {
            max_side: max_texture_side,
        })
    }

    /// Before the UI is built: the player screen reads the window size from here.
    pub fn announce(&self, video: &RefCell<swiftly_ui::VideoHandoff>, window: (u32, u32)) {
        video.borrow_mut().gpu = Some(swiftly_ui::GpuVideo {
            window,
            max_side: self.max_side,
        });
    }

    /// Before the draw: uploads the newest frame, or removes the layer when no player ran since the last draw or a new
    /// play began.
    pub fn sync(
        &self,
        video: &RefCell<swiftly_ui::VideoHandoff>,
        renderer: &mut swiftly_render::WgpuRenderer,
    ) {
        let mut v = video.borrow_mut();
        if std::mem::take(&mut v.reset) || !v.alive {
            renderer.clear_video();
        }
        if v.alive {
            if let Some(frame) = v.pending.take() {
                renderer.upload_video(frame.w, frame.h, &frame.rgba, swiftly_render::VideoFit::Fit);
                v.spare = frame.rgba;
            }
        } else {
            v.pending = None;
            v.shown = false;
        }
        v.alive = false;
    }
}

#[cfg(test)]
mod picture_tests {
    use super::PictureStats;

    fn solid(r: u8, g: u8, b: u8) -> Vec<u8> {
        [r, g, b, 255].repeat(64 * 64)
    }

    #[test]
    fn black_and_green_frames_are_not_fine_but_a_colourful_one_is() {
        assert!(
            !PictureStats::of(&solid(0, 0, 0))
                .expect("stats")
                .looks_fine()
        );
        assert!(
            !PictureStats::of(&solid(0, 135, 0))
                .expect("stats")
                .looks_fine()
        );
        let mut mixed = solid(200, 90, 40);
        mixed[..4096].copy_from_slice(&solid(0, 0, 0)[..4096]);
        assert!(PictureStats::of(&mixed).expect("stats").looks_fine());
        assert!(PictureStats::of(&[]).is_none());
    }
}
