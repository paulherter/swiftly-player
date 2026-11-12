//! `LibraryVm`: the grid of a library, a collection or a genre.
//!
//! The logic is `swiftly_library::LibraryState` (what `LibraryModel.swift` decides: run tokens,
//! paging, refresh, the fill of a filtering source). This file is the driver the Swift code had
//! in `AppModel.items(from:...)`: it does the fetch a [`LibraryCommand`] asks for and feeds the
//! answer back.
//!
//! * "By name" is ordered here (`NaturalOrder`): one slim request for the whole list (cached per
//!   source, filter and account, fetched again on the first page), then each page by id.
//!   Every other order is the server's.
//! * Only the latest run writes (the state machine's run token); the state is rebuilt on an
//!   account switch and answers of the old account are dropped by the switch counter.
//! * Sort and filter are remembered per place when `remember_name` is set.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_jellyfin::ItemsQuery;
use swiftly_library::client_ext::{natural_list, natural_page, title_filter};
use swiftly_library::library_filter::Sorting;
use swiftly_library::library_state::{FillStep, PAGES_SIZE, Page};
use swiftly_library::{
    KeyValue, LibraryCommand, LibraryFilter, LibraryState, RememberGenre, ShelfSource, SortingExt,
};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

use crate::account::AccountRef;
use crate::bell::{Bell, Changed, part};
use crate::home::{Client, build_client};
use crate::host::Host;
use crate::host::Shared;
use crate::library_list::{self, LibraryList};
use crate::load_state::{Load, LoadFailure};
use crate::parts::Tile;
use crate::plex::{Plex, build_plex_client, is_plex};
use crate::tile::{Words, grid_tile, plex_grid_tile};
use swiftly_library::TitleFilter;
use swiftly_model::ItemsResponse;
use swiftly_playback::media_server::MediaServer;
use swiftly_playback::section_offering::{SectionOffering, SectionSelection};
use swiftly_plex::PlexClient;
use swiftly_rules::alphabet_index::AlphabetIndex;

/// Where the Merkliste page keeps its kind (`WatchlistModel`).
const WATCHLIST_KIND_KEY: &str = "gattung.merkliste";

/// What the grid shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibrarySpec {
    /// The library, collection or set of libraries.
    pub source: ShelfSource,
    /// Only titles of this genre (a genre page).
    pub genre: Option<String>,
    /// Remember sort and filter under this name (`sortierung.<name>`, `filter.<name>`).
    pub remember_name: Option<String>,
}

/// The titles of the grid, display-ready. `version` is the view model version at which the part
/// was replaced.
#[derive(Debug, Clone, PartialEq)]
pub struct GridPart {
    /// Version of the part.
    pub version: u64,
    /// The titles in order, including the ones loaded by paging.
    pub tiles: Vec<Tile>,
    /// The server's total.
    pub total: i64,
}

/// Where the grid stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryStatus {
    /// A first page is on its way and nothing is shown.
    Loading,
    /// Titles are shown.
    Ready,
    /// The server answered: nothing here.
    Empty,
    /// The server did not answer and nothing is shown.
    Offline,
    /// There is no account.
    SignedOut,
}

/// The state around the grid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryStatusPart {
    /// Version of the part.
    pub version: u64,
    /// The state.
    pub status: LibraryStatus,
    /// The order in use.
    pub sorting: Sorting,
    /// The filter in use.
    pub filter: LibraryFilter,
    /// There are more titles beyond the ones shown.
    pub more_available: bool,
    /// A further page is being fetched.
    pub loading_more: bool,
    /// A load run (a new order or filter, a reload) started and has not finished. Unlike
    /// `status == Loading` this is also true while titles are shown: the old grid stays until the
    /// new page arrives.
    pub refreshing: bool,
    /// Loading more failed; the view offers a retry row (`LoadMore`).
    pub load_more_failed: bool,
    /// The readable reason the last watched or watchlist change failed (`setWatched`
    /// returns it in Swift); cleared by the next change.
    pub toggle_error: Option<String>,
}

/// What the view asks for. Never blocks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryIntent {
    /// Load now (first appearance, pull to refresh); a standing grid keeps its size.
    Load,
    /// Another order; reloads.
    SetSorting {
        /// The order.
        sorting: Sorting,
    },
    /// Another filter; reloads.
    SetFilter {
        /// The filter.
        filter: LibraryFilter,
    },
    /// Fetch the next page now (also the retry after a failure).
    LoadMore,
    /// A tile came into view: one of the last three rows loads more.
    Visible {
        /// The tile's title id.
        id: String,
        /// Tiles per row.
        columns: u32,
    },
    /// Mark a title watched or unwatched (`AppModel.setWatched`). Like Swift there is no
    /// optimistic change: the server is asked first; on success the tile is updated and the
    /// grid reloads (a filter may now exclude it), on failure `toggle_error` says why.
    SetWatched {
        /// The title id.
        id: String,
        /// Watched or not.
        on: bool,
    },
    /// Put a title on the watchlist or take it off (`AppModel.setWatchlist`, the favourite
    /// flag); same rules as [`LibraryIntent::SetWatched`].
    SetWatchlist {
        /// The title id.
        id: String,
        /// On the watchlist or not.
        on: bool,
    },
    /// Another account (or none: signed out). Clears the grid at once.
    AccountSwitched {
        /// The new account, `None` for signed out.
        account: Option<AccountRef>,
    },
}

