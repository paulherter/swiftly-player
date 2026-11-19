//! `ImageSelection.swift`: which image a tile shows, as a rule that is the same everywhere.

use crate::address::{ImageAddress, ImageKind, ImageMetric};
use swiftly_jellyfin::ServerKind;
use swiftly_model::Item;
use url::Url;

/// The landscape pick: the address and which step of the chain applied (goes to the log if a
/// tile stays empty after all). The step names are the German log texts of the Swift code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Landscape {
    /// Where to load it.
    pub url: Url,
    /// Which step applied.
    pub source: &'static str,
}

/// The first tag of a list, if any (`tags?.first`).
fn first_tag(tags: &Option<Vec<String>>) -> Option<&str> {
    tags.as_ref()?.first().map(String::as_str)
}

/// The image rules (`ImageSelection`).
pub struct ImageSelection;

impl ImageSelection {
    /// The landscape image of a "continue watching" tile.
    ///
    /// A chain, each step taken only if its **tag** is present (the tag proves the image
    /// exists; without it the code would guess and collect 404s). An episode never has its
    /// own backdrop, the series' arrives as `ParentBackdropImageTags`. Plex gets a 16:9 box
    /// to fill instead of a width limit, and two extra steps at the end.
    pub fn landscape(item: &Item, addresses: &ImageAddress, width: i64) -> Option<Landscape> {
        let plex = addresses.kind == ServerKind::Plex;
        let mass = if plex {
            ImageMetric::Filling {
                wide: width,
                up: width.saturating_mul(9) / 16,
            }
        } else {
            ImageMetric::AtMostWide(width)
        };
        let attempt = |source: &'static str,
                       id: Option<&str>,
                       art: ImageKind,
                       mark: Option<&str>|
         -> Option<Landscape> {
            let url = addresses.construct(id?, art, Some(mark?), mass)?;
            Some(Landscape { url, source })
        };
        let tag = |key: &str| item.image_tags.as_ref()?.get(key).map(String::as_str);
        let series = item.series_id.as_deref();

        attempt(
            "Serienhintergrund",
            item.parent_backdrop_item_id.as_deref().or(series),
            ImageKind::Background,
            first_tag(&item.parent_backdrop_image_tags),
        )
        .or_else(|| {
            attempt(
                "eigener Hintergrund",
                Some(&item.id),
                ImageKind::Background,
                first_tag(&item.backdrop_image_tags),
            )
        })
        .or_else(|| {
            attempt(
                "Serienvorschau",
                item.parent_thumb_item_id.as_deref().or(series),
                ImageKind::Preview,
                item.parent_thumb_image_tag.as_deref(),
            )
        })
        .or_else(|| {
            attempt(
                "eigene Vorschau",
                Some(&item.id),
                ImageKind::Preview,
                tag("Thumb"),
            )
        })
        // The still of an episode: weaker as a cover, hence last, but still an image.
        .or_else(|| {
            series?;
            attempt(
                "Folgenstandbild",
                Some(&item.id),
                ImageKind::Poster,
                tag("Primary"),
            )
        })
        // Plex only, whose titles often have no landscape image: the poster cut to 16:9 by the
        // server (series poster for an episode), and last the current background the server
        // keeps without naming it.
        .or_else(|| {
            if !plex {
                return None;
            }
            let (id, mark) = if series.is_some() {
                (series, item.series_primary_image_tag.as_deref())
            } else {
                (Some(item.id.as_str()), tag("Primary"))
            };
            attempt("Poster zugeschnitten", id, ImageKind::Poster, mark)
        })
        .or_else(|| {
            if !plex {
                return None;
            }
            let id = series.unwrap_or(&item.id);
            let url = addresses.construct(id, ImageKind::Background, None, mass)?;
            Some(Landscape {
                url,
                source: "Hintergrund ohne Pfad",
            })
        })
    }

    /// The image for the head of a page: only what is really landscape. Own backdrop, the
    /// series', then the thumbnails. If nothing comes out, the app keeps searching (episode,
    /// then poster); that needs a query and is not done here.
    pub fn header(item: &Item, addresses: &ImageAddress, width: i64) -> Option<Url> {
        let mass = ImageMetric::AtMostWide(width);
        let series = item.series_id.as_deref();
        let chain: [(Option<&str>, ImageKind, Option<&str>); 4] = [
            (
                Some(&item.id),
                ImageKind::Background,
                first_tag(&item.backdrop_image_tags),
            ),
            (
                item.parent_backdrop_item_id.as_deref().or(series),
                ImageKind::Background,
                first_tag(&item.parent_backdrop_image_tags),
            ),
            (
                Some(&item.id),
                ImageKind::Preview,
                item.image_tags
                    .as_ref()
                    .and_then(|t| t.get("Thumb"))
                    .map(String::as_str),
            ),
            (
                item.parent_thumb_item_id.as_deref().or(series),
                ImageKind::Preview,
                item.parent_thumb_image_tag.as_deref(),
            ),
        ];
        chain
            .into_iter()
            .find_map(|(id, art, mark)| addresses.construct(id?, art, Some(mark?), mass))
    }

