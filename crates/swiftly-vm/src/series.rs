//! `SeriesVm`: the page of one series (`SeriesDetailView` of the Swift app).
//!
//! * Opening: where the viewer is (`stateInSeries`: the episode in progress, else the next
//!   unwatched one, else the first), the seasons and the fresh series load together; the season
//!   shown is chosen by `SeasonSelectionRule` (hint from the episode we came from, then the
//!   state). The episodes of that season follow and everything is published at once.
//! * A failed fetch keeps what is shown (`nil` is not an empty list): the failure shows only
//!   on an empty page, with a retry.
//! * The episode list grows by 40 on request (`EpisodesSection.step`); a season switch shows
//!   the episodes seen before at once, else nothing until they arrive.
//! * Marking a season watched and the watched toggles ask the server first (series: switch at
//!   once and put back with the reason); afterwards the page reloads everything that can change.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures_util::future::join3;
use swiftly_images::ImageSelection;
use swiftly_jellyfin::Watcher;
use swiftly_l10n::Arg;
use swiftly_library::SeasonSelectionRule;
use swiftly_model::{Item, MediaSource, MediaVersions};
use swiftly_net::{ErrorKind, HttpTransport, Url};
use swiftly_playback::playback_plan::PlaybackPlan;

use crate::account::AccountRef;
use crate::bell::{Bell, Changed, part};
use crate::detail::{CastTile, PlayAction, play_action};
use crate::detail::{Server, clients, watcher_tile};
use crate::detail_more::WatcherTile;
use crate::detail_more::{
    MenuEntry, MenuKind, ProofPart, TrailerCandidate, age_rating_text, rating_text,
    trailer_candidates,
};
use crate::home::Client;
use crate::host::Host;
use crate::load_state::{FailKind, Load, LoadFailure};
use crate::parts::{ImageKind, ImageRef, Tile};
use crate::plex::Plex;
use crate::tile::Words;
use crate::title_text::{
    TitleText, header_image, logo_image, person_image, progress, resume_from, similar_cleaned,
    without_double,
};

/// How many episode rows the list grows by (`EpisodesSection.step`).
pub const EPISODES_STEP: usize = 40;
const SIMILAR_LIMIT: usize = 12;
const CAST_LIMIT: usize = 12;
const STILL_WIDTH: i64 = 640;
/// The episode picture's height limit, as the Swift row asks for it (`maxHeight: 280`).
const EPISODE_STILL_HEIGHT: i64 = 280;

/// Where the page was opened from.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SeriesSpec {
    /// The season of the episode we came from.
    pub start_season_id: Option<String>,
    /// The season number of that episode (the id can be missing on some servers).
    pub start_season_number: Option<i64>,
}

/// One season in the picker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeasonRow {
    /// Season id.
    pub id: String,
    /// Name as the server gives it ("Staffel 2", "Specials").
    pub name: String,
    /// Season number, if any.
    pub number: Option<i64>,
}

/// The season picker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeasonsPart {
    /// Version of the part.
    pub version: u64,
    /// The seasons in server order.
    pub seasons: Vec<SeasonRow>,
    /// The season shown.
    pub selected: Option<String>,
    /// The server did not answer and no seasons are known (retry offered).
    pub disturbed: bool,
}

/// One episode row.
#[derive(Debug, Clone, PartialEq)]
pub struct EpisodeRow {
    /// Episode id.
    pub id: String,
    /// Episode number.
    pub number: Option<i64>,
    /// The name.
    pub title: String,
    /// "S1 · F3".
    pub code: Option<String>,
    /// The description.
    pub overview: Option<String>,
    /// "52 Min." when the runtime is positive.
    pub runtime: Option<String>,
    /// "Noch 12 Min." for a started one.
    pub remaining: Option<String>,
    /// Watched share, 0 to 1.
    pub progress: Option<f32>,
    /// Watched.
    pub watched: bool,
    /// The still image.
    pub image: Option<ImageRef>,
}

/// Where the episode list stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EpisodesStatus {
    /// Rows are shown (or the season list is empty too).
    Ready,
    /// The first fetch of this season runs; the area stays empty.
    Loading,
    /// The season has no episodes ("Keine Folgen in dieser Staffel").
    Empty,
    /// The fetch failed and nothing is shown (retry offered).
    Disturbed,
}

/// The episode list.
#[derive(Debug, Clone, PartialEq)]
pub struct EpisodesPart {
    /// Version of the part.
    pub version: u64,
    /// State of the list.
    pub status: EpisodesStatus,
    /// The rows shown: the first `shown` of `total`.
    pub rows: Vec<EpisodeRow>,
    /// Episodes in the season.
    pub total: usize,
    /// More rows can be shown (`SeriesIntent::MoreEpisodes`).
    pub more_available: bool,
}

/// Stars and age rating of a series (see [`SeriesVm::rating`]).
#[derive(Debug, Clone, PartialEq)]
pub struct SeriesRating {
    /// Community rating, e.g. 8.1.
    pub community_rating: Option<f64>,
    /// Age rating, e.g. "TV-MA"; never empty.
    pub age_rating: Option<String>,
}

/// The head of the page, the main button and the toggles.
#[derive(Debug, Clone, PartialEq)]
pub struct SeriesButtonPart {
    /// Version of the part.
    pub version: u64,
    /// Server id of the series.
    pub id: String,
    /// The title.
    pub title: String,
    /// Year, seasons and genre in one line.
    pub secondary_line: String,
    /// The head image.
    pub image: Option<ImageRef>,
    /// The title as a logo.
    pub logo: Option<ImageRef>,
    /// The description.
    pub overview: Option<String>,
    /// "Abspielen S1 · F3", "Fortsetzen S1 · F3", "Lädt…" or "Keine Folgen".
    pub label: String,
    /// The label is final: the episode is resolved and, with none, the season load is over.
    pub label_ready: bool,
    /// The button can be pressed (it stays enabled while loading).
    pub enabled: bool,
    /// The episode behind the button.
    pub next_episode: Option<String>,
    /// "Noch 12 Min." under the button.
    pub remaining: Option<String>,
    /// Watched share of that episode.
    pub progress: Option<f32>,
    /// The series is watched.
    pub watched: bool,
    /// On the watchlist.
    pub favorite: bool,
    /// "Gemerkt" or "Merken".
    pub favorite_caption: String,
    /// Why the last toggle failed.
    pub toggle_error: Option<String>,
    /// A one-line notice (a season marked, a failed change); `DismissMessage` clears it.
    pub message: Option<String>,
    /// The line under the title: Direct Play mark or hint of the state episode's plan, stars and
    /// age rating of the series. Hidden until that plan has answered (with or without result).
    pub proof: ProofPart,
    /// Counts the effects queued for the host; moves this part so the host looks at
    /// [`SeriesVm::take_effects`].
    pub effect_seq: u64,
}

