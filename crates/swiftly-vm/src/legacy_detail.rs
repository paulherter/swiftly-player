#![allow(missing_docs)]
//! The title, series and person calls of the old Android facade (`Kern.title`, `series`, `episodes`, `titleField`,
//! `trailers`, `person`, `episodeAfter`, `shuffleStart`, `remember`, `watched`, `metadataRefresh`) as the finished JSON the
//! Compose code parses. Built from the same client calls and text rules as `DetailVm`, `SeriesVm` and `PersonModel`.
//! Jellyfin and Emby accounts; a Plex account answers with an error here, so the Swift path stays for Plex until
//! the Plex rules are compared the same way.

use std::sync::{Arc, Mutex, PoisonError};

use serde::Serialize;
use swiftly_images::{ImageAddress, ImageKind as Art, ImageMetric, ImageSelection};
use swiftly_jellyfin::ItemsQuery;
use swiftly_library::ListRules;
use swiftly_library::series_state::SeasonSelectionRule;
use swiftly_library::shuffle_run::{Rng, ShuffleRun};
use swiftly_model::MediaVersions;
use swiftly_model::{Item, Person};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_rules::display_rules::runtime_show;

use crate::account::AccountRef;
use crate::detail::fetch_plan;
use crate::detail_more::{TrailerCandidate, file_excerpt, trailer_candidates};
use crate::home::{Client, Source, build_source};
use crate::host::Host;
use crate::legacy_library::{LegacyGridTile, grid_tile_sorted};
use crate::plex::Plex;
use crate::tile::Words;
use crate::title_text::{TitleText, resume_from};
use std::future::Future;
use swiftly_playback::media_server::MediaServer;
use swiftly_playback::playback_plan::PlaybackPlan;
use swiftly_rules::alphabet_index::Sorting;

#[derive(Serialize)]
struct PersonOut {
    id: String,
    name: String,
    #[serde(rename = "rolle", skip_serializing_if = "Option::is_none")]
    role: Option<String>,
    #[serde(rename = "bild", skip_serializing_if = "Option::is_none")]
    image: Option<String>,
}

#[derive(Serialize)]
struct FileOut {
    #[serde(skip_serializing_if = "Option::is_none")]
    container: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    video: Option<String>,
    #[serde(rename = "ton")]
    audio: Vec<String>,
    #[serde(rename = "untertitel")]
    subtitle: String,
    #[serde(rename = "hatUntertitel")]
    has_subtitle: bool,
}

#[derive(Serialize)]
struct VersionOut {
    id: String,
    label: String,
}

#[derive(Serialize)]
struct TitleOut {
    id: String,
    name: String,
    #[serde(rename = "typ")]
    kind: String,
    #[serde(rename = "nebenzeile")]
    secondary_line: String,
    #[serde(rename = "jahrLaufzeit")]
    year_runtime: String,
    #[serde(rename = "kopfbild", skip_serializing_if = "Option::is_none")]
    header_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    logo: Option<String>,
    #[serde(rename = "bewertung", skip_serializing_if = "Option::is_none")]
    rating: Option<f64>,
    #[serde(rename = "freigabe", skip_serializing_if = "Option::is_none")]
    sharing: Option<String>,
    #[serde(rename = "planDa")]
    plan_present: bool,
    lossless: bool,
    #[serde(rename = "methode", skip_serializing_if = "Option::is_none")]
    method: Option<String>,
    #[serde(rename = "fortsetzenAb", skip_serializing_if = "Option::is_none")]
    resume_from: Option<f64>,
    #[serde(rename = "fortsetzenText", skip_serializing_if = "Option::is_none")]
    resume_text: Option<String>,
    #[serde(rename = "restzeit", skip_serializing_if = "Option::is_none")]
    remaining_time: Option<String>,
    #[serde(rename = "fortschritt", skip_serializing_if = "Option::is_none")]
    progress: Option<f64>,
    #[serde(rename = "beschreibung", skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(rename = "regie")]
    direction: Vec<String>,
    #[serde(rename = "darsteller")]
    actors: Vec<PersonOut>,
    #[serde(rename = "gemerkt")]
    remembered: bool,
    #[serde(rename = "gesehen")]
    watched: bool,
    #[serde(rename = "datei", skip_serializing_if = "Option::is_none")]
    file: Option<FileOut>,
    #[serde(rename = "kulisse", skip_serializing_if = "Option::is_none")]
    backdrop: Option<String>,
    #[serde(rename = "fassungen")]
    versions: Vec<VersionOut>,
}

#[derive(Serialize)]
struct StateOut {
    id: String,
    #[serde(rename = "fortsetzen")]
    resume: bool,
    #[serde(rename = "restzeit", skip_serializing_if = "Option::is_none")]
    remaining_time: Option<String>,
    #[serde(rename = "fortschritt", skip_serializing_if = "Option::is_none")]
    progress: Option<f64>,
    #[serde(rename = "staffel", skip_serializing_if = "Option::is_none")]
    season: Option<i64>,
    #[serde(rename = "folge", skip_serializing_if = "Option::is_none")]
    episode: Option<i64>,
    #[serde(rename = "ab", skip_serializing_if = "Option::is_none")]
    since: Option<f64>,
}

