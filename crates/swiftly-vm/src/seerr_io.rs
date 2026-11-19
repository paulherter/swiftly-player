//! The calls behind the Seerr screens, once for every host that is not UniFFI: the hub (who the account is, what it may,
//! the counts), the lists (discover rails, search block, "Meine Anfragen", the home block) and the title page with its
//! request sheet. The state machines are `seerr_lists` and `seerr_title`; these types run the calls of a
//! [`SeerrClient`] over any transport and feed the answers in, the way the UniFFI screens do for Swift and Kotlin
//! (same order of calls, same words). A host draws the `info()` records and forwards intents; without a connection or a
//! valid session every info is empty and the host draws nothing.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_l10n::Locale;
use swiftly_net::HttpTransport;
use swiftly_seerr::requests::{RequestQuery, ServiceDetail};
use swiftly_seerr::types::{RequestRow, TitleCard};
use swiftly_seerr::{AskError, CookieJar, SeerrClient};

use crate::seerr_lists::{
    HubCounts, RailId, RequestPill, SeerrDiscoverRails, SeerrDiscoverVm, SeerrHomeInfo,
    SeerrHomeVm, SeerrHubInfo, SeerrHubVm, SeerrRequestsInfo, SeerrSearchInfo, SeerrSearchVm,
    TitleCache, request_status,
};
use crate::seerr_title::{
    RequestEnd, SeerrSeasonRowInfo, SeerrSheetInfo, SeerrTileCard, SeerrTitleInfo, SeerrTitleVm,
    SheetNeeds, tile_of, today_utc,
};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// How a request ended, for the host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeerrRequestResult {
    /// Nothing was sent (the button was not pressable).
    NotSent,
    /// It is in. `auto_approved`: no admin needed.
    Requested {
        /// No admin needed.
        auto_approved: bool,
    },
    /// Somebody asked before; the page now reads "Angefragt".
    Exists,
    /// Refused; the sheet stays open and shows `message`.
    Failed {
        /// The refusal in words.
        message: String,
    },
}

/// See [`SeerrHub::timer`].
pub struct ScreenTimer {
    log: Option<swiftly_seerr::SeerrLog>,
    text: String,
    began: std::time::Instant,
}

impl Drop for ScreenTimer {
    fn drop(&mut self) {
        if let (Some(log), false) = (&self.log, swiftly_seerr::is_replaying()) {
            log(&format!(
                "[Seerr] {} {}ms",
                self.text,
                self.began.elapsed().as_millis()
            ));
        }
    }
}

/// The connection of the Seerr screens: who the account is and what it may do, the counts, the
/// titles read so far. One per signed-in connection; the screens share it.
pub struct SeerrHub<T: HttpTransport, J: CookieJar> {
    client: Option<Arc<SeerrClient<T, J>>>,
    pub(crate) locale: String,
    pub(crate) vm: Mutex<SeerrHubVm>,
    pub(crate) titles: Mutex<TitleCache>,
    /// The Radarr / Sonarr choices per kind (`movie` / `tv`) of this connection: the default server
    /// and its detail. Read once with the first title page an administrator opens, so the request sheet
    /// opens complete (see `SeerrTitleScreen::open_sheet`).
    services: Mutex<std::collections::HashMap<String, (i64, ServiceDetail)>>,
    /// One read of the account at a time: callers that ask while it runs wait for it, so the account is read once.
    gate: futures_util::lock::Mutex<()>,
    /// The state was painted from the stash (`restore_*`): the next `ensure` reads the account live once, so a
    /// session that ended since the last start is found out and the rights are the current ones.
    from_stash: std::sync::atomic::AtomicBool,
    /// Held while [`Self::warm_up`] runs; shared with every twin of this hub, so a screen can wait for it.
    warm: Arc<futures_util::lock::Mutex<()>>,
}

impl<T: HttpTransport, J: CookieJar> SeerrHub<T, J> {
    /// The client of the connection (`None`: this account has no Seerr).
    pub fn client(&self) -> Option<&SeerrClient<T, J>> {
        self.client.as_deref()
    }

    /// The user's language.
    pub fn locale_of(&self) -> Locale {
        Locale::parse(&self.locale)
    }

