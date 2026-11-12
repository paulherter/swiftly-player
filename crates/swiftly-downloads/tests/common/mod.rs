//! Shared builders and the test double for the audio rules.
#![allow(dead_code)]

use swiftly_downloads::{Art, AudioStream, AudioTrackRules, DownloadItem, DownloadState};
use swiftly_model::{Item, MediaSource, MediaStream};

/// Imitates `TrackImprint` / `TrackLabel` / `TrackRule` (3-letter code to 2-letter key).
pub struct Fake;

impl AudioTrackRules for Fake {
    fn language_key(&self, language: Option<&str>) -> Option<String> {
        let key = match language? {
            "ger" | "deu" | "de" => "de",
            "eng" | "en" => "en",
            "fra" | "fre" | "fr" => "fr",
            "jpn" | "ja" => "ja",
            _ => return None,
        };
        Some(key.to_owned())
    }
    fn language_label(&self, key: &str) -> Option<String> {
        Some(
            match key {
                "de" => "German",
                "en" => "English",
                "fr" => "French",
                "ja" => "Japanese",
                _ => return None,
            }
            .to_owned(),
        )
    }
    fn audio_label(
        &self,
        language: Option<&str>,
        codec: Option<&str>,
        channels: Option<i64>,
    ) -> Option<String> {
        let name = self.language_label(&self.language_key(language)?)?;
        Some(format!(
            "{name} · {} · {}",
            codec.unwrap_or("?").to_uppercase(),
            channels.unwrap_or(0)
        ))
    }
    fn distinct(&self, labels: Vec<String>) -> Vec<String> {
        labels.clone()
    }
    fn preferred_audio_index(
        &self,
        streams: &[AudioStream],
        preferred_language: &str,
    ) -> Option<i64> {
        streams
            .iter()
            .find(|s| {
                s.kind == "Audio"
                    && self.language_key(s.language.as_deref()).as_deref()
                        == Some(preferred_language)
            })
            .and_then(|s| s.index)
    }
    fn all_label(&self) -> String {
        "Alle Tonspuren".into()
    }
    fn track_word(&self) -> String {
        "Tonspur".into()
    }
}

/// `entries(...)` of the Swift tests: a film, waiting, 1 GB, mkv, created at 1_000_000 s.
pub fn entry(id: &str) -> DownloadItem {
    let mut p = DownloadItem::new(
        id,
        "u1",
        Art::Film,
        format!("Titel {id}"),
        1_000_000_000,
        1_000_000.0,
    );
    p.container = Some("mkv".into());
    p
}

pub fn with_state(id: &str, state: DownloadState) -> DownloadItem {
    DownloadItem { state, ..entry(id) }
}

pub fn episode_entry(id: &str, series: &str, sid: &str, season: i64, number: i64) -> DownloadItem {
    DownloadItem {
        art: Art::Episode,
        series: Some(series.into()),
        series_identifier: Some(sid.into()),
        season: Some(season),
        episode: Some(number),
        ..entry(id)
    }
}

pub fn audio_stream(index: i64, language: &str, codec: &str, is_default: bool) -> MediaStream {
    MediaStream {
        codec: Some(codec.into()),
        type_: Some("Audio".into()),
        language: Some(language.into()),
        channels: Some(6),
        is_default: Some(is_default),
        index: Some(index),
        ..MediaStream::default()
    }
}

pub fn episode_item(id: &str, season: i64, number: i64, streams: Vec<MediaStream>) -> Item {
    Item {
        id: id.into(),
        name: format!("Folge {id}"),
        type_: Some("Episode".into()),
        index_number: Some(number),
        parent_index_number: Some(season),
        media_sources: Some(vec![MediaSource {
            id: Some(format!("src-{id}")),
            container: Some("mkv".into()),
            size: Some(1_000),
            supports_direct_play: Some(true),
            supports_direct_stream: Some(true),
            supports_transcoding: Some(true),
            media_streams: Some(streams),
            ..MediaSource::default()
        }]),
        ..Item::default()
    }
}
