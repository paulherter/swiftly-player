//! `ImageAddress.swift`: the address of an image on the server.

use crate::url_build::build;
use swiftly_jellyfin::{ServerKind, token_name};
use url::Url;

/// Which image of an item is meant (`ImageKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ImageKind {
    /// `Primary`: the poster.
    Poster,
    /// `Backdrop`.
    Background,
    /// `Thumb`: landscape thumbnail; often there for series, rarely for episodes.
    Preview,
    /// `Logo`: the title wordmark with transparency.
    Logo,
}

impl ImageKind {
    /// The Jellyfin name in the path (`rawValue`).
    pub fn raw(self) -> &'static str {
        match self {
            Self::Poster => "Primary",
            Self::Background => "Backdrop",
            Self::Preview => "Thumb",
            Self::Logo => "Logo",
        }
    }
}

/// How the image is cropped (`ImageMetric`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageMetric {
    /// Limit the height, keep the aspect ratio; for posters.
    AtMostHigh(i64),
    /// Limit the width; for backgrounds.
    AtMostWide(i64),
    /// Fill exactly this size; for round icons and Plex 16:9 boxes.
    Filling {
        /// Width in pixels.
        wide: i64,
        /// Height in pixels.
        up: i64,
    },
}

/// The side the Plex scaler gets when the caller left it open: a limit no picture reaches.
const PLEX_OPEN: i64 = 4096;

/// Builds the address of an image on the server (`ImageAddress`).
#[derive(Clone, PartialEq, Eq)]
pub struct ImageAddress {
    /// The server address.
    pub base: Url,
    /// The access token, put last into the query.
    pub token: Option<String>,
    /// The query name that carries the token: `ApiKey`, `api_key` on Emby, `X-Plex-Token`.
    pub token_name: &'static str,
    /// Plex names images by path (the item's `thumb`/`art`), not by id and kind.
    pub kind: ServerKind,
}

/// `Debug` never shows the access token.
impl std::fmt::Debug for ImageAddress {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ImageAddress")
            .field("base", &swiftly_net::redact::url(&self.base))
            .field(
                "token",
                &self.token.as_ref().map(|_| swiftly_net::redact::MASK),
            )
            .field("token_name", &self.token_name)
            .field("kind", &self.kind)
            .finish()
    }
}

impl ImageAddress {
    /// An address builder for one server and session.
    pub fn new(base: Url, token: Option<String>, kind: ServerKind) -> Self {
        Self {
            base,
            token,
            token_name: token_name(kind),
            kind,
        }
    }

    /// `construct(itemID:art:mark:mass:)` with no image index and JPEG quality 90.
    pub fn construct(
        &self,
        item_id: &str,
        art: ImageKind,
        mark: Option<&str>,
        mass: ImageMetric,
    ) -> Option<Url> {
        self.construct_with(item_id, art, mark, mass, None, 90)
    }

    /// `construct(itemID:art:mark:mass:index:guete:)`. `mark` is Jellyfin's `tag` (the
    /// fingerprint of the image) or, on Plex, the path the server wrote in `thumb` / `art`.
    pub fn construct_with(
        &self,
        item_id: &str,
        art: ImageKind,
        mark: Option<&str>,
        mass: ImageMetric,
        index: Option<i64>,
        quality: i64,
    ) -> Option<Url> {
        if self.kind == ServerKind::Plex {
            return self.plex_image(item_id, art, mark, mass, quality);
        }
        let mut path = format!("Items/{item_id}/Images/{}", art.raw());
        if let Some(index) = index {
            path.push_str(&format!("/{index}"));
        }
        let mut values: Vec<(&str, String)> = Vec::new();
        // The tag is Jellyfin's fingerprint of the image. Without it the server still
        // answers, but caches may keep stale versions.
        if let Some(mark) = mark {
            values.push(("tag", mark.to_string()));
        }
        match mass {
            ImageMetric::AtMostHigh(h) => values.push(("maxHeight", h.to_string())),
            ImageMetric::AtMostWide(w) => values.push(("maxWidth", w.to_string())),
            ImageMetric::Filling { wide, up } => {
                values.push(("fillWidth", wide.to_string()));
                values.push(("fillHeight", up.to_string()));
            }
        }
        values.push(("quality", quality.to_string()));
        if let Some(token) = &self.token {
            values.push((self.token_name, token.clone()));
        }
        build(&self.base, &path, &values)
    }

    /// A Plex image: the "tag" is the path of `thumb` / `art`; the server scales it at
    /// `/photo/:/transcode`. The scaler answers `400` unless both sides are given, so the
    /// open side gets a limit no picture reaches. Without a path the item's own current image
    /// is asked for (poster and background only). A person's `thumb` is already a full
    /// address and stays one.
    fn plex_image(
        &self,
        item_id: &str,
        art: ImageKind,
        mark: Option<&str>,
        mass: ImageMetric,
        quality: i64,
    ) -> Option<Url> {
        let path = match mark {
            Some(path) => path.to_string(),
            None => match art {
                ImageKind::Poster | ImageKind::Preview => {
                    format!("/library/metadata/{item_id}/thumb")
                }
                ImageKind::Background => format!("/library/metadata/{item_id}/art"),
                ImageKind::Logo => return None,
            },
        };
        if path.starts_with("http://") || path.starts_with("https://") {
            return Url::parse(&path).ok();
        }
        let (width, height) = match mass {
            ImageMetric::AtMostHigh(h) => (PLEX_OPEN, h),
            ImageMetric::AtMostWide(w) => (w, PLEX_OPEN),
            ImageMetric::Filling { wide, up } => (wide, up),
        };
        let mut values: Vec<(&str, String)> = vec![
            ("url", path),
            ("upscale", "0".into()),
            ("width", width.to_string()),
            ("height", height.to_string()),
            ("quality", quality.to_string()),
        ];
        // Both sides are a box to fill, not a limit: cover it and cut the rest.
        if matches!(mass, ImageMetric::Filling { .. }) {
            values.push(("minSize", "1".into()));
        }
        if let Some(token) = &self.token {
            values.push((self.token_name, token.clone()));
        }
        build(&self.base, "photo/:/transcode", &values)
    }

    /// A user's profile picture. Plex has none: its profile picture is a full address from
    /// plex.tv.
    pub fn user(&self, user_id: &str, mark: Option<&str>, border: i64) -> Option<Url> {
        if self.kind == ServerKind::Plex {
            return None;
        }
        let mut values: Vec<(&str, String)> = Vec::new();
        if let Some(mark) = mark {
            values.push(("tag", mark.to_string()));
        }
        values.push(("fillWidth", border.to_string()));
        values.push(("fillHeight", border.to_string()));
        values.push(("quality", "90".into()));
        if let Some(token) = &self.token {
            values.push((self.token_name, token.clone()));
        }
        build(
            &self.base,
            &format!("Users/{user_id}/Images/Primary"),
            &values,
        )
    }
}
