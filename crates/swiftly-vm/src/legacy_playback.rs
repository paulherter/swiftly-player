#![allow(missing_docs)]
//! The playback state of the old Android facade (`Kern`'s `Playback`): the plan of the open title with its tracks,
//! chapters and trickplay, answered as the finished JSON the Compose player parses (`playbackOpen`, `tracksSelect`,
//! `trackNames`, `audioFromHand`, `subtitleFromHand`, `subtitleFiles`, `chapter*`, `trickplay*`). The plan comes from
//! the same `play_start` the new player uses; the decisions are the track rules and chapter rules of the packages.
//! Jellyfin and Emby accounts; Plex stays on the Swift path.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::json;
use swiftly_images::{ImageAddress, ImageKind as Art, ImageMetric};
use swiftly_jellyfin::TrackIndices;
use swiftly_model::{MediaSource, MediaStream};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::device_profile::Flavour;
use swiftly_playback::original_audio;
use swiftly_playback::track_label::{self, LabelText, codec_name_value, codec_name_value_vlc_id};
use swiftly_playback::track_mapping::{PlayerTrack, SubtitleFile, TrackImprint, TrackMapping};
use swiftly_playback::track_rule::{self, Choice, Subtitle, SubtitleInput};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::chapter::{Chapter, ChapterBar};
use swiftly_rules::playback_levels::bitrate_limit_of;

use crate::account::AccountRef;
use crate::home::{Client, Source, build_source};
use crate::host::Host;
use crate::language_names::LabelWords;
use crate::play_display::{PlayDisplay, play_display};
use crate::player_start::{
    NextSource, ReadyStart, StartAnswer, StartRequest, StartSettings, play_start,
};

/// One track as the engine reports it (`TrackInput`).
#[derive(Deserialize)]
struct TrackInput {
    id: i64,
    #[serde(rename = "kennung", default)]
    identifier: String,
    #[serde(default)]
    name: String,
    #[serde(rename = "sprache")]
    language: Option<String>,
    fourcc: Option<i64>,
    #[serde(rename = "kanaele")]
    channels: Option<i64>,
}

impl TrackInput {
    /// libVLC 3 names tracks "Track 1 - [English]"; the language is in the brackets.
    fn bracket_language(name: &str) -> Option<String> {
        let inner = name.strip_suffix(']')?;
        let (_, inner) = inner.rsplit_once('[')?;
        (!inner.is_empty()).then(|| inner.to_owned())
    }

    fn track(&self) -> PlayerTrack {
        let language = self
            .language
            .clone()
            .filter(|l| !l.is_empty())
            .or_else(|| Self::bracket_language(&self.name));
        let codec = self
            .fourcc
            .filter(|f| *f != 0)
            .and_then(|f| codec_name_value_vlc_id(f as u32));
        PlayerTrack {
            identifier: self.identifier.clone(),
            name: self.name.clone(),
            language,
            codec,
            channels: self.channels.filter(|c| *c > 0),
        }
    }
}

fn tracks(json: &str) -> Vec<TrackInput> {
    serde_json::from_str(json).unwrap_or_default()
}

fn memory(store: &str) -> HashMap<String, String> {
    serde_json::from_str(store).unwrap_or_default()
}

/// What `tracksSelect` and the hand choices keep for the reports and later calls.
#[derive(Default, Clone)]
pub(crate) struct Chosen {
    pub(crate) audio: Option<i64>,
    pub(crate) subtitle: Option<i64>,
    /// A subtitle file chosen but not yet reported by the engine.
    pub(crate) opened: Option<i64>,
}

pub(crate) struct State {
    pub(crate) always_direct_play: bool,
    pub(crate) megabit: i64,
    pub(crate) server_extracts_text: bool,
    pub(crate) no_dolby_vision_decoder: bool,
    pub(crate) downloads: String,
    pub(crate) without_network: bool,
    pub(crate) ready: Option<ReadyStart>,
    pub(crate) display: Option<PlayDisplay>,
    pub(crate) files: Vec<SubtitleFile>,
    pub(crate) chapters: Vec<Chapter>,
    pub(crate) chosen: Chosen,
    pub(crate) ordered: Option<(String, TrackIndices)>,
    pub(crate) live: crate::legacy_playback_run::Live,
    pub(crate) without_next: bool,
    /// The last tech-badge measurement (`Kern._counter`); `tech_fixed` clears it.
    pub(crate) counter: Option<swiftly_rules::counter::Counter>,
}

/// The open title of one account.
pub struct LegacyPlayback<T: HttpTransport + 'static> {
    pub(crate) transport: Arc<T>,
    pub(crate) host: Host,
    pub(crate) account: AccountRef,
    /// The Jellyfin client; `None` for Plex (no trickplay sheets there).
    pub(crate) client: Option<Arc<Client<T>>>,
    pub(crate) addresses: ImageAddress,
    pub(crate) words: LabelWords,
    pub(crate) state: Mutex<State>,
    pub(crate) run: Arc<crate::legacy_playback_run::Run>,
}

#[derive(Serialize)]
struct NextOut {
    id: String,
    name: String,
    #[serde(rename = "kuerzel")]
    abbreviation: String,
    #[serde(rename = "bild", skip_serializing_if = "Option::is_none")]
    image: Option<String>,
}

