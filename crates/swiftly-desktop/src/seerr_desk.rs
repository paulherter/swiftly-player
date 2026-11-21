//! The Seerr screens of the core (`swiftly_vm::seerr_io`: hub, lists, title page with its request sheet) over the
//! desktop's transport and the stored Seerr session of the Settings page. The core runs the calls and keeps every state
//! machine; this type only gives the core's futures a place to run and tells the pages that something changed.
//! Without a stored session there is no desk and nothing Seerr shows at all (an add-on leaves no hole).

use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use swiftly_seerr::{NoCookies, SeerrClient};
use swiftly_settings::{KeyValueStore, Value, keys};
use swiftly_vm::{SeerrAdminScreen, SeerrHub, SeerrListsScreen, SeerrTitleScreen};

use crate::seerr_link::Shared;

/// The connection of the screens.
pub type Hub = SeerrHub<Shared, NoCookies>;
/// The lists: discover rails, search block, "Meine Anfragen", the home block.
pub type Lists = SeerrListsScreen<Shared, NoCookies>;
/// The administrator's queue and problems.
pub type Admin = SeerrAdminScreen<Shared, NoCookies>;
/// One title page with its request sheet.
pub type Title = SeerrTitleScreen<Shared, NoCookies>;

/// How many calls are out and how often one came back.
#[derive(Default)]
struct Work {
    pending: AtomicU32,
    changed: AtomicU64,
}

/// The core's Seerr screens of one signed-in desktop.
#[derive(Clone)]
pub struct Desk {
    core: Arc<crate::live::Core>,
    /// The signed-in media server account: the home block looks its arrivals up there.
    account: Option<swiftly_vm::AccountRef>,
    hub: Arc<Hub>,
    lists: Arc<Lists>,
    admin: Arc<Admin>,
    work: Arc<Work>,
    /// The two Start switches (arrival banners, "Meine Anfragen") the block was last read or set with.
    applied: Arc<std::sync::Mutex<Option<(bool, bool)>>>,
}

impl Desk {
    /// The desk of the stored session; `None` when Seerr is not connected.
    pub fn stored(core: &Arc<crate::live::Core>) -> Option<Desk> {
        let access = core.seerr_stored()?;
        // The last answers of every read are kept in the core's cache: a screen paints them before the live read.
        let stash = core.host().cache.map(|cache| {
            swiftly_vm::SeerrStash::for_connection(cache, &access.address, &access.cookie)
        });
        let mut client = SeerrClient::with_jar(access, Shared(Arc::clone(&core.net)), NoCookies);
        if let Some(stash) = stash {
            client = client.with_stash(stash);
        }
        // The desktop's log is stderr: one `[Seerr]` line per call and per screen (path, status, milliseconds).
        client = client.with_log(Arc::new(|line: &str| eprintln!("{line}")));
        let hub = Hub::new(Some(client), core.host().locale.tag());
        let lists = Lists::new(Arc::clone(&hub));
        let admin = Admin::new(Arc::clone(&hub));
        Some(Desk {
            core: Arc::clone(core),
            account: None,
            hub,
            lists,
            admin,
            work: Arc::new(Work::default()),
            applied: Arc::new(std::sync::Mutex::new(None)),
        })
    }

    /// The same desk, with the account whose library the home block looks arrivals up in.
    pub fn with_account(mut self, account: swiftly_vm::AccountRef) -> Desk {
        self.account = Some(account);
        self
    }

    /// The device's settings (the arrival switch and the closed banners).
    /// The "Meine Anfragen" switch as the Start page honours it (off until the user switches it on).
    fn requests_rail_on(st: &swiftly_settings::Settings<crate::settings_screen::Mem>) -> bool {
        st.get(&keys::SEERR_REQUESTS_RAIL)
            && swiftly_library::SeerrSection::Requests.on_start(swiftly_library::HomeForm::Desktop)
    }

    /// The "ist da" switch as the Start page honours it: the core keeps that banner off the desktop Start page whatever
    /// the switch says (`SeerrSection::on_start`), so its library lookup is not read either.
    fn arrival_on(st: &swiftly_settings::Settings<crate::settings_screen::Mem>) -> bool {
        st.get(&keys::SEERR_ARRIVAL_HINT)
            && swiftly_library::SeerrSection::Arrival.on_start(swiftly_library::HomeForm::Desktop)
    }

