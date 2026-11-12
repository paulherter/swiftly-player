//! Port of DownloadAudio.swift (the choice logic; `DownloadItem.withAudio` needs the
//! download model and is not ported).
//!
//! Which audio a download carries: all tracks (the original), exactly one stream index (a
//! film), or the track in one language (a selection of episodes, where the same language has
//! a different index in every file).
//!
//! Swift calls `TrackLabel`, `TrackImprint`, `TechDetails` and `TrackRule`, which live in other
//! files (they belong to `swiftly-playback`). They are reached through the small
//! [`AudioTrackRules`] trait instead, and the catalog strings ("Alle Tonspuren", "Tonspur")
//! come from it as well.

/// The fields of `MediaStream` this file reads.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioStream {
    /// Codec name as the server reports it.
    pub codec: Option<String>,
    /// Stream type ("Audio", "Subtitle", "Video").
    pub kind: String,
    /// Language code as the file stores it ("ger", "eng").
    pub language: Option<String>,
    /// The server's display title.
    pub display_title: Option<String>,
    /// Channel count.
    pub channels: Option<i64>,
    /// Marked as default track.
    pub is_default: Option<bool>,
    /// Stream index in the file.
    pub index: Option<i64>,
}

/// What the choice is.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum DownloadAudioChoice {
    /// The original file, every track.
    All,
    /// Exactly this stream index.
    Track(i64),
    /// The track in this language key (`TrackImprint.languageKey`).
    Language(String),
}

/// One row of the picker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadAudioOption {
    /// The choice it stands for.
    pub choice: DownloadAudioChoice,
    /// Its label.
    pub label: String,
}

/// The collaborators of Swift's `DownloadAudio` that live in other files.
pub trait AudioTrackRules {
    /// `TrackImprint.languageKey(_:)`.
    fn language_key(&self, language: Option<&str>) -> Option<String>;
    /// `TrackLabel.language(_:)`: the display name of a language key.
    fn language_label(&self, key: &str) -> Option<String>;
    /// `TrackLabel.audio(language:codec:channels:)` with `TechDetails.codecNameValue`
    /// already applied to the codec by the implementor.
    fn audio_label(
        &self,
        language: Option<&str>,
        codec: Option<&str>,
        channels: Option<i64>,
    ) -> Option<String>;
    /// `TrackLabel.distinct(_:)`: makes equal labels different (adds numbers).
    fn distinct(&self, labels: Vec<String>) -> Vec<String>;
    /// `TrackRule.audio(streams:remembered: nil, preferredLanguage:, serverPreGift: nil)`:
    /// the index of the preferred track, if any.
    fn preferred_audio_index(
        &self,
        streams: &[AudioStream],
        preferred_language: &str,
    ) -> Option<i64>;
    /// `translated("Alle Tonspuren")`.
    fn all_label(&self) -> String;
    /// `translated("Tonspur")`.
    fn track_word(&self) -> String;
}

/// The audio streams that have an index. (`DownloadAudio.swift:34-36`)
fn tracks(streams: &[AudioStream]) -> Vec<&AudioStream> {
    streams
        .iter()
        .filter(|s| s.kind == "Audio" && s.index.is_some())
        .collect()
}

/// Whether to ask at all: one track has nothing to choose from.
pub fn offered_for_streams(streams: &[AudioStream]) -> bool {
    tracks(streams).len() > 1
}

/// Whether a selection of files offers a choice: at least one of them holds two languages
/// (the option list is more than "all" plus one language).
pub fn offered_for_selection(rules: &dyn AudioTrackRules, selection: &[Vec<AudioStream>]) -> bool {
    language_options(rules, selection).len() > 2
}

fn all_option(rules: &dyn AudioTrackRules) -> DownloadAudioOption {
    DownloadAudioOption {
        choice: DownloadAudioChoice::All,
        label: rules.all_label(),
    }
}

fn label_for(rules: &dyn AudioTrackRules, stream: &AudioStream, position: usize) -> String {
    rules
        .audio_label(
            stream.language.as_deref(),
            stream.codec.as_deref(),
            stream.channels,
        )
        .or_else(|| stream.display_title.clone())
        .unwrap_or_else(|| format!("{} {position}", rules.track_word()))
}

