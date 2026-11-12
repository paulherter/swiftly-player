//! The exported detail (movie or episode page) and series view models.

use std::sync::Arc;

use swiftly_model::{Item, UserItemData};
use swiftly_vm::{
    AccountRef, ActionsPart, Badge, BottomPart, CastTile, Change, CollectionRailPart,
    DownloadField, DownloadState, EpisodeRow, EpisodesStatus, FailKind, FileExcerpt, FileRow,
    HeroPart, ImageRef, LoadFailure, MenuEntry, MenuKind, PlayAction, PlayButton, ProofPart,
    SeasonRow, SeasonsPart, SeriesButtonPart, SeriesSpec, Tile, VersionOption, WatcherTile,
};

use crate::error::CoreError;
use crate::transport::CoreTransport;

#[uniffi::remote(Record)]
pub struct HeroPart {
    pub version: u64,
    pub id: String,
    pub kind: Option<String>,
    pub title: String,
    pub secondary_line: String,
    pub image: Option<ImageRef>,
    pub logo: Option<ImageRef>,
    pub overview: Option<String>,
    pub directors: Vec<String>,
    pub community_rating: Option<f64>,
    pub age_rating: Option<String>,
    pub failure: Option<LoadFailure>,
}

#[uniffi::remote(Enum)]
pub enum LoadFailure {
    Offline,
    Failed(FailKind),
}

#[uniffi::remote(Enum)]
pub enum FailKind {
    Server,
    Unreadable,
    Denied,
}

#[uniffi::remote(Record)]
pub struct VersionOption {
    pub id: String,
    pub name: String,
    pub label: String,
}

#[uniffi::remote(Record)]
pub struct PlayButton {
    pub label: String,
    pub enabled: bool,
    pub remaining: Option<String>,
    pub progress: Option<f32>,
    pub version_title: String,
}

#[uniffi::remote(Record)]
pub struct ProofPart {
    pub visible: bool,
    pub direct_play: bool,
    pub hint: Option<String>,
    pub rating: Option<String>,
    pub age_rating: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum DownloadState {
    Nothing,
    Queued,
    Loading(f32),
    Paused,
    Ready,
    Failed,
}

#[uniffi::remote(Record)]
pub struct DownloadField {
    pub state: DownloadState,
    pub caption: String,
}

#[uniffi::remote(Record)]
pub struct ActionsPart {
    pub version: u64,
    pub play: PlayButton,
    pub watched: bool,
    pub favorite: bool,
    pub favorite_caption: String,
    pub toggle_error: Option<String>,
    pub proof: ProofPart,
    pub download: Option<DownloadField>,
    pub message: Option<String>,
    pub effect_seq: u64,
}

#[uniffi::remote(Record)]
pub struct CastTile {
    pub id: String,
    pub name: String,
    pub role: Option<String>,
    pub image: Option<ImageRef>,
}

#[uniffi::remote(Record)]
pub struct WatcherTile {
    pub user_id: String,
    pub name: String,
    pub initial: String,
    pub ring: f64,
    pub play_count: i64,
    pub last_watched: Option<String>,
    pub watched_count: Option<i64>,
    pub total_count: Option<i64>,
    pub image: Option<ImageRef>,
}

#[uniffi::remote(Record)]
pub struct CollectionRailPart {
    pub id: String,
    pub title: String,
    pub tiles: Vec<Tile>,
}

#[uniffi::remote(Record)]
pub struct FileRow {
    pub label: String,
    pub value: String,
}

#[uniffi::remote(Record)]
pub struct FileExcerpt {
    pub title: String,
    pub rows: Vec<FileRow>,
}

#[uniffi::remote(Record)]
pub struct BottomPart {
    pub version: u64,
    pub ready: bool,
    pub cast: Vec<CastTile>,
    pub extras: Vec<Tile>,
    pub similar: Vec<Tile>,
    pub similar_failed: bool,
    pub watchers: Vec<WatcherTile>,
    pub collections: Vec<CollectionRailPart>,
    pub file: Option<FileExcerpt>,
}

#[uniffi::remote(Enum)]
pub enum MenuKind {
    Play,
    PlayFromStart,
    Overview,
    MarkWatched,
    MarkUnwatched,
    Download,
    PlayOn { id: String, name: String },
    Together,
    RemoveFromContinue,
    ResetProgress,
    RefreshMetadata,
    PlayEpisodeFromStart,
    NextEpisode,
    Shuffle,
    MarkSeasonWatched { name: String },
    Trailer,
}

#[uniffi::remote(Record)]
pub struct MenuEntry {
    pub kind: MenuKind,
    pub text: String,
}

#[uniffi::remote(Enum)]
pub enum PlayAction {
    Wait,
    Resolve {
        item_id: String,
        since: f64,
    },
    Choose {
        item_id: String,
        since: f64,
        versions: Vec<VersionOption>,
    },
    Start {
        item_id: String,
        since: f64,
        source_id: Option<String>,
    },
}

/// A device the title can be started on.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PlayOnDevice {
    /// Device id.
    pub id: String,
    /// Device name.
    pub name: String,
}

