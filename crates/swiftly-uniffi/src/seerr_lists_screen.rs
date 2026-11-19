//! The Seerr hub and the list screens (discover, search merge, my requests, home block) over one
//! connection. The state machines are `swiftly_vm::seerr_lists`; this file runs the calls and feeds
//! the answers in. Without a connection (or a valid session) every info is empty and `show` /
//! `available` are false: the host draws nothing.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_l10n::Locale;
use swiftly_seerr::types::{RequestRow, TitleCard};
use swiftly_seerr::{AskError, SeerrClient};
use swiftly_vm::{
    RailId, RequestPill, SeerrDiscoverRails, SeerrDiscoverVm, SeerrHomeInfo, SeerrHomeVm,
    SeerrHubInfo, SeerrHubVm, SeerrRequestsInfo, SeerrSearchInfo, SeerrSearchVm, SeerrTileCard,
    TitleCache, tile_of, today_utc,
};

use crate::error::CoreError;
use crate::seerr::{JarAdapter, SeerrModel};
use crate::transport::CoreTransport;

pub(crate) type Client = SeerrClient<CoreTransport, JarAdapter>;

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What the host's Jellyfin side offers the Seerr screens. Implemented in the app over the Jellyfin
/// client it already holds.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait SeerrLibrary: Send + Sync {
    /// The library item id of a title (`movie` / `tv`) by its TMDB id; `None` when the server has none.
    async fn find(&self, art: String, tmdb: i64) -> Result<Option<String>, LibraryFailure>;
    /// Asks Jellyfin to scan its libraries again; fails when it does not answer or refuses.
    async fn refresh(&self) -> Result<(), LibraryFailure>;
}

/// Why the library side did not answer.
#[derive(Debug, uniffi::Error)]
pub enum LibraryFailure {
    /// The call was cancelled.
    Cancelled,
    /// Anything else.
    Other {
        /// Developer-readable description.
        message: String,
    },
}

impl std::fmt::Display for LibraryFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for LibraryFailure {}

/// What a Seerr entry of the More menu does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SeerrMenuKind {
    /// Opens the report sheet ("Problem melden").
    ReportProblem,
    /// Opens the delete flow ("Vom Server löschen").
    DeleteFromServer,
}

/// One Seerr entry of a title's More menu.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeerrMenuEntry {
    /// What it does.
    pub kind: SeerrMenuKind,
    /// The label in the user's language.
    pub text: String,
}

/// The core's hub over this crate's transport and cookie jar.
pub(crate) type CoreHub = swiftly_vm::SeerrHub<CoreTransport, JarAdapter>;

/// The connection of the Seerr screens: who the account is and what it may do, the counts, the
/// titles read so far. One per signed-in connection; the screens share it. The calls and the state
/// are `swiftly_vm::SeerrHub`, the same code the desktop runs; this object exports it and adds the
/// host's library handle.
#[derive(uniffi::Object)]
pub struct SeerrHub {
    pub(crate) library: Option<Arc<dyn SeerrLibrary>>,
    pub(crate) core: Arc<CoreHub>,
}

impl SeerrHub {
    pub(crate) fn client(&self) -> Option<&Client> {
        self.core.client()
    }

    pub(crate) fn locale_of(&self) -> Locale {
        self.core.locale_of()
    }

    pub(crate) fn vm(&self) -> &Mutex<SeerrHubVm> {
        self.core.vm()
    }

    pub(crate) fn titles(&self) -> &Mutex<TitleCache> {
        self.core.titles()
    }

    /// The hub is ready (reads it once when it has not been).
    pub(crate) async fn ensure(&self) -> bool {
        self.core.ensure().await
    }

    pub(crate) async fn resolve_requests(&self, rows: &[RequestRow]) {
        self.core.resolve_requests(rows).await;
    }
}

