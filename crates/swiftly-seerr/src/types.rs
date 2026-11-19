//! Types of the full Seerr API: account, quota, settings, media with downloads, requests, search
//! results, titles, people. Every field is lenient (missing or `null` never fails a read, an
//! unknown number is a neutral value), because Seerr, Jellyseerr and Overseerr differ in details.

use serde::{Deserialize, Deserializer};

use crate::models::{SeerrHit, SeerrPerson, SeerrState};
use crate::perms::Perms;
use crate::status::{SeerrStatus, StatusInput, status_of};

/// `null` or a missing list reads as an empty list.
pub(crate) fn list<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(d)?.unwrap_or_default())
}

/// `null` reads as the default.
pub(crate) fn or_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

// ---- account ----

/// A Seerr user (`GET auth/me`, request and issue authors).
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SeerrUser {
    /// User id.
    pub id: i64,
    /// Display name the server computed.
    pub display_name: Option<String>,
    /// Account name.
    pub username: Option<String>,
    /// Name on the Jellyfin server.
    pub jellyfin_username: Option<String>,
    /// Mail address.
    pub email: Option<String>,
    /// Avatar path or address.
    pub avatar: Option<String>,
    /// Permission bitmask.
    #[serde(deserialize_with = "or_default")]
    pub permissions: i64,
    /// Number of requests made.
    #[serde(deserialize_with = "or_default")]
    pub request_count: i64,
}

impl SeerrUser {
    /// The name to show: display name, Jellyfin name, account name, mail.
    pub fn name(&self) -> String {
        [
            &self.display_name,
            &self.jellyfin_username,
            &self.username,
            &self.email,
        ]
        .into_iter()
        .flatten()
        .find(|n| !n.is_empty())
        .cloned()
        .unwrap_or_default()
    }

    /// The permissions as the typed helper.
    pub fn perms(&self) -> Perms {
        Perms(self.permissions)
    }
}

/// The signed-in account (`GET auth/me`).
pub type Me = SeerrUser;

/// One half of the quota (films or series; series count seasons).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuotaPart {
    /// Window in days; `None` without a limit.
    pub days: Option<i64>,
    /// Allowed requests in the window; `None` = unlimited.
    pub limit: Option<i64>,
    /// Used in the window.
    #[serde(deserialize_with = "or_default")]
    pub used: i64,
    /// Left in the window.
    pub remaining: Option<i64>,
    /// The server's flag (the quota is used up).
    #[serde(deserialize_with = "or_default")]
    pub restricted: bool,
}

impl QuotaPart {
    /// A limit applies (nothing to show for admins and unlimited accounts).
    pub fn has_limit(&self) -> bool {
        self.limit.is_some_and(|l| l > 0)
    }

    /// Requests left, only with a limit.
    pub fn left(&self) -> Option<i64> {
        if !self.has_limit() {
            return None;
        }
        self.remaining
            .or_else(|| self.limit.map(|l| (l - self.used).max(0)))
    }

    /// Nothing left: no further request of this kind is possible.
    pub fn used_up(&self) -> bool {
        self.has_limit() && (self.restricted || self.left().is_some_and(|r| r <= 0))
    }
}

/// `GET user/{id}/quota`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct Quota {
    /// Films.
    pub movie: QuotaPart,
    /// Series (counted in seasons).
    pub tv: QuotaPart,
}

impl Quota {
    /// The part for `art` (`movie` or `tv`).
    pub fn part(&self, art: &str) -> QuotaPart {
        if art == "tv" { self.tv } else { self.movie }
    }
}

/// `GET settings/public` (no sign-in needed).
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PublicSettings {
    /// Name of the instance.
    pub application_title: Option<String>,
    /// Films may be requested in 4K.
    #[serde(deserialize_with = "or_default")]
    pub movie4k_enabled: bool,
    /// Series may be requested in 4K.
    #[serde(deserialize_with = "or_default")]
    pub series4k_enabled: bool,
    /// Single seasons may be requested.
    #[serde(deserialize_with = "or_default")]
    pub partial_requests_enabled: bool,
    /// Specials (season 0) can be requested.
    #[serde(deserialize_with = "or_default")]
    pub enable_special_episodes: bool,
    /// The instance hides available titles in discover.
    #[serde(deserialize_with = "or_default")]
    pub hide_available: bool,
    /// The instance hides blocklisted titles in discover.
    #[serde(deserialize_with = "or_default")]
    pub hide_blocklisted: bool,
    /// Region of discover.
    pub discover_region: Option<String>,
    /// Language filter of discover.
    pub original_language: Option<String>,
    /// `jellyfin`, `emby`, `plex`.
    pub media_server_type: Option<i64>,
}