/// What the page needs to know about the host (settings, capabilities, menu context).
#[derive(Debug, Clone, uniffi::Record)]
pub struct DetailOptions {
    /// Show who watched it.
    pub watchers_shown: bool,
    /// Show the download button.
    pub download_button: bool,
    /// Bitrate ceiling for the playback plan.
    pub max_bitrate: i64,
    /// The host can open web addresses.
    pub can_open_web: bool,
    /// The title is on the device (offline copy).
    pub on_device: bool,
    /// Other devices in reach.
    pub play_on: Vec<PlayOnDevice>,
    /// Watch-together is available.
    pub together: bool,
    /// The tile comes from the continue-watching row.
    pub continue_watching: bool,
    /// The menu opens inside the player.
    pub in_player: bool,
}

impl From<DetailOptions> for swiftly_vm::DetailOptions {
    fn from(o: DetailOptions) -> Self {
        Self {
            watchers_shown: o.watchers_shown,
            download_button: o.download_button,
            max_bitrate: o.max_bitrate,
            can_open_web: o.can_open_web,
            menu: swiftly_vm::MenuContext {
                download_button: o.download_button,
                on_device: o.on_device,
                play_on: o.play_on.into_iter().map(|d| (d.id, d.name)).collect(),
                together: o.together,
                continue_watching: o.continue_watching,
                in_player: o.in_player,
            },
        }
    }
}

/// What the view asks for. The playback plan itself is not an intent here: the player round
/// brings it.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum DetailIntent {
    /// First appearance.
    Load,
    /// Reload.
    Refresh,
    /// Watched on or off.
    SetWatched {
        /// On or off.
        on: bool,
    },
    /// Watchlist on or off.
    SetWatchlist {
        /// On or off.
        on: bool,
    },
    /// Retry the similar titles.
    RetrySimilar,
    /// The title is (not) on the device.
    Downloaded {
        /// On the device.
        on: bool,
    },
    /// Host settings changed.
    Options {
        /// The settings.
        options: DetailOptions,
    },
    /// The download manager's state for this title.
    DownloadState {
        /// The state.
        state: DownloadState,
    },
    /// The download field was pressed.
    DownloadPressed,
    /// The trailer was asked for.
    Trailer,
    /// A menu entry was chosen.
    Menu {
        /// The entry.
        kind: MenuKind,
    },
    /// Close the notice line.
    DismissMessage,
    /// Another account (or none).
    AccountSwitched {
        /// The account.
        account: Option<AccountRef>,
    },
}