/// What a tile menu entry asks of the host (the app starts the download sheet, a remote play or a SyncPlay group; the
/// view model only carries the request, like `DetailEffect`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TileRequest {
    /// "Laden": open the download sheet for the title.
    Load {
        /// The title id.
        id: String,
    },
    /// "Abspielen auf …": start the title on a device in reach.
    PlayOn {
        /// The title id.
        id: String,
        /// The device id.
        device: String,
    },
    /// "Gemeinsam schauen": make a SyncPlay group for the title.
    Together {
        /// The title id.
        id: String,
    },
}

/// The title menu's state: what the host offered and what is chosen.
#[derive(Default)]
struct Section {
    offering: Option<SectionOffering>,
    choice: Option<SectionSelection>,
    collections: Vec<Tile>,
    playlists: Vec<Tile>,
}

struct Live<T: HttpTransport> {
    switch: u64,
    /// The cache scope of the account on screen (`None`: signed out).
    scope: Option<swiftly_cache::Scope>,
    client: Option<Arc<Client<T>>>,
    /// A Plex account toggles through this client (the host builds it).
    plex: Option<Arc<PlexClient<Shared<T>>>>,
    state: LibraryState,
    more_running: bool,
    toggle_error: Option<String>,
    /// The reason of the last failed request of this page (reset when a load starts).
    failure: FailureNote,
    grid: Arc<GridPart>,
    status: Arc<LibraryStatusPart>,
}

struct Inner<T: HttpTransport> {
    transport: Arc<T>,
    host: Host,
    words: Words,
    spec: LibrarySpec,
    /// The source in use; starts as `spec.source` and follows the title menu.
    source: Mutex<ShelfSource>,
    /// The kind pill of the Merkliste page (`None`: an ordinary grid, the source decides). Set by `set_remember_kind`.
    kind: Mutex<Option<RememberGenre>>,
    section: Mutex<Section>,
    kv: Arc<dyn KeyValue>,
    collator: Option<NaturalCollator>,
    lists: Mutex<HashMap<String, Arc<Vec<Item>>>>,
    bell: Arc<Bell>,
    menu: Mutex<(crate::detail_more::MenuContext, Vec<TileRequest>)>,
    live: Mutex<Live<T>>,
}

/// The library grid view model. Cheap to clone (a handle).
pub struct LibraryVm<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: HttpTransport + 'static> Clone for LibraryVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

/// The server the grid loads from: the same fetches, asked of Jellyfin/Emby or of Plex
/// (`MediaServer`; Plex turns the Jellyfin words into its own).
enum Kind<T: HttpTransport + 'static> {
    Jelly(Arc<Client<T>>),
    Plex(Arc<Plex<T>>),
}

/// Why the last request failed (the group), shared by the backends of one page; `None` after a success-free start.
type FailureNote = Arc<Mutex<Option<swiftly_net::ErrorTopic>>>;

/// A [`Kind`] that notes the reason of every failed request, so the page can tell unreachable from refused.
struct Backend<T: HttpTransport + 'static> {
    kind: Kind<T>,
    note: FailureNote,
}

impl<T: HttpTransport + 'static> Clone for Backend<T> {
    fn clone(&self) -> Self {
        Self {
            kind: self.kind.clone(),
            note: Arc::clone(&self.note),
        }
    }
}

impl<T: HttpTransport + 'static> Clone for Kind<T> {
    fn clone(&self) -> Self {
        match self {
            Self::Jelly(c) => Self::Jelly(Arc::clone(c)),
            Self::Plex(c) => Self::Plex(Arc::clone(c)),
        }
    }
}

impl<T: HttpTransport + 'static> Backend<T> {
    fn noting<R>(&self, result: Result<R, ErrorKind>) -> Result<R, ErrorKind> {
        if let Err(e) = &result {
            *self.note.lock().unwrap_or_else(PoisonError::into_inner) = Some(e.topic());
        }
        result
    }

    fn tile(&self, item: &Item, words: &Words) -> Tile {
        self.kind.tile(item, words)
    }

    async fn items(&self, query: &ItemsQuery) -> Result<ItemsResponse, ErrorKind> {
        self.noting(self.kind.items(query).await)
    }

    async fn title_filter(
        &self,
        source: &ShelfSource,
        filters: &[String],
        watched: Option<bool>,
    ) -> Result<TitleFilter, ErrorKind> {
        self.noting(self.kind.title_filter(source, filters, watched).await)
    }

    #[allow(clippy::too_many_arguments)] // the Swift signature, kept 1:1
    async fn natural_list(
        &self,
        collator: &NaturalCollator,
        parent_id: Option<&str>,
        sort_order: &str,
        filters: &[String],
        is_watched: Option<bool>,
        recursive: bool,
        types: &[&str],
    ) -> Result<Vec<Item>, ErrorKind> {
        self.noting(
            self.kind
                .natural_list(
                    collator, parent_id, sort_order, filters, is_watched, recursive, types,
                )
                .await,
        )
    }

    async fn natural_page(
        &self,
        list: &[Item],
        since: usize,
        count: usize,
    ) -> Result<ItemsResponse, ErrorKind> {
        self.noting(self.kind.natural_page(list, since, count).await)
    }
}

