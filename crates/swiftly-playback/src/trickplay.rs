//! Port of `Trickplay.swift` (JellyfinKit): preview images when scrubbing (Jellyfin 10.9
//! Trickplay tile sheets), the tile lookup, the width choice, and the `Trickplay` part of an
//! item response. The address builder lives in `swiftly-jellyfin` (`trickplay_url`).

use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};

/// The width asked for by default (Trickplay.swift:68, default argument `320`).
pub const DEFAULT_TARGET: i64 = 320;

/// Trickplay details of one width (Trickplay.swift:17).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Trickplay {
    /// Width of a preview image in pixels, also the path part of the address.
    pub width: i64,
    /// Height of a preview image in pixels.
    pub height: i64,
    /// Images per sheet row.
    pub tiles_wide: i64,
    /// Rows per sheet.
    pub tiles_up: i64,
    /// Total number of images.
    pub count: i64,
    /// Milliseconds between two preview images.
    pub interval: i64,
}

/// Where the preview image for a position lies (Trickplay.swift:38).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tile {
    /// Number of the sheet: `/Trickplay/{width}/{sheet}.jpg`.
    pub sheet: i64,
    /// Section within the sheet, in pixels.
    pub x: i64,
    /// Section within the sheet, in pixels.
    pub y: i64,
    /// Width of the section.
    pub width: i64,
    /// Height of the section.
    pub height: i64,
}

impl Trickplay {
    /// n = ms / interval, sheet = n / (columns x rows), place = n mod (columns x rows), row by
    /// row from the top left. Past the last image the last one stays, before the start the
    /// first (Trickplay.swift:53).
    pub fn tile(&self, seconds: f64) -> Option<Tile> {
        // The sizes come from the server: a product or a pixel offset that does not fit is no tile.
        let per_sheet = self.tiles_wide.checked_mul(self.tiles_up).unwrap_or(0);
        if !(self.interval > 0
            && self.tiles_wide > 0
            && self.tiles_up > 0
            && per_sheet > 0
            && self.count > 0
            && self.width > 0
            && self.height > 0
            && seconds.is_finite())
        {
            return None;
        }
        let ms = seconds.max(0.0) * 1000.0;
        let n = ((ms as i64) / self.interval).min(self.count - 1);
        let slot = n % per_sheet;
        Some(Tile {
            sheet: n / per_sheet,
            x: (slot % self.tiles_wide).saturating_mul(self.width),
            y: (slot / self.tiles_wide).saturating_mul(self.height),
            width: self.width,
            height: self.height,
        })
    }

    /// Of all offered widths the one closest to a preview of `target` pixels, rather a bit
    /// larger than too small (Trickplay.swift:68).
    pub fn choose(offering: &[Trickplay], target: i64) -> Option<Trickplay> {
        let valid: Vec<Trickplay> = offering
            .iter()
            .copied()
            .filter(|t| t.interval > 0 && t.count > 0)
            .collect();
        // First smallest width at or above the target; on a tie the first one stays
        // (Swift `min(by:)` / `max(by:)` keep the first of equals).
        let mut smallest_above: Option<Trickplay> = None;
        for t in valid.iter().filter(|t| t.width >= target) {
            if smallest_above.is_none_or(|s| t.width < s.width) {
                smallest_above = Some(*t);
            }
        }
        if smallest_above.is_some() {
            return smallest_above;
        }
        let mut largest: Option<Trickplay> = None;
        for t in &valid {
            if largest.is_none_or(|l| l.width < t.width) {
                largest = Some(*t);
            }
        }
        largest
    }
}

/// One width entry as the server sends it (Trickplay.swift:82, `Detail`).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Detail {
    width: Option<i64>,
    height: Option<i64>,
    tile_width: Option<i64>,
    tile_height: Option<i64>,
    thumbnail_count: Option<i64>,
    interval: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct RawResponse {
    #[serde(rename = "Trickplay", default)]
    trickplay: Option<HashMap<String, BTreeMap<String, Detail>>>,
}

/// The part of an item response that carries Trickplay (Trickplay.swift:76). Decode with
/// `serde_json::from_str`; a response without `Trickplay` yields no sources.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(from = "RawResponse")]
pub struct TrickplayResponse {
    /// Per source all offered widths.
    pub sources: HashMap<String, Vec<Trickplay>>,
}

impl From<RawResponse> for TrickplayResponse {
    fn from(raw: RawResponse) -> Self {
        let mut sources: HashMap<String, Vec<Trickplay>> = HashMap::new();
        for (source, widths) in raw.trickplay.unwrap_or_default() {
            let list = widths
                .into_iter()
                .filter_map(|(key, a)| {
                    Some(Trickplay {
                        width: a.width.or_else(|| key.parse().ok())?,
                        height: a.height?,
                        tiles_wide: a.tile_width?,
                        tiles_up: a.tile_height?,
                        count: a.thumbnail_count?,
                        interval: a.interval?,
                    })
                })
                .collect();
            sources.insert(source, list);
        }
        Self { sources }
    }
}

impl TrickplayResponse {
    /// The details for the running source, width closest to [`DEFAULT_TARGET`]; without an ID
    /// the only one available (Trickplay.swift:109).
    pub fn of(&self, source: Option<&str>) -> Option<Trickplay> {
        self.of_target(source, DEFAULT_TARGET)
    }

