//! The play plan call of the player screens: one question from a title to everything the player
//! needs (`PlayerStart`, sections, chapters, trickplay), the versions to choose from, or the
//! reason there is nothing to play. The rules live in `swiftly_vm::play_start`.

use std::collections::HashMap;
use std::sync::Arc;

use swiftly_jellyfin::TrackIndices;
use swiftly_playback::device_profile::Flavour;
use swiftly_playback::playback_plan::PlaybackPlan;
use swiftly_playback::sections::{Art, Segment};
use swiftly_playback::track_mapping::SubtitleFile;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{
    AccountRef, DownloadedFile, Host, NextSource, StartAnswer, StartRequest, StartSettings,
    TrackMemoryStore,
};

use crate::error::CoreError;
use crate::player::{
    PlayerBuffer, PlayerChapter, PlayerHeader, PlayerMethod, PlayerNext, PlayerSection,
    PlayerSectionKind, PlayerStart, PlayerStream, PlayerSubtitleFile, PlayerTrickplay,
};
use crate::stores::KeyValueStore;
use crate::transport::ForeignTransport;

/// Which engine plays: the profile the server is asked with.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayFlavour {
    /// The own engine (Aether): the `vlc` profile.
    Aether,
    /// AVPlayer (AirPlay, PiP): the `airplay` profile.
    AvPlayer,
    /// AVPlayer that may also copy AV1.
    AvPlayerAv1,
}

/// A copy of the title on the device.
#[derive(uniffi::Record, Clone, Debug)]
pub struct PlayDownloaded {
    pub file: String,
    pub container: Option<String>,
    pub source: Option<String>,
    pub video_codec: Option<String>,
    /// Sections stored at download time; `None`: ask the server.
    pub sections: Option<Vec<PlayerSection>>,
    pub subtitle_files: Vec<PlayerSubtitleFile>,
}

/// The settings a start reads.
#[derive(uniffi::Record, Clone, Debug)]
pub struct PlaySettings {
    /// `tonSprache`.
    pub audio_language: String,
    /// `utSprache`.
    pub subtitle_language: String,
    /// `utAuto`.
    pub automatic_subtitles: bool,
    /// The bitrate the profile reports (`BitratesLimit.of`).
    pub max_bitrate: i64,
    /// `pufferstufe`.
    pub buffer_level: PlayerBuffer,
    pub frame_rate_match: bool,
    /// The server hands ASS out as SRT (`fileStyleAdjustable` and "keep the style" off).
    pub server_extracts_text: bool,
}

/// Tracks chosen on the client that sent the title here.
#[derive(uniffi::Record, Clone, Copy, Debug)]
pub struct PlayOrderedTracks {
    pub audio: Option<i64>,
    pub subtitle: Option<i64>,
}

/// Where "next episode" comes from (`AppModel.episodePost`).
#[derive(uniffi::Enum, Clone, Debug)]
pub enum PlayNextSource {
    /// None (a group plays without one).
    None,
    /// The old rule: without a network the next downloaded episode, else the server's answer.
    /// `downloads_json` is the downloads list (`liste.json`, any account).
    Rule {
        downloads_json: String,
        without_network: bool,
    },
    /// A shuffled run names its own next title (`None`: its end).
    Given { next: Option<PlayerNext> },
}

/// What the screen asks for.
#[derive(uniffi::Record, Clone, Debug)]
pub struct PlayPlanRequest {
    pub item_id: String,
    /// The version the user picked.
    pub source_id: Option<String>,
    /// The start position; `None`: the title's remembered one.
    pub since: Option<f64>,
    pub flavour: PlayFlavour,
    /// The device decodes AV1 in hardware (`VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` on Apple): then the
    /// own engine direct-plays AV1 Dolby Vision 10.0, else the server transcodes it. Android passes `false`.
    pub hardware_av1: bool,
    /// The caller can ask for a version.
    pub ask_versions: bool,
    pub downloaded: Option<PlayDownloaded>,
    pub ordered: Option<PlayOrderedTracks>,
    /// The account in front of the track memory key.
    pub account_key: Option<String>,
    pub settings: PlaySettings,
    pub next: PlayNextSource,
}

/// One version to choose from.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayVersion {
    pub id: String,
    pub name: String,
}

