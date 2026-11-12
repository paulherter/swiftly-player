//! `DetailVm`: the page of one movie or episode (`ItemDetailView` of the Swift app).
//!
//! * The page opens with the list entry and is completed by the fresh title (`Items/{id}`);
//!   a failed fresh load keeps the entry, and Play is gray until the versions are known (the
//!   entry has no `MediaSources`). When the fresh load failed Play is enabled again: a press
//!   resolves the title ([`PlayAction::Resolve`]).
//! * Watched and watchlist switch at once and are put back with a readable reason when the
//!   server says no (`ItemDetailView.actionRail`).
//! * Cast, extras and similar titles arrive together once all of them are answered
//!   (`bottomPresent`); a failed "similar" fetch is told apart from an empty one.
//! * What a press on Play does is decided by [`DetailVm::play`]: ask for a version, start, or
//!   resolve the title first. The player itself is the host's business.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures_util::future::{join, join4};
use swiftly_jellyfin::{JellyfinClient, Watcher};
use swiftly_l10n::Arg;
use swiftly_library::{LibraryGenre, client_ext::collection_directory};
use swiftly_model::{DeliveryMethod, Item, MediaSource, MediaVersions, VersionStart};
use swiftly_net::{ErrorKind, HttpTransport, Url};
use swiftly_playback::device_profile::{DeviceProfile, Flavour};
use swiftly_playback::playback_plan::{PlanError, PlaybackPlan};

use crate::account::AccountRef;
use crate::bell::{Bell, Changed, part};
use crate::detail_more::{
    CollectionRailPart, DownloadField, DownloadState, FileExcerpt, MenuContext, MenuEntry,
    MenuKind, ProofPart, TrailerCandidate, WatcherTile, age_rating_text, file_excerpt, more_menu,
    rating_text, tile_menu, trailer_candidates,
};
use crate::home::{Client, build_client};
use crate::host::Host;
use crate::load_state::LoadFailure;
use crate::parts::{ImageRef, Tile};
use crate::plex::{Plex, build_plex_client, is_plex};
use crate::tile::{Words, grid_tile, plex_grid_tile};
use crate::title_text::{
    TitleText, addresses, header_image, logo_image, person_image, progress, resume_from,
    similar_cleaned, user_image, without_double,
};
use swiftly_images::ImageAddress;
use swiftly_playback::media_server::MediaServer;

const SIMILAR_LIMIT: usize = 12;
const CAST_LIMIT: usize = 12;

/// The head of the page.
#[derive(Debug, Clone, PartialEq)]
pub struct HeroPart {
    /// Version of the part.
    pub version: u64,
    /// Server id.
    pub id: String,
    /// The server's `Type`.
    pub kind: Option<String>,
    /// The title.
    pub title: String,
    /// Year, runtime and genre in one line.
    pub secondary_line: String,
    /// The head image.
    pub image: Option<ImageRef>,
    /// The title as a logo, if the server has one.
    pub logo: Option<ImageRef>,
    /// The description.
    pub overview: Option<String>,
    /// Directors, in order.
    pub directors: Vec<String>,
    /// Community rating (stars).
    pub community_rating: Option<f64>,
    /// Age rating as the server names it.
    pub age_rating: Option<String>,
    /// Why the first fresh load failed (the page then shows only the list entry); `None` while it
    /// has not failed. Unreachable, sign-in refused, server error or unreadable answer.
    pub failure: Option<LoadFailure>,
}

/// One version of a title to pick from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionOption {
    /// The media source id.
    pub id: String,
    /// The label ("4K", "Extended cut"); empty if the source has no name (the view shows the
    /// word "Fassung" then).
    pub name: String,
    /// What the choice shows (`MediaSource.versionLabel`): the name, or the word "Fassung" when
    /// it has none, then " · " and "2160p · HEVC · 18,6 GB" when that is not empty.
    pub label: String,
}

impl VersionOption {
    /// The option for a media source; `None` without an id.
    pub(crate) fn of(source: &MediaSource, words: &Words, language: &str) -> Option<Self> {
        let id = source.id.clone()?;
        let separator = crate::downloads_vm::decimal_separator(language);
        let name = source.version_name_with(words);
        let detail =
            source.version_detail(&|bytes| crate::downloads_vm::size_text(bytes, separator));
        Some(Self {
            id,
            label: if detail.is_empty() {
                name
            } else {
                format!("{name} · {detail}")
            },
            name: source.name.clone().unwrap_or_default(),
        })
    }
}

/// The main button.
#[derive(Debug, Clone, PartialEq)]
pub struct PlayButton {
    /// "Abspielen" or "Fortsetzen ab 1:23" in the user's language.
    pub label: String,
    /// False until the versions are known and while nothing can start.
    pub enabled: bool,
    /// "Noch 12 Min." under the button.
    pub remaining: Option<String>,
    /// Watched share under the button, 0 to 1.
    pub progress: Option<f32>,
    /// The heading of the version sheet ("Fassung wählen").
    pub version_title: String,
}

/// The play button and the two toggles.
#[derive(Debug, Clone, PartialEq)]
pub struct ActionsPart {
    /// Version of the part.
    pub version: u64,
    /// The main button.
    pub play: PlayButton,
    /// Watched.
    pub watched: bool,
    /// On the watchlist.
    pub favorite: bool,
    /// "Gemerkt" or "Merken".
    pub favorite_caption: String,
    /// Why the last toggle failed; cleared by the next one.
    pub toggle_error: Option<String>,
    /// The line under the title: Direct Play, rating, age rating.
    pub proof: ProofPart,
    /// The "Laden" field, where the feature is on and the title is no series.
    pub download: Option<DownloadField>,
    /// A hint strip for the user (trailer missing, metadata reread, ...); cleared by
    /// [`DetailIntent::DismissMessage`].
    pub message: Option<String>,
    /// Counts the effects queued for the host; moves this part so the host looks at
    /// [`DetailVm::take_effects`].
    pub effect_seq: u64,
}

/// A cast member.
#[derive(Debug, Clone, PartialEq)]
pub struct CastTile {
    /// Person id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Role.
    pub role: Option<String>,
    /// Portrait.
    pub image: Option<ImageRef>,
}

/// Everything below the description. Empty and `ready == false` until all of it is answered.
#[derive(Debug, Clone, PartialEq)]
pub struct BottomPart {
    /// Version of the part.
    pub version: u64,
    /// Everything has been answered; the view fades the sections in together.
    pub ready: bool,
    /// The first twelve cast members.
    pub cast: Vec<CastTile>,
    /// Extras (featurettes, scenes).
    pub extras: Vec<Tile>,
    /// Similar titles.
    pub similar: Vec<Tile>,
    /// The similar fetch failed and nothing is shown (retry offered).
    pub similar_failed: bool,
    /// Who has seen it (plugin, switch on); first row, quiet.
    pub watchers: Vec<WatcherTile>,
    /// "Part of the collection": at most two rows, above the similar titles.
    pub collections: Vec<CollectionRailPart>,
    /// The file excerpt at the very bottom; needs the playback plan.
    pub file: Option<FileExcerpt>,
}