    /// As [`TrickplayResponse::of`] with an explicit target width (Trickplay.swift:109).
    pub fn of_target(&self, source: Option<&str>, target: i64) -> Option<Trickplay> {
        let matching = source.and_then(|s| {
            self.sources
                .get(s)
                .or_else(|| self.sources.get(&s.to_lowercase()))
        });
        let offering: Option<&Vec<Trickplay>> = match matching {
            Some(m) => Some(m),
            None if self.sources.len() == 1 => self.sources.values().next(),
            None => None,
        };
        offering.and_then(|o| Trickplay::choose(o, target))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape of `TrickplayInfoDto` on a title, per source and width.
    const ANSWER: &str = r#"
    { "Id": "e1", "Name": "Folge",
      "Trickplay": {
        "abc123": {
          "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                   "ThumbnailCount": 250, "Interval": 10000, "Bandwidth": 1000 },
          "640": { "Width": 640, "Height": 360, "TileWidth": 10, "TileHeight": 10,
                   "ThumbnailCount": 250, "Interval": 10000, "Bandwidth": 4000 }
        }
      } }
    "#;

    fn detail() -> Trickplay {
        Trickplay {
            width: 320,
            height: 180,
            tiles_wide: 10,
            tiles_up: 10,
            count: 250,
            interval: 10_000,
        }
    }

    // F-cast-02: sizes that overflow are no tile (Swift traps on the product).
    #[test]
    fn hostile_sizes_give_no_tile_and_never_panic() {
        for (wide, up, width, height, interval, count) in [
            (i64::MAX, 2, 320, 180, 10_000, 250),
            (1 << 32, 1 << 32, 320, 180, 10_000, 250),
            (-1, -1, 320, 180, 10_000, 250),
            (i64::MIN, -1, 320, 180, 10_000, 250),
            (10, 10, 320, 180, 0, 250),
            (10, 10, 320, 180, -1, i64::MAX),
        ] {
            let t = Trickplay {
                width,
                height,
                tiles_wide: wide,
                tiles_up: up,
                count,
                interval,
            };
            for seconds in [0.0, 1.0, 1e30, f64::NAN, f64::INFINITY, -5.0] {
                assert_eq!(t.tile(seconds), None, "{wide} {up} {interval} {seconds}");
            }
        }
        let huge = Trickplay {
            width: i64::MAX,
            height: i64::MAX,
            tiles_wide: 10,
            tiles_up: 10,
            count: i64::MAX,
            interval: 1,
        };
        let tile = huge.tile(1e30).expect("a tile");
        assert!(tile.x >= 0 && tile.y >= 0);
    }

    fn want(sheet: i64, x: i64, y: i64) -> Option<Tile> {
        Some(Tile {
            sheet,
            x,
            y,
            width: 320,
            height: 180,
        })
    }

    fn width(t: Option<Trickplay>) -> Option<i64> {
        t.map(|t| t.width)
    }

    #[test]
    fn in_read() -> Result<(), serde_json::Error> {
        let a: TrickplayResponse = serde_json::from_str(ANSWER)?;
        assert_eq!(a.sources.get("abc123").map(Vec::len), Some(2));
        assert_eq!(width(a.of(Some("abc123"))), Some(320));
        assert_eq!(width(a.of_target(Some("abc123"), 400)), Some(640));
        assert_eq!(width(a.of_target(Some("abc123"), 1000)), Some(640));
        // Without an ID the only source counts.
        assert_eq!(width(a.of(None)), Some(320));
        Ok(())
    }

    #[test]
    fn without() -> Result<(), serde_json::Error> {
        let a: TrickplayResponse = serde_json::from_str(r#"{ "Id": "e1", "Name": "Folge" }"#)?;
        assert_eq!(a.of(Some("abc123")), None);
        assert_eq!(a.of(None), None);
        Ok(())
    }

    #[test]
    fn foreign_source() -> Result<(), serde_json::Error> {
        let d = r#"
        { "Trickplay": {
            "a": { "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                            "ThumbnailCount": 5, "Interval": 1000 } },
            "b": { "320": { "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                            "ThumbnailCount": 5, "Interval": 1000 } } } }
        "#;
        let a: TrickplayResponse = serde_json::from_str(d)?;
        assert_eq!(a.of(Some("c")), None);
        assert!(a.of(Some("b")).is_some());
        Ok(())
    }

    #[test]
    fn tile() {
        // 0 s -> first image, first sheet, top left.
        assert_eq!(detail().tile(0.0), want(0, 0, 0));
        // 125 s -> n = 12 -> row 1, column 2.
        assert_eq!(detail().tile(125.0), want(0, 640, 180));
        // 1000 s -> n = 100 -> second sheet, top left.
        assert_eq!(detail().tile(1000.0), want(1, 0, 0));
        // 1999 s -> n = 199 -> second sheet, bottom right.
        assert_eq!(detail().tile(1999.0), want(1, 2880, 1620));
    }

    #[test]
    fn edges() {
        // n is capped at 249 -> sheet 2, slot 49.
        assert_eq!(detail().tile(99_999.0), want(2, 2880, 720));
        assert_eq!(detail().tile(-5.0).map(|t| t.sheet), Some(0));
        assert_eq!(detail().tile(f64::NAN), None);
    }

    // `address` (Swift: JellyfinClient.trickplayURL) lives in swiftly-jellyfin
    // (`endpoints.rs` `trickplay_url`) and is not ported here.
}
