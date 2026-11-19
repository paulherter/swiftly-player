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

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures_util::future::{join, join_all, join4};
use swiftly_jellyfin::{JellyfinClient, Watcher};
use swiftly_l10n::Arg;
use swiftly_library::{CollectionDirectory, LibraryGenre, client_ext::collection_directory};
use swiftly_model::{DeliveryMethod, Item, MediaSource, MediaVersions, VersionStart};
use swiftly_net::{ErrorKind, HttpTransport, Url};
use swiftly_playback::device_profile::{DeviceProfile, Flavour};
use swiftly_playback::playback_plan::{PlanError, PlaybackPlan};

use crate::account::AccountRef;
use crate::bell::{Bell, Changed, part};
use crate::detail_more::{
    CollectionRailPart, DownloadField, DownloadState, FileExcerpt, MenuContext, MenuEntry,
    MenuKind, ProofPart, ProofPhase, TrailerCandidate, WatcherTile, age_rating_text, file_excerpt,
    more_menu, rating_text, tile_menu, trailer_candidates,
};
use crate::home::{Client, build_client};
use crate::host::Host;
use crate::load_state::LoadFailure;
use crate::parts::{ImageRef, Tile};
use crate::plex::{Plex, build_plex_client, is_plex};
use crate::tile::{Words, grid_tile, plex_grid_tile};
use crate::title_text::{
    TitleText, addresses, header_blur_hash, header_image_waiting, logo_image, person_image,
    progress, resume_from, similar_cleaned, user_image, without_double,
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
    /// The BlurHash of the head image, for the blurred stand-in until the image itself is there.
    pub image_blur_hash: Option<String>,
    /// The pictures the tiles of this title showed so far (the landscape one first), for frame 1 of the page: the host
    /// shows the first one it still has in its picture memory until the head image is there.
    pub tile_images: Vec<ImageRef>,
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
    /// The version a tap on Play starts (the menu marks it). One of the options has it set.
    pub is_default: bool,
}

/// The version a tap on Play starts when none was picked, and so the one the version menu marks:
/// the one that takes the least work and, on a tie, the top one as the server orders them. It is
/// the rule the playback plan itself uses without a named version (`best_source`), applied to the
/// sources the title lists. That is only the fallback for while no plan has answered: the server's
/// answer to the device profile can rule the top version out (over the bitrate cap, a container the
/// device cannot read), and the start then takes another one, so the mark follows the plan
/// ([`VersionOption::list`]). `None` without a usable source.
pub fn default_version(sources: &[MediaSource]) -> Option<&MediaSource> {
    let usable: Vec<MediaSource> = sources.iter().filter(|s| s.id.is_some()).cloned().collect();
    let best = swiftly_playback::playback_plan::best_source(&usable)?;
    sources.iter().find(|s| s.id == best.id)
}

impl VersionOption {
    /// The options of a title with several versions in the server's order, the default one marked.
    /// Empty when there is no choice (fewer than two usable versions). The mark is the version the
    /// title's live plan (`planned`, its `media_source_id`) starts when one is among the options,
    /// the one a tap on Play really starts; before the plan has answered it is the least-work
    /// rule on the sources ([`default_version`]).
    pub(crate) fn list(
        sources: &[MediaSource],
        words: &Words,
        language: &str,
        planned: Option<&str>,
    ) -> Vec<Self> {
        let offered = MediaVersions::choices(Some(sources));
        let default = planned
            .filter(|id| offered.iter().any(|s| s.id.as_deref() == Some(*id)))
            .map(str::to_owned)
            .or_else(|| default_version(&offered).and_then(|d| d.id.clone()));
        offered
            .iter()
            .filter_map(|v| Self::of(v, words, language))
            .map(|o| Self {
                is_default: Some(&o.id) == default.as_ref(),
                ..o
            })
            .collect()
    }

    /// The option for a media source; `None` without an id. Not marked as the default.
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
            is_default: false,
        })
    }
}