#[derive(Serialize)]
struct SeasonOut {
    id: String,
    name: String,
}

#[derive(Serialize)]
struct SeriesOut {
    id: String,
    name: String,
    #[serde(rename = "jahr", skip_serializing_if = "Option::is_none")]
    year: Option<String>,
    #[serde(rename = "staffelzeile", skip_serializing_if = "Option::is_none")]
    season_row: Option<String>,
    #[serde(rename = "staffelzahl", skip_serializing_if = "Option::is_none")]
    season_count: Option<i64>,
    #[serde(rename = "gattungen", skip_serializing_if = "Option::is_none")]
    genres: Option<String>,
    #[serde(rename = "kopfbild", skip_serializing_if = "Option::is_none")]
    header_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    logo: Option<String>,
    #[serde(rename = "bewertung", skip_serializing_if = "Option::is_none")]
    rating: Option<f64>,
    #[serde(rename = "freigabe", skip_serializing_if = "Option::is_none")]
    sharing: Option<String>,
    #[serde(rename = "beschreibung", skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(rename = "gemerkt")]
    remembered: bool,
    #[serde(rename = "gesehen")]
    watched: bool,
    #[serde(rename = "planDa")]
    plan_present: bool,
    lossless: bool,
    #[serde(rename = "methode", skip_serializing_if = "Option::is_none")]
    method: Option<String>,
    #[serde(rename = "stand", skip_serializing_if = "Option::is_none")]
    state: Option<StateOut>,
    #[serde(rename = "knopftext")]
    button_text: String,
    #[serde(rename = "staffeln")]
    seasons: Vec<SeasonOut>,
    #[serde(rename = "gewaehlt", skip_serializing_if = "Option::is_none")]
    selected: Option<String>,
    #[serde(rename = "darsteller")]
    actors: Vec<PersonOut>,
    #[serde(rename = "kulisse", skip_serializing_if = "Option::is_none")]
    backdrop: Option<String>,
}

#[derive(Serialize)]
struct LoadSelectionEpisodeOut {
    bytes: i64,
    #[serde(rename = "gesehen")]
    watched: bool,
    id: String,
    name: String,
    ticks: i64,
}

#[derive(Serialize)]
struct EpisodeOut {
    id: String,
    #[serde(rename = "titel")]
    title: String,
    #[serde(rename = "unterzeile", skip_serializing_if = "Option::is_none")]
    subline: Option<String>,
    #[serde(rename = "bild", skip_serializing_if = "Option::is_none")]
    image: Option<String>,
    #[serde(rename = "fortschritt", skip_serializing_if = "Option::is_none")]
    progress: Option<f64>,
    #[serde(rename = "gesehen")]
    watched: bool,
    #[serde(rename = "ab", skip_serializing_if = "Option::is_none")]
    since: Option<f64>,
    name: String,
    #[serde(rename = "nummer", skip_serializing_if = "Option::is_none")]
    number: Option<i64>,
    #[serde(rename = "laufzeitMin", skip_serializing_if = "Option::is_none")]
    runtime_min: Option<i64>,
    #[serde(rename = "restzeit", skip_serializing_if = "Option::is_none")]
    remaining_time: Option<String>,
}

#[derive(Serialize)]
struct ExtraOut {
    id: String,
    name: String,
    #[serde(rename = "bild", skip_serializing_if = "Option::is_none")]
    image: Option<String>,
    #[serde(rename = "laufzeit", skip_serializing_if = "Option::is_none")]
    runtime: Option<String>,
}

#[derive(Serialize)]
struct FieldOut {
    #[serde(rename = "aehnliche")]
    similar: Vec<LegacyGridTile>,
    extras: Vec<ExtraOut>,
}

#[derive(Serialize)]
struct TrailerOut {
    #[serde(rename = "art")]
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(rename = "bild", skip_serializing_if = "Option::is_none")]
    image: Option<String>,
    #[serde(rename = "laufzeit", skip_serializing_if = "Option::is_none")]
    runtime: Option<String>,
    #[serde(rename = "adresse", skip_serializing_if = "Option::is_none")]
    address: Option<String>,
}

#[derive(Serialize)]
struct PersonPageOut {
    #[serde(rename = "beschreibung", skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(rename = "geboren", skip_serializing_if = "Option::is_none")]
    born: Option<String>,
    #[serde(rename = "ort", skip_serializing_if = "Option::is_none")]
    place: Option<String>,
    #[serde(rename = "bild", skip_serializing_if = "Option::is_none")]
    image: Option<String>,
    banner: Vec<String>,
    #[serde(rename = "titel")]
    title: Vec<LegacyGridTile>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tmdb: Option<i64>,
    #[serde(rename = "gestoert")]
    disrupted: bool,
}

