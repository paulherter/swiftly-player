//! `SearchVm`: the search page as a view model.
//!
//! Rules from the Swift code (`SearchView.searching`, `AppModel.search`, `JellyfinClient.search`):
//! a term under two characters clears the page; otherwise the request waits [`DEBOUNCE`] so not
//! every keystroke hits the server, and only the latest query may write. Movies and series
//! only (Swift deliberately leaves episodes out of the search) come from the full-text
//! search, one hit per work and in natural order; **a failed search is "offline", an empty
//! answer is "nothing found"**. Recent terms are `SearchHistory` (last eight per
//! account, newest first).

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_library::KeyValue;
use swiftly_library::client_ext::items_in_times;
use swiftly_library::search_history;
use swiftly_model::{Item, ItemKind};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_rules::display_rules::search_term_fits;
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

use crate::account::AccountRef;
use crate::bell::{Bell, Changed, part};
use crate::home::{Client, build_client};
use crate::host::Shared;
use crate::host::{Host, Sleeper};
use crate::load_state::{Load, LoadEvent, LoadFailure};
use crate::parts::Tile;
use crate::tile::{Words, grid_tile, plex_grid_tile};
use swiftly_plex::PlexClient;

/// How long the query rests before the request goes out (`Task.sleep(.milliseconds(300))`).
pub const DEBOUNCE: f64 = 0.3;
const MOVIE_SERIES_LIMIT: i64 = 40;

/// Which kind of hits a group holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchKind {
    /// Movies.
    Movies,
    /// Series.
    Series,
}

/// One group of hits, display-ready.
#[derive(Debug, Clone, PartialEq)]
pub struct SearchGroup {
    /// What the group holds.
    pub kind: SearchKind,
    /// The hits.
    pub tiles: Vec<Tile>,
}

/// The hits for `query`. Groups are in the order movies, series; empty groups
/// are left out.
#[derive(Debug, Clone, PartialEq)]
pub struct SearchResultsPart {
    /// Version of the part.
    pub version: u64,
    /// The term the hits belong to (trimmed).
    pub query: String,
    /// The groups.
    pub groups: Vec<SearchGroup>,
}

/// Where the search stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchStatus {
    /// No usable term: the page shows the recent terms.
    Idle,
    /// Waiting out the debounce or for the server.
    Searching,
    /// Hits are shown.
    Done,
    /// The server answered: nothing found.
    Empty,
    /// The server did not answer.
    Offline,
    /// There is no account.
    SignedOut,
}

impl SearchStatus {
    /// The status a settled or running [`Load`] stands for (`Idle` is the empty term).
    #[must_use]
    pub fn from_load(load: Load) -> Self {
        match load {
            Load::Idle => Self::Idle,
            Load::Loading | Load::Refreshing => Self::Searching,
            Load::Loaded => Self::Done,
            Load::Empty => Self::Empty,
            Load::Failed(_) | Load::Offline => Self::Offline,
        }
    }
}

/// The status of the search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchStatusPart {
    /// Version of the part.
    pub version: u64,
    /// The state.
    pub status: SearchStatus,
}

/// What the view asks for. Never blocks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchIntent {
    /// The text field changed.
    Query {
        /// The text as typed.
        text: String,
    },
    /// A recent term was picked: searches at once, without the debounce.
    Pick {
        /// The term.
        term: String,
    },
    /// The user opened a hit or submitted: remember the current term in the history.
    Remember,
    /// Empty the recent terms.
    ClearRecents,
    /// Another account (or none). Clears the page and loads that account's recents.
    AccountSwitched {
        /// The new account, `None` for signed out.
        account: Option<AccountRef>,
    },
}

/// Which server answers the search.
enum Backend<T: HttpTransport + 'static> {
    Jellyfin(Arc<Client<T>>),
    Plex(Arc<PlexClient<Shared<T>>>),
}

