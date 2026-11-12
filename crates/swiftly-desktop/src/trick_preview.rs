//! The trickplay still under the scrub handle: sheets are fetched off-thread, decoded once, and the tile for the
//! hovered position is cropped into one reserved region of the image page (rewritten in place, no atlas growth).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use swiftly_playback::trickplay::{Tile, Trickplay};
use swiftly_ui::{Cx, ImageId, ImageSlot};

/// Fetches one raw JPEG sheet by number; blocks, runs on a worker thread. `None` = only the time is shown.
pub type SheetSource = Arc<dyn Fn(i64) -> Option<Vec<u8>> + Send + Sync>;

enum Sheet {
    Loading,
    Failed,
    Ready(u32, u32, Vec<u8>),
}

/// Trickplay state of one running title.
pub struct TrickPreview {
    tp: Trickplay,
    source: SheetSource,
    sheets: Arc<Mutex<HashMap<i64, Sheet>>>,
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
            slot: None,
            shown: None,
        }
    }

    /// The image for `tile` once its sheet has arrived (starts the fetch otherwise).
    pub fn image(&mut self, cx: &Cx, tile: Option<Tile>) -> Option<ImageId> {
        let tile = tile?;
        let ready = {
            let mut sheets = self.sheets.lock().unwrap_or_else(PoisonError::into_inner);
            match sheets.get(&tile.sheet) {
                None => {
                    sheets.insert(tile.sheet, Sheet::Loading);
                    let (map, source, n) = (
                        Arc::clone(&self.sheets),
                        Arc::clone(&self.source),
                        tile.sheet,
                    );
                    std::thread::spawn(move || {
                        let done = source(n)
                            .and_then(|b| swiftly_images::decode::decode(&b, 0).ok())
                            .map_or(Sheet::Failed, |d| Sheet::Ready(d.width, d.height, d.rgba));
                        map.lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .insert(n, done);
                    });
                    false
                }
                Some(Sheet::Ready(..)) => true,
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
                        self.slot = images.reserve(w, h);
                    }
                    if let Some(s) = &self.slot
                        && images.rewrite(s, w, h, &crop)
                    {
                        self.shown = Some(tile);
                    }
                }
            }
        }
        if self.shown.is_some() {
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