/// A title ready to open.
#[derive(uniffi::Record, Clone, Debug)]
pub struct PlayReady {
    pub start: PlayerStart,
    /// The chosen version as the server's `MediaSource` JSON (what `PlaybackPlan.source` holds); the
    /// file excerpt on the detail page, the technical badges and the engine's track lists read it.
    pub source_json: Option<String>,
    pub sections: Vec<PlayerSection>,
    pub chapters: Vec<PlayerChapter>,
    pub trickplay: Option<PlayerTrickplay>,
    /// What the screens show about the title besides the stream (`PlayPlanResponse` of the old Android core,
    /// `PlayerScreen.titleLine` / `metaText` and the card pictures on Apple).
    pub display: PlayDisplay,
}

/// The episode after this one, as its card shows it.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayDisplayNext {
    pub id: String,
    pub name: String,
    /// "S6 · F11", else the name (`Item.episodeCode ?? name`).
    pub abbreviation: String,
    /// The episode's own still, else a landscape picture (1080 high / 1920 wide).
    pub image: Option<String>,
}

/// The display facts of a title that is about to play (`swiftly_vm::PlayDisplay`).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlayDisplay {
    /// `Item.contextLine`, empty without one.
    pub context_line: String,
    /// "MKV · 1080p · H.264 · German · AAC · Stereo" (container, picture, first sound track).
    pub file_row: Option<String>,
    pub series: Option<String>,
    /// "S6 · F11" of an episode (`Item.episodeCode`).
    pub abbreviation: Option<String>,
    /// The picture for the media controls (primary image, 600 high).
    pub image: Option<String>,
    pub episode: bool,
    pub season_id: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    /// The series for an episode, otherwise the title (`titleLine`).
    pub header_line: String,
    /// Year, runtime and genre of a movie; `None` for an episode.
    pub secondary_line: Option<String>,
    /// What sits next to the title (`metaText`): "S1 · F3" for an episode, the secondary line for a movie.
    pub meta_line: Option<String>,
    /// The hand-over card's picture (`TakeoverModel.cardImageURL`).
    pub card_image: Option<String>,
    /// Dolby Vision profile when the file arrives untouched (`0` if the profile is unknown).
    pub dolby_vision: Option<i64>,
    /// Lower case codec of the default sound track; `Some("")` for a file without sound; `None` if unknown.
    pub audio_codec: Option<String>,
    pub next: Option<PlayDisplayNext>,
}

impl From<swiftly_vm::PlayDisplay> for PlayDisplay {
    fn from(d: swiftly_vm::PlayDisplay) -> Self {
        Self {
            context_line: d.context_line,
            file_row: d.file_row,
            series: d.series,
            abbreviation: d.abbreviation,
            image: d.image,
            episode: d.episode,
            season_id: d.season_id,
            season_number: d.season_number,
            episode_number: d.episode_number,
            header_line: d.header_line,
            secondary_line: d.secondary_line,
            meta_line: d.meta_line,
            card_image: d.card_image,
            dolby_vision: d.dolby_vision,
            audio_codec: d.audio_codec,
            next: d.next.map(|n| PlayDisplayNext {
                id: n.id,
                name: n.name,
                abbreviation: n.abbreviation,
                image: n.image,
            }),
        }
    }
}

/// The answer.
#[derive(uniffi::Enum, Clone, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum PlayPlanAnswer {
    Ready {
        ready: PlayReady,
    },
    /// Several versions and none picked: ask ("Fassung wählen").
    Choose {
        item_id: String,
        versions: Vec<PlayVersion>,
        since: f64,
    },
    /// The server names no source (a series).
    NoSource,
    /// The versions could not be loaded.
    VersionsFailed,
    /// The server refused or did not answer. `message` is the sentence for the user in the host's
    /// language (`readableError`); `failure` says which error it was, so a host with a system text for
    /// network errors can word it itself.
    Failed {
        message: String,
        failure: PlayFailure,
    },
}

/// Which error a failed plan was (`JellyfinError`).
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum PlayFailure {
    Network {
        code: i32,
    },
    Http {
        status: u16,
        body: Option<String>,
    },
    NotAuthenticated,
    TwoFactor,
    InvalidServerUrl,
    Decoding {
        text: String,
    },
    NoPlayableSource,
    PlaybackRejected {
        reason: String,
    },
    /// Certificate, transport or anything else: `message` is the whole truth.
    Other,
}

