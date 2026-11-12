//! The exported home view model: a thin object over `swiftly_vm::HomeVm`, plus the records of
//! its parts. The records are declared once in `swiftly-vm`; the `remote` declarations below
//! only tell UniFFI their shape (a mismatch does not compile).

use std::sync::Arc;

use swiftly_jellyfin::ServerKind;
use swiftly_vm::{
    AccountRef, Badge, Change, HomeIntent, HomePrefs, ImageKind, ImageRef, Rail, RailKind,
    RailsPart, Status, StatusPart, Tile, TileFacts,
};

use crate::error::CoreError;
use crate::transport::CoreTransport;

#[uniffi::remote(Enum)]
pub enum ServerKind {
    Jellyfin,
    Emby,
    Plex,
}

#[uniffi::remote(Record)]
pub struct AccountRef {
    pub base_url: String,
    pub user_id: String,
    pub token: String,
    pub server_kind: ServerKind,
    pub device_id: String,
    #[uniffi(default = None)]
    pub plex_machine_id: Option<String>,
    #[uniffi(default = None)]
    pub plex_account_token: Option<String>,
}

#[uniffi::remote(Record)]
pub struct HomePrefs {
    pub disconnected: bool,
    pub genre_chips: bool,
    pub start_genres: Vec<String>,
}

#[uniffi::remote(Enum)]
pub enum ImageKind {
    Poster,
    Backdrop,
}

#[uniffi::remote(Record)]
pub struct ImageRef {
    pub address: String,
    pub kind: ImageKind,
    pub wanted_width: u32,
    pub wanted_height: u32,
}

#[uniffi::remote(Enum)]
pub enum Badge {
    Watched,
    Favorite,
    Unplayed { count: u32 },
    Seasons { count: u32 },
}

#[uniffi::remote(Record)]
pub struct Tile {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub progress: Option<f32>,
    pub image: Option<ImageRef>,
    pub badges: Vec<Badge>,
    pub remaining: Option<String>,
    pub facts: TileFacts,
}

#[uniffi::remote(Record)]
pub struct TileFacts {
    pub kind: Option<String>,
    pub name: String,
    pub year: Option<i32>,
    pub series_id: Option<String>,
    pub season_id: Option<String>,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    pub child_count: Option<i32>,
}

#[uniffi::remote(Enum)]
pub enum RailKind {
    ContinueWatching,
    NextEpisode,
    NewMovies,
    NewSeries,
    NewArrivals,
    Genre,
}

#[uniffi::remote(Record)]
pub struct Rail {
    pub id: String,
    pub title_key: String,
    pub title: String,
    pub kind: RailKind,
    pub count: u32,
    pub ids: Vec<String>,
    pub tiles: Vec<Tile>,
}

#[uniffi::remote(Record)]
pub struct RailsPart {
    pub version: u64,
    pub rails: Vec<Rail>,
}

#[uniffi::remote(Enum)]
pub enum Status {
    Loading,
    Ready,
    Offline,
    SignedOut,
}

#[uniffi::remote(Record)]
pub struct StatusPart {
    pub version: u64,
    pub status: Status,
    pub preview: bool,
    pub refreshing: bool,
}

#[uniffi::remote(Enum)]
pub enum HomeIntent {
    Load,
    Refresh,
    AccountSwitched { account: Option<AccountRef> },
    Visible { rail: String },
}

#[uniffi::remote(Record)]
pub struct Change {
    pub version: u64,
    pub parts: u32,
}

/// Bits of `Change.parts`.
/// A library or collection chosen for the home page.
/// The details line of the focused tile (`HomeVm::tile_details`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TileDetails {
    pub id: String,
    /// Year, runtime and genre in one line.
    pub details_line: String,
    pub overview: Option<String>,
    /// Community rating as "7,5".
    pub rating: Option<String>,
    pub age_rating: Option<String>,
    /// "Noch 12 Min." for a started title.
    pub remaining: Option<String>,
    /// Only for an episode.
    pub episode_name: Option<String>,
    /// Production year.
    pub year: Option<i32>,
    /// Runtime in seconds when positive.
    pub runtime_seconds: Option<f64>,
    /// Community rating as the server gave it.
    pub community_rating: Option<f64>,
    /// Age rating as the server gave it (before the wording).
    pub official_rating: Option<String>,
    /// The second playback resumes at, when started.
    pub resume_seconds: Option<f64>,
}

