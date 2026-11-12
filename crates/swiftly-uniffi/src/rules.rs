//! Ported rules the host calls directly: the track mapping for engines that report their own
//! ids (VLC), the subtitle cue lookup, the "(Original)" audio tag, the next-episode version
//! and the one-time `utAuto` migration.

use std::sync::Arc;

use swiftly_model::{MediaSource, MediaStream};
use swiftly_playback::original_audio;
use swiftly_playback::subtitle_cues::SubtitleCues;
use swiftly_playback::track_mapping::{PlayerTrack, SubtitleFile, TrackMapping};
use swiftly_settings::Settings;

use crate::error::CoreError;
use crate::settings::{Backing, SettingsStore};

/// A track as the engine reports it (libVLC style ids: `audio/1`, `spu/3`, `<md5>/spu/0`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HostTrack {
    /// The engine's identifier.
    pub identifier: String,
    /// Track name.
    pub name: String,
    /// As reported: `ger`, `German` or empty.
    pub language: Option<String>,
    /// Codec in the spelling the rules use.
    pub codec: Option<String>,
    /// Channel count.
    pub channels: Option<i64>,
}

/// A subtitle file loaded into the engine.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostSubtitleFile {
    /// The server's `Index` of the stream.
    pub index: i64,
    /// Full address.
    pub address: String,
    /// MD5 of the address as lowercase hex.
    pub attribute: Option<String>,
}

/// Server index per position of the engine's lists (`None`: no match).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostTrackMapping {
    /// Per position in the audio list.
    pub audio: Vec<Option<i64>>,
    /// Per position in the subtitle list.
    pub subtitle: Vec<Option<i64>>,
}

fn host(t: HostTrack) -> PlayerTrack {
    PlayerTrack {
        identifier: t.identifier,
        name: t.name,
        language: t.language,
        codec: t.codec,
        channels: t.channels,
    }
}

fn failed(what: &str) -> CoreError {
    CoreError::Failed {
        message: what.to_owned(),
    }
}

/// Maps the engine's track lists onto the server's streams (`TrackMapping.compose`): the
/// decision is made by the server's index, the engine is addressed by position among the
/// embedded tracks, and only when the counts agree. `streams_json` is the `MediaStreams` array
/// of the chosen source.
///
/// # Errors
/// When `streams_json` is not a `MediaStreams` array.
#[uniffi::export]
pub fn map_host_tracks(
    audio: Vec<HostTrack>,
    subtitle: Vec<HostTrack>,
    streams_json: String,
    files: Vec<HostSubtitleFile>,
) -> Result<HostTrackMapping, CoreError> {
    let streams: Vec<MediaStream> = serde_json::from_str(&streams_json)
        .map_err(|_| failed("streams are not a MediaStreams array"))?;
    let audio: Vec<PlayerTrack> = audio.into_iter().map(host).collect();
    let subtitle: Vec<PlayerTrack> = subtitle.into_iter().map(host).collect();
    let files: Vec<SubtitleFile> = files
        .into_iter()
        .map(|f| SubtitleFile {
            index: f.index,
            address: f.address,
            attribute: f.attribute,
        })
        .collect();
    let m = TrackMapping::compose(&audio, &subtitle, &streams, &files);
    Ok(HostTrackMapping {
        audio: m.audio,
        subtitle: m.subtitle,
    })
}

/// A parsed subtitle file for the lookup at a time (SRT or WebVTT text).
#[derive(uniffi::Object)]
pub struct SubtitleCueIndex {
    cues: SubtitleCues,
}

#[uniffi::export]
impl SubtitleCueIndex {
    /// Parses the text of a subtitle file.
    #[uniffi::constructor]
    pub fn parse(raw: String) -> Arc<Self> {
        Arc::new(Self {
            cues: SubtitleCues::parse(&raw),
        })
    }

    /// The text showing at `seconds`, if any (a long cue behind many short ones is found).
    pub fn text_at(&self, seconds: f64) -> Option<String> {
        self.cues.text_at(seconds)
    }

    /// Number of cues.
    pub fn count(&self) -> u64 {
        self.cues.cues().len() as u64
    }
}

/// Whether an audio track is the title's original language: the stream's own flag wins,
/// otherwise the language is compared with the title's `OriginalLanguage`.
#[uniffi::export]
pub fn audio_is_original(
    language: Option<String>,
    stream_language: Option<String>,
    flagged_original: bool,
    original_language: Option<String>,
) -> bool {
    // `language` is the engine's; when it is missing the stream's own counts, like the old rule.
    let stream = MediaStream {
        is_original: Some(flagged_original),
        language: stream_language,
        ..MediaStream::default()
    };
    original_audio::is_original(
        language.as_deref(),
        Some(&stream),
        original_language.as_deref(),
    )
}

/// `base` plus the suffix (the catalog word "(Original)") when the track is the original.
#[uniffi::export]
pub fn audio_label_with_original(
    base: String,
    language: Option<String>,
    stream_language: Option<String>,
    flagged_original: bool,
    original_language: Option<String>,
    suffix: String,
) -> String {
    if audio_is_original(
        language,
        stream_language,
        flagged_original,
        original_language,
    ) {
        format!("{base} {suffix}")
    } else {
        base
    }
}

/// The version to keep for the next episode: the one named like the previous (trimmed, case-
/// insensitive), else the one with the same resolution. `None` asks the user again. Both are
/// `MediaSource` JSON; the answer is a `MediaSource` JSON.
#[uniffi::export]
pub fn matching_next_version(previous_json: String, next_json: String) -> Option<String> {
    let previous: MediaSource = serde_json::from_str(&previous_json).ok()?;
    let next: Vec<MediaSource> = serde_json::from_str(&next_json).ok()?;
    let found = swiftly_model::MediaVersions::matching(&previous, Some(&next))?;
    serde_json::to_string(&found).ok()
}