impl PublicSettings {
    /// 4K exists for `art`.
    pub fn four_k_enabled(&self, art: &str) -> bool {
        if art == "tv" {
            self.series4k_enabled
        } else {
            self.movie4k_enabled
        }
    }
}

/// Kind of a discover slider of `GET settings/discover`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SliderKind {
    /// 1.
    RecentlyAdded,
    /// 2.
    RecentRequests,
    /// 3 (Plex only).
    PlexWatchlist,
    /// 4.
    Trending,
    /// 5.
    PopularMovies,
    /// 6.
    MovieGenres,
    /// 7.
    UpcomingMovies,
    /// 8.
    Studios,
    /// 9.
    PopularTv,
    /// 10.
    TvGenres,
    /// 11.
    UpcomingTv,
    /// 12.
    Networks,
    /// 13: films by keyword.
    MovieKeyword,
    /// 14: films by genre.
    MovieGenre,
    /// 15: series by keyword.
    TvKeyword,
    /// 16: series by genre.
    TvGenre,
    /// 17: search.
    Search,
    /// 18: films by studio.
    Studio,
    /// 19: series by network.
    Network,
    /// A kind this client does not know (skipped).
    Other(i64),
}

impl SliderKind {
    /// From the API number.
    pub fn from_raw(raw: i64) -> Self {
        match raw {
            1 => Self::RecentlyAdded,
            2 => Self::RecentRequests,
            3 => Self::PlexWatchlist,
            4 => Self::Trending,
            5 => Self::PopularMovies,
            6 => Self::MovieGenres,
            7 => Self::UpcomingMovies,
            8 => Self::Studios,
            9 => Self::PopularTv,
            10 => Self::TvGenres,
            11 => Self::UpcomingTv,
            12 => Self::Networks,
            13 => Self::MovieKeyword,
            14 => Self::MovieGenre,
            15 => Self::TvKeyword,
            16 => Self::TvGenre,
            17 => Self::Search,
            18 => Self::Studio,
            19 => Self::Network,
            other => Self::Other(other),
        }
    }

    /// Slider types this client can fill without a Plex account.
    pub fn supported(self) -> bool {
        !matches!(self, Self::Other(_) | Self::PlexWatchlist | Self::Search)
    }
}

/// One slider of the admin's discover page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoverSlider {
    /// Slider id.
    pub id: i64,
    /// Kind.
    pub kind: SliderKind,
    /// Own title (custom sliders).
    pub title: Option<String>,
    /// Switched on.
    pub enabled: bool,
    /// Kind data (a genre or keyword id, a studio id, a search term).
    pub data: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct RawSlider {
    id: i64,
    #[serde(rename = "type")]
    kind: i64,
    title: Option<String>,
    #[serde(deserialize_with = "or_default")]
    enabled: bool,
    data: Option<serde_json::Value>,
}

impl From<RawSlider> for DiscoverSlider {
    fn from(r: RawSlider) -> Self {
        Self {
            id: r.id,
            kind: SliderKind::from_raw(r.kind),
            title: r.title.filter(|t| !t.is_empty()),
            enabled: r.enabled,
            data: r.data.and_then(|d| match d {
                serde_json::Value::String(s) => Some(s),
                serde_json::Value::Number(n) => Some(n.to_string()),
                _ => None,
            }),
        }
    }
}

// ---- media, downloads, requests ----

/// The episode a queue item belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QueueEpisode {
    /// Season.
    #[serde(deserialize_with = "or_default")]
    pub season_number: i64,
    /// Episode.
    #[serde(deserialize_with = "or_default")]
    pub episode_number: i64,
}

/// One entry of the download queue of Radarr / Sonarr (`downloadStatus[]`).
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QueueItem {
    /// Whole size in bytes.
    #[serde(deserialize_with = "or_default")]
    pub size: f64,
    /// Bytes still to fetch.
    #[serde(deserialize_with = "or_default")]
    pub size_left: f64,
    /// Queue state text of the downloader.
    pub status: Option<String>,
    /// `HH:MM:SS` until done.
    pub time_left: Option<String>,
    /// ISO time of the expected end.
    pub estimated_completion_time: Option<String>,
    /// Name of the release.
    pub title: Option<String>,
    /// Episode of a series entry.
    pub episode: Option<QueueEpisode>,
}

