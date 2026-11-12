//! The play plan of the player screens: from a title to everything a player needs to open
//! (`PlayRequest.start`, `AppModel.plan(for:)`, `engineRequest`, `TrackRule.start`, `resumeFrom`,
//! `sections`, `trickplay`, `chapter`). The host asks once and gets a [`StartAnswer`]:
//! either a ready start, the versions to choose from, or the reason there is nothing to play.

use std::collections::HashMap;

use swiftly_downloads::{DownloadItem, DownloadRules};
use swiftly_jellyfin::{ServerKind, TrackIndices};
use swiftly_model::{DeliveryMethod, Item, MediaSource, MediaStream, MediaVersions, VersionStart};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::device_profile::{DeviceProfile, Flavour};
use swiftly_playback::dolby_vision::HostDecoders;
use swiftly_playback::media_server::MediaServer;
use swiftly_playback::playback_plan::PlaybackPlan;
use swiftly_playback::sections::Segment;
use swiftly_playback::track_mapping::{SubtitleFile, TrackImprint};
use swiftly_playback::track_rule::{
    self, AUDIO_KEY, Choice, SUBTITLE_KEY, Subtitle, SubtitleInput,
};
use swiftly_playback::trickplay::{DEFAULT_TARGET, Trickplay, TrickplayResponse};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::chapter::{Chapter, ChapterBar};

use crate::detail::{Server, VersionOption, fetch_plan_for};
use crate::player_extra::TrackMemoryStore;
use crate::title_text::resume_from;

/// A copy of the title on the device (`downloads.file(for:)` and its entry).
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadedFile {
    /// The file's address (`file://...`).
    pub file: String,
    /// Container remembered at download time.
    pub container: Option<String>,
    /// Media source id remembered at download time.
    pub source: Option<String>,
    /// Video codec remembered at download time.
    pub video_codec: Option<String>,
    /// Intro/outro sections stored at download time (`DownloadRules.sections`).
    pub sections: Option<Vec<Segment>>,
    /// Subtitle files that came along with the download.
    pub subtitle_files: Vec<SubtitleFile>,
}

/// The settings a start reads.
#[derive(Debug, Clone, PartialEq)]
pub struct StartSettings {
    /// `tonSprache`.
    pub audio_language: String,
    /// `utSprache`.
    pub subtitle_language: String,
    /// `utAuto`.
    pub automatic_subtitles: bool,
    /// The bitrate the profile reports (`BitratesLimit.of`).
    pub max_bitrate: i64,
    /// `pufferstufe`.
    pub buffer_level: BufferLevel,
    /// Frame-rate matching is on.
    pub frame_rate_match: bool,
    /// "Keep the file's style" off: the server hands ASS out as SRT (`fileStyleAdjustable`).
    pub server_extracts_text: bool,
}

/// Where "next episode" comes from (`AppModel.episodePost`).
#[derive(Debug, Clone, Default)]
pub enum NextSource {
    /// No next episode (a group plays without one, everyone would drift apart).
    #[default]
    None,
    /// The old rule: the next downloaded episode without a network, else the server's answer
    /// (`adjacentTo`); a failing request falls back to the downloaded one, "none" stands.
    Rule {
        /// The account's downloads.
        downloads: Vec<DownloadItem>,
        /// No network: the server is not even asked.
        without_network: bool,
    },
    /// A shuffled run goes along its own order: the host names the next one (`None` = its end).
    Given(Option<Box<Item>>),
}

/// What the host asks for.
#[derive(Debug, Clone)]
pub struct StartRequest {
    /// The title.
    pub item_id: String,
    /// The version the user picked.
    pub source_id: Option<String>,
    /// The start position; `None`: the title's remembered one.
    pub since: Option<f64>,
    /// The engine's profile.
    pub flavour: Flavour,
    /// The device decodes AV1 in hardware (host probe); decides whether AV1 Dolby Vision 10.0 is transcoded
    /// ([`swiftly_playback::dolby_vision`]). `false` when the host does not know.
    pub hardware_av1: bool,
    /// The device has no Dolby Vision decoder: profile 5 (no HDR10 base layer) is then transcoded by the server.
    pub no_dolby_vision_decoder: bool,
    /// The caller can ask for a version: several versions end in [`StartAnswer::Choose`].
    pub ask_versions: bool,
    /// A copy on the device wins over the server.
    pub downloaded: Option<DownloadedFile>,
    /// Tracks chosen on the client that sent the title here (`PlayOrder.tracks`).
    pub ordered: Option<TrackIndices>,
    /// The account in front of the memory key (`account|series`).
    pub account_key: Option<String>,
    /// Settings.
    pub settings: StartSettings,
    /// Where the next episode comes from.
    pub next: NextSource,
}