/// The main button.
#[derive(Debug, Clone, PartialEq)]
pub struct PlayButton {
    /// "Abspielen" or "Fortsetzen ab 1:23" in the user's language.
    pub label: String,
    /// Whether a press decides at once. The button is drawn the same either way (white, with `label`): a press
    /// while it is `Waiting` is held by the core and starts the title when the versions are there.
    pub ready: PlayReadiness,
    /// "Noch 12 Min." under the button; the runtime ("1 Std. 52 Min.") for a title not started.
    pub remaining: Option<String>,
    /// Watched share under the button, 0 to 1.
    pub progress: Option<f32>,
    /// The heading of the version sheet ("Fassung wählen").
    pub version_title: String,
}

/// Whether a press on Play can start the title now. One state: the press itself is held in `Waiting`, so no host
/// keeps a press of its own and the look of the button never depends on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayReadiness {
    /// The versions are known (or a copy on the device decides): a press returns the action at once.
    Ready,
    /// The versions are on their way. `queued`: the viewer already pressed Play; the core starts the title when they
    /// arrive (a [`DetailEffect::Play`]), once.
    Waiting {
        /// A press is waiting for the versions.
        queued: bool,
    },
}

impl PlayReadiness {
    /// A press decides at once.
    pub fn is_ready(self) -> bool {
        self == Self::Ready
    }
}

/// A press on Play held until the versions are known.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct QueuedPress {
    /// From the beginning ("Play from start" in the More panel).
    from_start: bool,
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
    /// Everything has been answered; the view puts the sections in together.
    pub ready: bool,
    /// The first twelve cast members. Filled before `ready` when the page's seed already knows them (the stored copy of
    /// an earlier visit), so they stand in frame 1.
    pub cast: Vec<CastTile>,
    /// A cast row is expected but not known yet (a film whose title has not answered): the host keeps its place with a
    /// placeholder of the row's final height until `cast` fills in or this turns false.
    pub cast_pending: bool,
    /// The "Gesehen von" row can still arrive (the setting is on and the viewers have not answered): the host keeps its
    /// place after the cast row with a placeholder of the row's final height. False once `ready`.
    pub watchers_pending: bool,
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
    /// Start now. A title with several versions starts its default version (`source_id` `None`);
    /// the others are offered by `versions()` for a long press on Play, never in front of the start.
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
    /// A press on Play that came before the versions were known; the next publish with versions turns it into a
    /// [`DetailEffect::Play`].
    queued: Option<QueuedPress>,
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
    /// The proof line's answer of an earlier visit, shown until the fresh plan answers.
    mark: Option<crate::proof_mark::ProofMark>,
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