/// The audio or subtitle delay (milliseconds) that applies when the player moves to another title:
/// the same title and the same series keep it, anything else starts at zero (`Delay.forNewTitle`).
#[uniffi::export]
pub fn delay_for_new_title(
    current_ms: i64,
    old_title: String,
    old_series: Option<String>,
    new_title: String,
    added_series: Option<String>,
) -> i64 {
    swiftly_rules::delay::Delay::for_new_title(
        swiftly_rules::delay::Delay::from_milliseconds(current_ms),
        &old_title,
        old_series.as_deref(),
        &new_title,
        added_series.as_deref(),
    )
    .milliseconds()
}

/// The one-time migration of the subtitle language to the "automatic" switch (`utAuto`): a
/// language chosen before the switch existed never took effect, so the switch goes on once.
/// Call at every start; it does its work once. Returns the resulting `utAuto`.
#[uniffi::export]
pub fn migrate_subtitle_auto(store: Arc<dyn SettingsStore>) -> bool {
    migrate_on(Backing::Native(store))
}

pub(crate) fn migrate_on(backing: Backing) -> bool {
    Settings::new(backing)
        .migrate_subtitle_auto()
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::SettingValue;
    use std::collections::HashMap;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Mem(Mutex<HashMap<String, SettingValue>>);
    impl SettingsStore for Mem {
        fn get(&self, key: String) -> Option<SettingValue> {
            self.0.lock().unwrap().get(&key).cloned()
        }
        fn set(&self, key: String, value: SettingValue) {
            self.0.lock().unwrap().insert(key, value);
        }
        fn remove(&self, key: String) {
            self.0.lock().unwrap().remove(&key);
        }
        fn keys(&self) -> Vec<String> {
            self.0.lock().unwrap().keys().cloned().collect()
        }
    }

    #[test]
    fn a_language_chosen_before_the_auto_switch_turns_it_on_once() {
        let store = Arc::new(Mem::default());
        store.set(
            "utSprache".into(),
            SettingValue::Text {
                value: "deu".into(),
            },
        );
        assert!(migrate_subtitle_auto(Arc::clone(&store) as _));
        // The user switches it off again: the migration does not run twice.
        store.set("utAuto".into(), SettingValue::Bool { value: false });
        assert!(!migrate_subtitle_auto(store));
    }

    #[test]
    fn cues_are_found_by_time() {
        let idx = SubtitleCueIndex::parse(
            "1\n00:00:01,000 --> 00:00:03,000\nHello\n\n2\n00:00:05,000 --> 00:00:06,000\nBye\n"
                .into(),
        );
        assert_eq!(idx.count(), 2);
        assert_eq!(idx.text_at(2.0).as_deref(), Some("Hello"));
        assert_eq!(idx.text_at(4.0), None);
    }

    #[test]
    fn the_original_tag_follows_flag_or_language() {
        assert!(audio_is_original(
            Some("ger".into()),
            None,
            false,
            Some("de".into())
        ));
        assert!(!audio_is_original(
            Some("eng".into()),
            None,
            false,
            Some("de".into())
        ));
        assert!(audio_is_original(Some("eng".into()), None, true, None));
        // The engine knows no language: the stream's own counts (old rule `language ?? stream.language`).
        assert!(audio_is_original(
            None,
            Some("jpn".into()),
            false,
            Some("ja".into())
        ));
        assert!(!audio_is_original(None, None, false, Some("ja".into())));
        // An empty engine language is a language of its own and does not fall back.
        assert!(!audio_is_original(
            Some(String::new()),
            Some("jpn".into()),
            false,
            Some("ja".into())
        ));
        assert_eq!(
            audio_label_with_original(
                "Deutsch".into(),
                Some("ger".into()),
                None,
                false,
                Some("de".into()),
                "(Original)".into()
            ),
            "Deutsch (Original)"
        );
    }

    #[test]
    fn the_next_episode_keeps_the_version_by_name_then_resolution() {
        let prev = r#"{"Id":"a","Name":"Director's Cut"}"#;
        let next = r#"[{"Id":"x","Name":"Theatrical"},{"Id":"y","Name":" director's cut "}]"#;
        let found = matching_next_version(prev.into(), next.into()).expect("match");
        assert!(found.contains("\"y\""), "{found}");
        assert!(
            matching_next_version(prev.into(), r#"[{"Id":"x","Name":"Theatrical"}]"#.into())
                .is_none()
        );
    }

    #[test]
    fn host_tracks_map_to_server_indices() {
        let streams = r#"[{"Type":"Audio","Index":1,"Language":"ger","Codec":"ac3","Channels":6},
                          {"Type":"Audio","Index":2,"Language":"eng","Codec":"aac","Channels":2}]"#;
        let t = |id: &str, lang: &str| HostTrack {
            identifier: id.into(),
            name: String::new(),
            language: Some(lang.into()),
            codec: None,
            channels: None,
        };
        let m = map_host_tracks(
            vec![t("audio/1", "ger"), t("audio/2", "eng")],
            vec![],
            streams.into(),
            vec![],
        )
        .unwrap();
        assert_eq!(m.audio, vec![Some(1), Some(2)]);
        assert!(map_host_tracks(vec![], vec![], "nope".into(), vec![]).is_err());
    }
}