#[uniffi::export]
impl SeerrHub {
    /// The hub of a connection; `None` = this account has no Seerr (everything stays empty).
    #[uniffi::constructor]
    pub fn new(
        model: Option<Arc<SeerrModel>>,
        locale: String,
        library: Option<Arc<dyn SeerrLibrary>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            library,
            core: CoreHub::shared(model.map(|m| m.shared_client()), locale),
        })
    }

    /// **Call once when the media server's Home has loaded** (low priority, in the background): reads what the Seerr
    /// screens show first (the account and its rights, the Start block, "Meine Anfragen", for an administrator the queue
    /// and the problems, the discover rails) into the stash, so the first visit of any of them paints at once. One at a
    /// time: a call while one runs returns `false` at once; `false` also without Seerr or a session.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn warm_up(&self) -> Result<bool, CoreError> {
        Ok(self.core.warm_up().await)
    }

    /// The state now.
    pub fn info(&self) -> SeerrHubInfo {
        self.core.info()
    }

    /// True when Seerr is connected with a valid session: the one check before drawing anything.
    pub fn available(&self) -> bool {
        self.core.available()
    }

    /// **The one Profile entry** (`swiftly_vm::profile_entry`): "Verwaltung" with its sections for an administrator,
    /// "Meine Anfragen" for everyone else with Seerr, `None` for no row. `is_administrator` is the account's
    /// `Policy.IsAdministrator` (`AccountDefaultsInfo`).
    pub fn profile_entry(
        &self,
        server_kind: swiftly_jellyfin::ServerKind,
        is_administrator: bool,
    ) -> Option<swiftly_vm::ProfileEntry> {
        swiftly_vm::profile_entry(
            &self.locale_of(),
            server_kind,
            is_administrator,
            Some(&self.core.info()),
        )
    }

    /// **The action words of the management hub** (Freigeben, Ablehnen, Antworten, empty states ...) in the account's
    /// language: every host reads them here instead of keeping its own list.
    pub fn admin_words(&self) -> swiftly_vm::AdminWords {
        swiftly_vm::AdminWords::new(&self.locale_of())
    }

    /// What Seerr adds to the More menu of a title that the own server has: "Problem melden" for an
    /// account that may report, "Vom Server löschen" for one that manages requests (unless this device
    /// locked the delete). Empty without a working connection. Every platform asks here, so the rule and
    /// the words live once.
    pub fn title_menu(&self) -> Vec<SeerrMenuEntry> {
        if !self.available() {
            return Vec::new();
        }
        let perms = lock(self.vm()).perms();
        let t = swiftly_l10n::Translator::new(self.locale_of());
        let mut out = Vec::new();
        if perms.can_create_issues() {
            out.push(SeerrMenuEntry {
                kind: SeerrMenuKind::ReportProblem,
                text: t.t("Problem melden"),
            });
        }
        if swiftly_vm::delete_offered(perms.can_manage_requests()) {
            out.push(SeerrMenuEntry {
                kind: SeerrMenuKind::DeleteFromServer,
                text: t.t("Vom Server löschen"),
            });
        }
        out
    }

    /// Reads who the account is, what it may do, its quota and the counts.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn refresh(&self) -> Result<SeerrHubInfo, CoreError> {
        Ok(self.core.refresh().await)
    }

    /// The account is read (once, even when several screens ask at the same time) and the hub is usable. Does not read the
    /// counts: the screens that show them read them next to their own lists.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn ensure_available(&self) -> Result<bool, CoreError> {
        Ok(self.core.ensure().await)
    }

    /// Reads only the counts (profile rows, home line); cheap enough for every Home appearance.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn refresh_counts(&self) -> Result<SeerrHubInfo, CoreError> {
        Ok(self.core.refresh_counts().await)
    }

    /// The quota line for a request sheet of `art` ("Noch 1 von 3 Staffeln frei diese Woche") and
    /// whether it is the warning; `None` without a limit.
    pub fn quota_line(&self, art: String) -> Option<String> {
        self.core.quota_line(art)
    }
}

/// The lists of Seerr over one hub.
#[derive(uniffi::Object)]
pub struct SeerrListsScreen {
    hub: Arc<SeerrHub>,
    discover: Mutex<SeerrDiscoverVm>,
    search: Mutex<SeerrSearchVm>,
    my: swiftly_vm::MyRequests<CoreTransport, JarAdapter>,
    home: Mutex<SeerrHomeVm>,
    /// Signals the first answer of the home block to a waiting [`Self::gate_home`].
    home_answered: tokio::sync::Notify,
}

impl SeerrListsScreen {
    /// The first read of the home block is over: the block is `Shown` or `Hidden` from now on, and the page that waits
    /// for it (first start of a profile) is released.
    fn home_is_answered(&self) {
        lock(&self.home).answered();
        self.home_answered.notify_one();
    }

    /// A screen over a hub that has read nothing, on the same client: what runs inside `swiftly_seerr::replaying`.
    fn stale_twin(&self) -> Arc<Self> {
        Self::new(Arc::new(SeerrHub {
            library: self.hub.library.clone(),
            core: self.hub.core.stale_twin(),
        }))
    }