/// Everything a screen needs to open a title.
#[derive(Debug, Clone)]
pub struct ReadyStart {
    /// The plan.
    pub plan: PlaybackPlan,
    /// The full title.
    pub item: Item,
    /// The second to start at.
    pub start_at: f64,
    /// The chosen version: the plan's source, else the title's own entry for the id (a copy on the device has none
    /// in its plan). `streams` are its `MediaStreams`.
    pub source: Option<MediaSource>,
    /// Streams of the chosen version.
    pub streams: Vec<MediaStream>,
    /// Starting audio track (Jellyfin index).
    pub audio: Option<i64>,
    /// Starting subtitle track, `-1` off.
    pub subtitle: i64,
    /// External subtitle files for the engine.
    pub subtitle_files: Vec<SubtitleFile>,
    /// The memory key of the title; `None` for a copy without a title key.
    pub track_title: String,
    /// Intro, recap, outro.
    pub sections: Vec<Segment>,
    /// Chapters that divide the bar.
    pub chapters: Vec<Chapter>,
    /// Trickplay sheet description.
    pub trickplay: Option<Trickplay>,
    /// Address and token to build sheet and file URLs from.
    pub server: String,
    /// The episode after this one (`AppModel.episodePost`), per [`StartRequest::next`].
    pub next: Option<Item>,
    /// What the screens show about the title (header, file line, pictures, HDR badge, next card); filled by
    /// [`play_start`], which knows the language.
    pub display: crate::play_display::PlayDisplay,
}

/// The answer.
#[derive(Debug, Clone)]
pub enum StartAnswer {
    /// Ready to open.
    Ready(Box<ReadyStart>),
    /// Several versions, none picked: ask.
    Choose {
        /// The full title.
        item: Box<Item>,
        /// The versions.
        versions: Vec<VersionOption>,
        /// The start meant for the pick.
        since: f64,
    },
    /// The server names no source (a series).
    NoSource,
    /// The versions could not be loaded.
    VersionsFailed,
    /// The plan failed.
    Failed(ErrorKind),
}

/// The starting tracks of a title: remembered choice, then the server's default, then the
/// settings; an order from another client wins (`TrackRule.start` with `ordered`).
/// `audio_fallback`: the audio track already playing, used when no rule names one.
pub fn start_tracks(
    streams: &[MediaStream],
    server_defaults: (Option<i64>, Option<i64>),
    memory: Option<&dyn TrackMemoryStore>,
    title: &str,
    settings: &StartSettings,
    ordered: Option<TrackIndices>,
    audio_fallback: Option<i64>,
) -> (Option<i64>, i64) {
    let (remembered_audio, remembered_subtitle): (Option<TrackImprint>, Option<Choice>) = memory
        .map_or((None, None), |m| {
            let audio = track_rule::read_audio(&m.load(AUDIO_KEY), title);
            let subtitle = track_rule::read_choice(&m.load(SUBTITLE_KEY), title);
            (audio, subtitle)
        });
    let audio = track_rule::audio(
        streams,
        remembered_audio.as_ref(),
        &settings.audio_language,
        server_defaults.0,
        ordered.and_then(|o| o.audio),
    )
    // The track the engine already plays stands in when no rule names one (it also feeds the
    // subtitle rule, as `avTracksApply` always did).
    .or(audio_fallback);
    let choice = track_rule::subtitle(
        streams,
        &SubtitleInput {
            remembered: remembered_subtitle,
            server_default: server_defaults.1,
            automatic: settings.automatic_subtitles,
            audio_index: audio,
            audio_wish: &settings.audio_language,
            preferred_language: &settings.subtitle_language,
            ordered: ordered.and_then(|o| o.subtitle),
        },
    );
    let subtitle = match choice {
        Subtitle::Feed(i) => i,
        Subtitle::Off => -1,
    };
    (audio, subtitle)
}

/// Raw items of `MediaSegments` (`segmentsToStore`): an error answer counts as none.
fn segments_of(value: &serde_json::Value) -> Vec<Segment> {
    value
        .get("Items")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|s| serde_json::from_value::<Segment>(s.clone()).ok())
                .collect()
        })
        .unwrap_or_default()
}