fn failure_of(kind: &swiftly_net::ErrorKind) -> PlayFailure {
    use swiftly_net::ErrorKind as E;
    match kind {
        E::Network { code } => PlayFailure::Network { code: *code },
        E::Http { status, body } => PlayFailure::Http {
            status: *status,
            body: body.clone(),
        },
        E::NotAuthenticated => PlayFailure::NotAuthenticated,
        E::TwoFactor => PlayFailure::TwoFactor,
        E::InvalidServerUrl => PlayFailure::InvalidServerUrl,
        E::Decoding(text) => PlayFailure::Decoding { text: text.clone() },
        E::NoPlayableSource => PlayFailure::NoPlayableSource,
        E::PlaybackRejected(reason) => PlayFailure::PlaybackRejected {
            reason: reason.clone(),
        },
        _ => PlayFailure::Other,
    }
}

fn level(b: PlayerBuffer) -> BufferLevel {
    match b {
        PlayerBuffer::Normal => BufferLevel::Normal,
        PlayerBuffer::Bad => BufferLevel::Bad,
        PlayerBuffer::VeryBad => BufferLevel::VeryBad,
    }
}

fn section_kind(art: Art) -> PlayerSectionKind {
    match art {
        Art::Unknown => PlayerSectionKind::Unknown,
        Art::Ads => PlayerSectionKind::Ads,
        Art::Preview => PlayerSectionKind::Preview,
        Art::LookBack => PlayerSectionKind::LookBack,
        Art::Credits => PlayerSectionKind::Credits,
        Art::IntroSegment => PlayerSectionKind::Intro,
    }
}

fn section(s: &Segment) -> PlayerSection {
    PlayerSection {
        kind: section_kind(s.art),
        from: s.from,
        until: s.until,
    }
}

fn file_of(f: &PlayerSubtitleFile) -> SubtitleFile {
    SubtitleFile {
        index: f.index,
        address: f.address.clone(),
        attribute: f.attribute.clone(),
    }
}

fn request_of(r: PlayPlanRequest) -> StartRequest {
    StartRequest {
        item_id: r.item_id,
        source_id: r.source_id,
        since: r.since,
        flavour: match r.flavour {
            PlayFlavour::Aether => Flavour::Aether,
            PlayFlavour::AvPlayer => Flavour::AirPlay { av1: false },
            PlayFlavour::AvPlayerAv1 => Flavour::AirPlay { av1: true },
        },
        hardware_av1: r.hardware_av1,
        no_dolby_vision_decoder: false,
        ask_versions: r.ask_versions,
        downloaded: r.downloaded.map(|d| DownloadedFile {
            file: d.file,
            container: d.container,
            source: d.source,
            video_codec: d.video_codec,
            sections: d
                .sections
                .map(|list| list.into_iter().map(Segment::from).collect()),
            subtitle_files: d.subtitle_files.iter().map(file_of).collect(),
        }),
        ordered: r.ordered.map(|o| TrackIndices {
            audio: o.audio,
            subtitle: o.subtitle,
        }),
        account_key: r.account_key,
        next: match r.next {
            PlayNextSource::None => NextSource::None,
            PlayNextSource::Rule {
                downloads_json,
                without_network,
            } => NextSource::Rule {
                downloads: serde_json::from_str(&downloads_json).unwrap_or_default(),
                without_network,
            },
            PlayNextSource::Given { next } => NextSource::Given(next.map(|n| {
                Box::new(swiftly_model::Item {
                    id: n.id,
                    name: n.title,
                    ..swiftly_model::Item::default()
                })
            })),
        },
        settings: StartSettings {
            audio_language: r.settings.audio_language,
            subtitle_language: r.settings.subtitle_language,
            automatic_subtitles: r.settings.automatic_subtitles,
            max_bitrate: r.settings.max_bitrate,
            buffer_level: level(r.settings.buffer_level),
            frame_rate_match: r.settings.frame_rate_match,
            server_extracts_text: r.settings.server_extracts_text,
        },
    }
}