    /// The account's own requests as the home block reads them.
    async fn mine(&self, take: u32) -> Result<Vec<RequestRow>, AskError> {
        self.my.rows(take).await
    }

    async fn tiles_of(&self, cards: Result<Vec<TitleCard>, AskError>) -> Vec<SeerrTileCard> {
        let t = swiftly_l10n::Translator::new(self.hub.locale_of());
        let today = today_utc();
        cards
            .unwrap_or_default()
            .iter()
            .map(|c| tile_of(&t, c, &today))
            .filter(|tile| !tile.on_server)
            .collect()
    }
}

/// The home block of the very first frame, before any call: Seerr is connected, nothing came back, so the host reserves
/// the shape stored under `seerr_home_memory_key` ("" when there is none). `Hidden` hosts draw nothing.
#[uniffi::export]
pub fn seerr_home_pending(memory: String) -> SeerrHomeInfo {
    SeerrHomeInfo::pending(&memory)
}

/// The key a host stores the home block's last shape under, per profile (`account`: the account key).
#[uniffi::export]
pub fn seerr_home_memory_key(account: Option<String>) -> String {
    swiftly_vm::seerr_home_memory_key(account.as_deref())
}

#[uniffi::export]
impl SeerrListsScreen {
    /// The list screens over a hub.
    #[uniffi::constructor]
    pub fn new(hub: Arc<SeerrHub>) -> Arc<Self> {
        let locale = hub.locale_of();
        let today = today_utc();
        Arc::new(Self {
            discover: Mutex::new(SeerrDiscoverVm::new(locale.clone(), &today)),
            search: Mutex::new(SeerrSearchVm::new(locale.clone(), &today)),
            my: swiftly_vm::MyRequests::new(Arc::clone(&hub.core)),
            home: Mutex::new(SeerrHomeVm::new(locale, &today)),
            home_answered: tokio::sync::Notify::new(),
            hub,
        })
    }

    // ---- discover

    /// The discover rails now (empty until `load_discover` ran).
    pub fn discover(&self) -> SeerrDiscoverRails {
        lock(&self.discover).info()
    }

