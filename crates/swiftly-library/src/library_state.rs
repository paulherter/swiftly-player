//! The pure state of a library page (Swift `Sources/Shared/LibraryModel.swift`, class
//! `LibraryModel`): load, load more, filtered load and fill, each with a run token.
//!
//! The Swift `async` functions are split at their `await`s. The driver does the fetch a returned
//! [`LibraryCommand`] asks for and feeds the answer to the matching `*_loaded` / `fill_page`
//! method. Only the latest run writes: an answer of an overtaken run changes nothing. Nothing
//! here does I/O; the letter strip (`loadAlphabet`, `jumpTarget`) is not ported (see NOTES.md).

use swiftly_model::Item;

use crate::library_filter::{LibraryFilter, Sorting, SortingExt};
use crate::list_rules::ListRules;
use crate::shelf::{ShelfSource, TitleFilter};
use crate::store::KeyValue;

/// Large enough that the first swipe does not reach the end, small enough that the first page
/// appears quickly (`AppModel.pagesSize`, `AppModel.swift:2082`).
pub const PAGES_SIZE: usize = 60;

/// One answered page: its titles and the server total (`(title:, total:)`).
#[derive(Debug, Clone, PartialEq)]
pub struct Page {
    /// The titles of the page.
    pub items: Vec<Item>,
    /// The server's total.
    pub total: i64,
}

/// A fetch the driver has to do.
#[derive(Debug, Clone, PartialEq)]
pub enum LibraryCommand {
    /// `model.items(from:sorting:filter:since:count:)`; answer with the matching `*_loaded`.
    FetchPage {
        /// The run this belongs to.
        run: u64,
        /// The order to ask for.
        sorting: Sorting,
        /// The filter to ask for.
        filter: LibraryFilter,
        /// Offset.
        since: usize,
        /// How many.
        count: usize,
    },
    /// `model.titleFilter(source, filter:)`; answer with [`LibraryState::title_filter_loaded`].
    FetchTitleFilter {
        /// The run this belongs to.
        run: u64,
        /// The filter to ask for.
        filter: LibraryFilter,
    },
}

/// The result of [`LibraryState::begin_load`].
#[derive(Debug, Clone, PartialEq)]
pub struct LoadStart {
    /// The run token to pass back.
    pub run: u64,
    /// What to fetch, `None` if the load ended at once (no source).
    pub command: Option<LibraryCommand>,
}

/// What a fill step wants next.
#[derive(Debug, Clone, PartialEq)]
pub enum FillStep {
    /// Fetch this page and call [`LibraryState::fill_page`] again.
    Fetch(LibraryCommand),
    /// The fill is over and its result is applied (or discarded as stale).
    Done,
}

#[derive(Debug, Clone)]
enum Purpose {
    /// `filteredLoad`: the run and what the result is stored for.
    Load { of: String },
    /// `loadMore` with a filter: the `loadedFor` seen when it began.
    More { before: Option<String> },
}

/// `fill(...)` (:296-317): fetch pages until something remains.
#[derive(Debug, Clone)]
struct Fill {
    run: u64,
    purpose: Purpose,
    filter: TitleFilter,
    new: Vec<Item>,
    offset: usize,
    raw: i64,
    count: usize,
}

/// A library with filter, sorting and paging (`LibraryModel`).
#[derive(Debug, Clone)]
pub struct LibraryState {
    /// The titles shown.
    pub items: Vec<Item>,
    /// The server's total.
    pub total: i64,
    /// A first page is on its way and nothing is shown.
    pub loads: bool,
    /// A load run started and has not finished, whether or not titles are shown. Differs from `loads`
    /// on a quiet refresh: the old titles stay while the new page is on its way.
    pub running: bool,
    /// The server did not answer, as opposed to "nothing here".
    pub disrupted: bool,
    /// Loading more failed; the view shows a tappable row.
    pub load_more_failed: bool,
    /// The sort order. Use [`LibraryState::set_sorting`] so it is remembered.
    pub sorting: Sorting,
    /// The filter. Use [`LibraryState::set_filter`] so it is remembered.
    pub filter: LibraryFilter,
    remember_name: Option<String>,
    loads_post: bool,
    for_account: u64,
    run: u64,
    filter_ref: Option<TitleFilter>,
    raw_offset: usize,
    raw_total: i64,
    /// How many entries the server delivered to a plain (non-filtering) list, before duplicates were
    /// dropped. The next `StartIndex` is this, not the number of tiles shown: a page whose entries were
    /// all known already must still move on (Plex repeats entries across pages).
    plain_raw: usize,
    loaded_for: Option<String>,
    fill: Option<Fill>,
    more: Option<Option<String>>,
}