    /// The hub's state machine: who the account is, what it may, the counts.
    pub fn vm(&self) -> &Mutex<SeerrHubVm> {
        &self.vm
    }

    /// The titles read so far, shared by every screen over this hub.
    pub fn titles(&self) -> &Mutex<TitleCache> {
        &self.titles
    }

    /// The hub is ready (reads it once when it has not been). Reads the account, not the counts: a screen that
    /// needs them reads them next to its own lists (`read_counts`), in the same round.
    pub async fn ensure(&self) -> bool {
        if self.client().is_none() {
            return false;
        }
        let loading = || {
            lock(&self.vm).info().state == crate::HubState::Loading
                || self.from_stash.load(std::sync::atomic::Ordering::SeqCst)
        };
        if loading() {
            let _one_at_a_time = self.gate.lock().await;
            if loading() {
                self.from_stash
                    .store(false, std::sync::atomic::Ordering::SeqCst);
                self.read().await;
            }
        }
        lock(&self.vm).available()
    }

    /// Who the account is and what it may: `me` and the public settings in one round, the quota after it.
    async fn read(&self) {
        let Some(c) = self.client() else {
            lock(&self.vm).unavailable();
            return;
        };
        let (me, public) = futures_util::future::join(c.me(), c.public_settings()).await;
        let quota = match &me {
            Ok(m) => c.quota(m.id).await.ok(),
            Err(_) => None,
        };
        lock(&self.vm).loaded(me, quota, public.ok());
    }

    /// Reads the quota again (after a request, when a sheet opens).
    pub async fn read_quota(&self) {
        let (Some(c), uid) = (self.client(), lock(&self.vm).user_id()) else {
            return;
        };
        if uid == 0 {
            return;
        }
        if let Ok(q) = c.quota(uid).await {
            lock(&self.vm).quota_loaded(q);
        }
    }

    /// Reads the counts (my running requests and problems, the admin queue and open problems).
    pub async fn read_counts(&self) {
        let Some(c) = self.client() else { return };
        let (uid, perms) = {
            let vm = lock(&self.vm);
            (vm.user_id(), vm.perms())
        };
        if uid == 0 {
            return;
        }
        let today = today_utc();
        let mine = async {
            let q = RequestQuery {
                requested_by: Some(uid),
                by_modified: true,
                take: 50,
                ..RequestQuery::default()
            };
            c.request_list(&q).await.ok().map(|p| {
                let n = p
                    .results
                    .iter()
                    .filter(|r| {
                        use swiftly_seerr::SeerrStatus as S;
                        matches!(
                            request_status(r, None, &today),
                            S::Fetching { .. } | S::Searching | S::Soon { .. } | S::UpToDate { .. }
                        )
                    })
                    .count();
                i64::try_from(n).unwrap_or(0)
            })
        };
        let issues = async {
            if !(perms.can_create_issues() || perms.can_view_issues()) {
                return None;
            }
            let q = swiftly_seerr::issues::IssueQuery {
                filter: swiftly_seerr::issues::IssueFilter::Open,
                requested_by: Some(uid),
                take: 1,
                ..Default::default()
            };
            c.issue_list(&q).await.ok().map(|p| p.page_info.results)
        };
        let pending = async {
            if !perms.can_manage_requests() {
                return None;
            }
            c.request_count().await.ok().map(|n| n.pending)
        };
        let open_issues = async {
            if !perms.can_manage_issues() {
                return None;
            }
            c.issue_count().await.ok().map(|n| n.open)
        };
        let ((a, b), (p, i)) = futures_util::future::join(
            futures_util::future::join(mine, issues),
            futures_util::future::join(pending, open_issues),
        )
        .await;
        lock(&self.vm).counts_loaded(HubCounts {
            my_running: a.unwrap_or(0),
            my_issues: b.unwrap_or(0),
            pending: p.unwrap_or(0),
            issues_open: i.unwrap_or(0),
        });
    }

    /// Reads the titles of these requests that the cache does not know yet.
    pub async fn resolve_titles(&self, keys: Vec<(String, i64)>) {
        let Some(c) = self.client() else { return };
        let answers =
            futures_util::future::join_all(keys.iter().take(40).map(|(art, id)| c.title(art, *id)))
                .await;
        let mut cache = lock(&self.titles);
        for info in answers.into_iter().flatten() {
            cache.put(&info);
        }
    }

