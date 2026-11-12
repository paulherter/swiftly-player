//! The one interface the library, home and player code calls on a media server
//! (`MediaServer.swift:77-165`, `ServerCapability` :35).
//!
//! It lives here because it names types from `swiftly-playback` (`PlaybackPlan`, `Segment`,
//! `Trickplay`) and from `swiftly-library` (`PlaylistDirectory`, `ShelfSource`), and
//! `swiftly-jellyfin` sits below both. A Jellyfin or Emby client can implement it from a
//! crate above `swiftly-jellyfin`; `swiftly-plex` implements it for `PlexClient`.
//!
//! Left out on purpose, because their types are not ported yet: `watchers` (`Watcher`),
//! `airplayPlan` (`AirPlayInfo`), the DEBUG-only `userDataRaw`/`userDataBackPut`, and the
//! Jellyfin-only helper protocols (`QuickSignIn`, `RemoteSessionServer`,
//! `DisplayPreferencesServer`, `ActiveEncodingServer`): a server without them simply does not
//! implement the extra trait. Defaults of the Swift extension are covered by
//! [`ItemsQuery::default`](swiftly_jellyfin::ItemsQuery) and `Option` parameters.

use std::future::Future;

use swiftly_jellyfin::{PendingReport, ServerKind, Session, TrackIndices};
use swiftly_library::home::HomePageSource;
use swiftly_library::{
    CollectionDirectory, LibraryShare, PlaylistDirectory, ShelfSource, TitleFilter,
};
use swiftly_model::{Item, ItemsResponse, PublicSystemInfo};
use swiftly_net::ErrorKind;
use swiftly_rules::chapter::Chapter;
use swiftly_rules::download_quality::DownloadQuality;

use crate::device_profile::DeviceProfile;
use crate::offering_layer::AccountPreGift;
use crate::playback_plan::PlaybackPlan;
use crate::sections::Segment;
use crate::trickplay::Trickplay;

/// What a server may offer beyond the common core (`ServerCapability`, MediaServer.swift:35).
/// The user interface asks and shows only what the server can do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ServerCapability {
    /// Quick Connect sign-in.
    QuickConnect,
    /// A list of public users to pick from.
    PublicUsers,
    /// SyncPlay.
    SyncPlay,
    /// Reports this device to the server and takes remote commands.
    RemoteControl,
    /// Sends playback to another device of the account.
    PlayOnOtherDevice,
    /// Display preferences kept on the server.
    SettingsSync,
    /// Preview pictures when scrubbing.
    Trickplay,
    /// Intro and credits sections.
    IntroSegments,
    /// Chapters.
    Chapters,
    /// Collections.
    Collections,
    /// Playlists.
    Playlists,
    /// Favourites.
    Favorites,
    /// Mark watched / unwatched.
    MarkWatched,
    /// Similar titles.
    Similar,
    /// Extras and trailers.
    Extras,
    /// Genres.
    Genres,
    /// Seerr.
    Seerr,
    /// Downloads.
    Downloads,
}

impl ServerCapability {
    /// Every capability, in declaration order (`CaseIterable`).
    pub const ALL: [Self; 18] = [
        Self::QuickConnect,
        Self::PublicUsers,
        Self::SyncPlay,
        Self::RemoteControl,
        Self::PlayOnOtherDevice,
        Self::SettingsSync,
        Self::Trickplay,
        Self::IntroSegments,
        Self::Chapters,
        Self::Collections,
        Self::Playlists,
        Self::Favorites,
        Self::MarkWatched,
        Self::Similar,
        Self::Extras,
        Self::Genres,
        Self::Seerr,
        Self::Downloads,
    ];
}

/// The library "views" a page asks for and a server answers (`MediaServer` protocol).
///
/// Every method is the Swift one with the same name in snake case. Errors are
/// [`ErrorKind`]; a server's own errors map onto it. `Option`/`Vec` results that the Swift
/// code returns as `nil` on failure stay `Option`.
pub trait MediaServer: HomePageSource {
    /// Which kind of server this is.
    fn kind(&self) -> ServerKind;
    /// What the server can do.
    fn capabilities(&self) -> Vec<ServerCapability>;
    /// The address in use.
    fn base_url(&self) -> String;

    // Account and connection
    /// The signed-in session, if any.
    fn current_session(&self) -> impl Future<Output = Option<Session>> + Send;
    /// What the server calls itself.
    fn public_system_info(
        &self,
    ) -> impl Future<Output = Result<PublicSystemInfo, ErrorKind>> + Send;
    /// Is the server reachable (and the right one)?
    fn check_reachability(
        &self,
    ) -> impl Future<Output = Result<PublicSystemInfo, ErrorKind>> + Send;
    /// Sign-in with a name and password.
    fn authenticate(
        &self,
        username: &str,
        password: &str,
    ) -> impl Future<Output = Result<Session, ErrorKind>> + Send;
    /// Forgets the account on this client.
    fn sign_off(&self) -> impl Future<Output = ()> + Send;
    /// `false` only when the server says the token is dead.
    fn session_applies_still(&self) -> impl Future<Output = bool> + Send;
    /// What the account may do.
    fn account_defaults(&self) -> impl Future<Output = Option<AccountPreGift>> + Send;