impl QueueItem {
    /// Seconds of `time_left` (`HH:MM:SS`).
    pub fn seconds_left(&self) -> Option<u32> {
        let t = self.time_left.as_deref()?;
        let mut total: u32 = 0;
        let parts: Vec<&str> = t.split(':').collect();
        if parts.len() != 3 {
            return None;
        }
        for p in parts {
            let n: f64 = p.trim().parse().ok()?;
            total = total.checked_mul(60)?.checked_add(n.max(0.0) as u32)?;
        }
        Some(total)
    }
}

/// Status of one season on the media.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SeasonStatus {
    /// Season number.
    #[serde(deserialize_with = "or_default")]
    pub season_number: i64,
    /// Normal lane.
    pub status: SeerrState,
    /// 4K lane.
    pub status4k: SeerrState,
}

/// `mediaInfo`: what Seerr knows about a title.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MediaInfo {
    /// Seerr's own media id (needed for issues and delete).
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// TMDB id.
    pub tmdb_id: Option<i64>,
    /// `movie` or `tv`.
    pub media_type: Option<String>,
    /// Normal lane.
    pub status: SeerrState,
    /// 4K lane.
    pub status4k: SeerrState,
    /// Requests for this title.
    #[serde(deserialize_with = "list")]
    pub requests: Vec<RequestRow>,
    /// Per season.
    #[serde(deserialize_with = "list")]
    pub seasons: Vec<SeasonStatus>,
    /// Queue of the normal lane.
    #[serde(deserialize_with = "list")]
    pub download_status: Vec<QueueItem>,
    /// Queue of the 4K lane.
    #[serde(deserialize_with = "list")]
    pub download_status4k: Vec<QueueItem>,
}

impl MediaInfo {
    /// Status of the lane.
    pub fn lane(&self, is4k: bool) -> SeerrState {
        if is4k { self.status4k } else { self.status }
    }

    /// Queue of the lane.
    pub fn queue(&self, is4k: bool) -> &[QueueItem] {
        if is4k {
            &self.download_status4k
        } else {
            &self.download_status
        }
    }

    /// Status of one season in the lane (`Opened` when Seerr does not list it).
    pub fn season_state(&self, number: i64, is4k: bool) -> SeerrState {
        self.seasons
            .iter()
            .find(|s| s.season_number == number)
            .map_or(
                SeerrState::Opened,
                |s| {
                    if is4k { s.status4k } else { s.status }
                },
            )
    }
}

/// `MediaRequestStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum RequestStatus {
    /// 1: waits for an admin.
    #[default]
    Pending,
    /// 2: approved, being searched or fetched.
    Approved,
    /// 3: declined.
    Declined,
    /// 4: Radarr / Sonarr could not take it.
    Failed,
    /// 5: done.
    Completed,
}

impl RequestStatus {
    /// From the API number (unknown = pending).
    pub fn from_raw(raw: i64) -> Self {
        match raw {
            2 => Self::Approved,
            3 => Self::Declined,
            4 => Self::Failed,
            5 => Self::Completed,
            _ => Self::Pending,
        }
    }
}

impl<'de> Deserialize<'de> for RequestStatus {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Option::<serde_json::Value>::deserialize(d)?;
        Ok(v.and_then(|v| v.as_i64())
            .map_or(Self::Pending, Self::from_raw))
    }
}

/// A season of a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RequestSeason {
    /// Season number.
    #[serde(deserialize_with = "or_default")]
    pub season_number: i64,
    /// State of this season's request.
    pub status: RequestStatus,
}

/// One request (`GET request`, `POST request`, `mediaInfo.requests[]`).
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RequestRow {
    /// Request id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// State.
    pub status: RequestStatus,
    /// `movie` or `tv`.
    #[serde(rename = "type")]
    pub media_type: Option<String>,
    /// 4K lane.
    #[serde(deserialize_with = "or_default")]
    pub is4k: bool,
    /// ISO time created.
    pub created_at: Option<String>,
    /// ISO time changed.
    pub updated_at: Option<String>,
    /// Who asked.
    pub requested_by: Option<SeerrUser>,
    /// Who approved or declined.
    pub modified_by: Option<SeerrUser>,
    /// Seasons of a series request (empty = all, or a film).
    #[serde(deserialize_with = "list")]
    pub seasons: Vec<RequestSeason>,
    /// Radarr / Sonarr server id.
    pub server_id: Option<i64>,
    /// Quality profile id.
    pub profile_id: Option<i64>,
    /// Folder.
    pub root_folder: Option<String>,
    /// The title (not in a `mediaInfo.requests[]` entry).
    pub media: Option<Box<MediaInfo>>,
}