impl<T: HttpTransport + 'static> Kind<T> {
    fn tile(&self, item: &Item, words: &Words) -> Tile {
        match self {
            Self::Jelly(c) => grid_tile(item, &**c, words),
            Self::Plex(c) => plex_grid_tile(item, &**c, words),
        }
    }

    async fn items(&self, query: &ItemsQuery) -> Result<ItemsResponse, ErrorKind> {
        match self {
            Self::Jelly(c) => c.items(query).await,
            Self::Plex(c) => c.items_page(query).await.map_err(|e| e.into_kind()),
        }
    }

    async fn title_filter(
        &self,
        source: &ShelfSource,
        filters: &[String],
        watched: Option<bool>,
    ) -> Result<TitleFilter, ErrorKind> {
        match self {
            Self::Jelly(c) => title_filter(&**c, source, filters, watched).await,
            Self::Plex(c) => MediaServer::title_filter(&**c, source, filters, watched).await,
        }
    }

    #[allow(clippy::too_many_arguments)] // the Swift signature, kept 1:1
    async fn natural_list(
        &self,
        collator: &NaturalCollator,
        parent_id: Option<&str>,
        sort_order: &str,
        filters: &[String],
        is_watched: Option<bool>,
        recursive: bool,
        types: &[&str],
    ) -> Result<Vec<Item>, ErrorKind> {
        match self {
            Self::Jelly(c) => {
                natural_list(
                    &**c, collator, parent_id, sort_order, filters, is_watched, recursive, types,
                )
                .await
            }
            Self::Plex(c) => c
                .natural_list(
                    &ItemsQuery {
                        parent_id: parent_id.map(String::from),
                        sort_order: sort_order.into(),
                        filters: filters.to_vec(),
                        is_watched,
                        recursive,
                        include_item_types: types.iter().map(|s| (*s).into()).collect(),
                        ..ItemsQuery::default()
                    },
                    collator,
                )
                .await
                .map_err(|e| e.into_kind()),
        }
    }

    async fn natural_page(
        &self,
        list: &[Item],
        since: usize,
        count: usize,
    ) -> Result<ItemsResponse, ErrorKind> {
        match self {
            Self::Jelly(c) => natural_page(&**c, list, since, count).await,
            Self::Plex(c) => c
                .natural_page(
                    list,
                    i64::try_from(since).unwrap_or(i64::MAX),
                    i64::try_from(count).unwrap_or(i64::MAX),
                )
                .await
                .map_err(|e| e.into_kind()),
        }
    }
}

impl<T: HttpTransport + 'static> Live<T> {
    /// Plex when one was given or built, else the Jellyfin/Emby client.
    fn backend(&self) -> Option<Backend<T>> {
        self.plex
            .clone()
            .map(Kind::Plex)
            .or_else(|| self.client.clone().map(Kind::Jelly))
            .map(|kind| Backend {
                kind,
                note: Arc::clone(&self.failure),
            })
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Load,
    More,
}