/// `Chapters` of an item answer, cleaned for the bar (`ChapterBar.usable`).
fn chapters_of(value: &serde_json::Value) -> Vec<Chapter> {
    let list: Vec<Chapter> = value
        .get("Chapters")
        .and_then(|v| v.as_array())
        .map(|a| {
            // A chapter without a position is dropped, not put at 0 where it would sit on top of
            // the first one (`Chapter.init(from:)` throws, `Lenient` drops exactly that one).
            a.iter()
                .filter_map(|c| {
                    let ticks = c
                        .get("StartPositionTicks")
                        .and_then(serde_json::Value::as_i64)?;
                    Some(Chapter::from_ticks(
                        c.get("Name").and_then(|n| n.as_str()),
                        ticks,
                    ))
                })
                .collect()
        })
        .unwrap_or_default();
    ChapterBar::usable(&list)
}

impl<T: HttpTransport + 'static> Server<T> {
    async fn sections_of(&self, item_id: &str) -> Vec<Segment> {
        match self {
            Self::Jelly(c) => {
                if c.current_session()
                    .is_some_and(|s| s.kind == ServerKind::Emby)
                {
                    return Vec::new();
                }
                match c.raw_json(&format!("MediaSegments/{item_id}"), &[]).await {
                    Ok(v) => segments_of(&v),
                    Err(_) => Vec::new(),
                }
            }
            Self::Plex(c) => MediaServer::sections(&**c, item_id).await,
        }
    }

    async fn trickplay_of(&self, item_id: &str, source: Option<&str>) -> Option<Trickplay> {
        match self {
            Self::Jelly(c) => {
                let s = c.current_session()?;
                if s.kind == ServerKind::Emby {
                    return None;
                }
                let v = c
                    .raw_json(
                        &format!("Items/{item_id}"),
                        &[("userId", s.user_id.as_str()), ("Fields", "Trickplay")],
                    )
                    .await
                    .ok()?;
                serde_json::from_value::<TrickplayResponse>(v)
                    .ok()?
                    .of_target(source, DEFAULT_TARGET)
            }
            Self::Plex(c) => MediaServer::trickplay(&**c, item_id, source, DEFAULT_TARGET).await,
        }
    }

    async fn chapters_for(&self, item_id: &str, source: Option<&str>) -> Vec<Chapter> {
        match self {
            Self::Jelly(c) => {
                let Some(s) = c.current_session() else {
                    return Vec::new();
                };
                let query = |id: String| {
                    let user = s.user_id.clone();
                    async move {
                        c.raw_json(
                            &format!("Items/{id}"),
                            &[("userId", user.as_str()), ("Fields", "Chapters")],
                        )
                        .await
                        .ok()
                        .map(|v| chapters_of(&v))
                    }
                };
                // The version asks first: each version of a movie is a title of its own.
                if let Some(src) = source.filter(|x| !x.eq_ignore_ascii_case(item_id))
                    && let Some(found) = query(src.to_owned()).await
                {
                    return found;
                }
                query(item_id.to_owned()).await.unwrap_or_default()
            }
            Self::Plex(c) => MediaServer::chapter(&**c, item_id, source).await,
        }
    }

    /// Address and token to build file addresses from.
    fn address(&self) -> (String, Option<String>, &'static str) {
        match self {
            Self::Jelly(c) => {
                let s = c.current_session();
                let kind = s.as_ref().map_or(ServerKind::Jellyfin, |s| s.kind);
                (
                    c.base_url().to_string(),
                    s.map(|s| s.access_token),
                    swiftly_jellyfin::token_name(kind),
                )
            }
            Self::Plex(c) => (
                c.base_url().to_string(),
                Some(c.access_token()),
                swiftly_jellyfin::token_name(ServerKind::Plex),
            ),
        }
    }

    async fn plan_with(
        &self,
        item_id: &str,
        flavour: Flavour,
        host: HostDecoders,
        max_bitrate: i64,
        source_id: Option<&str>,
    ) -> Result<Option<PlaybackPlan>, ErrorKind> {
        match self {
            Self::Jelly(c) => {
                fetch_plan_for(
                    &**c,
                    item_id,
                    DeviceProfile::for_flavour(flavour, max_bitrate),
                    source_id,
                    Some((flavour, host)),
                )
                .await
            }
            Self::Plex(c) => c
                .plan_for_device(item_id, source_id, None, None, (flavour, host))
                .await
                .map(Some)
                .map_err(|e| e.into_kind()),
        }
    }

    /// The plan again with the chosen subtitle, when the plan transcodes and the track must be burned in or
    /// out ([`swiftly_playback::transcode_subtitle::delivery`]); `None` keeps the plan as it is.
    #[allow(clippy::too_many_arguments)] // the plan inputs are separate values, as on the Swift side
    pub(crate) async fn replan(
        &self,
        item_id: &str,
        flavour: Flavour,
        host: HostDecoders,
        max_bitrate: i64,
        plan: &PlaybackPlan,
        streams: &[MediaStream],
        subtitle: i64,
    ) -> Option<PlaybackPlan> {
        match self {
            Self::Jelly(c) => {
                crate::detail::replan_for_subtitle(
                    &**c,
                    item_id,
                    &DeviceProfile::for_flavour(flavour, max_bitrate),
                    plan,
                    streams,
                    subtitle,
                )
                .await
            }
            Self::Plex(c) => {
                use swiftly_playback::transcode_subtitle::{SubtitleDelivery, delivery};
                if delivery(
                    plan.method == DeliveryMethod::Transcode,
                    &plan.url,
                    streams,
                    subtitle,
                ) != SubtitleDelivery::Replan
                {
                    return None;
                }
                c.plan_for_device(
                    item_id,
                    plan.media_source_id.as_deref(),
                    None,
                    Some(subtitle),
                    (flavour, host),
                )
                .await
                .ok()
                .filter(|p| p.method == DeliveryMethod::Transcode)
            }
        }
    }

    /// The episode after `item`, by the old rule (`AppModel.episodePost`).
    async fn next_of(&self, item: &Item, source: &NextSource) -> Option<Item> {
        match source {
            NextSource::None => None,
            NextSource::Given(next) => next.as_deref().cloned(),
            NextSource::Rule {
                downloads,
                without_network,
            } => {
                DownloadRules::episode_post_item(item, downloads, *without_network, || async {
                    let Some(series) = item.series_id.as_deref() else {
                        return Ok(None);
                    };
                    match self {
                        Self::Jelly(c) => c.episode_post(&item.id, series).await,
                        Self::Plex(c) => MediaServer::episode_post(&**c, &item.id, series).await,
                    }
                })
                .await
            }
        }
    }

    /// The whole start (`PlayRequest.start`).
    pub(crate) async fn start(
        &self,
        request: &StartRequest,
        memory: Option<&dyn TrackMemoryStore>,
        words: &crate::tile::Words,
        language: &str,
    ) -> StartAnswer {
        let downloaded = request.downloaded.is_some();
        let open = request.ask_versions && request.source_id.is_none();
        // The full title: the list entry has no `MediaSources`. A copy on the device plays
        // without the server, so a title that cannot be fetched is not an error there.
        let fetched = self.item(&request.item_id).await;
        let item = match fetched {
            Ok(item) => item,
            Err(e) if !downloaded => {
                return if open {
                    StartAnswer::VersionsFailed
                } else {
                    StartAnswer::Failed(e)
                };
            }
            Err(_) => Item {
                id: request.item_id.clone(),
                ..Item::default()
            },
        };
        let since = request.since.or_else(|| resume_from(&item)).unwrap_or(0.0);
        if open
            && !downloaded
            && let VersionStart::Choose(versions) =
                MediaVersions::start(Some(item.media_sources.as_deref().unwrap_or(&[])), false)
        {
            return StartAnswer::Choose {
                versions: versions
                    .iter()
                    .filter_map(|v| VersionOption::of(v, words, language))
                    .collect(),
                item: Box::new(item),
                since,
            };
        }
        // A copy on the device: the server is not asked.
        let mut plan = if let Some(file) = &request.downloaded {
            PlaybackPlan::from_slab(
                &file.file,
                file.container.as_deref(),
                file.source.as_deref(),
                file.video_codec.as_deref(),
            )
        } else {
            match self
                .plan_with(
                    &request.item_id,
                    request.flavour,
                    HostDecoders {
                        hardware_av1: request.hardware_av1,
                        no_dolby_vision: request.no_dolby_vision_decoder,
                    },
                    request.settings.max_bitrate,
                    request.source_id.as_deref(),
                )
                .await
            {
                Ok(Some(plan)) => plan,
                Ok(None) => return StartAnswer::NoSource,
                Err(e) => return StartAnswer::Failed(e),
            }
        };
        let source = plan.source.clone().or_else(|| {
            let wanted = plan.media_source_id.as_deref();
            let all = item.media_sources.as_deref().unwrap_or(&[]);
            all.iter()
                .find(|s| wanted.is_some() && s.id.as_deref() == wanted)
                .or_else(|| all.first())
                .cloned()
        });
        let mut streams: Vec<MediaStream> = source
            .as_ref()
            .and_then(|s| s.media_streams.clone())
            .unwrap_or_default();
        let title = track_rule::title_key(
            item.series_id.as_deref(),
            &item.id,
            request.account_key.as_deref(),
        );
        let (audio, subtitle) = start_tracks(
            &streams,
            (
                source.as_ref().and_then(|s| s.default_audio_stream_index),
                source
                    .as_ref()
                    .and_then(|s| s.default_subtitle_stream_index),
            ),
            memory,
            &title,
            &request.settings,
            request.ordered,
            None,
        );
        // A transcode carries no bitmap subtitle unless the request names it: ask again with the chosen
        // track (burned in by the server). Direct play and text tracks keep the first plan.
        if request.downloaded.is_none()
            && let Some(again) = self
                .replan(
                    &request.item_id,
                    request.flavour,
                    HostDecoders {
                        hardware_av1: request.hardware_av1,
                        no_dolby_vision: request.no_dolby_vision_decoder,
                    },
                    request.settings.max_bitrate,
                    &plan,
                    &streams,
                    subtitle,
                )
                .await
        {
            plan = again;
        }
        // A transcode (HLS) carries no text track: the server delivers it as a file, which the players load as one.
        if plan.method == DeliveryMethod::Transcode {
            swiftly_playback::track_mapping::mark_delivered_files(&mut streams);
        }
        let (server, key, key_name) = self.address();
        let subtitle_files = if let Some(file) = &request.downloaded {
            file.subtitle_files.clone()
        } else {
            SubtitleFile::for_avplayer(
                &streams,
                &item.id,
                plan.media_source_id.as_deref(),
                &server,
                key.as_deref(),
                key_name,
                request.settings.server_extracts_text,
                matches!(
                    request.flavour,
                    Flavour::Aether | Flavour::Mpv | Flavour::Media3
                ),
            )
        };
        let next = self.next_of(&item, &request.next).await;
        let (sections, trickplay, chapters) = if let Some(file) = &request.downloaded {
            // Stored sections first; offline there are no others.
            let stored = file.sections.clone();
            let sections = match stored {
                Some(s) => s,
                None => self.sections_of(&item.id).await,
            };
            (sections, None, Vec::new())
        } else {
            let source_id = plan.media_source_id.clone();
            let (sections, trickplay, chapters) = futures_util::future::join3(
                self.sections_of(&item.id),
                self.trickplay_of(&item.id, source_id.as_deref()),
                self.chapters_for(&item.id, source_id.as_deref()),
            )
            .await;
            (sections, trickplay, chapters)
        };
        StartAnswer::Ready(Box::new(ReadyStart {
            plan,
            item,
            start_at: since,
            source,
            streams,
            audio,
            subtitle,
            subtitle_files,
            track_title: title,
            sections,
            chapters,
            trickplay,
            server,
            next,
            display: crate::play_display::PlayDisplay::default(),
        }))
    }
}

