//! `DownloadState` (Downloads.swift:22).

use serde::{Deserialize, Serialize};

/// What a download is doing right now.
///
/// Progress is deliberately not in here: it changes several times a second and the state is
/// written to disk. How far along it is comes from `DownloadItem::loaded` against `bytes`.
/// The serde names are the Swift raw values (German), they are in `liste.json`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DownloadState {
    /// In the queue. Only one loads at a time (`wartet`).
    #[serde(rename = "wartet")]
    Waits,
    /// This one is up (`laedt`).
    #[serde(rename = "laedt")]
    Loads,
    /// Paused by hand, or paused by a failed transfer that left resume data (`angehalten`).
    #[serde(rename = "angehalten")]
    Halted,
    /// On the device (`fertig`).
    #[serde(rename = "fertig")]
    Done,
    /// Failed; `reason` says why (`fehler`).
    #[serde(rename = "fehler")]
    Error,
}

impl DownloadState {
    /// `CaseIterable.allCases`.
    pub const ALL: [DownloadState; 5] = [
        Self::Waits,
        Self::Loads,
        Self::Halted,
        Self::Done,
        Self::Error,
    ];

    /// The persisted raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Waits => "wartet",
            Self::Loads => "laedt",
            Self::Halted => "angehalten",
            Self::Done => "fertig",
            Self::Error => "fehler",
        }
    }
}
