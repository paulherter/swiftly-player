//! `DownloadItem` and `PathPart` (Downloads.swift:40-349, DownloadAudio.swift `withAudio`).
//!
//! The serde field names are the Swift `CodingKeys` (German), exactly, so an existing
//! `liste.json` reads back. Dates are Swift `Date`s encoded by the default `JSONEncoder`: seconds
//! since 2001-01-01 as a number. In memory the fields are Unix seconds (`f64`).

use serde::{Deserialize, Serialize};
use swiftly_model::{Item, MediaSource, UserItemData};
use swiftly_playback::sections::Segment;
use swiftly_rules::download_audio::{
    self as audio, AudioStream, AudioTrackRules, DownloadAudioChoice,
};
use swiftly_rules::download_quality::DownloadQuality;

use crate::rules::{POINT_OFF, WATCHED_OFF};
use crate::state::DownloadState;

/// Seconds between 1970-01-01 and Swift's reference date 2001-01-01.
pub const REFERENCE_DATE_OFFSET: f64 = 978_307_200.0;

/// Ticks (100 ns) per second.
const TICKS_PER_SECOND: f64 = 10_000_000.0;

/// Swift `Date` <-> JSON number (seconds since 2001) for `f64` Unix seconds.
mod reference_date {
    use super::REFERENCE_DATE_OFFSET;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &f64, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_f64(value - REFERENCE_DATE_OFFSET)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
        Ok(f64::deserialize(d)? + REFERENCE_DATE_OFFSET)
    }

    pub mod option {
        use super::*;

        pub fn serialize<S: Serializer>(value: &Option<f64>, s: S) -> Result<S::Ok, S::Error> {
            match value {
                Some(v) => s.serialize_f64(v - REFERENCE_DATE_OFFSET),
                None => s.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
            Ok(Option::<f64>::deserialize(d)?.map(|v| v + REFERENCE_DATE_OFFSET))
        }
    }
}

/// `DownloadQuality` as its Swift raw value (`original`, `hd1080`, ...).
mod quality_raw {
    use serde::de::Error as _;
    use serde::{Deserialize, Deserializer, Serializer};
    use swiftly_rules::download_quality::DownloadQuality;

    pub fn serialize<S: Serializer>(v: &Option<DownloadQuality>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            Some(q) => s.serialize_str(q.raw_value()),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        d: D,
    ) -> Result<Option<DownloadQuality>, D::Error> {
        match Option::<String>::deserialize(d)? {
            None => Ok(None),
            Some(raw) => DownloadQuality::from_raw_value(&raw)
                .map(Some)
                .ok_or_else(|| D::Error::custom(format!("unknown quality {raw:?}"))),
        }
    }
}

/// Film or episode (`DownloadItem.Art`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Art {
    /// A movie (`film`).
    #[serde(rename = "film")]
    Film,
    /// An episode (`folge`).
    #[serde(rename = "folge")]
    Episode,
}