fn method_of(plan: &PlaybackPlan) -> PlayerMethod {
    use swiftly_model::DeliveryMethod;
    match plan.method {
        DeliveryMethod::DirectPlay => PlayerMethod::DirectPlay,
        DeliveryMethod::DirectStream => PlayerMethod::DirectStream,
        DeliveryMethod::Transcode => PlayerMethod::Transcode,
    }
}

fn answer_of(
    answer: StartAnswer,
    downloaded: bool,
    settings: &PlaySettings,
    locale: swiftly_l10n::Locale,
) -> PlayPlanAnswer {
    match answer {
        StartAnswer::Ready(r) => {
            let runtime = r
                .item
                .run_time_ticks
                .map_or(0.0, |t| t as f64 / 10_000_000.0);
            let start = PlayerStart {
                item_id: r.item.id.clone(),
                title: r.item.name.clone(),
                play_session_id: r.plan.play_session_id.clone(),
                media_source_id: r.plan.media_source_id.clone(),
                method: method_of(&r.plan),
                url: r.plan.url.clone(),
                headers: Vec::<PlayerHeader>::new(),
                streams: r
                    .streams
                    .iter()
                    .map(|s| PlayerStream {
                        index: s.index.unwrap_or(-1),
                        kind: s.type_.clone().unwrap_or_default(),
                        language: s.language.clone(),
                        codec: s.codec.clone(),
                        channels: s.channels,
                        title: s.title.clone(),
                        is_default: s.is_default.unwrap_or(false),
                        is_forced: s.is_forced.unwrap_or(false),
                        is_external: s.is_external.unwrap_or(false),
                        is_hearing_impaired: s.is_hearing_impaired.unwrap_or(false),
                    })
                    .collect(),
                runtime,
                start_at: r.start_at,
                audio_index: r.audio,
                subtitle_index: r.subtitle,
                next: r.next.as_ref().map(|i| PlayerNext {
                    id: i.id.clone(),
                    title: i.name.clone(),
                }),
                series_id: r.item.series_id.clone(),
                track_title: Some(r.track_title.clone()),
                downloaded,
                software_decode: r.plan.software_decoder(),
                frame_rate_match: settings.frame_rate_match,
                buffer_level: settings.buffer_level,
                subtitle_files: r
                    .subtitle_files
                    .iter()
                    .map(|f| PlayerSubtitleFile {
                        index: f.index,
                        address: f.address.clone(),
                        attribute: f.attribute.clone(),
                    })
                    .collect(),
                external_track_id_base: 1000,
                source_json: r
                    .source
                    .as_ref()
                    .and_then(|m| serde_json::to_string(m).ok()),
            };
            PlayPlanAnswer::Ready {
                ready: PlayReady {
                    start,
                    source_json: r
                        .plan
                        .source
                        .as_ref()
                        .and_then(|m| serde_json::to_string(m).ok()),
                    sections: r.sections.iter().map(section).collect(),
                    chapters: r
                        .chapters
                        .iter()
                        .map(|c| PlayerChapter {
                            name: c.name.clone(),
                            from: c.from,
                        })
                        .collect(),
                    trickplay: r.trickplay.map(|t| PlayerTrickplay {
                        width: t.width,
                        height: t.height,
                        tiles_wide: t.tiles_wide,
                        tiles_up: t.tiles_up,
                        count: t.count,
                        interval: t.interval,
                    }),
                    display: r.display.clone().into(),
                },
            }
        }
        StartAnswer::Choose {
            item,
            versions,
            since,
        } => PlayPlanAnswer::Choose {
            item_id: item.id,
            versions: versions
                .into_iter()
                .map(|v| PlayVersion {
                    id: v.id,
                    name: v.name,
                })
                .collect(),
            since,
        },
        StartAnswer::NoSource => PlayPlanAnswer::NoSource,
        StartAnswer::VersionsFailed => PlayPlanAnswer::VersionsFailed,
        StartAnswer::Failed(kind) => PlayPlanAnswer::Failed {
            message: swiftly_l10n::error_text::readable_error(
                &swiftly_l10n::Translator::new(locale),
                &kind,
            ),
            failure: failure_of(&kind),
        },
    }
}

/// The hand-chosen tracks in the host's store (`trackmemory.<key>`, the player writes them).
struct Memory(Arc<dyn KeyValueStore>);

