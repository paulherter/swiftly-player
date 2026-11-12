//! The exported search view model (`swiftly_vm::SearchVm`).

use std::sync::Arc;

use swiftly_vm::{
    AccountRef, Change, SearchGroup, SearchIntent, SearchKind, SearchResultsPart, SearchStatus,
    SearchStatusPart, Sleeper, Tile,
};

use crate::error::CoreError;
use crate::transport::CoreTransport;

#[uniffi::remote(Enum)]
pub enum SearchKind {
    Movies,
    Series,
}

#[uniffi::remote(Record)]
pub struct SearchGroup {
    pub kind: SearchKind,
    pub tiles: Vec<Tile>,
}

#[uniffi::remote(Record)]
pub struct SearchResultsPart {
    pub version: u64,
    pub query: String,
    pub groups: Vec<SearchGroup>,
}

#[uniffi::remote(Enum)]
pub enum SearchStatus {
    Idle,
    Searching,
    Done,
    Empty,
    Offline,
    SignedOut,
}

#[uniffi::remote(Record)]
pub struct SearchStatusPart {
    pub version: u64,
    pub status: SearchStatus,
}

#[uniffi::remote(Enum)]
pub enum SearchIntent {
    Query { text: String },
    Pick { term: String },
    Remember,
    ClearRecents,
    AccountSwitched { account: Option<AccountRef> },
}

/// Bit of `Change.parts`: the result groups.
#[uniffi::export]
pub fn part_results() -> u32 {
    swiftly_vm::part::RESULTS
}

/// Bit of `Change.parts`: the recent terms.
#[uniffi::export]
pub fn part_recents() -> u32 {
    swiftly_vm::part::RECENTS
}

/// Debounce on the runtime UniFFI already has.
pub(crate) struct TokioSleeper;

impl Sleeper for TokioSleeper {
    fn sleep(
        &self,
        seconds: f64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        Box::pin(tokio::time::sleep(crate::support::wait_duration(seconds)))
    }
}

/// Search with debounce, result groups and recent terms.
#[derive(uniffi::Object)]
pub struct SearchVm {
    vm: swiftly_vm::SearchVm<CoreTransport>,
}

impl SearchVm {
    pub(crate) fn wrap(vm: swiftly_vm::SearchVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { vm })
    }
}

#[uniffi::export]
impl SearchVm {
    /// The version of the view model.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// The result groups for the current query.
    pub fn results(&self) -> SearchResultsPart {
        SearchResultsPart::clone(&self.vm.results())
    }

    /// The shared load state (additive to `status`).
    pub fn load(&self) -> crate::state::LoadPart {
        crate::state::LoadPart::of(self.vm.version(), self.vm.load())
    }

    /// Idle, searching, done, empty, offline, signed out.
    pub fn status(&self) -> SearchStatusPart {
        SearchStatusPart::clone(&self.vm.status())
    }

    /// Recent terms of the account, newest first.
    pub fn recents(&self) -> Vec<String> {
        Vec::clone(&self.vm.recents())
    }

    /// An intent. Never blocks.
    pub fn send(&self, intent: SearchIntent) {
        self.vm.send(intent);
    }

    /// Returns at once when newer than `seen`, else waits.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// Observers parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}