    /// Reads the rails of the empty Search page.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_discover(&self) -> Result<SeerrDiscoverRails, CoreError> {
        let _timer = self.hub.core.timer("discover", "live ready");
        if !self.hub.ensure().await {
            return Ok(self.discover());
        }
        let Some(c) = self.hub.client() else {
            return Ok(self.discover());
        };
        let order = RailId::order(&c.discover_sliders().await.unwrap_or_default());
        let hide = lock(self.hub.vm()).public().hide_available;
        lock(&self.discover).begin(order.clone(), hide);
        let reads = order.iter().map(|id| async move {
            let page = match id {
                RailId::Trending => c.trending(1).await,
                RailId::PopularMovies => c.popular_movies(1).await,
                RailId::PopularTv => c.popular_tv(1).await,
                RailId::UpcomingMovies => c.upcoming_movies(1).await,
                RailId::UpcomingTv => c.upcoming_tv(1).await,
                RailId::Recent => Err(AskError::NotFound),
            };
            (*id, page)
        });
        for (id, page) in futures_util::future::join_all(reads).await {
            let page = if id == RailId::Recent {
                self.recent_rail(c).await
            } else {
                page
            };
            lock(&self.discover).rail_loaded(id, page);
        }
        Ok(self.discover())
    }

    // ---- search merge

    /// The search block now.
    pub fn search_info(&self) -> SeerrSearchInfo {
        lock(&self.search).info()
    }

    /// Searches Seerr for `term`; an empty term resets. Returns when the answer is in.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn search(&self, term: String) -> Result<SeerrSearchInfo, CoreError> {
        lock(&self.search).begin(&term);
        if term.trim().is_empty() || !self.hub.ensure().await {
            return Ok(self.search_info());
        }
        let Some(c) = self.hub.client() else {
            return Ok(self.search_info());
        };
        let page = c.search(term.trim(), 1).await;
        lock(&self.search).loaded(&term, page);
        Ok(self.search_info())
    }

    // ---- my requests (the logic is `swiftly_vm::MyRequests`, shared with the desktop)

    /// "Meine Anfragen" now.
    pub fn requests(&self) -> SeerrRequestsInfo {
        self.my.info()
    }

    /// Reads the account's requests.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_requests(&self) -> Result<SeerrRequestsInfo, CoreError> {
        Ok(self.my.load().await)
    }

    /// "Meine Anfragen" as the last visit left them, from the stash and without a call to Seerr (`None`: nothing
    /// complete is stored, or the list was read already). The page paints it at once and then calls `load_requests`,
    /// which replaces it; `select_pill` works on the stored rows meanwhile.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn restore_requests(&self) -> Result<Option<SeerrRequestsInfo>, CoreError> {
        Ok(self.my.restore().await.then(|| self.my.info()))
    }

    /// Picks a filter pill.
    pub fn select_pill(&self, pill: RequestPill) -> SeerrRequestsInfo {
        self.my.select_pill(pill)
    }

    /// "Zurückziehen" on an own waiting request; the row goes at once and comes back with its
    /// error text when the server refuses.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn withdraw(&self, id: i64) -> Result<SeerrRequestsInfo, CoreError> {
        Ok(self.my.withdraw(id).await)
    }

    // ---- home block

    /// The home block now (`show` false = draw nothing).
    pub fn home(&self) -> SeerrHomeInfo {
        let cache = lock(self.hub.titles()).clone();
        lock(&self.home).info(&cache)
    }

    /// Reads what the home block needs. `dismissed` are the request ids the host stored,
    /// `arrival_on` is the setting `seerrArrivalHint`, `requests_on` the setting `seerrRequestsRail`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_home(
        &self,
        dismissed: Vec<i64>,
        arrival_on: bool,
        requests_on: bool,
    ) -> Result<SeerrHomeInfo, CoreError> {
        let _timer = self.hub.core.timer("home", "live ready");
        let ok = self.hub.ensure().await;
        {
            let mut h = lock(&self.home);
            h.set_dismissed(&dismissed);
            h.set_arrival_enabled(arrival_on);
            h.set_requests_enabled(requests_on);
            h.set_available(ok);
        }
        if !ok {
            self.home_is_answered();
            return Ok(self.home());
        }
        // The counts and the account's requests are read side by side, not one after the other.
        let (_, mine) = futures_util::future::join(
            self.hub.core.read_counts(),
            self.mine(swiftly_vm::HOME_REQUESTS_TAKE),
        )
        .await;
        let info = self.hub.info();
        lock(&self.home).set_attention(
            info.admin_line
                .map(|l| (l, info.counts.pending + info.counts.issues_open)),
        );
        if let Ok(rows) = mine {
            self.hub.resolve_requests(&rows).await;
            lock(&self.home).requests_loaded(rows);
        }
        let candidates = lock(&self.home).arrival_candidates();
        let mut found = Vec::new();
        if let Some(library) = &self.hub.library {
            for cand in candidates {
                if let Some(id) = library
                    .find(cand.art.clone(), cand.tmdb)
                    .await
                    .ok()
                    .flatten()
                {
                    found.push((cand.request_id, id));
                }
            }
        }
        lock(&self.home).arrivals_found(found);
        self.home_is_answered();
        Ok(self.home())
    }

    /// The home block as the last visit left it, from the stash and without a call (`None`: nothing stored, or not
    /// complete). The Start page paints it at once and then calls `load_home`, which replaces it.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn restore_home(
        &self,
        dismissed: Vec<i64>,
        arrival_on: bool,
        requests_on: bool,
    ) -> Result<Option<SeerrHomeInfo>, CoreError> {
        let began = std::time::Instant::now();
        let mut waited = false;
        loop {
            let twin = self.stale_twin();
            let shown = swiftly_seerr::replaying(twin.load_home(
                dismissed.clone(),
                arrival_on,
                requests_on,
            ))
            .await;
            if let Some(info) = shown.and_then(Result::ok).filter(|info| info.show) {
                self.hub.core.took("home", "first paint from stash", began);
                return Ok(Some(info));
            }
            if waited || !self.hub.core.after_warm_up().await {
                self.hub.core.took("home", "stash miss", began);
                return Ok(None);
            }
            waited = true;
        }
    }

    /// The discover rails as the last visit left them (see `restore_home`).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn restore_discover(&self) -> Result<Option<SeerrDiscoverRails>, CoreError> {
        let began = std::time::Instant::now();
        let mut waited = false;
        loop {
            let twin = self.stale_twin();
            let rails = swiftly_seerr::replaying(twin.load_discover()).await;
            if let Some(rails) = rails
                .and_then(Result::ok)
                .filter(|r| r.load == swiftly_vm::ListLoad::Content)
            {
                self.hub
                    .core
                    .took("discover", "first paint from stash", began);
                return Ok(Some(rails));
            }
            if waited || !self.hub.core.after_warm_up().await {
                self.hub.core.took("discover", "stash miss", began);
                return Ok(None);
            }
            waited = true;
        }
    }

    /// Seerr is connected and the home block is about to be read: the block reserves the shape of the last start
    /// (`memory`: the code stored under `seerr_home_memory_key`, "" when there is none) until the first answer.
    pub fn begin_home(&self, memory: String) -> SeerrHomeInfo {
        lock(&self.home).begin(&memory);
        self.home()
    }

    /// The Start page's gate for the block: returns at once unless this profile remembers nothing (`holds_page`), then when
    /// Seerr has answered or after `HOME_BUDGET_SECONDS`, whichever comes first (the block then reserves the first guess
    /// and closes in one motion if Seerr has nothing). The host shows its page as a whole when this returns; call it next
    /// to `load_home`, after `begin_home`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn gate_home(&self) -> Result<SeerrHomeInfo, CoreError> {
        let wait = async {
            while self.home().holds_page {
                self.home_answered.notified().await;
            }
        };
        let budget = std::time::Duration::from_secs_f64(swiftly_vm::HOME_BUDGET_SECONDS);
        if tokio::time::timeout(budget, wait).await.is_err() {
            lock(&self.home).budget_over();
        }
        Ok(self.home())
    }

    /// The tap on the stack (`true`) or "Weniger anzeigen" (`false`): opens or closes the list of arrival cards. Also the
    /// host's way to restore the stored state before the first read. The host stores `arrivals_expanded` of the answer.
    pub fn set_arrivals_expanded(&self, expanded: bool) -> SeerrHomeInfo {
        lock(&self.home).set_arrivals_expanded(expanded);
        self.home()
    }

    /// The X on a card or a swipe: hides that arrival for good (any card, open or closed). Returns every dismissed request id; the
    /// host stores them (device setting).
    pub fn dismiss_arrival(&self, request_id: i64) -> Vec<i64> {
        lock(&self.home).dismiss(request_id)
    }

    // ---- titles around a library page

    /// Similar and recommended titles that are not on the server (for "Ähnliches").
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn similar(&self, art: String, tmdb: i64) -> Result<Vec<SeerrTileCard>, CoreError> {
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Ok(Vec::new());
        };
        let cards = c.related(&art, tmdb).await;
        Ok(self.tiles_of(cards).await)
    }

    /// The parts of a collection that are not on the server.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn collection_parts(&self, id: i64) -> Result<Vec<SeerrTileCard>, CoreError> {
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Ok(Vec::new());
        };
        let cards = c.collection(id).await.map(|col| col.parts);
        Ok(self.tiles_of(cards).await)
    }

    /// The credits of a person that are not on the server.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn person_credits(&self, tmdb: i64) -> Result<Vec<SeerrTileCard>, CoreError> {
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Ok(Vec::new());
        };
        let cards = c.person_credits(tmdb).await.map(|cr| {
            let mut all = cr.cast;
            all.extend(cr.crew);
            all
        });
        Ok(self.tiles_of(cards).await)
    }
}