/// A title on the device: downloaded, downloading or waiting.
///
/// `account` is not optional decoration: storage hangs on the user id, not on the item id alone.
/// Two accounts on one server carry the same ids.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DownloadItem {
    /// The server's item id.
    pub id: String,
    /// The user id this download belongs to (`konto`).
    #[serde(rename = "konto")]
    pub account: String,
    /// Film or episode (`art`).
    pub art: Art,
    /// Title (`titel`).
    #[serde(rename = "titel")]
    pub title: String,
    /// For an episode the series name (`serie`).
    #[serde(rename = "serie", default, skip_serializing_if = "Option::is_none")]
    pub series: Option<String>,
    /// Series id (`serienId`).
    #[serde(rename = "serienId", default, skip_serializing_if = "Option::is_none")]
    pub series_identifier: Option<String>,
    /// Season number (`staffel`).
    #[serde(rename = "staffel", default, skip_serializing_if = "Option::is_none")]
    pub season: Option<i64>,
    /// Episode number (`folge`).
    #[serde(rename = "folge", default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<i64>,
    /// Runtime in ticks (`laufzeitTicks`).
    #[serde(
        rename = "laufzeitTicks",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub runtime_ticks: Option<i64>,
    /// Container of the file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
    /// `mediaSourceId` (`quelle`).
    #[serde(rename = "quelle", default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    /// What the server states as size; 0 if none. An estimate for a built file until finished.
    pub bytes: i64,
    /// The quality it loads in (`qualitaet`). `None` means original (lists from before 1.0.5).
    #[serde(
        rename = "qualitaet",
        default,
        with = "quality_raw",
        skip_serializing_if = "Option::is_none"
    )]
    pub quality: Option<DownloadQuality>,
    /// How much is already on disk (`geladen`).
    #[serde(rename = "geladen")]
    pub loaded: i64,
    /// Current state (`stand`).
    #[serde(rename = "stand")]
    pub state: DownloadState,
    /// Only set when `state == Error` (`grund`).
    #[serde(rename = "grund", default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Only watched items count as expendable (`gesehen`).
    #[serde(rename = "gesehen")]
    pub watched: bool,
    /// Creation time, Unix seconds (`angelegt`; JSON holds 2001-based seconds).
    #[serde(rename = "angelegt", with = "reference_date")]
    pub created: f64,
    /// Falls to `false` when the server no longer knows the title (`nochAufDemServer`).
    #[serde(rename = "nochAufDemServer")]
    pub still_on_the_server: bool,
    /// Intro, recap, credits taken along (`abschnitte`). `None`: never asked; empty: none.
    #[serde(
        rename = "abschnitte",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub sections: Option<Vec<Segment>>,
    /// The video is on the device but its subtitle files and `info.json` are not written yet
    /// (`untertitelOffen`). The title only counts as finished once this is false.
    #[serde(rename = "untertitelOffen", default, skip_serializing_if = "is_false")]
    pub subtitles_pending: bool,
    /// Where playback last stopped, in ticks (`stelleTicks`).
    #[serde(
        rename = "stelleTicks",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub point_ticks: Option<i64>,
    /// When last played, Unix seconds (`zuletzt`; JSON holds 2001-based seconds).
    #[serde(
        rename = "zuletzt",
        default,
        with = "reference_date::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub recent: Option<f64>,
    /// Codec of the video track of the downloaded file (`bildcodec`).
    #[serde(rename = "bildcodec", default, skip_serializing_if = "Option::is_none")]
    pub video_codec: Option<String>,
    /// The one audio track the file holds, the server's stream index (`tonIndex`).
    #[serde(rename = "tonIndex", default, skip_serializing_if = "Option::is_none")]
    pub audio_index: Option<i64>,
    /// The language the audio track was chosen by (`tonSprache`).
    #[serde(
        rename = "tonSprache",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub audio_language: Option<String>,
    /// The id of the watched episode this one was loaded to follow (`ersetzt`).
    #[serde(rename = "ersetzt", default, skip_serializing_if = "Option::is_none")]
    pub replaces: Option<String>,
    /// Set when the successor could not be looked up yet (`naechsteOffen`).
    #[serde(
        rename = "naechsteOffen",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub next_pending: Option<bool>,
}

impl DownloadItem {
    /// The Swift `init` with its defaults: waiting, nothing loaded, not watched, still on the
    /// server. `created` is a parameter because the core reads no clock.
    pub fn new(
        id: impl Into<String>,
        account: impl Into<String>,
        art: Art,
        title: impl Into<String>,
        bytes: i64,
        created: f64,
    ) -> Self {
        Self {
            id: id.into(),
            account: account.into(),
            art,
            title: title.into(),
            series: None,
            series_identifier: None,
            season: None,
            episode: None,
            runtime_ticks: None,
            container: None,
            source: None,
            bytes,
            quality: None,
            loaded: 0,
            state: DownloadState::Waits,
            reason: None,
            watched: false,
            created,
            still_on_the_server: true,
            sections: None,
            subtitles_pending: false,
            point_ticks: None,
            recent: None,
            video_codec: None,
            audio_index: None,
            audio_language: None,
            replaces: None,
            next_pending: None,
        }
    }

    /// The normalisation the Swift `init` does on every construction: original quality is
    /// stored as `None`, and a converted file has the server's video codec, not the original's.
    pub fn normalized(mut self) -> Self {
        if self.quality == Some(DownloadQuality::Original) {
            self.quality = None;
        }
        if self.quality.is_some() {
            self.video_codec = None;
        }
        self
    }

    /// The second Swift `init`: a title's watch state as the server knows it, passed along when
    /// creating a download so the list shows it without network.
    pub fn with_watch_state(
        mut self,
        watch_state: Option<&UserItemData>,
        video_codec: Option<String>,
    ) -> Self {
        self.watched = watch_state.and_then(|w| w.played).unwrap_or(false);
        self.point_ticks = watch_state
            .and_then(|w| w.playback_position_ticks)
            .filter(|t| *t > 0);
        self.recent = watch_state.and_then(UserItemData::last_play);
        self.video_codec = video_codec;
        self.normalized()
    }