/// The remembered choices as the dictionaries the store holds, for tests and hosts.
#[derive(Default)]
pub struct MemoryDictionaries(pub HashMap<String, HashMap<String, String>>);

impl TrackMemoryStore for MemoryDictionaries {
    fn load(&self, key: &str) -> HashMap<String, String> {
        self.0.get(key).cloned().unwrap_or_default()
    }
    fn save(&self, _key: &str, _all: &HashMap<String, String>) {}
}

/// Asks for the play plan of a title: the one call the player screens make before a start.
/// `memory` is the hand-chosen track store, `None` remembers nothing.
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
pub async fn play_start<T: HttpTransport + 'static>(
    transport: std::sync::Arc<T>,
    host: &crate::host::Host,
    account: &crate::account::AccountRef,
    request: &StartRequest,
    memory: Option<&dyn TrackMemoryStore>,
) -> Result<StartAnswer, ErrorKind> {
    let server = server_of(&transport, host, account)?;
    let mut answer = server
        .start(
            request,
            memory,
            &crate::tile::Words::new(host.locale.clone()),
            host.locale.language(),
        )
        .await;
    if let StartAnswer::Ready(ready) = &mut answer {
        let addresses = server.addresses();
        ready.display = crate::play_display::play_display(
            &ready.item,
            ready.plan.method,
            ready.source.as_ref(),
            ready.next.as_ref(),
            addresses.as_ref(),
            host.locale.clone(),
        );
    }
    Ok(answer)
}

