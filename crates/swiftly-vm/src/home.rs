//! `HomeVm`: the home page as a view model.
//!
//! The logic is `swiftly_library::HomeState` (what `HomePageModel.swift` decides) and
//! `HomeLoader` (what is fetched). This file is the driver the Swift code had in `load`: it
//! does the I/O the state machine asks for, in the order its module documentation gives, and
//! turns the state into versioned parts.
//!
//! * `send` never blocks. `Load`/`Refresh`/`AccountSwitched` start a run on the [`Spawner`];
//!   an older run is aborted, and the state machine's run token keeps an overtaken run from
//!   writing anything.
//! * The preview of the last session is read first, so there is something to draw before the
//!   server answers (`preview` in the status part).
//! * A run that is aborted ends through [`RunGuard`], so `needs_refresh` never stays stuck.

use std::collections::HashMap;
use std::pin::pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures_util::future::{AbortHandle, Abortable, maybe_done};
use swiftly_jellyfin::{ClientConfig, JellyfinClient, Session};
use swiftly_library::home::GenreRail;
use swiftly_library::home_state::{Fixed, HomeFinish, HomeRun, Step};
use swiftly_library::{HomeCommand, HomeLoader, HomeState, HomeStore, LoadRequest, StartRail};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpTransport};

use crate::account::AccountRef;
use crate::bell::{Bell, Changed, part};
use crate::host::{Host, Shared};
use crate::load_state::{Load, LoadFailure};
use crate::parts::{
    HomeIntent, ImageKind, ImageRef, Rail, RailKind, RailsPart, Status, StatusPart, Tile,
};
use crate::plex::{Plex, build_plex_client, is_plex};
use crate::tile::{Words, kind_of, tile_at};
use swiftly_images::{ImageAddress, ImageSelection};
use swiftly_library::home::HomePageSource;

pub use swiftly_library::home_state::HomePrefs;

/// How many tiles of a rail carry display data before the rail is reported visible. Covers the
/// first screen on a phone and on a TV.
pub const INITIAL_WINDOW: usize = 12;

pub(crate) type Client<T> = JellyfinClient<Shared<T>>;

/// Where the page comes from: the Jellyfin client or the Plex client (both are a
/// `HomePageSource`, as in Swift). The run is generic over the source.
pub(crate) enum Source<T: HttpTransport + 'static> {
    Jellyfin(Arc<Client<T>>),
    Plex(Arc<Plex<T>>),
}

impl<T: HttpTransport + 'static> Clone for Source<T> {
    fn clone(&self) -> Self {
        match self {
            Self::Jellyfin(c) => Self::Jellyfin(Arc::clone(c)),
            Self::Plex(c) => Self::Plex(Arc::clone(c)),
        }
    }
}

impl<T: HttpTransport + 'static> Source<T> {
    /// The image addresses of the server (`ImageAddress` knows the Plex path scheme).
    pub(crate) fn addresses(&self) -> Option<ImageAddress> {
        match self {
            Self::Jellyfin(c) => c.current_session().map(|s| {
                ImageAddress::new(c.base_url().clone(), Some(s.access_token), c.server_kind())
            }),
            Self::Plex(c) => Some(ImageAddress::new(
                c.base_url(),
                Some(c.access_token()),
                swiftly_jellyfin::ServerKind::Plex,
            )),
        }
    }
}

/// The source for `account`: Plex for a Plex account, else Jellyfin/Emby.
pub(crate) fn build_source<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
) -> Result<Source<T>, ErrorKind> {
    if is_plex(account) {
        build_plex_client(transport, host, account).map(|c| Source::Plex(Arc::new(c)))
    } else {
        build_client(transport, host, account).map(|c| Source::Jellyfin(Arc::new(c)))
    }
}