impl SeerrListsScreen {
    /// "Zuletzt angefragt" as a rail of title cards.
    async fn recent_rail(
        &self,
        c: &Client,
    ) -> Result<swiftly_seerr::types::Page<TitleCard>, AskError> {
        let rows = c.recently_requested(12).await?;
        self.hub.resolve_requests(&rows).await;
        let cache = lock(self.hub.titles()).clone();
        let results = rows
            .into_iter()
            .filter_map(|r| {
                let media = r.media.as_deref()?.clone();
                let art = r.media_type.clone().unwrap_or_else(|| "movie".into());
                let tmdb = media.tmdb_id?;
                let lite = cache.get(&art, tmdb)?;
                Some(TitleCard {
                    hit: swiftly_seerr::SeerrHit {
                        id: tmdb,
                        art,
                        title: lite.title.clone(),
                        year: lite.year,
                        poster_path: lite.poster.clone(),
                        backdrop_path: None,
                        state: media.status,
                    },
                    release_date: lite.release_date.clone(),
                    overview: None,
                    rating: None,
                    media: Some(media),
                })
            })
            .collect::<Vec<_>>();
        let total = i64::try_from(results.len()).unwrap_or(0);
        Ok(swiftly_seerr::types::Page {
            page: 1,
            total_pages: 1,
            total_results: total,
            results,
        })
    }
}