impl RequestRow {
    /// Season numbers of the request.
    pub fn season_numbers(&self) -> Vec<i64> {
        self.seasons.iter().map(|s| s.season_number).collect()
    }
}

// ---- search results, titles, people ----

/// A film or series in a list, with what Seerr knows about it.
#[derive(Debug, Clone, PartialEq)]
pub struct TitleCard {
    /// The plain hit (id, art, title, year, pictures, state).
    pub hit: SeerrHit,
    /// `yyyy-mm-dd` when TMDB gives one.
    pub release_date: Option<String>,
    /// Story, trimmed.
    pub overview: Option<String>,
    /// TMDB rating.
    pub rating: Option<f64>,
    /// Seerr's record of it.
    pub media: Option<MediaInfo>,
}

impl TitleCard {
    /// The status word of the card (see [`SeerrStatus`]).
    pub fn status(&self, today: &str, is4k: bool) -> SeerrStatus {
        status_of(&StatusInput {
            media: self.media.as_ref(),
            is4k,
            season: None,
            release_date: self.release_date.as_deref(),
            today,
        })
    }
}

/// A person in a search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersonCard {
    /// TMDB id.
    pub id: i64,
    /// Name.
    pub name: String,
    /// Portrait path.
    pub profile_path: Option<String>,
    /// `Acting`, `Directing`, ...
    pub known_for: Option<String>,
}

/// A collection (film series) in a search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionCard {
    /// TMDB id.
    pub id: i64,
    /// Name.
    pub name: String,
    /// Poster path.
    pub poster_path: Option<String>,
    /// Backdrop path.
    pub backdrop_path: Option<String>,
}

/// One entry of a search.
#[derive(Debug, Clone, PartialEq)]
pub enum SearchResult {
    /// Film or series.
    Title(Box<TitleCard>),
    /// Person.
    Person(PersonCard),
    /// Collection.
    Collection(CollectionCard),
}

/// A page of a list (`page`, `totalPages`, `totalResults`).
#[derive(Debug, Clone, PartialEq)]
pub struct Page<T> {
    /// Page number (1...).
    pub page: i64,
    /// Pages in all.
    pub total_pages: i64,
    /// Entries in all.
    pub total_results: i64,
    /// The entries.
    pub results: Vec<T>,
}

