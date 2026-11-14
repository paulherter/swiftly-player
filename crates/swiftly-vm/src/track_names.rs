//! The rules for the audio tracks of a download: names, the language key and the track the player would pick, from
//! the same shared rules the player's track panel uses. One implementation for every host (Apple through uniffi,
//! Linux and Windows directly).

use swiftly_downloads::{AudioStream, AudioTrackRules};
use swiftly_l10n::Locale;

/// Track names for the download picker: the same wording rules as the player's track panel.
pub struct TrackNames {
    words: crate::LabelWords,
    tr: swiftly_l10n::Translator,
}

impl TrackNames {
    /// The rules worded in `locale`.
    pub fn new(locale: &str) -> Self {
        Self {
            words: crate::LabelWords::new(Locale::parse(locale)),
            tr: swiftly_l10n::Translator::new(Locale::parse(locale)),
        }
    }
}

impl AudioTrackRules for TrackNames {
    fn language_key(&self, language: Option<&str>) -> Option<String> {
        swiftly_playback::track_mapping::language_key(language)
    }
    fn language_label(&self, key: &str) -> Option<String> {
        swiftly_playback::track_label::language(Some(key), &self.words)
    }
    fn audio_label(
        &self,
        language: Option<&str>,
        codec: Option<&str>,
        channels: Option<i64>,
    ) -> Option<String> {
        let codec = swiftly_playback::track_label::codec_name_value(codec);
        swiftly_playback::track_label::audio(language, codec.as_deref(), channels, &self.words)
    }
    fn distinct(&self, labels: Vec<String>) -> Vec<String> {
        swiftly_playback::track_label::distinct(&labels)
    }
    fn preferred_audio_index(&self, streams: &[AudioStream], preferred: &str) -> Option<i64> {
        let media: Vec<swiftly_model::MediaStream> = streams
            .iter()
            .map(|s| swiftly_model::MediaStream {
                index: s.index,
                type_: Some(s.kind.clone()),
                language: s.language.clone(),
                codec: s.codec.clone(),
                channels: s.channels,
                display_title: s.display_title.clone(),
                is_default: s.is_default,
                ..swiftly_model::MediaStream::default()
            })
            .collect();
        swiftly_playback::track_rule::audio(&media, None, preferred, None, None)
    }
    fn all_label(&self) -> String {
        self.tr.t("Alle Tonspuren")
    }
    fn track_word(&self) -> String {
        self.tr.t("Tonspur")
    }
}

impl TrackNames {
    /// The rules in German (the desktop's language until it has a language switch).
    pub fn german() -> Self {
        Self::new("de")
    }
}