#[derive(Serialize)]
struct PlanOut {
    url: String,
    lossless: bool,
    #[serde(rename = "methode")]
    method: String,
    #[serde(rename = "titel")]
    title: String,
    #[serde(rename = "untertitel")]
    subtitle: String,
    #[serde(rename = "naechste")]
    next: bool,
    #[serde(rename = "dateizeile", skip_serializing_if = "Option::is_none")]
    file_row: Option<String>,
    #[serde(rename = "serie", skip_serializing_if = "Option::is_none")]
    series: Option<String>,
    #[serde(rename = "kuerzel", skip_serializing_if = "Option::is_none")]
    abbreviation: Option<String>,
    #[serde(rename = "bild", skip_serializing_if = "Option::is_none")]
    image: Option<String>,
    #[serde(rename = "itemId")]
    item_id: String,
    episode: bool,
    #[serde(rename = "serieId", skip_serializing_if = "Option::is_none")]
    series_id: Option<String>,
    #[serde(rename = "staffelId", skip_serializing_if = "Option::is_none")]
    season_id: Option<String>,
    #[serde(rename = "kopfzeile")]
    header_line: String,
    #[serde(rename = "staffelNr", skip_serializing_if = "Option::is_none")]
    season_number: Option<i64>,
    #[serde(rename = "folgeNr", skip_serializing_if = "Option::is_none")]
    episode_number: Option<i64>,
    #[serde(rename = "nebenzeile", skip_serializing_if = "Option::is_none")]
    secondary_line: Option<String>,
    #[serde(rename = "marken")]
    marks: Vec<f64>,
    #[serde(rename = "softwareDekoder")]
    software_decoder: bool,
    #[serde(rename = "naechsteFolge", skip_serializing_if = "Option::is_none")]
    next_episode: Option<NextOut>,
    #[serde(rename = "kartenbild", skip_serializing_if = "Option::is_none")]
    card_image: Option<String>,
    #[serde(rename = "dolbyVision", skip_serializing_if = "Option::is_none")]
    dolby_vision: Option<i64>,
    #[serde(rename = "audioCodec", skip_serializing_if = "Option::is_none")]
    audio_codec: Option<String>,
}

fn json<V: Serialize>(v: &V) -> Result<String, ErrorKind> {
    serde_json::to_string(v).map_err(|e| ErrorKind::Decoding(e.to_string()))
}

fn stream_of<'a>(streams: &'a [MediaStream], kind: &str, index: i64) -> Option<&'a MediaStream> {
    streams
        .iter()
        .find(|s| s.type_.as_deref() == Some(kind) && s.index == Some(index))
}