impl<T: HttpTransport + 'static> LibraryVm<T> {
    /// A view model for `account` (or signed out). Nothing is loaded until
    /// [`LibraryIntent::Load`]. `kv` holds the remembered sort and filter.
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
    pub fn new(
        transport: Arc<T>,
        host: Host,
        kv: Arc<dyn KeyValue>,
        spec: LibrarySpec,
        account: Option<AccountRef>,
    ) -> Result<Self, ErrorKind> {
        let (client, plex) = clients(&transport, &host, account.as_ref())?;
        let state = LibraryState::new(spec.remember_name.as_deref(), &*kv);
        let live = Live {
            switch: 1,
            scope: account.as_ref().map(crate::cache::ViewCache::scope),
            client,
            plex,
            state,
            more_running: false,
            toggle_error: None,
            failure: FailureNote::default(),
            grid: Arc::new(GridPart {
                version: 1,
                tiles: Vec::new(),
                total: 0,
            }),
            status: Arc::new(LibraryStatusPart {
                version: 1,
                status: LibraryStatus::Loading,
                sorting: Sorting::Name,
                filter: LibraryFilter::All,
                more_available: false,
                loading_more: false,
                refreshing: false,
                load_more_failed: false,
                toggle_error: None,
            }),
        };
        let inner = Arc::new(Inner {
            words: Words::new(host.locale.clone()),
            collator: NaturalCollator::new(host.locale.language()).ok(),
            transport,
            host,
            source: Mutex::new(spec.source.clone()),
            kind: Mutex::new(None),
            section: Mutex::new(Section::default()),
            spec,
            kv,
            lists: Mutex::new(HashMap::new()),
            bell: Bell::new(),
            menu: Mutex::new((crate::detail_more::MenuContext::default(), Vec::new())),
            live: Mutex::new(live),
        });
        {
            let mut live = inner.live();
            inner.publish(&mut live);
        }
        let vm = Self { inner };
        vm.watch_cache();
        Ok(vm)
    }

    /// An event (or the polling fallback) that marks the account's lists stale reloads the grid:
    /// the standing grid stays on screen and the fresh answer patches it.
    fn watch_cache(&self) {
        let Some(cache) = self.inner.host.cache.clone() else {
            return;
        };
        let weak = Arc::downgrade(&self.inner);
        let last = Mutex::new(f64::NEG_INFINITY);
        cache.watch(move |change| {
            let Some(inner) = weak.upgrade() else {
                return false;
            };
            if let swiftly_cache::CacheChange::ListsStale(scope) = change {
                let own = inner.live().scope.clone();
                let now = inner.host.clock.now();
                let mut last = last.lock().unwrap_or_else(PoisonError::into_inner);
                if own.as_ref() == Some(scope) && now - *last >= 3.0 {
                    *last = now;
                    drop(last);
                    Inner::start_load(&inner);
                }
            }
            true
        });
    }

    /// What the host knows for the tile menu: the download button, devices in reach, SyncPlay (`TileMenu.entries`).
    pub fn set_menu_context(&self, context: crate::detail_more::MenuContext) {
        if let Ok(mut m) = self.inner.menu.lock() {
            m.0 = context;
        }
    }

    /// The context set by the host (default: nothing offered).
    pub fn menu_context(&self) -> crate::detail_more::MenuContext {
        self.inner
            .menu
            .lock()
            .map(|m| m.0.clone())
            .unwrap_or_default()
    }

    /// A tile menu entry only the host can carry out; queued for [`LibraryVm::take_requests`].
    pub fn request(&self, request: TileRequest) {
        if let Ok(mut m) = self.inner.menu.lock() {
            m.1.push(request);
        }
    }

    /// The queued host requests, oldest first; the queue is emptied.
    pub fn take_requests(&self) -> Vec<TileRequest> {
        self.inner
            .menu
            .lock()
            .map(|mut m| std::mem::take(&mut m.1))
            .unwrap_or_default()
    }

    /// The host tells which libraries, collections and playlists exist for this page's kind (`model.sectionOffering`).
    /// The choice is kept when it is still offered, else "All".
    pub fn set_offering(&self, offering: SectionOffering) {
        let mut s = self
            .inner
            .section
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let keep = s.choice.clone().unwrap_or(SectionSelection::All);
        s.choice = Some(if offering.entries().contains(&keep) {
            keep
        } else {
            SectionSelection::All
        });
        s.offering = Some(offering);
    }

    /// Collection and playlist cards (title, count line as subtitle, poster) for the card lists of the title menu.
    pub fn set_cards(&self, collections: Vec<Tile>, playlists: Vec<Tile>) {
        let mut s = self
            .inner
            .section
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        s.collections = collections;
        s.playlists = playlists;
    }

    /// The title menu; `None` until [`LibraryVm::set_offering`].
    pub fn list(&self) -> Option<LibraryList> {
        let s = self
            .inner
            .section
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let offering = s.offering.as_ref()?;
        Some(library_list::library_list(
            offering,
            s.choice.as_ref().unwrap_or(&SectionSelection::All),
        ))
    }

    /// The cards of the current choice (empty unless collections or playlists are chosen).
    pub fn cards(&self) -> Vec<Tile> {
        let s = self
            .inner
            .section
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        match s.choice {
            Some(SectionSelection::Collections) => s.collections.clone(),
            Some(SectionSelection::Playlists) => s.playlists.clone(),
            _ => Vec::new(),
        }
    }

    /// Picks an entry of the title menu by its key. A library or "All" reloads the grid from that source (sort and
    /// filter stay); collections and playlists only change [`LibraryVm::cards`]. Returns whether the choice changed.
    pub fn select(&self, key: &str) -> bool {
        let wish = SectionSelection::from_remember_value(Some(key));
        let source = {
            let mut s = self
                .inner
                .section
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let Some(offering) = s.offering.clone() else {
                return false;
            };
            if !offering.entries().contains(&wish) || s.choice.as_ref() == Some(&wish) {
                return false;
            }
            s.choice = Some(wish.clone());
            library_list::source_for(&offering, &wish)
        };
        if let Some(source) = source {
            *self
                .inner
                .source
                .lock()
                .unwrap_or_else(PoisonError::into_inner) = source;
            {
                // The store is foreign code: read it before the lock is taken.
                let inner = &self.inner;
                let fresh = LibraryState::new(inner.spec.remember_name.as_deref(), &*inner.kv);
                let mut live = self.inner.live();
                live.state = fresh;
                live.more_running = false;
            }
            Inner::start_load(&self.inner);
        }
        true
    }

    /// The kind the Merkliste page last showed (`WatchlistModel.genre`, key `gattung.merkliste`): `All` before anything
    /// was chosen. Rust hosts only (the page is not on the uniffi surface).
    pub fn remembered_kind(&self) -> RememberGenre {
        RememberGenre::toward(self.inner.kv.get(WATCHLIST_KIND_KEY).as_deref())
    }

    /// Turns this grid into the Merkliste page of `kind` (movies AND series for `All`, like the Mac's
    /// `WatchlistModel`): the filter becomes the watchlist, the query asks for the kind's types over every library, and
    /// the choice is kept. Calling it again with another kind reloads; the same kind again is a no-op. Returns whether
    /// anything changed.
    pub fn set_remember_kind(&self, kind: RememberGenre) -> bool {
        let same = *self
            .inner
            .kind
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            == Some(kind);
        if same && self.inner.live().state.filter == LibraryFilter::Watchlist {
            return false;
        }
        *self
            .inner
            .kind
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(kind);
        *self
            .inner
            .source
            .lock()
            .unwrap_or_else(PoisonError::into_inner) =
            ShelfSource::new(None, kind.art(), false, &[]);
        self.inner
            .kv
            .set(WATCHLIST_KIND_KEY, kind.art().unwrap_or(""));
        let writes = Writes::default();
        {
            let mut live = self.inner.live();
            if live.state.filter != LibraryFilter::Watchlist {
                live.state.set_filter(LibraryFilter::Watchlist, &writes);
            }
            live.more_running = false;
        }
        writes.replay(&*self.inner.kv);
        Inner::start_load(&self.inner);
        true
    }

    /// The letter strip of the list on screen: the whole "By name" list when it was fetched, else the loaded titles.
    pub fn alphabet(&self) -> AlphabetIndex {
        let (sorting, filter, switch, loaded) = {
            let live = self.inner.live();
            (
                live.state.sorting,
                live.state.filter,
                live.switch,
                live.state.items.clone(),
            )
        };
        let key = self.inner.strip_key(sorting, filter, switch);
        let whole = self
            .inner
            .lists
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&key)
            .cloned();
        library_list::alphabet(whole.as_deref().map_or(&loaded, |l| l), sorting)
    }

    /// Fetches the whole list of the order on screen once (slim), so the strip covers every title and not only the
    /// loaded pages (`AppModel.indexList`). "By name" is the list the grid already holds. No-op without a server;
    /// a failed fetch leaves the strip on the loaded titles.
    pub async fn load_alphabet(&self) {
        let (sorting, filter, switch, backend) = {
            let live = self.inner.live();
            (
                live.state.sorting,
                live.state.filter,
                live.switch,
                live.backend(),
            )
        };
        let Some(backend) = backend else { return };
        let key = self.inner.strip_key(sorting, filter, switch);
        if sorting == Sorting::Name {
            if self.inner.collator.is_some() {
                let _ = self.inner.natural(&backend, switch, filter, false).await;
            }
            return;
        }
        if self
            .inner
            .lists
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(&key)
        {
            return;
        }
        let source = self.inner.source();
        let answer = backend
            .items(&ItemsQuery {
                parent_id: source.parent.clone(),
                sort_by: sorting.input_field().into(),
                sort_order: source.bearing(sorting).into(),
                filters: filter.jellyfin_filter(),
                is_watched: filter.is_watched(),
                recursive: self.inner.recursive() || self.inner.spec.genre.is_some(),
                include_item_types: self.inner.types().iter().map(|t| (*t).to_owned()).collect(),
                genres: self.inner.spec.genre.iter().cloned().collect(),
                slim: true,
                ..ItemsQuery::default()
            })
            .await;
        // The switch moved on (account change): the answer belongs to nobody.
        if let Ok(answer) = answer
            && self.inner.live().switch == switch
        {
            self.inner
                .lists
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(key, Arc::new(answer.items));
        }
    }

    /// The strip key of a loaded title (the letter, year or rating the strip lights).
    pub fn key_of(&self, id: &str, index: &AlphabetIndex) -> Option<String> {
        let live = self.inner.live();
        live.state
            .items
            .iter()
            .find(|i| i.id == id)
            .map(|i| index.key(&library_list::index_item(i)))
    }

    /// Position among the loaded titles of the first one under `key`; `None`: not loaded yet (load more, ask again).
    pub fn jump_target(&self, key: &str, index: &AlphabetIndex) -> Option<usize> {
        let live = self.inner.live();
        let rows: Vec<_> = live
            .state
            .items
            .iter()
            .map(library_list::index_item)
            .collect();
        index.target_for_key(key, &rows)
    }

    /// The version of the view model; moves whenever a part is replaced.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The grid part.
    pub fn grid(&self) -> Arc<GridPart> {
        Arc::clone(&self.inner.live().grid)
    }

    /// The page's shared load state (`Idle` while signed out).
    pub fn load(&self) -> Load {
        let live = self.inner.live();
        if live.backend().is_none() {
            Load::Idle
        } else {
            Inner::load_of(&live)
        }
    }

    /// The status part.
    pub fn status(&self) -> Arc<LibraryStatusPart> {
        Arc::clone(&self.inner.live().status)
    }

    /// Waits until the view model is newer than `seen`; names the parts that changed after it
    /// (`part::GRID`, `part::STATUS`).
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`LibraryVm::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// An intent from the view. Never blocks.
    /// Watched and watchlist toggles go to a Plex server from now on (`None`: back to the account).
    pub fn set_plex(&self, plex: Option<Arc<PlexClient<Shared<T>>>>) {
        self.inner.live().plex = plex;
    }

    /// Sends an intent.
    pub fn send(&self, intent: LibraryIntent) {
        let inner = &self.inner;
        match intent {
            LibraryIntent::Load => Inner::start_load(inner),
            LibraryIntent::SetSorting { sorting } => {
                let writes = Writes::default();
                {
                    let mut live = inner.live();
                    if live.state.sorting == sorting {
                        return;
                    }
                    live.state.set_sorting(sorting, &writes);
                }
                // Remembering goes to the host's store (foreign code) after the lock is released.
                writes.replay(&*inner.kv);
                Inner::start_load(inner);
            }
            LibraryIntent::SetFilter { filter } => {
                let writes = Writes::default();
                {
                    let mut live = inner.live();
                    if live.state.filter == filter {
                        return;
                    }
                    live.state.set_filter(filter, &writes);
                }
                // Remembering goes to the host's store (foreign code) after the lock is released.
                writes.replay(&*inner.kv);
                Inner::start_load(inner);
            }
            LibraryIntent::LoadMore => Inner::start_more(inner, None),
            LibraryIntent::Visible { id, columns } => {
                Inner::start_more(inner, Some((id, i64::from(columns))));
            }
            LibraryIntent::SetWatched { id, on } => Inner::toggle(inner, id, on, false),
            LibraryIntent::SetWatchlist { id, on } => Inner::toggle(inner, id, on, true),
            LibraryIntent::AccountSwitched { account } => Inner::switch_account(inner, account),
        }
    }
}

impl<T: HttpTransport + 'static> Inner<T> {
    /// `IncludeItemTypes` of the grid: the kind of the Merkliste page when there is one (movies AND series for "All"),
    /// else the section's.
    fn types(&self) -> Vec<&'static str> {
        match *self.kind.lock().unwrap_or_else(PoisonError::into_inner) {
            Some(kind) => kind.types(),
            None => self.source().types(),
        }
    }

    /// Whether the query descends into folders; the Merkliste always does (its kinds are fixed).
    fn recursive(&self) -> bool {
        self.kind
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_some()
            || self.source().recursive()
    }

    fn source(&self) -> ShelfSource {
        self.source
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn live(&self) -> MutexGuard<'_, Live<T>> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The shared load state from the facts the page holds.
    fn load_of(live: &Live<T>) -> Load {
        let s = &live.state;
        Load::from_facts(
            s.loads,
            !s.items.is_empty(),
            (s.disrupted && s.items.is_empty()).then(|| {
                let note = *live.failure.lock().unwrap_or_else(PoisonError::into_inner);
                note.map_or(LoadFailure::Offline, LoadFailure::from_topic)
            }),
        )
    }

    fn publish(&self, live: &mut Live<T>) {
        let s = &live.state;
        let backend = live.backend();
        let tiles: Vec<Tile> = backend.as_ref().map_or_else(Vec::new, |backend| {
            s.items
                .iter()
                .map(|i| backend.tile(i, &self.words))
                .collect()
        });
        let total = s.total;
        let load = Self::load_of(live);
        let status = if backend.is_none() {
            LibraryStatus::SignedOut
        } else {
            match load {
                Load::Idle | Load::Loading | Load::Refreshing => LibraryStatus::Loading,
                Load::Loaded => LibraryStatus::Ready,
                Load::Empty => LibraryStatus::Empty,
                Load::Failed(_) | Load::Offline => LibraryStatus::Offline,
            }
        };
        let rest = (
            status,
            s.sorting,
            s.filter,
            backend.is_some() && s.still_more_present(),
            live.more_running,
            backend.is_some() && s.running,
            s.load_more_failed,
            live.toggle_error.clone(),
        );
        let old = &live.status;
        let status_changed = rest
            != (
                old.status,
                old.sorting,
                old.filter,
                old.more_available,
                old.loading_more,
                old.refreshing,
                old.load_more_failed,
                old.toggle_error.clone(),
            );
        let grid_changed = tiles != live.grid.tiles || total != live.grid.total;
        if !grid_changed && !status_changed {
            return;
        }
        let mut changed = Vec::new();
        if grid_changed {
            changed.push(0);
        }
        if status_changed {
            changed.push(1);
        }
        let version = self.bell.bump(&changed);
        if grid_changed {
            live.grid = Arc::new(GridPart {
                version,
                tiles,
                total,
            });
        }
        if status_changed {
            let (
                status,
                sorting,
                filter,
                more_available,
                loading_more,
                refreshing,
                load_more_failed,
                toggle_error,
            ) = rest;
            live.status = Arc::new(LibraryStatusPart {
                version,
                status,
                sorting,
                filter,
                more_available,
                loading_more,
                refreshing,
                load_more_failed,
                toggle_error,
            });
        }
        const { assert!(part::GRID == 1 << 0 && part::STATUS == 1 << 1) };
    }

    fn start_load(self: &Arc<Self>) {
        let mut live = self.live();
        let Some(client) = live.backend() else {
            self.publish(&mut live);
            return;
        };
        let switch = live.switch;
        *live.failure.lock().unwrap_or_else(PoisonError::into_inner) = None;
        let start = live.state.begin_load(switch, false, Some(&self.source()));
        self.publish(&mut live);
        drop(live);
        self.spawn_drive(Mode::Load, switch, client, start.command);
    }

    fn start_more(self: &Arc<Self>, trigger: Option<(String, i64)>) {
        let mut live = self.live();
        let Some(client) = live.backend() else {
            return;
        };
        if let Some((id, columns)) = trigger
            && !live.state.solves_load_more_out(&id, columns)
        {
            return;
        }
        let switch = live.switch;
        let Some(command) = live
            .state
            .begin_load_more(switch, &self.source(), PAGES_SIZE)
        else {
            return;
        };
        live.more_running = true;
        self.publish(&mut live);
        drop(live);
        self.spawn_drive(Mode::More, switch, client, Some(command));
    }

    /// `setWatched` / `setWatchlist`: ask the server, then show the result.
    fn toggle(self: &Arc<Self>, id: String, on: bool, watchlist: bool) {
        let mut live = self.live();
        let plex = live.plex.clone();
        let client = live.client.clone();
        if plex.is_none() && client.is_none() {
            return;
        }
        live.toggle_error = None;
        let switch = live.switch;
        self.publish(&mut live);
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let done = match (&plex, &client) {
                // Plex: the watchlist is the favourite rating (`PlexClient.setFavorite`).
                (Some(plex), _) if watchlist => {
                    plex.set_favorite(&id, on).await.map_err(|e| e.into_kind())
                }
                (Some(plex), _) => plex
                    .set_watched_key(&id, on)
                    .await
                    .map_err(|e| e.into_kind()),
                (None, Some(client)) if watchlist => client.set_watchlist(&id, on).await,
                (None, Some(client)) => client.set_watched(&id, on).await,
                (None, None) => return,
            };
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            match done {
                Err(e) => live.toggle_error = Some(inner.words.error(&e)),
                Ok(()) => {
                    for item in live.state.items.iter_mut().filter(|i| i.id == id) {
                        let data = item.user_data.get_or_insert_with(Default::default);
                        if watchlist {
                            data.is_favorite = Some(on);
                        } else {
                            data.played = Some(on);
                        }
                    }
                }
            }
            let ok = live.toggle_error.is_none();
            inner.publish(&mut live);
            drop(live);
            if ok {
                Inner::start_load(&inner);
            }
        }));
    }

    fn switch_account(self: &Arc<Self>, account: Option<AccountRef>) {
        // The store is foreign code: read it before the lock is taken.
        let fresh = LibraryState::new(self.spec.remember_name.as_deref(), &*self.kv);
        {
            let mut live = self.live();
            live.switch += 1;
            live.scope = account.as_ref().map(crate::cache::ViewCache::scope);
            (live.client, live.plex) =
                clients(&self.transport, &self.host, account.as_ref()).unwrap_or((None, None));
            // A fresh state: a stale page of the old account can no longer reach it.
            live.state = fresh;
            live.more_running = false;
            live.toggle_error = None;
            self.lists
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clear();
        }
        self.start_load();
    }

    fn spawn_drive(
        self: &Arc<Self>,
        mode: Mode,
        switch: u64,
        client: Backend<T>,
        command: Option<LibraryCommand>,
    ) {
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            inner.drive(mode, switch, &client, command).await;
        }));
    }

    /// Does the fetches the state machine asks for until it asks for none.
    async fn drive(
        &self,
        mode: Mode,
        switch: u64,
        client: &Backend<T>,
        mut command: Option<LibraryCommand>,
    ) {
        let source = &self.source();
        while let Some(current) = command.take() {
            match current {
                LibraryCommand::FetchTitleFilter { run, filter } => {
                    let fetched = client
                        .title_filter(source, &filter.jellyfin_filter(), filter.is_watched())
                        .await
                        .ok();
                    let mut live = self.live();
                    if live.switch != switch {
                        return;
                    }
                    command = live.state.title_filter_loaded(run, source, fetched, false);
                    self.publish(&mut live);
                }
                LibraryCommand::FetchPage {
                    run,
                    sorting,
                    filter,
                    since,
                    count,
                } => {
                    // The first page of an unfiltered grid paints from the cache before the fetch
                    // and is stored after it (stale-while-revalidate).
                    let remembered = (mode == Mode::Load && since == 0 && !source.is_filtering())
                        .then(|| self.remember(switch, sorting, filter, count))
                        .flatten();
                    let mut painted = false;
                    if let Some(memory) = &remembered
                        && let Some(cached) = memory.read()
                    {
                        let mut live = self.live();
                        if live.switch != switch {
                            return;
                        }
                        // Only an empty grid paints from the cache; a standing one is newer.
                        if live.state.items.is_empty() {
                            live.state.page_loaded(run, source, Some(cached), false);
                            self.publish(&mut live);
                            painted = true;
                        }
                    }
                    let page = self
                        .fetch_page(client, switch, sorting, filter, since, count)
                        .await;
                    let changed = match (&remembered, &page) {
                        (Some(memory), Some(page)) => memory.write(page),
                        _ => true,
                    };
                    let mut live = self.live();
                    if live.switch != switch {
                        return;
                    }
                    if painted && page.is_some() && !changed {
                        // Same answer as the painted copy: nothing to patch, nothing to redraw.
                    } else if source.is_filtering() {
                        if let FillStep::Fetch(next) = live.state.fill_page(run, page, false) {
                            command = Some(next);
                        }
                    } else if mode == Mode::Load {
                        live.state.page_loaded(run, source, page, false);
                    } else {
                        live.state.more_page_loaded(page, false);
                    }
                    self.publish(&mut live);
                }
            }
        }
        if mode == Mode::More {
            let mut live = self.live();
            if live.switch == switch {
                live.more_running = false;
                self.publish(&mut live);
            }
        }
    }

    /// The cache slot of the first page for this order and filter, if there is a cache and an
    /// account. The ticket is taken now, so an answer that outlives a logout is not stored.
    fn remember(
        &self,
        switch: u64,
        sorting: Sorting,
        filter: LibraryFilter,
        count: usize,
    ) -> Option<Remembered> {
        let cache = self.host.cache.clone()?;
        let scope = {
            let live = self.live();
            if live.switch != switch {
                return None;
            }
            live.scope.clone()?
        };
        let source = self.source();
        let natural = sorting == Sorting::Name && self.collator.is_some();
        let key = format!(
            "lib|{}|{}|{}|{}|{}|{count}",
            source.key(),
            self.spec.genre.as_deref().unwrap_or(""),
            if natural {
                "natural"
            } else {
                sorting.input_field()
            },
            source.bearing(sorting),
            filter.raw_value(),
        );
        Some(Remembered {
            ticket: cache.ticket(&scope),
            cache,
            scope,
            key,
        })
    }

    /// One page in the given order (`AppModel.items(from:sorting:filter:since:count:)`).
    async fn fetch_page(
        &self,
        client: &Backend<T>,
        switch: u64,
        sorting: Sorting,
        filter: LibraryFilter,
        since: usize,
        count: usize,
    ) -> Option<Page> {
        let source = &self.source();
        if sorting == Sorting::Name && self.collator.is_some() {
            let list = self.natural(client, switch, filter, since == 0).await?;
            let page = client.natural_page(&list, since, count).await.ok()?;
            return Some(Page {
                items: page.items,
                total: page.total_record_count,
            });
        }
        let answer = client
            .items(&ItemsQuery {
                parent_id: source.parent.clone(),
                limit: i64::try_from(count).unwrap_or(i64::MAX),
                start_index: i64::try_from(since).unwrap_or(i64::MAX),
                sort_by: sorting.input_field().into(),
                sort_order: source.bearing(sorting).into(),
                filters: filter.jellyfin_filter(),
                is_watched: filter.is_watched(),
                recursive: self.recursive() || self.spec.genre.is_some(),
                include_item_types: self.types().iter().map(|t| (*t).to_owned()).collect(),
                genres: self.spec.genre.iter().cloned().collect(),
                ..ItemsQuery::default()
            })
            .await
            .ok()?;
        Some(Page {
            items: answer.items,
            total: answer.total_record_count,
        })
    }

    /// Where the whole list of an order is kept: "By name" under the natural list's key, the others next to it.
    fn strip_key(&self, sorting: Sorting, filter: LibraryFilter, switch: u64) -> String {
        let base = format!(
            "{}|{}|{}|{switch}",
            self.source().key(),
            self.spec.genre.as_deref().unwrap_or(""),
            filter.raw_value()
        );
        if sorting == Sorting::Name {
            base
        } else {
            format!("{base}|{}", sorting.input_field())
        }
    }

    /// The whole list in "By name" order, slim; kept per source, filter and account.
    async fn natural(
        &self,
        client: &Backend<T>,
        switch: u64,
        filter: LibraryFilter,
        fresh: bool,
    ) -> Option<Arc<Vec<Item>>> {
        let source = &self.source();
        let key = format!(
            "{}|{}|{}|{switch}",
            source.key(),
            self.spec.genre.as_deref().unwrap_or(""),
            filter.raw_value()
        );
        if !fresh
            && let Some(list) = self
                .lists
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&key)
        {
            return Some(Arc::clone(list));
        }
        let collator = self.collator.as_ref()?;
        let types = self.types();
        let list = if let Some(genre) = &self.spec.genre {
            let answer = client
                .items(&ItemsQuery {
                    parent_id: source.parent.clone(),
                    sort_by: Sorting::Name.input_field().into(),
                    sort_order: source.bearing(Sorting::Name).into(),
                    filters: filter.jellyfin_filter(),
                    is_watched: filter.is_watched(),
                    recursive: true,
                    include_item_types: types.iter().map(|t| (*t).to_owned()).collect(),
                    genres: vec![genre.clone()],
                    slim: true,
                    ..ItemsQuery::default()
                })
                .await
                .ok()?;
            NaturalOrder::sorted(answer.items, collator, |i| {
                (i.name.as_str(), i.sort_name.as_deref())
            })
        } else {
            client
                .natural_list(
                    collator,
                    source.parent.as_deref(),
                    source.bearing(Sorting::Name),
                    &filter.jellyfin_filter(),
                    filter.is_watched(),
                    self.recursive(),
                    &types,
                )
                .await
                .ok()?
        };
        let list = Arc::new(list);
        self.lists
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key, Arc::clone(&list));
        Some(list)
    }
}

/// One cache slot: where the first page of a grid is read from and written to.
struct Remembered {
    cache: crate::cache::ViewCache,
    scope: swiftly_cache::Scope,
    ticket: swiftly_cache::Ticket,
    key: String,
}

impl Remembered {
    fn read(&self) -> Option<Page> {
        let page = self.cache.read_page(&self.scope, &self.key)?;
        let total = page.total.and_then(|t| i64::try_from(t).ok())?;
        Some(Page {
            items: page.items,
            total,
        })
    }

    /// Stores the answer; `true` if it differs from what was stored.
    fn write(&self, page: &Page) -> bool {
        let total = u64::try_from(page.total).ok();
        self.cache
            .write_page(&self.ticket, &self.key, &page.items, total)
    }
}

/// The clients of an account: a Plex account gets the Plex one, every other the Jellyfin one.
type Clients<T> = (Option<Arc<Client<T>>>, Option<Arc<Plex<T>>>);

/// Writes collected under the lock and handed to the host store after it.
#[derive(Default)]
struct Writes(Mutex<Vec<(String, String)>>);

impl KeyValue for Writes {
    fn get(&self, _: &str) -> Option<String> {
        None
    }
    fn set(&self, key: &str, value: &str) {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((key.to_owned(), value.to_owned()));
    }
}

impl Writes {
    fn replay(&self, store: &dyn KeyValue) {
        let all = std::mem::take(&mut *self.0.lock().unwrap_or_else(PoisonError::into_inner));
        for (key, value) in all {
            store.set(&key, &value);
        }
    }
}

fn clients<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: Option<&AccountRef>,
) -> Result<Clients<T>, ErrorKind> {
    match account {
        None => Ok((None, None)),
        Some(a) if is_plex(a) => Ok((None, Some(Arc::new(build_plex_client(transport, host, a)?)))),
        Some(a) => Ok((Some(Arc::new(build_client(transport, host, a)?)), None)),
    }
}