/// What the host tells the page about itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetailOptions {
    /// The "Gesehen von" setting.
    pub watchers_shown: bool,
    /// A download button appears at all (switch and the account's right).
    pub download_button: bool,
    /// The bitrate limit sent with the playback request.
    pub max_bitrate: i64,
    /// A browser can open a trailer link.
    pub can_open_web: bool,
    /// What the menus need to know.
    pub menu: MenuContext,
}

impl Default for DetailOptions {
    fn default() -> Self {
        Self {
            watchers_shown: false,
            download_button: false,
            max_bitrate: 1_000_000_000,
            can_open_web: false,
            menu: MenuContext::default(),
        }
    }
}

/// Work for the host that the page cannot do itself.
#[derive(Debug, Clone, PartialEq)]
pub enum DetailEffect {
    /// Play a trailer file with this plan.
    PlayTrailer {
        /// The trailer.
        item: Box<Item>,
        /// How to open it.
        plan: Box<PlaybackPlan>,
    },
    /// Open a trailer page in the browser.
    OpenWeb(Url),
    /// A menu entry started playback (from the beginning, or resuming).
    Play(PlayAction),
    /// The press on the download field: the host decides between the sheet and the manager.
    OpenDownload,
    /// A menu entry only the host can carry out (play on another device, watch together,
    /// download, remove from "Continue Watching").
    Menu(MenuKind),
    /// The watched state changed on the server (a write succeeded); the lists around the page
    /// should reload.
    StateChanged,
    /// The watchlist changed on the server (a write succeeded).
    WatchlistChanged,
}

/// What a press on Play leads to.
#[derive(Debug, Clone, PartialEq)]
pub enum PlayAction {
    /// The versions are not known yet; the button is gray.
    Wait,
    /// The title carries no sources (the fresh load failed): fetch it and decide.
    Resolve {
        /// The title.
        item_id: String,
        /// Second to start at.
        since: f64,
    },
    /// Several versions: ask which.
    Choose {
        /// The title.
        item_id: String,
        /// Second to start at.
        since: f64,
        /// The versions.
        versions: Vec<VersionOption>,
    },
    /// Start now.
    Start {
        /// The title.
        item_id: String,
        /// Second to start at.
        since: f64,
        /// The picked version, if any.
        source_id: Option<String>,
    },
}

/// What the view asks for. Never blocks.
#[derive(Debug, Clone, PartialEq)]
pub enum DetailIntent {
    /// First appearance: the fresh title, then cast, extras and similar titles.
    Load,
    /// Back from the player or a state change: only the fresh title.
    Refresh,
    /// Watched or unwatched.
    SetWatched {
        /// The wanted state.
        on: bool,
    },
    /// On the watchlist or off.
    SetWatchlist {
        /// The wanted state.
        on: bool,
    },
    /// Fetch only the similar titles again.
    RetrySimilar,
    /// The host knows a copy of the title is on the device: Play starts it without asking.
    Downloaded {
        /// Whether a copy exists.
        on: bool,
    },
    /// What the host knows (settings, rights, devices).
    Options(Box<DetailOptions>),
    /// The state of the title in the download manager.
    DownloadState(DownloadState),
    /// A plan for the copy on the device; it replaces the server's plan.
    LocalPlan(Option<Box<PlaybackPlan>>),
    /// A press on the download field.
    DownloadPressed,
    /// A press on the trailer field.
    Trailer,
    /// A pick in the More panel or the Play button's long-press menu.
    Menu(MenuKind),
    /// The hint strip was dismissed.
    DismissMessage,
    /// Another account (or none: signed out).
    AccountSwitched {
        /// The new account, `None` for signed out.
        account: Option<AccountRef>,
    },
}

struct Live<T: HttpTransport + 'static> {
    switch: u64,
    /// The cache scope of the account on screen (`None`: signed out).
    scope: Option<swiftly_cache::Scope>,
    client: Option<Arc<Client<T>>>,
    /// A Plex account: the page asks Plex for the title, the plan and the lists.
    plex: Option<Arc<Plex<T>>>,
    /// The stored copy of the title from an earlier visit, without its `MediaSources`: it paints
    /// the page until the fresh answer arrives and never enables Play (only `fresh` does).
    cached: Option<Item>,
    fresh: Option<Item>,
    versions_failed: bool,
    /// What kind of failure `versions_failed` was (for the page's own error text).
    title_failure: Option<LoadFailure>,
    watched: bool,
    favorite: bool,
    downloaded: bool,
    toggle_error: Option<String>,
    similar: Vec<Item>,
    similar_failed: bool,
    extras: Vec<Item>,
    bottom_ready: bool,
    title_answered: bool,
    plan: Option<Arc<PlaybackPlan>>,
    local_plan: Option<Arc<PlaybackPlan>>,
    plan_present: bool,
    options: DetailOptions,
    download_state: DownloadState,
    message: Option<String>,
    effects: Vec<DetailEffect>,
    effect_seq: u64,
    watchers: Vec<Watcher>,
    collections: Vec<(Item, Vec<Item>)>,
    hero: Arc<HeroPart>,
    actions: Arc<ActionsPart>,
    bottom: Arc<BottomPart>,
}

struct Inner<T: HttpTransport + 'static> {
    transport: Arc<T>,
    host: Host,
    words: Words,
    text: TitleText,
    item: Item,
    bell: Arc<Bell>,
    live: Mutex<Live<T>>,
}

/// The detail view model of a movie or episode. Cheap to clone (a handle).
pub struct DetailVm<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: HttpTransport + 'static> Clone for DetailVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

/// One "Gesehen von" entry (page and series page).
pub(crate) fn watcher_tile(w: &Watcher, addresses: Option<&ImageAddress>) -> WatcherTile {
    WatcherTile {
        user_id: w.user_id.clone(),
        name: w.name.clone(),
        initial: w
            .name
            .chars()
            .next()
            .map(|c| c.to_uppercase().collect())
            .unwrap_or_default(),
        ring: w.ring(),
        play_count: w.play_count,
        last_watched: w.last_watched.clone(),
        watched_count: w.watched_count,
        total_count: w.total_count,
        image: w
            .image_tag
            .as_ref()
            .and_then(|tag| addresses.and_then(|a| user_image(&w.user_id, tag, a))),
    }
}