    /// Between 0 and 1. `None` if the server stated no size. An estimate never quite reaches
    /// the end: a streamed file that is not done shows at most 0.99.
    pub fn share(&self) -> Option<f64> {
        if self.bytes <= 0 {
            return None;
        }
        let value = (self.loaded as f64 / self.bytes as f64).clamp(0.0, 1.0);
        Some(if self.streamed() && self.state != DownloadState::Done {
            value.min(0.99)
        } else {
            value
        })
    }

    /// Is the file converted by the server? Then `bytes` is estimated until the end.
    pub fn converted(&self) -> bool {
        self.quality.is_some_and(|q| !q.is_original())
    }

    /// Is the file built by the server while it loads? Converted, or cut down to one audio
    /// track: no length up front, no resuming, subtitles as separate files.
    pub fn streamed(&self) -> bool {
        self.converted() || self.audio_index.is_some()
    }

    /// The chosen quality; `None` counts as original (`guete`).
    pub fn guete(&self) -> DownloadQuality {
        self.quality.unwrap_or(DownloadQuality::Original)
    }

    /// The same item in another quality. Container and size change with it. Called on the item
    /// as the catalog describes it (original size and container).
    pub fn in_quality(&self, q: DownloadQuality) -> Self {
        let container = if q.is_original() && self.audio_index.is_none() {
            self.container.clone()
        } else {
            Some(DownloadQuality::CONTAINER.to_owned())
        };
        Self {
            container,
            bytes: q.estimated_bytes(self.bytes, self.runtime_ticks),
            quality: Some(q),
            ..self.clone()
        }
        .normalized()
    }

    /// The same item with a chosen audio choice, resolved against this file's streams. A choice
    /// that leaves all tracks in returns the item unchanged.
    pub fn with_audio(
        &self,
        rules: &dyn AudioTrackRules,
        choice: &DownloadAudioChoice,
        streams: &[AudioStream],
    ) -> Self {
        let Some(index) = audio::index_for(rules, choice, streams) else {
            return self.clone();
        };
        let language = match choice {
            DownloadAudioChoice::Language(key) => Some(key.clone()),
            _ => audio::language_key_of(rules, index, streams),
        };
        self.with_audio_index(index, language)
    }

    /// The same item, cut down to one audio track.
    pub fn with_audio_index(&self, index: i64, language: Option<String>) -> Self {
        Self {
            container: if self.converted() {
                self.container.clone()
            } else {
                Some(DownloadQuality::CONTAINER.to_owned())
            },
            audio_index: Some(index),
            audio_language: language,
            ..self.clone()
        }
        .normalized()
    }

    /// An `Item` from what is stored here, for playback without network. Explicitly no
    /// substitute for the server once one is there: plot, cast and progress are missing.
    pub fn as_item(&self) -> Item {
        Item {
            id: self.id.clone(),
            name: self.title.clone(),
            type_: Some(
                if self.art == Art::Episode {
                    "Episode"
                } else {
                    "Movie"
                }
                .to_owned(),
            ),
            run_time_ticks: self.runtime_ticks,
            series_name: self.series.clone(),
            index_number: self.episode,
            parent_index_number: self.season,
            series_id: self.series_identifier.clone(),
            ..Item::default()
        }
    }

    /// Where the download list starts playback, in seconds: the remembered position, otherwise
    /// from the start. Watched items start over, like "Watch again" online.
    pub fn resume_from(&self) -> f64 {
        match self.point_ticks {
            Some(t) if !self.watched && t > 0 => t as f64 / TICKS_PER_SECOND,
            _ => 0.0,
        }
    }

    /// Record a playback on this device, with or without network. Same thresholds as the server
    /// (`MinResumePct` 5, `MaxResumePct` 90): below 5 % nothing counts as a position, from 90 %
    /// the title counts as watched and the position is dropped; in between "watched" stays.
    pub fn post_playback(&self, ticks: i64, moment: f64) -> Self {
        let mut p = self.clone();
        p.recent = Some(moment);
        let Some(runtime) = self.runtime_ticks.filter(|r| *r > 0) else {
            p.point_ticks = (ticks > 0).then_some(ticks);
            return p;
        };
        let share = ticks as f64 / runtime as f64;
        if share >= WATCHED_OFF {
            p.watched = true;
            p.point_ticks = None;
        } else if share < POINT_OFF {
            p.point_ticks = None;
        } else {
            p.point_ticks = Some(ticks);
        }
        p
    }