impl From<DetailIntent> for swiftly_vm::DetailIntent {
    fn from(intent: DetailIntent) -> Self {
        use swiftly_vm::DetailIntent as I;
        match intent {
            DetailIntent::Load => I::Load,
            DetailIntent::Refresh => I::Refresh,
            DetailIntent::SetWatched { on } => I::SetWatched { on },
            DetailIntent::SetWatchlist { on } => I::SetWatchlist { on },
            DetailIntent::RetrySimilar => I::RetrySimilar,
            DetailIntent::Downloaded { on } => I::Downloaded { on },
            DetailIntent::Options { options } => I::Options(Box::new(options.into())),
            DetailIntent::DownloadState { state } => I::DownloadState(state),
            DetailIntent::DownloadPressed => I::DownloadPressed,
            DetailIntent::Trailer => I::Trailer,
            DetailIntent::Menu { kind } => I::Menu(kind),
            DetailIntent::DismissMessage => I::DismissMessage,
            DetailIntent::AccountSwitched { account } => I::AccountSwitched { account },
        }
    }
}

/// Work for the host that the page cannot do itself (`take_effects`).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum DetailEffect {
    /// Play a trailer file of this title (the plan comes with the player round).
    PlayTrailer {
        /// The trailer's item id.
        item_id: String,
    },
    /// Open a web address (a trailer on the web).
    OpenWeb {
        /// The address.
        url: String,
    },
    /// Start playing.
    Play {
        /// What to do.
        action: PlayAction,
    },
    /// Open the download screen.
    OpenDownload,
    /// A menu entry the host runs.
    Menu {
        /// The entry.
        kind: MenuKind,
    },
    /// The watched state changed on the server (a write succeeded): other pages reload.
    StateChanged,
    /// The watchlist changed on the server (a write succeeded): other pages reload.
    WatchlistChanged,
}

impl From<swiftly_vm::DetailEffect> for DetailEffect {
    fn from(effect: swiftly_vm::DetailEffect) -> Self {
        use swiftly_vm::DetailEffect as E;
        match effect {
            E::PlayTrailer { item, .. } => Self::PlayTrailer { item_id: item.id },
            E::OpenWeb(url) => Self::OpenWeb {
                url: url.to_string(),
            },
            E::Play(action) => Self::Play { action },
            E::OpenDownload => Self::OpenDownload,
            E::Menu(kind) => Self::Menu { kind },
            E::StateChanged => Self::StateChanged,
            E::WatchlistChanged => Self::WatchlistChanged,
        }
    }
}

