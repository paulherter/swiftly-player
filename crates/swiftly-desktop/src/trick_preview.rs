//! The trickplay still under the scrub handle: sheets are fetched off-thread, decoded once, and the tile for the
//! hovered position is cropped into one reserved region of the image page (rewritten in place, no atlas growth).
//!
//! Like the Mac's `TrickplayImages`: a sheet that failed is asked for again (a network blip must not take the picture
//! away for the rest of the film), and only the last few decoded sheets are kept (a 10 x 10 sheet is 23 MB decoded).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};
use swiftly_playback::trickplay::{Tile, Trickplay};
use swiftly_ui::{Cx, ImageId, ImageSlot};

/// Fetches one raw JPEG sheet by number; blocks, runs on a worker thread. `None` = only the time is shown.
pub type SheetSource = Arc<dyn Fn(i64) -> Option<Vec<u8>> + Send + Sync>;

/// Decoded sheets kept at once (`TrickplayImages.atMost`).
const KEEP_SHEETS: usize = 3;

/// How long a failed sheet waits before it is asked for again.
const RETRY_AFTER: Duration = Duration::from_secs(2);

enum Sheet {
    Loading,
    Failed(Instant),
    Ready(u32, u32, Vec<u8>),
}

/// Trickplay state of one running title.
pub struct TrickPreview {
    tp: Trickplay,
    source: SheetSource,
    sheets: Arc<Mutex<HashMap<i64, Sheet>>>,
    /// Ready sheets, oldest first.
    order: Vec<i64>,
    retry_after: Duration,
    slot: Option<ImageSlot>,
    shown: Option<Tile>,
}

impl TrickPreview {
    /// For the chosen width of the server's offer.
    pub fn new(tp: Trickplay, source: SheetSource) -> TrickPreview {
        TrickPreview {
            tp,
            source,
            sheets: Arc::new(Mutex::new(HashMap::new())),
            order: Vec::new(),
            retry_after: RETRY_AFTER,
            slot: None,
            shown: None,
        }
    }

    /// Starts the fetch of sheet `n` on a worker thread.
    fn fetch(&self, n: i64) {
        let (map, source) = (Arc::clone(&self.sheets), Arc::clone(&self.source));
        std::thread::spawn(move || {
            let done = source(n)
                .and_then(|b| swiftly_images::decode::decode(&b, 0).ok())
                .map_or(Sheet::Failed(Instant::now()), |d| {
                    Sheet::Ready(d.width, d.height, d.rgba)
                });
            map.lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(n, done);
        });
    }

    /// The image for `tile` once its sheet has arrived (starts the fetch otherwise).
    pub fn image(&mut self, cx: &Cx, tile: Option<Tile>) -> Option<ImageId> {
        let tile = tile?;
        let ready = {
            let mut sheets = self.sheets.lock().unwrap_or_else(PoisonError::into_inner);
            match sheets.get(&tile.sheet) {
                None => {
                    sheets.insert(tile.sheet, Sheet::Loading);
                    self.fetch(tile.sheet);
                    false
                }
                Some(Sheet::Failed(at)) if at.elapsed() >= self.retry_after => {
                    sheets.insert(tile.sheet, Sheet::Loading);
                    self.fetch(tile.sheet);
                    false
                }
                Some(Sheet::Ready(..)) => {
                    if !self.order.contains(&tile.sheet) {
                        self.order.push(tile.sheet);
                    }
                    // Keep the newest few; the sheet in use stays.
                    while self.order.len() > KEEP_SHEETS {
                        let at = self
                            .order
                            .iter()
                            .position(|n| *n != tile.sheet)
                            .unwrap_or(0);
                        let old = self.order.remove(at);
                        sheets.remove(&old);
                    }
                    true
                }
                Some(_) => false,
            }
        };
        let (w, h) = (
            u32::try_from(tile.width).ok()?,
            u32::try_from(tile.height).ok()?,
        );
        if ready && self.shown != Some(tile) {
            let sheets = self.sheets.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(Sheet::Ready(sw, sh, px)) = sheets.get(&tile.sheet) {
                let mut crop = Vec::with_capacity(w as usize * h as usize * 4);
                let (x0, y0) = (u32::try_from(tile.x).ok()?, u32::try_from(tile.y).ok()?);
                if x0 + w <= *sw && y0 + h <= *sh {
                    for row in y0..y0 + h {
                        let from = ((row * sw + x0) * 4) as usize;
                        crop.extend_from_slice(&px[from..from + w as usize * 4]);
                    }
                    let mut images = cx.images.borrow_mut();
                    if self.slot.is_none() {
                        self.slot = images.reserve_preview(w, h);
                        crate::script::trace(&format!(
                            "trickplay slot {w}x{h}: {}, shelf cursor {:?}",
                            if self.slot.is_some() {
                                "reserved"
                            } else {
                                "FAILED, the image page is full"
                            },
                            images.cursor()
                        ));
                    }
                    if let Some(s) = &self.slot
                        && images.rewrite(s, w, h, &crop)
                    {
                        self.shown = Some(tile);
                    }
                }
            }
        }
        // The picture of this tile only: while its sheet is on the way the bar shows its placeholder, never the
        // picture of another position (the Mac's `image(at:)` returns nil then).
        if self.shown == Some(tile) {
            self.slot.map(|s| s.id)
        } else {
            None
        }
    }