fn len64(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(i64::MAX)
}

impl LibraryState {
    /// `init(rememberName:)` (:55-61): reads the remembered order and filter; without a name
    /// nothing is remembered.
    pub fn new(remember_name: Option<&str>, store: &dyn KeyValue) -> Self {
        let mut s = Self {
            items: Vec::new(),
            total: 0,
            loads: true,
            running: false,
            disrupted: false,
            load_more_failed: false,
            sorting: Sorting::Name,
            filter: LibraryFilter::All,
            remember_name: remember_name.map(String::from),
            loads_post: false,
            for_account: 0,
            run: 0,
            filter_ref: None,
            raw_offset: 0,
            raw_total: 0,
            plain_raw: 0,
            loaded_for: None,
            fill: None,
            more: None,
        };
        if let Some(name) = remember_name {
            if let Some(v) = store
                .get(&format!("sortierung.{name}"))
                .and_then(|r| Sorting::from_raw(&r))
            {
                s.sorting = v;
            }
            if let Some(v) = store
                .get(&format!("filter.{name}"))
                .and_then(|r| LibraryFilter::from_raw(&r))
            {
                s.filter = v;
            }
        }
        s
    }

    /// Sets the order and remembers it per place (`didSet { secure() }`, :64-72).
    pub fn set_sorting(&mut self, sorting: Sorting, store: &dyn KeyValue) {
        self.sorting = sorting;
        self.secure(store);
    }

    /// Sets the filter and remembers it per place.
    pub fn set_filter(&mut self, filter: LibraryFilter, store: &dyn KeyValue) {
        self.filter = filter;
        self.secure(store);
    }

    fn secure(&self, store: &dyn KeyValue) {
        if let Some(name) = &self.remember_name {
            Self::remember(self.sorting, name, store);
            store.set(&format!("filter.{name}"), self.filter.raw_value());
        }
    }

    /// Stores the order of a place without a page in memory (`remember(_:for:)`, :77-79).
    pub fn remember(sorting: Sorting, remember_name: &str, store: &dyn KeyValue) {
        store.set(&format!("sortierung.{remember_name}"), sorting.raw_value());
    }

    /// If either changes, reload (`identifier`, :82).
    pub fn identifier(&self) -> String {
        format!("{}|{}", self.sorting.raw_value(), self.filter.raw_value())
    }

    /// Do the contents still belong to the signed-in account? (`outdated`, :35).
    pub fn outdated(&self, account_switch: u64) -> bool {
        self.for_account != account_switch
    }

    /// Drops a running fill. A load more that held the guard never answers then, so it frees it.
    fn drop_fill(&mut self) {
        if let Some(fill) = self.fill.take()
            && matches!(fill.purpose, Purpose::More { .. })
        {
            self.loads_post = false;
            self.more = None;
        }
    }

    /// Whether there is more beyond what is already shown (:151-154).
    pub fn still_more_present(&self) -> bool {
        if self.filter_ref.is_none() {
            ListRules::still_more_present(len64(self.plain_raw.max(self.items.len())), self.total)
        } else {
            ListRules::still_more_present(len64(self.raw_offset), self.raw_total)
        }
    }

    /// Whether this tile triggers loading more: any of the last three rows (:165).
    pub fn solves_load_more_out(&self, id: &str, columns: i64) -> bool {
        ListRules::post_load_section(id, &self.items, columns)
    }

    /// What `items` was loaded for: source, sort, filter, account (:170 and :195-200).
    fn key_of(&self, source: &ShelfSource) -> String {
        format!(
            "{}|{}|{}",
            source.key(),
            self.identifier(),
            self.for_account
        )
    }