struct Live<T: HttpTransport + 'static> {
    switch: u64,
    account: Option<AccountRef>,
    client: Option<Source<T>>,
    state: HomeState,
    views: Vec<Item>,
    preview: bool,
    windows: HashMap<String, usize>,
    rails: Arc<RailsPart>,
    status: Arc<StatusPart>,
    abort: Option<AbortHandle>,
    /// The chosen libraries and collections (`startBibliotheken`), set by the host; empty: no library rows.
    libraries: Vec<swiftly_library::start_libraries::StartLibrary>,
    /// The combined order of fixed, library and collection rows (`startReihenfolge`), set by the host; empty: the old
    /// order (fixed rows, then libraries).
    row_order: Vec<String>,
}

struct Inner<T: HttpTransport + 'static> {
    transport: Arc<T>,
    host: Host,
    words: Words,
    prefs: HomePrefs,
    bell: Arc<Bell>,
    live: Mutex<Live<T>>,
}

/// The home page view model. Cheap to clone (a handle).
pub struct HomeVm<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: HttpTransport + 'static> HomeVm<T> {
    /// Sets the chosen libraries and collections (`startBibliotheken`, per server) before a load. Kept apart from
    /// [`HomePrefs`] so the host API does not change; empty (the default) means no library rows.
    pub fn set_start_libraries(&self, choice: Vec<swiftly_library::start_libraries::StartLibrary>) {
        self.inner.live().libraries = choice;
    }

    /// The details line of one title (year/runtime/genre, description, stars, age rating, time left, episode
    /// name) for the focused tile: one request for the full title. Additive; `Tile` is unchanged. `None` when no
    /// server is connected or the title cannot be read.
    pub async fn tile_details(&self, id: &str) -> Option<crate::tile_details::TileDetails> {
        let client = self.inner.live().client.clone()?;
        let item = match &client {
            Source::Jellyfin(c) => c.item(id).await.ok()?,
            Source::Plex(c) => swiftly_playback::media_server::MediaServer::item(&**c, id)
                .await
                .ok()?,
        };
        let text = crate::tile_details::text_for(self.inner.host.locale.clone());
        Some(crate::tile_details::details_of(&text, &item))
    }

    /// The details of many titles with ONE request (`Ids`), for a header that reads every row up front. Titles the
    /// server does not answer for are missing; empty when no server is connected or the request fails.
    pub async fn tile_details_many(&self, ids: &[String]) -> Vec<crate::tile_details::TileDetails> {
        if ids.is_empty() {
            return Vec::new();
        }
        let Some(client) = self.inner.live().client.clone() else {
            return Vec::new();
        };
        let query = swiftly_jellyfin::ItemsQuery {
            limit: i64::try_from(ids.len()).unwrap_or(100),
            ids: ids.to_vec(),
            ..swiftly_jellyfin::ItemsQuery::default()
        };
        let answer = match &client {
            Source::Jellyfin(c) => c.items(&query).await,
            Source::Plex(c) => {
                swiftly_playback::media_server::MediaServer::items(&**c, &query).await
            }
        };
        let Ok(answer) = answer else {
            return Vec::new();
        };
        let text = crate::tile_details::text_for(self.inner.host.locale.clone());
        answer
            .items
            .iter()
            .map(|i| crate::tile_details::details_of(&text, i))
            .collect()
    }

    /// Sets the stored combined row order (`startReihenfolge`: fixed raw values and `library:<id>`) before a load, or
    /// after the user moved a row; the rails part updates at once. Empty: the old order.
    pub fn set_row_order(&self, order: Vec<String>) {
        let mut live = self.inner.live();
        live.row_order = order;
        self.inner.publish(&mut live);
    }
}