    /// Reads the titles of these requests that the cache does not know yet.
    pub async fn resolve_requests(&self, rows: &[RequestRow]) {
        let keys = lock(&self.titles).missing(rows);
        if !keys.is_empty() {
            self.resolve_titles(keys).await;
        }
    }
}
impl<T: HttpTransport, J: CookieJar> SeerrHub<T, J> {
    /// The hub of a connection; `None` = this account has no Seerr (everything stays empty).
    pub fn new(client: Option<SeerrClient<T, J>>, locale: String) -> Arc<Self> {
        Self::shared(client.map(Arc::new), locale)
    }

    /// The hub over a client that another owner holds too (the UniFFI model).
    pub fn shared(client: Option<Arc<SeerrClient<T, J>>>, locale: String) -> Arc<Self> {
        Self::sharing(client, locale, Arc::new(futures_util::lock::Mutex::new(())))
    }

    fn sharing(
        client: Option<Arc<SeerrClient<T, J>>>,
        locale: String,
        warm: Arc<futures_util::lock::Mutex<()>>,
    ) -> Arc<Self> {
        let mut vm = SeerrHubVm::new(Locale::parse(&locale));
        if client.is_none() {
            vm.unavailable();
        }
        Arc::new(Self {
            client,
            vm: Mutex::new(vm),
            titles: Mutex::new(TitleCache::default()),
            services: Mutex::new(std::collections::HashMap::new()),
            gate: futures_util::lock::Mutex::new(()),
            from_stash: std::sync::atomic::AtomicBool::new(false),
            warm,
            locale,
        })
    }

    /// True while nothing has been read on this hub (a stash paint is only allowed then).
    pub(crate) fn untouched(&self) -> bool {
        lock(&self.vm).info().state == crate::HubState::Loading
    }