    fn page_command(&self, run: u64, since: usize, count: usize) -> LibraryCommand {
        LibraryCommand::FetchPage {
            run,
            sorting: self.sorting,
            filter: self.filter,
            since,
            count,
        }
    }

    /// Starts a load (`load(_:from:)`, :174-231). `views_empty` is `model.views.isEmpty`.
    pub fn begin_load(
        &mut self,
        account_switch: u64,
        views_empty: bool,
        source: Option<&ShelfSource>,
    ) -> LoadStart {
        self.run += 1;
        let run = self.run;
        self.drop_fill();
        // Empty right after an account switch, so placeholders show until the new account fades in.
        if self.outdated(account_switch) {
            self.items.clear();
            self.total = 0;
            self.filter_ref = None;
            self.loaded_for = None;
        }
        self.loads = self.items.is_empty();
        self.running = true;
        self.disrupted = false;
        self.load_more_failed = false;
        self.for_account = account_switch;
        let Some(source) = source else {
            // A server without a library of this type, or one that did not answer at all: tell
            // them apart by whether any libraries are known.
            self.disrupted = views_empty;
            self.loads = false;
            self.running = false;
            return LoadStart { run, command: None };
        };
        if source.is_filtering() {
            return LoadStart {
                run,
                command: Some(LibraryCommand::FetchTitleFilter {
                    run,
                    filter: self.filter,
                }),
            };
        }
        self.filter_ref = None;
        // When refreshing, fetch as many as are already shown (up to 300).
        let for_retrieval = self.key_of(source);
        let reach = if self.loaded_for.as_deref() == Some(for_retrieval.as_str()) {
            300.min(PAGES_SIZE.max(self.items.len()))
        } else {
            PAGES_SIZE
        };
        LoadStart {
            run,
            command: Some(self.page_command(run, 0, reach)),
        }
    }

    /// The first page arrived (the end of `load`, :206-230). `None` is a failed fetch;
    /// `cancelled` says it failed because the task was cancelled, which is not an outage.
    pub fn page_loaded(
        &mut self,
        run: u64,
        source: &ShelfSource,
        answer: Option<Page>,
        cancelled: bool,
    ) {
        if run != self.run {
            return;
        }
        if let Some(page) = answer {
            let of = self.key_of(source);
            let same = self.loaded_for.as_deref() == Some(of.as_str());
            self.plain_raw = if same {
                self.plain_raw.max(page.items.len())
            } else {
                page.items.len()
            };
            self.items = if same {
                ListRules::refresh(&page.items, &self.items, self.total, page.total)
            } else {
                ListRules::without_double(&page.items)
            };
            self.loaded_for = Some(of);
            self.total = page.total;
        } else if !cancelled {
            // If something is already shown it stays.
            self.disrupted = self.items.is_empty();
        }
        self.loads = false;
        self.running = false;
    }

    /// The title filter for "All" arrived (`filteredLoad`, :244-266). Returns the first fetch of
    /// the fill, or `None` if the load ended.
    pub fn title_filter_loaded(
        &mut self,
        run: u64,
        source: &ShelfSource,
        fetched: Option<TitleFilter>,
        cancelled: bool,
    ) -> Option<LibraryCommand> {
        if run != self.run {
            return None;
        }
        let Some(new_filter) = fetched else {
            if !cancelled {
                self.disrupted = self.items.is_empty();
            }
            self.loads = false;
            self.running = false;
            return None;
        };
        let of = self.key_of(source);
        let first = PAGES_SIZE.max(if self.loaded_for.as_deref() == Some(of.as_str()) {
            self.raw_offset
        } else {
            0
        });
        self.drop_fill();
        self.fill = Some(Fill {
            run,
            purpose: Purpose::Load { of },
            filter: new_filter,
            new: Vec::new(),
            offset: 0,
            raw: 0,
            count: first,
        });
        Some(self.page_command(run, 0, first))
    }