    // Libraries and lists
    /// The libraries, as home-page views.
    fn user_views(&self, hidden: bool)
    -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// A page of titles.
    fn items(
        &self,
        query: &swiftly_jellyfin::ItemsQuery,
    ) -> impl Future<Output = Result<ItemsResponse, ErrorKind>> + Send;
    /// Search by name.
    fn search(
        &self,
        term: &str,
        limit: i64,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// All genre names.
    fn genres(&self) -> impl Future<Output = Result<Vec<String>, ErrorKind>> + Send;
    /// The video playlists with their members.
    fn playlist_directory(
        &self,
    ) -> impl Future<Output = Result<PlaylistDirectory, ErrorKind>> + Send;
    /// The entries of a playlist.
    fn playlist_entries(
        &self,
        playlist: &str,
        lean: bool,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// The collections with their members.
    fn collection_directory(
        &self,
        view_list: &[Item],
    ) -> impl Future<Output = Result<CollectionDirectory, ErrorKind>> + Send;
    /// How the movies and series are shared in a library.
    fn library_shares(
        &self,
        views: &[Item],
    ) -> impl Future<Output = std::collections::HashMap<String, LibraryShare>> + Send;
    /// "All" across libraries.
    fn title_filter(
        &self,
        source: &ShelfSource,
        filters: &[String],
        is_watched: Option<bool>,
    ) -> impl Future<Output = Result<TitleFilter, ErrorKind>> + Send;
    /// The watchlist: favourites, once per work, paged.
    fn remembered_items(
        &self,
        types: &[String],
        sort_by: &str,
        sort_order: &str,
        start_index: i64,
        limit: i64,
    ) -> impl Future<Output = Result<ItemsResponse, ErrorKind>> + Send;
    /// Titles of a person with the total.
    fn title_with_number_person(
        &self,
        id: &str,
        limit: i64,
        start_index: i64,
    ) -> impl Future<Output = Option<(Vec<Item>, i64)>> + Send;
    /// Titles of a genre with the total.
    fn title_with_number_genre(
        &self,
        genre: &str,
        limit: i64,
        start_index: i64,
    ) -> impl Future<Output = Option<(Vec<Item>, i64)>> + Send;

    // Details
    /// One title.
    fn item(&self, id: &str) -> impl Future<Output = Result<Item, ErrorKind>> + Send;
    /// Titles like this one.
    fn similar(
        &self,
        item_id: &str,
        limit: i64,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// Extras as files.
    fn extras(&self, item_id: &str) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// Trailers as files.
    fn trailer(&self, item_id: &str) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// The seasons of a series.
    fn seasons(&self, series_id: &str)
    -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// A season's episodes, or all of the series.
    fn episodes(
        &self,
        series_id: &str,
        season_id: Option<&str>,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// The episode after the last watched.
    fn next_episode_series(
        &self,
        series_id: &str,
    ) -> impl Future<Output = Result<Option<Item>, ErrorKind>> + Send;
    /// The episode after this one.
    fn episode_post(
        &self,
        item_id: &str,
        series_id: &str,
    ) -> impl Future<Output = Result<Option<Item>, ErrorKind>> + Send;
    /// Where to continue in a series; `None` also on failure.
    fn state_in_series(&self, series_id: &str) -> impl Future<Output = Option<Item>> + Send;
    /// Like [`state_in_series`](Self::state_in_series), but a failure is an error.
    fn state_in_series_checked(
        &self,
        series_id: &str,
    ) -> impl Future<Output = Result<Option<Item>, ErrorKind>> + Send;
    /// Asks the server to refresh a title's metadata.
    fn metadata_refresh(&self, item_id: &str)
    -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// Puts a title on or off the watchlist.
    fn set_watchlist(
        &self,
        item_id: &str,
        on: bool,
    ) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// Marks a title watched or unwatched.
    fn set_watched(
        &self,
        item_id: &str,
        on: bool,
    ) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// Takes a title out of "continue watching".
    fn point_back_set(&self, item_id: &str) -> impl Future<Output = Result<(), ErrorKind>> + Send;

    // Images
    /// The picture address of a title.
    fn image_url(
        &self,
        item: &Item,
        max_height: i64,
    ) -> impl Future<Output = Option<String>> + Send;

    // Playback
    /// What to open and how.
    fn playback_plan(
        &self,
        item_id: &str,
        profile: &DeviceProfile,
        audio_stream_index: Option<i64>,
        subtitle_stream_index: Option<i64>,
        media_source_id: Option<&str>,
    ) -> impl Future<Output = Result<Option<PlaybackPlan>, ErrorKind>> + Send;
    /// The address for a download.
    fn download_url(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        quality: DownloadQuality,
        audio_stream_index: Option<i64>,
    ) -> impl Future<Output = Result<String, ErrorKind>> + Send;
    /// Skip sections of a title (empty on failure).
    fn sections(&self, item_id: &str) -> impl Future<Output = Vec<Segment>> + Send;
    /// Skip sections to store for offline use; `None` on failure.
    fn segments_to_store(&self, item_id: &str)
    -> impl Future<Output = Option<Vec<Segment>>> + Send;
    /// Preview-picture details.
    fn trickplay(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        target: i64,
    ) -> impl Future<Output = Option<Trickplay>> + Send;
    /// One preview sheet.
    fn trickplay_sheet(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        width: i64,
        sheet: i64,
    ) -> impl Future<Output = Option<Vec<u8>>> + Send;
    /// Chapters (empty on failure).
    fn chapter(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
    ) -> impl Future<Output = Vec<Chapter>> + Send;

    // Reports
    /// Playback started.
    fn report_start(
        &self,
        item_id: &str,
        plan: &PlaybackPlan,
        ticks: i64,
        tracks: TrackIndices,
    ) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// Playback progress.
    fn report_progress(
        &self,
        item_id: &str,
        plan: &PlaybackPlan,
        position_ticks: i64,
        paused: bool,
        tracks: TrackIndices,
    ) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// Playback stopped.
    fn report_stopped(
        &self,
        item_id: &str,
        plan: &PlaybackPlan,
        position_ticks: i64,
    ) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// Sends positions made offline; returns the ids of the settled reports.
    fn report_later(&self, opened: &[PendingReport]) -> impl Future<Output = Vec<String>> + Send;
}