/// The list entry the page starts from: what a tile knows. The fresh title completes it.
///
/// The tile's marks carry over into `user_data` (watched, favourite, unseen count, progress) so
/// the page shows the right checkmark and bookmark from the first frame (`Item(rust:)`).
pub(crate) fn item_of(tile: &Tile) -> Item {
    let mut watched = false;
    let mut favorite = false;
    let mut unplayed = None;
    for badge in &tile.badges {
        match badge {
            Badge::Watched => watched = true,
            Badge::Favorite => favorite = true,
            Badge::Unplayed { count } => unplayed = Some(i64::from(*count)),
            Badge::Seasons { .. } => {}
        }
    }
    let user_data =
        (watched || favorite || unplayed.is_some() || tile.progress.is_some()).then(|| {
            UserItemData {
                played: Some(watched),
                is_favorite: Some(favorite),
                played_percentage: tile.progress.map(|p| f64::from(p) * 100.0),
                unplayed_item_count: unplayed,
                ..UserItemData::default()
            }
        });
    Item {
        id: tile.id.clone(),
        name: tile.facts.name.clone(),
        type_: tile.facts.kind.clone(),
        production_year: tile.facts.year.map(i64::from),
        series_id: tile.facts.series_id.clone(),
        season_id: tile.facts.season_id.clone(),
        parent_index_number: tile.facts.season_number.map(i64::from),
        index_number: tile.facts.episode_number.map(i64::from),
        child_count: tile.facts.child_count.map(i64::from),
        user_data,
        ..Item::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_vm::{Badge, TileFacts};

    fn tile(badges: Vec<Badge>, progress: Option<f32>) -> Tile {
        Tile {
            id: "e1".into(),
            title: "Folge".into(),
            subtitle: None,
            progress,
            image: None,
            badges,
            remaining: None,
            facts: TileFacts {
                kind: Some("Episode".into()),
                name: "Folge".into(),
                year: None,
                series_id: Some("s1".into()),
                season_id: None,
                season_number: Some(1),
                episode_number: Some(2),
                child_count: Some(3),
            },
        }
    }

    #[test]
    fn the_tile_state_reaches_the_item() {
        let item = item_of(&tile(
            vec![
                Badge::Watched,
                Badge::Favorite,
                Badge::Unplayed { count: 4 },
            ],
            Some(0.25),
        ));
        let data = item.user_data.expect("user data");
        assert_eq!(data.played, Some(true));
        assert_eq!(data.is_favorite, Some(true));
        assert_eq!(data.unplayed_item_count, Some(4));
        assert!((data.played_percentage.unwrap() - 25.0).abs() < 1e-6);
        assert_eq!(item.child_count, Some(3));
    }

    #[test]
    fn a_plain_tile_has_no_user_data() {
        assert!(item_of(&tile(Vec::new(), None)).user_data.is_none());
        let begun = item_of(&tile(Vec::new(), Some(0.5)))
            .user_data
            .expect("progress");
        assert_eq!(begun.played, Some(false));
        assert_eq!(begun.is_favorite, Some(false));
    }
}

/// Bit of `Change.parts`: the hero.
#[uniffi::export]
pub fn part_detail_hero() -> u32 {
    swiftly_vm::part::DETAIL_HERO
}

/// Bit of `Change.parts`: buttons and toggles.
#[uniffi::export]
pub fn part_detail_actions() -> u32 {
    swiftly_vm::part::DETAIL_ACTIONS
}

/// Bit of `Change.parts`: cast, extras, similar, rows.
#[uniffi::export]
pub fn part_detail_bottom() -> u32 {
    swiftly_vm::part::DETAIL_BOTTOM
}

/// A movie or episode page.
#[derive(uniffi::Object)]
pub struct DetailVm {
    vm: swiftly_vm::DetailVm<CoreTransport>,
}

impl DetailVm {
    pub(crate) fn wrap(vm: swiftly_vm::DetailVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { vm })
    }
}

#[uniffi::export]
impl DetailVm {
    /// The version of the view model.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// Title, image, overview.
    pub fn hero(&self) -> HeroPart {
        HeroPart::clone(&self.vm.hero())
    }

    /// Play button, toggles, proof row, download field, notice.
    pub fn actions(&self) -> ActionsPart {
        ActionsPart::clone(&self.vm.actions())
    }

    /// Cast, extras, similar, watchers, collections, file.
    pub fn bottom(&self) -> BottomPart {
        BottomPart::clone(&self.vm.bottom())
    }

    /// What a press on Play does now.
    pub fn play(&self, pick: Option<String>) -> PlayAction {
        self.vm.play(pick.as_deref())
    }

    /// What "from the start" does now.
    pub fn play_from_start(&self, pick: Option<String>) -> PlayAction {
        self.vm.play_from_start(pick.as_deref())
    }

    /// The long-press menu of the page.
    pub fn tile_menu(&self) -> Vec<MenuEntry> {
        self.vm.tile_menu()
    }

    /// The "More" panel.
    pub fn more_menu(&self) -> Vec<MenuEntry> {
        self.vm.more_menu()
    }

    /// The current title as the server's JSON (fresh, else stored, else the list entry).
    pub fn item_json(&self) -> Option<String> {
        self.vm.item_json()
    }

    /// The plan the page already holds (the server's, or the copy on the device); `None`
    /// until answered or when there is none.
    pub fn plan_answer(&self) -> Option<crate::play_start::PlanOnly> {
        self.vm
            .plan()
            .map(|plan| crate::play_start::plan_ready(&plan))
    }

    /// Work for the host; empties the queue.
    pub fn take_effects(&self) -> Vec<DetailEffect> {
        self.vm.take_effects().into_iter().map(Into::into).collect()
    }

