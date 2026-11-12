//! `DownloadGroup` (Downloads.swift:352): a row in the download list. A series is one row.

use crate::item::DownloadItem;

/// A row in the download list.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum DownloadGroup {
    /// A movie, or an episode that cannot be grouped.
    Single(DownloadItem),
    /// All episodes of one series.
    Series {
        /// The series id.
        id: String,
        /// The series name.
        title: String,
        /// Episodes by season and number.
        episodes: Vec<DownloadItem>,
    },
}

impl DownloadGroup {
    /// Row id: the item id, or `serie-<series id>`.
    pub fn id(&self) -> String {
        match self {
            Self::Single(p) => p.id.clone(),
            Self::Series { id, .. } => format!("serie-{id}"),
        }
    }

    /// Row title.
    pub fn title(&self) -> &str {
        match self {
            Self::Single(p) => &p.title,
            Self::Series { title, .. } => title,
        }
    }

    /// Sum of the bytes.
    pub fn bytes(&self) -> i64 {
        match self {
            Self::Single(p) => p.bytes,
            Self::Series { episodes, .. } => episodes.iter().map(|e| e.bytes).sum(),
        }
    }

    /// The group's most recent addition, which sorting uses. `f64::NEG_INFINITY` for an empty
    /// series (Swift `.distantPast`).
    pub fn created(&self) -> f64 {
        match self {
            Self::Single(p) => p.created,
            Self::Series { episodes, .. } => episodes
                .iter()
                .map(|e| e.created)
                .fold(f64::NEG_INFINITY, f64::max),
        }
    }
}