impl<T> Page<T> {
    /// A further page exists.
    pub fn has_more(&self) -> bool {
        self.page < self.total_pages
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct RawResult {
    id: i64,
    media_type: Option<String>,
    title: Option<String>,
    name: Option<String>,
    release_date: Option<String>,
    first_air_date: Option<String>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    profile_path: Option<String>,
    overview: Option<String>,
    vote_average: Option<f64>,
    known_for_department: Option<String>,
    media_info: Option<MediaInfo>,
}

impl RawResult {
    /// A title card; `standard_art` stands in for a missing `mediaType`.
    pub(crate) fn card(self, standard_art: Option<&str>) -> Option<TitleCard> {
        let art = self
            .media_type
            .clone()
            .or_else(|| standard_art.map(str::to_string))?;
        if art != "movie" && art != "tv" {
            return None;
        }
        let title = self
            .title
            .clone()
            .or_else(|| self.name.clone())
            .filter(|t| !t.is_empty())?;
        let date = self
            .release_date
            .clone()
            .or_else(|| self.first_air_date.clone())
            .filter(|d| !d.is_empty());
        Some(TitleCard {
            hit: SeerrHit {
                id: self.id,
                art,
                title,
                year: date
                    .as_ref()
                    .and_then(|d| d.chars().take(4).collect::<String>().parse().ok()),
                poster_path: self.poster_path,
                backdrop_path: self.backdrop_path,
                state: self
                    .media_info
                    .as_ref()
                    .map_or(SeerrState::Opened, |m| m.status),
            },
            release_date: date,
            overview: self
                .overview
                .map(|o| o.trim().to_string())
                .filter(|o| !o.is_empty()),
            rating: self.vote_average.filter(|v| *v > 0.0),
            media: self.media_info,
        })
    }

    pub(crate) fn search_result(self) -> Option<SearchResult> {
        match self.media_type.as_deref() {
            Some("person") => Some(SearchResult::Person(PersonCard {
                id: self.id,
                name: self.name.filter(|n| !n.is_empty())?,
                profile_path: self.profile_path,
                known_for: self.known_for_department,
            })),
            Some("collection") => Some(SearchResult::Collection(CollectionCard {
                id: self.id,
                name: self.name.or(self.title).filter(|n| !n.is_empty())?,
                poster_path: self.poster_path,
                backdrop_path: self.backdrop_path,
            })),
            _ => self.card(None).map(|c| SearchResult::Title(Box::new(c))),
        }
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct RawPage {
    #[serde(deserialize_with = "or_default")]
    page: i64,
    #[serde(deserialize_with = "or_default")]
    total_pages: i64,
    #[serde(deserialize_with = "or_default")]
    total_results: i64,
    #[serde(deserialize_with = "list")]
    results: Vec<RawResult>,
}

impl RawPage {
    fn into_page<T>(self, convert: impl Fn(RawResult) -> Option<T>) -> Page<T> {
        let page = self.page.max(1);
        let results: Vec<T> = self.results.into_iter().filter_map(convert).collect();
        Page {
            page,
            total_pages: self.total_pages.max(page),
            total_results: self.total_results.max(results.len() as i64),
            results,
        }
    }

    pub(crate) fn cards(self, standard_art: Option<&str>) -> Page<TitleCard> {
        self.into_page(|r| r.card(standard_art))
    }

    pub(crate) fn search(self) -> Page<SearchResult> {
        self.into_page(RawResult::search_result)
    }
}

/// A season of a title.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TitleSeason {
    /// Number (0 = specials).
    #[serde(deserialize_with = "or_default")]
    pub season_number: i64,
    /// Episodes.
    #[serde(deserialize_with = "or_default")]
    pub episode_count: i64,
    /// Name.
    pub name: Option<String>,
    /// `yyyy-mm-dd` of the first episode.
    pub air_date: Option<String>,
    /// The episodes of `tv/{id}/season/{n}` (empty when that call failed or TMDB has none).
    #[serde(skip)]
    pub episodes: Vec<TitleEpisode>,
}

/// One episode of a season as TMDB lists it through Seerr.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TitleEpisode {
    /// Number in the season.
    #[serde(deserialize_with = "or_default")]
    pub episode_number: i64,
    /// Name.
    pub name: Option<String>,
    /// Story.
    pub overview: Option<String>,
    /// `yyyy-mm-dd`.
    pub air_date: Option<String>,
    /// Minutes.
    pub runtime: Option<i64>,
    /// Picture path.
    pub still_path: Option<String>,
}

/// The collection a film belongs to.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CollectionRef {
    /// TMDB id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// Name.
    pub name: Option<String>,
    /// Poster path.
    pub poster_path: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct RawGenre {
    name: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct RawCast {
    id: i64,
    name: Option<String>,
    character: Option<String>,
    profile_path: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
pub(crate) struct RawCredits {
    #[serde(deserialize_with = "list")]
    cast: Vec<RawCast>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct RawTitle {
    id: i64,
    title: Option<String>,
    name: Option<String>,
    tagline: Option<String>,
    overview: Option<String>,
    release_date: Option<String>,
    first_air_date: Option<String>,
    #[serde(deserialize_with = "list")]
    genres: Vec<RawGenre>,
    runtime: Option<i64>,
    #[serde(deserialize_with = "list")]
    episode_run_time: Vec<i64>,
    vote_average: Option<f64>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    status: Option<String>,
    #[serde(deserialize_with = "list")]
    seasons: Vec<TitleSeason>,
    credits: Option<RawCredits>,
    belongs_to_collection: Option<CollectionRef>,
    media_info: Option<MediaInfo>,
}

/// A film or series with everything the title page needs.
#[derive(Debug, Clone, PartialEq)]
pub struct TitleInfo {
    /// TMDB id.
    pub id: i64,
    /// `movie` or `tv`.
    pub art: String,
    /// Title.
    pub title: String,
    /// Tagline.
    pub tagline: Option<String>,
    /// Story.
    pub overview: Option<String>,
    /// `yyyy-mm-dd`.
    pub release_date: Option<String>,
    /// All genres.
    pub genres: Vec<String>,
    /// Minutes.
    pub runtime: Option<i64>,
    /// TMDB rating.
    pub rating: Option<f64>,
    /// Poster path.
    pub poster_path: Option<String>,
    /// Backdrop path.
    pub backdrop_path: Option<String>,
    /// TMDB's own state (`Released`, `Returning Series`, ...).
    pub tmdb_status: Option<String>,
    /// Seasons without specials.
    pub seasons: Vec<TitleSeason>,
    /// At most twenty cast members.
    pub cast: Vec<SeerrPerson>,
    /// The collection of a film.
    pub collection: Option<CollectionRef>,
    /// Seerr's record, with requests, seasons and downloads.
    pub media: Option<MediaInfo>,
}

impl RawTitle {
    pub(crate) fn into_info(self, art: &str) -> TitleInfo {
        let date = self
            .release_date
            .or(self.first_air_date)
            .filter(|d| !d.is_empty());
        TitleInfo {
            id: self.id,
            art: art.to_string(),
            title: self.title.or(self.name).unwrap_or_default(),
            tagline: self.tagline.filter(|t| !t.is_empty()),
            overview: self
                .overview
                .map(|o| o.trim().to_string())
                .filter(|o| !o.is_empty()),
            release_date: date,
            genres: self.genres.into_iter().filter_map(|g| g.name).collect(),
            runtime: self
                .runtime
                .or_else(|| self.episode_run_time.first().copied()),
            rating: self.vote_average.filter(|v| *v > 0.0),
            poster_path: self.poster_path,
            backdrop_path: self.backdrop_path,
            tmdb_status: self.status,
            seasons: self
                .seasons
                .into_iter()
                .filter(|s| s.season_number > 0)
                .collect(),
            cast: self
                .credits
                .map(|c| c.cast)
                .unwrap_or_default()
                .into_iter()
                .filter_map(|k| {
                    Some(SeerrPerson {
                        id: k.id,
                        name: k.name.filter(|n| !n.is_empty())?,
                        role: k.character.filter(|c| !c.is_empty()),
                        image_path: k.profile_path,
                    })
                })
                .take(20)
                .collect(),
            collection: self.belongs_to_collection.filter(|c| c.id > 0),
            media: self.media_info,
        }
    }
}

impl TitleInfo {
    /// The status of the title, or of one season of it, in one lane.
    pub fn status(&self, today: &str, is4k: bool, season: Option<i64>) -> SeerrStatus {
        let date = season
            .and_then(|n| self.seasons.iter().find(|s| s.season_number == n))
            .and_then(|s| s.air_date.as_deref())
            .or(self.release_date.as_deref());
        status_of(&StatusInput {
            media: self.media.as_ref(),
            is4k,
            season,
            release_date: date,
            today,
        })
    }
}

/// `GET person/{id}`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PersonInfo {
    /// TMDB id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// Name.
    pub name: Option<String>,
    /// Biography.
    pub biography: Option<String>,
    /// `yyyy-mm-dd`.
    pub birthday: Option<String>,
    /// Birthplace.
    pub place_of_birth: Option<String>,
    /// Portrait path.
    pub profile_path: Option<String>,
    /// `Acting`, ...
    pub known_for_department: Option<String>,
}

/// `GET person/{id}/combined_credits`, each (art, id) once.
#[derive(Debug, Clone, PartialEq)]
pub struct Credits {
    /// Roles as actor.
    pub cast: Vec<TitleCard>,
    /// Work behind the camera.
    pub crew: Vec<TitleCard>,
}

/// `GET collection/{id}`.
#[derive(Debug, Clone, PartialEq)]
pub struct Collection {
    /// TMDB id.
    pub id: i64,
    /// Name.
    pub name: String,
    /// Story.
    pub overview: Option<String>,
    /// Poster path.
    pub poster_path: Option<String>,
    /// Backdrop path.
    pub backdrop_path: Option<String>,
    /// The films of the collection.
    pub parts: Vec<TitleCard>,
}

/// A genre tile with some backdrops (`discover/genreslider/*`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct GenreCard {
    /// TMDB genre id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// Name.
    pub name: Option<String>,
    /// Backdrop paths.
    #[serde(deserialize_with = "list")]
    pub backdrops: Vec<String>,
}