    /// An intent. Never blocks.
    pub fn send(&self, intent: DetailIntent) {
        self.vm.send(intent.into());
    }

    /// Returns at once when newer than `seen`, else waits.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// Observers parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}

// ---- series ----

#[uniffi::remote(Record)]
pub struct SeriesSpec {
    pub start_season_id: Option<String>,
    pub start_season_number: Option<i64>,
}

#[uniffi::remote(Record)]
pub struct SeasonRow {
    pub id: String,
    pub name: String,
    pub number: Option<i64>,
}

#[uniffi::remote(Record)]
pub struct SeasonsPart {
    pub version: u64,
    pub seasons: Vec<SeasonRow>,
    pub selected: Option<String>,
    pub disturbed: bool,
}

#[uniffi::remote(Record)]
pub struct EpisodeRow {
    pub id: String,
    pub number: Option<i64>,
    pub title: String,
    pub code: Option<String>,
    pub overview: Option<String>,
    pub runtime: Option<String>,
    pub remaining: Option<String>,
    pub progress: Option<f32>,
    pub watched: bool,
    pub image: Option<ImageRef>,
}

#[uniffi::remote(Enum)]
pub enum EpisodesStatus {
    Ready,
    Loading,
    Empty,
    Disturbed,
}

/// The episode list (`total` fits `u32`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct EpisodesPart {
    /// Version of the part.
    pub version: u64,
    /// State of the list.
    pub status: EpisodesStatus,
    /// The rows shown.
    pub rows: Vec<EpisodeRow>,
    /// Episodes in the season.
    pub total: u32,
    /// More rows can be shown.
    pub more_available: bool,
}

#[uniffi::remote(Record)]
pub struct SeriesButtonPart {
    pub version: u64,
    pub id: String,
    pub title: String,
    pub secondary_line: String,
    pub image: Option<ImageRef>,
    pub logo: Option<ImageRef>,
    pub overview: Option<String>,
    pub label: String,
    pub label_ready: bool,
    pub enabled: bool,
    pub next_episode: Option<String>,
    pub remaining: Option<String>,
    pub progress: Option<f32>,
    pub watched: bool,
    pub favorite: bool,
    pub favorite_caption: String,
    pub toggle_error: Option<String>,
    pub message: Option<String>,
    pub proof: ProofPart,
    pub effect_seq: u64,
}

/// What the series page needs to know about the host (settings, capabilities, devices).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SeriesOptions {
    /// A download button appears at all (the menu then carries the trailer entry).
    pub download_button: bool,
    /// The host can open web addresses.
    pub can_open_web: bool,
    /// Bitrate ceiling for the playback plan.
    pub max_bitrate: i64,
    /// Watch-together is available.
    pub together: bool,
    /// Other devices in reach.
    pub play_on: Vec<PlayOnDevice>,
    /// Show who watched it.
    pub watchers_shown: bool,
}

impl From<SeriesOptions> for swiftly_vm::SeriesOptions {
    fn from(o: SeriesOptions) -> Self {
        Self {
            download_button: o.download_button,
            can_open_web: o.can_open_web,
            max_bitrate: o.max_bitrate,
            together: o.together,
            play_on: o.play_on.into_iter().map(|d| (d.id, d.name)).collect(),
            watchers_shown: o.watchers_shown,
        }
    }
}

/// Work for the host that the series page cannot do itself (`take_effects`).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum SeriesEffect {
    /// Start an episode (from its start, or the next one).
    Play {
        /// What to do.
        action: PlayAction,
    },
    /// Play a trailer file (the plan comes with the player round).
    PlayTrailer {
        /// The trailer's item id.
        item_id: String,
    },
    /// Open a web address (a trailer on the web).
    OpenWeb {
        /// The address.
        url: String,
    },
    /// A menu entry the host runs (shuffle, watch together, play on a device).
    Menu {
        /// The entry.
        kind: MenuKind,
    },
    /// The watched state changed on the server (a write succeeded): other pages reload.
    StateChanged,
    /// The watchlist changed on the server (a write succeeded): other pages reload.
    WatchlistChanged,
}