fn server_of<T: HttpTransport + 'static>(
    transport: &std::sync::Arc<T>,
    host: &crate::host::Host,
    account: &crate::account::AccountRef,
) -> Result<Server<T>, ErrorKind> {
    let (client, plex) = crate::detail::clients(transport, host, Some(account))?;
    match (client, plex) {
        (Some(c), _) => Ok(Server::Jelly(c)),
        (None, Some(p)) => Ok(Server::Plex(p)),
        (None, None) => Err(ErrorKind::InvalidServerUrl),
    }
}

/// The skip sections of a title (intro, recap, outro ...) from the server; empty when it knows none
/// or cannot be reached (`AppModel.sections` without the stored ones of a download).
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
pub async fn play_sections<T: HttpTransport + 'static>(
    transport: std::sync::Arc<T>,
    host: &crate::host::Host,
    account: &crate::account::AccountRef,
    item_id: &str,
) -> Result<Vec<Segment>, ErrorKind> {
    Ok(server_of(&transport, host, account)?
        .sections_of(item_id)
        .await)
}

/// The preview sheets of a version (`AppModel.trickplay`); `None` without trickplay on the server.
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
pub async fn play_trickplay<T: HttpTransport + 'static>(
    transport: std::sync::Arc<T>,
    host: &crate::host::Host,
    account: &crate::account::AccountRef,
    item_id: &str,
    source: Option<&str>,
) -> Result<Option<Trickplay>, ErrorKind> {
    Ok(server_of(&transport, host, account)?
        .trickplay_of(item_id, source)
        .await)
}