    /// The head image with fallback: [`header`](Self::header), else for a series the landscape
    /// image of the episode that plays next (or the first), else the poster at head size.
    /// Fetching the episode stays with the caller; this only decides which image applies.
    pub fn header_with_fallback(
        item: &Item,
        episode: Option<&Item>,
        addresses: &ImageAddress,
        width: i64,
    ) -> Option<Url> {
        if let Some(url) = Self::header(item, addresses, width) {
            return Some(url);
        }
        if item.type_.as_deref() == Some("Series")
            && let Some(episode) = episode
            && let Some(hit) = Self::landscape(episode, addresses, width)
        {
            return Some(hit.url);
        }
        // Only a poster the server is known to have (a tag names it): a head image built from a guess would be a
        // broken picture for a title with no image at all, where the page shows its placeholder instead.
        Self::portrait_of(item, addresses, width, false)
    }

    /// The logo of a title; for episodes, the series'. `None` if the server has none.
    pub fn logo(item: &Item, addresses: &ImageAddress, max_height: i64) -> Option<Url> {
        let (id, mark) = if let (Some(series), Some(mark)) = (
            item.series_id.as_deref(),
            item.parent_logo_image_tag.as_deref(),
        ) {
            (series, mark)
        } else {
            let mark = item.image_tags.as_ref()?.get("Logo")?;
            (item.id.as_str(), mark.as_str())
        };
        addresses.construct(
            id,
            ImageKind::Logo,
            Some(mark),
            ImageMetric::AtMostHigh(max_height),
        )
    }

    /// The portrait poster of a 2:3 tile. For an episode, the series poster (its own image is
    /// a 16:9 still and would be cropped beyond recognition).
    ///
    /// A poster-bearing title (film, series, season; a box set without a poster gets the mosaic of its
    /// first titles instead) that names no `Primary` tag still gets the
    /// untagged address: titles that a catalog plugin fills in, or an endpoint that leaves `ImageTags` out,
    /// have an image the server serves without a tag (the tag only keeps caches honest). Every grid, row and
    /// card asks this one function, so a title never shows in the library and lacks its poster on home.
    pub fn portrait(item: &Item, addresses: &ImageAddress, max_height: i64) -> Option<Url> {
        Self::portrait_of(item, addresses, max_height, true)
    }

    /// [`portrait`](Self::portrait); with `guess` off only an image the item names by a tag (so the server has it).
    fn portrait_of(
        item: &Item,
        addresses: &ImageAddress,
        max_height: i64,
        guess: bool,
    ) -> Option<Url> {
        let series = item.series_id.as_deref();
        let jellyfin_like = addresses.kind != ServerKind::Plex;
        let (id, mark) = if let (Some(series), Some(mark)) =
            (series, item.series_primary_image_tag.as_deref())
        {
            (series, Some(mark))
        } else if let (true, true, Some(series), Some("Episode")) =
            (guess, jellyfin_like, series, item.type_.as_deref())
        {
            // An episode that names its series but not the series' poster tag (a catalog plugin, an endpoint that
            // leaves the field out): the series poster, untagged. Its own image is a 16:9 still.
            (series, None)
        } else if let Some(mark) = item.image_tags.as_ref().and_then(|t| t.get("Primary")) {
            (item.id.as_str(), Some(mark.as_str()))
        } else if guess
            && jellyfin_like
            && matches!(item.type_.as_deref(), Some("Movie" | "Series" | "Season"))
        {
            (item.id.as_str(), None)
        } else {
            return None;
        };
        addresses.construct(
            id,
            ImageKind::Poster,
            mark,
            ImageMetric::AtMostHigh(max_height),
        )
    }

    /// Default widths and heights of the Swift signatures.
    pub const LANDSCAPE_WIDTH: i64 = 600;
    /// Default width of [`header`](Self::header).
    pub const HEADER_WIDTH: i64 = 1200;
    /// Default height of [`logo`](Self::logo).
    pub const LOGO_HEIGHT: i64 = 240;
    /// Default height of [`portrait`](Self::portrait).
    pub const PORTRAIT_HEIGHT: i64 = 480;
}