    fn settings(&self) -> swiftly_settings::Settings<crate::settings_screen::Mem> {
        swiftly_settings::Settings::new(crate::settings_screen::Mem::shared(Arc::clone(
            &self.core.settings,
        )
            as Arc<dyn swiftly_settings::KeyValueStore>))
    }

    /// The library lookup of the home block (arrival banners): this account's Jellyfin/Emby server by TMDB id.
    fn finder(
        &self,
    ) -> impl Fn(
        String,
        i64,
    )
        -> std::pin::Pin<Box<dyn Future<Output = Option<swiftly_vm::LibraryHit>> + Send>>
    + Clone
    + Send
    + Sync
    + 'static {
        let (core, account) = (Arc::clone(&self.core), self.account.clone());
        move |art: String, tmdb: i64| {
            let (core, account) = (Arc::clone(&core), account.clone());
            Box::pin(async move {
                let account = account?;
                if account.server_kind == swiftly_jellyfin::ServerKind::Plex {
                    return None;
                }
                let kind = if art == "tv" { "Series" } else { "Movie" };
                let client = core.client_for(&account).ok()?;
                let id = client.item_id_by_tmdb(tmdb, kind).await.ok().flatten()?;
                let cover = client.image_url_by_id(&id, 360).map(|u| u.to_string());
                Some(swiftly_vm::LibraryHit { id, cover })
            })
        }
    }

    /// The rails of the empty Search page: the last visit's rails first (stash), then the live read.
    pub fn load_discover(&self) {
        let (lists, work) = (Arc::clone(&self.lists), Arc::clone(&self.work));
        self.run(async move {
            if lists.restore_discover().await {
                work.changed.fetch_add(1, Ordering::SeqCst);
            }
            let _ = lists.load_discover().await;
        });
    }

    /// "Meine Anfragen": the last visit's list first (stash; the filter pills work on it at once), then the live read.
    pub fn load_requests(&self) {
        let (lists, work) = (Arc::clone(&self.lists), Arc::clone(&self.work));
        self.run(async move {
            if lists.restore_requests().await {
                work.changed.fetch_add(1, Ordering::SeqCst);
            }
            let _ = lists.load_requests().await;
        });
    }

    /// The admin page: the last visit's queue and problems first (stash), then one live read of counts, queue and
    /// problems side by side.
    pub fn load_admin(&self) {
        let (admin, work) = (Arc::clone(&self.admin), Arc::clone(&self.work));
        self.run(async move {
            if admin.restore_all().await {
                work.changed.fetch_add(1, Ordering::SeqCst);
            }
            let _ = admin.load_all().await;
        });
    }

    /// Reads the home block again from the core (`SeerrListsScreen::load_home`: the same call the iPhone makes): the
    /// request ids closed on this device and the setting `seerrArrivalHint` go in, the library lookup by TMDB id is this
    /// account's Jellyfin/Emby server. A Plex account has no such call and never shows an arrival.
    pub fn load_home(&self) {
        let st = self.settings();
        let dismissed: Vec<i64> = st
            .get(&keys::SEERR_ARRIVAL_DISMISSED)
            .iter()
            .filter_map(|s| s.parse().ok())
            .collect();
        let on = Self::arrival_on(&st);
        let requests_on = Self::requests_rail_on(&st);
        *self.applied.lock().unwrap_or_else(|e| e.into_inner()) = Some((on, requests_on));
        let find = self.finder();
        // The first frame already knows the block's room: what the last start of this profile showed is reserved
        // until the answer is in (`SeerrHomeState::Pending`), and the answer's shape is stored for the next start.
        let key =
            swiftly_vm::seerr_home_memory_key(self.account.as_ref().map(|a| a.key()).as_deref());
        let remembered = match KeyValueStore::get(&*self.core.settings, &key) {
            Some(Value::Str(code)) => code,
            _ => String::new(),
        };
        self.lists.begin_home(&remembered);
        // The stack stays as it was left (the core shows it open only with two or more cards).
        self.lists
            .set_arrivals_expanded(st.get(&keys::SEERR_ARRIVAL_EXPANDED));
        let (lists, store) = (Arc::clone(&self.lists), Arc::clone(&self.core.settings));
        let (work, again) = (Arc::clone(&self.work), find.clone());
        let hub = Arc::clone(&self.hub);
        self.run(async move {
            // What the last start showed is there at once (the core's stash, no call); the live read replaces it.
            if lists
                .restore_home(dismissed.clone(), on, requests_on, again)
                .await
            {
                work.changed.fetch_add(1, Ordering::SeqCst);
            }
            let info = lists.load_home(dismissed, on, requests_on, find).await;
            if info.state != swiftly_vm::SeerrHomeState::Pending {
                let _ = KeyValueStore::set(&*store, &key, Value::Str(info.memory));
            }
            // Start stands: the first Seerr read of this start fills the stash for every other Seerr page (the core
            // runs it once at a time; the pages wait for it instead of reading the same calls again).
            hub.warm_up().await;
        });
    }

    /// Start follows its two switches at once (Settings > Darstellung > Startseite), not at the next read: "Meine Anfragen"
    /// is applied to the block as it stands (its requests are in already); the arrival banners need the library lookup, so
    /// switching them on reads the block again. Returns whether anything changed.
    pub fn follow_switches(&self) -> bool {
        let st = self.settings();
        let now = (Self::arrival_on(&st), Self::requests_rail_on(&st));
        let before = *self.applied.lock().unwrap_or_else(|e| e.into_inner());
        match before {
            Some(b) if b == now => false,
            None => false,
            Some((arrival, _)) if arrival != now.0 => {
                self.load_home();
                true
            }
            Some(_) => {
                self.lists.set_requests_enabled(now.1);
                *self.applied.lock().unwrap_or_else(|e| e.into_inner()) = Some(now);
                true
            }
        }
    }

    /// The X on the arrival banner: the core hides that request for good, the device keeps the ids.
    pub fn dismiss_arrival(&self, request_id: i64) {
        let ids = self.lists.dismiss_arrival(request_id);
        let _ = self.settings().set(
            &keys::SEERR_ARRIVAL_DISMISSED,
            ids.iter().map(i64::to_string).collect(),
        );
        // The core closes a stack of fewer than two cards: keep the stored state in step.
        let _ = self.settings().set(
            &keys::SEERR_ARRIVAL_EXPANDED,
            self.lists.home().arrivals_expanded,
        );
    }

    /// The one Profile entry for this account right now (the sections of the management page and what waits on them).
    pub fn entry(&self) -> Option<swiftly_vm::ProfileEntry> {
        crate::server_admin_link::entry_for(&self.core, &self.hub.info())
    }

    /// The click or select on the closed stack, or "Weniger anzeigen": the core opens or closes it, the device keeps the
    /// state (the core shows it open only with two or more cards).
    pub fn set_arrivals_expanded(&self, on: bool) {
        let info = self.lists.set_arrivals_expanded(on);
        let _ = self
            .settings()
            .set(&keys::SEERR_ARRIVAL_EXPANDED, info.arrivals_expanded);
    }

    /// The hub (account, rights, counts).
    pub fn hub(&self) -> &Arc<Hub> {
        &self.hub
    }

    /// The list screens.
    pub fn lists(&self) -> &Arc<Lists> {
        &self.lists
    }

    /// The administrator screens (queue, request detail, problems with their thread).
    pub fn admin(&self) -> &Arc<Admin> {
        &self.admin
    }

    /// The page of one title (`art` is `movie` or `tv`, `tmdb` its id).
    pub fn title(&self, art: &str, tmdb: i64) -> Arc<Title> {
        Title::new(Arc::clone(&self.hub), art.to_owned(), tmdb)
    }

    /// Runs one of the core's calls on the network runtime; the page draws again when it is done.
    pub fn run(&self, call: impl Future<Output = ()> + Send + 'static) {
        let work = Arc::clone(&self.work);
        work.pending.fetch_add(1, Ordering::SeqCst);
        self.core.spawn(async move {
            call.await;
            work.changed.fetch_add(1, Ordering::SeqCst);
            work.pending.fetch_sub(1, Ordering::SeqCst);
        });
    }

    /// Grows whenever a call came back.
    pub fn changed(&self) -> u64 {
        self.work.changed.load(Ordering::SeqCst)
    }

    /// A call is still out, so the screen keeps asking for frames.
    pub fn busy(&self) -> bool {
        self.work.pending.load(Ordering::SeqCst) > 0
    }
}

/// Where a Seerr entry point of the Profile or Start leads; the suite opens that page over the stack.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeerrRoute {
    /// "Meine Anfragen".
    Requests,
    /// "Verwaltung": the queue and the problems (only with the right to manage).
    Admin,
    /// "Verwaltung" on its reports tab.
    Issues,
}