/// What the host tells the page about itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeriesOptions {
    /// A download button appears at all; the menu then carries the trailer entry
    /// (`moreActions`).
    pub download_button: bool,
    /// A browser can open a trailer link.
    pub can_open_web: bool,
    /// The bitrate limit sent with the playback request.
    pub max_bitrate: i64,
    /// Watching together is possible on this platform and account.
    pub together: bool,
    /// Other devices in reach (id, name) to start the state episode on.
    pub play_on: Vec<(String, String)>,
    /// The "Gesehen von" setting: the page asks the plugin who watched the series.
    pub watchers_shown: bool,
}

impl Default for SeriesOptions {
    fn default() -> Self {
        Self {
            download_button: false,
            can_open_web: false,
            max_bitrate: 1_000_000_000,
            together: false,
            play_on: Vec::new(),
            watchers_shown: false,
        }
    }
}

/// Work for the host that the page cannot do itself.
#[derive(Debug, Clone, PartialEq)]
pub enum SeriesEffect {
    /// Start an episode (from its start, or the next one).
    Play(PlayAction),
    /// Play a trailer file with this plan.
    PlayTrailer {
        /// The trailer.
        item: Box<Item>,
        /// How to open it.
        plan: Box<PlaybackPlan>,
    },
    /// Open a trailer page in the browser.
    OpenWeb(Url),
    /// A menu entry only the host can carry out (shuffle, watch together, play on a device).
    Menu(MenuKind),
    /// The watched state changed on the server (a write succeeded); other pages reload.
    StateChanged,
    /// The watchlist changed on the server (a write succeeded).
    WatchlistChanged,
}

/// Cast, extras and similar titles.
#[derive(Debug, Clone, PartialEq)]
pub struct MorePart {
    /// Version of the part.
    pub version: u64,
    /// The cast of the state episode, else of the series.
    pub cast: Vec<CastTile>,
    /// Extras (specials, behind the scenes).
    pub extras: Vec<Tile>,
    /// Similar titles.
    pub similar: Vec<Tile>,
    /// Who has seen the series (plugin, switch on); empty otherwise.
    pub watchers: Vec<WatcherTile>,
    /// The similar fetch runs; the view shows placeholders, not "nothing similar".
    pub similar_loads: bool,
    /// The similar fetch failed and nothing is shown.
    pub similar_failed: bool,
}

/// What the view asks for. Never blocks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeriesIntent {
    /// First appearance (and the retry of a failed season list).
    Load,
    /// Back from the player: only state, series and the episodes of the shown season.
    Refresh,
    /// Another season.
    SelectSeason {
        /// The season id.
        id: String,
    },
    /// Show 40 more rows.
    MoreEpisodes,
    /// Fetch the episodes of the shown season again.
    RetryEpisodes,
    /// Mark one episode watched or unwatched; the list reloads.
    SetEpisodeWatched {
        /// The episode id.
        id: String,
        /// The wanted state.
        on: bool,
    },
    /// Mark the shown season watched ("<season> als gesehen").
    MarkSeasonWatched,
    /// The series watched or unwatched.
    SetWatched {
        /// The wanted state.
        on: bool,
    },
    /// The series on the watchlist or off.
    SetWatchlist {
        /// The wanted state.
        on: bool,
    },
    /// Clear the notice.
    DismissMessage,
    /// What the host knows (settings, devices).
    Options(SeriesOptions),
    /// A press on the trailer field.
    Trailer,
    /// A pick in the More panel.
    Menu(MenuKind),
    /// Another account (or none: signed out).
    AccountSwitched {
        /// The new account, `None` for signed out.
        account: Option<AccountRef>,
    },
}

struct Live<T: HttpTransport + 'static> {
    switch: u64,
    client: Option<Arc<Client<T>>>,
    /// A Plex account: the page asks Plex for seasons, episodes and lists.
    plex: Option<Arc<Plex<T>>>,
    state: Option<Item>,
    state_resolved: bool,
    seasons: Vec<Item>,
    seasons_disturbed: bool,
    selected: Option<Item>,
    episodes: Vec<Item>,
    episodes_disturbed: bool,
    episodes_loads: bool,
    shown: usize,
    cache: HashMap<String, Vec<Item>>,
    loads: bool,
    fresh_year: Option<i64>,
    /// The cache scope of the account on screen (`None`: signed out).
    scope: Option<swiftly_cache::Scope>,
    /// Stars, age rating and description of the fresh series (list entries often lack them).
    fresh_facts: Option<(Option<f64>, Option<String>, Option<String>)>,
    /// The fresh series item, once loaded.
    fresh: Option<Item>,
    /// The episode after the state episode, once the menu resolved it.
    next_item: Option<Item>,
    /// The playback plan of the state episode (the proof row's, and the host's start).
    plan: Option<Arc<PlaybackPlan>>,
    plan_present: bool,
    options: SeriesOptions,
    effects: Vec<SeriesEffect>,
    effect_seq: u64,
    watched: bool,
    favorite: bool,
    /// The version of the episode played last (kept for the next one, `MediaVersions::matching`).
    kept: Option<MediaSource>,
    toggle_error: Option<String>,
    message: Option<String>,
    similar: Vec<Item>,
    similar_failed: bool,
    similar_loads: bool,
    extras: Vec<Item>,
    watchers: Vec<Watcher>,
    seasons_part: Arc<SeasonsPart>,
    episodes_part: Arc<EpisodesPart>,
    button: Arc<SeriesButtonPart>,
    more: Arc<MorePart>,
}

