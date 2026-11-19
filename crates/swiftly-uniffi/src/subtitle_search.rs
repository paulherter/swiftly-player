//! The exported subtitle search (`swiftly_vm::SubtitleSearchVm`): search the server's providers for a title and let
//! the server download one.

use std::sync::Arc;

use swiftly_vm::{
    AccountRef, SubtitleHitRow, SubtitleLanguage, SubtitleSearchIntent, SubtitleSearchPart,
    SubtitleSearchPhase, SubtitleTrackRow,
};

use crate::error::CoreError;
use crate::transport::CoreTransport;

#[uniffi::remote(Enum)]
pub enum SubtitleSearchPhase {
    Idle,
    Loading,
    Results,
    Empty,
    NoProvider,
    Failed,
    Downloading,
    Done,
}

#[uniffi::remote(Record)]
pub struct SubtitleLanguage {
    pub value: String,
    pub label: String,
    pub selected: bool,
}

#[uniffi::remote(Record)]
pub struct SubtitleHitRow {
    pub id: String,
    pub title: String,
    pub source_line: String,
    pub meta_line: String,
    pub rating: Option<String>,
    pub downloads: Option<i64>,
    pub hearing_impaired: bool,
    pub matches_file: bool,
    pub busy: bool,
}

#[uniffi::remote(Record)]
pub struct SubtitleTrackRow {
    pub index: i64,
    pub label: String,
    pub language: Option<String>,
    pub external: bool,
}

#[uniffi::remote(Record)]
pub struct SubtitleSearchPart {
    pub version: u64,
    pub phase: SubtitleSearchPhase,
    pub title: String,
    pub languages: Vec<SubtitleLanguage>,
    pub rows: Vec<SubtitleHitRow>,
    pub message: Option<String>,
    pub tracks: Vec<SubtitleTrackRow>,
    pub added: i64,
    pub selected_track: Option<i64>,
}

#[uniffi::remote(Enum)]
pub enum SubtitleSearchIntent {
    Search { language: Option<String> },
    Download { id: String },
}

/// Does this account's server have the subtitle search (Jellyfin and Emby do, Plex does not)? The host hides the
/// menu entry when it says no.
#[uniffi::export]
pub fn subtitle_search_offered(account: AccountRef) -> bool {
    swiftly_vm::subtitle_search_offered(&account)
}

/// The subtitle search of one title.
#[derive(uniffi::Object)]
pub struct SubtitleSearchVm {
    vm: swiftly_vm::SubtitleSearchVm<CoreTransport>,
}

impl SubtitleSearchVm {
    pub(crate) fn wrap(vm: swiftly_vm::SubtitleSearchVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { vm })
    }
}

#[uniffi::export]
impl SubtitleSearchVm {
    /// The version; moves whenever the part changes.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// The whole screen state.
    pub fn part(&self) -> SubtitleSearchPart {
        SubtitleSearchPart::clone(&self.vm.part())
    }

    /// An intent; the state is `Loading` / `Downloading` when it returns.
    pub fn send(&self, intent: SubtitleSearchIntent) {
        self.vm.send(intent);
    }

    /// Resolves when the part is newer than `seen`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<swiftly_vm::Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// Observers parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}