impl TrackMemoryStore for Memory {
    fn load(&self, key: &str) -> HashMap<String, String> {
        self.0
            .get(format!("trackmemory.{key}"))
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
    fn save(&self, _key: &str, _all: &HashMap<String, String>) {}
}

pub(crate) async fn play_plan(
    transport: &ForeignTransport,
    host: &Host,
    store: &Arc<dyn KeyValueStore>,
    account: &AccountRef,
    request: PlayPlanRequest,
) -> Result<PlayPlanAnswer, CoreError> {
    let downloaded = request.downloaded.is_some();
    let settings = request.settings.clone();
    let memory = Memory(Arc::clone(store));
    let answer = swiftly_vm::play_start(
        Arc::new(transport.clone()),
        host,
        account,
        &request_of(request),
        Some(&memory),
    )
    .await
    .map_err(CoreError::from)?;
    Ok(answer_of(
        answer,
        downloaded,
        &settings,
        host.locale.clone(),
    ))
}

/// The plan of a title alone (`AppModel.plan` / `JellyfinClient.playbackPlan`).
#[derive(uniffi::Enum, Clone, Debug)]
pub enum PlanOnly {
    Ready {
        url: String,
        method: PlayerMethod,
        media_source_id: Option<String>,
        play_session_id: Option<String>,
        /// The chosen version as the server's `MediaSource` JSON.
        source_json: Option<String>,
    },
    /// The server names no source (a series or a season).
    NoSource,
    Failed {
        message: String,
        failure: PlayFailure,
    },
}

/// A plan the page already holds, as the host's play seam takes it.
pub(crate) fn plan_ready(plan: &PlaybackPlan) -> PlanOnly {
    PlanOnly::Ready {
        url: plan.url.clone(),
        method: method_of(plan),
        media_source_id: plan.media_source_id.clone(),
        play_session_id: plan.play_session_id.clone(),
        source_json: plan
            .source
            .as_ref()
            .and_then(|m| serde_json::to_string(m).ok()),
    }
}

#[allow(clippy::too_many_arguments)] // mirrors the exported method
pub(crate) async fn play_plan_only(
    transport: &ForeignTransport,
    host: &Host,
    account: &AccountRef,
    item_id: &str,
    source_id: Option<&str>,
    hardware_av1: bool,
    max_bitrate: i64,
    subtitle: Option<i64>,
) -> Result<PlanOnly, CoreError> {
    let answer = swiftly_vm::play_plan_only(
        Arc::new(transport.clone()),
        host,
        account,
        item_id,
        Flavour::Aether,
        hardware_av1,
        max_bitrate,
        source_id,
        subtitle,
    )
    .await;
    Ok(match answer {
        Ok(Some(plan)) => plan_ready(&plan),
        Ok(None) => PlanOnly::NoSource,
        Err(kind) => PlanOnly::Failed {
            message: swiftly_l10n::error_text::readable_error(
                &swiftly_l10n::Translator::new(host.locale.clone()),
                &kind,
            ),
            failure: failure_of(&kind),
        },
    })
}

/// The skip sections of a title from the server (`AppModel.sections` without a download's stored ones).
pub(crate) async fn play_sections(
    transport: &ForeignTransport,
    host: &Host,
    account: &AccountRef,
    item_id: &str,
) -> Result<Vec<PlayerSection>, CoreError> {
    let list = swiftly_vm::play_sections(Arc::new(transport.clone()), host, account, item_id)
        .await
        .map_err(CoreError::from)?;
    Ok(list.iter().map(section).collect())
}

/// The preview sheets of a version (`AppModel.trickplay`).
pub(crate) async fn play_trickplay(
    transport: &ForeignTransport,
    host: &Host,
    account: &AccountRef,
    item_id: &str,
    source: Option<&str>,
) -> Result<Option<PlayerTrickplay>, CoreError> {
    let found =
        swiftly_vm::play_trickplay(Arc::new(transport.clone()), host, account, item_id, source)
            .await
            .map_err(CoreError::from)?;
    Ok(found.map(|t| PlayerTrickplay {
        width: t.width,
        height: t.height,
        tiles_wide: t.tiles_wide,
        tiles_up: t.tiles_up,
        count: t.count,
        interval: t.interval,
    }))
}

/// The chapters of a title for the bar (`AppModel.chapter`).
pub(crate) async fn play_chapters(
    transport: &ForeignTransport,
    host: &Host,
    account: &AccountRef,
    item_id: &str,
    source: Option<&str>,
) -> Result<Vec<PlayerChapter>, CoreError> {
    let list =
        swiftly_vm::play_chapters(Arc::new(transport.clone()), host, account, item_id, source)
            .await
            .map_err(CoreError::from)?;
    Ok(list
        .iter()
        .map(|c| PlayerChapter {
            name: c.name.clone(),
            from: c.from,
        })
        .collect())
}

/// The tracks this device starts a title with (`TrackRule.start`): a track of the remembered
/// choice, the settings' languages, the server's defaults; an order from another client wins.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct StartTrackChoice {
    pub audio: Option<i64>,
    /// `-1`: off.
    pub subtitle: i64,
}