    /// True while this hub has not read live (nothing read, or only painted from the stash).
    pub(crate) fn cold(&self) -> bool {
        self.untouched() || self.from_stash.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// The state of this hub was painted from the stash: the live read replaces it (see `from_stash`).
    pub(crate) fn painted_from_stash(&self) {
        self.from_stash
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// A second hub over the same client with nothing read yet: what a screen paints from the stash before the live
    /// read ([`swiftly_seerr::replaying`]) lives there, so the live hub's state is never touched by stale answers.
    pub fn stale_twin(&self) -> Arc<Self> {
        Self::sharing(
            self.client.clone(),
            self.locale.clone(),
            Arc::clone(&self.warm),
        )
    }

    /// One `[Seerr]` line into the host's log (nothing when the client has no log).
    pub fn note(&self, line: &str) {
        if let Some(c) = self.client() {
            c.note(line);
        }
    }

    /// A screen step took `began.elapsed()`: `[Seerr] admin live ready 604ms`.
    pub fn took(&self, screen: &str, what: &str, began: std::time::Instant) {
        // A stash probe or paint replays the live read without a call: its time is the paint's, logged by its caller.
        if swiftly_seerr::is_replaying() {
            return;
        }
        self.note(&format!(
            "{screen} {what} {}ms",
            began.elapsed().as_millis()
        ));
    }

    /// Logs `[Seerr] <screen> <what> <ms>ms` when the returned guard is dropped (the end of the read, whichever way it
    /// returns). A stash probe replays the read without a call and logs nothing.
    #[must_use]
    pub fn timer(&self, screen: &str, what: &str) -> ScreenTimer {
        ScreenTimer {
            log: self.client().and_then(|c| c.log_sink()),
            text: format!("{screen} {what}"),
            began: std::time::Instant::now(),
        }
    }

    /// A screen whose stash probe found nothing waits here while a warm-up runs: the warm-up is filling exactly what
    /// the screen would read, so the screen asks again from the stash instead of reading the same calls a second time.
    /// `true` = it had to wait (probe again); `false` = no warm-up runs.
    pub async fn after_warm_up(&self) -> bool {
        if self.warm.try_lock().is_some() {
            return false;
        }
        let _ = self.warm.lock().await;
        true
    }

    /// The first read of a start, run once the media server's Home stands: the account, the Start block, "Meine
    /// Anfragen", for an account with admin tabs the queue and the problems, and the discover rails, all kept in the
    /// stash, so the first visit of any Seerr screen of this session (or ever) paints at once. It reads on a twin of
    /// this hub (a screen's own first live read and its stash paint stay as they are) and never twice at the same
    /// time: a second call while one runs returns `false` at once. `false` also when there is no Seerr or no session.
    pub async fn warm_up(&self) -> bool {
        if self.client().is_none() {
            return false;
        }
        let Some(_running) = self.warm.try_lock() else {
            self.note("warm-up already running");
            return false;
        };
        let began = std::time::Instant::now();
        let twin = self.stale_twin();
        if !twin.ensure().await {
            self.note("warm-up stopped: no session");
            return false;
        }
        let lists = SeerrListsScreen::new(Arc::clone(&twin));
        let admin = crate::SeerrAdminScreen::new(Arc::clone(&twin));
        let with_admin = !admin.tabs().is_empty();
        futures_util::future::join3(
            async {
                lists
                    .load_home(Vec::new(), true, true, |_, _| async { None })
                    .await;
            },
            async {
                lists.load_requests().await;
            },
            async {
                if with_admin {
                    admin.load_all().await;
                }
            },
        )
        .await;
        lists.load_discover().await;
        self.took(
            "warm-up",
            if with_admin { "done (admin)" } else { "done" },
            began,
        );
        true
    }

    /// The state now.
    pub fn info(&self) -> SeerrHubInfo {
        lock(&self.vm).info()
    }

    /// True when Seerr is connected with a valid session: the one check before drawing anything.
    pub fn available(&self) -> bool {
        lock(&self.vm).available()
    }

    /// Reads who the account is, what it may do, its quota and the counts.
    pub async fn refresh(&self) -> SeerrHubInfo {
        {
            let _one_at_a_time = self.gate.lock().await;
            self.read().await;
        }
        self.read_counts().await;
        self.info()
    }

    /// Reads only the counts (profile rows, home line); cheap enough for every Home appearance.
    pub async fn refresh_counts(&self) -> SeerrHubInfo {
        if self.ensure().await {
            self.read_counts().await;
        }
        self.info()
    }

    /// The quota line for a request sheet of `art` ("Noch 1 von 3 Staffeln frei diese Woche") and
    /// whether it is the warning; `None` without a limit.
    pub fn quota_line(&self, art: String) -> Option<String> {
        lock(&self.vm).quota_line(&art).map(|(t, _)| t)
    }
}

/// The lists of Seerr over one hub.
pub struct SeerrListsScreen<T: HttpTransport, J: CookieJar> {
    hub: Arc<SeerrHub<T, J>>,
    discover: Mutex<SeerrDiscoverVm>,
    search: Mutex<SeerrSearchVm>,
    my: crate::seerr_my_requests::MyRequests<T, J>,
    home: Mutex<SeerrHomeVm>,
}

impl<T: HttpTransport, J: CookieJar> SeerrListsScreen<T, J> {
    /// The account's own requests as the home block and the list read them (`take` rows).
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
impl<T: HttpTransport, J: CookieJar> SeerrListsScreen<T, J> {
    /// The list screens over a hub.
    pub fn new(hub: Arc<SeerrHub<T, J>>) -> Arc<Self> {
        let locale = hub.locale_of();
        let today = today_utc();
        Arc::new(Self {
            discover: Mutex::new(SeerrDiscoverVm::new(locale.clone(), &today)),
            search: Mutex::new(SeerrSearchVm::new(locale.clone(), &today)),
            my: crate::seerr_my_requests::MyRequests::new(Arc::clone(&hub)),
            home: Mutex::new(SeerrHomeVm::new(locale, &today)),
            hub,
        })
    }

    // ---- discover

    /// The discover rails now (empty until `load_discover` ran).
    pub fn discover(&self) -> SeerrDiscoverRails {
        lock(&self.discover).info()
    }

    /// Reads the rails of the empty Search page.
    pub async fn load_discover(&self) -> SeerrDiscoverRails {
        let began = std::time::Instant::now();
        let rails = self.load_discover_read().await;
        self.hub.took("discover", "live ready", began);
        rails
    }

    async fn load_discover_read(&self) -> SeerrDiscoverRails {
        if !self.hub.ensure().await {
            return self.discover();
        }
        let Some(c) = self.hub.client() else {
            return self.discover();
        };
        let order = RailId::order(&c.discover_sliders().await.unwrap_or_default());
        let hide = lock(&self.hub.vm).public().hide_available;
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
        self.discover()
    }

    // ---- search merge

    /// The search block now.
    pub fn search_info(&self) -> SeerrSearchInfo {
        lock(&self.search).info()
    }

    /// Searches Seerr for `term`; an empty term resets. Returns when the answer is in.
    pub async fn search(&self, term: String) -> SeerrSearchInfo {
        lock(&self.search).begin(&term);
        if term.trim().is_empty() || !self.hub.ensure().await {
            return self.search_info();
        }
        let Some(c) = self.hub.client() else {
            return self.search_info();
        };
        let page = c.search(term.trim(), 1).await;
        lock(&self.search).loaded(&term, page);
        self.search_info()
    }

    // ---- my requests (see `MyRequests`)

    /// "Meine Anfragen" now.
    pub fn requests(&self) -> SeerrRequestsInfo {
        self.my.info()
    }

    /// Reads the account's requests.
    pub async fn load_requests(&self) -> SeerrRequestsInfo {
        self.my.load().await
    }

    /// Paints "Meine Anfragen" of the last visit from the stash (see `MyRequests::restore`).
    pub async fn restore_requests(&self) -> bool {
        self.my.restore().await
    }

    /// Picks a filter pill.
    pub fn select_pill(&self, pill: RequestPill) -> SeerrRequestsInfo {
        self.my.select_pill(pill)
    }

    /// "Zurückziehen" on an own waiting request.
    pub async fn withdraw(&self, id: i64) -> SeerrRequestsInfo {
        self.my.withdraw(id).await
    }

    // ---- home block

    /// The home block now (`show` false = draw nothing).
    pub fn home(&self) -> SeerrHomeInfo {
        let cache = lock(&self.hub.titles).clone();
        lock(&self.home).info(&cache)
    }

    /// Reads what the home block needs. `dismissed` are the request ids the host stored,
    /// `arrival_on` is the setting `seerrArrivalHint`, `requests_on` the setting `seerrRequestsRail`.
    pub async fn load_home<F, Fut>(
        &self,
        dismissed: Vec<i64>,
        arrival_on: bool,
        requests_on: bool,
        find: F,
    ) -> SeerrHomeInfo
    where
        F: Fn(String, i64) -> Fut,
        Fut: std::future::Future<Output = Option<String>>,
    {
        let began = std::time::Instant::now();
        let info = self
            .load_home_read(dismissed, arrival_on, requests_on, find)
            .await;
        self.hub.took("home", "live ready", began);
        info
    }

    async fn load_home_read<F, Fut>(
        &self,
        dismissed: Vec<i64>,
        arrival_on: bool,
        requests_on: bool,
        find: F,
    ) -> SeerrHomeInfo
    where
        F: Fn(String, i64) -> Fut,
        Fut: std::future::Future<Output = Option<String>>,
    {
        let ok = self.hub.ensure().await;
        {
            let mut h = lock(&self.home);
            h.set_dismissed(&dismissed);
            h.set_arrival_enabled(arrival_on);
            h.set_requests_enabled(requests_on);
            h.set_available(ok);
        }
        if !ok {
            lock(&self.home).answered();
            return self.home();
        }
        // The counts and the account's requests are read side by side, not one after the other.
        let (_, mine) = futures_util::future::join(
            self.hub.read_counts(),
            self.mine(crate::seerr_my_requests::HOME_TAKE),
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
        for cand in candidates {
            if let Some(id) = find(cand.art.clone(), cand.tmdb).await {
                found.push((cand.request_id, id));
            }
        }
        lock(&self.home).arrivals_found(found);
        lock(&self.home).answered();
        self.home()
    }

    /// Paints the home block of the last start into this screen from the stash, without a call to Seerr (`false`:
    /// nothing complete is stored, or the screen already read; nothing is touched then). The live `load_home` that
    /// follows replaces it. A copy of the screen probes the stash first, so a missing answer never leaves a half-read
    /// block behind (a first start would release its page gate too early).
    pub async fn restore_home<F, Fut>(
        &self,
        dismissed: Vec<i64>,
        arrival_on: bool,
        requests_on: bool,
        find: F,
    ) -> bool
    where
        F: Fn(String, i64) -> Fut,
        Fut: std::future::Future<Output = Option<String>>,
    {
        if !self.hub.untouched() {
            return false;
        }
        let began = std::time::Instant::now();
        let mut waited = false;
        loop {
            let probe = Self::new(self.hub.stale_twin());
            let seen = swiftly_seerr::replaying(probe.load_home(
                dismissed.clone(),
                arrival_on,
                requests_on,
                |_, _| async { None },
            ))
            .await;
            if seen.is_some_and(|info| info.show) {
                break;
            }
            if waited || !self.hub.after_warm_up().await {
                self.hub.took("home", "stash miss", began);
                return false;
            }
            waited = true;
        }
        let shown =
            swiftly_seerr::replaying(self.load_home(dismissed, arrival_on, requests_on, find))
                .await;
        self.hub.painted_from_stash();
        self.hub.took("home", "first paint from stash", began);
        shown.is_some()
    }

    /// Paints the discover rails of the last visit from the stash (see `restore_home`).
    pub async fn restore_discover(&self) -> bool {
        if !self.hub.untouched() {
            return false;
        }
        let began = std::time::Instant::now();
        let mut waited = false;
        loop {
            let probe = Self::new(self.hub.stale_twin());
            let seen = swiftly_seerr::replaying(probe.load_discover()).await;
            if seen.is_some_and(|r| r.load == crate::ListLoad::Content) {
                break;
            }
            if waited || !self.hub.after_warm_up().await {
                self.hub.took("discover", "stash miss", began);
                return false;
            }
            waited = true;
        }
        let shown = swiftly_seerr::replaying(self.load_discover()).await;
        self.hub.painted_from_stash();
        self.hub.took("discover", "first paint from stash", began);
        shown.is_some()
    }

    /// The setting "Meine Anfragen" on Start changed: the block follows at once, without another read (the account's
    /// requests are already in). Returns the block now.
    pub fn set_requests_enabled(&self, on: bool) -> SeerrHomeInfo {
        lock(&self.home).set_requests_enabled(on);
        self.home()
    }

    /// Seerr is connected and the home block is about to be read: the block reserves the shape of the last start
    /// (`memory`: the code stored under [`crate::seerr_home_memory_key`], "" when there is none) until the first answer.
    pub fn begin_home(&self, memory: &str) -> SeerrHomeInfo {
        lock(&self.home).begin(memory);
        self.home()
    }

    /// The budget of a first start ran out ([`crate::HOME_BUDGET_SECONDS`]) with Seerr still out: the page shows now and
    /// the block reserves the first guess. The host owns the timer (it has to wake its screen anyway).
    pub fn home_budget_over(&self) -> SeerrHomeInfo {
        lock(&self.home).budget_over();
        self.home()
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
    pub async fn similar(&self, art: String, tmdb: i64) -> Vec<SeerrTileCard> {
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Vec::new();
        };
        let cards = c.related(&art, tmdb).await;
        self.tiles_of(cards).await
    }

    /// The parts of a collection that are not on the server.
    pub async fn collection_parts(&self, id: i64) -> Vec<SeerrTileCard> {
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Vec::new();
        };
        let cards = c.collection(id).await.map(|col| col.parts);
        self.tiles_of(cards).await
    }

    /// The credits of a person that are not on the server.
    pub async fn person_credits(&self, tmdb: i64) -> Vec<SeerrTileCard> {
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Vec::new();
        };
        let cards = c.person_credits(tmdb).await.map(|cr| {
            let mut all = cr.cast;
            all.extend(cr.crew);
            all
        });
        self.tiles_of(cards).await
    }
}

impl<T: HttpTransport, J: CookieJar> SeerrListsScreen<T, J> {
    /// "Zuletzt angefragt" as a rail of title cards.
    async fn recent_rail(
        &self,
        c: &SeerrClient<T, J>,
    ) -> Result<swiftly_seerr::types::Page<TitleCard>, AskError> {
        let rows = c.recently_requested(12).await?;
        self.hub.resolve_requests(&rows).await;
        let cache = lock(&self.hub.titles).clone();
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

/// The page and sheet of one title.
pub struct SeerrTitleScreen<T: HttpTransport, J: CookieJar> {
    hub: Arc<SeerrHub<T, J>>,
    art: String,
    tmdb: i64,
    vm: Mutex<SeerrTitleVm>,
    needs: Mutex<Option<SheetNeeds>>,
}

impl<T: HttpTransport, J: CookieJar> SeerrTitleScreen<T, J> {
    async fn read(&self) {
        let ready = self.hub.ensure().await;
        let Some(c) = self.hub.client().filter(|_| ready) else {
            let offline = self.hub.info().state == crate::HubState::Offline;
            let mut vm = lock(&self.vm);
            if offline {
                vm.offline();
            } else {
                vm.unavailable();
            }
            return;
        };
        lock(&self.vm).begin_load();
        // **The request sheet's choices come with the page** (administrators): read next to the title,
        // so the sheet never waits for them while it slides up.
        let advanced = self.hub.vm_account(&self.art).perms.can_choose_advanced();
        let prefetch = async {
            if advanced {
                let _ = self.hub.services(&self.art).await;
            }
        };
        let (title, related, ()) = futures_util::future::join3(
            c.title(&self.art, self.tmdb),
            c.related(&self.art, self.tmdb),
            prefetch,
        )
        .await;
        if let Ok(info) = &title {
            lock(&self.hub.titles).put(info);
        }
        let account = self.hub.vm_account(&self.art);
        lock(&self.vm).loaded(title, related.unwrap_or_default(), account);
    }
}

impl<T: HttpTransport, J: CookieJar> SeerrHub<T, J> {
    /// The cached Radarr / Sonarr choices of `art`, without asking.
    pub(crate) fn cached_services(&self, art: &str) -> Option<(i64, ServiceDetail)> {
        lock(&self.services).get(art).cloned()
    }

    /// The Radarr / Sonarr choices of `art`: from the cache, or read once and kept.
    pub(crate) async fn services(&self, art: &str) -> Option<(i64, ServiceDetail)> {
        if let Some(hit) = self.cached_services(art) {
            return Some(hit);
        }
        let c = self.client()?;
        let servers = c.service_servers(art).await.ok()?;
        let server = servers
            .iter()
            .find(|s| s.is_default && !s.is4k)
            .or_else(|| servers.iter().find(|s| !s.is4k))?;
        let detail = c.service_detail(art, server.id).await.ok()?;
        let hit = (server.id, detail);
        lock(&self.services).insert(art.to_string(), hit.clone());
        Some(hit)
    }

    pub(crate) fn vm_account(&self, art: &str) -> crate::SeerrAccount {
        lock(&self.vm).account(art)
    }
}
impl<T: HttpTransport, J: CookieJar> SeerrTitleScreen<T, J> {
    /// The page of `art` (`movie` / `tv`) and TMDB id over a hub.
    pub fn new(hub: Arc<SeerrHub<T, J>>, art: String, tmdb: i64) -> Arc<Self> {
        let locale = Locale::parse(&hub.locale);
        Arc::new(Self {
            vm: Mutex::new(SeerrTitleVm::new(locale, &art, tmdb, &today_utc())),
            hub,
            art,
            tmdb,
            needs: Mutex::new(None),
        })
    }

    /// The page now.
    pub fn info(&self) -> SeerrTitleInfo {
        lock(&self.vm).info()
    }

    /// The seasons of the library series (present on the server).
    pub fn set_library_seasons(&self, numbers: Vec<i64>) {
        lock(&self.vm).set_library_seasons(&numbers);
    }

    /// The seasons for the picker of a library series: the library's and Seerr's, merged; missing
    /// ones are grey (`missing`) and a tap on them calls `open_sheet(Some(number))`.
    pub fn season_picker(&self) -> Vec<SeerrSeasonRowInfo> {
        lock(&self.vm).season_picker()
    }

    /// Reads the title, what is around it and the account; returns when the page is there.
    pub async fn load(&self) -> SeerrTitleInfo {
        self.read().await;
        self.info()
    }

    /// Opens the request sheet at once and complete: the choices come from the page's prefetch; the
    /// quota line (reserved space) and choices not read yet (reserved rows) fill in with `load_sheet`.
    pub fn open_sheet(&self, season: Option<i64>) -> SeerrSheetInfo {
        let mut needs = lock(&self.vm).open_sheet(season);
        if needs.services
            && let Some((id, detail)) = self.hub.cached_services(&self.art)
        {
            lock(&self.vm).services_loaded(Some(id), &detail);
            needs.services = false;
        }
        *lock(&self.needs) = Some(needs);
        self.info().sheet
    }

    /// Reads the quota and (admin) the quality and folder choices for the open sheet.
    pub async fn load_sheet(&self) -> SeerrSheetInfo {
        let needs = lock(&self.needs).take();
        let Some(needs) = needs else {
            return self.info().sheet;
        };
        let Some(c) = self.hub.client() else {
            return self.info().sheet;
        };
        let uid = self.hub.info().user_id;
        let quota = async {
            if needs.quota && uid != 0 {
                Some(c.quota(uid).await.ok())
            } else {
                None
            }
        };
        let services = async {
            if needs.services {
                Some(self.hub.services(&self.art).await)
            } else {
                None
            }
        };
        let (quota, services) = futures_util::future::join(quota, services).await;
        if let Some(q) = quota {
            let part = q.map(|q| q.part(&self.art));
            if let Some(q) = q {
                lock(&self.hub.vm).quota_loaded(q);
            }
            lock(&self.vm).quota_loaded(part);
        }
        match services {
            Some(Some((id, detail))) => lock(&self.vm).services_loaded(Some(id), &detail),
            Some(None) => lock(&self.vm).services_failed(),
            None => {}
        }
        self.info().sheet
    }

    /// A season row of the sheet was tapped.
    pub fn toggle(&self, number: i64) -> SeerrSheetInfo {
        lock(&self.vm).toggle(number);
        self.info().sheet
    }

    /// "In 4K".
    pub fn set_four_k(&self, on: bool) -> SeerrSheetInfo {
        lock(&self.vm).set_four_k(on);
        self.info().sheet
    }

    /// "Qualität": the id of the chosen option.
    pub fn choose_quality(&self, id: i64) -> SeerrSheetInfo {
        lock(&self.vm).choose_quality(id);
        self.info().sheet
    }

    /// "Ordner": the path of the chosen option.
    pub fn choose_folder(&self, path: String) -> SeerrSheetInfo {
        lock(&self.vm).choose_folder(&path);
        self.info().sheet
    }

    /// The sheet was closed.
    pub fn close_sheet(&self) -> SeerrSheetInfo {
        lock(&self.vm).close_sheet();
        self.info().sheet
    }

    /// The sheet's button: sends the request. On success the sheet closes and the page reads again;
    /// a refusal (limit, permission, blocked) comes back as `Failed` and stays in the sheet.
    pub async fn confirm(&self) -> SeerrRequestResult {
        let sent = lock(&self.vm).confirm();
        let Some((spec, perms)) = sent else {
            return SeerrRequestResult::NotSent;
        };
        let result = match self.hub.client() {
            Some(c) => c.request(&spec, perms).await,
            None => Err(AskError::SessionLost),
        };
        let end = lock(&self.vm).asked(result);
        match end {
            RequestEnd::Requested { auto_approved } => {
                self.reread().await;
                SeerrRequestResult::Requested { auto_approved }
            }
            RequestEnd::Exists => {
                self.reread().await;
                SeerrRequestResult::Exists
            }
            RequestEnd::Failed(message) => SeerrRequestResult::Failed { message },
        }
    }

    /// Reads the page again (pull to refresh, a sheet that closed).
    pub async fn refresh(&self) -> SeerrTitleInfo {
        self.reread().await;
        self.info()
    }
}

impl<T: HttpTransport, J: CookieJar> SeerrTitleScreen<T, J> {
    async fn reread(&self) {
        self.hub.read_quota().await;
        self.read().await;
        let _ = self.hub.refresh_counts().await;
    }
}