impl<T: HttpTransport + 'static> Clone for HomeVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<T: HttpTransport + 'static> HomeVm<T> {
    /// A view model for `account` (or signed out). Nothing is loaded until [`HomeIntent::Load`].
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
    pub fn new(
        transport: Arc<T>,
        host: Host,
        prefs: HomePrefs,
        account: Option<AccountRef>,
    ) -> Result<Self, ErrorKind> {
        let client = account
            .as_ref()
            .map(|a| build_source(&transport, &host, a))
            .transpose()?;
        let bell = Bell::new();
        let words = Words::new(host.locale.clone());
        let live = Live {
            switch: 1,
            account,
            client,
            state: HomeState::new(),
            views: Vec::new(),
            preview: false,
            windows: HashMap::new(),
            rails: Arc::new(RailsPart {
                version: 1,
                rails: Vec::new(),
            }),
            status: Arc::new(StatusPart {
                version: 1,
                status: Status::Loading,
                preview: false,
                refreshing: false,
            }),
            abort: None,
            libraries: Vec::new(),
            row_order: Vec::new(),
        };
        let inner = Arc::new(Inner {
            transport,
            host,
            words,
            prefs,
            bell,
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

    /// A `LibraryChanged`/`UserDataChanged` event (or the polling fallback) for the account on
    /// screen reloads the page: the rails show the preview or the standing page meanwhile.
    fn watch_cache(&self) {
        let Some(cache) = self.inner.host.cache.clone() else {
            return;
        };
        let weak = Arc::downgrade(&self.inner);
        // A burst of events (marking a season watched) reloads once, not once per message.
        let last = Mutex::new(f64::NEG_INFINITY);
        cache.watch(move |change| {
            let Some(inner) = weak.upgrade() else {
                return false;
            };
            if let swiftly_cache::CacheChange::ListsStale(scope) = change {
                let own = inner.live().account.as_ref().map(|a| a.key());
                let now = inner.host.clock.now();
                let mut last = last.lock().unwrap_or_else(PoisonError::into_inner);
                if own.as_deref() == Some(scope.0.as_str()) && now - *last >= 3.0 {
                    *last = now;
                    drop(last);
                    HomeVm { inner }.send(HomeIntent::Load);
                }
            }
            true
        });
    }

    /// The version of the view model; moves whenever a part is replaced.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The page's shared load state (the finer form of `status().status`).
    pub fn load(&self) -> Load {
        let live = self.inner.live();
        self.inner.load_of(&live)
    }

    /// The status part.
    pub fn status(&self) -> Arc<StatusPart> {
        Arc::clone(&self.inner.live().status)
    }

    /// The rails part.
    pub fn rails(&self) -> Arc<RailsPart> {
        Arc::clone(&self.inner.live().rails)
    }

    /// Display data for `count` titles of a rail from `start` on (beyond the window).
    pub fn tiles(&self, rail: &str, start: usize, count: usize) -> Vec<Tile> {
        let live = self.inner.live();
        let Some(client) = live.client.as_ref() else {
            return Vec::new();
        };
        let Some((kind, items)) = rail_items(&live, &self.inner.prefs, rail) else {
            return Vec::new();
        };
        items
            .iter()
            .skip(start)
            .take(count)
            .map(|i| tile_at(i, kind, client.addresses(), &self.inner.words))
            .collect()
    }

    /// The wide picture of a title on the page for the head that follows the focus (the TV's
    /// home page): the landscape chain at `width`, else the page-head chain at 1200 (the same two
    /// steps as the Swift `landscapeImageURL(width:) ?? headerImageURL`). `None` when the title
    /// is not on the page or the server has no wide picture for it; the host then searches on.
    pub fn hero_image(&self, id: &str, width: u32) -> Option<ImageRef> {
        let live = self.inner.live();
        let client = live.client.as_ref()?;
        let addresses = client.addresses()?;
        let item = all_rails(&live, &self.inner.prefs)
            .into_iter()
            .flat_map(|rail| rail.4.iter())
            .find(|item| item.id == id)?;
        let url = ImageSelection::landscape(item, &addresses, i64::from(width))
            .map(|hit| hit.url)
            .or_else(|| ImageSelection::header(item, &addresses, 1200))?;
        Some(ImageRef {
            address: url.into(),
            kind: ImageKind::Backdrop,
            wanted_width: width,
            wanted_height: width * 9 / 16,
        })
    }

    /// Waits until the view model is newer than `seen` (at once if it already is). The answer
    /// names the parts that changed after `seen`.
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`HomeVm::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// An intent from the view. Never blocks.
    pub fn send(&self, intent: HomeIntent) {
        let inner = &self.inner;
        match intent {
            HomeIntent::Load => Inner::start(inner, true),
            HomeIntent::Refresh => Inner::start(inner, false),
            HomeIntent::AccountSwitched { account } => Inner::switch_account(inner, account),
            HomeIntent::Visible { rail } => inner.visible(&rail),
        }
    }
}

/// The rail ids and items as the current state has them (the same rule as [`Inner::publish`]).
fn rail_items<'a, T: HttpTransport + 'static>(
    live: &'a Live<T>,
    prefs: &HomePrefs,
    id: &str,
) -> Option<(RailKind, &'a [Item])> {
    all_rails(live, prefs)
        .into_iter()
        .find(|r| r.0 == id)
        .map(|r| (r.3, r.4))
}

type RailSource<'a> = (String, &'static str, String, RailKind, &'a [Item]);

/// Every non-empty rail: id, title key, title text (server names only), kind, items.
fn all_rails<'a, T: HttpTransport + 'static>(
    live: &'a Live<T>,
    prefs: &HomePrefs,
) -> Vec<RailSource<'a>> {
    if live.client.is_none() {
        return Vec::new();
    }
    let s = &live.state;
    let mut rails: Vec<RailSource<'a>> = Vec::new();
    for rail in StartRail::ALL
        .into_iter()
        .filter(|r| r.fits(prefs.disconnected))
    {
        let items: &[Item] = match rail {
            StartRail::ContinueWatching => &s.continue_watching,
            StartRail::NextEpisode => &s.next_episode,
            StartRail::NewMovies => &s.new_movies,
            StartRail::NewSeries => &s.new_series,
            StartRail::NewArrivals => &s.recent,
        };
        if !items.is_empty() {
            rails.push((
                rail.raw_value().to_owned(),
                rail.rails_title(),
                String::new(),
                kind_of(rail),
                items,
            ));
        }
    }
    // The chosen libraries and collections, in the chosen order, before the genre rows. They reuse the genre kind so
    // the host API does not change; the id starts with `library:` (`Rail::is_library`).
    for lib in s.library_rails_for(&live.libraries) {
        if !lib.items.is_empty() {
            rails.push((
                format!("library:{}", lib.id),
                "",
                lib.name.clone(),
                RailKind::Genre,
                &lib.items,
            ));
        }
    }
    if !live.row_order.is_empty() {
        // Fixed and library rows in the one stored order; genre rows (added below) stay last.
        let order = swiftly_library::StartOrder::applicable(
            &live.row_order,
            prefs.disconnected,
            &live.libraries,
        );
        rails.sort_by_key(|r| swiftly_library::StartOrder::rank(&order, &r.0));
    }
    if !prefs.genre_chips {
        for genre in s.genre_rails.iter().filter(|g| !g.items.is_empty()) {
            rails.push((
                format!("genre:{}", genre.name),
                "",
                genre.name.clone(),
                RailKind::Genre,
                &genre.items,
            ));
        }
    }
    rails
}

impl<T: HttpTransport + 'static> Inner<T> {
    fn live(&self) -> MutexGuard<'_, Live<T>> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Recomputes both parts; replaces the ones whose content changed and rings the bell once.
    fn publish(&self, live: &mut Live<T>) {
        let mut rails = Vec::new();
        if let Some(client) = live.client.as_ref() {
            for (id, key, name, kind, items) in all_rails(live, &self.prefs) {
                let window = live.windows.get(&id).copied().unwrap_or(INITIAL_WINDOW);
                rails.push(Rail {
                    title: if key.is_empty() {
                        name
                    } else {
                        self.words.title(key)
                    },
                    title_key: key.to_owned(),
                    count: u32::try_from(items.len()).unwrap_or(u32::MAX),
                    ids: items.iter().map(|i| i.id.clone()).collect(),
                    tiles: items
                        .iter()
                        .take(window)
                        .map(|i| tile_at(i, kind, client.addresses(), &self.words))
                        .collect(),
                    kind,
                    id,
                });
            }
        }
        let status = self.status_of(live);
        let refreshing = live.state.loaded && !live.preview && self.running(live);
        let mut changed = Vec::new();
        if rails != live.rails.rails {
            changed.push(0);
        }
        if (status, live.preview, refreshing)
            != (
                live.status.status,
                live.status.preview,
                live.status.refreshing,
            )
        {
            changed.push(1);
        }
        if changed.is_empty() {
            return;
        }
        let version = self.bell.bump(&changed);
        if changed.contains(&0) {
            live.rails = Arc::new(RailsPart { version, rails });
        }
        if changed.contains(&1) {
            live.status = Arc::new(StatusPart {
                version,
                status,
                preview: live.preview,
                refreshing,
            });
        }
        const { assert!(part::RAILS == 1 << 0 && part::STATUS == 1 << 1) };
    }

    /// A run is in flight (`runningRuns > 0`).
    fn running(&self, live: &Live<T>) -> bool {
        !live.state.needs_refresh(f64::MAX)
    }

    /// The shared load state of the page (`Idle` while signed out).
    fn load_of(&self, live: &Live<T>) -> Load {
        if live.client.is_none() {
            return Load::Idle;
        }
        let s = &live.state;
        Load::from_facts(
            self.running(live),
            s.loaded && !s.disrupted && (!self.running(live) || !live.preview),
            s.disrupted.then(|| {
                s.failure
                    .map_or(LoadFailure::Offline, LoadFailure::from_topic)
            }),
        )
    }

    fn status_of(&self, live: &Live<T>) -> Status {
        if live.client.is_none() {
            return Status::SignedOut;
        }
        match self.load_of(live) {
            Load::Offline | Load::Failed(_) => Status::Offline,
            Load::Loaded | Load::Refreshing => Status::Ready,
            Load::Idle | Load::Loading | Load::Empty => Status::Loading,
        }
    }

    fn visible(&self, rail: &str) {
        let mut live = self.live();
        let count = all_rails(&live, &self.prefs)
            .into_iter()
            .find(|r| r.0 == rail)
            .map(|r| r.4.len());
        if let Some(count) = count {
            let window = live.windows.get(rail).copied().unwrap_or(INITIAL_WINDOW);
            if count > window {
                live.windows.insert(rail.to_owned(), count);
                self.publish(&mut live);
            }
        }
    }

    /// `Load` forces a run, `Refresh` only starts one when the rows are 30 s old (`needsRefresh`).
    fn start(self: &Arc<Self>, force: bool) {
        let mut live = self.live();
        if live.client.is_none() {
            self.publish(&mut live);
            return;
        }
        if !force && !live.state.needs_refresh(self.host.clock.now()) {
            return;
        }
        self.begin_run(&mut live);
    }

    fn switch_account(self: &Arc<Self>, account: Option<AccountRef>) {
        let mut live = self.live();
        live.switch += 1;
        if let Some(handle) = live.abort.take() {
            handle.abort();
        }
        live.views.clear();
        live.preview = false;
        live.windows.clear();
        let client = account
            .as_ref()
            .and_then(|a| build_source(&self.transport, &self.host, a).ok());
        live.account = account.filter(|_| client.is_some());
        live.client = client;
        if live.client.is_some() {
            self.begin_run(&mut live);
        } else {
            self.publish(&mut live);
        }
    }

    /// Starts a run; the page is wiped synchronously if the account changed (`begin`).
    fn begin_run(self: &Arc<Self>, live: &mut Live<T>) {
        let (Some(account), Some(client)) = (live.account.clone(), live.client.clone()) else {
            return;
        };
        if let Some(old) = live.abort.take() {
            old.abort();
        }
        let key = account.key();
        let switch = live.switch;
        let (run, commands) = live.state.begin(switch, Some(&key));
        let guard = RunGuard {
            inner: Arc::clone(self),
            run,
            armed: true,
        };
        let (handle, registration) = AbortHandle::new_pair();
        live.abort = Some(handle);
        self.publish(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let mut guard = guard;
            let ctx = RunCtx {
                inner,
                run,
                switch,
                client,
                key,
            };
            if Abortable::new(ctx.drive(commands), registration)
                .await
                .is_ok()
            {
                guard.armed = false;
            }
        }));
    }
}

pub(crate) fn build_client<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
) -> Result<Client<T>, ErrorKind> {
    let config = ClientConfig::new(&account.device_id, &host.device_name, &host.client_version)
        .lean_tiles(true)
        .kind(account.server_kind);
    let client = JellyfinClient::new(Shared(Arc::clone(transport)), &account.base_url, config)?;
    client.set_session(Some(Session {
        access_token: account.token.clone(),
        user_id: account.user_id.clone(),
        user_name: String::new(),
        server_url: account.base_url.clone(),
        kind: account.server_kind,
    }));
    Ok(client)
}

/// Ends a run that was dropped before it finished (aborted by a newer run, an account switch or
/// the host), so `running_runs` goes back down. A wrong account makes the state machine stop
/// the run, which is the one thing it does on `end`.
struct RunGuard<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
    run: HomeRun,
    armed: bool,
}

impl<T: HttpTransport + 'static> Drop for RunGuard<T> {
    fn drop(&mut self) {
        if self.armed {
            let mut live = self.inner.live();
            let _ = live.state.views_ready(self.run, u64::MAX, true, true);
            self.inner.publish(&mut live);
        }
    }
}

struct RunCtx<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
    run: HomeRun,
    switch: u64,
    client: Source<T>,
    key: String,
}

impl<T: HttpTransport + 'static> RunCtx<T> {
    /// One load run, step by step as the module documentation of `HomeState` lists them.
    async fn drive(self, commands: Vec<HomeCommand>) {
        match self.client.clone() {
            Source::Jellyfin(c) => self.drive_with(&*c, commands).await,
            Source::Plex(c) => self.drive_with(&*c, commands).await,
        }
    }

    /// The run against any page source.
    async fn drive_with(&self, client: &impl HomePageSource, commands: Vec<HomeCommand>) {
        let (inner, run) = (&self.inner, self.run);
        let prefs = &inner.prefs;

        // 1. The preview of the last session, only while nothing is shown.
        if commands
            .iter()
            .any(|c| matches!(c, HomeCommand::ReadStore { .. }))
        {
            let stored = HomeStore::load(&*inner.host.preview_store(&self.key), &self.key);
            let mut live = inner.live();
            let switch = live.switch;
            match live.state.store_read(run, switch, stored.as_ref(), prefs) {
                Step::Stop => return inner.publish(&mut live),
                Step::Continue(commands) => {
                    for command in commands {
                        if let HomeCommand::AdoptLibraries(views) = command {
                            live.views = views;
                            live.preview = true;
                        }
                    }
                }
            }
            inner.publish(&mut live);
        }

        // 2. The libraries: wait for them when none are known, else fetch alongside.
        let views_command = {
            let live = inner.live();
            live.state.views_command(live.views.is_empty())
        };
        match views_command {
            Some(HomeCommand::LoadViews { wait: true }) => self.load_views(client).await,
            Some(HomeCommand::LoadViews { wait: false }) => {
                let again = RunCtx {
                    inner: Arc::clone(&self.inner),
                    run,
                    switch: self.switch,
                    client: self.client.clone(),
                    key: String::new(),
                };
                inner.host.spawner.spawn(Box::pin(async move {
                    match again.client.clone() {
                        Source::Jellyfin(c) => again.load_views(&*c).await,
                        Source::Plex(c) => again.load_views(&*c).await,
                    }
                }));
            }
            _ => {}
        }
        {
            let mut live = inner.live();
            let switch = live.switch;
            if live.state.views_ready(run, switch, true, false) == Step::Stop {
                return inner.publish(&mut live);
            }
        }

        // 3. Fixed rows, with the genre rows fetched alongside (`async let genres`).
        let (wish, names) = {
            let live = inner.live();
            let mut wish = LoadRequest::new(prefs.disconnected);
            wish.until_from_continue_watching = live.state.continue_watching.clone();
            (wish, prefs.start_genres.clone())
        };
        let choice = inner.live().libraries.clone();
        let mut library_rows = pin!(maybe_done(async {
            if choice.is_empty() {
                Vec::new()
            } else {
                HomeLoader::library_rails(client, &choice).await
            }
        }));
        let chips = prefs.genre_chips;
        let mut genres = pin!(maybe_done(async {
            if chips || names.is_empty() {
                Vec::<GenreRail>::new()
            } else {
                HomeLoader::genre_rails(client, &names).await
            }
        }));
        let mut load = pin!(HomeLoader::load(client, &wish));
        let home = std::future::poll_fn(|cx| {
            let _ = genres.as_mut().poll(cx);
            let _ = library_rows.as_mut().poll(cx);
            load.as_mut().poll(cx)
        })
        .await;
        let fixed = {
            let mut live = inner.live();
            let (switch, now) = (live.switch, inner.host.clock.now());
            let fixed =
                live.state
                    .fixed_rows_arrived(run, switch, false, prefs.disconnected, home, now);
            match fixed {
                Fixed::Stop | Fixed::AwaitLater => inner.publish(&mut live),
                Fixed::AwaitFirst => {}
            }
            fixed
        };
        if fixed == Fixed::Stop {
            return;
        }
        genres.as_mut().await;
        let fresh = genres.as_mut().take_output().unwrap_or_default();
        library_rows.as_mut().await;
        let choice_empty = inner.live().libraries.is_empty();
        let fresh_libraries = library_rows.as_mut().take_output().unwrap_or_default();

        // 4. The end of the run: first appearance in one go, or the standing page's tail.
        let mut guard = inner.live();
        let live = &mut *guard;
        let switch = live.switch;
        let finish = HomeFinish {
            account_key: Some(&self.key),
            views: &live.views,
        };
        let step = if fixed == Fixed::AwaitFirst {
            let now = inner.host.clock.now();
            live.state.first_extras_ready(
                run,
                switch,
                false,
                prefs.disconnected,
                fresh,
                fresh_libraries,
                now,
                &finish,
            )
        } else if live.state.genres_ready(run, switch, fresh, chips) == Step::Stop {
            Step::Stop
        } else {
            live.state
                .libraries_ready(run, switch, fresh_libraries, choice_empty, &finish)
        };
        let mut writes = Vec::new();
        if let Step::Continue(commands) = step {
            for command in commands {
                if let HomeCommand::WriteStore { account, store } = command {
                    writes.push((account, store));
                }
            }
            if !live.state.disrupted {
                live.preview = false;
            }
        }
        inner.publish(live);
        drop(guard);
        // The snapshot goes to the host's store (foreign code) after the lock is released.
        for (account, store) in writes {
            store.save(&*inner.host.preview_store(&account), &account);
        }
    }

    /// `model.loadViews()`: the account's libraries, kept for the snapshot.
    async fn load_views(&self, source: &impl HomePageSource) {
        let fetched = source.libraries().await;
        let mut live = self.inner.live();
        if live.switch == self.switch
            && let Some(views) = fetched
        {
            live.views = views;
        }
    }
}

/// A signed-in client for an account over a shared transport, for screens that load their own
/// lists (person page, playlists).
pub fn account_client<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
) -> Result<JellyfinClient<Shared<T>>, ErrorKind> {
    build_client(transport, host, account)
}