impl<T: HttpTransport + 'static> Backend<T> {
    fn of(live: &Live<T>) -> Option<Self> {
        live.plex
            .clone()
            .map(Self::Plex)
            .or_else(|| live.client.clone().map(Self::Jellyfin))
    }
}

struct Live<T: HttpTransport> {
    switch: u64,
    generation: u64,
    account: Option<AccountRef>,
    client: Option<Arc<Client<T>>>,
    /// A Plex account searches through this client instead (the host builds it).
    plex: Option<Arc<PlexClient<Shared<T>>>>,
    term: String,
    results: Arc<SearchResultsPart>,
    status: Arc<SearchStatusPart>,
    /// Why the last search failed, when it did and the server could be reached (`Offline` status).
    failure: Option<crate::load_state::LoadFailure>,
    recents: Arc<Vec<String>>,
}

struct Inner<T: HttpTransport> {
    transport: Arc<T>,
    host: Host,
    sleeper: Arc<dyn Sleeper>,
    history: Arc<dyn KeyValue>,
    words: Words,
    collator: Option<NaturalCollator>,
    bell: Arc<Bell>,
    live: Mutex<Live<T>>,
}

/// The search view model. Cheap to clone (a handle).
pub struct SearchVm<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: HttpTransport + 'static> Clone for SearchVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

fn history_key(account: Option<&AccountRef>) -> Option<String> {
    account.map(AccountRef::key)
}