/// "Alle Tonspuren", then every track of one file, labelled as the player labels them.
/// (`DownloadAudio.swift:50-56`)
pub fn track_options(
    rules: &dyn AudioTrackRules,
    streams: &[AudioStream],
) -> Vec<DownloadAudioOption> {
    let list = tracks(streams);
    let labels = rules.distinct(
        list.iter()
            .enumerate()
            .map(|(i, s)| label_for(rules, s, i + 1))
            .collect(),
    );
    let mut options = vec![all_option(rules)];
    options.extend(list.iter().zip(labels).filter_map(|(stream, label)| {
        stream.index.map(|index| DownloadAudioOption {
            choice: DownloadAudioChoice::Track(index),
            label,
        })
    }));
    options
}

/// "Alle Tonspuren", then every language that occurs in any of the files, in the order they
/// first appear. (`DownloadAudio.swift:60-72`)
pub fn language_options(
    rules: &dyn AudioTrackRules,
    selection: &[Vec<AudioStream>],
) -> Vec<DownloadAudioOption> {
    let mut seen: Vec<String> = Vec::new();
    for streams in selection {
        for stream in tracks(streams) {
            if let Some(key) = rules.language_key(stream.language.as_deref())
                && !seen.contains(&key)
            {
                seen.push(key);
            }
        }
    }
    let mut options = vec![all_option(rules)];
    options.extend(seen.into_iter().map(|key| {
        let label = rules.language_label(&key).unwrap_or_else(|| key.clone());
        DownloadAudioOption {
            choice: DownloadAudioChoice::Language(key),
            label,
        }
    }));
    options
}

/// What the choice starts on: the track of the audio language from the settings if there is
/// one, otherwise all tracks. (`DownloadAudio.swift:91-103`)
pub fn preselected(
    rules: &dyn AudioTrackRules,
    options: &[DownloadAudioOption],
    streams: &[AudioStream],
    preferred_language: &str,
) -> DownloadAudioChoice {
    if preferred_language.is_empty() {
        return DownloadAudioChoice::All;
    }
    if let Some(index) = rules.preferred_audio_index(streams, preferred_language)
        && options
            .iter()
            .any(|o| o.choice == DownloadAudioChoice::Track(index))
    {
        return DownloadAudioChoice::Track(index);
    }
    let language = DownloadAudioChoice::Language(preferred_language.to_owned());
    if options.iter().any(|o| o.choice == language) {
        language
    } else {
        DownloadAudioChoice::All
    }
}

/// The stream index a choice means in this file; `None` for "all tracks", and for a language
/// or track the file does not have (then the whole file is loaded). With a single track
/// there is never an index. (`DownloadAudio.swift:108-123`)
pub fn index_for(
    rules: &dyn AudioTrackRules,
    choice: &DownloadAudioChoice,
    streams: &[AudioStream],
) -> Option<i64> {
    let list = tracks(streams);
    if list.len() <= 1 {
        return None;
    }
    match choice {
        DownloadAudioChoice::All => None,
        DownloadAudioChoice::Track(index) => list
            .iter()
            .any(|s| s.index == Some(*index))
            .then_some(*index),
        DownloadAudioChoice::Language(key) => {
            let fitting: Vec<&&AudioStream> = list
                .iter()
                .filter(|s| {
                    rules.language_key(s.language.as_deref()).as_deref() == Some(key.as_str())
                })
                .collect();
            fitting
                .iter()
                .find(|s| s.is_default == Some(true))
                .or_else(|| fitting.first())
                .and_then(|s| s.index)
        }
    }
}