impl From<swiftly_vm::SeriesEffect> for SeriesEffect {
    fn from(effect: swiftly_vm::SeriesEffect) -> Self {
        use swiftly_vm::SeriesEffect as E;
        match effect {
            E::Play(action) => Self::Play { action },
            E::PlayTrailer { item, .. } => Self::PlayTrailer { item_id: item.id },
            E::OpenWeb(url) => Self::OpenWeb {
                url: url.to_string(),
            },
            E::Menu(kind) => Self::Menu { kind },
            E::StateChanged => Self::StateChanged,
            E::WatchlistChanged => Self::WatchlistChanged,
        }
    }
}

/// Cast, extras and similar titles of a series.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MorePart {
    /// Version of the part.
    pub version: u64,
    /// The cast.
    pub cast: Vec<CastTile>,
    /// Extras.
    pub extras: Vec<Tile>,
    /// Similar titles.
    pub similar: Vec<Tile>,
    /// Who has seen the series; empty when the setting is off or the plugin is missing.
    pub watchers: Vec<WatcherTile>,
    /// Similar titles are on their way.
    pub similar_loads: bool,
    /// Similar titles failed.
    pub similar_failed: bool,
}

/// What the series view asks for.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum SeriesIntent {
    /// First appearance (and the retry of a failed season list).
    Load,
    /// Back from the player.
    Refresh,
    /// Another season.
    SelectSeason {
        /// The season id.
        id: String,
    },
    /// Show 40 more rows.
    MoreEpisodes,
    /// Fetch the episodes again.
    RetryEpisodes,
    /// One episode watched or unwatched.
    SetEpisodeWatched {
        /// The episode id.
        id: String,
        /// On or off.
        on: bool,
    },
    /// Mark the shown season watched.
    MarkSeasonWatched,
    /// The series watched or unwatched.
    SetWatched {
        /// On or off.
        on: bool,
    },
    /// The series on the watchlist or off.
    SetWatchlist {
        /// On or off.
        on: bool,
    },
    /// Close the notice line.
    DismissMessage,
    /// Host settings changed.
    Options {
        /// The settings.
        options: SeriesOptions,
    },
    /// The trailer was asked for.
    Trailer,
    /// A menu entry was chosen.
    Menu {
        /// The entry.
        kind: MenuKind,
    },
    /// Another account (or none).
    AccountSwitched {
        /// The account.
        account: Option<AccountRef>,
    },
}

impl From<SeriesIntent> for swiftly_vm::SeriesIntent {
    fn from(intent: SeriesIntent) -> Self {
        use swiftly_vm::SeriesIntent as I;
        match intent {
            SeriesIntent::Load => I::Load,
            SeriesIntent::Refresh => I::Refresh,
            SeriesIntent::SelectSeason { id } => I::SelectSeason { id },
            SeriesIntent::MoreEpisodes => I::MoreEpisodes,
            SeriesIntent::RetryEpisodes => I::RetryEpisodes,
            SeriesIntent::SetEpisodeWatched { id, on } => I::SetEpisodeWatched { id, on },
            SeriesIntent::MarkSeasonWatched => I::MarkSeasonWatched,
            SeriesIntent::SetWatched { on } => I::SetWatched { on },
            SeriesIntent::SetWatchlist { on } => I::SetWatchlist { on },
            SeriesIntent::DismissMessage => I::DismissMessage,
            SeriesIntent::Options { options } => I::Options(options.into()),
            SeriesIntent::Trailer => I::Trailer,
            SeriesIntent::Menu { kind } => I::Menu(kind),
            SeriesIntent::AccountSwitched { account } => I::AccountSwitched { account },
        }
    }
}

/// Bit of `Change.parts`: the season picker.
#[uniffi::export]
pub fn part_series_seasons() -> u32 {
    swiftly_vm::part::SERIES_SEASONS
}