/// The streams of a version as the rules read them.
fn media_streams(streams: Vec<PlayerStream>) -> Vec<swiftly_model::MediaStream> {
    streams
        .into_iter()
        .map(|t| swiftly_model::MediaStream {
            index: Some(t.index),
            type_: Some(t.kind),
            language: t.language,
            codec: t.codec,
            channels: t.channels,
            title: t.title,
            is_default: Some(t.is_default),
            is_forced: Some(t.is_forced),
            is_external: Some(t.is_external),
            is_hearing_impaired: Some(t.is_hearing_impaired),
            ..swiftly_model::MediaStream::default()
        })
        .collect()
}

/// A track picked by hand, remembered for the series or film (`TrackMemory.rememberAudio` /
/// `rememberSubtitle`): `kind` is `audio` or `subtitle`, `index` the Jellyfin `Index` (`None` for
/// subtitle = switched off), `name` the player's track name, `title` the key (`account|series`).
/// Returns the dictionary (`tonJeTitel` / `utJeTitel`) with the entry written; the host stores it.
#[uniffi::export]
pub fn remember_track_choice(
    kind: String,
    streams: Vec<PlayerStream>,
    index: Option<i64>,
    name: Option<String>,
    title: String,
    memory: HashMap<String, String>,
) -> HashMap<String, String> {
    use swiftly_playback::track_rule::{Choice, write_choice};
    let media = media_streams(streams);
    let mut all = memory;
    let choice = match index {
        None => Choice::Off,
        Some(i) => match media.iter().find(|s| s.index == Some(i)) {
            Some(feed) => Choice::Track(swiftly_playback::track_mapping::TrackImprint::from_feed(
                feed,
                &media,
                name.as_deref(),
            )),
            None => return all,
        },
    };
    // Audio is always a track; only subtitles can be remembered as off.
    if kind == "audio" && matches!(choice, Choice::Off) {
        return all;
    }
    write_choice(&mut all, &title, &choice);
    all
}

/// The starting audio and subtitle track of a title, for the streams of one version.
/// `audio_memory` and `subtitle_memory` are the dictionaries `tonJeTitel` and `utJeTitel`,
/// `title` the key (`account|series`). `audio_fallback`: the audio track the engine already plays,
/// used (also for the subtitle rule) when no rule names one.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn start_track_choice(
    streams: Vec<PlayerStream>,
    default_audio: Option<i64>,
    default_subtitle: Option<i64>,
    audio_language: String,
    subtitle_language: String,
    automatic_subtitles: bool,
    audio_memory: HashMap<String, String>,
    subtitle_memory: HashMap<String, String>,
    title: String,
    ordered: Option<PlayOrderedTracks>,
    audio_fallback: Option<i64>,
) -> StartTrackChoice {
    let media = media_streams(streams);
    let memory = swiftly_vm::MemoryDictionaries(HashMap::from([
        (
            swiftly_playback::track_rule::AUDIO_KEY.to_owned(),
            audio_memory,
        ),
        (
            swiftly_playback::track_rule::SUBTITLE_KEY.to_owned(),
            subtitle_memory,
        ),
    ]));
    let settings = StartSettings {
        audio_language,
        subtitle_language,
        automatic_subtitles,
        max_bitrate: 0,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
        server_extracts_text: false,
    };
    let (audio, subtitle) = swiftly_vm::start_tracks(
        &media,
        (default_audio, default_subtitle),
        Some(&memory),
        &title,
        &settings,
        ordered.map(|o| TrackIndices {
            audio: o.audio,
            subtitle: o.subtitle,
        }),
        audio_fallback,
    );
    StartTrackChoice { audio, subtitle }
}