/// What a press does for `item`, with `downloaded` as the host knows it (`launch(since:)`).
pub(crate) fn play_action(
    item: &Item,
    downloaded: bool,
    since: f64,
    words: &Words,
    language: &str,
) -> PlayAction {
    let item_id = item.id.clone();
    match MediaVersions::start(item.media_sources.as_deref(), downloaded) {
        VersionStart::Choose(versions) => PlayAction::Choose {
            item_id,
            since,
            versions: versions
                .iter()
                .filter_map(|v| VersionOption::of(v, words, language))
                .collect(),
        },
        VersionStart::Play => PlayAction::Start {
            item_id,
            since,
            source_id: None,
        },
        VersionStart::Wait => PlayAction::Resolve { item_id, since },
    }
}

impl<T: HttpTransport + 'static> DetailVm<T> {
    /// A view model for `item` (the list entry the page was opened with) and `account` (or
    /// signed out). Nothing is loaded until [`DetailIntent::Load`].
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
    pub fn new(
        transport: Arc<T>,
        host: Host,
        item: Item,
        account: Option<AccountRef>,
    ) -> Result<Self, ErrorKind> {
        let (client, plex) = clients(&transport, &host, account.as_ref())?;
        let text = TitleText::new(host.locale.clone());
        let hero = HeroPart {
            version: 1,
            id: String::new(),
            kind: None,
            title: String::new(),
            secondary_line: String::new(),
            image: None,
            logo: None,
            overview: None,
            directors: Vec::new(),
            community_rating: None,
            age_rating: None,
            failure: None,
        };
        let live = Live {
            switch: 1,
            scope: account.as_ref().map(crate::cache::ViewCache::scope),
            client,
            plex,
            cached: None,
            fresh: None,
            versions_failed: false,
            title_failure: None,
            watched: item
                .user_data
                .as_ref()
                .and_then(|d| d.played)
                .unwrap_or(false),
            favorite: item
                .user_data
                .as_ref()
                .and_then(|d| d.is_favorite)
                .unwrap_or(false),
            downloaded: false,
            toggle_error: None,
            similar: Vec::new(),
            similar_failed: false,
            extras: Vec::new(),
            bottom_ready: false,
            title_answered: false,
            plan: None,
            local_plan: None,
            plan_present: false,
            options: DetailOptions::default(),
            download_state: DownloadState::Nothing,
            message: None,
            effects: Vec::new(),
            effect_seq: 0,
            watchers: Vec::new(),
            collections: Vec::new(),
            hero: Arc::new(hero),
            actions: Arc::new(ActionsPart {
                version: 1,
                play: PlayButton {
                    label: String::new(),
                    enabled: false,
                    remaining: None,
                    progress: None,
                    version_title: String::new(),
                },
                watched: false,
                favorite: false,
                favorite_caption: String::new(),
                toggle_error: None,
                proof: ProofPart {
                    visible: false,
                    direct_play: false,
                    hint: None,
                    rating: None,
                    age_rating: None,
                },
                download: None,
                message: None,
                effect_seq: 0,
            }),
            bottom: Arc::new(BottomPart {
                version: 1,
                ready: false,
                cast: Vec::new(),
                extras: Vec::new(),
                similar: Vec::new(),
                similar_failed: false,
                watchers: Vec::new(),
                collections: Vec::new(),
                file: None,
            }),
        };
        let inner = Arc::new(Inner {
            words: Words::new(host.locale.clone()),
            text,
            transport,
            host,
            item,
            bell: Bell::new(),
            live: Mutex::new(live),
        });
        {
            let mut live = inner.live();
            inner.publish(&mut live, true);
        }
        let vm = Self { inner };
        vm.watch_cache();
        Ok(vm)
    }

    /// An event naming this title (or the polling fallback) fetches it again; a burst reloads once.
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
            let (scope, named) = match change {
                swiftly_cache::CacheChange::ListsStale(s) => (s, true),
                swiftly_cache::CacheChange::ItemsChanged(s, ids) => {
                    (s, ids.contains(&inner.item.id))
                }
                swiftly_cache::CacheChange::ScopeDropped(_) => return true,
            };
            let own = inner.live().scope.clone();
            let now = inner.host.clock.now();
            let mut last = last.lock().unwrap_or_else(PoisonError::into_inner);
            if named && own.as_ref() == Some(scope) && now - *last >= 3.0 {
                *last = now;
                drop(last);
                Inner::start_fresh(&inner, false);
            }
            true
        });
    }

    /// The version of the view model; moves whenever a part is replaced.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The head part.
    pub fn hero(&self) -> Arc<HeroPart> {
        Arc::clone(&self.inner.live().hero)
    }

    /// The play button and toggles.
    pub fn actions(&self) -> Arc<ActionsPart> {
        Arc::clone(&self.inner.live().actions)
    }

    /// Cast, extras and similar titles.
    pub fn bottom(&self) -> Arc<BottomPart> {
        Arc::clone(&self.inner.live().bottom)
    }

    /// The playback plan the server gave (or the copy on the device); `None` until answered or
    /// when there is none. Starting with it saves the request on press.
    pub fn plan(&self) -> Option<Arc<PlaybackPlan>> {
        self.inner.live().plan.clone()
    }

    /// The title as the server's JSON (what the host's `Item` decodes): the fresh one, else the
    /// stored copy, else the list entry the page was opened with.
    pub fn item_json(&self) -> Option<String> {
        let live = self.inner.live();
        serde_json::to_string(self.inner.current(&live)).ok()
    }

    /// The host's work queued since the last call.
    pub fn take_effects(&self) -> Vec<DetailEffect> {
        std::mem::take(&mut self.inner.live().effects)
    }

    /// The entries of the More panel.
    pub fn more_menu(&self) -> Vec<MenuEntry> {
        let live = self.inner.live();
        let current = self.inner.current(&live);
        more_menu(
            &self.inner.text,
            current,
            live.plan.is_some(),
            &live.options.menu,
        )
    }

    /// The entries of the long press on the Play button (the title's tile menu).
    pub fn tile_menu(&self) -> Vec<MenuEntry> {
        let live = self.inner.live();
        let current = self.inner.current(&live);
        tile_menu(&self.inner.text, current, &live.options.menu)
    }

    /// Waits until the view model is newer than `seen`; names the parts that changed after it
    /// (`part::DETAIL_HERO`, `part::DETAIL_ACTIONS`, `part::DETAIL_BOTTOM`).
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`DetailVm::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// What a press on Play does now: from the resume point when there is one, else from the
    /// start. `Wait` while the button is gray. `pick` is the version the user chose; with it the
    /// press starts that version.
    pub fn play(&self, pick: Option<&str>) -> PlayAction {
        let live = self.inner.live();
        let current = self.inner.current(&live);
        if !self.inner.versions_known(&live, current) {
            return PlayAction::Wait;
        }
        let since = resume_from(current).unwrap_or(0.0);
        if let Some(source) = pick {
            return PlayAction::Start {
                item_id: current.id.clone(),
                since,
                source_id: Some(source.to_owned()),
            };
        }
        play_action(
            current,
            live.downloaded,
            since,
            &self.inner.words,
            self.inner.text.locale().language(),
        )
    }

    /// Like [`DetailVm::play`], but from the beginning ("Play from start" in the More panel).
    pub fn play_from_start(&self, pick: Option<&str>) -> PlayAction {
        match self.play(pick) {
            PlayAction::Choose {
                item_id, versions, ..
            } => PlayAction::Choose {
                item_id,
                since: 0.0,
                versions,
            },
            PlayAction::Start {
                item_id, source_id, ..
            } => PlayAction::Start {
                item_id,
                since: 0.0,
                source_id,
            },
            PlayAction::Resolve { item_id, .. } => PlayAction::Resolve {
                item_id,
                since: 0.0,
            },
            PlayAction::Wait => PlayAction::Wait,
        }
    }

    /// An intent from the view. Never blocks.
    pub fn send(&self, intent: DetailIntent) {
        let inner = &self.inner;
        match intent {
            DetailIntent::Load => Inner::start_fresh(inner, true),
            DetailIntent::Refresh => Inner::start_fresh(inner, false),
            DetailIntent::SetWatched { on } => Inner::toggle(inner, on, false),
            DetailIntent::SetWatchlist { on } => Inner::toggle(inner, on, true),
            DetailIntent::RetrySimilar => Inner::retry_similar(inner),
            DetailIntent::Downloaded { on } => {
                let mut live = inner.live();
                live.downloaded = on;
                inner.publish(&mut live, false);
            }
            DetailIntent::Options(options) => {
                let mut live = inner.live();
                live.options = *options;
                inner.publish(&mut live, false);
            }
            DetailIntent::DownloadState(state) => {
                let mut live = inner.live();
                live.download_state = state;
                inner.publish(&mut live, false);
            }
            DetailIntent::LocalPlan(plan) => {
                let mut live = inner.live();
                live.local_plan = plan.map(|p| Arc::new(*p));
                live.plan = live.local_plan.clone().or(live.plan.take());
                inner.publish(&mut live, false);
            }
            DetailIntent::DownloadPressed => {
                let mut live = inner.live();
                inner.queue(&mut live, DetailEffect::OpenDownload);
            }
            DetailIntent::DismissMessage => {
                let mut live = inner.live();
                live.message = None;
                inner.publish(&mut live, false);
            }
            DetailIntent::Trailer => Inner::trailer(inner),
            DetailIntent::Menu(kind) => Inner::menu(inner, kind),
            DetailIntent::AccountSwitched { account } => Inner::switch_account(inner, account),
        }
    }
}

impl<T: HttpTransport + 'static> Inner<T> {
    fn live(&self) -> MutexGuard<'_, Live<T>> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn current<'a>(&'a self, live: &'a Live<T>) -> &'a Item {
        live.fresh
            .as_ref()
            .or(live.cached.as_ref())
            .unwrap_or(&self.item)
    }

    /// The versions are known, or a copy on the device decides (`versionsKnown`).
    fn versions_known(&self, live: &Live<T>, current: &Item) -> bool {
        live.versions_failed
            || live.fresh.is_some()
            || MediaVersions::start(current.media_sources.as_deref(), live.downloaded)
                != VersionStart::Wait
    }

    /// Rebuilds the parts and moves the version for the ones that differ.
    fn publish(&self, live: &mut Live<T>, first: bool) {
        let current = self.current(live);
        let server = live.server();
        let addresses = server.as_ref().and_then(Server::addresses);
        let hero = HeroPart {
            version: live.hero.version,
            id: current.id.clone(),
            kind: current.type_.clone(),
            title: current.name.clone(),
            secondary_line: self.text.secondary_line(current),
            image: match &live.plex {
                Some(plex) => plex_image(plex, current, swiftly_plex::ImageKind::Background),
                None => addresses
                    .as_ref()
                    .and_then(|a| header_image(current, None, a)),
            },
            logo: match &live.plex {
                Some(plex) => plex_image(plex, current, swiftly_plex::ImageKind::Logo),
                None => addresses.as_ref().and_then(|a| logo_image(current, a)),
            },
            overview: current.overview.clone().filter(|o| !o.is_empty()),
            directors: current
                .direction()
                .iter()
                .map(|d| (*d).to_owned())
                .collect(),
            community_rating: current.community_rating,
            age_rating: current.official_rating.clone().filter(|r| !r.is_empty()),
            failure: if live.fresh.is_none() {
                live.title_failure
            } else {
                None
            },
        };
        let play = PlayButton {
            label: match resume_from(current) {
                Some(since) => self
                    .text
                    .with("Fortsetzen ab %@", &[Arg::Str(self.text.time_text(since))]),
                None => self.text.key("Abspielen"),
            },
            enabled: server.is_some() && self.versions_known(live, current),
            remaining: self.text.remaining(current),
            progress: progress(current),
            version_title: self.text.key("Fassung wählen"),
        };
        let actions = ActionsPart {
            version: live.actions.version,
            play,
            watched: live.watched,
            favorite: live.favorite,
            favorite_caption: self
                .text
                .key(if live.favorite { "Gemerkt" } else { "Merken" }),
            toggle_error: live.toggle_error.clone(),
            proof: ProofPart {
                visible: live.plan_present,
                direct_play: live.plan.as_ref().is_some_and(|p| p.is_lossless()),
                hint: live
                    .plan
                    .as_ref()
                    .filter(|p| !p.is_lossless())
                    .map(|p| p.method.raw_value().to_owned()),
                rating: current.community_rating.map(rating_text),
                age_rating: age_rating_text(&self.text, current.official_rating.clone()),
            },
            download: (live.options.download_button && current.type_.as_deref() != Some("Series"))
                .then(|| DownloadField {
                    state: live.download_state,
                    caption: self.text.key("Laden"),
                }),
            message: live.message.clone(),
            effect_seq: live.effect_seq,
        };
        let bottom = match (&server, live.bottom_ready && live.title_answered) {
            (Some(client), true) => BottomPart {
                version: live.bottom.version,
                ready: true,
                cast: current
                    .actors()
                    .into_iter()
                    .take(CAST_LIMIT)
                    .map(|p| CastTile {
                        id: p.id.clone(),
                        name: p.name.clone(),
                        role: p.role.clone(),
                        image: addresses
                            .as_ref()
                            .and_then(|a| person_image(&p.id, p.primary_image_tag.as_deref(), a)),
                    })
                    .collect(),
                extras: live
                    .extras
                    .iter()
                    .map(|i| client.tile(i, &self.words))
                    .collect(),
                similar: live
                    .similar
                    .iter()
                    .map(|i| client.tile(i, &self.words))
                    .collect(),
                similar_failed: live.similar_failed,
                watchers: live
                    .watchers
                    .iter()
                    .map(|w| watcher_tile(w, addresses.as_ref()))
                    .collect(),
                collections: live
                    .collections
                    .iter()
                    .map(|(c, members)| CollectionRailPart {
                        id: c.id.clone(),
                        title: c.name.clone(),
                        tiles: members
                            .iter()
                            .map(|i| client.tile(i, &self.words))
                            .collect(),
                    })
                    .collect(),
                file: live
                    .plan
                    .as_ref()
                    .and_then(|p| p.source.as_ref())
                    .map(|src| file_excerpt(&self.text, src, self.host.locale.language())),
            },
            _ => BottomPart {
                version: live.bottom.version,
                ready: false,
                cast: Vec::new(),
                extras: Vec::new(),
                similar: Vec::new(),
                similar_failed: false,
                watchers: Vec::new(),
                collections: Vec::new(),
                file: None,
            },
        };
        let changed = [
            first || hero != *live.hero,
            first || actions != *live.actions,
            first || bottom != *live.bottom,
        ];
        if !changed.iter().any(|c| *c) {
            return;
        }
        let indices: Vec<usize> = (0..3).filter(|i| changed[*i]).collect();
        let version = self.bell.bump(&indices);
        if changed[0] {
            live.hero = Arc::new(HeroPart { version, ..hero });
        }
        if changed[1] {
            live.actions = Arc::new(ActionsPart { version, ..actions });
        }
        if changed[2] {
            live.bottom = Arc::new(BottomPart { version, ..bottom });
        }
        const {
            assert!(
                part::DETAIL_HERO == 1 << 0
                    && part::DETAIL_ACTIONS == 1 << 1
                    && part::DETAIL_BOTTOM == 1 << 2
            );
        }
    }

    /// The fresh title; with `all` also cast, extras and similar titles (`.task` versus
    /// `refresh()`).
    fn start_fresh(self: &Arc<Self>, all: bool) {
        let mut live = self.live();
        let Some(client) = live.server() else {
            self.publish(&mut live, false);
            return;
        };
        let jelly = live.client.clone();
        let switch = live.switch;
        // Paint the stored copy of the title (once per visit) while the fresh one is on its way.
        let remembered = self
            .host
            .cache
            .clone()
            .zip(live.scope.clone())
            .map(|(cache, scope)| {
                let ticket = cache.ticket(&scope);
                (cache, scope, ticket)
            });
        if let Some((cache, scope, _)) = &remembered
            && live.fresh.is_none()
            && live.cached.is_none()
            && let Some(mut stored) = cache.read_title(scope, &self.item.id)
        {
            stored.media_sources = None;
            live.cached = Some(stored);
            self.publish(&mut live, false);
        }
        drop(live);
        let inner = Arc::clone(self);
        let c = client.clone();
        self.host.spawner.spawn(Box::pin(async move {
            let (bitrate, local) = {
                let live = inner.live();
                (live.options.max_bitrate, live.local_plan.clone())
            };
            let (answer, planned) = join(c.item(&inner.item.id), async {
                match local {
                    Some(p) => Ok(Some((*p).clone())),
                    None => c.plan(&inner.item.id, bitrate, None).await,
                }
            })
            .await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            // The plan is replaced even by "none" (a refresh asks again), the page shows the
            // proof row once it is answered.
            live.plan = planned.ok().flatten().map(Arc::new);
            live.title_answered = true;
            live.plan_present = true;
            match answer {
                Ok(fresh) => {
                    if let Some((cache, _, ticket)) = &remembered {
                        cache.write_title(ticket, &fresh);
                    }
                    live.fresh = Some(fresh);
                    if all {
                        live.versions_failed = false;
                        live.title_failure = None;
                    }
                }
                // A failed refresh keeps the title shown so far; a failed first load enables
                // Play again so that a press tries once more.
                Err(e) if all => {
                    live.versions_failed = true;
                    live.title_failure = Some(LoadFailure::from_error(&e));
                }
                Err(_) => {}
            }
            if live.fresh.is_some() {
                let data = live.fresh.as_ref().and_then(|f| f.user_data.clone());
                live.favorite = data.as_ref().and_then(|d| d.is_favorite).unwrap_or(false);
                live.watched = data.as_ref().and_then(|d| d.played).unwrap_or(false);
            }
            inner.publish(&mut live, false);
        }));
        if all {
            let inner = Arc::clone(self);
            self.host.spawner.spawn(Box::pin(async move {
                let own = inner.item.clone();
                let watchers_on = inner.live().options.watchers_shown;
                let (similar, extras, collections, watchers) = join4(
                    client.similar(&own.id, i64::try_from(SIMILAR_LIMIT).unwrap_or(12)),
                    client.extras(&own.id),
                    async { client.collection_rails(&own).await },
                    // Plex keeps no list of who watched a title.
                    async {
                        match &jelly {
                            Some(j) if watchers_on => j.watchers(&own.id).await.unwrap_or_default(),
                            _ => Vec::new(),
                        }
                    },
                )
                .await;
                let mut live = inner.live();
                if live.switch != switch {
                    return;
                }
                live.collections = collections;
                live.watchers = watchers;
                live.similar_failed = similar.is_err() && live.similar.is_empty();
                if let Ok(raw) = similar {
                    live.similar = without_double(&similar_cleaned(&raw, &own, SIMILAR_LIMIT));
                }
                // Extras are not a section with a statement: if missing, the row is missing.
                live.extras = extras.unwrap_or_default();
                live.bottom_ready = true;
                inner.publish(&mut live, false);
            }));
        }
    }

    fn retry_similar(self: &Arc<Self>) {
        let live = self.live();
        let Some(client) = live.server() else {
            return;
        };
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let own = inner.item.clone();
            let answer = client
                .similar(&own.id, i64::try_from(SIMILAR_LIMIT).unwrap_or(12))
                .await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            live.similar_failed = answer.is_err();
            if let Ok(raw) = answer {
                live.similar = without_double(&similar_cleaned(&raw, &own, SIMILAR_LIMIT));
            }
            inner.publish(&mut live, false);
        }));
    }

    /// Switch at once, ask the server, put it back with the reason if it says no.
    fn toggle(self: &Arc<Self>, on: bool, watchlist: bool) {
        let mut live = self.live();
        let Some(client) = live.server() else {
            live.toggle_error = Some(self.words.title("Nicht angemeldet."));
            self.publish(&mut live, false);
            return;
        };
        live.toggle_error = None;
        if watchlist {
            live.favorite = on;
        } else {
            live.watched = on;
        }
        let switch = live.switch;
        let id = self.item.id.clone();
        self.publish(&mut live, false);
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let done = client.set_flag(&id, on, watchlist).await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            if let Err(e) = done {
                if watchlist {
                    live.favorite = !on;
                } else {
                    live.watched = !on;
                }
                live.toggle_error = Some(inner.words.error(&e));
                inner.publish(&mut live, false);
            } else {
                // The write reached the server: other pages reload on this.
                let effect = if watchlist {
                    DetailEffect::WatchlistChanged
                } else {
                    DetailEffect::StateChanged
                };
                inner.queue(&mut live, effect);
            }
        }));
    }

    fn queue(&self, live: &mut Live<T>, effect: DetailEffect) {
        live.effects.push(effect);
        live.effect_seq += 1;
        self.publish(live, false);
    }

    fn say(&self, live: &mut Live<T>, text: String) {
        live.message = Some(text);
        self.publish(live, false);
    }

    /// Server trailers first, then the linked one; the first that gets a plan plays
    /// (`TrailerStart.start`). Only when nothing is left to try does a failed plan say so.
    fn trailer(self: &Arc<Self>) {
        let live = self.live();
        let Some(client) = live.server() else {
            drop(live);
            let mut live = self.live();
            self.say(&mut live, self.words.title("Nicht angemeldet."));
            return;
        };
        let current = self.current(&live).clone();
        let (bitrate, web) = (live.options.max_bitrate, live.options.can_open_web);
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let files = client.trailers(&current.id).await.unwrap_or_default();
            let candidates = trailer_candidates(&files, current.remote_trailers.as_deref(), web);
            let last = candidates.len().saturating_sub(1);
            let mut tried = false;
            let mut outcome: Option<DetailEffect> = None;
            let mut failure: Option<String> = None;
            for (index, candidate) in candidates.into_iter().enumerate() {
                match candidate {
                    TrailerCandidate::File(film) => {
                        tried = true;
                        match client.plan(&film.id, bitrate, None).await {
                            Ok(Some(plan)) => {
                                outcome = Some(DetailEffect::PlayTrailer {
                                    item: film,
                                    plan: Box::new(plan),
                                });
                                break;
                            }
                            Ok(None) => {}
                            Err(e) if index == last => failure = Some(inner.words.error(&e)),
                            Err(_) => {}
                        }
                    }
                    TrailerCandidate::Web(url) => {
                        outcome = Some(DetailEffect::OpenWeb(url));
                        break;
                    }
                }
            }
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            match outcome {
                Some(effect) => inner.queue(&mut live, effect),
                None if !tried => {
                    let text = inner.text.key("Für diesen Titel liegt kein Trailer vor.");
                    inner.say(&mut live, text);
                }
                None => {
                    if let Some(text) = failure {
                        inner.say(&mut live, text);
                    }
                }
            }
        }));
    }

    /// A pick in the More panel or the tile menu.
    fn menu(self: &Arc<Self>, kind: MenuKind) {
        match kind {
            MenuKind::PlayFromStart | MenuKind::Play => {
                let vm = DetailVm {
                    inner: Arc::clone(self),
                };
                let action = if kind == MenuKind::Play {
                    vm.play(None)
                } else {
                    vm.play_from_start(None)
                };
                let mut live = self.live();
                self.queue(&mut live, DetailEffect::Play(action));
            }
            MenuKind::MarkWatched => Self::toggle(self, true, false),
            MenuKind::MarkUnwatched => Self::toggle(self, false, false),
            MenuKind::ResetProgress => self.reset_progress(),
            MenuKind::RefreshMetadata => self.refresh_metadata(),
            other => {
                let mut live = self.live();
                self.queue(&mut live, DetailEffect::Menu(other));
            }
        }
    }

    /// "Fortschritt zurücksetzen": watched off, then say so and reload the title.
    fn reset_progress(self: &Arc<Self>) {
        let live = self.live();
        let Some(client) = live.server() else {
            drop(live);
            let mut live = self.live();
            self.say(&mut live, self.words.title("Nicht angemeldet."));
            return;
        };
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let done = client.set_flag(&inner.item.id, false, false).await;
            {
                let mut live = inner.live();
                if live.switch != switch {
                    return;
                }
                match done {
                    Err(e) => {
                        let text = inner.words.error(&e);
                        inner.say(&mut live, text);
                        return;
                    }
                    Ok(()) => {
                        let text = inner.text.key("Der Fortschritt ist zurückgesetzt.");
                        inner.say(&mut live, text);
                        inner.queue(&mut live, DetailEffect::StateChanged);
                    }
                }
            }
            Inner::start_fresh(&inner, false);
        }));
    }

    fn refresh_metadata(self: &Arc<Self>) {
        let live = self.live();
        let Some(client) = live.server() else {
            drop(live);
            let mut live = self.live();
            self.say(&mut live, self.words.title("Nicht angemeldet."));
            return;
        };
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let done = client.metadata_refresh(&inner.item.id).await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            let text = match done {
                Ok(()) => inner.text.key("Der Server liest die Metadaten neu ein."),
                Err(e) => inner.words.error(&e),
            };
            inner.say(&mut live, text);
        }));
    }

    fn switch_account(self: &Arc<Self>, account: Option<AccountRef>) {
        {
            let mut live = self.live();
            live.switch += 1;
            live.scope = account.as_ref().map(crate::cache::ViewCache::scope);
            (live.client, live.plex) =
                clients(&self.transport, &self.host, account.as_ref()).unwrap_or((None, None));
            live.cached = None;
            live.fresh = None;
            live.versions_failed = false;
            live.title_failure = None;
            live.toggle_error = None;
            live.similar.clear();
            live.similar_failed = false;
            live.extras.clear();
            live.bottom_ready = false;
            live.title_answered = false;
            live.plan = None;
            live.plan_present = false;
            live.watchers.clear();
            live.collections.clear();
            live.message = None;
            live.effects.clear();
            let data = self.item.user_data.clone();
            live.watched = data.as_ref().and_then(|d| d.played).unwrap_or(false);
            live.favorite = data.as_ref().and_then(|d| d.is_favorite).unwrap_or(false);
            self.publish(&mut live, false);
        }
        self.start_fresh(true);
    }
}

/// The playback plan for a title, the way the page asks for it (`AppModel.plan(for:)` with the
/// VLC profile). `Ok(None)`: the server names no source (a series). A rejection is the error.
pub(crate) async fn fetch_plan<T: HttpTransport>(
    client: &JellyfinClient<T>,
    item_id: &str,
    max_bitrate: i64,
    source_id: Option<&str>,
) -> Result<Option<PlaybackPlan>, ErrorKind> {
    // The page only describes the delivery; the start asks again with the engine's own flavour.
    fetch_plan_for(
        client,
        item_id,
        DeviceProfile::vlc(max_bitrate),
        source_id,
        None,
    )
    .await
}

/// The same with the profile of the engine that will play (Aether: `vlc`, AVPlayer: `airplay`).
pub async fn fetch_plan_for<T: HttpTransport>(
    client: &JellyfinClient<T>,
    item_id: &str,
    profile: DeviceProfile,
    source_id: Option<&str>,
    dv10: Option<(Flavour, swiftly_playback::dolby_vision::HostDecoders)>,
) -> Result<Option<PlaybackPlan>, ErrorKind> {
    let profile = &profile;
    let ask = |allow_direct: bool| async move {
        let info = client
            .playback_info_with(
                item_id,
                profile,
                profile.max_streaming_bitrate,
                None,
                None,
                source_id,
                allow_direct,
            )
            .await?;
        PlaybackPlan::make(
            &info,
            item_id,
            profile,
            |id, source, session| {
                client
                    .stream_url(id, source, session)
                    .map(|u| u.to_string())
                    .map_err(|_| PlanError::InvalidServerUrl)
            },
            client.base_url().as_str(),
            source_id,
        )
        .map_err(|e| match e {
            PlanError::PlaybackRejected(r) => ErrorKind::PlaybackRejected(r),
            PlanError::InvalidServerUrl => ErrorKind::InvalidServerUrl,
        })
    };
    let plan = ask(true).await?;
    // AV1 Dolby Vision 10.0 on a device that would show a green picture: ask the server again with
    // direct play and direct stream off, so it transcodes (tone-mapped HEVC/H.264). Every other
    // title, and a server that cannot or may not transcode, keeps the first answer (the engine
    // then refuses the title with its message).
    if let (Some((flavour, host)), Some(first)) = (dv10, plan.as_ref())
        && first.method != DeliveryMethod::Transcode
        && first.source.as_ref().is_some_and(|s| {
            swiftly_playback::dolby_vision::needs_server_transcode(s, flavour, host)
        })
        && let Ok(Some(second)) = ask(false).await
        && second.method == DeliveryMethod::Transcode
    {
        return Ok(Some(second));
    }
    Ok(plan)
}

/// A new plan that names `subtitle`, for a plan that transcodes and needs it
/// ([`swiftly_playback::transcode_subtitle::delivery`] says `Replan`): a bitmap track is asked as `Encode`
/// (the server burns it into the picture), any other choice just names the index (so a burned track
/// goes away again). The version stays and direct play stays off, since the plan transcodes already.
/// `None`: nothing to do, the server failed or no longer transcodes; the caller keeps its plan.
pub async fn replan_for_subtitle<T: HttpTransport>(
    client: &JellyfinClient<T>,
    item_id: &str,
    profile: &DeviceProfile,
    plan: &PlaybackPlan,
    streams: &[swiftly_model::MediaStream],
    subtitle: i64,
) -> Option<PlaybackPlan> {
    use swiftly_playback::transcode_subtitle::{SubtitleDelivery, delivery, is_bitmap};
    if delivery(
        plan.method == DeliveryMethod::Transcode,
        &plan.url,
        streams,
        subtitle,
    ) != SubtitleDelivery::Replan
    {
        return None;
    }
    let bitmap = streams
        .iter()
        .find(|s| s.index == Some(subtitle))
        .and_then(|s| s.codec.as_deref())
        .is_some_and(is_bitmap);
    let burning;
    let profile = if bitmap {
        burning = profile.burning_bitmap_subtitles();
        &burning
    } else {
        profile
    };
    let source_id = plan.media_source_id.as_deref();
    let info = client
        .playback_info_with(
            item_id,
            profile,
            profile.max_streaming_bitrate,
            None,
            Some(subtitle),
            source_id,
            false,
        )
        .await
        .ok()?;
    let again = PlaybackPlan::make(
        &info,
        item_id,
        profile,
        |id, source, session| {
            client
                .stream_url(id, source, session)
                .map(|u| u.to_string())
                .map_err(|_| PlanError::InvalidServerUrl)
        },
        client.base_url().as_str(),
        source_id,
    )
    .ok()??;
    (again.method == DeliveryMethod::Transcode).then_some(again)
}

/// The same rows on Plex: the collections of the movie and series libraries with their
/// members (`PlexClient.collectionDirectory`), at most two that hold the title.
async fn plex_collection_rails<T: HttpTransport + 'static>(
    client: &Plex<T>,
    title: &Item,
) -> Vec<(Item, Vec<Item>)> {
    let Some(art) = LibraryGenre::art_to_type(title.type_.as_deref()) else {
        return Vec::new();
    };
    let Ok(directory) = MediaServer::collection_directory(client, &[]).await else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for collection in directory.collections_with(title).into_iter().take(2) {
        let Ok(list) = client.collection_items(collection.id()).await else {
            continue;
        };
        let in_section: Vec<Item> = list
            .into_iter()
            .filter(|m| LibraryGenre::art_to_type(m.type_.as_deref()) == Some(art))
            .collect();
        let other: Vec<Item> = without_double(&in_section)
            .into_iter()
            .filter(|i| i.id != title.id)
            .collect();
        if !other.is_empty() {
            found.push((collection.item.clone(), other));
        }
    }
    found
}

/// "Part of the collection": at most two rows of the other titles of the collections this
/// title is in (`AppModel.collectionRails`). Any failure leaves the row out.
async fn collection_rails<T: HttpTransport>(
    client: &JellyfinClient<T>,
    title: &Item,
) -> Vec<(Item, Vec<Item>)> {
    let Some(art) = LibraryGenre::art_to_type(title.type_.as_deref()) else {
        return Vec::new();
    };
    let Ok(views) = client.user_views(true).await else {
        return Vec::new();
    };
    let Ok(directory) = collection_directory(client, &views).await else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for collection in directory.collections_with(title).into_iter().take(2) {
        let Ok(list) = client.collection_members(collection.id()).await else {
            continue;
        };
        let in_section: Vec<Item> = list
            .into_iter()
            .filter(|m| LibraryGenre::art_to_type(m.type_.as_deref()) == Some(art))
            .collect();
        let other: Vec<Item> = without_double(&in_section)
            .into_iter()
            .filter(|i| i.id != title.id)
            .collect();
        if !other.is_empty() {
            found.push((collection.item.clone(), other));
        }
    }
    found
}

/// The server the page talks to: the same questions, asked of Jellyfin/Emby or of Plex.
pub(crate) enum Server<T: HttpTransport + 'static> {
    Jelly(Arc<Client<T>>),
    Plex(Arc<Plex<T>>),
}

impl<T: HttpTransport + 'static> Clone for Server<T> {
    fn clone(&self) -> Self {
        match self {
            Self::Jelly(c) => Self::Jelly(Arc::clone(c)),
            Self::Plex(c) => Self::Plex(Arc::clone(c)),
        }
    }
}

impl<T: HttpTransport + 'static> Live<T> {
    pub(crate) fn server(&self) -> Option<Server<T>> {
        self.plex
            .clone()
            .map(Server::Plex)
            .or_else(|| self.client.clone().map(Server::Jelly))
    }
}

impl<T: HttpTransport + 'static> Server<T> {
    /// The image addresses of the server (`ImageAddress` knows the Plex path scheme, and a
    /// person's `thumb` there is already a full address).
    pub(crate) fn addresses(&self) -> Option<ImageAddress> {
        match self {
            Self::Jelly(c) => addresses(&**c),
            Self::Plex(c) => Some(ImageAddress::new(
                c.base_url(),
                Some(c.access_token()),
                swiftly_jellyfin::ServerKind::Plex,
            )),
        }
    }

    pub(crate) async fn seasons(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        match self {
            Self::Jelly(c) => c.seasons(id).await,
            Self::Plex(c) => MediaServer::seasons(&**c, id).await,
        }
    }

    pub(crate) async fn episodes(
        &self,
        id: &str,
        season: Option<&str>,
    ) -> Result<Vec<Item>, ErrorKind> {
        match self {
            Self::Jelly(c) => c.episodes(id, season).await,
            Self::Plex(c) => MediaServer::episodes(&**c, id, season).await,
        }
    }

    /// Where the viewer is in a series (`stateInSeries`).
    pub(crate) async fn state_in_series(&self, id: &str) -> Option<Item> {
        match self {
            Self::Jelly(c) => swiftly_library::client_ext::state_in_series(&**c, id).await,
            Self::Plex(c) => MediaServer::state_in_series(&**c, id).await,
        }
    }

    pub(crate) async fn collection_rails(&self, title: &Item) -> Vec<(Item, Vec<Item>)> {
        match self {
            Self::Jelly(c) => collection_rails(&**c, title).await,
            Self::Plex(c) => plex_collection_rails(&**c, title).await,
        }
    }

    pub(crate) fn tile(&self, item: &Item, words: &Words) -> Tile {
        match self {
            Self::Jelly(c) => grid_tile(item, &**c, words),
            Self::Plex(c) => plex_grid_tile(item, &**c, words),
        }
    }

    pub(crate) async fn item(&self, id: &str) -> Result<Item, ErrorKind> {
        match self {
            Self::Jelly(c) => c.item(id).await,
            Self::Plex(c) => MediaServer::item(&**c, id).await,
        }
    }

    pub(crate) async fn similar(&self, id: &str, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        match self {
            Self::Jelly(c) => c.similar(id, limit).await,
            Self::Plex(c) => MediaServer::similar(&**c, id, limit).await,
        }
    }

    pub(crate) async fn extras(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        match self {
            Self::Jelly(c) => c.extras(id).await,
            Self::Plex(c) => MediaServer::extras(&**c, id).await,
        }
    }

    pub(crate) async fn trailers(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        match self {
            Self::Jelly(c) => c.trailers(id).await,
            Self::Plex(c) => MediaServer::trailer(&**c, id).await,
        }
    }

    /// The plan: Jellyfin negotiates with the VLC profile, Plex plays the file directly.
    pub(crate) async fn plan(
        &self,
        id: &str,
        max_bitrate: i64,
        source_id: Option<&str>,
    ) -> Result<Option<PlaybackPlan>, ErrorKind> {
        match self {
            Self::Jelly(c) => fetch_plan(&**c, id, max_bitrate, source_id).await,
            Self::Plex(c) => c
                .plan_for(id, source_id, None, None)
                .await
                .map(Some)
                .map_err(|e| e.into_kind()),
        }
    }

    /// The episode after `id` in its series (`AppModel.episodePost` without the downloads).
    pub(crate) async fn episode_post(&self, id: &str, series: &str) -> Option<Item> {
        match self {
            Self::Jelly(c) => c.episode_post(id, series).await.ok().flatten(),
            Self::Plex(c) => MediaServer::episode_post(&**c, id, series)
                .await
                .ok()
                .flatten(),
        }
    }

    /// Watched (`watchlist == false`) or the watchlist flag.
    pub(crate) async fn set_flag(
        &self,
        id: &str,
        on: bool,
        watchlist: bool,
    ) -> Result<(), ErrorKind> {
        match (self, watchlist) {
            (Self::Jelly(c), true) => c.set_watchlist(id, on).await,
            (Self::Jelly(c), false) => c.set_watched(id, on).await,
            (Self::Plex(c), true) => c.set_favorite(id, on).await.map_err(|e| e.into_kind()),
            (Self::Plex(c), false) => c.set_watched_key(id, on).await.map_err(|e| e.into_kind()),
        }
    }

    pub(crate) async fn metadata_refresh(&self, id: &str) -> Result<(), ErrorKind> {
        match self {
            Self::Jelly(c) => c.metadata_refresh(id).await,
            Self::Plex(c) => MediaServer::metadata_refresh(&**c, id).await,
        }
    }
}

pub(crate) type Clients<T> = (Option<Arc<Client<T>>>, Option<Arc<Plex<T>>>);

pub(crate) fn clients<T: HttpTransport + 'static>(
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

/// A head or logo picture of a Plex title.
fn plex_image(
    plex: &Plex<impl HttpTransport + 'static>,
    item: &Item,
    kind: swiftly_plex::ImageKind,
) -> Option<ImageRef> {
    let logo = kind == swiftly_plex::ImageKind::Logo;
    let (height, width) = if logo { (200, 400) } else { (675, 1200) };
    plex.image_url_for(item, kind, Some(height), Some(width))
        .map(|url| ImageRef {
            address: url.to_string(),
            kind: if logo {
                crate::parts::ImageKind::Poster
            } else {
                crate::parts::ImageKind::Backdrop
            },
            wanted_width: u32::try_from(width).unwrap_or(0),
            wanted_height: u32::try_from(height).unwrap_or(0),
        })
}