impl<T: HttpTransport + 'static> LegacyPlayback<T> {
    pub fn new(
        transport: &Arc<T>,
        host: &Host,
        account: &AccountRef,
        desk: Arc<crate::ReportDesk>,
    ) -> Result<Self, ErrorKind> {
        let source = build_source(transport, host, account)?;
        let addresses = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
        let client = match source {
            Source::Jellyfin(client) => Some(client),
            _ => None,
        };
        Ok(Self {
            transport: Arc::clone(transport),
            host: host.clone(),
            account: account.clone(),
            client,
            addresses,
            words: LabelWords::new(host.locale.clone()),
            state: Mutex::new(State {
                always_direct_play: true,
                megabit: 0,
                server_extracts_text: false,
                no_dolby_vision_decoder: false,
                downloads: "[]".into(),
                without_network: false,
                ready: None,
                display: None,
                files: Vec::new(),
                chapters: Vec::new(),
                chosen: Chosen::default(),
                ordered: None,
                live: crate::legacy_playback_run::Live::new(),
                without_next: false,
                counter: None,
            }),
            run: Arc::new(crate::legacy_playback_run::Run::new(desk)),
        })
    }

    pub(crate) fn locked<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        f(&mut self.state.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// `Kern.playbackSelection`.
    pub fn playback_selection(&self, always_direct_play: bool, megabit: i64) {
        self.locked(|s| {
            s.always_direct_play = always_direct_play;
            s.megabit = megabit;
        });
    }

    /// The downloads list (`liste.json`) and whether there is no network: where "next episode" comes from.
    pub fn set_downloads(&self, list: &str, without_network: bool) {
        self.locked(|s| {
            s.downloads = list.to_owned();
            s.without_network = without_network;
        });
    }

    /// `Kern.subtitleLookReport`: with "keep the file's style" off the server hands ASS out as SRT.
    pub fn set_server_extracts_text(&self, on: bool) {
        self.locked(|s| s.server_extracts_text = on);
    }

    /// The device has no Dolby Vision decoder (`MediaCodecList`): profile 5 is then planned as a server transcode.
    pub fn set_no_dolby_vision_decoder(&self, on: bool) {
        self.locked(|s| s.no_dolby_vision_decoder = on);
    }

    /// A group plays without a next episode (`_withoutNext`).
    pub fn set_without_next(&self, on: bool) {
        self.locked(|s| s.without_next = on);
    }

    /// The running title as an order for another device (`playHandOver`): item, version, the audio and
    /// subtitle track (Jellyfin indices, `-1` off) that play now. `None` when nothing is open.
    pub fn hand_over_order(&self) -> Option<(String, Option<String>, Option<i64>, i64)> {
        self.locked(|s| {
            let r = s.ready.as_ref()?;
            Some((
                r.item.id.clone(),
                r.plan.media_source_id.clone(),
                s.chosen.audio.or(r.audio),
                s.chosen.subtitle.unwrap_or(r.subtitle),
            ))
        })
    }

    /// Tracks sent with the title from another client (`playArrived`); other titles ignore them.
    pub fn set_ordered(&self, item_id: &str, audio: Option<i64>, subtitle: Option<i64>) {
        self.locked(|s| s.ordered = Some((item_id.to_owned(), TrackIndices { audio, subtitle })));
    }

    /// The plan of a title without setting anything (`playbackFetch`): the old playback stays until a new one is installed.
    pub(crate) async fn fetch(
        &self,
        id: &str,
        source_id: &str,
    ) -> Result<(ReadyStart, PlayDisplay), ErrorKind> {
        let (always, megabit, extracts, no_dv, downloads, without_network, ordered) =
            self.locked(|s| {
                (
                    s.always_direct_play,
                    s.megabit,
                    s.server_extracts_text,
                    s.no_dolby_vision_decoder,
                    s.downloads.clone(),
                    s.without_network,
                    s.ordered
                        .clone()
                        .filter(|(item, _)| item == id)
                        .map(|(_, t)| t),
                )
            });
        let request = StartRequest {
            item_id: id.to_owned(),
            source_id: (!source_id.is_empty()).then(|| source_id.to_owned()),
            since: None,
            flavour: Flavour::Media3,
            hardware_av1: false,
            no_dolby_vision_decoder: no_dv,
            ask_versions: false,
            downloaded: None,
            ordered,
            account_key: None,
            settings: StartSettings {
                audio_language: String::new(),
                subtitle_language: String::new(),
                automatic_subtitles: false,
                max_bitrate: bitrate_limit_of(always, megabit),
                buffer_level: BufferLevel::Normal,
                frame_rate_match: false,
                server_extracts_text: extracts,
            },
            next: NextSource::Rule {
                downloads: serde_json::from_str(&downloads).unwrap_or_default(),
                without_network,
            },
        };
        let answer = play_start(
            Arc::clone(&self.transport),
            &self.host,
            &self.account,
            &request,
            None,
        )
        .await?;
        let mut ready = match answer {
            StartAnswer::Ready(r) => *r,
            StartAnswer::Failed(kind) => return Err(kind),
            _ => return Err(ErrorKind::Decoding("the server names no source".into())),
        };
        if self.locked(|s| s.without_next) {
            ready.next = None;
        }
        let display = play_display(
            &ready.item,
            ready.plan.method,
            ready.plan.source.as_ref(),
            ready.next.as_ref(),
            Some(&self.addresses),
            self.host.locale.clone(),
        );
        Ok((ready, display))
    }

    /// Makes `ready` the open title (`_playback = w`), tracks and subtitle files new.
    pub(crate) fn install(&self, ready: ReadyStart, display: PlayDisplay) {
        self.locked(|s| {
            s.files = ready.subtitle_files.clone();
            s.chapters = ChapterBar::usable(&ready.chapters);
            s.chosen = Chosen::default();
            s.live = crate::legacy_playback_run::Live::new();
            s.display = Some(display);
            s.ready = Some(ready);
        });
    }

    /// `Kern.playbackOpen`: the plan of a title, as the old `PlayPlanResponse`.
    pub async fn open(&self, id: &str, source_id: &str) -> Result<String, ErrorKind> {
        let (ready, display) = self.fetch(id, source_id).await?;
        let text = self.plan_json(&ready, &display)?;
        self.run.reset_switch();
        self.install(ready, display);
        Ok(text)
    }

    /// `Kern.playbackFromTheSlab`: a stored file plays **before any server**, so no timeout waits on a plane. `entries` is the
    /// download's list entry (JSON), `path` the file, `image` the stored picture for the media controls (empty: none). Sections
    /// and the next episode are there as far as they are known without a server; `look_up` brings the rest.
    pub fn open_slab(&self, entries: &str, path: &str, image: &str) -> Result<String, ErrorKind> {
        let p: swiftly_downloads::DownloadItem =
            serde_json::from_str(entries).map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        let list: Vec<swiftly_downloads::DownloadItem> =
            self.locked(|s| serde_json::from_str(&s.downloads).unwrap_or_default());
        let next = swiftly_downloads::DownloadRules::episode_post(&p.id, &list)
            .map(swiftly_downloads::DownloadItem::as_item);
        let item = p.as_item();
        let plan = swiftly_playback::playback_plan::PlaybackPlan::from_slab(
            &file_url(path),
            p.container.as_deref(),
            p.source.as_deref(),
            p.video_codec.as_deref(),
        );
        let ready = ReadyStart {
            track_title: track_rule::title_key(item.series_id.as_deref(), &item.id, None),
            plan,
            item,
            start_at: 0.0,
            source: None,
            streams: crate::subtitle_sidecar::streams(&std::path::PathBuf::from(format!(
                "{path}.untertitel"
            ))),
            audio: None,
            subtitle: -1,
            subtitle_files: slab_subtitle_files(path),
            sections: p.sections.clone().unwrap_or_default(),
            chapters: Vec::new(),
            trickplay: None,
            server: String::new(),
            next,
            display: PlayDisplay::default(),
        };
        let mut display = self.display_of(&ready);
        if !image.is_empty() {
            display.image = Some(image.to_owned());
        }
        let text = self.plan_json(&ready, &display)?;
        self.run.reset_switch();
        self.install(ready, display);
        Ok(text)
    }

    fn display_of(&self, ready: &ReadyStart) -> PlayDisplay {
        play_display(
            &ready.item,
            ready.plan.method,
            ready.source.as_ref(),
            ready.next.as_ref(),
            Some(&self.addresses),
            self.host.locale.clone(),
        )
    }

    /// `Kern.playbackLookUp`: next episode and sections of a title that opened from disk, from the server. Answer: the new plan
    /// (as `open`), empty when nothing changed, the title is not a stored file, or another title opened meanwhile.
    pub async fn look_up(&self) -> String {
        let (item, key, downloads, without_network, no_next, stored) = self
            .locked(|s| {
                let r = s
                    .ready
                    .as_ref()
                    .filter(|r| r.plan.url.starts_with("file:"))?;
                let list: Vec<swiftly_downloads::DownloadItem> =
                    serde_json::from_str(&s.downloads).unwrap_or_default();
                let stored = list
                    .iter()
                    .find(|d| d.id == r.item.id)
                    .and_then(|d| d.sections.clone());
                Some((
                    r.item.clone(),
                    r.item.id.clone(),
                    list,
                    s.without_network,
                    s.without_next,
                    stored,
                ))
            })
            .map_or(
                (None, String::new(), Vec::new(), false, false, None),
                |(a, b, c, d, e, f)| (Some(a), b, c, d, e, f),
            );
        let Some(item) = item else {
            return String::new();
        };
        let next = if no_next || item.kind() != swiftly_model::ItemKind::Episode {
            None
        } else {
            let rule = NextSource::Rule {
                downloads,
                without_network,
            };
            crate::player_start::play_next(
                Arc::clone(&self.transport),
                &self.host,
                &self.account,
                &item,
                &rule,
            )
            .await
            .ok()
            .flatten()
        };
        let sections = swiftly_downloads::DownloadRules::sections(stored, || async {
            crate::player_start::play_sections(
                Arc::clone(&self.transport),
                &self.host,
                &self.account,
                &key,
            )
            .await
            .unwrap_or_default()
        })
        .await;
        let changed = self.locked(|s| {
            let Some(r) = s.ready.as_mut().filter(|r| r.item.id == key) else {
                return false;
            };
            let mut changed = false;
            if no_next || r.item.kind() != swiftly_model::ItemKind::Episode {
            } else if r.next.as_ref().map(|n| &n.id) != next.as_ref().map(|n| &n.id) {
                r.next = next;
                changed = true;
            }
            if r.sections != sections {
                r.sections = sections;
                changed = true;
            }
            changed
        });
        if !changed {
            return String::new();
        }
        let Some((ready, old)) = self.locked(|s| s.ready.clone().zip(s.display.clone())) else {
            return String::new();
        };
        let mut display = self.display_of(&ready);
        display.image = old.image;
        let text = self.plan_json(&ready, &display).unwrap_or_default();
        self.locked(|s| s.display = Some(display));
        text
    }

    pub(crate) fn plan_json(
        &self,
        ready: &ReadyStart,
        d: &PlayDisplay,
    ) -> Result<String, ErrorKind> {
        let item = &ready.item;
        json(&PlanOut {
            url: ready.plan.url.clone(),
            lossless: ready.plan.is_lossless(),
            method: ready.plan.method.raw_value().to_owned(),
            title: item.name.clone(),
            subtitle: d.context_line.clone(),
            next: ready.next.is_some(),
            file_row: d.file_row.clone(),
            series: d.series.clone(),
            abbreviation: d.abbreviation.clone(),
            image: d.image.clone(),
            item_id: item.id.clone(),
            episode: d.episode,
            series_id: item.series_id.clone(),
            season_id: d.season_id.clone(),
            header_line: d.header_line.clone(),
            season_number: d.season_number,
            episode_number: d.episode_number,
            secondary_line: d.secondary_line.clone(),
            marks: ready
                .sections
                .iter()
                .flat_map(|s| [s.from, s.until])
                .collect(),
            software_decoder: ready.plan.software_decoder(),
            next_episode: d.next.as_ref().map(|n| NextOut {
                id: n.id.clone(),
                name: n.name.clone(),
                abbreviation: n.abbreviation.clone(),
                image: n.image.clone(),
            }),
            card_image: d.card_image.clone(),
            dolby_vision: d.dolby_vision,
            audio_codec: d.audio_codec.clone(),
        })
    }

    fn source_streams(s: &State) -> Vec<MediaStream> {
        let from_plan = s
            .ready
            .as_ref()
            .and_then(|r| r.plan.source.as_ref())
            .and_then(|m| m.media_streams.clone());
        // A stored file has no plan from the server: its downloaded subtitle files bring their own stream rows.
        from_plan
            .or_else(|| s.ready.as_ref().map(|r| r.streams.clone()))
            .unwrap_or_default()
    }

    /// `Kern.subtitleFiles`: `[{"index","adresse"}]`, plus `"format"` (`srt`/`ass`/`vtt`) where the address does not name
    /// the format itself (Plex: `/library/streams/<id>`), so the host can tell its engine what the file is.
    pub fn subtitle_files(&self) -> String {
        let rows: Vec<_> = self.locked(|s| {
            let streams = Self::source_streams(s);
            s.files
                .iter()
                .map(|f| {
                    let codec = streams
                        .iter()
                        .find(|m| m.index == Some(f.index))
                        .and_then(|m| m.codec.as_deref());
                    let mut row = json!({"index": f.index, "adresse": f.address});
                    if let Some(format) = subtitle_format_hint(&f.address, codec) {
                        row["format"] = json!(format);
                    }
                    row
                })
                .collect()
        });
        serde_json::Value::Array(rows).to_string()
    }

    /// `Kern.subtitleAttributeSet`.
    pub fn subtitle_attribute_set(&self, index: i64, attribute: &str) {
        self.locked(|s| {
            if let Some(f) = s.files.iter_mut().find(|f| f.index == index) {
                f.attribute = Some(attribute.to_owned());
            }
        });
    }

    fn title_key(ready: &ReadyStart) -> String {
        track_rule::title_key(ready.item.series_id.as_deref(), &ready.item.id, None)
    }

    /// `Kern.tracksSelect`: `{"ton"?,"untertitel"}`, the VLC ids; `ton` is left out to keep the file's track.
    #[allow(clippy::too_many_arguments)]
    pub fn tracks_select(
        &self,
        audio: &str,
        subtitle: &str,
        audio_now: i64,
        audio_wish: &str,
        subtitle_preference: &str,
        automatic: bool,
        audio_memory: &str,
        subtitle_memory: &str,
    ) -> String {
        let audio_tracks = tracks(audio);
        let sub_tracks = tracks(subtitle);
        self.locked(|s| {
            let Some(ready) = s.ready.as_ref() else { return "{}".to_owned() };
            let source = ready.plan.source.as_ref();
            let streams = Self::source_streams(s);
            let ap: Vec<PlayerTrack> = audio_tracks.iter().map(TrackInput::track).collect();
            let sp: Vec<PlayerTrack> = sub_tracks.iter().map(TrackInput::track).collect();
            let z = TrackMapping::compose(&ap, &sp, &streams, &s.files);
            let title = Self::title_key(ready);
            let audio_all = memory(audio_memory);
            let remembered_audio = track_rule::read_audio(&audio_all, &title);
            let ordered = s.ordered.as_ref().filter(|(item, _)| *item == ready.item.id).map(|(_, t)| *t);
            let mut audio_index = track_rule::audio(
                &streams,
                remembered_audio.as_ref(),
                audio_wish,
                source.and_then(|m| m.default_audio_stream_index),
                ordered.and_then(|o| o.audio),
            );
            let mut audio_id: Option<i64> = None;
            if let Some(position) = audio_index.and_then(|i| z.audio_position(i)) {
                audio_id = Some(audio_tracks[position].id);
            } else {
                if !audio_wish.is_empty()
                    && let Some(hit) = audio_tracks.iter().find(|t| swiftly_rules::language::fits(&t.name, audio_wish))
                {
                    audio_id = Some(hit.id);
                }
                let ongoing = audio_id.unwrap_or(audio_now);
                audio_index = audio_tracks.iter().position(|t| t.id == ongoing).and_then(|p| z.audio.get(p).copied().flatten());
            }
            let choice = track_rule::subtitle(
                &streams,
                &SubtitleInput {
                    remembered: track_rule::read_choice(&memory(subtitle_memory), &title),
                    server_default: source.and_then(|m| m.default_subtitle_stream_index),
                    automatic,
                    audio_index,
                    audio_wish,
                    preferred_language: subtitle_preference,
                    ordered: ordered.and_then(|o| o.subtitle),
                },
            );
            let mut ut_id = -1;
            let mut opened = None;
            let mut ut_index = -1;
            if let Subtitle::Feed(index) = choice {
                ut_index = index;
                if let Some(position) = z.subtitle_position(index) {
                    ut_id = sub_tracks[position].id;
                } else if s.files.iter().any(|f| f.index == index) {
                    opened = Some(index);
                }
            }
            if opened.is_some() {
                self.run.row(format!("Spuren: Untertiteldatei {} noch nicht da, wartet", opened.unwrap_or(-1)));
            } else if let Subtitle::Feed(index) = choice
                && ut_id == -1
            {
                self.run.row(format!("Spuren: Untertitel {index} nicht zuzuordnen, bleibt aus"));
            }
            let optional = |list: &[Option<i64>]| {
                format!("[{}]", list.iter().map(|o| o.map_or("nil".to_owned(), |n| format!("Optional({n})"))).collect::<Vec<_>>().join(", "))
            };
            let dash = |v: Option<i64>| v.map_or("\u{2014}".to_owned(), |n| n.to_string());
            self.run.row(format!(
                "Spuren: Ton {} \u{b7} Untertitel {} \u{b7} Vorgaben {}/{} \u{b7} Zuordnung Ton {} Untertitel {} \u{b7} Kennungen [{}]",
                audio_index.map_or("Datei".to_owned(), |n| n.to_string()),
                match choice { Subtitle::Off => "off".to_owned(), Subtitle::Feed(i) => format!("feed({i})") },
                dash(source.and_then(|m| m.default_audio_stream_index)),
                dash(source.and_then(|m| m.default_subtitle_stream_index)),
                optional(&z.audio),
                optional(&z.subtitle),
                sub_tracks.iter().map(|t| format!("\"{}\"", t.identifier)).collect::<Vec<_>>().join(", ")
            ));
            s.chosen = Chosen { audio: audio_index, subtitle: Some(ut_index), opened };
            let mut out = serde_json::Map::new();
            if let Some(id) = audio_id {
                out.insert("ton".into(), json!(id));
            }
            out.insert("untertitel".into(), json!(ut_id));
            serde_json::Value::Object(out).to_string()
        })
    }

    /// `Kern.openSubtitle`: the engine reports a new subtitle track, maybe the chosen file; its id or -1.
    pub fn open_subtitle(&self, subtitle: &str) -> i64 {
        let sub_tracks = tracks(subtitle);
        self.locked(|s| {
            let Some(index) = s.chosen.opened else {
                return -1;
            };
            let sp: Vec<PlayerTrack> = sub_tracks.iter().map(TrackInput::track).collect();
            let z = TrackMapping::compose(&[], &sp, &Self::source_streams(s), &s.files);
            let Some(position) = z.subtitle_position(index) else {
                return -1;
            };
            s.chosen.opened = None;
            s.chosen.subtitle = Some(index);
            self.run
                .row(format!("Spuren: Untertiteldatei {index} nachgereicht"));
            sub_tracks[position].id
        })
    }

    /// `Kern.audioFromHand`: the new memory after a hand choice (also for the whole series).
    pub fn audio_from_hand(&self, audio: &str, id: i64, memory_json: &str) -> String {
        let audio_tracks = tracks(audio);
        self.locked(|s| {
            let Some(ready) = s.ready.as_ref() else {
                return memory_json.to_owned();
            };
            let Some(position) = audio_tracks.iter().position(|t| t.id == id) else {
                return memory_json.to_owned();
            };
            let streams = Self::source_streams(s);
            let ap: Vec<PlayerTrack> = audio_tracks.iter().map(TrackInput::track).collect();
            let z = TrackMapping::compose(&ap, &[], &streams, &[]);
            let index = z.audio[position];
            let imprint = index
                .and_then(|i| stream_of(&streams, "Audio", i))
                .map(|f| TrackImprint::from_feed(f, &streams, Some(&audio_tracks[position].name)))
                .unwrap_or_else(|| TrackImprint::from_track(&ap[position]));
            s.chosen.audio = index;
            let mut all = memory(memory_json);
            track_rule::write_choice(&mut all, &Self::title_key(ready), &Choice::Track(imprint));
            serde_json::to_string(&all).unwrap_or_default()
        })
    }

    /// `Kern.subtitleFromHand`: `id` -1 means off.
    pub fn subtitle_from_hand(&self, subtitle: &str, id: i64, memory_json: &str) -> String {
        let sub_tracks = tracks(subtitle);
        self.locked(|s| {
            let Some(ready) = s.ready.as_ref() else {
                return memory_json.to_owned();
            };
            let title = Self::title_key(ready);
            let mut all = memory(memory_json);
            let position = (id >= 0)
                .then(|| sub_tracks.iter().position(|t| t.id == id))
                .flatten();
            let Some(position) = position else {
                s.chosen.opened = None;
                s.chosen.subtitle = Some(-1);
                track_rule::write_choice(&mut all, &title, &Choice::Off);
                return serde_json::to_string(&all).unwrap_or_default();
            };
            let streams = Self::source_streams(s);
            let sp: Vec<PlayerTrack> = sub_tracks.iter().map(TrackInput::track).collect();
            let z = TrackMapping::compose(&[], &sp, &streams, &s.files);
            let index = z.subtitle[position];
            let imprint = index
                .and_then(|i| stream_of(&streams, "Subtitle", i))
                .map(|f| TrackImprint::from_feed(f, &streams, Some(&sub_tracks[position].name)))
                .unwrap_or_else(|| TrackImprint::from_track(&sp[position]));
            s.chosen.opened = None;
            s.chosen.subtitle = index;
            track_rule::write_choice(&mut all, &title, &Choice::Track(imprint));
            serde_json::to_string(&all).unwrap_or_default()
        })
    }

    /// `Kern.trackNames`: readable names for the two lists, `{"ton":[..],"untertitel":[..]}`.
    pub fn track_names(&self, audio: &str, subtitle: &str) -> String {
        let audio_tracks = tracks(audio);
        let sub_tracks = tracks(subtitle);
        self.locked(|s| {
            let streams = Self::source_streams(s);
            let files: &[SubtitleFile] = &s.files;
            let ap: Vec<PlayerTrack> = audio_tracks.iter().map(TrackInput::track).collect();
            let sp: Vec<PlayerTrack> = sub_tracks.iter().map(TrackInput::track).collect();
            let z = TrackMapping::compose(&ap, &sp, &streams, files);
            let original = s.ready.as_ref().and_then(|r| r.item.original_language.clone());
            let words = &self.words;
            let audio_names: Vec<_> = audio_tracks
                .iter()
                .enumerate()
                .map(|(position, input)| {
                    let track = &ap[position];
                    let feed = z.audio[position].and_then(|i| stream_of(&streams, "Audio", i));
                    let own = track_label::audio(track.language.as_deref(), track.codec.as_deref(), track.channels, words);
                    let from_server = feed.and_then(|f| {
                        track_label::audio(f.language.as_deref(), codec_name_value(f.codec.as_deref()).as_deref(), f.channels, words)
                    });
                    let text = if track.codec.is_none() { from_server.or(own) } else { own.or(from_server) };
                    let name = text.unwrap_or_else(|| input.name.clone());
                    let labelled = original_audio::label(
                        &name,
                        track.language.as_deref().or(feed.and_then(|f| f.language.as_deref())),
                        feed,
                        original.as_deref(),
                        &words.original_suffix(),
                    );
                    json!({"id": input.id, "text": labelled, "erzwungen": false, "datei": false, "hoergeschaedigt": false})
                })
                .collect();
            let ut_streams: Vec<Option<&MediaStream>> =
                (0..sp.len()).map(|p| z.subtitle[p].and_then(|i| stream_of(&streams, "Subtitle", i))).collect();
            let sub_names: Vec<_> = sub_tracks
                .iter()
                .enumerate()
                .map(|(position, input)| match ut_streams[position] {
                    None => {
                        let language = sp[position].language.as_deref().and_then(|l| track_label::language(Some(l), words));
                        json!({"id": input.id, "text": language.unwrap_or_else(|| input.name.clone()),
                               "erzwungen": false, "datei": sp[position].addition_id().is_some(), "hoergeschaedigt": false})
                    }
                    Some(feed) => {
                        let language = track_label::language(feed.language.as_deref(), words).unwrap_or_else(|| input.name.clone());
                        let own_name = track_label::language(feed.language.as_deref(), words);
                        let double = ut_streams
                            .iter()
                            .filter(|o| o.and_then(|f| track_label::language(f.language.as_deref(), words)) == own_name)
                            .count()
                            > 1;
                        let mut parts = vec![language];
                        if double || feed.is_external == Some(true) {
                            parts.extend(codec_name_value(feed.codec.as_deref()));
                        }
                        json!({"id": input.id, "text": parts.join(" · "), "erzwungen": feed.is_forced == Some(true),
                               "datei": feed.is_external == Some(true), "hoergeschaedigt": feed.is_hearing_impaired == Some(true)})
                    }
                })
                .collect();
            let hidden = TrackMapping::replaced_positions(&sp, &streams, files);
            let shown: Vec<_> = sub_names.into_iter().enumerate().filter(|(i, _)| !hidden.contains(i)).map(|(_, v)| v).collect();
            json!({"ton": audio_names, "untertitel": shown}).to_string()
        })
    }

    /// `Kern.chapterLoad`: how many chapters the open title has.
    pub fn chapter_load(&self) -> i64 {
        self.locked(|s| s.chapters.len() as i64)
    }

    fn pieces(
        &self,
        duration: f64,
        width: f64,
        min_width: f64,
    ) -> Vec<swiftly_rules::chapter::Piece> {
        let chapters = self.locked(|s| s.chapters.clone());
        ChapterBar::pieces(
            &ChapterBar::limits(&chapters, duration),
            duration,
            width,
            min_width,
        )
    }

    /// `Kern.chapterBar`: `{"stuecke":[[from,until,x,width]],"fang":[seconds]}`.
    pub fn chapter_bar(&self, duration: f64, width: f64, min_width: f64, gap: f64) -> String {
        let pieces = self.pieces(duration, width, min_width);
        let rows: Vec<Vec<f64>> = pieces
            .iter()
            .map(|p| {
                let (x, w) = p.frame_rect(width, gap);
                vec![p.from, p.until, x, w]
            })
            .collect();
        json!({"stuecke": rows, "fang": ChapterBar::snap_cuts(&pieces, duration, width)})
            .to_string()
    }

    /// `Kern.chapterName`: empty without chapters.
    pub fn chapter_name(&self, at: f64) -> String {
        self.locked(|s| {
            ChapterBar::chapter_at(at, &s.chapters)
                .map(|c| c.name.clone())
                .unwrap_or_default()
        })
    }

    /// `Kern.chapterPiece`: the piece of the bar containing a fraction, -1 without one.
    pub fn chapter_piece(&self, share: f64, duration: f64, width: f64, min_width: f64) -> i64 {
        let pieces = self.pieces(duration, width, min_width);
        ChapterBar::piece_at(share, &pieces).map_or(-1, |p| p as i64)
    }

    /// `Kern.trickplayDetail`: `{"breite","hoehe","kachelnBreit","kachelnHoch","anzahl","intervall"}`, `{}` without.
    pub fn trickplay_detail(&self) -> String {
        self.locked(|s| match s.ready.as_ref().and_then(|r| r.trickplay) {
            Some(t) => json!({"breite": t.width, "hoehe": t.height, "kachelnBreit": t.tiles_wide, "kachelnHoch": t.tiles_up,
                              "anzahl": t.count, "intervall": t.interval})
            .to_string(),
            None => "{}".to_owned(),
        })
    }

    /// `Kern.trickplayAddress`: the address of a sheet, empty without a title.
    pub fn trickplay_address(&self, width: i64, sheet: i64) -> String {
        let (item, source) = self.locked(|s| {
            s.ready
                .as_ref()
                .map(|r| (r.item.id.clone(), r.plan.media_source_id.clone()))
                .unzip()
        });
        let Some(item): Option<String> = item else {
            return String::new();
        };
        let Some(client) = self.client.as_ref() else {
            return String::new();
        };
        client
            .trickplay_url(&item, source.flatten().as_deref(), width, sheet)
            .map(|u| u.to_string())
            .unwrap_or_default()
    }

    /// `Kern.firstFrameVideoCodec`: the server's codec of the video track, empty without one.
    pub fn first_frame_video_codec(&self) -> String {
        self.locked(|s| {
            let source: Option<&MediaSource> =
                s.ready.as_ref().and_then(|r| r.plan.source.as_ref());
            source
                .and_then(MediaSource::video_track)
                .map(|v| v.codec.clone().unwrap_or_else(|| "?".to_owned()))
                .unwrap_or_default()
        })
    }

    #[allow(dead_code)]
    fn picture(&self, id: &str, mark: Option<&str>) -> Option<String> {
        self.addresses
            .construct(id, Art::Poster, mark, ImageMetric::AtMostHigh(600))
            .map(|u| u.to_string())
    }

    /// `Kern.techFixed`: the fixed lines of the tech badge, `[{"text","art","schluessel"?,"kopf"}]`. The reason line of a
    /// transcode is not in yet (the plan's reason texts are not in the core).
    pub fn tech_fixed(&self, measure: bool) -> String {
        use swiftly_playback::tech_details as tech;
        let words = &self.words;
        let localizer = crate::tile::Words::new(self.host.locale.clone());
        let sep = crate::decimal_separator(self.host.locale.language());
        self.locked(|s| {
            s.counter = None;
            let Some(ready) = s.ready.as_ref() else { return "[]".to_owned() };
            let plan = &ready.plan;
            let mut rows = vec![json!({
                "text": tech::delivery(plan.method, &localizer),
                "art": if tech::weight(plan.method) == tech::Weight::Good { "gut" } else { "warnend" },
                "kopf": true,
            })];
            let join = |values: Vec<Option<String>>| {
                let present: Vec<String> = values.into_iter().flatten().collect();
                (!present.is_empty()).then(|| present.join(" \u{b7} "))
            };
            let row = |text: String, key: &str| json!({"text": text, "art": "", "schluessel": key, "kopf": false});
            if let Some(q) = plan.source.as_ref() {
                let streams = q.media_streams.clone().unwrap_or_default();
                let of = |kind: &str| streams.iter().find(|x| x.type_.as_deref() == Some(kind));
                let (video, audio, subtitle) = (of("Video"), of("Audio"), of("Subtitle"));
                if let Some(image) = join(vec![
                    codec_name_value(video.and_then(|v| v.codec.as_deref())),
                    tech::image_row(video.and_then(|v| v.width), video.and_then(|v| v.height), None, None),
                    tech::dynamics(video),
                    if measure { tech::frame_rate(video.and_then(MediaStream::frame_rate)).map(|f| format!("{f} fps")) } else { None },
                ]) {
                    rows.push(row(image, "Bild"));
                }
                let audio_codec = codec_name_value(audio.and_then(|a| a.codec.as_deref()));
                if audio_codec.is_some()
                    && let Some(t) = join(vec![
                        audio_codec,
                        track_label::channel_word(audio.and_then(|a| a.channels)),
                        track_label::language(audio.and_then(|a| a.language.as_deref()), words),
                    ])
                {
                    rows.push(row(t, "Ton"));
                }
                let sub_codec = codec_name_value(subtitle.and_then(|a| a.codec.as_deref()));
                if sub_codec.is_some()
                    && let Some(u) = join(vec![sub_codec, track_label::language(subtitle.and_then(|a| a.language.as_deref()), words)])
                {
                    rows.push(row(u, "Untertitel"));
                }
                if let Some(container) = q.container.as_ref() {
                    let mut text = match q.size {
                        Some(bytes) => format!("{} \u{b7} {}", container.to_uppercase(), crate::downloads_vm::size_text(bytes, sep)),
                        None => container.to_uppercase(),
                    };
                    let duration = ready.item.runtime_seconds();
                    if let (Some(size), Some(d)) = (q.size.filter(|b| *b > 0), duration.filter(|d| *d > 1.0))
                        && let Some(rate) = tech::bitrate(Some(size as f64 * 8.0 / d))
                    {
                        text.push_str(&format!(" \u{b7} \u{d8} {rate}"));
                    }
                    rows.push(row(text, "Datei"));
                }
            }
            serde_json::Value::Array(rows).to_string()
        })
    }

    /// `Kern.techTick`: a measurement point from VLC's counters (negative values count as 0) against the previous one;
    /// `{}` when a field looks like garbage. Keys as the old `TechResponse` (`eingang`, `zeigt`, `vorratKiB` ...), unset ones left out.
    #[allow(clippy::too_many_arguments)]
    pub fn tech_tick(&self, values: [i64; 10], spot: f64, running: bool) -> String {
        use swiftly_rules::counter::{Counter, RawValues};
        let u = |x: i64| x.max(0) as u64;
        let raw = RawValues {
            has_read: u(values[0]),
            unpacked: u(values[1]),
            shown: u(values[2]),
            discarded: u(values[3]),
            too_late: 0,
            video_blocks: u(values[4]),
            audio_blocks: u(values[5]),
            audio_play: u(values[6]),
            audio_lost: u(values[7]),
            damaged: u(values[8]),
            jumps: u(values[9]),
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let (should, per_second) = self.tech_source();
        self.locked(|s| {
            let Some(c) = Counter::new(raw, spot, running, s.counter.as_ref(), now) else {
                return "{}".to_owned();
            };
            s.counter = Some(c);
            let mut o = serde_json::Map::new();
            let mut put = |k: &str, v: Option<serde_json::Value>| {
                if let Some(v) = v {
                    o.insert(k.to_owned(), v);
                }
            };
            let num = |x: f64| serde_json::Number::from_f64(x).map(serde_json::Value::Number);
            put(
                "eingang",
                swiftly_playback::tech_details::bitrate(c.input).map(Into::into),
            );
            put(
                "demuxer",
                swiftly_playback::tech_details::bitrate(c.demuxer).map(Into::into),
            );
            put("zeigt", c.shows_per_second.and_then(num));
            put("gezeigt", Some(raw.shown.into()));
            put("soll", (should > 0.0).then_some(should).and_then(num));
            put("lauf", c.run_share.and_then(num));
            put("dekodiert", c.decoded_per_second.and_then(num));
            put(
                "vorratSekunden",
                (per_second > 0.0)
                    .then(|| c.reserve_seconds(per_second))
                    .flatten()
                    .and_then(num),
            );
            put("vorratKiB", Some((c.pre_advice_bytes() / 1024).into()));
            put("verworfen", Some(raw.discarded.into()));
            put("tonVerloren", Some(raw.audio_lost.into()));
            put("beschaedigt", Some(raw.damaged.into()));
            put("spruenge", Some(raw.jumps.into()));
            serde_json::Value::Object(o).to_string()
        })
    }

    /// What the tech badge's measurement needs from the plan: the file's frame rate and its average bytes per second.
    pub fn tech_source(&self) -> (f64, f64) {
        self.locked(|s| {
            let Some(r) = s.ready.as_ref() else {
                return (-1.0, -1.0);
            };
            let q = r.plan.source.as_ref();
            let should = q
                .and_then(MediaSource::video_track)
                .and_then(MediaStream::frame_rate)
                .unwrap_or(-1.0);
            let per_second = match (q.and_then(|m| m.size), r.item.runtime_seconds()) {
                (Some(size), Some(d)) if d > 0.0 => size as f64 / d,
                _ => -1.0,
            };
            (should, per_second)
        })
    }
}

/// `URL(fileURLWithPath:).absoluteString`: the path as a `file://` address, percent-encoded as far as an address needs.
fn file_url(path: &str) -> String {
    let mut out = String::from("file://");
    for b in path.bytes() {
        match b {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'.'
            | b'_'
            | b'~'
            | b'/'
            | b':'
            | b'@'
            | b'!'
            | b'$'
            | b'&'
            | b'\''
            | b'('
            | b')'
            | b'*'
            | b'+'
            | b','
            | b';'
            | b'=' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod slab_tests {
    #[test]
    fn file_url_encodes_like_the_old_url() {
        assert_eq!(
            super::file_url("/data/a b/x.mkv"),
            "file:///data/a%20b/x.mkv"
        );
    }
}

/// The subtitle files that came with a download: `<file>.untertitel/<index>.<ending>` (a folder of its own, so the player
/// does not load them twice). Sorted by index; empty when there is none.
pub(crate) fn slab_subtitle_files(path: &str) -> Vec<SubtitleFile> {
    let folder = std::path::PathBuf::from(format!("{path}.untertitel"));
    let mut found: Vec<SubtitleFile> = std::fs::read_dir(&folder)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let index: i64 = name.split('.').next()?.parse().ok()?;
            Some(SubtitleFile {
                index,
                address: file_url(&folder.join(&name).to_string_lossy()),
                attribute: None,
            })
        })
        .collect();
    found.sort_by_key(|f| f.index);
    found
}

#[cfg(test)]
mod slab_subtitle_tests {
    #[test]
    fn a_stored_file_hands_its_downloaded_subtitles_to_the_player() {
        let base = std::env::temp_dir().join(format!("slab-subs-{}", std::process::id()));
        let folder = base.join("u1-x.mp4.untertitel");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("3.ass"), "a").unwrap();
        std::fs::write(folder.join("2.srt"), "a").unwrap();
        let files = super::slab_subtitle_files(&base.join("u1-x.mp4").to_string_lossy());
        std::fs::remove_dir_all(&base).ok();
        assert_eq!(
            files.iter().map(|f| f.index).collect::<Vec<_>>(),
            vec![2, 3]
        );
        assert!(files[0].address.starts_with("file://") && files[0].address.ends_with("/2.srt"));
        assert!(super::slab_subtitle_files("/nonexistent/none.mp4").is_empty());
    }
}

/// The subtitle format of a file whose address has no ending (`None` when the address names it already).
fn subtitle_format_hint(address: &str, codec: Option<&str>) -> Option<&'static str> {
    let path = address.split(['?', '#']).next().unwrap_or("");
    if path
        .rsplit('/')
        .next()
        .is_some_and(|name| name.contains('.'))
    {
        return None;
    }
    Some(match codec.map(str::to_lowercase).as_deref() {
        Some("ass" | "ssa") => "ass",
        Some("vtt" | "webvtt") => "vtt",
        _ => "srt",
    })
}

#[cfg(test)]
mod subtitle_format_tests {
    use super::subtitle_format_hint;

    #[test]
    fn a_plex_file_without_an_ending_gets_its_format_from_the_codec() {
        assert_eq!(
            subtitle_format_hint("http://h/library/streams/42?X-Plex-Token=t", Some("ass")),
            Some("ass")
        );
        assert_eq!(
            subtitle_format_hint("http://h/library/streams/42?X-Plex-Token=t", Some("srt")),
            Some("srt")
        );
        assert_eq!(
            subtitle_format_hint("http://h/Videos/1/Subtitles/2/0/Stream.vtt", Some("vtt")),
            None
        );
    }
}