/// The language key of a track, to hand to the next episode.
pub fn language_key_of(
    rules: &dyn AudioTrackRules,
    index: i64,
    streams: &[AudioStream],
) -> Option<String> {
    tracks(streams)
        .into_iter()
        .find(|s| s.index == Some(index))
        .and_then(|s| rules.language_key(s.language.as_deref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A test double for the collaborators; the Swift tests use the real `TrackImprint` /
    /// `TrackLabel` / `TrackRule`, whose behaviour is only imitated here (3-letter code to
    /// 2-letter key, "Language · codec · channels" labels, numbered duplicates).
    struct Fake;

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
            let copy = labels.clone();
            labels
                .into_iter()
                .enumerate()
                .map(|(i, l)| {
                    if copy.iter().filter(|x| **x == l).count() > 1 {
                        format!("{l} {}", copy[..=i].iter().filter(|x| **x == l).count())
                    } else {
                        l
                    }
                })
                .collect()
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

    fn audio(index: i64, language: &str, codec: &str, is_default: bool) -> AudioStream {
        AudioStream {
            codec: Some(codec.into()),
            kind: "Audio".into(),
            language: Some(language.into()),
            display_title: None,
            channels: Some(6),
            is_default: Some(is_default),
            index: Some(index),
        }
    }

    fn a(index: i64, language: &str) -> AudioStream {
        audio(index, language, "ac3", false)
    }

    fn film() -> Vec<AudioStream> {
        vec![a(1, "ger"), audio(2, "eng", "dts", false)]
    }

    // Swift: offered()
    #[test]
    fn offered() {
        assert!(!offered_for_streams(&[a(1, "ger")]));
        assert!(offered_for_streams(&film()));
    }

    // Swift: filmOptions()
    #[test]
    fn film_options() {
        let options = track_options(&Fake, &film());
        let choices: Vec<DownloadAudioChoice> = options.into_iter().map(|o| o.choice).collect();
        assert_eq!(
            choices,
            [
                DownloadAudioChoice::All,
                DownloadAudioChoice::Track(1),
                DownloadAudioChoice::Track(2)
            ]
        );
    }

    // Swift: distinctLabels()
    #[test]
    fn distinct_labels() {
        let twin = [a(1, "ger"), a(2, "ger")];
        let labels: Vec<String> = track_options(&Fake, &twin)
            .into_iter()
            .skip(1)
            .map(|o| o.label)
            .collect();
        let mut unique = labels.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), 2);
    }

    // Swift: preselectionNone()
    #[test]
    fn preselection_none() {
        let options = track_options(&Fake, &film());
        assert_eq!(
            preselected(&Fake, &options, &film(), ""),
            DownloadAudioChoice::All
        );
    }

    // Swift: preselection()
    #[test]
    fn preselection() {
        let options = track_options(&Fake, &film());
        let key = Fake
            .language_key(Some("eng"))
            .unwrap_or_else(|| "eng".into());
        assert_eq!(
            preselected(&Fake, &options, &film(), &key),
            DownloadAudioChoice::Track(2)
        );
        assert_eq!(
            preselected(&Fake, &options, &film(), "fr"),
            DownloadAudioChoice::All
        );
    }

    // Swift: languages()
    #[test]
    fn languages() {
        let (x, y) = (
            vec![a(1, "ger"), a(2, "eng")],
            vec![a(1, "eng"), a(2, "jpn")],
        );
        let options = language_options(&Fake, &[x.clone(), y.clone()]);
        assert_eq!(options.len(), 4);
        assert_eq!(
            options.first().map(|o| o.choice.clone()),
            Some(DownloadAudioChoice::All)
        );
        assert!(offered_for_selection(&Fake, &[x, y]));
        assert!(!offered_for_selection(
            &Fake,
            &[vec![a(1, "ger"), a(2, "ger")]]
        ));
    }

    // Swift: languageIndex()
    #[test]
    fn language_index() {
        let key = Fake
            .language_key(Some("eng"))
            .unwrap_or_else(|| "eng".into());
        let lang = DownloadAudioChoice::Language(key);
        assert_eq!(
            index_for(&Fake, &lang, &[a(1, "ger"), a(2, "eng")]),
            Some(2)
        );
        assert_eq!(
            index_for(&Fake, &lang, &[a(1, "eng"), a(2, "ger")]),
            Some(1)
        );
        assert_eq!(index_for(&Fake, &lang, &[a(1, "ger"), a(2, "fra")]), None);
        assert_eq!(
            index_for(&Fake, &DownloadAudioChoice::Track(9), &film()),
            None
        );
        assert_eq!(index_for(&Fake, &DownloadAudioChoice::All, &film()), None);
    }

    // Extra: a default track wins among several of the same language; language_key_of.
    #[test]
    fn default_wins_and_key_of() {
        let streams = [
            audio(1, "eng", "ac3", false),
            audio(2, "eng", "dts", true),
            a(3, "ger"),
        ];
        assert_eq!(
            index_for(&Fake, &DownloadAudioChoice::Language("en".into()), &streams),
            Some(2)
        );
        assert_eq!(language_key_of(&Fake, 3, &streams).as_deref(), Some("de"));
        assert_eq!(language_key_of(&Fake, 9, &streams), None);
    }
}