    /// Starts loading more (`loadMore`, :234-290). `None` if nothing is to be fetched (outdated,
    /// nothing more, or a load is running). Locks `loads_post` before the first fetch so two
    /// tiles of the loading area cannot both get through. Pass the result of the fetch to
    /// [`LibraryState::more_page_loaded`], or to [`LibraryState::fill_page`] for a filtering
    /// source (the returned command is then a fill step).
    pub fn begin_load_more(
        &mut self,
        account_switch: u64,
        source: &ShelfSource,
        count: usize,
    ) -> Option<LibraryCommand> {
        if self.outdated(account_switch) {
            return None;
        }
        if !self.still_more_present() || self.loads_post || self.loads || self.fill.is_some() {
            return None;
        }
        self.loads_post = true;
        let before = self.loaded_for.clone();
        self.load_more_failed = false;
        self.more = Some(before.clone());
        if source.is_filtering()
            && let Some(filter) = self.filter_ref.clone()
        {
            let run = self.run;
            self.fill = Some(Fill {
                run,
                purpose: Purpose::More { before },
                filter,
                new: Vec::new(),
                offset: self.raw_offset,
                raw: 0,
                count,
            });
            return Some(self.page_command(run, self.raw_offset, count));
        }
        self.plain_raw = self.plain_raw.max(self.items.len());
        Some(self.page_command(self.run, self.plain_raw, count))
    }

    /// The page of a plain (non-filtering) load more arrived (:276-290).
    pub fn more_page_loaded(&mut self, page: Option<Page>, cancelled: bool) {
        let Some(before) = self.more.take() else {
            return;
        };
        self.loads_post = false;
        let Some(page) = page else {
            if !cancelled {
                self.load_more_failed = true;
            }
            return;
        };
        // If it was re-sorted or filtered meanwhile, the page belongs to a different list.
        if self.loaded_for != before {
            return;
        }
        self.items = ListRules::append(&page.items, &self.items);
        self.total = page.total;
        // The server's own offset moves by what it delivered; an empty page ends the list instead of
        // asking for the same page again for ever.
        self.plain_raw = if page.items.is_empty() {
            usize::try_from(page.total.max(0)).unwrap_or(usize::MAX)
        } else {
            self.plain_raw + page.items.len()
        };
    }

    /// A page of a running fill arrived (`fill`, :296-317); `None` is a failed fetch. A page of
    /// an overtaken run is ignored. The result of a finished fill is applied here
    /// (`filteredLoad` :258-266 or `loadMore` :258-270).
    pub fn fill_page(&mut self, run: u64, page: Option<Page>, cancelled: bool) -> FillStep {
        // A page of an overtaken run must not take the running fill away.
        if self.fill.as_ref().is_none_or(|f| f.run != run) {
            return FillStep::Done;
        }
        let Some(mut fill) = self.fill.take() else {
            return FillStep::Done;
        };
        match page {
            None => self.fill_finished(fill, None, cancelled),
            Some(page) => {
                fill.new.extend(fill.filter.sift(&page.items));
                fill.offset += page.items.len();
                fill.raw = page.total;
                fill.count = PAGES_SIZE;
                let go_on = !page.items.is_empty()
                    && fill.new.len() < PAGES_SIZE / 2
                    && len64(fill.offset) < fill.raw;
                if go_on {
                    let cmd = self.page_command(run, fill.offset, fill.count);
                    self.fill = Some(fill);
                    FillStep::Fetch(cmd)
                } else {
                    self.fill_finished(fill, Some(()), cancelled)
                }
            }
        }
    }

