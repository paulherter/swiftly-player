//! Persistence format of the download list (`liste.json`).
//!
//! The file holds a JSON array of [`DownloadItem`]s of **all** accounts. The keys are the Swift
//! `Codable` keys, absent optionals are omitted (Swift's synthesised `encodeIfPresent`), dates are
//! numbers of seconds since 2001-01-01. Behaviour of `DownloadManager.allRead/allWrite` is kept:
//! a broken list is never silently overwritten (the platform sets the file aside first), and a
//! write replaces only the current account's entries.

use crate::item::DownloadItem;

/// Result of reading the list file.
#[derive(Debug, Clone, PartialEq)]
pub struct LoadedList {
    /// The items of all accounts; empty if the file is missing or unreadable.
    pub items: Vec<DownloadItem>,
    /// `Some((byte count, message))` if the file exists but cannot be decoded. The platform
    /// copies it to `liste.defekt.json` and logs it before anything is written.
    pub broken: Option<(usize, String)>,
}

/// Decode a list file's bytes.
pub fn decode_list(bytes: &[u8]) -> Result<Vec<DownloadItem>, serde_json::Error> {
    serde_json::from_slice(bytes)
}

/// Encode a list for writing (atomic write is the platform's job).
pub fn encode_list(items: &[DownloadItem]) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(items)
}

/// `allRead`: `None` bytes mean the file does not exist.
pub fn load_list(bytes: Option<&[u8]>) -> LoadedList {
    let Some(bytes) = bytes else {
        return LoadedList {
            items: Vec::new(),
            broken: None,
        };
    };
    match decode_list(bytes) {
        Ok(items) => LoadedList {
            items,
            broken: None,
        },
        Err(e) => LoadedList {
            items: Vec::new(),
            broken: Some((bytes.len(), e.to_string())),
        },
    }
}

/// `allWrite`: the existing list without `account`'s entries, then the account's own entries.
pub fn merge_for_write(
    existing: Vec<DownloadItem>,
    account: &str,
    own: Vec<DownloadItem>,
) -> Vec<DownloadItem> {
    let mut all: Vec<DownloadItem> = existing
        .into_iter()
        .filter(|e| e.account != account)
        .collect();
    all.extend(own);
    all
}