struct Clock(u64);
impl Rng for Clock {
    fn next_u64(&mut self) -> u64 {
        // SplitMix64, seeded from the clock.
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

struct State {
    always_direct_play: bool,
    megabit: i64,
    run: Option<ShuffleRun>,
}

/// The title, series and person state of one account.
pub struct DetailOf<S> {
    pub(crate) client: Arc<S>,
    /// The account's user id (the owner of the download posts).
    pub(crate) account: String,
    pub(crate) addresses: ImageAddress,
    words: Words,
    text: TitleText,
    language: String,
    state: Mutex<State>,
    /// The audio streams of the titles the download calls looked at (`Kern._audioStreams`).
    pub(crate) audio_streams:
        Mutex<std::collections::HashMap<String, Vec<swiftly_model::MediaStream>>>,
    /// One pending-report pass at a time (`Kern._reportLaterRuns`).
    pub(crate) report_later_runs: std::sync::atomic::AtomicBool,
}

fn json<V: Serialize>(v: &V) -> Result<String, ErrorKind> {
    serde_json::to_string(v).map_err(|e| ErrorKind::Decoding(e.to_string()))
}

/// The title pages of a Jellyfin or Emby account.
pub type LegacyDetail<T> = DetailOf<Client<T>>;
/// The title pages of a Plex account (title, series, episodes, trailers, person, small writes).
pub type LegacyPlexDetail<T> = DetailOf<Plex<T>>;

/// The server calls the pages make, the same for Jellyfin and Plex.
pub trait DetailServer: Send + Sync + 'static {
    fn item(&self, id: &str) -> impl Future<Output = Result<Item, ErrorKind>> + Send;
    fn similar(
        &self,
        id: &str,
        limit: i64,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    fn extras(&self, id: &str) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    fn trailers(&self, id: &str) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    fn seasons(&self, series: &str) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    fn episodes(
        &self,
        series: &str,
        season: Option<&str>,
    ) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    fn next_episode_series(
        &self,
        series: &str,
    ) -> impl Future<Output = Result<Option<Item>, ErrorKind>> + Send;
    fn episode_post(
        &self,
        episode: &str,
        series: &str,
    ) -> impl Future<Output = Result<Option<Item>, ErrorKind>> + Send;
    fn state_in_series(&self, series: &str) -> impl Future<Output = Option<Item>> + Send;
    fn items(
        &self,
        query: &ItemsQuery,
    ) -> impl Future<Output = Result<swiftly_model::ItemsResponse, ErrorKind>> + Send;
    fn set_watchlist(
        &self,
        id: &str,
        on: bool,
    ) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    fn set_watched(&self, id: &str, on: bool)
    -> impl Future<Output = Result<(), ErrorKind>> + Send;
    fn metadata_refresh(&self, id: &str) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// Remove a title from "Continue watching": the position goes, the watched state stays.
    fn point_back_set(&self, id: &str) -> impl Future<Output = Result<(), ErrorKind>> + Send;
    /// The picture of an episode row.
    fn episode_image(
        &self,
        item: &Item,
        max_height: i64,
    ) -> impl Future<Output = Option<String>> + Send;
    /// The play plan the title page shows (`Ok(None)`: the server names no file, a series).
    fn plan(
        &self,
        id: &str,
        max_bitrate: i64,
    ) -> impl Future<Output = Result<Option<PlaybackPlan>, ErrorKind>> + Send;
    /// The address of the file a download fetches (Plex: always the original).
    fn download_url(
        &self,
        id: &str,
        source: Option<&str>,
        quality: swiftly_rules::download_quality::DownloadQuality,
        audio_index: Option<i64>,
    ) -> impl Future<Output = Result<String, ErrorKind>> + Send;
    /// The intro/outro sections to store for offline use; `None` is no answer.
    fn segments_to_store(
        &self,
        id: &str,
    ) -> impl Future<Output = Option<Vec<swiftly_playback::sections::Segment>>> + Send;
}

impl<T: HttpTransport + 'static> DetailServer for Client<T> {
    async fn download_url(
        &self,
        id: &str,
        source: Option<&str>,
        quality: swiftly_rules::download_quality::DownloadQuality,
        audio_index: Option<i64>,
    ) -> Result<String, ErrorKind> {
        let _ = (quality, audio_index);
        // Jellyfin and Emby build their (converted) address without a request in `Core::download_address`; this one is the original.
        self.download_url(id, source, None, None)
            .map(|u| u.to_string())
    }
    async fn segments_to_store(
        &self,
        id: &str,
    ) -> Option<Vec<swiftly_playback::sections::Segment>> {
        swiftly_playback::endpoints::PlaybackEndpoints::segments_to_store(self, id).await
    }
    async fn item(&self, id: &str) -> Result<Item, ErrorKind> {
        Client::<T>::item(self, id).await
    }
    async fn similar(&self, id: &str, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        Client::<T>::similar(self, id, limit).await
    }
    async fn extras(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        Client::<T>::extras(self, id).await
    }
    async fn trailers(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        Client::<T>::trailers(self, id).await
    }
    async fn seasons(&self, series: &str) -> Result<Vec<Item>, ErrorKind> {
        Client::<T>::seasons(self, series).await
    }
    async fn episodes(&self, series: &str, season: Option<&str>) -> Result<Vec<Item>, ErrorKind> {
        Client::<T>::episodes(self, series, season).await
    }
    async fn next_episode_series(&self, series: &str) -> Result<Option<Item>, ErrorKind> {
        Client::<T>::next_episode_series(self, series).await
    }
    async fn episode_post(&self, episode: &str, series: &str) -> Result<Option<Item>, ErrorKind> {
        Client::<T>::episode_post(self, episode, series).await
    }
    async fn state_in_series(&self, series: &str) -> Option<Item> {
        swiftly_library::client_ext::state_in_series(self, series).await
    }
    async fn items(&self, query: &ItemsQuery) -> Result<swiftly_model::ItemsResponse, ErrorKind> {
        Client::<T>::items(self, query).await
    }
    async fn set_watchlist(&self, id: &str, on: bool) -> Result<(), ErrorKind> {
        Client::<T>::set_watchlist(self, id, on).await
    }
    async fn set_watched(&self, id: &str, on: bool) -> Result<(), ErrorKind> {
        Client::<T>::set_watched(self, id, on).await
    }
    async fn metadata_refresh(&self, id: &str) -> Result<(), ErrorKind> {
        Client::<T>::metadata_refresh(self, id).await
    }
    async fn point_back_set(&self, id: &str) -> Result<(), ErrorKind> {
        Client::<T>::point_back_set(self, id).await
    }
    async fn episode_image(&self, item: &Item, max_height: i64) -> Option<String> {
        self.image_url(item, max_height).map(|u| u.to_string())
    }
    async fn plan(&self, id: &str, max_bitrate: i64) -> Result<Option<PlaybackPlan>, ErrorKind> {
        fetch_plan(self, id, max_bitrate, None).await
    }
}

impl<T: HttpTransport + 'static> DetailServer for Plex<T> {
    async fn download_url(
        &self,
        id: &str,
        source: Option<&str>,
        quality: swiftly_rules::download_quality::DownloadQuality,
        audio_index: Option<i64>,
    ) -> Result<String, ErrorKind> {
        MediaServer::download_url(self, id, source, quality, audio_index).await
    }
    async fn segments_to_store(
        &self,
        id: &str,
    ) -> Option<Vec<swiftly_playback::sections::Segment>> {
        MediaServer::segments_to_store(self, id).await
    }
    async fn item(&self, id: &str) -> Result<Item, ErrorKind> {
        MediaServer::item(self, id).await
    }
    async fn similar(&self, id: &str, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        MediaServer::similar(self, id, limit).await
    }
    async fn extras(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        MediaServer::extras(self, id).await
    }
    async fn trailers(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        MediaServer::trailer(self, id).await
    }
    async fn seasons(&self, series: &str) -> Result<Vec<Item>, ErrorKind> {
        MediaServer::seasons(self, series).await
    }
    async fn episodes(&self, series: &str, season: Option<&str>) -> Result<Vec<Item>, ErrorKind> {
        MediaServer::episodes(self, series, season).await
    }
    async fn next_episode_series(&self, series: &str) -> Result<Option<Item>, ErrorKind> {
        MediaServer::next_episode_series(self, series).await
    }
    async fn episode_post(&self, episode: &str, series: &str) -> Result<Option<Item>, ErrorKind> {
        MediaServer::episode_post(self, episode, series).await
    }
    async fn state_in_series(&self, series: &str) -> Option<Item> {
        MediaServer::state_in_series(self, series).await
    }
    async fn items(&self, query: &ItemsQuery) -> Result<swiftly_model::ItemsResponse, ErrorKind> {
        MediaServer::items(self, query).await
    }
    async fn set_watchlist(&self, id: &str, on: bool) -> Result<(), ErrorKind> {
        MediaServer::set_watchlist(self, id, on).await
    }
    async fn set_watched(&self, id: &str, on: bool) -> Result<(), ErrorKind> {
        MediaServer::set_watched(self, id, on).await
    }
    async fn metadata_refresh(&self, id: &str) -> Result<(), ErrorKind> {
        MediaServer::metadata_refresh(self, id).await
    }
    async fn point_back_set(&self, id: &str) -> Result<(), ErrorKind> {
        MediaServer::point_back_set(self, id).await
    }
    async fn episode_image(&self, item: &Item, max_height: i64) -> Option<String> {
        MediaServer::image_url(self, item, max_height).await
    }
    async fn plan(&self, id: &str, _max_bitrate: i64) -> Result<Option<PlaybackPlan>, ErrorKind> {
        match self.plan_for(id, None, None, None).await {
            Ok(plan) => Ok(Some(plan)),
            Err(_) => Ok(None),
        }
    }
}