    fn fill_finished(&mut self, fill: Fill, ok: Option<()>, cancelled: bool) -> FillStep {
        match fill.purpose {
            Purpose::Load { of } => {
                if fill.run == self.run {
                    if ok.is_none() {
                        if !cancelled {
                            self.disrupted = self.items.is_empty();
                        }
                    } else {
                        self.total = fill.filter.total;
                        self.filter_ref = Some(fill.filter);
                        self.items = fill.new;
                        self.raw_offset = fill.offset;
                        self.raw_total = fill.raw;
                        self.loaded_for = Some(of);
                    }
                    self.loads = false;
                    self.running = false;
                }
            }
            Purpose::More { before } => {
                self.more = None;
                self.loads_post = false;
                if self.loaded_for == before {
                    if ok.is_none() {
                        if !cancelled {
                            self.load_more_failed = true;
                        }
                    } else {
                        self.filter_ref = Some(fill.filter);
                        self.items = ListRules::append(&fill.new, &self.items);
                        self.raw_offset = fill.offset;
                        self.raw_total = fill.raw;
                    }
                }
            }
        }
        FillStep::Done
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryKeyValue;

    fn t(id: &str) -> Item {
        Item::new(id, id, None)
    }
    fn many(from: usize, n: usize) -> Vec<Item> {
        (from..from + n).map(|i| t(&format!("i{i}"))).collect()
    }
    fn page(from: usize, n: usize, total: i64) -> Option<Page> {
        Some(Page {
            items: many(from, n),
            total,
        })
    }
    fn lib() -> ShelfSource {
        ShelfSource::new(Some("l1"), Some("movies"), false, &[])
    }
    fn state() -> LibraryState {
        LibraryState::new(None, &MemoryKeyValue::new())
    }
    fn fetch(c: &Option<LibraryCommand>) -> (u64, usize, usize) {
        match c {
            Some(LibraryCommand::FetchPage {
                run, since, count, ..
            }) => (*run, *since, *count),
            other => panic!("not a page fetch: {other:?}"),
        }
    }
    /// Loads the first page and `more` further pages.
    fn loaded(s: &mut LibraryState, total: i64, pages: usize) {
        let st = s.begin_load(0, false, Some(&lib()));
        let (run, _, count) = fetch(&st.command);
        s.page_loaded(
            run,
            &lib(),
            page(0, count.min(usize::try_from(total).unwrap_or(0)), total),
            false,
        );
        for _ in 1..pages {
            let cmd = s.begin_load_more(0, &lib(), PAGES_SIZE);
            let (_, since, count) = fetch(&cmd);
            s.more_page_loaded(
                page(
                    since,
                    count.min(usize::try_from(total).unwrap_or(0) - since),
                    total,
                ),
                false,
            );
        }
    }

    #[test]
    fn first_load_then_refresh_keeps_further_pages() {
        let mut s = state();
        loaded(&mut s, 2000, 3);
        assert_eq!(s.items.len(), 180);
        // Back from a detail page: as many as shown are fetched (up to 300), the list does not shrink.
        let st = s.begin_load(0, false, Some(&lib()));
        assert_eq!(fetch(&st.command), (st.run, 0, 180));
        assert!(!s.loads, "something is shown");
        s.page_loaded(st.run, &lib(), page(0, 180, 2000), false);
        assert_eq!(s.items.len(), 180);
        // Above 300 the reach stops at 300.
        loaded(&mut s, 2000, 6);
        let st = s.begin_load(0, false, Some(&lib()));
        assert_eq!(fetch(&st.command).2, 300);
    }

    #[test]
    fn total_change_replaces() {
        let mut s = state();
        loaded(&mut s, 120, 2);
        let st = s.begin_load(0, false, Some(&lib()));
        let mut p = page(0, 60, 121);
        if let Some(p) = p.as_mut() {
            p.items[0] = t("neu");
        }
        s.page_loaded(st.run, &lib(), p, false);
        assert_eq!(s.items.len(), 60);
        assert_eq!(s.items[0].id, "neu");
    }

    #[test]
    fn overtaken_run_does_not_write() {
        let mut s = state();
        let old = s.begin_load(0, false, Some(&lib()));
        let new = s.begin_load(0, false, Some(&lib()));
        s.page_loaded(old.run, &lib(), page(0, 60, 100), false);
        assert!(s.items.is_empty() && s.loads, "the old answer is dropped");
        s.page_loaded(new.run, &lib(), page(100, 60, 200), false);
        assert_eq!(s.items[0].id, "i100");
        assert!(!s.loads);
    }

    #[test]
    fn account_switch_empties_at_once_and_blocks_load_more() {
        let mut s = state();
        loaded(&mut s, 200, 1);
        assert!(
            s.begin_load_more(1, &lib(), PAGES_SIZE).is_none(),
            "nothing appended after a switch"
        );
        assert!(s.outdated(1));
        let st = s.begin_load(1, false, Some(&lib()));
        assert!(s.items.is_empty() && s.loads && s.total == 0);
        s.page_loaded(st.run, &lib(), page(500, 60, 100), false);
        assert_eq!(s.items.len(), 60);
        assert!(!s.outdated(1));
    }

    #[test]
    fn failed_first_page_is_disrupted_only_if_empty_and_not_cancelled() {
        let mut s = state();
        let st = s.begin_load(0, false, Some(&lib()));
        s.page_loaded(st.run, &lib(), None, true);
        assert!(!s.disrupted && !s.loads, "cancelled is not an outage");
        let st = s.begin_load(0, false, Some(&lib()));
        s.page_loaded(st.run, &lib(), None, false);
        assert!(s.disrupted);
        loaded(&mut s, 100, 1);
        let st = s.begin_load(0, false, Some(&lib()));
        s.page_loaded(st.run, &lib(), None, false);
        assert!(!s.disrupted, "what is shown stays");
    }

    #[test]
    fn no_source_is_disrupted_only_without_known_libraries() {
        let mut s = state();
        let st = s.begin_load(0, true, None);
        assert!(st.command.is_none() && s.disrupted && !s.loads);
        let st = s.begin_load(0, false, None);
        assert!(st.command.is_none() && !s.disrupted);
    }

    #[test]
    fn load_more_is_locked_and_appends_only_new() {
        let mut s = state();
        loaded(&mut s, 150, 1);
        let first = s.begin_load_more(0, &lib(), PAGES_SIZE);
        assert_eq!(fetch(&first).1, 60);
        assert!(
            s.begin_load_more(0, &lib(), PAGES_SIZE).is_none(),
            "second tile gets nothing through"
        );
        // The server added a title in between: the page overlaps the shown list.
        s.more_page_loaded(page(59, 60, 151), false);
        assert_eq!(s.items.len(), 119);
        assert_eq!(s.total, 151);
        assert!(
            s.begin_load_more(0, &lib(), PAGES_SIZE).is_some(),
            "the lock is released"
        );
    }

    /// F8 (dossier 16): a page whose entries were all shown already (Plex repeats entries) must
    /// still move the next `StartIndex` on, and an empty page ends the list.
    #[test]
    fn plain_paging_uses_the_server_offset() {
        let mut s = state();
        loaded(&mut s, 100, 1);
        let first = s.begin_load_more(0, &lib(), PAGES_SIZE);
        assert_eq!(fetch(&first).1, 60);
        // Three ids already shown, nothing new: the tiles stay 60, the server offset moves to 63.
        s.more_page_loaded(page(0, 3, 100), false);
        assert_eq!(s.items.len(), 60);
        let next = s.begin_load_more(0, &lib(), PAGES_SIZE);
        assert_eq!(fetch(&next).1, 63);
        // A page that delivers nothing at all stops the list.
        s.more_page_loaded(page(0, 0, 100), false);
        assert!(!s.still_more_present());
        assert!(s.begin_load_more(0, &lib(), PAGES_SIZE).is_none());
    }

    #[test]
    fn load_more_failure_and_resort_meanwhile() {
        let mut s = state();
        loaded(&mut s, 150, 1);
        assert!(s.begin_load_more(0, &lib(), PAGES_SIZE).is_some());
        s.more_page_loaded(None, false);
        assert!(s.load_more_failed);
        assert!(s.begin_load_more(0, &lib(), PAGES_SIZE).is_some());
        // Re-sorted meanwhile: a new load changed `loaded_for`, so the late page is dropped.
        let st = s.begin_load(0, false, Some(&lib()));
        s.sorting = Sorting::Latest;
        s.page_loaded(st.run, &lib(), page(0, 60, 150), false);
        s.more_page_loaded(page(60, 60, 150), false);
        assert_eq!(s.items.len(), 60);
    }

    #[test]
    fn filtering_source_fills_until_something_remains() {
        let src = ShelfSource::new(None, None, false, &["a", "b"]);
        let mut s = state();
        let st = s.begin_load(0, false, Some(&src));
        assert!(matches!(
            st.command,
            Some(LibraryCommand::FetchTitleFilter { .. })
        ));
        // Only i0..i9 and i100.. are allowed; the first page is almost all foreign titles.
        let allowed: Vec<Item> = many(0, 10).into_iter().chain(many(100, 100)).collect();
        let filter = TitleFilter::from_identifiers(&allowed);
        let cmd = s.title_filter_loaded(st.run, &src, Some(filter), false);
        assert_eq!(fetch(&cmd), (st.run, 0, PAGES_SIZE));
        // Page 1: ids 0..60 -> 10 allowed (< 30), so it asks again with the page size.
        let FillStep::Fetch(next) = s.fill_page(st.run, page(0, 60, 1000), false) else {
            panic!("filled too early")
        };
        assert_eq!(fetch(&Some(next)), (st.run, 60, PAGES_SIZE));
        // Page 2: ids 100..160 -> 60 allowed, enough.
        assert_eq!(
            s.fill_page(st.run, page(100, 60, 1000), false),
            FillStep::Done
        );
        assert_eq!(s.items.len(), 70);
        assert_eq!(s.total, 110);
        assert!(!s.loads);
        assert!(
            s.still_more_present(),
            "paging follows the server's offset, not what remained"
        );
        // Load more continues from the raw offset.
        let more = s.begin_load_more(0, &src, PAGES_SIZE);
        assert_eq!(fetch(&more).1, 120);
        assert_eq!(
            s.fill_page(st.run, page(160, 0, 1000), false),
            FillStep::Done,
            "an empty page ends the fill"
        );
        assert_eq!(s.items.len(), 70);
        assert!(
            s.begin_load_more(0, &src, PAGES_SIZE).is_some(),
            "the lock was released"
        );
    }

    #[test]
    fn filter_fetch_failure_and_stale_fill() {
        let src = ShelfSource::new(None, None, false, &["a"]);
        let mut s = state();
        let st = s.begin_load(0, false, Some(&src));
        assert!(s.title_filter_loaded(st.run, &src, None, false).is_none());
        assert!(s.disrupted && !s.loads);
        let old = s.begin_load(0, false, Some(&src));
        let cmd = s.title_filter_loaded(
            old.run,
            &src,
            Some(TitleFilter::from_identifiers(&many(0, 5))),
            false,
        );
        assert!(cmd.is_some());
        let _new = s.begin_load(0, false, Some(&src));
        assert_eq!(s.fill_page(old.run, page(0, 5, 5), false), FillStep::Done);
        assert!(s.items.is_empty(), "the overtaken fill wrote nothing");
    }

    #[test]
    fn order_and_filter_are_remembered_per_place() {
        let kv = MemoryKeyValue::new();
        let mut s = LibraryState::new(Some("movies"), &kv);
        assert_eq!((s.sorting, s.filter), (Sorting::Name, LibraryFilter::All));
        s.set_sorting(Sorting::Rating, &kv);
        s.set_filter(LibraryFilter::Begun, &kv);
        assert_eq!(kv.get("sortierung.movies").as_deref(), Some("bewertung"));
        assert_eq!(kv.get("filter.movies").as_deref(), Some("angefangen"));
        let again = LibraryState::new(Some("movies"), &kv);
        assert_eq!(
            (again.sorting, again.filter),
            (Sorting::Rating, LibraryFilter::Begun)
        );
        assert_eq!(again.identifier(), "bewertung|angefangen");
        let other = LibraryState::new(Some("series"), &kv);
        assert_eq!(other.sorting, Sorting::Name);
        let mut nameless = LibraryState::new(None, &kv);
        nameless.set_sorting(Sorting::Latest, &kv);
        assert_eq!(kv.get("sortierung.movies").as_deref(), Some("bewertung"));
        LibraryState::remember(Sorting::Latest, "movies", &kv);
        assert_eq!(kv.get("sortierung.movies").as_deref(), Some("neueste"));
    }

    #[test]
    fn load_more_trigger() {
        let mut s = state();
        loaded(&mut s, 100, 1);
        assert!(s.solves_load_more_out("i59", 5));
        assert!(!s.solves_load_more_out("i0", 5));
    }
}