impl<T: HttpTransport + 'static> SearchVm<T> {
    /// A view model for `account` (or signed out). `history` stores the recent terms.
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
    pub fn new(
        transport: Arc<T>,
        host: Host,
        sleeper: Arc<dyn Sleeper>,
        history: Arc<dyn KeyValue>,
        account: Option<AccountRef>,
    ) -> Result<Self, ErrorKind> {
        let client = account
            .as_ref()
            .map(|a| build_client(&transport, &host, a).map(Arc::new))
            .transpose()?;
        let recents = search_history::list(&search_history::load(
            history_key(account.as_ref()).as_deref(),
            &*history,
        ));
        let status = if client.is_some() {
            SearchStatus::Idle
        } else {
            SearchStatus::SignedOut
        };
        let live = Live {
            switch: 1,
            generation: 0,
            account,
            client,
            plex: None,
            term: String::new(),
            results: Arc::new(SearchResultsPart {
                version: 1,
                query: String::new(),
                groups: Vec::new(),
            }),
            status: Arc::new(SearchStatusPart { version: 1, status }),
            failure: None,
            recents: Arc::new(recents),
        };
        Ok(Self {
            inner: Arc::new(Inner {
                words: Words::new(host.locale.clone()),
                collator: NaturalCollator::new(host.locale.language()).ok(),
                transport,
                host,
                sleeper,
                history,
                bell: Bell::new(),
                live: Mutex::new(live),
            }),
        })
    }

    /// The version of the view model; moves whenever a part is replaced.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The hits.
    pub fn results(&self) -> Arc<SearchResultsPart> {
        Arc::clone(&self.inner.live().results)
    }

    /// The search's shared load state, from the status it shows.
    pub fn load(&self) -> Load {
        let live = self.inner.live();
        match (Load::from_search(live.status.status), live.failure) {
            (Load::Offline, Some(LoadFailure::Failed(kind))) => Load::Failed(kind),
            (load, _) => load,
        }
    }

    /// The status.
    pub fn status(&self) -> Arc<SearchStatusPart> {
        Arc::clone(&self.inner.live().status)
    }

    /// The recent terms, newest first (at most eight).
    pub fn recents(&self) -> Arc<Vec<String>> {
        Arc::clone(&self.inner.live().recents)
    }

    /// Waits until the view model is newer than `seen`; names the parts that changed after it
    /// (`part::RESULTS`, `part::STATUS`, `part::RECENTS`).
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`SearchVm::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// An intent from the view. Never blocks.
    /// Searches a Plex server (`MediaServer.search`) from now on, or leaves Plex with `None`.
    /// Like an account switch: older answers are dropped and the page starts empty.
    pub fn set_plex(&self, plex: Option<Arc<PlexClient<Shared<T>>>>) {
        self.inner.set_plex(plex);
    }

    /// Sends an intent.
    pub fn send(&self, intent: SearchIntent) {
        let inner = &self.inner;
        match intent {
            SearchIntent::Query { text } => Inner::query(inner, &text, true),
            SearchIntent::Pick { term } => Inner::query(inner, &term, false),
            SearchIntent::Remember => inner.remember(),
            SearchIntent::ClearRecents => inner.clear_recents(),
            SearchIntent::AccountSwitched { account } => Inner::switch_account(inner, account),
        }
    }
}

impl<T: HttpTransport + 'static> Inner<T> {
    fn live(&self) -> MutexGuard<'_, Live<T>> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Replaces the parts that differ and rings the bell once.
    fn set(
        &self,
        live: &mut Live<T>,
        query: &str,
        groups: Vec<SearchGroup>,
        status: SearchStatus,
        recents: Option<Vec<String>>,
    ) {
        let results_changed = query != live.results.query || groups != live.results.groups;
        let status_changed = status != live.status.status;
        let recents_changed = recents.as_ref().is_some_and(|r| **r != *live.recents);
        let mut changed = Vec::new();
        if results_changed {
            changed.push(0);
        }
        if status_changed {
            changed.push(1);
        }
        if recents_changed {
            changed.push(2);
        }
        if changed.is_empty() {
            return;
        }
        let version = self.bell.bump(&changed);
        if results_changed {
            live.results = Arc::new(SearchResultsPart {
                version,
                query: query.to_owned(),
                groups,
            });
        }
        if status_changed {
            live.status = Arc::new(SearchStatusPart { version, status });
        }
        if let (true, Some(recents)) = (recents_changed, recents) {
            live.recents = Arc::new(recents);
        }
        const { assert!(part::RESULTS == 1 && part::STATUS == 2 && part::RECENTS == 4) };
    }

    fn query(self: &Arc<Self>, text: &str, debounce: bool) {
        let clean = text.trim().to_owned();
        let mut live = self.live();
        live.generation += 1;
        live.term.clone_from(&clean);
        let Some(backend) = Backend::of(&live) else {
            return;
        };
        if !search_term_fits(&clean) {
            self.set(&mut live, "", Vec::new(), SearchStatus::Idle, None);
            return;
        }
        // The old hits stay until the new ones arrive (no flash of an empty page).
        let query = live.results.query.clone();
        let groups = live.results.groups.clone();
        self.set(&mut live, &query, groups, SearchStatus::Searching, None);
        let (generation, switch) = (live.generation, live.switch);
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            if debounce {
                inner.sleeper.sleep(DEBOUNCE).await;
                if !inner.current(generation, switch) {
                    return;
                }
            }
            let found = inner.find(&backend, &clean).await;
            let mut live = inner.live();
            if live.generation != generation || live.switch != switch {
                return;
            }
            // One transition decides the outcome; the exported status derives from it.
            live.failure = found.as_ref().err().copied();
            let (load, groups) = match found {
                Err(LoadFailure::Failed(kind)) => {
                    (Load::Loading.reduce(LoadEvent::Failed(kind)), Vec::new())
                }
                Err(LoadFailure::Offline) => {
                    (Load::Loading.reduce(LoadEvent::WentOffline), Vec::new())
                }
                Ok(groups) => (
                    Load::Loading.reduce(LoadEvent::Answered {
                        items: groups.len(),
                    }),
                    groups,
                ),
            };
            inner.set(
                &mut live,
                &clean,
                groups,
                SearchStatus::from_load(load),
                None,
            );
        }));
    }

    fn current(&self, generation: u64, switch: u64) -> bool {
        let live = self.live();
        live.generation == generation && live.switch == switch
    }

    /// The search. `Err` (with the reason) if the movie and series search failed.
    async fn find(
        &self,
        backend: &Backend<T>,
        term: &str,
    ) -> Result<Vec<SearchGroup>, LoadFailure> {
        let works = match backend {
            Backend::Jellyfin(client) => {
                let main = client.search(term, MOVIE_SERIES_LIMIT).await;
                items_in_times(
                    &**client,
                    &main.map_err(|e| LoadFailure::from_error(&e))?,
                    false,
                    None,
                )
                .await
            }
            // Plex has no cinema times: the hits of the hub search are the works.
            Backend::Plex(plex) => plex
                .search(term, MOVIE_SERIES_LIMIT)
                .await
                .map_err(|e| LoadFailure::from_error(&e.into_kind()))?,
        };
        let works = match &self.collator {
            Some(c) => {
                NaturalOrder::sorted(works, c, |i| (i.name.as_str(), i.sort_name.as_deref()))
            }
            None => works,
        };
        let of = |kind: ItemKind| -> Vec<Item> {
            works.iter().filter(|i| i.kind() == kind).cloned().collect()
        };
        let grid = |items: &[Item]| -> Vec<Tile> {
            items
                .iter()
                .map(|i| match backend {
                    Backend::Jellyfin(client) => grid_tile(i, &**client, &self.words),
                    Backend::Plex(plex) => plex_grid_tile(i, &**plex, &self.words),
                })
                .collect()
        };
        let groups = [
            (SearchKind::Movies, grid(&of(ItemKind::Movie))),
            (SearchKind::Series, grid(&of(ItemKind::Series))),
        ];
        Ok(groups
            .into_iter()
            .filter(|(_, tiles)| !tiles.is_empty())
            .map(|(kind, tiles)| SearchGroup { kind, tiles })
            .collect())
    }

    fn set_plex(&self, plex: Option<Arc<PlexClient<Shared<T>>>>) {
        let mut live = self.live();
        live.switch += 1;
        live.generation += 1;
        live.term.clear();
        live.plex = plex;
        let ready = live.plex.is_some() || live.client.is_some();
        let status = if ready {
            SearchStatus::Idle
        } else {
            SearchStatus::SignedOut
        };
        let recents = (*live.recents).clone();
        self.set(&mut live, "", Vec::new(), status, Some(recents));
    }

    fn remember(&self) {
        let mut live = self.live();
        let key = history_key(live.account.as_ref());
        let raw = search_history::load(key.as_deref(), &*self.history);
        let new = search_history::remember(&live.term, &raw);
        if new != raw {
            search_history::save(&new, key.as_deref(), &*self.history);
        }
        let (query, groups, status) = (
            live.results.query.clone(),
            live.results.groups.clone(),
            live.status.status,
        );
        self.set(
            &mut live,
            &query,
            groups,
            status,
            Some(search_history::list(&new)),
        );
    }

    fn clear_recents(&self) {
        let mut live = self.live();
        search_history::save(
            "",
            history_key(live.account.as_ref()).as_deref(),
            &*self.history,
        );
        let (query, groups, status) = (
            live.results.query.clone(),
            live.results.groups.clone(),
            live.status.status,
        );
        self.set(&mut live, &query, groups, status, Some(Vec::new()));
    }

    fn switch_account(&self, account: Option<AccountRef>) {
        let mut live = self.live();
        live.switch += 1;
        live.generation += 1;
        live.term.clear();
        live.plex = None;
        live.client = account
            .as_ref()
            .and_then(|a| build_client(&self.transport, &self.host, a).ok())
            .map(Arc::new);
        live.account = account.filter(|_| live.client.is_some());
        let recents = search_history::list(&search_history::load(
            history_key(live.account.as_ref()).as_deref(),
            &*self.history,
        ));
        let status = if live.client.is_some() {
            SearchStatus::Idle
        } else {
            SearchStatus::SignedOut
        };
        self.set(&mut live, "", Vec::new(), status, Some(recents));
    }
}