impl<T: HttpTransport + 'static> Live<T> {
    fn server(&self) -> Option<Server<T>> {
        self.plex
            .clone()
            .map(Server::Plex)
            .or_else(|| self.client.clone().map(Server::Jelly))
    }
}

struct Inner<T: HttpTransport + 'static> {
    transport: Arc<T>,
    host: Host,
    words: Words,
    text: TitleText,
    series: Item,
    spec: SeriesSpec,
    bell: Arc<Bell>,
    live: Mutex<Live<T>>,
}

/// The series view model. Cheap to clone (a handle).
pub struct SeriesVm<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: HttpTransport + 'static> Clone for SeriesVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<T: HttpTransport + 'static> SeriesVm<T> {
    /// A view model for `series` (the list entry) and `account` (or signed out). Nothing is
    /// loaded until [`SeriesIntent::Load`].
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
    pub fn new(
        transport: Arc<T>,
        host: Host,
        series: Item,
        spec: SeriesSpec,
        account: Option<AccountRef>,
    ) -> Result<Self, ErrorKind> {
        let (client, plex) = clients(&transport, &host, account.as_ref())?;
        let data = series.user_data.clone();
        let live = Live {
            switch: 1,
            client,
            plex,
            state: None,
            state_resolved: false,
            seasons: Vec::new(),
            seasons_disturbed: false,
            selected: None,
            episodes: Vec::new(),
            episodes_disturbed: false,
            episodes_loads: true,
            shown: EPISODES_STEP,
            cache: HashMap::new(),
            loads: true,
            fresh_year: None,
            scope: account.as_ref().map(crate::cache::ViewCache::scope),
            fresh_facts: None,
            fresh: None,
            next_item: None,
            plan: None,
            plan_present: false,
            options: SeriesOptions::default(),
            effects: Vec::new(),
            effect_seq: 0,
            watched: data.as_ref().and_then(|d| d.played).unwrap_or(false),
            favorite: data.as_ref().and_then(|d| d.is_favorite).unwrap_or(false),
            kept: None,
            toggle_error: None,
            message: None,
            similar: Vec::new(),
            similar_failed: false,
            similar_loads: true,
            extras: Vec::new(),
            watchers: Vec::new(),
            seasons_part: Arc::new(SeasonsPart {
                version: 1,
                seasons: Vec::new(),
                selected: None,
                disturbed: false,
            }),
            episodes_part: Arc::new(EpisodesPart {
                version: 1,
                status: EpisodesStatus::Loading,
                rows: Vec::new(),
                total: 0,
                more_available: false,
            }),
            button: Arc::new(SeriesButtonPart {
                version: 1,
                id: String::new(),
                title: String::new(),
                secondary_line: String::new(),
                image: None,
                logo: None,
                overview: None,
                label: String::new(),
                label_ready: false,
                enabled: true,
                next_episode: None,
                remaining: None,
                progress: None,
                watched: false,
                favorite: false,
                favorite_caption: String::new(),
                toggle_error: None,
                message: None,
                proof: ProofPart {
                    visible: false,
                    direct_play: false,
                    hint: None,
                    rating: None,
                    age_rating: None,
                },
                effect_seq: 0,
            }),
            more: Arc::new(MorePart {
                version: 1,
                cast: Vec::new(),
                extras: Vec::new(),
                similar: Vec::new(),
                watchers: Vec::new(),
                similar_loads: true,
                similar_failed: false,
            }),
        };
        let inner = Arc::new(Inner {
            words: Words::new(host.locale.clone()),
            text: TitleText::new(host.locale.clone()),
            transport,
            host,
            series,
            spec,
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
                    (s, ids.contains(&inner.series.id))
                }
                swiftly_cache::CacheChange::ScopeDropped(_) => return true,
            };
            let own = inner.live().scope.clone();
            let now = inner.host.clock.now();
            let mut last = last.lock().unwrap_or_else(PoisonError::into_inner);
            if named && own.as_ref() == Some(scope) && now - *last >= 3.0 {
                *last = now;
                drop(last);
                Inner::start_load(&inner, true);
            }
            true
        });
    }

    /// The version of the view model; moves whenever a part is replaced.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The season picker.
    pub fn seasons(&self) -> Arc<SeasonsPart> {
        Arc::clone(&self.inner.live().seasons_part)
    }

    /// The episode list's shared load state (the finer form of `episodes().status`).
    pub fn load(&self) -> Load {
        Inner::load_of(&self.inner.live())
    }

    /// The episode list.
    pub fn episodes(&self) -> Arc<EpisodesPart> {
        Arc::clone(&self.inner.live().episodes_part)
    }

    /// The head, the main button and the toggles.
    pub fn button(&self) -> Arc<SeriesButtonPart> {
        Arc::clone(&self.inner.live().button)
    }

    /// Cast, extras and similar titles.
    pub fn more(&self) -> Arc<MorePart> {
        Arc::clone(&self.inner.live().more)
    }

    /// Waits until the view model is newer than `seen`; names the parts that changed after it
    /// (`part::SERIES_*`).
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`SeriesVm::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// What the main button does: the episode the server sees the viewer at, from its resume
    /// point. `Wait` while that episode is not known or its versions are not known yet.
    pub fn play_next(&self, pick: Option<&str>) -> PlayAction {
        let mut live = self.inner.live();
        match live.state.clone() {
            Some(episode) => Self::action(&self.inner, &mut live, &episode, pick),
            None => PlayAction::Wait,
        }
    }

    /// Stars and age rating of the series page, from the full series item (list entries often carry
    /// neither; `SeriesView.swift:484`). The same wording as `DetailVm`'s hero: one decimal, comma.
    pub fn rating(&self) -> SeriesRating {
        let live = self.inner.live();
        self.inner.rating_of(&live)
    }

    /// The playback plan of the state (next) episode, fetched for the proof row; `None` until
    /// answered or when there is none. Starting with it saves the request on press.
    pub fn plan(&self) -> Option<Arc<PlaybackPlan>> {
        self.inner.live().plan.clone()
    }

    /// The host's work queued since the last call.
    pub fn take_effects(&self) -> Vec<SeriesEffect> {
        std::mem::take(&mut self.inner.live().effects)
    }

    /// The raw item for the host's play seam, as the server's JSON (what the host's `Item`
    /// decodes). `None` id: the series, fresh when loaded. `Some(id)`: the episode or season with
    /// that id from the lists on screen or remembered, else the state or next episode; an entry
    /// that carries `MediaSources` wins over one that does not.
    pub fn item_json(&self, id: Option<&str>) -> Option<String> {
        let live = self.inner.live();
        let item = match id {
            None => live.fresh.as_ref().unwrap_or(&self.inner.series),
            Some(id) if id == self.inner.series.id => {
                live.fresh.as_ref().unwrap_or(&self.inner.series)
            }
            Some(id) => {
                let all = live
                    .episodes
                    .iter()
                    .chain(live.cache.values().flatten())
                    .chain(live.state.iter())
                    .chain(live.next_item.iter())
                    .chain(live.seasons.iter())
                    .chain(live.selected.iter())
                    .filter(|e| e.id == id);
                all.clone()
                    .find(|e| e.media_sources.is_some())
                    .or_else(|| all.clone().next())?
            }
        };
        serde_json::to_string(item).ok()
    }

    /// The entries of the More panel (`moreActions`, `TitleActions.forSeries`).
    pub fn more_menu(&self) -> Vec<MenuEntry> {
        let live = self.inner.live();
        let text = &self.inner.text;
        let push = |list: &mut Vec<MenuEntry>, kind: MenuKind, key: &str| {
            list.push(MenuEntry {
                kind,
                text: text.key(key),
            });
        };
        let mut list = Vec::new();
        if live.options.download_button {
            push(&mut list, MenuKind::Trailer, "Trailer");
        }
        if live.state.is_some() {
            for (id, name) in &live.options.play_on {
                list.push(MenuEntry {
                    kind: MenuKind::PlayOn {
                        id: id.clone(),
                        name: name.clone(),
                    },
                    text: text.with("Abspielen auf „%@“", &[Arg::Str(name.clone())]),
                });
            }
            push(
                &mut list,
                MenuKind::PlayEpisodeFromStart,
                "Folge von vorn abspielen",
            );
            if live.options.together {
                push(&mut list, MenuKind::Together, "Gemeinsam schauen");
            } else {
                push(&mut list, MenuKind::NextEpisode, "Nächste Folge abspielen");
            }
        }
        push(&mut list, MenuKind::Shuffle, "Zufällig abspielen");
        if let Some(season) = &live.selected {
            list.push(MenuEntry {
                kind: MenuKind::MarkSeasonWatched {
                    name: season.name.clone(),
                },
                text: text.with("%@ als gesehen", &[Arg::Str(season.name.clone())]),
            });
        }
        push(
            &mut list,
            MenuKind::RefreshMetadata,
            "Metadaten neu einlesen",
        );
        list
    }

    /// What a tap on an episode row does.
    pub fn play_episode(&self, id: &str, pick: Option<&str>) -> PlayAction {
        let mut live = self.inner.live();
        match live.episodes.iter().find(|e| e.id == id).cloned() {
            Some(episode) => Self::action(&self.inner, &mut live, &episode, pick),
            None => PlayAction::Wait,
        }
    }

    /// Remembers the version that is playing now (the player's `source`), for the next episode: the next
    /// start without a pick takes the version with the same name, else the same resolution
    /// (`MediaVersions::matching`), and only asks again when there is none. Picks made through
    /// [`Self::play_episode`]/[`Self::play_next`] are remembered by themselves; this is for hosts that learn
    /// the version elsewhere (a resumed session). `None` forgets.
    pub fn keep_version(&self, source: Option<MediaSource>) {
        self.inner.live().kept = source;
    }

    /// Several versions are asked for episodes too (#33): an episode known only from a list that
    /// carries no `MediaSources` (the next-up entry) takes its sources from the episode list when that
    /// has it; while the list still loads the button is gray (`Wait`), and only a failed list lets a
    /// press resolve the episode (`Resolve`), as `DetailVm` does for a movie.
    fn action(
        inner: &Inner<T>,
        live: &mut Live<T>,
        episode: &Item,
        pick: Option<&str>,
    ) -> PlayAction {
        let since = resume_from(episode).unwrap_or(0.0);
        let full = live
            .episodes
            .iter()
            .find(|e| e.id == episode.id && e.media_sources.is_some())
            .unwrap_or(episode)
            .clone();
        let sources = full.media_sources.as_deref();
        if let Some(source) = pick {
            // The pick is the version to keep for the next episode.
            if let Some(chosen) =
                sources.and_then(|all| all.iter().find(|s| s.id.as_deref() == Some(source)))
            {
                live.kept = Some(chosen.clone());
            }
            return PlayAction::Start {
                item_id: episode.id.clone(),
                since,
                source_id: Some(source.to_owned()),
            };
        }
        if full.media_sources.is_none() && live.episodes_loads {
            return PlayAction::Wait;
        }
        // The version of the episode before wins over asking again.
        if let Some(found) = live
            .kept
            .as_ref()
            .and_then(|k| MediaVersions::matching(k, sources))
            && let Some(id) = found.id.clone()
        {
            live.kept = Some(found);
            return PlayAction::Start {
                item_id: full.id.clone(),
                since,
                source_id: Some(id),
            };
        }
        play_action(
            &full,
            false,
            since,
            &inner.words,
            inner.text.locale().language(),
        )
    }

    /// An intent from the view. Never blocks.
    pub fn send(&self, intent: SeriesIntent) {
        let inner = &self.inner;
        match intent {
            SeriesIntent::Load => Inner::start_load(inner, false),
            SeriesIntent::Refresh => Inner::start_load(inner, true),
            SeriesIntent::SelectSeason { id } => Inner::select_season(inner, &id),
            SeriesIntent::MoreEpisodes => {
                let mut live = inner.live();
                live.shown += EPISODES_STEP;
                inner.publish(&mut live, false);
            }
            SeriesIntent::RetryEpisodes => {
                let mut live = inner.live();
                live.episodes_loads = true;
                inner.publish(&mut live, false);
                drop(live);
                Inner::start_episodes(inner);
            }
            SeriesIntent::SetEpisodeWatched { id, on } => Inner::episode_watched(inner, id, on),
            SeriesIntent::MarkSeasonWatched => Inner::mark_season(inner),
            SeriesIntent::SetWatched { on } => Inner::toggle(inner, on, false),
            SeriesIntent::SetWatchlist { on } => Inner::toggle(inner, on, true),
            SeriesIntent::DismissMessage => {
                let mut live = inner.live();
                live.message = None;
                inner.publish(&mut live, false);
            }
            SeriesIntent::Options(options) => {
                let mut live = inner.live();
                live.options = options;
                inner.publish(&mut live, false);
            }
            SeriesIntent::Trailer => Inner::trailer(inner),
            SeriesIntent::Menu(kind) => Inner::menu(inner, kind),
            SeriesIntent::AccountSwitched { account } => Inner::switch_account(inner, account),
        }
    }
}

impl<T: HttpTransport + 'static> Inner<T> {
    fn live(&self) -> MutexGuard<'_, Live<T>> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Stars and age rating: the opened entry's, else the fresh series' (see [`SeriesVm::rating`]).
    fn rating_of(&self, live: &Live<T>) -> SeriesRating {
        let own = &self.series;
        let fresh = live.fresh_facts.as_ref();
        SeriesRating {
            community_rating: own.community_rating.or_else(|| fresh.and_then(|f| f.0)),
            age_rating: own
                .official_rating
                .clone()
                .filter(|r| !r.is_empty())
                .or_else(|| fresh.and_then(|f| f.1.clone())),
        }
    }

    fn queue(&self, live: &mut Live<T>, effect: SeriesEffect) {
        live.effects.push(effect);
        live.effect_seq += 1;
        self.publish(live, false);
    }

    fn say(&self, live: &mut Live<T>, text: String) {
        live.message = Some(text);
        self.publish(live, false);
    }

    /// Year, seasons and genre in one line (`SeriesDetailView.secondaryLine`).
    fn secondary_line(&self, live: &Live<T>) -> String {
        let mut parts = Vec::new();
        if let Some(year) = self.series.production_year.or(live.fresh_year) {
            parts.push(year.to_string());
        }
        // Not `childCount` once the seasons are loaded: it means different things per query.
        if live.seasons.len() == 1 {
            parts.push(live.seasons[0].name.clone());
        } else if let Some(count) = if live.seasons.is_empty() {
            self.series.child_count
        } else {
            i64::try_from(live.seasons.len()).ok()
        } {
            parts.push(self.text_plural("%lld Staffeln", count));
        }
        if let Some(genres) = self.series.genres.as_ref().filter(|g| !g.is_empty()) {
            parts.push(
                genres
                    .iter()
                    .take(2)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", "),
            );
        }
        parts.join(" · ")
    }

    fn text_plural(&self, key: &str, n: i64) -> String {
        use swiftly_model::Localizer;
        self.words.text(key, &[n])
    }

    fn episode_row(
        &self,
        episode: &Item,
        addr: Option<&swiftly_images::ImageAddress>,
    ) -> EpisodeRow {
        EpisodeRow {
            id: episode.id.clone(),
            number: episode.index_number,
            title: episode.name.clone(),
            code: episode.episode_code_with(&self.words),
            overview: episode.overview.clone().filter(|o| !o.is_empty()),
            runtime: episode
                .runtime_seconds()
                .filter(|s| *s > 0.0)
                .map(|s| self.text.runtime(s)),
            remaining: self.text.remaining(episode),
            progress: progress(episode),
            watched: episode.is_watched(),
            image: addr.and_then(|a| {
                // An episode row shows the episode's OWN picture (Swift: `imageURL(for: episode)`);
                // the landscape chain would give the series backdrop for every row. Plex keeps the
                // chain, because its pictures are named by path.
                let url = if a.kind == swiftly_jellyfin::ServerKind::Plex {
                    ImageSelection::landscape(episode, a, STILL_WIDTH).map(|hit| hit.url)
                } else {
                    let mark = episode.image_tags.as_ref()?.get("Primary")?;
                    a.construct(
                        &episode.id,
                        swiftly_images::ImageKind::Poster,
                        Some(mark.as_str()),
                        swiftly_images::ImageMetric::AtMostHigh(EPISODE_STILL_HEIGHT),
                    )
                }?;
                Some(ImageRef {
                    address: url.into(),
                    kind: ImageKind::Backdrop,
                    wanted_width: 640,
                    wanted_height: 360,
                })
            }),
        }
    }

    /// The shared load state of the episode list.
    fn load_of(live: &Live<T>) -> Load {
        Load::from_facts(
            live.episodes_loads && !live.episodes_disturbed,
            !live.episodes.is_empty(),
            live.episodes_disturbed
                .then_some(LoadFailure::Failed(FailKind::Server)),
        )
    }

    /// Rebuilds the parts and moves the version for the ones that differ.
    fn publish(&self, live: &mut Live<T>, first: bool) {
        let server = live.server();
        let addr = server.as_ref().and_then(Server::addresses);
        let seasons = SeasonsPart {
            version: live.seasons_part.version,
            seasons: live
                .seasons
                .iter()
                .map(|s| SeasonRow {
                    id: s.id.clone(),
                    name: s.name.clone(),
                    number: s.index_number,
                })
                .collect(),
            selected: live.selected.as_ref().map(|s| s.id.clone()),
            disturbed: live.seasons_disturbed && live.seasons.is_empty(),
        };
        let load = Self::load_of(live);
        let status = match load {
            _ if live.episodes_disturbed => EpisodesStatus::Disturbed,
            Load::Failed(_) | Load::Offline => EpisodesStatus::Disturbed,
            Load::Loading | Load::Idle => EpisodesStatus::Loading,
            Load::Empty if !live.seasons.is_empty() && !live.loads => EpisodesStatus::Empty,
            Load::Empty | Load::Loaded | Load::Refreshing => EpisodesStatus::Ready,
        };
        let episodes = EpisodesPart {
            version: live.episodes_part.version,
            status,
            rows: live
                .episodes
                .iter()
                .take(live.shown)
                .map(|e| self.episode_row(e, addr.as_ref()))
                .collect(),
            total: live.episodes.len(),
            more_available: live.episodes.len() > live.shown,
        };
        let loading_label = live.loads || !live.state_resolved;
        let state = live.state.as_ref();
        let rating = self.rating_of(live);
        let button = SeriesButtonPart {
            version: live.button.version,
            id: self.series.id.clone(),
            title: self.series.name.clone(),
            secondary_line: self.secondary_line(live),
            image: addr
                .as_ref()
                .and_then(|a| header_image(&self.series, state, a)),
            logo: addr.as_ref().and_then(|a| logo_image(&self.series, a)),
            overview: self
                .series
                .overview
                .clone()
                .filter(|o| !o.is_empty())
                .or_else(|| live.fresh_facts.as_ref().and_then(|f| f.2.clone())),
            label: self.text.series_button(state, loading_label),
            label_ready: live.state_resolved && (state.is_some() || !live.loads),
            enabled: server.is_some() && !(state.is_none() && live.state_resolved && !live.loads),
            next_episode: state.map(|s| s.id.clone()),
            remaining: state.and_then(|s| self.text.remaining(s)),
            progress: state.and_then(progress),
            watched: live.watched,
            favorite: live.favorite,
            favorite_caption: self
                .text
                .key(if live.favorite { "Gemerkt" } else { "Merken" }),
            toggle_error: live.toggle_error.clone(),
            message: live.message.clone(),
            proof: ProofPart {
                visible: live.plan_present,
                direct_play: live.plan.as_ref().is_some_and(|p| p.is_lossless()),
                hint: live
                    .plan
                    .as_ref()
                    .filter(|p| !p.is_lossless())
                    .map(|p| p.method.raw_value().to_owned()),
                rating: rating.community_rating.map(rating_text),
                age_rating: age_rating_text(&self.text, rating.age_rating),
            },
            effect_seq: live.effect_seq,
        };
        let folks: Vec<_> = match state.map(Item::actors).filter(|a| !a.is_empty()) {
            Some(a) => a,
            None => self.series.actors(),
        };
        let more = MorePart {
            version: live.more.version,
            cast: folks
                .into_iter()
                .take(CAST_LIMIT)
                .map(|p| CastTile {
                    id: p.id.clone(),
                    name: p.name.clone(),
                    role: p.role.clone(),
                    image: addr
                        .as_ref()
                        .and_then(|a| person_image(&p.id, p.primary_image_tag.as_deref(), a)),
                })
                .collect(),
            extras: server.as_ref().map_or_else(Vec::new, |c| {
                live.extras.iter().map(|i| c.tile(i, &self.words)).collect()
            }),
            similar: server.as_ref().map_or_else(Vec::new, |c| {
                live.similar
                    .iter()
                    .map(|i| c.tile(i, &self.words))
                    .collect()
            }),
            watchers: live
                .watchers
                .iter()
                .map(|w| watcher_tile(w, addr.as_ref()))
                .collect(),
            similar_loads: live.similar_loads,
            similar_failed: live.similar_failed,
        };
        let changed = [
            first || seasons != *live.seasons_part,
            first || episodes != *live.episodes_part,
            first || button != *live.button,
            first || more != *live.more,
        ];
        if !changed.iter().any(|c| *c) {
            return;
        }
        let indices: Vec<usize> = (0..4).filter(|i| changed[*i]).collect();
        let version = self.bell.bump(&indices);
        if changed[0] {
            live.seasons_part = Arc::new(SeasonsPart { version, ..seasons });
        }
        if changed[1] {
            live.episodes_part = Arc::new(EpisodesPart {
                version,
                ..episodes
            });
        }
        if changed[2] {
            live.button = Arc::new(SeriesButtonPart { version, ..button });
        }
        if changed[3] {
            live.more = Arc::new(MorePart { version, ..more });
        }
        const {
            assert!(
                part::SERIES_SEASONS == 1 << 0
                    && part::SERIES_EPISODES == 1 << 1
                    && part::SERIES_BUTTON == 1 << 2
                    && part::SERIES_MORE == 1 << 3
            );
        }
    }

    /// `load(postPlayback:)`. With `post` only the state, the series and the episodes of the
    /// shown season; seasons and similar titles do not change while watching.
    fn start_load(self: &Arc<Self>, post: bool) {
        let mut live = self.live();
        let Some(client) = live.server() else {
            self.publish(&mut live, false);
            return;
        };
        let switch = live.switch;
        // The facts of the series (rating, overview, year) paint from the stored copy of an
        // earlier visit; seasons, state and episodes still come from the server only.
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
            && !post
            && live.fresh_facts.is_none()
            && let Some(stored) = cache.read_title(scope, &self.series.id)
        {
            live.fresh_year = stored.production_year;
            live.fresh_facts = Some((
                stored.community_rating,
                stored.official_rating.clone().filter(|r| !r.is_empty()),
                stored.overview.clone().filter(|o| !o.is_empty()),
            ));
            self.publish(&mut live, false);
        }
        let jelly = live.client.clone();
        drop(live);
        let inner = Arc::clone(self);
        let c = client.clone();
        self.host.spawner.spawn(Box::pin(async move {
            let id = inner.series.id.clone();
            let (state, seasons, fresh) = join3(
                c.state_in_series(&id),
                async {
                    if post {
                        None
                    } else {
                        Some(c.seasons(&id).await.ok())
                    }
                },
                c.item(&id),
            )
            .await;
            let (seasons_now, seasons_failed) = {
                let live = inner.live();
                if live.switch != switch {
                    return;
                }
                match seasons {
                    Some(Some(list)) => (list, false),
                    Some(None) => (live.seasons.clone(), true),
                    None => (live.seasons.clone(), live.seasons_disturbed),
                }
            };
            // On a refresh the choice already made stays.
            let choice = {
                let live = inner.live();
                live.selected.clone().or_else(|| {
                    SeasonSelectionRule::choose(
                        &seasons_now,
                        inner.spec.start_season_id.as_deref(),
                        inner.spec.start_season_number,
                        state.as_ref(),
                    )
                    .cloned()
                })
            };
            let fetched = c
                .episodes(&id, choice.as_ref().map(|s| s.id.as_str()))
                .await
                .ok();
            let wanted = {
                let mut live = inner.live();
                if live.switch != switch {
                    return;
                }
                live.state = state;
                live.seasons_disturbed = seasons_failed;
                live.seasons = seasons_now;
                live.state_resolved = true;
                // Someone who picked a season meanwhile keeps that list.
                if live.selected.is_none()
                    || live.selected.as_ref().map(|s| &s.id) == choice.as_ref().map(|s| &s.id)
                {
                    live.selected = choice;
                    Self::accept(&mut live, fetched);
                }
                live.loads = false;
                // No state episode, no plan: the proof row shows at once, without the badge.
                if live.state.is_none() {
                    live.plan = None;
                    live.plan_present = true;
                }
                if let Ok(item) = fresh {
                    if let Some((cache, _, ticket)) = &remembered {
                        cache.write_title(ticket, &item);
                    }
                    live.fresh = Some(item.clone());
                    live.fresh_year = item.production_year;
                    live.fresh_facts = Some((
                        item.community_rating,
                        item.official_rating.clone().filter(|r| !r.is_empty()),
                        item.overview.clone().filter(|o| !o.is_empty()),
                    ));
                    let data = item.user_data;
                    live.favorite = data.as_ref().and_then(|d| d.is_favorite).unwrap_or(false);
                    live.watched = data.as_ref().and_then(|d| d.played).unwrap_or(false);
                }
                inner.publish(&mut live, false);
                // The plan of the state episode runs after the page is shown (`fetchPlan`); the row
                // fades in once it answered, with or without a result.
                live.state
                    .as_ref()
                    .map(|s| (s.id.clone(), live.options.max_bitrate))
            };
            let Some((episode, bitrate)) = wanted else {
                return;
            };
            let planned = c.plan(&episode, bitrate, None).await.ok().flatten();
            let mut live = inner.live();
            if live.switch != switch || live.state.as_ref().map(|s| &s.id) != Some(&episode) {
                return;
            }
            live.plan = planned.map(Arc::new);
            live.plan_present = true;
            inner.publish(&mut live, false);
        }));
        if !post {
            let inner = Arc::clone(self);
            self.host.spawner.spawn(Box::pin(async move {
                let own = inner.series.clone();
                let watchers_on = inner.live().options.watchers_shown;
                let (similar, extras, watchers) = join3(
                    client.similar(&own.id, i64::try_from(SIMILAR_LIMIT).unwrap_or(12)),
                    client.extras(&own.id),
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
                if let Ok(list) = extras {
                    live.extras = without_double(&list);
                }
                live.watchers = watchers;
                live.similar_loads = false;
                live.similar_failed = similar.is_err() && live.similar.is_empty();
                if let Ok(raw) = similar {
                    live.similar = without_double(&similar_cleaned(&raw, &own, SIMILAR_LIMIT));
                }
                inner.publish(&mut live, false);
            }));
        }
    }

    /// `episodesAccept`: a failure keeps the list; only an empty page shows it.
    fn accept(live: &mut Live<T>, fetched: Option<Vec<Item>>) {
        live.episodes_loads = false;
        live.episodes_disturbed = fetched.is_none() && live.episodes.is_empty();
        let Some(fetched) = fetched else {
            return;
        };
        if let Some(id) = live.selected.as_ref().map(|s| s.id.clone()) {
            live.cache.insert(id, fetched.clone());
        }
        live.episodes = fetched;
    }

    /// `seasonSwitch`: what was seen before shows at once, else nothing until it arrives.
    fn select_season(self: &Arc<Self>, id: &str) {
        let mut live = self.live();
        let Some(season) = live.seasons.iter().find(|s| s.id == id).cloned() else {
            return;
        };
        let remembered = live.cache.get(id).cloned();
        live.episodes_loads = remembered.is_none();
        live.episodes = remembered.unwrap_or_default();
        live.selected = Some(season);
        live.shown = EPISODES_STEP;
        live.episodes_disturbed = false;
        self.publish(&mut live, false);
        drop(live);
        self.start_episodes();
    }

    /// `episodesLoad`: the episodes of the shown season; an answer for a season that is no
    /// longer shown is dropped.
    fn start_episodes(self: &Arc<Self>) {
        let live = self.live();
        let Some(client) = live.server() else {
            return;
        };
        let switch = live.switch;
        let of = live.selected.as_ref().map(|s| s.id.clone());
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let fetched = client.episodes(&inner.series.id, of.as_deref()).await.ok();
            let mut live = inner.live();
            if live.switch != switch || live.selected.as_ref().map(|s| &s.id) != of.as_ref() {
                return;
            }
            Self::accept(&mut live, fetched);
            inner.publish(&mut live, false);
        }));
    }

    fn episode_watched(self: &Arc<Self>, id: String, on: bool) {
        let live = self.live();
        let Some(client) = live.server() else {
            return;
        };
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let done = client.set_flag(&id, on, false).await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            live.cache.clear();
            match done {
                Err(e) => {
                    live.message = Some(inner.words.error(&e));
                    inner.publish(&mut live, false);
                }
                Ok(()) => {
                    live.episodes_loads = live.episodes.is_empty();
                    inner.queue(&mut live, SeriesEffect::StateChanged);
                    drop(live);
                    inner.start_episodes();
                }
            }
        }));
    }

    /// "<season> als gesehen": ask, say so, load everything that can change.
    fn mark_season(self: &Arc<Self>) {
        let live = self.live();
        let (Some(client), Some(season)) = (live.server(), live.selected.clone()) else {
            return;
        };
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let done = client.set_flag(&season.id, true, false).await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            live.cache.clear();
            match done {
                Err(e) => {
                    live.message = Some(inner.words.error(&e));
                    inner.publish(&mut live, false);
                }
                Ok(()) => {
                    live.message = Some(
                        inner
                            .text
                            .with("%@ ist als gesehen vermerkt.", &[Arg::Str(season.name)]),
                    );
                    inner.queue(&mut live, SeriesEffect::StateChanged);
                    drop(live);
                    Inner::start_load(&inner, true);
                }
            }
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
        self.publish(&mut live, false);
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let id = inner.series.id.clone();
            let done = if watchlist {
                client.set_flag(&id, on, true).await
            } else {
                client.set_flag(&id, on, false).await
            };
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
                live.message = live.toggle_error.clone();
                inner.publish(&mut live, false);
            } else {
                if !watchlist {
                    live.cache.clear();
                }
                // The write reached the server: other pages reload on this.
                let effect = if watchlist {
                    SeriesEffect::WatchlistChanged
                } else {
                    SeriesEffect::StateChanged
                };
                inner.queue(&mut live, effect);
            }
        }));
    }

    /// A pick in the More panel.
    fn menu(self: &Arc<Self>, kind: MenuKind) {
        match kind {
            MenuKind::Play | MenuKind::PlayFromStart | MenuKind::PlayEpisodeFromStart => {
                let mut live = self.live();
                let action = match live.state.clone() {
                    Some(episode) => {
                        let action = SeriesVm::<T>::action(self, &mut live, &episode, None);
                        if kind == MenuKind::Play {
                            action
                        } else {
                            from_start(action)
                        }
                    }
                    None => PlayAction::Wait,
                };
                self.queue(&mut live, SeriesEffect::Play(action));
            }
            MenuKind::NextEpisode => self.next_episode(),
            MenuKind::MarkSeasonWatched { .. } => Self::mark_season(self),
            MenuKind::MarkWatched => Self::toggle(self, true, false),
            MenuKind::MarkUnwatched => Self::toggle(self, false, false),
            MenuKind::RefreshMetadata => self.refresh_metadata(),
            MenuKind::Trailer => Self::trailer(self),
            other => {
                let mut live = self.live();
                self.queue(&mut live, SeriesEffect::Menu(other));
            }
        }
    }

    /// "Nächste Folge abspielen": the episode after the state episode, from its start; nothing
    /// after it says so (`episodePost`).
    fn next_episode(self: &Arc<Self>) {
        let live = self.live();
        let (Some(client), Some(state)) = (live.server(), live.state.clone()) else {
            return;
        };
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let next = client.episode_post(&state.id, &inner.series.id).await;
            let mut live = inner.live();
            if live.switch != switch {
                return;
            }
            let Some(next) = next else {
                let text = inner.text.key("Danach kommt nichts mehr.");
                inner.say(&mut live, text);
                return;
            };
            // The episode list may carry its sources; the neighbour entry does not.
            let full = live
                .episodes
                .iter()
                .find(|e| e.id == next.id && e.media_sources.is_some())
                .unwrap_or(&next);
            let action = crate::detail::play_action(
                full,
                false,
                0.0,
                &inner.words,
                inner.text.locale().language(),
            );
            live.next_item = Some(next);
            inner.queue(&mut live, SeriesEffect::Play(action));
        }));
    }

    /// Server trailers first, then the linked one; the first that gets a plan plays. Only when
    /// nothing is left to try does a failed plan say so (as `DetailVm`).
    fn trailer(self: &Arc<Self>) {
        let live = self.live();
        let Some(client) = live.server() else {
            drop(live);
            let mut live = self.live();
            self.say(&mut live, self.words.title("Nicht angemeldet."));
            return;
        };
        let current = live.fresh.clone().unwrap_or_else(|| self.series.clone());
        let (bitrate, web) = (live.options.max_bitrate, live.options.can_open_web);
        let switch = live.switch;
        drop(live);
        let inner = Arc::clone(self);
        self.host.spawner.spawn(Box::pin(async move {
            let files = client.trailers(&current.id).await.unwrap_or_default();
            let candidates = trailer_candidates(&files, current.remote_trailers.as_deref(), web);
            let last = candidates.len().saturating_sub(1);
            let mut tried = false;
            let mut outcome: Option<SeriesEffect> = None;
            let mut failure: Option<String> = None;
            for (index, candidate) in candidates.into_iter().enumerate() {
                match candidate {
                    TrailerCandidate::File(film) => {
                        tried = true;
                        match client.plan(&film.id, bitrate, None).await {
                            Ok(Some(plan)) => {
                                outcome = Some(SeriesEffect::PlayTrailer {
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
                        outcome = Some(SeriesEffect::OpenWeb(url));
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

    /// "Metadaten neu einlesen" (`AppModel.metadataRefresh`).
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
            let done = client.metadata_refresh(&inner.series.id).await;
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
            (live.client, live.plex) = account
                .as_ref()
                .and_then(|a| clients(&self.transport, &self.host, Some(a)).ok())
                .unwrap_or((None, None));
            live.state = None;
            live.state_resolved = false;
            live.seasons.clear();
            live.seasons_disturbed = false;
            live.selected = None;
            live.episodes.clear();
            live.episodes_disturbed = false;
            live.episodes_loads = true;
            live.shown = EPISODES_STEP;
            live.cache.clear();
            live.loads = true;
            live.fresh = None;
            live.next_item = None;
            live.plan = None;
            live.plan_present = false;
            live.effects.clear();
            live.toggle_error = None;
            live.message = None;
            live.similar.clear();
            live.similar_failed = false;
            live.similar_loads = true;
            live.extras.clear();
            live.watchers.clear();
            let data = self.series.user_data.clone();
            live.watched = data.as_ref().and_then(|d| d.played).unwrap_or(false);
            live.favorite = data.as_ref().and_then(|d| d.is_favorite).unwrap_or(false);
            self.publish(&mut live, false);
        }
        self.start_load(false);
    }
}

/// The same action, from the beginning.
fn from_start(action: PlayAction) -> PlayAction {
    match action {
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