impl<T: HttpTransport + 'static> DetailOf<Client<T>> {
    pub fn new(transport: &Arc<T>, host: &Host, account: &AccountRef) -> Result<Self, ErrorKind> {
        let source = build_source(transport, host, account)?;
        let addresses = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
        let Source::Jellyfin(client) = source else {
            return Err(ErrorKind::Decoding("not a Jellyfin account".into()));
        };
        Ok(Self::with(client, addresses, host, account.user_id.clone()))
    }
}

impl<T: HttpTransport + 'static> DetailOf<Plex<T>> {
    pub fn new(transport: &Arc<T>, host: &Host, account: &AccountRef) -> Result<Self, ErrorKind> {
        let source = build_source(transport, host, account)?;
        let addresses = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
        let Source::Plex(client) = source else {
            return Err(ErrorKind::Decoding("not a Plex account".into()));
        };
        Ok(Self::with(client, addresses, host, account.user_id.clone()))
    }
}

impl<S: DetailServer> DetailOf<S> {
    fn with(client: Arc<S>, addresses: ImageAddress, host: &Host, account: String) -> Self {
        Self {
            client,
            account,
            addresses,
            words: Words::new(host.locale.clone()),
            text: TitleText::new(host.locale.clone()),
            language: host.locale.language().to_owned(),
            state: Mutex::new(State {
                always_direct_play: true,
                megabit: 0,
                run: None,
            }),
            audio_streams: Mutex::new(std::collections::HashMap::new()),
            report_later_runs: std::sync::atomic::AtomicBool::new(false),
        }
    }