/// The chapters of a title cleaned for the bar (`AppModel.chapter`).
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
pub async fn play_chapters<T: HttpTransport + 'static>(
    transport: std::sync::Arc<T>,
    host: &crate::host::Host,
    account: &crate::account::AccountRef,
    item_id: &str,
    source: Option<&str>,
) -> Result<Vec<Chapter>, ErrorKind> {
    Ok(server_of(&transport, host, account)?
        .chapters_for(item_id, source)
        .await)
}

/// The plan of a title alone (`JellyfinClient.playbackPlan`): one `PlaybackInfo` request with the profile of
/// `flavour` (`hardware_av1`: see [`StartRequest::hardware_av1`]), the cheapest version or the one picked. `Ok(None)`: the server names no source. `subtitle`: the track a
/// running transcode must now show (or drop): the plan comes with it burned in (or out), see
/// [`swiftly_playback::transcode_subtitle::delivery`].
///
/// # Errors
/// The server's or the network's error, as the old client threw it.
#[allow(clippy::too_many_arguments)]
pub async fn play_plan_only<T: HttpTransport + 'static>(
    transport: std::sync::Arc<T>,
    host: &crate::host::Host,
    account: &crate::account::AccountRef,
    item_id: &str,
    flavour: Flavour,
    hardware_av1: bool,
    max_bitrate: i64,
    source_id: Option<&str>,
    subtitle: Option<i64>,
) -> Result<Option<PlaybackPlan>, ErrorKind> {
    let server = server_of(&transport, host, account)?;
    let plan = server
        .plan_with(
            item_id,
            flavour,
            HostDecoders::av1(hardware_av1),
            max_bitrate,
            source_id,
        )
        .await?;
    // A chosen subtitle while a transcode runs: the same plan, asking for the track (burned in, or dropped again).
    let (Some(plan), Some(subtitle)) = (plan.clone(), subtitle) else {
        return Ok(plan);
    };
    let streams = plan
        .source
        .as_ref()
        .and_then(|s| s.media_streams.clone())
        .unwrap_or_default();
    let again = server
        .replan(
            item_id,
            flavour,
            HostDecoders::av1(hardware_av1),
            max_bitrate,
            &plan,
            &streams,
            subtitle,
        )
        .await;
    Ok(Some(again.unwrap_or(plan)))
}

/// The episode after `item` by the old rule (`AppModel.episodePost`), for a title that opened from disk: the server's answer
/// arrives after the start (`Kern.playbackLookUp`).
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the account's address is not an http(s) address.
pub async fn play_next<T: HttpTransport + 'static>(
    transport: std::sync::Arc<T>,
    host: &crate::host::Host,
    account: &crate::account::AccountRef,
    item: &Item,
    source: &NextSource,
) -> Result<Option<Item>, ErrorKind> {
    Ok(server_of(&transport, host, account)?
        .next_of(item, source)
        .await)
}
