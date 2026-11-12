//! The exported library grid view model (`swiftly_vm::LibraryVm`): same shape as `HomeVm`.

use std::sync::Arc;

use swiftly_library::library_filter::Sorting;
use swiftly_library::{KeyValue, LibraryFilter, ShelfSource};
use swiftly_vm::{
    AccountRef, Change, GridPart, LibraryIntent, LibraryStatus, LibraryStatusPart, Tile,
};

use crate::error::CoreError;
use crate::stores::KeyValueStore;
use crate::transport::CoreTransport;

#[uniffi::remote(Enum)]
pub enum Sorting {
    Name,
    Latest,
    Rating,
    Erscheinung,
}

#[uniffi::remote(Enum)]
pub enum LibraryFilter {
    All,
    Begun,
    Watchlist,
    Unwatched,
}

#[uniffi::remote(Record)]
pub struct ShelfSource {
    pub parent: Option<String>,
    pub only_out: Vec<String>,
    pub art: Option<String>,
    pub collection: bool,
}

/// What the grid shows: where the titles come from, an optional genre, and the name under which
/// sort and filter are remembered.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LibrarySpec {
    /// Library, collection or "All".
    pub source: ShelfSource,
    /// Only this genre.
    pub genre: Option<String>,
    /// Remember sort and filter under this name; `None` = do not remember.
    pub remember_name: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum LibraryStatus {
    Loading,
    Ready,
    Empty,
    Offline,
    SignedOut,
}

#[uniffi::remote(Record)]
pub struct GridPart {
    pub version: u64,
    pub tiles: Vec<Tile>,
    pub total: i64,
}

#[uniffi::remote(Record)]
pub struct LibraryStatusPart {
    pub version: u64,
    pub status: LibraryStatus,
    pub sorting: Sorting,
    pub filter: LibraryFilter,
    pub more_available: bool,
    pub loading_more: bool,
    pub refreshing: bool,
    pub load_more_failed: bool,
    pub toggle_error: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum LibraryIntent {
    Load,
    SetSorting { sorting: Sorting },
    SetFilter { filter: LibraryFilter },
    LoadMore,
    Visible { id: String, columns: u32 },
    SetWatched { id: String, on: bool },
    SetWatchlist { id: String, on: bool },
    AccountSwitched { account: Option<AccountRef> },
}

impl From<LibrarySpec> for swiftly_vm::LibrarySpec {
    fn from(spec: LibrarySpec) -> Self {
        Self {
            source: spec.source,
            genre: spec.genre,
            remember_name: spec.remember_name,
        }
    }
}

/// Bits of `Change.parts` for the library.
#[uniffi::export]
pub fn part_grid() -> u32 {
    swiftly_vm::part::GRID
}

/// Sort and filter live in the host's key-value store as UTF-8 text.
pub(crate) struct TextKeys(pub(crate) Arc<dyn KeyValueStore>);

impl KeyValue for TextKeys {
    fn get(&self, key: &str) -> Option<String> {
        let bytes = self.0.get(key.to_owned())?;
        String::from_utf8(bytes).ok()
    }
    fn set(&self, key: &str, value: &str) {
        self.0.set(key.to_owned(), value.as_bytes().to_vec());
    }
}

/// One entry of the letter strip.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AlphabetEntry {
    /// The key a title is matched against and a jump asks for.
    pub key: String,
    /// Position of the first title with this key in the server's list.
    pub first: u64,
    /// What the strip shows (the letter, "26" for a year, "7" for a rating).
    pub label: String,
    /// A dot before this entry (the next step among years and ratings).
    pub gap: bool,
}

/// The letter strip of the list on screen (`LibraryVm::alphabet`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AlphabetPart {
    /// In the strip's order.
    pub entries: Vec<AlphabetEntry>,
    /// How many titles the list holds.
    pub count: u64,
    /// The order the list is sorted in.
    pub sorting: Sorting,
    /// "Recently added" by month.
    pub monthly: bool,
    /// At least two entries: there is something to jump between.
    pub useful: bool,
}

type Strip = swiftly_rules::alphabet_index::AlphabetIndex;

/// The core's strip as the host record.
fn alphabet_part(index: &Strip, sorting: Sorting) -> AlphabetPart {
    AlphabetPart {
        entries: index
            .entries
            .iter()
            .map(|e| AlphabetEntry {
                key: e.letter.clone(),
                first: e.first as u64,
                label: e.label.clone(),
                gap: e.gap,
            })
            .collect(),
        count: index.count as u64,
        sorting,
        monthly: index.monthly,
        useful: index.is_useful(),
    }
}

/// The grid of a library, collection or genre.
#[derive(uniffi::Object)]
pub struct LibraryVm {
    vm: swiftly_vm::LibraryVm<CoreTransport>,
    /// The strip last handed out; `key_of` and `jump_target` read against it (the host keeps one strip too).
    strip: std::sync::Mutex<Option<Strip>>,
}

impl LibraryVm {
    pub(crate) fn wrap(vm: swiftly_vm::LibraryVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self {
            vm,
            strip: std::sync::Mutex::new(None),
        })
    }

    fn strip(&self) -> std::sync::MutexGuard<'_, Option<Strip>> {
        self.strip
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[uniffi::export]
impl LibraryVm {
    /// The version of the view model.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// The tiles shown and the total count.
    pub fn grid(&self) -> GridPart {
        GridPart::clone(&self.vm.grid())
    }

    /// The shared load state (additive to `status`).
    pub fn load(&self) -> crate::state::LoadPart {
        crate::state::LoadPart::of(self.vm.version(), self.vm.load())
    }

    /// State, sort, filter, paging flags, toggle error.
    pub fn status(&self) -> LibraryStatusPart {
        LibraryStatusPart::clone(&self.vm.status())
    }

    /// An intent. Never blocks.
    pub fn send(&self, intent: LibraryIntent) {
        self.vm.send(intent);
    }

    /// The letter strip of the list on screen (the whole "By name" list when fetched, else the loaded titles).
    /// Remembered for `key_of` and `jump_target`.
    pub fn alphabet(&self) -> AlphabetPart {
        let index = self.vm.alphabet();
        let part = alphabet_part(&index, self.vm.status().sorting);
        *self.strip() = Some(index);
        part
    }

    /// Fetches the whole list of the order on screen (once), so `alphabet` covers every title.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_alphabet(&self) -> Result<(), CoreError> {
        self.vm.load_alphabet().await;
        Ok(())
    }

    /// The strip key of a loaded title (the letter, year or rating the strip lights), against the strip last
    /// handed out by `alphabet`.
    pub fn key_of(&self, id: String) -> Option<String> {
        let strip = self.strip();
        self.vm.key_of(&id, strip.as_ref()?)
    }

    /// Position among the loaded titles of the first one under `key`; `None`: not loaded yet (load more, ask
    /// again).
    pub fn jump_target(&self, key: String) -> Option<u64> {
        let strip = self.strip();
        self.vm.jump_target(&key, strip.as_ref()?).map(|i| i as u64)
    }

    /// Returns at once when newer than `seen`, else waits. Cancelling the Swift `Task` drops it.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// Observers parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}