/// Bit of `Change.parts`: the episode list.
#[uniffi::export]
pub fn part_series_episodes() -> u32 {
    swiftly_vm::part::SERIES_EPISODES
}

/// Bit of `Change.parts`: head, main button, toggles.
#[uniffi::export]
pub fn part_series_button() -> u32 {
    swiftly_vm::part::SERIES_BUTTON
}

/// Bit of `Change.parts`: cast, extras, similar.
#[uniffi::export]
pub fn part_series_more() -> u32 {
    swiftly_vm::part::SERIES_MORE
}

/// A series page.
#[derive(uniffi::Object)]
pub struct SeriesVm {
    vm: swiftly_vm::SeriesVm<CoreTransport>,
}

impl SeriesVm {
    pub(crate) fn wrap(vm: swiftly_vm::SeriesVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { vm })
    }
}

#[uniffi::export]
impl SeriesVm {
    /// The version of the view model.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// The season picker.
    pub fn seasons(&self) -> SeasonsPart {
        SeasonsPart::clone(&self.vm.seasons())
    }

    /// The episode list's shared load state (additive to `episodes().status`).
    pub fn load(&self) -> crate::state::LoadPart {
        crate::state::LoadPart::of(self.vm.version(), self.vm.load())
    }

    /// The episodes of the selected season.
    pub fn episodes(&self) -> EpisodesPart {
        let part = self.vm.episodes();
        EpisodesPart {
            version: part.version,
            status: part.status,
            rows: part.rows.clone(),
            total: u32::try_from(part.total).unwrap_or(u32::MAX),
            more_available: part.more_available,
        }
    }

    /// Head, main button, toggles.
    pub fn button(&self) -> SeriesButtonPart {
        SeriesButtonPart::clone(&self.vm.button())
    }

    /// Cast, extras, similar.
    pub fn more(&self) -> MorePart {
        let part = self.vm.more();
        MorePart {
            version: part.version,
            cast: part.cast.clone(),
            extras: part.extras.clone(),
            similar: part.similar.clone(),
            watchers: part.watchers.clone(),
            similar_loads: part.similar_loads,
            similar_failed: part.similar_failed,
        }
    }

    /// What the main button does.
    pub fn play_next(&self, pick: Option<String>) -> PlayAction {
        self.vm.play_next(pick.as_deref())
    }

    /// What a tap on an episode does.
    pub fn play_episode(&self, id: String, pick: Option<String>) -> PlayAction {
        self.vm.play_episode(&id, pick.as_deref())
    }

    /// Remembers the version that plays now (`MediaSource` JSON, e.g. the player's source) so the next
    /// episode keeps it: same name, else same resolution, else the version is asked for again. Picks made
    /// through `play_episode`/`play_next` are remembered by themselves. `None` or bad JSON forgets.
    pub fn keep_version(&self, source_json: Option<String>) {
        self.vm
            .keep_version(source_json.and_then(|j| serde_json::from_str(&j).ok()));
    }

    /// The entries of the "More" panel.
    pub fn more_menu(&self) -> Vec<MenuEntry> {
        self.vm.more_menu()
    }

    /// Work for the host; empties the queue.
    pub fn take_effects(&self) -> Vec<SeriesEffect> {
        self.vm.take_effects().into_iter().map(Into::into).collect()
    }

    /// The raw item for the host's play seam as the server's JSON: `None` id is the series
    /// (fresh when loaded); an id names an episode or season on screen.
    pub fn item_json(&self, id: Option<String>) -> Option<String> {
        self.vm.item_json(id.as_deref())
    }

    /// The plan of the state (next) episode that the proof row asked for; `None` until it
    /// answered or when there is none.
    pub fn plan_answer(&self) -> Option<crate::play_start::PlanOnly> {
        self.vm
            .plan()
            .map(|plan| crate::play_start::plan_ready(&plan))
    }

    /// An intent. Never blocks.
    pub fn send(&self, intent: SeriesIntent) {
        self.vm.send(intent.into());
    }

    /// Returns at once when newer than `seen`, else waits.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// Observers parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}