    /// The server's offer behind this preview.
    pub fn offer(&self) -> Trickplay {
        self.tp
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// One sheet of 2 x 2 tiles of 32 x 18.
    fn offer() -> Trickplay {
        Trickplay {
            width: 32,
            height: 18,
            tiles_wide: 2,
            tiles_up: 2,
            count: 4,
            interval: 1000,
        }
    }

    fn tile(sheet: i64) -> Option<Tile> {
        Some(Tile {
            sheet,
            x: 32,
            y: 0,
            width: 32,
            height: 18,
        })
    }

    /// Asks `p` for the image until it shows or two seconds pass.
    fn wait_for(p: &mut TrickPreview, cx: &Cx, t: Option<Tile>) -> Option<ImageId> {
        let until = Instant::now() + Duration::from_secs(4);
        while Instant::now() < until {
            if let Some(id) = p.image(cx, t) {
                return Some(id);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        None
    }

    fn png_sheet() -> Vec<u8> {
        swiftly_images::fixture::png("sheet", 64, 36)
    }

    /// A long session fills the image page with posters and icons; the preview still has its room (it failed silently
    /// when `reserve` found the page full, and the scrub bar showed no picture).
    #[test]
    fn a_full_image_page_does_not_take_the_preview_away() {
        let cx = crate::frame_surface::app_cx();
        let pixels = vec![9_u8; 256 * 256 * 4];
        while cx.add_image(256, 256, &pixels).is_some() {}
        assert!(
            cx.add_image(256, 256, &pixels).is_none(),
            "the page is full"
        );
        let mut p = TrickPreview::new(offer(), Arc::new(|_| Some(png_sheet())));
        assert!(wait_for(&mut p, &cx, tile(0)).is_some());
    }

    #[test]
    fn a_failed_sheet_is_asked_for_again() {
        let cx = crate::frame_surface::app_cx();
        let asked = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&asked);
        let source: SheetSource = Arc::new(move |_| {
            // The first answer is a network error, the second the sheet.
            (count.fetch_add(1, Ordering::SeqCst) > 0).then(png_sheet)
        });
        let mut p = TrickPreview::new(offer(), source);
        p.retry_after = Duration::from_millis(100);
        assert!(wait_for(&mut p, &cx, tile(0)).is_some());
        assert_eq!(asked.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn only_the_last_sheets_stay_decoded() {
        let cx = crate::frame_surface::app_cx();
        let mut p = TrickPreview::new(offer(), Arc::new(|_| Some(png_sheet())));
        for n in 0..6 {
            assert!(wait_for(&mut p, &cx, tile(n)).is_some(), "sheet {n}");
        }
        let ready = p
            .sheets
            .lock()
            .map(|m| m.values().filter(|s| matches!(s, Sheet::Ready(..))).count());
        assert_eq!(ready.ok(), Some(KEEP_SHEETS));
    }
}