    fn locked<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        f(&mut self.state.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// `Kern.playbackSelection`: from the settings, at start and on every change.
    pub fn playback_selection(&self, always_direct_play: bool, megabit: i64) {
        self.locked(|s| {
            s.always_direct_play = always_direct_play;
            s.megabit = megabit;
        });
    }

    pub(crate) fn limit(&self) -> i64 {
        self.locked(|s| {
            swiftly_rules::playback_levels::bitrate_limit_of(s.always_direct_play, s.megabit)
        })
    }

    fn tile(&self, item: &Item) -> LegacyGridTile {
        grid_tile_sorted(item, &self.addresses, &self.words, Sorting::Name)
    }

    fn person_out(&self, p: &Person) -> PersonOut {
        let image = p.primary_image_tag.as_deref().and_then(|mark| {
            self.addresses
                .construct(&p.id, Art::Poster, Some(mark), ImageMetric::AtMostHigh(220))
                .map(|u| u.to_string())
        });
        PersonOut {
            id: p.id.clone(),
            name: p.name.clone(),
            role: p.role.clone(),
            image,
        }
    }

    fn backdrop(&self, item: &Item, episode: Option<&Item>) -> Option<String> {
        ImageSelection::landscape(item, &self.addresses, 1600)
            .map(|l| l.url)
            .or_else(|| ImageSelection::header_with_fallback(item, episode, &self.addresses, 1200))
            .map(|u| u.to_string())
    }

    // ---- title ----------------------------------------------------------------------------------------------------

    pub async fn title(&self, id: &str) -> Result<String, ErrorKind> {
        let c = &*self.client;
        let (item, plan) = futures_util::future::join(c.item(id), c.plan(id, self.limit())).await;
        let i = item?;
        let plan = plan.ok().flatten();
        let file = plan.as_ref().and_then(|p| p.source.as_ref()).map(|q| {
            let excerpt = file_excerpt(&self.text, q, &self.language);
            let row = |key: &str| {
                excerpt
                    .rows
                    .iter()
                    .find(|r| r.label == self.text.key(key))
                    .map(|r| r.value.clone())
            };
            let streams = q.media_streams.as_deref().unwrap_or(&[]);
            let audio: Vec<String> = excerpt
                .rows
                .iter()
                .filter(|r| r.label == self.text.key("Ton"))
                .map(|r| r.value.clone())
                .collect();
            FileOut {
                container: row("Container"),
                video: row("Video"),
                audio,
                subtitle: row("Untertitel").unwrap_or_default(),
                has_subtitle: streams
                    .iter()
                    .any(|s| s.type_.as_deref() == Some("Subtitle")),
            }
        });
        let since = resume_from(&i);
        let year_runtime = [
            i.production_year.map(|y| y.to_string()),
            i.runtime_seconds()
                .filter(|s| *s > 0.0)
                .map(|s| self.text.runtime(s)),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ");
        let versions = MediaVersions::choices(i.media_sources.as_deref())
            .iter()
            .filter_map(|v| {
                let id = v.id.clone()?;
                let detail = v.version_detail(&|bytes| {
                    crate::downloads_vm::size_text(
                        bytes,
                        if self.language == "de" { "," } else { "." },
                    )
                });
                let name = v.version_name_with(&self.words);
                Some(VersionOut {
                    id,
                    label: if detail.is_empty() {
                        name
                    } else {
                        format!("{name} · {detail}")
                    },
                })
            })
            .collect();
        json(&TitleOut {
            id: i.id.clone(),
            name: i.name.clone(),
            kind: i.type_.clone().unwrap_or_default(),
            secondary_line: self.text.secondary_line(&i),
            year_runtime,
            header_image: ImageSelection::header_with_fallback(&i, None, &self.addresses, 1200)
                .map(|u| u.to_string()),
            logo: ImageSelection::logo(&i, &self.addresses, 240).map(|u| u.to_string()),
            rating: i.community_rating,
            sharing: i.official_rating.clone(),
            plan_present: plan.is_some(),
            lossless: plan.as_ref().is_some_and(|p| p.is_lossless()),
            method: plan.as_ref().map(|p| p.method.raw_value().to_owned()),
            resume_from: since,
            resume_text: since.map(|s| self.text.time_text(s)),
            remaining_time: self.text.remaining(&i),
            progress: i
                .user_data
                .as_ref()
                .and_then(|d| d.played_percentage)
                .map(|p| p / 100.0),
            description: i.overview.clone(),
            direction: i.direction().into_iter().map(str::to_owned).collect(),
            actors: i
                .actors()
                .into_iter()
                .take(12)
                .map(|p| self.person_out(p))
                .collect(),
            remembered: i
                .user_data
                .as_ref()
                .and_then(|d| d.is_favorite)
                .unwrap_or(false),
            watched: i.user_data.as_ref().and_then(|d| d.played).unwrap_or(false),
            file,
            backdrop: self.backdrop(&i, None),
            versions,
        })
    }

    // ---- series ---------------------------------------------------------------------------------------------------

    pub async fn series(&self, id: &str) -> Result<String, ErrorKind> {
        let c = &*self.client;
        let first = c.item(id).await?;
        let (mut hint_id, mut hint_number) = (None, None);
        let series = if first.type_.as_deref() == Some("Episode")
            && let Some(series_id) = first.series_id.clone()
        {
            hint_id = first.season_id.clone();
            hint_number = first.parent_index_number;
            c.item(&series_id).await?
        } else {
            first
        };
        let (state, seasons) = futures_util::future::join(c.state_in_series(&series.id), async {
            c.seasons(&series.id).await.ok()
        })
        .await;
        let seasons = seasons.unwrap_or_default();
        let selected =
            SeasonSelectionRule::choose(&seasons, hint_id.as_deref(), hint_number, state.as_ref())
                .map(|s| s.id.clone());
        let folks: Vec<&Person> = match state.as_ref().map(|s| s.actors()) {
            Some(list) if !list.is_empty() => list,
            _ => series.actors(),
        };
        let genres = series
            .genres
            .as_ref()
            .filter(|g| !g.is_empty())
            .map(|g| g.iter().take(2).cloned().collect::<Vec<_>>().join(", "));
        json(&SeriesOut {
            id: series.id.clone(),
            name: series.name.clone(),
            year: series.production_year.map(|y| y.to_string()),
            season_row: (seasons.len() == 1).then(|| seasons[0].name.clone()),
            season_count: if seasons.len() == 1 {
                None
            } else if seasons.is_empty() {
                series.child_count
            } else {
                i64::try_from(seasons.len()).ok()
            },
            genres,
            header_image: ImageSelection::header_with_fallback(
                &series,
                state.as_ref(),
                &self.addresses,
                1200,
            )
            .map(|u| u.to_string()),
            logo: ImageSelection::logo(&series, &self.addresses, 240).map(|u| u.to_string()),
            rating: series.community_rating,
            sharing: series.official_rating.clone(),
            description: series.overview.clone(),
            remembered: series
                .user_data
                .as_ref()
                .and_then(|d| d.is_favorite)
                .unwrap_or(false),
            watched: series
                .user_data
                .as_ref()
                .and_then(|d| d.played)
                .unwrap_or(false),
            plan_present: false,
            lossless: false,
            method: None,
            state: state.as_ref().map(|f| StateOut {
                id: f.id.clone(),
                resume: f
                    .user_data
                    .as_ref()
                    .and_then(|d| d.playback_position_ticks)
                    .unwrap_or(0)
                    > 0,
                remaining_time: self.text.remaining(f),
                progress: f
                    .user_data
                    .as_ref()
                    .and_then(|d| d.played_percentage)
                    .map(|p| p / 100.0),
                season: f.parent_index_number,
                episode: f.index_number,
                since: resume_from(f),
            }),
            button_text: self.text.series_button(state.as_ref(), false),
            seasons: seasons
                .iter()
                .map(|s| SeasonOut {
                    id: s.id.clone(),
                    name: s.name.clone(),
                })
                .collect(),
            selected,
            actors: folks.into_iter().map(|p| self.person_out(p)).collect(),
            backdrop: self.backdrop(&series, state.as_ref()),
        })
    }

    // ---- episodes -------------------------------------------------------------------------------------------------

    pub async fn episodes(&self, series: &str, season: &str) -> Result<String, ErrorKind> {
        let list = self
            .client
            .episodes(series, (!season.is_empty()).then_some(season))
            .await?;
        let mut images = Vec::with_capacity(list.len());
        for f in &list {
            images.push(self.client.episode_image(f, 220).await);
        }
        let rows: Vec<EpisodeOut> = list
            .iter()
            .zip(images)
            .map(|(f, image)| {
                let watched = f.user_data.as_ref().and_then(|d| d.played).unwrap_or(false);
                let minutes = |s: f64| {
                    if s.is_finite() {
                        (s / 60.0).clamp(0.0, 1.0e9) as i64
                    } else {
                        0
                    }
                };
                let time = runtime_show(f.runtime_seconds()).then(|| {
                    self.text.remaining(f).unwrap_or_else(|| {
                        format!("{} min", minutes(f.runtime_seconds().unwrap_or(0.0)))
                    })
                });
                EpisodeOut {
                    id: f.id.clone(),
                    title: f
                        .index_number
                        .map_or_else(|| f.name.clone(), |n| format!("{n}. {}", f.name)),
                    subline: time,
                    image,
                    progress: if watched {
                        None
                    } else {
                        f.user_data
                            .as_ref()
                            .and_then(|d| d.played_percentage)
                            .map(|p| p / 100.0)
                    },
                    watched,
                    since: resume_from(f),
                    name: f.name.clone(),
                    number: f.index_number,
                    runtime_min: f.runtime_seconds().filter(|s| *s > 0.0).map(minutes),
                    remaining_time: self.text.remaining(f),
                }
            })
            .collect();
        json(&rows)
    }

    // ---- similar titles and extras, trailers ---------------------------------------------------------------------

    pub async fn title_field(&self, id: &str) -> Result<String, ErrorKind> {
        let c = &*self.client;
        let own = c.item(id).await.ok();
        let (alike, addition) = futures_util::future::join(c.similar(id, 12), c.extras(id)).await;
        let raw = alike.unwrap_or_default();
        let similar: Vec<Item> = match &own {
            Some(own) => {
                ListRules::without_double(&crate::title_text::similar_cleaned(&raw, own, 12))
            }
            None => ListRules::without_double(&raw),
        };
        json(&FieldOut {
            similar: similar.iter().map(|i| self.tile(i)).collect(),
            extras: addition
                .unwrap_or_default()
                .iter()
                .map(|e| ExtraOut {
                    id: e.id.clone(),
                    name: e.name.clone(),
                    image: ImageSelection::landscape(e, &self.addresses, 600)
                        .map(|l| l.url.to_string()),
                    runtime: runtime_show(e.runtime_seconds())
                        .then(|| e.runtime_seconds().map(|s| self.text.runtime(s)))
                        .flatten(),
                })
                .collect(),
        })
    }

    pub async fn trailers(&self, id: &str, can_open_web: bool) -> String {
        let c = &*self.client;
        let candidates = if can_open_web && let Ok(item) = c.item(id).await {
            let files = c.trailers(id).await.unwrap_or_default();
            trailer_candidates(&files, item.remote_trailers.as_deref(), true)
        } else {
            let files = c.trailers(id).await.unwrap_or_default();
            trailer_candidates(&files, None, false)
        };
        let out: Vec<TrailerOut> = candidates
            .into_iter()
            .map(|cand| match cand {
                TrailerCandidate::File(t) => TrailerOut {
                    kind: "datei",
                    id: Some(t.id.clone()),
                    name: Some(t.name.clone()),
                    image: ImageSelection::landscape(&t, &self.addresses, 600)
                        .map(|l| l.url.to_string()),
                    runtime: runtime_show(t.runtime_seconds())
                        .then(|| t.runtime_seconds().map(|s| self.text.runtime(s)))
                        .flatten(),
                    address: None,
                },
                TrailerCandidate::Web(url) => TrailerOut {
                    kind: "web",
                    id: None,
                    name: None,
                    image: None,
                    runtime: None,
                    address: Some(url.to_string()),
                },
            })
            .collect();
        serde_json::to_string(&out).unwrap_or_else(|_| "[]".into())
    }

    // ---- person ---------------------------------------------------------------------------------------------------

    pub async fn person(&self, id: &str) -> Result<String, ErrorKind> {
        let c = &*self.client;
        let (own, inquiry) = futures_util::future::join(
            async {
                DetailServer::items(
                    c,
                    &ItemsQuery {
                        limit: 60,
                        sort_by: "ProductionYear,SortName".into(),
                        sort_order: "Descending".into(),
                        recursive: true,
                        include_item_types: vec!["Movie".into(), "Series".into()],
                        person_ids: vec![id.into()],
                        ..ItemsQuery::default()
                    },
                )
                .await
                .ok()
                .map(|a| ListRules::without_double(&a.items))
            },
            async { c.item(id).await.ok() },
        )
        .await;
        let disrupted = own.is_none();
        let title = own.unwrap_or_default();
        let mut banner: Vec<String> = title
            .iter()
            .filter_map(|t| ImageSelection::header(t, &self.addresses, 1200).map(|u| u.to_string()))
            .collect();
        if banner.is_empty()
            && let Some(first) = title.first()
        {
            let mut episode: Option<Item> = None;
            if first.type_.as_deref() == Some("Series") {
                if let Ok(Some(next)) = c.next_episode_series(&first.id).await {
                    episode = Some(next);
                }
                if episode.is_none() {
                    episode = c
                        .episodes(&first.id, None)
                        .await
                        .ok()
                        .and_then(|e| e.into_iter().next());
                }
            }
            if let Some(url) =
                ImageSelection::header_with_fallback(first, episode.as_ref(), &self.addresses, 1200)
            {
                banner = vec![url.to_string()];
            }
        }
        let image = inquiry
            .as_ref()
            .and_then(|i| i.image_tags.as_ref())
            .and_then(|t| t.get("Primary"))
            .and_then(|mark| {
                self.addresses.construct(
                    id,
                    Art::Poster,
                    Some(mark.as_str()),
                    ImageMetric::AtMostHigh(300),
                )
            })
            .map(|u| u.to_string());
        let born = inquiry
            .as_ref()
            .and_then(|i| i.premiere_date.as_deref())
            .and_then(|raw| {
                let day: String = raw.chars().take(10).collect();
                let parts: Vec<i64> = day.split('-').filter_map(|p| p.parse().ok()).collect();
                (day.chars().count() >= 10 && parts.len() == 3)
                    .then(|| format!("{:04}-{:02}-{:02}", parts[0], parts[1], parts[2]))
            });
        json(&PersonPageOut {
            description: inquiry.as_ref().and_then(|i| i.overview.clone()),
            born,
            place: inquiry
                .as_ref()
                .and_then(|i| i.production_locations.as_ref())
                .and_then(|l| l.iter().find(|p| !p.is_empty()).cloned()),
            image,
            banner,
            title: title.iter().map(|t| self.tile(t)).collect(),
            tmdb: inquiry
                .as_ref()
                .and_then(|i| i.provider_ids.as_ref())
                .and_then(|m| m.get("Tmdb"))
                .and_then(|t| t.parse().ok()),
            disrupted,
        })
    }

    // ---- the shuffled run and the small writes --------------------------------------------------------------------

    /// The episode after `episode` in the same series ("" if none follows); a shuffled run keeps its own order.
    pub async fn episode_after(&self, episode: &str, series: &str) -> String {
        let run = self.locked(|s| match &s.run {
            Some(run) if run.contains(episode) => Some(run.clone()),
            _ => {
                s.run = None;
                None
            }
        });
        if let Some(run) = run {
            return run
                .next_after(episode)
                .map(|i| i.id.clone())
                .unwrap_or_default();
        }
        self.client
            .episode_post(episode, series)
            .await
            .ok()
            .flatten()
            .map(|i| i.id)
            .unwrap_or_default()
    }

    /// "Play shuffled" on a series: mixes all episodes once and returns the first one ("" if none).
    pub async fn shuffle_start(&self, series: &str) -> String {
        let Ok(all) = self.client.episodes(series, None).await else {
            return String::new();
        };
        if all.is_empty() {
            return String::new();
        }
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |d| d.as_nanos() as u64);
        let run = ShuffleRun::mixed(all, &mut Clock(seed));
        let first = run
            .episodes
            .first()
            .map(|i| i.id.clone())
            .unwrap_or_default();
        self.locked(|s| s.run = Some(run));
        first
    }

    /// The ids of the shuffled run, in order (the player's run).
    pub fn run_ids(&self) -> Vec<String> {
        self.locked(|s| {
            s.run
                .as_ref()
                .map(|r| r.episodes.iter().map(|i| i.id.clone()).collect())
                .unwrap_or_default()
        })
    }

    async fn request(&self, result: Result<(), ErrorKind>) -> String {
        match result {
            Ok(()) => String::new(),
            Err(e) => crate::legacy_detail::error_text(&self.text, &e),
        }
    }

    pub async fn remember(&self, id: &str, on: bool) -> String {
        self.request(self.client.set_watchlist(id, on).await).await
    }

    pub async fn watched(&self, id: &str, on: bool) -> String {
        self.request(self.client.set_watched(id, on).await).await
    }

    pub async fn metadata_refresh(&self, id: &str) -> String {
        self.request(self.client.metadata_refresh(id).await).await
    }

    /// `Kern.fromContinueWatchingTake`: empty means done, otherwise the sentence for the failure.
    #[allow(clippy::wrong_self_convention)] // name mirrors `Kern.fromContinueWatchingTake`
    pub async fn from_continue_watching_take(&self, id: &str) -> String {
        self.request(self.client.point_back_set(id).await).await
    }

    /// `Kern.plan`: `{"lossless":..,"methode":..}` or `{}` when the server names no plan.
    pub async fn plan_answer(&self, id: &str) -> String {
        let limit = self.limit();
        match self.client.plan(id, limit).await {
            Ok(Some(p)) => format!(
                r#"{{"lossless":{},"methode":{}}}"#,
                p.is_lossless(),
                serde_json::to_string(p.method.raw_value()).unwrap_or_default()
            ),
            _ => "{}".into(),
        }
    }

    /// `Kern.loadSelectionEpisodes`: `[{"id","name","gesehen","bytes","ticks"}]`; a failed call is an error, not an empty list.
    pub async fn load_selection_episodes(
        &self,
        series: &str,
        season: &str,
    ) -> Result<String, ErrorKind> {
        let list = self
            .client
            .episodes(series, (!season.is_empty()).then_some(season))
            .await?;
        let rows: Vec<LoadSelectionEpisodeOut> = list
            .iter()
            .map(|f| LoadSelectionEpisodeOut {
                bytes: f
                    .media_sources
                    .as_ref()
                    .and_then(|m| m.first())
                    .and_then(|m| m.size)
                    .unwrap_or(0),
                id: f.id.clone(),
                name: f.name.clone(),
                watched: f.user_data.as_ref().and_then(|d| d.played).unwrap_or(false),
                ticks: f.run_time_ticks.unwrap_or(0),
            })
            .collect();
        json(&rows)
    }
}

/// `coreErrorText`: the sentence for an error.
pub(crate) fn error_text(text: &TitleText, e: &ErrorKind) -> String {
    swiftly_l10n::error_text::readable_error(&swiftly_l10n::Translator::new(text.locale()), e)
}