    /// The file name on disk: account and id so two accounts do not collide, plus the
    /// container's extension. All parts pass through [`PathPart`].
    pub fn file_name(&self) -> String {
        let suffix = PathPart::suffix(self.container.as_deref())
            .map(|s| format!(".{s}"))
            .unwrap_or_default();
        format!(
            "{}-{}{}",
            PathPart::safe(&self.account),
            PathPart::safe(&self.id),
            suffix
        )
    }

    /// The name of the image on disk, next to the file.
    pub fn image_name(account: &str, identifier: &str) -> String {
        format!(
            "{}-{}.jpg",
            PathPart::safe(account),
            PathPart::safe(identifier)
        )
    }

    /// The name of the folder of external subtitles for a file: a separate folder, not next to
    /// the file (VLC would load them twice).
    pub fn subtitle_folder_name(&self) -> String {
        format!("{}.untertitel", self.file_name())
    }
}

/// The first media source of an item, as the download rules read it.
pub fn first_source(item: &Item) -> Option<&MediaSource> {
    item.media_sources.as_deref().and_then(<[_]>::first)
}

/// The audio tracks of a source in the form the audio rules read them.
pub fn audio_streams(source: Option<&MediaSource>) -> Vec<AudioStream> {
    source
        .and_then(|s| s.media_streams.as_deref())
        .unwrap_or(&[])
        .iter()
        .map(|m| AudioStream {
            codec: m.codec.clone(),
            kind: m.type_.clone().unwrap_or_default(),
            language: m.language.clone(),
            display_title: m.display_title.clone(),
            channels: m.channels,
            is_default: m.is_default,
            index: m.index,
        })
        .collect()
}

/// The item that follows a watched one (`DownloadRules.followUp`), lives here because it builds
/// an item; see [`DownloadRules::follow_up`].
pub(crate) fn follower_of(
    rules: &dyn AudioTrackRules,
    watched: &DownloadItem,
    next: &Item,
    now: f64,
) -> DownloadItem {
    let source = first_source(next);
    let mut base = DownloadItem::new(
        next.id.clone(),
        watched.account.clone(),
        Art::Episode,
        next.name.clone(),
        source.and_then(|s| s.size).unwrap_or(0),
        now,
    );
    base.series = watched.series.clone();
    base.series_identifier = watched.series_identifier.clone();
    base.season = next.parent_index_number.or(watched.season);
    base.episode = next.index_number;
    base.runtime_ticks = next.run_time_ticks;
    base.container = source.and_then(|s| s.container.clone());
    base.source = source.and_then(|s| s.id.clone());
    let codec = source.and_then(|s| s.video_codec().map(str::to_owned));
    let mut follower = base
        .with_watch_state(next.user_data.as_ref(), codec)
        .in_quality(watched.guete());
    if let Some(language) = &watched.audio_language {
        let streams = audio_streams(source);
        follower = follower.with_audio(
            rules,
            &DownloadAudioChoice::Language(language.clone()),
            &streams,
        );
        follower.audio_language = Some(language.clone());
    }
    follower.replaces = Some(watched.id.clone());
    follower
}

/// **A piece of a file name from server data**, never a way out of the folder.
pub struct PathPart;

impl PathPart {
    /// Letters, digits, `-` and `_` stay; every other character becomes `_`. Empty becomes `_`.
    /// Works per Unicode scalar, like the Swift original.
    pub fn safe(part: &str) -> String {
        let out: String = part
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        if out.is_empty() { "_".to_owned() } else { out }
    }

    /// Does this look like a Jellyfin id (GUID, with or without hyphens)? 1 to 64 characters of
    /// `[A-Za-z0-9-]`. Swift's `count` counts grapheme clusters; any non-ASCII fails anyway.
    pub fn is_id(text: &str) -> bool {
        (1..=64).contains(&text.chars().count())
            && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    }

    /// The extension from the server's container: `[a-z0-9]{1,8}`, otherwise `None`. A list like
    /// `mov,mp4,m4a` stays allowed as long as every member fits.
    pub fn suffix(container: Option<&str>) -> Option<String> {
        let c = container?.to_lowercase();
        if c.is_empty() {
            return None;
        }
        let fits = c.split(',').all(|g| {
            (1..=8).contains(&g.chars().count())
                && g.chars()
                    .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit())
        });
        fits.then_some(c)
    }
}

fn is_false(b: &bool) -> bool {
    !*b
}