/// The key a title's remembered track choices are filed under: `account|series` (the series' id,
/// or the title's own for a film), the bare id without an account.
#[uniffi::export]
pub fn track_memory_key(
    series_id: Option<String>,
    item_id: String,
    account: Option<String>,
) -> String {
    swiftly_playback::track_rule::title_key(series_id.as_deref(), &item_id, account.as_deref())
}

/// One shuffled run through a series (`swiftly_library::shuffle_run`): the host passes the
/// series' episodes, gets the fixed order, and asks for the next title after each one. Hand
/// `next_after` to `PlayNextSource::Given`.
#[derive(uniffi::Object)]
pub struct ShuffleRunModel {
    run: swiftly_library::shuffle_run::ShuffleRun,
}

#[uniffi::export]
impl ShuffleRunModel {
    /// Mix the episodes (the server's `Items` array as JSON). `seed` makes it repeatable;
    /// `None` takes the clock. Unplayed episodes come first, the played ones after.
    #[uniffi::constructor]
    pub fn mixed(episodes_json: String, seed: Option<u64>) -> Result<Arc<Self>, CoreError> {
        let items: Vec<swiftly_model::Item> =
            serde_json::from_str(&episodes_json).map_err(|e| CoreError::Failed {
                message: e.to_string(),
            })?;
        let seed = seed.unwrap_or_else(|| swiftly_library::shuffle_run::SplitMix::from_clock().0);
        let run = swiftly_library::shuffle_run::ShuffleRun::mixed(
            items,
            &mut swiftly_library::shuffle_run::SplitMix(seed),
        );
        Ok(Arc::new(Self { run }))
    }
    /// A run in the given order (a playlist: its entries in their order are the run).
    #[uniffi::constructor]
    pub fn ordered(episodes_json: String) -> Result<Arc<Self>, CoreError> {
        let items: Vec<swiftly_model::Item> =
            serde_json::from_str(&episodes_json).map_err(|e| CoreError::Failed {
                message: e.to_string(),
            })?;
        Ok(Arc::new(Self {
            run: swiftly_library::shuffle_run::ShuffleRun { episodes: items },
        }))
    }
    /// The ids of the run in order.
    pub fn ids(&self) -> Vec<String> {
        self.run.episodes.iter().map(|i| i.id.clone()).collect()
    }
    /// The first episode, `None` for an empty run.
    pub fn first(&self) -> Option<PlayerNext> {
        self.run.episodes.first().map(|i| PlayerNext {
            id: i.id.clone(),
            title: i.name.clone(),
        })
    }
    /// The episode after `id`; `None` at the end and for one that is not in the run.
    pub fn next_after(&self, id: String) -> Option<PlayerNext> {
        self.run.next_after(&id).map(|i| PlayerNext {
            id: i.id.clone(),
            title: i.name.clone(),
        })
    }
    /// Whether the episode is part of the run.
    pub fn contains(&self, id: String) -> bool {
        self.run.contains(&id)
    }
}

#[cfg(test)]
mod shuffle_tests {
    use super::*;

    #[test]
    fn run_keeps_all_and_walks() {
        let json = r#"[{"Id":"a","Name":"A","UserData":{"Played":true}},{"Id":"b","Name":"B"},{"Id":"c","Name":"C"}]"#;
        let r = ShuffleRunModel::mixed(json.into(), Some(7)).unwrap();
        let ids = r.ids();
        assert_eq!(ids.len(), 3);
        assert_eq!(ids[2], "a");
        assert_eq!(r.first().unwrap().id, ids[0]);
        assert_eq!(r.next_after(ids[0].clone()).unwrap().id, ids[1]);
        assert!(r.next_after(ids[2].clone()).is_none());
        assert!(r.next_after("zz".into()).is_none());
        assert!(ShuffleRunModel::mixed("nope".into(), None).is_err());
        let o = ShuffleRunModel::ordered(json.into()).unwrap();
        assert_eq!(o.ids(), vec!["a", "b", "c"]);
        assert_eq!(o.next_after("b".into()).unwrap().id, "c");
    }
}