impl From<swiftly_vm::TileDetails> for TileDetails {
    fn from(d: swiftly_vm::TileDetails) -> Self {
        Self {
            id: d.id,
            details_line: d.details_line,
            overview: d.overview,
            rating: d.rating,
            age_rating: d.age_rating,
            remaining: d.remaining,
            episode_name: d.episode_name,
            year: d.year,
            runtime_seconds: d.runtime_seconds,
            community_rating: d.community_rating,
            official_rating: d.official_rating,
            resume_seconds: d.resume_seconds,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct HomeLibraryChoice {
    pub id: String,
    pub name: String,
    pub collection: bool,
}

/// The effective combined row order for the settings list: `stored` healed against the fixed rows that exist and
/// the chosen libraries. Save the result (after a move) under the per-server setting `startReihenfolge`.
#[uniffi::export]
pub fn home_row_order(
    stored: Vec<String>,
    disconnected: bool,
    libraries: Vec<HomeLibraryChoice>,
) -> Vec<String> {
    let libs: Vec<_> = libraries
        .iter()
        .map(|c| swiftly_library::StartLibrary::new(&c.id, &c.name, c.collection))
        .collect();
    swiftly_library::StartOrder::applicable(&stored, disconnected, &libs)
}

/// Moves one row of the combined order (`from` to `to`, clamped).
#[uniffi::export]
pub fn home_row_order_moved(list: Vec<String>, from: u32, to: u32) -> Vec<String> {
    swiftly_library::StartOrder::moved(&list, from as usize, to as usize)
}

#[uniffi::export]
pub fn part_rails() -> u32 {
    swiftly_vm::part::RAILS
}

/// Bits of `Change.parts`.
#[uniffi::export]
pub fn part_status() -> u32 {
    swiftly_vm::part::STATUS
}

/// The home page: parts to read, intents to send, `changed` to wait on.
#[derive(uniffi::Object)]
pub struct HomeVm {
    vm: swiftly_vm::HomeVm<CoreTransport>,
}

impl HomeVm {
    pub(crate) fn wrap(vm: swiftly_vm::HomeVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { vm })
    }
}

#[uniffi::export]
impl HomeVm {
    /// The version of the view model.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// The shared load state (additive to `status`).
    pub fn load(&self) -> crate::state::LoadPart {
        crate::state::LoadPart::of(self.vm.version(), self.vm.load())
    }

    /// Where the page stands.
    pub fn status(&self) -> StatusPart {
        StatusPart::clone(&self.vm.status())
    }

    /// The rails (ids of all titles, tile data of the window).
    pub fn rails(&self) -> RailsPart {
        RailsPart::clone(&self.vm.rails())
    }

    /// Tile data of `count` titles of a rail from `start` on.
    pub fn tiles(&self, rail: String, start: u32, count: u32) -> Vec<Tile> {
        self.vm.tiles(&rail, start as usize, count as usize)
    }

    /// The wide picture of a title on the page (for a head that follows the focus), or `None`.
    pub fn hero_image(&self, id: String, width: u32) -> Option<ImageRef> {
        self.vm.hero_image(&id, width)
    }

    /// An intent. Never blocks.
    pub fn send(&self, intent: HomeIntent) {
        self.vm.send(intent);
    }

    /// The chosen libraries and collections (`startBibliotheken`) as rows; call before `Load`.
    pub fn set_start_libraries(&self, choice: Vec<HomeLibraryChoice>) {
        self.vm.set_start_libraries(
            choice
                .into_iter()
                .map(|c| swiftly_library::StartLibrary::new(&c.id, &c.name, c.collection))
                .collect(),
        );
    }

    /// The stored combined row order (`startReihenfolge`: fixed raw values and `library:<id>`); the rails part
    /// updates at once. Empty: the old order.
    pub fn set_row_order(&self, order: Vec<String>) {
        self.vm.set_row_order(order);
    }

    /// Returns at once when the view model is newer than `seen`, else waits (changes coalesce).
    /// Cancelling the Swift `Task` drops this future.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// The details line of one title for the focused tile (one request for the full title); `None` when the
    /// server cannot be asked or the title cannot be read. Additive: `Tile` is unchanged.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn tile_details(&self, id: String) -> Result<Option<TileDetails>, CoreError> {
        Ok(self.vm.tile_details(&id).await.map(TileDetails::from))
    }

    /// The details of many titles with one request (the TV header reads every row up front); titles the server
    /// does not answer for are missing.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn tile_details_many(&self, ids: Vec<String>) -> Result<Vec<TileDetails>, CoreError> {
        Ok(self
            .vm
            .tile_details_many(&ids)
            .await
            .into_iter()
            .map(TileDetails::from)
            .collect())
    }

    /// Observers parked in `changed` (proves a cancelled Task dropped its future).
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}