/// The same action, from the beginning.
fn from_start_of(action: PlayAction) -> PlayAction {
    match action {
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

/// What a press does for `item`, with `downloaded` as the host knows it (`launch(since:)`). Several
/// versions do not ask: the press starts the default one, the choice is [`DetailVm::versions`].
pub(crate) fn play_action(item: &Item, downloaded: bool, since: f64) -> PlayAction {
    let item_id = item.id.clone();
    match MediaVersions::start(item.media_sources.as_deref(), downloaded) {
        VersionStart::Choose(_) | VersionStart::Play => PlayAction::Start {
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
        // The page opens complete from what the list answer and an earlier visit stored: description, genres, ratings,
        // picture tags and BlurHashes are in frame 1, nothing of it waits for the server.
        let scope = account.as_ref().map(crate::cache::ViewCache::scope);
        let item = crate::seed::from_store(item, host.cache.as_ref(), scope.as_ref());
        let hero = HeroPart {
            version: 1,
            id: String::new(),
            kind: None,
            title: String::new(),
            secondary_line: String::new(),
            image: None,
            logo: None,
            image_blur_hash: None,
            tile_images: Vec::new(),
            overview: None,
            directors: Vec::new(),
            community_rating: None,
            age_rating: None,
            failure: None,
        };
        let live = Live {
            switch: 1,
            scope,
            client,
            plex,
            cached: None,
            fresh: None,
            versions_failed: false,
            queued: None,
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
            mark: None,
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
                    ready: PlayReadiness::Waiting { queued: false },
                    remaining: None,
                    progress: None,
                    version_title: String::new(),
                },
                watched: false,
                favorite: false,
                favorite_caption: String::new(),
                toggle_error: None,
                proof: ProofPart {
                    phase: ProofPhase::Waiting,
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
                cast_pending: false,
                watchers_pending: false,
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

    /// The TMDB id of the title (`ProviderIds.Tmdb`), for Seerr.
    pub fn tmdb_id(&self) -> Option<i64> {
        let live = self.inner.live();
        crate::series::tmdb_of(self.inner.current(&live))
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

    /// Whether a background request of this view model is still running (a watched or watchlist write that has not
    /// been answered). A handle that is kept only for such a write can be dropped once this is false. Other clones of
    /// the handle count as busy too.
    pub fn busy(&self) -> bool {
        Arc::strong_count(&self.inner) > 1
    }

    /// Observers currently parked in [`DetailVm::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// What a press on Play does now: from the resume point when there is one, else from the
    /// start. `Wait` while the button is gray. `pick` is the version the user chose; with it the
    /// press starts that version.
    pub fn play(&self, pick: Option<&str>) -> PlayAction {
        self.press(pick, false)
    }

    /// One press: the action now, or `Wait` and the press is held (no second one is queued) until the versions
    /// arrive. A press with a picked version is never held (the version list only exists once they are known).
    fn press(&self, pick: Option<&str>, from_start: bool) -> PlayAction {
        let mut live = self.inner.live();
        let action = self.inner.decide(&live, pick);
        if action == PlayAction::Wait && pick.is_none() {
            live.queued = Some(QueuedPress { from_start });
            self.inner.publish(&mut live, false);
        }
        if from_start {
            from_start_of(action)
        } else {
            action
        }
    }

    /// The versions for the long press on Play: the title's versions in the server's order with the
    /// default one marked, only when there is a real choice. Empty while the versions are not known,
    /// for a title with one version and for a copy on the device (it plays that copy). Picking one
    /// goes to [`DetailVm::play`] as `pick`.
    pub fn versions(&self) -> Vec<VersionOption> {
        let live = self.inner.live();
        let current = self.inner.current(&live);
        if live.downloaded || !self.inner.versions_known(&live, current) {
            return Vec::new();
        }
        VersionOption::list(
            current.media_sources.as_deref().unwrap_or_default(),
            &self.inner.words,
            self.inner.text.locale().language(),
            live.plan
                .as_deref()
                .filter(|p| p.item_id.as_deref() == Some(current.id.as_str()))
                .and_then(|p| p.media_source_id.as_deref()),
        )
    }

    /// Whether the title is a placeholder the server lists without a file (`LocationType: Virtual`, a missing movie):
    /// there is nothing to start, and the page says so instead of waiting for versions.
    pub fn is_placeholder(&self) -> bool {
        let live = self.inner.live();
        self.inner.current(&live).location_type.as_deref() == Some("Virtual")
    }

    /// Like [`DetailVm::play`], but from the beginning ("Play from start" in the More panel).
    pub fn play_from_start(&self, pick: Option<&str>) -> PlayAction {
        self.press(pick, true)
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

    /// What a press does now: from the resume point when there is one, else from the start; `Wait` while the
    /// versions are not known.
    fn decide(&self, live: &Live<T>, pick: Option<&str>) -> PlayAction {
        let current = self.current(live);
        if !self.versions_known(live, current) {
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
        play_action(current, live.downloaded, since)
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
        // A press that waited for the versions starts the title now, once (the host sees it as an effect).
        if let Some(press) = live.queued
            && self.versions_known(live, self.current(live))
        {
            live.queued = None;
            let action = self.decide(live, None);
            live.effects.push(DetailEffect::Play(if press.from_start {
                from_start_of(action)
            } else {
                action
            }));
            live.effect_seq += 1;
        }
        let current = self.current(live);
        let server = live.server();
        let addresses = server.as_ref().and_then(Server::addresses);
        let placeholder = current.location_type.as_deref() == Some("Virtual");
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
                    .and_then(|a| header_image_waiting(current, None, a, live.title_answered)),
            },
            logo: match &live.plex {
                Some(plex) => plex_image(plex, current, swiftly_plex::ImageKind::Logo),
                None => addresses.as_ref().and_then(|a| logo_image(current, a)),
            },
            image_blur_hash: header_blur_hash(current),
            tile_images: crate::seed::head_stand_ins(&current.id),
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
            ready: if server.is_some() && self.versions_known(live, current) {
                PlayReadiness::Ready
            } else {
                PlayReadiness::Waiting {
                    queued: live.queued.is_some(),
                }
            },
            remaining: self.text.resume_slot(current),
            progress: progress(current),
            version_title: self.text.key("Fassung wählen"),
        };
        let mark = live.mark.as_ref().filter(|m| {
            m.usable(
                &self.item.id,
                live.options.max_bitrate,
                live.fresh
                    .as_ref()
                    .map(crate::proof_mark::version_of)
                    .as_deref(),
            )
        });
        let plan_known = live.plan_present || mark.is_some();
        let title_known = live.title_answered || (mark.is_some() && live.cached.is_some());
        let proof_ready = title_known && plan_known;
        let shown = crate::proof_mark::shown(live.plan.as_deref(), live.plan_present, mark);
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
                // The chips depend on the title (stars, age rating) and on the plan (Direct Play or a hint). The answer
                // of an earlier visit stands in for both from frame 1 (the stored copy carries the title's chips).
                phase: if proof_ready {
                    ProofPhase::Settled
                } else {
                    ProofPhase::Waiting
                },
                visible: proof_ready && !placeholder,
                direct_play: shown.0,
                hint: shown.1,
                // The title chips are known from the seed, so the host draws them at once; a placeholder without a file
                // never shows any, so it is not offered one.
                rating: current
                    .community_rating
                    .filter(|_| !placeholder)
                    .map(rating_text),
                age_rating: age_rating_text(&self.text, current.official_rating.clone())
                    .filter(|_| !placeholder),
            },
            download: (live.options.download_button && current.type_.as_deref() != Some("Series"))
                .then(|| DownloadField {
                    state: live.download_state,
                    caption: self.text.key("Laden"),
                }),
            message: live.message.clone(),
            effect_seq: live.effect_seq,
        };
        let ready = live.bottom_ready && live.title_answered;
        // The cast of the seed (the stored copy of an earlier visit) stands in frame 1; the fresh title replaces it.
        let cast: Vec<CastTile> = if server.is_some() {
            current
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
                .collect()
        } else {
            Vec::new()
        };
        // Which rows can still arrive, so the host reserves their final height instead of letting them push in.
        let cast_pending = cast.is_empty()
            && !live.title_answered
            && server.is_some()
            && current.type_.as_deref() == Some("Movie");
        let watchers_pending = !ready
            && live.options.watchers_shown
            && live.client.is_some()
            && !placeholder
            && current.type_.as_deref() != Some("Series");
        let bottom = match (&server, ready) {
            (Some(client), true) => BottomPart {
                version: live.bottom.version,
                ready: true,
                cast,
                cast_pending: false,
                watchers_pending: false,
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
                cast,
                cast_pending,
                watchers_pending,
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
        // What the account offers is remembered under the key of the account, as everything else kept for it is.
        let offering = crate::offered::Whose::new(
            live.scope.as_ref().map_or("", |scope| scope.0.as_str()),
            &self.host,
        );
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
            // The tile the page was opened with carries the newest user data (resume position, played). An older
            // stored copy never overrides it: that flipped the Play label "Fortsetzen ab 20 Min." -> "Abspielen"
            // -> "Fortsetzen ..." on a second visit. The copy fills the user data only when the tile has none.
            stored.user_data = self.item.user_data.clone().or(stored.user_data);
            live.cached = Some(stored);
            self.publish(&mut live, false);
        }
        // The proof line of an earlier visit: shown from this first frame until the fresh plan answers.
        if let Some((cache, scope, _)) = &remembered
            && live.mark.is_none()
            && let Some(mark) = crate::proof_mark::read(cache, scope, &self.item.id)
        {
            live.mark = Some(mark);
            self.publish(&mut live, false);
        }
        let proof_store = remembered
            .as_ref()
            .map(|(cache, scope, _)| (cache.clone(), cache.ticket(scope)));
        drop(live);
        // The title and the playback plan are asked side by side and each is published when it arrives: the plan is a
        // PlaybackInfo call (the server may probe the file), and nothing needed only to start Play may hold the page.
        let who = client.who(&crate::prefetch::scope(&self.host));
        let inner = Arc::clone(self);
        let c = client.clone();
        let who_item = who.clone();
        self.host.spawner.spawn(Box::pin(async move {
            let answer = c.item(&inner.item.id).await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            live.title_answered = true;
            match answer {
                Ok(fresh) => {
                    if let Some((cache, _, ticket)) = &remembered {
                        cache.write_title(ticket, &fresh);
                    }
                    // The start of Play takes this copy instead of asking for the title again.
                    if let Some(who) = &who_item {
                        crate::prefetch::remember_item(who, &fresh, inner.host.clock.now());
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
        let inner = Arc::clone(self);
        let c = client.clone();
        self.host.spawner.spawn(Box::pin(async move {
            let (bitrate, local) = {
                let live = inner.live();
                (live.options.max_bitrate, live.local_plan.clone())
            };
            let planned = match &local {
                Some(p) => Ok(Some((**p).clone())),
                None => c.plan(&inner.item.id, bitrate, None).await,
            };
            if local.is_none()
                && let (Some(who), Ok(Some(plan))) = (&who, &planned)
            {
                // Play starts from this plan when it is the one the engine would ask for.
                crate::prefetch::remember_plan(
                    who,
                    &inner.item.id,
                    bitrate,
                    None,
                    plan,
                    inner.host.clock.now(),
                );
            }
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            // The plan is replaced even by "none" (a refresh asks again), the page shows the
            // proof row once it is answered. A copy on the device keeps standing in for it.
            live.plan = live
                .local_plan
                .clone()
                .or_else(|| planned.ok().flatten().map(Arc::new));
            live.plan_present = true;
            // The answer stays for the next visit; a copy on the device is not a delivery question.
            if local.is_none()
                && let (Some((cache, ticket)), Some(plan)) = (&proof_store, live.plan.as_deref())
            {
                let version = live
                    .fresh
                    .as_ref()
                    .map(crate::proof_mark::version_of)
                    .unwrap_or_default();
                crate::proof_mark::write(cache, ticket, &inner.item.id, bitrate, plan, version);
            }
            inner.publish(&mut live, false);
        }));
        if all {
            let inner = Arc::clone(self);
            self.host.spawner.spawn(Box::pin(async move {
                let own = inner.item.clone();
                let watchers_on = inner.live().options.watchers_shown;
                let seen = crate::offered::version(&offering);
                let (similar, extras, collections, watchers) = join4(
                    client.similar(&own.id, i64::try_from(SIMILAR_LIMIT).unwrap_or(12)),
                    client.extras(&own.id),
                    async { client.collection_rails(&offering, &own).await },
                    // Plex keeps no list of who watched a title.
                    async {
                        match &jelly {
                            Some(j) if watchers_on => j.watchers(&own.id).await.unwrap_or_default(),
                            _ => Vec::new(),
                        }
                    },
                )
                .await;
                {
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
                }
                // After the page has drawn: the collections are asked again when the stored ones are over a minute old.
                client.refresh_offering(&offering).await;
                // The refresh brought other collections than the page drew from: the open page takes its row from them.
                if crate::offered::version(&offering) != seen {
                    let fresh = client.collection_rails(&offering, &own).await;
                    let mut live = inner.live();
                    if live.switch == switch && live.collections != fresh {
                        live.collections = fresh;
                        inner.publish(&mut live, false);
                    }
                }
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
        // Watched (or not) changes the resume point: what the page remembered for a start is out of date from now on.
        let who = if watchlist {
            None
        } else {
            client.who(&crate::prefetch::scope(&self.host))
        };
        if let Some(who) = &who {
            crate::prefetch::forget(who, &id);
        }
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let done = client.set_flag(&id, on, watchlist).await;
            if let Some(who) = &who {
                // Again once the server has the new state: a start in between must not have put the old one back.
                crate::prefetch::forget(who, &id);
            }
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
            if let Some(who) = client.who(&crate::prefetch::scope(&inner.host)) {
                // The resume point is gone: a start must not take the title the page remembered with it.
                crate::prefetch::forget(&who, &inner.item.id);
            }
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
            live.queued = None;
            live.title_failure = None;
            live.toggle_error = None;
            live.similar.clear();
            live.similar_failed = false;
            live.extras.clear();
            live.bottom_ready = false;
            live.title_answered = false;
            live.plan = None;
            live.plan_present = false;
            live.mark = None;
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

/// The titles of a collection's row: the members of the section the title is in, without doubles and without the title.
fn rail_titles(members: &[Item], art: &str, title: &Item) -> Vec<Item> {
    let in_section: Vec<Item> = members
        .iter()
        .filter(|m| LibraryGenre::art_to_type(m.type_.as_deref()) == Some(art))
        .cloned()
        .collect();
    without_double(&in_section)
        .into_iter()
        .filter(|i| i.id != title.id)
        .collect()
}

/// What an account offers (the collections, the views they hide in), asked of a Jellyfin or Emby server
/// (`AppModel.offeringLoad`: hidden collections count as none).
async fn jelly_directory<T: HttpTransport + 'static>(
    client: &Client<T>,
) -> Option<CollectionDirectory> {
    let (visible, hidden) = join(client.user_views(false), client.user_views(true)).await;
    let visible = visible.ok()?;
    let with_hidden = hidden.unwrap_or_else(|_| visible.clone());
    if CollectionDirectory::hidden(&visible, &with_hidden) {
        return Some(CollectionDirectory::default());
    }
    collection_directory(client, &with_hidden).await.ok()
}

/// The collections of an account for a host screen that composes its own section menu (the desktop's library page):
/// the directory the core keeps per account ([`crate::offered`], shared with the home page and the detail pages) when
/// it is current, otherwise asked once and stored for them all. A library change reported for the account makes it old.
/// `None` when the server cannot be asked and nothing current is kept.
pub async fn account_directory<T: HttpTransport + 'static>(
    client: &JellyfinClient<crate::host::Shared<T>>,
    host: &Host,
    account: &AccountRef,
) -> Option<CollectionDirectory> {
    let who = crate::offered::Whose::new(&account.key(), host);
    if let Some(kept) = crate::offered::current(&who) {
        return Some(kept);
    }
    let began = crate::offered::stamp(&who);
    let found = jelly_directory(client).await?;
    crate::offered::remember(&who, began, &found);
    Some(found)
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

    /// Where the viewer is in a series (`stateInSeries`); a failed request is an error (nothing started is `Ok(None)`).
    pub(crate) async fn state_in_series_checked(
        &self,
        id: &str,
    ) -> Result<Option<Item>, ErrorKind> {
        match self {
            Self::Jelly(c) => swiftly_library::client_ext::state_in_series_checked(&**c, id).await,
            Self::Plex(c) => MediaServer::state_in_series_checked(&**c, id).await,
        }
    }

    /// The fetch of what the account offers, for [`crate::offered`] (nothing is asked until it runs).
    pub(crate) fn directory_fetch(
        &self,
    ) -> impl FnOnce() -> Pin<Box<dyn Future<Output = Option<CollectionDirectory>> + Send>> + use<T>
    {
        let server = self.clone();
        move || {
            Box::pin(async move {
                match &server {
                    Self::Jelly(c) => jelly_directory(&**c).await,
                    Self::Plex(c) => MediaServer::collection_directory(&**c, &[]).await.ok(),
                }
            })
        }
    }

    /// Asks again for the collections when the stored ones are older than a minute, for after a page has drawn.
    pub(crate) async fn refresh_offering(&self, who: &crate::offered::Whose) {
        crate::offered::refresh(who, self.directory_fetch()).await;
    }

    /// The titles of a collection (a short while kept: a row of a title in a collection is asked once, not per visit).
    async fn collection_titles(
        &self,
        who: &crate::offered::Whose,
        collection: &str,
    ) -> Option<Arc<Vec<Item>>> {
        if let Some(kept) = crate::offered::members(who, collection) {
            return Some(kept);
        }
        let began = crate::offered::stamp(who);
        let list = match self {
            Self::Jelly(c) => c.collection_members(collection).await.ok()?,
            Self::Plex(c) => c.collection_items(collection).await.ok()?,
        };
        Some(crate::offered::remember_members(
            who, began, collection, list,
        ))
    }

    /// "Part of the collection": at most two rows of the other titles of the collections this title is in
    /// (`AppModel.collectionRails`). The collections come from the account's memory; any failure leaves the row out.
    pub(crate) async fn collection_rails(
        &self,
        who: &crate::offered::Whose,
        title: &Item,
    ) -> Vec<(Item, Vec<Item>)> {
        let Some(art) = LibraryGenre::art_to_type(title.type_.as_deref()) else {
            return Vec::new();
        };
        let Some(directory) = crate::offered::directory(who, self.directory_fetch()).await else {
            return Vec::new();
        };
        let holding = directory.collections_with(title);
        let rows = join_all(holding.iter().take(2).map(|collection| {
            let who = &who;
            async move {
                let list = self.collection_titles(who, collection.id()).await?;
                let other = rail_titles(&list, art, title);
                (!other.is_empty()).then(|| (collection.item.clone(), other))
            }
        }))
        .await;
        rows.into_iter().flatten().collect()
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

/// The address of the head picture the page of a tapped tile will ask for, known before that page exists: from the
/// tile's own marks and the stored copy of the title (the same seed the page opens from, the same size and quality
/// as the page's own request). A host starts the download on finger-down with it, so the picture is on its way
/// while the page is still opening and the server resizes it in that time. `None` when the seed names no head
/// picture yet (the page then asks after the title answered) and for Plex.
pub fn head_picture_ahead<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
    item: Item,
) -> Option<String> {
    let (client, _) = clients(transport, host, Some(account)).ok()?;
    let client = client?;
    let scope = crate::cache::ViewCache::scope(account);
    let item = crate::seed::from_store(item, host.cache.as_ref(), Some(&scope));
    let addresses = addresses(&*client)?;
    header_image_waiting(&item, None, &addresses, false).map(|image| image.address)
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

#[cfg(test)]
mod default_version_tests {
    use super::*;

    fn source(id: Option<&str>, direct: bool) -> MediaSource {
        MediaSource {
            id: id.map(Into::into),
            supports_direct_play: Some(direct),
            ..Default::default()
        }
    }

    fn id_of(sources: &[MediaSource]) -> Option<String> {
        default_version(sources).and_then(|s| s.id.clone())
    }

    #[test]
    fn on_a_tie_the_top_version_of_the_servers_order_is_the_default() {
        let all = [
            source(Some("a"), true),
            source(Some("b"), true),
            source(Some("c"), true),
        ];
        assert_eq!(id_of(&all).as_deref(), Some("a"));
    }

    #[test]
    fn the_version_that_takes_the_least_work_wins_like_in_the_plan() {
        // The same rule the playback plan uses without a named version (`best_source`): the first one needs a transcode.
        let all = [
            source(Some("a"), false),
            source(Some("b"), true),
            source(Some("c"), true),
        ];
        assert_eq!(id_of(&all).as_deref(), Some("b"));
        assert_eq!(id_of(&[]), None);
    }

    #[test]
    fn a_source_without_an_id_is_never_the_default_nor_an_option() {
        let all = [
            source(None, true),
            source(Some("b"), false),
            source(Some("c"), false),
        ];
        assert_eq!(id_of(&all).as_deref(), Some("b"));
        let one_usable = [source(None, true), source(Some("b"), true)];
        let words = Words::new(swiftly_l10n::Locale::parse("de"));
        assert!(
            VersionOption::list(&one_usable, &words, "de", None).is_empty(),
            "one usable version is no choice"
        );
        let list = VersionOption::list(&all, &words, "de", None);
        assert_eq!(
            list.iter()
                .map(|o| (o.id.as_str(), o.is_default))
                .collect::<Vec<_>>(),
            [("b", true), ("c", false)]
        );
    }
}
