//! The rules for the audio tracks of a download: names, the language key and the track the player would pick, from
//! the same shared rules the player's track panel uses. One implementation for every host (Apple through uniffi,
//! Linux and Windows directly).

use swiftly_downloads::{AudioStream, AudioTrackRules};
use swiftly_l10n::Locale;
use swiftly_playback::track_rule::{LanguageWishes, OriginalStep};
use swiftly_rules::download_audio::{DownloadAudioChoice, preselected, track_options};

/// Track names for the download picker: the same wording rules as the player's track panel.
pub struct TrackNames {
    words: crate::LabelWords,
    tr: swiftly_l10n::Translator,
    /// The language of the device ("de-DE"): the track a download starts on follows the start language rule, which
    /// takes it after the audio language of the settings.
    device_language: Option<String>,
}

impl TrackNames {
    /// The rules worded in `locale`.
    pub fn new(locale: &str) -> Self {
        Self {
            words: crate::LabelWords::new(Locale::parse(locale)),
            tr: swiftly_l10n::Translator::new(Locale::parse(locale)),
            device_language: None,
        }
    }

    /// The same rules with the language of the device (`None` when the host does not know it).
    #[must_use]
    pub fn with_device_language(mut self, tag: Option<String>) -> Self {
        self.device_language = tag.filter(|t| !t.trim().is_empty());
        self
    }

    /// **What the download picker of one title starts on**: the track the start rule would play (the settings language, then
    /// the device language), else all tracks. The one place every host asks, so a film sheet and a season sheet agree.
    pub fn film_start(&self, streams: &[AudioStream], setting: &str) -> DownloadAudioChoice {
        let options = track_options(self, streams);
        preselected(self, &options, streams, setting)
    }

    /// The languages the start rule looks for, in its order (the settings, then the device).
    fn wishes<'a>(&'a self, setting: &'a str) -> LanguageWishes<'a> {
        LanguageWishes {
            setting,
            device: self.device_language.as_deref(),
            original: OriginalStep::Off,
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
        swiftly_playback::track_rule::audio_decodable(
            &media,
            None,
            &self.wishes(preferred),
            None,
            None,
            &|_| true,
        )
    }
    fn preferred_language_key(&self, keys: &[String], preferred: &str) -> Option<String> {
        swiftly_playback::track_rule::first_wished_language(keys, &self.wishes(preferred))
    }
    fn all_label(&self) -> String {
        self.tr.t("Alle Tonspuren")
    }
    fn track_word(&self) -> String {
        self.tr.t("Tonspur")
    }
}

impl TrackNames {
    /// The rules in German, the key language (tests; an app words them in the language of the device with `new`).
    pub fn german() -> Self {
        Self::new("de")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_rules::download_audio::{language_options, wished_language};

    fn track(index: i64, language: &str, is_default: bool) -> AudioStream {
        AudioStream {
            codec: Some("eac3".into()),
            kind: "Audio".into(),
            language: Some(language.into()),
            display_title: None,
            channels: Some(6),
            is_default: Some(is_default),
            index: Some(index),
        }
    }

    /// An English file with a German dub; the file's default track is the English one.
    fn film() -> Vec<AudioStream> {
        vec![track(1, "eng", true), track(2, "ger", false)]
    }

    fn picked(rules: &TrackNames, setting: &str) -> DownloadAudioChoice {
        rules.film_start(&film(), setting)
    }

    #[test]
    fn a_film_starts_the_download_on_the_device_language_when_the_settings_name_none() {
        let german = TrackNames::german().with_device_language(Some("de-DE".into()));
        assert_eq!(picked(&german, ""), DownloadAudioChoice::Track(2));
        let english = TrackNames::german().with_device_language(Some("en_US.UTF-8".into()));
        assert_eq!(picked(&english, ""), DownloadAudioChoice::Track(1));
    }

    #[test]
    fn without_a_device_language_and_without_a_setting_all_tracks_stay_the_start() {
        assert_eq!(picked(&TrackNames::german(), ""), DownloadAudioChoice::All);
        let unknown = TrackNames::german().with_device_language(Some("  ".into()));
        assert_eq!(picked(&unknown, ""), DownloadAudioChoice::All);
    }

    #[test]
    fn the_audio_language_of_the_settings_beats_the_device_language() {
        let german = TrackNames::german().with_device_language(Some("de-DE".into()));
        assert_eq!(picked(&german, "English"), DownloadAudioChoice::Track(1));
    }

    #[test]
    fn a_device_language_the_file_does_not_hold_leaves_all_tracks() {
        let french = TrackNames::german().with_device_language(Some("fr-FR".into()));
        assert_eq!(picked(&french, ""), DownloadAudioChoice::All);
    }

    #[test]
    fn a_selection_of_episodes_wishes_the_device_language_too() {
        let files = vec![
            vec![track(1, "eng", true), track(2, "ger", false)],
            vec![track(1, "eng", true), track(2, "deu", false)],
        ];
        let german = TrackNames::german().with_device_language(Some("de-AT".into()));
        let options = language_options(&german, &files);
        let key = wished_language(&german, &options, "").expect("German is held by both files");
        assert!(german.language_key(Some("ger")).as_deref() == Some(key.as_str()));
        // The settings first, then the device.
        let from_settings = wished_language(&german, &options, "English").expect("English is held");
        assert_eq!(
            german.language_key(Some("eng")).as_deref(),
            Some(from_settings.as_str())
        );
        // Neither a setting nor a device language: no wish.
        assert_eq!(wished_language(&TrackNames::german(), &options, ""), None);
    }
}
