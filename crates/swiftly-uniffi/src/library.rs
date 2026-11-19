//! The exported library grid view model (`swiftly_vm::LibraryVm`): same shape as `HomeVm`.

use std::sync::Arc;

use swiftly_library::library_filter::Sorting;
use swiftly_library::{
    FilterChoice, FilterGroupKind, KeyValue, LibraryFilter, ShelfSource, YearSpan,
};
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
pub struct YearSpan {
    pub from: i32,
    pub to: i32,
}

#[uniffi::remote(Enum)]
pub enum FilterGroupKind {
    Status,
    Years,
    Language,
}

/// What picking a row of the filter sheet does; hand it to `LibraryVm::pick`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FilterPick {
    /// The status filter.
    Status { filter: LibraryFilter },
    /// The year span, `None` for all years.
    Years { years: Option<YearSpan> },
    /// The audio language, `None` for any.
    Language { language: Option<String> },
}

impl From<FilterChoice> for FilterPick {
    fn from(choice: FilterChoice) -> Self {
        match choice {
            FilterChoice::Status(filter) => Self::Status { filter },
            FilterChoice::Years(years) => Self::Years { years },
            FilterChoice::Language(language) => Self::Language { language },
        }
    }
}

impl From<FilterPick> for FilterChoice {
    fn from(pick: FilterPick) -> Self {
        match pick {
            FilterPick::Status { filter } => Self::Status(filter),
            FilterPick::Years { years } => Self::Years(years),
            FilterPick::Language { language } => Self::Language(language),
        }
    }
}

/// One line of the sheet drawn as one list (the core's `flat_rows`): the group heading sits on the first line of its
/// group; a group still loading is one line without a `pick`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FilterLinePart {
    /// Hand to `LibraryVm::pick` when the line is tapped; `None` for the "loading" line.
    pub pick: Option<FilterPick>,
    /// The text in the interface language.
    pub label: String,
    /// It is the current pick of its group.
    pub selected: bool,
    /// How many titles it covers, where the server said.
    pub count: Option<u64>,
    /// The heading of the group this line opens.
    pub heading: Option<String>,
}

/// One row of the filter sheet, ready to draw.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FilterRowPart {
    /// Hand to `LibraryVm::pick` when the row is tapped.
    pub pick: FilterPick,
    /// The text in the interface language.
    pub label: String,
    /// It is the current pick of its group.
    pub selected: bool,
    /// How many titles it covers, where the server said.
    pub count: Option<u64>,
}

/// A group of rows with its heading (empty for the first group).
#[derive(Debug, Clone, uniffi::Record)]
pub struct FilterGroupPart {
    /// Which group.
    pub kind: FilterGroupKind,
    /// The heading.
    pub title: String,
    /// The rows; empty while `loading`.
    pub rows: Vec<FilterRowPart>,
    /// The choices are on their way: draw the heading with a quiet progress mark.
    pub loading: bool,
}

/// The whole filter sheet: every platform draws exactly these groups and rows.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FilterSheetPart {
    /// The sheet's title.
    pub title: String,
    /// Status, years, language (a group the server cannot do is not there).
    pub groups: Vec<FilterGroupPart>,
    /// The same rows as one list with the headings on their first line: draw this, do not rebuild it from `groups`.
    pub lines: Vec<FilterLinePart>,
    /// What the filter pill shows for the current picks ("Ungesehen \u{b7} 2010\u{2013}2019 \u{b7} Deutsch").
    pub pill: String,
}

impl From<swiftly_library::FilterSheet> for FilterSheetPart {
    fn from(sheet: swiftly_library::FilterSheet) -> Self {
        let lines = sheet
            .flat_rows()
            .into_iter()
            .map(|l| FilterLinePart {
                pick: l.choice.map(Into::into),
                label: l.label,
                selected: l.selected,
                count: l.count,
                heading: l.heading,
            })
            .collect();
        Self {
            lines,
            pill: sheet.pill,
            title: sheet.title,
            groups: sheet
                .groups
                .into_iter()
                .map(|g| FilterGroupPart {
                    kind: g.kind,
                    title: g.title,
                    loading: g.loading,
                    rows: g
                        .rows
                        .into_iter()
                        .map(|r| FilterRowPart {
                            pick: r.choice.into(),
                            label: r.label,
                            selected: r.selected,
                            count: r.count,
                        })
                        .collect(),
                })
                .collect(),
        }
    }
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
    pub years: Option<YearSpan>,
    pub language: Option<String>,
    pub sheet_stamp: u64,
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
    SetYears { years: Option<YearSpan> },
    SetLanguage { language: Option<String> },
    LoadFilterOptions,
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

    /// The filter sheet. `offered` are the status filters this page offers. Re-read it when
    /// `status.sheet_stamp` or `status.filter` changed; send `LoadFilterOptions` when it opens.
    pub fn filter_sheet(&self, offered: Vec<LibraryFilter>) -> FilterSheetPart {
        self.vm.filter_sheet(&offered).into()
    }

    /// A row of the filter sheet was tapped: one call for every kind of row.
    pub fn pick(&self, pick: FilterPick) {
        self.vm.pick(pick.into());
    }

    /// What the filter pill shows now (status, year span, language), also before the sheet was ever opened.
    pub fn pill_text(&self) -> String {
        self.vm.pill_text()
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

    /// Position in the list of the first title under `key` (the strip's own position, so it may lie past the
    /// loaded tiles: load more, ask again); a letter without titles gives the next one that has some.
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
