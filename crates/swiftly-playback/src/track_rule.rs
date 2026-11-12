//! Which audio and subtitle track is on when playback starts (JellyfinKit/TrackRule.swift).
//!
//! Decided from Jellyfin's `MediaStream`s, not from the names in the player.
//!
//! Audio, top to bottom: ordered by another device, chosen by hand for this title or series,
//! the app's audio language, the server default, else the file (TrackRule.swift:8-14).
//!
//! Subtitles: ordered, remembered (incl. off), automatic subtitles when the audio is not in the
//! preferred language (full track before SDH), the server default (any if automatic, else
//! forced only), forced (audio language first), else off. Never the first track
//! (TrackRule.swift:15-28).

use std::collections::HashMap;

use swiftly_jellyfin::TrackIndices;
use swiftly_model::MediaStream;
use swiftly_rules::language;

use crate::track_mapping::{TrackImprint, language_key};

/// The subtitle decision (TrackRule.swift:37).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Subtitle {
    /// No subtitle.
    Off,
    /// Jellyfin's `Index`.
    Feed(i64),
}

/// The track choice made by hand (TrackRule.swift:171).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Choice {
    /// Switched off.
    Off,
    /// A snapshot of a track.
    Track(TrackImprint),
    /// Old entry: only the track name.
    Name(String),
}

fn tracks_of<'a>(streams: &'a [MediaStream], ty: &str) -> Vec<&'a MediaStream> {
    streams
        .iter()
        .filter(|s| s.type_.as_deref() == Some(ty))
        .collect()
}

/// The audio index to start with (TrackRule.swift:45-61).
///
/// `ordered` is the index sent by another device; one the file does not have is ignored.
pub fn audio(
    streams: &[MediaStream],
    remembered: Option<&TrackImprint>,
    preferred_language: &str,
    server_default: Option<i64>,
    ordered: Option<i64>,
) -> Option<i64> {
    audio_decodable(
        streams,
        remembered,
        preferred_language,
        server_default,
        ordered,
        &|_| true,
    )
}

/// [`audio`] with the question "can the engine decode this audio track?" (issue #50). A track
/// it cannot decode is never chosen by memory, language or server default; when the server's
/// default is such a track, the first decodable one (same language first) takes its place.
/// An order from another device is kept. `|_| true` gives the same answer as [`audio`].
pub fn audio_decodable(
    streams: &[MediaStream],
    remembered: Option<&TrackImprint>,
    preferred_language: &str,
    server_default: Option<i64>,
    ordered: Option<i64>,
    can_decode: &dyn Fn(&MediaStream) -> bool,
) -> Option<i64> {
    let all_tracks = tracks_of(streams, "Audio");
    if let Some(o) = ordered
        && all_tracks.iter().any(|t| t.index == Some(o))
    {
        return Some(o);
    }
    let usable: Vec<MediaStream> = streams
        .iter()
        .filter(|s| s.type_.as_deref() != Some("Audio") || can_decode(s))
        .cloned()
        .collect();
    let tracks = tracks_of(&usable, "Audio");
    if let Some(hit) = remembered.and_then(|r| r.best(&usable, "Audio")) {
        return hit.index;
    }
    if !preferred_language.is_empty()
        && let Some(hit) = tracks
            .iter()
            .find(|t| language_key(t.language.as_deref()).as_deref() == Some(preferred_language))
    {
        return hit.index;
    }
    if let Some(s) = server_default {
        if tracks.iter().any(|t| t.index == Some(s)) {
            return Some(s);
        }
        if let Some(lost) = all_tracks.iter().find(|t| t.index == Some(s)) {
            let key = language_key(lost.language.as_deref());
            let same = tracks
                .iter()
                .find(|t| key.is_some() && language_key(t.language.as_deref()) == key);
            return same.or(tracks.first()).and_then(|t| t.index);
        }
    }
    None
}

/// The inputs of [`subtitle`] that are not the streams.
#[derive(Debug, Clone, Default)]
pub struct SubtitleInput<'a> {
    /// Hand choice for this title, incl. off.
    pub remembered: Option<Choice>,
    /// The server's `DefaultSubtitleStreamIndex`.
    pub server_default: Option<i64>,
    /// "Automatic subtitles" setting.
    pub automatic: bool,
    /// The audio track that is playing.
    pub audio_index: Option<i64>,
    /// Audio language from the settings, empty for none (`tonwunsch`).
    pub audio_wish: &'a str,
    /// Subtitle language from the settings.
    pub preferred_language: &'a str,
    /// Index sent by another device, `-1` for off.
    pub ordered: Option<i64>,
}

/// The subtitle to start with (TrackRule.swift:69-139).
pub fn subtitle(streams: &[MediaStream], input: &SubtitleInput<'_>) -> Subtitle {
    let tracks = tracks_of(streams, "Subtitle");
    if let Some(o) = input.ordered {
        if o < 0 {
            return Subtitle::Off;
        }
        if tracks.iter().any(|t| t.index == Some(o)) {
            return Subtitle::Feed(o);
        }
    }
    let forced: Vec<&&MediaStream> = tracks
        .iter()
        .filter(|t| t.is_forced == Some(true))
        .collect();

    match &input.remembered {
        Some(Choice::Off) => return Subtitle::Off,
        Some(Choice::Track(imprint)) => {
            if let Some(index) = imprint.best(streams, "Subtitle").and_then(|h| h.index) {
                return Subtitle::Feed(index);
            }
            // If it does not exist, the normal case applies instead of "off".
        }
        Some(Choice::Name(alt)) => {
            if let Some(lang) = language::detected(alt) {
                let matching: Vec<&&MediaStream> = tracks
                    .iter()
                    .filter(|t| language_key(t.language.as_deref()).as_deref() == Some(lang))
                    .collect();
                let will_forced = language::sounds_forced(alt);
                let hit = matching
                    .iter()
                    .find(|t| (t.is_forced == Some(true)) == will_forced)
                    .or_else(|| matching.first());
                if let Some(index) = hit.and_then(|h| h.index) {
                    return Subtitle::Feed(index);
                }
            }
        }
        None => {}
    }

    let audio_long = streams
        .iter()
        .find(|s| {
            s.type_.as_deref() == Some("Audio")
                && s.index == input.audio_index
                && input.audio_index.is_some()
        })
        .and_then(|s| language_key(s.language.as_deref()));

    if input.automatic && !input.preferred_language.is_empty() {
        // Without an audio preference the subtitle language counts.
        let should = if input.audio_wish.is_empty() {
            input.preferred_language
        } else {
            input.audio_wish
        };
        if let Some(al) = &audio_long
            && al != should
        {
            let matching: Vec<&&MediaStream> = tracks
                .iter()
                .filter(|t| {
                    language_key(t.language.as_deref()).as_deref() == Some(input.preferred_language)
                })
                .collect();
            let full = matching
                .iter()
                .find(|t| t.is_forced != Some(true) && t.is_hearing_impaired != Some(true))
                .or_else(|| matching.iter().find(|t| t.is_forced != Some(true)))
                .or_else(|| matching.first());
            if let Some(index) = full.and_then(|f| f.index) {
                return Subtitle::Feed(index);
            }
        }
    }

    if let Some(s) = input.server_default.filter(|s| *s >= 0)
        && let Some(guideline) = tracks.iter().find(|t| t.index == Some(s))
        && (input.automatic || guideline.is_forced == Some(true))
    {
        return Subtitle::Feed(s);
    }

    if let Some(al) = &audio_long
        && let Some(index) = forced
            .iter()
            .find(|t| language_key(t.language.as_deref()).as_ref() == Some(al))
            .and_then(|t| t.index)
    {
        return Subtitle::Feed(index);
    }
    if let Some(index) = forced.first().and_then(|t| t.index) {
        return Subtitle::Feed(index);
    }
    Subtitle::Off
}

/// Inputs of [`start_indices`] (TrackRule.swift:151-154).
#[derive(Debug, Clone, Default)]
pub struct StartInput<'a> {
    /// Remembered audio choice.
    pub remembered_audio: Option<TrackImprint>,
    /// Remembered subtitle choice.
    pub remembered_subtitle: Option<Choice>,
    /// The server's `DefaultAudioStreamIndex`.
    pub server_audio: Option<i64>,
    /// The server's `DefaultSubtitleStreamIndex`.
    pub server_subtitle: Option<i64>,
    /// "Automatic subtitles".
    pub automatic: bool,
    /// Audio language from the settings.
    pub audio_language: &'a str,
    /// Subtitle language from the settings.
    pub subtitle_language: &'a str,
}

/// The tracks this device would start with as Jellyfin indices, for a "Play" sent to another
/// device (TrackRule.swift:151-163). Subtitle `-1` means off.
pub fn start_indices(streams: &[MediaStream], input: &StartInput<'_>) -> TrackIndices {
    start_indices_decodable(streams, input, &|_| true)
}

/// [`start_indices`] that only starts with audio the engine can decode (issue #50).
pub fn start_indices_decodable(
    streams: &[MediaStream],
    input: &StartInput<'_>,
    can_decode: &dyn Fn(&MediaStream) -> bool,
) -> TrackIndices {
    let audio_index = audio_decodable(
        streams,
        input.remembered_audio.as_ref(),
        input.audio_language,
        input.server_audio,
        None,
        can_decode,
    );
    let choice = subtitle(
        streams,
        &SubtitleInput {
            remembered: input.remembered_subtitle.clone(),
            server_default: input.server_subtitle,
            automatic: input.automatic,
            audio_index,
            audio_wish: input.audio_language,
            preferred_language: input.subtitle_language,
            ordered: None,
        },
    );
    TrackIndices {
        audio: audio_index,
        subtitle: Some(match choice {
            Subtitle::Feed(i) => i,
            Subtitle::Off => -1,
        }),
    }
}

// MARK: Memory (the UserDefaults part is storage; the pure keys and encodings are here)

/// Storage key of the subtitle choices (TrackRule.swift:180).
pub const SUBTITLE_KEY: &str = "utJeTitel";
/// Storage key of the audio choices (TrackRule.swift:181).
pub const AUDIO_KEY: &str = "tonJeTitel";
const SEPARATOR: &str = "|";

/// The key of the series or movie, with the account in front (TrackRule.swift:189-193).
pub fn title_key(series_id: Option<&str>, item_id: &str, account: Option<&str>) -> String {
    let base = series_id.unwrap_or(item_id);
    match account.filter(|a| !a.is_empty()) {
        Some(a) => format!("{a}{SEPARATOR}{base}"),
        None => base.to_owned(),
    }
}

/// The bare key an entry had before the account went in front; Jellyfin and Emby only
/// (TrackRule.swift:215-219).
fn legacy(title: &str) -> Option<String> {
    if title.starts_with("plex-") {
        return None;
    }
    let (_, bare) = title.split_once(SEPARATOR)?;
    (!bare.is_empty()).then(|| bare.to_owned())
}

/// Reads one choice from the stored dictionary (TrackRule.swift:221-230).
pub fn read_choice(all: &HashMap<String, String>, title: &str) -> Option<Choice> {
    let raw = all
        .get(title)
        .or_else(|| legacy(title).and_then(|l| all.get(&l)))?;
    if raw.is_empty() {
        return Some(Choice::Off);
    }
    if raw.starts_with('{')
        && let Ok(imprint) = serde_json::from_str::<TrackImprint>(raw)
    {
        return Some(Choice::Track(imprint));
    }
    Some(Choice::Name(raw.clone()))
}

/// The remembered audio imprint for a title, if any (TrackRule.swift:199-202).
pub fn read_audio(all: &HashMap<String, String>, title: &str) -> Option<TrackImprint> {
    match read_choice(all, title) {
        Some(Choice::Track(i)) => Some(i),
        _ => None,
    }
}

/// Writes one choice into the stored dictionary (TrackRule.swift:232-242).
pub fn write_choice(all: &mut HashMap<String, String>, title: &str, choice: &Choice) {
    let raw = match choice {
        Choice::Off => String::new(),
        Choice::Name(n) => n.clone(),
        Choice::Track(i) => serde_json::to_string(i).unwrap_or_default(),
    };
    all.insert(title.to_owned(), raw);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::track_label::codec_name_value_vlc_id;
    use crate::track_mapping::{PlayerTrack, SubtitleFile, TrackMapping};

    fn ut(
        index: i64,
        lang: &str,
        forced: bool,
        ext: bool,
        codec: &str,
        title: Option<&str>,
        hi: bool,
    ) -> MediaStream {
        MediaStream {
            codec: Some(codec.into()),
            type_: Some("Subtitle".into()),
            language: Some(lang.into()),
            index: Some(index),
            is_forced: Some(forced),
            is_external: Some(ext),
            title: title.map(Into::into),
            delivery_url: ext.then(|| format!("/Videos/x/y/Subtitles/{index}/0/Stream.srt")),
            is_hearing_impaired: Some(hi),
            ..MediaStream::default()
        }
    }
    fn u(index: i64, lang: &str) -> MediaStream {
        ut(index, lang, false, false, "subrip", None, false)
    }
    fn uf(index: i64, lang: &str) -> MediaStream {
        ut(index, lang, true, false, "subrip", None, false)
    }
    fn a(index: i64, lang: &str) -> MediaStream {
        aud(index, lang, "aac", 2)
    }
    fn aud(index: i64, lang: &str, codec: &str, ch: i64) -> MediaStream {
        MediaStream {
            codec: Some(codec.into()),
            type_: Some("Audio".into()),
            language: Some(lang.into()),
            channels: Some(ch),
            index: Some(index),
            ..MediaStream::default()
        }
    }
    fn vlc(id: &str, name: &str, lang: Option<&str>, codec: Option<&str>) -> PlayerTrack {
        PlayerTrack::new(id, name, lang, codec, None)
    }
    fn imprint(feed: &MediaStream, streams: &[MediaStream]) -> TrackImprint {
        TrackImprint::from_feed(feed, streams, None)
    }
    fn rule(
        streams: &[MediaStream],
        remembered: Option<Choice>,
        guideline: Option<i64>,
        automatic: bool,
        wish: &str,
    ) -> Subtitle {
        subtitle(
            streams,
            &SubtitleInput {
                remembered,
                server_default: guideline,
                automatic,
                audio_index: Some(1),
                audio_wish: "",
                preferred_language: wish,
                ordered: None,
            },
        )
    }

    /// TrackRuleTests.startPositionsJeArt
    #[test]
    fn start_positions_je_art() {
        let streams = vec![
            a(1, "ger"),
            a(2, "eng"),
            u(3, "ger"),
            u(4, "eng"),
            ut(5, "fre", false, true, "subrip", None, false),
        ];
        assert_eq!(
            TrackMapping::start_positions(&streams, Some(2), Subtitle::Feed(4), &[]),
            (Some(1), Some(1))
        );
        assert_eq!(
            TrackMapping::start_positions(&streams, None, Subtitle::Off, &[]),
            (None, None)
        );
        assert_eq!(
            TrackMapping::start_positions(&streams, Some(1), Subtitle::Feed(5), &[]),
            (Some(0), None)
        );
    }

    /// TrackRuleTests.multiTrackFile
    #[test]
    fn multi_track_file() {
        let audio_langs = [(1, "ger"), (7, "eng"), (13, "jpn")];
        let ut_langs: [(i64, &str, &str); 16] = [
            (2, "ger", "subrip"),
            (3, "eng", "subrip"),
            (4, "fre", "subrip"),
            (5, "spa", "subrip"),
            (6, "ita", "subrip"),
            (8, "ger", "subrip"),
            (9, "eng", "subrip"),
            (10, "und", "subrip"),
            (11, "jpn", "subrip"),
            (12, "chi", "subrip"),
            (14, "kor", "subrip"),
            (15, "ger", "ass"),
            (16, "eng", "ass"),
            (17, "por", "subrip"),
            (18, "dut", "subrip"),
            (19, "pol", "subrip"),
        ];
        let mut streams: Vec<MediaStream> = audio_langs
            .iter()
            .map(|(i, l)| aud(*i, l, "ac3", 6))
            .collect();
        streams.extend(
            ut_langs
                .iter()
                .map(|(i, l, c)| ut(*i, l, *i == 8, false, c, (*i == 9).then_some("SDH"), false)),
        );
        for (offset, name) in [(1, "libVLC 4"), (0, "libVLC 3")] {
            let audio_tracks: Vec<PlayerTrack> = audio_langs
                .iter()
                .map(|(i, l)| {
                    vlc(
                        &format!("audio/{}", i + offset),
                        "Track",
                        Some(l),
                        Some("AC-3"),
                    )
                })
                .collect();
            let sub_tracks: Vec<PlayerTrack> = ut_langs
                .iter()
                .map(|(i, l, c)| {
                    let id = if *c == "ass" {
                        0x2061_7373
                    } else {
                        0x7462_7573
                    };
                    PlayerTrack::new(
                        &format!("spu/{}", i + offset),
                        "Track",
                        Some(l),
                        codec_name_value_vlc_id(id).as_deref(),
                        None,
                    )
                })
                .collect();
            let z = TrackMapping::compose(&audio_tracks, &sub_tracks, &streams, &[]);
            assert_eq!(
                z.audio,
                audio_langs.iter().map(|x| Some(x.0)).collect::<Vec<_>>(),
                "{name}"
            );
            assert_eq!(
                z.subtitle,
                ut_langs.iter().map(|x| Some(x.0)).collect::<Vec<_>>(),
                "{name}"
            );
            for (position, e) in ut_langs.iter().enumerate() {
                assert_eq!(
                    z.subtitle_position(e.0),
                    Some(position),
                    "{name} Index {}",
                    e.0
                );
            }
        }
    }

    /// TrackRuleTests.sameNames
    #[test]
    fn same_names() {
        let streams = vec![a(1, "ger"), uf(2, "ger"), u(3, "ger")];
        let z = TrackMapping::compose(
            &[vlc("audio/1", "Deutsch", Some("ger"), Some("AAC"))],
            &[
                vlc("spu/2", "Deutsch", Some("ger"), None),
                vlc("spu/3", "Deutsch", Some("ger"), None),
            ],
            &streams,
            &[],
        );
        assert_eq!(z.audio, vec![Some(1)]);
        assert_eq!(z.subtitle, vec![Some(2), Some(3)]);
    }

    /// TrackRuleTests.countSoftOff
    #[test]
    fn count_soft_off() {
        let streams = vec![
            aud(1, "ger", "dts", 2),
            aud(2, "eng", "truehd", 2),
            a(3, "jpn"),
        ];
        let z = TrackMapping::compose(
            &[
                vlc("audio/1", "German", Some("German"), Some("DTS")),
                vlc("audio/3", "Japanese", Some("jpn"), Some("AAC")),
            ],
            &[],
            &streams,
            &[],
        );
        assert_eq!(z.audio, vec![Some(1), Some(3)]);
        let without = TrackMapping::compose(
            &[vlc("audio/1", "Spur 1", None, None)],
            &[],
            &[a(1, "ger"), a(2, "eng")],
            &[],
        );
        assert_eq!(without.audio, vec![None]);
    }

    /// TrackRuleTests.contradiction
    #[test]
    fn contradiction() {
        let streams = vec![u(3, "eng"), u(4, "ger")];
        let z = TrackMapping::compose(
            &[],
            &[vlc("spu/4", "Deutsch", Some("ger"), None)],
            &[u(4, "ger")],
            &[],
        );
        assert_eq!(z.subtitle, vec![Some(4)]);
        let swapped = TrackMapping::compose(
            &[],
            &[
                vlc("spu/1", "German", Some("German"), None),
                vlc("spu/2", "English", Some("eng"), None),
            ],
            &streams,
            &[],
        );
        assert_eq!(swapped.subtitle, vec![Some(4), None]);
    }

    /// TrackRuleTests.externalTrack
    #[test]
    fn external_track() {
        let md5 = "0123456789abcdef0123456789abcdef";
        let streams = vec![
            a(1, "ger"),
            uf(2, "ger"),
            ut(5, "eng", false, true, "subrip", None, false),
        ];
        let file = SubtitleFile {
            index: 5,
            address: "https://s/x.srt".into(),
            attribute: Some(md5.into()),
        };
        let z = TrackMapping::compose(
            &[vlc("audio/1", "Deutsch", None, None)],
            &[
                vlc(&format!("{md5}/spu/0"), "Track 1", None, None),
                vlc("spu/2", "Deutsch", Some("ger"), None),
            ],
            &streams,
            std::slice::from_ref(&file),
        );
        assert_eq!(z.subtitle, vec![Some(5), Some(2)]);
        assert_eq!(z.subtitle_position(5), Some(0));
        let without = SubtitleFile {
            attribute: None,
            ..file
        };
        let z2 = TrackMapping::compose(
            &[],
            &[
                vlc("spu/2", "D", None, None),
                vlc(&format!("{md5}/spu/0"), "T", None, None),
            ],
            &streams,
            &[without],
        );
        assert_eq!(z2.subtitle, vec![Some(2), Some(5)]);
    }

    /// TrackRuleTests.externalAddresses
    #[test]
    fn external_addresses() {
        let streams = vec![
            u(2, "ger"),
            ut(5, "eng", false, true, "subrip", None, false),
        ];
        let files = SubtitleFile::from_streams(
            &streams,
            "https://tv.example",
            Some("abc"),
            "ApiKey",
            &|_| Some("m".into()),
        );
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].index, 5);
        assert_eq!(
            files[0].address,
            "https://tv.example/Videos/x/y/Subtitles/5/0/Stream.srt?ApiKey=abc"
        );
        assert_eq!(files[0].attribute.as_deref(), Some("m"));
    }

    /// A transcode (HLS) cannot carry a text track, so the server hands it out as a file: `DeliveryMethod: External`
    /// with a `DeliveryUrl` while `IsExternal` stays false. It is a subtitle file for the player; a plain embedded
    /// track (`Embed`, no address) and a burned-in one (`Encode`) are not.
    #[test]
    fn transcode_delivers_text_track_as_file() {
        let mut served = ut(3, "eng", false, false, "subrip", None, false);
        served.delivery_method = Some("External".into());
        served.delivery_url = Some("/Videos/x/y/Subtitles/3/0/Stream.srt".into());
        let mut embed = ut(4, "eng", false, false, "subrip", None, false);
        embed.delivery_method = Some("Embed".into());
        let mut burned = ut(5, "eng", false, false, "pgssub", None, false);
        burned.delivery_method = Some("Encode".into());
        let mut no_address = ut(6, "eng", false, false, "subrip", None, false);
        no_address.delivery_method = Some("External".into());
        let streams = vec![served, embed, burned, no_address];
        let files =
            SubtitleFile::from_streams(&streams, "https://s", Some("k"), "ApiKey", &|_| None);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].index, 3);
        assert_eq!(
            files[0].address,
            "https://s/Videos/x/y/Subtitles/3/0/Stream.srt?ApiKey=k"
        );
        let for_player = SubtitleFile::for_avplayer(
            &streams,
            "x",
            Some("y"),
            "https://s",
            Some("k"),
            "ApiKey",
            false,
            true,
        );
        assert_eq!(
            for_player.iter().map(|f| f.index).collect::<Vec<_>>(),
            vec![3]
        );
    }

    /// The players of the other platforms read `IsExternal` to know a subtitle file from a track of the container. On a
    /// transcode the file the server delivers counts as a file there too (the Apple host does the same when it hands the
    /// tracks over); a track that is only embedded, burned in or without an address stays what it is.
    #[test]
    fn transcode_marks_delivered_text_tracks_as_files() {
        let mut served = ut(3, "eng", false, false, "subrip", None, false);
        served.delivery_method = Some("External".into());
        served.delivery_url = Some("/Videos/x/y/Subtitles/3/0/Stream.srt".into());
        let mut embed = ut(4, "eng", false, false, "subrip", None, false);
        embed.delivery_method = Some("Embed".into());
        let mut burned = ut(5, "eng", false, false, "pgssub", None, false);
        burned.delivery_method = Some("Encode".into());
        let mut no_address = ut(6, "eng", false, false, "subrip", None, false);
        no_address.delivery_method = Some("External".into());
        let mut streams = vec![served, embed, burned, no_address];
        crate::track_mapping::mark_delivered_files(&mut streams);
        let files: Vec<i64> = streams
            .iter()
            .filter(|s| s.is_external == Some(true))
            .filter_map(|s| s.index)
            .collect();
        assert_eq!(files, vec![3]);
    }

    /// External ASS/SSA next to the film: dropped for AVPlayer (cannot draw it), handed over for an engine that
    /// reads it itself (Apple engine); VTT and SRT are handed over either way.
    #[test]
    fn external_styled_file_goes_to_an_engine_that_reads_it() {
        let mut ass = ut(3, "deu", false, true, "ass", None, false);
        ass.delivery_url = Some("/Videos/x/y/Subtitles/3/0/Stream.ass".into());
        let mut vtt = ut(4, "eng", false, true, "webvtt", None, false);
        vtt.delivery_url = Some("/Videos/x/y/Subtitles/4/0/Stream.vtt".into());
        let srt = ut(2, "eng", false, true, "subrip", None, false);
        let streams = vec![srt, ass, vtt];
        let indices = |reads_styled| -> Vec<i64> {
            SubtitleFile::for_avplayer(
                &streams,
                "x",
                Some("y"),
                "https://s",
                Some("k"),
                "ApiKey",
                false,
                reads_styled,
            )
            .iter()
            .map(|f| f.index)
            .collect()
        };
        assert_eq!(indices(false), vec![2, 4]);
        assert_eq!(indices(true), vec![2, 3, 4]);
    }

    /// TrackRuleTests.wasDecoded
    #[test]
    fn was_decoded() {
        let json = r#"{"Id":"q","DefaultAudioStreamIndex":2,"DefaultSubtitleStreamIndex":-1,"MediaStreams":[{"Type":"Subtitle","Index":4,"IsExternal":true,"IsForced":true,"Title":"Forced","DeliveryUrl":"/Videos/a/b/Subtitles/4/0/Stream.srt"}]}"#;
        let source: swiftly_model::MediaSource = serde_json::from_str(json).expect("json");
        assert_eq!(source.default_audio_stream_index, Some(2));
        assert_eq!(source.default_subtitle_stream_index, Some(-1));
        let feed = &source.media_streams.expect("streams")[0];
        assert_eq!(
            feed.delivery_url.as_deref(),
            Some("/Videos/a/b/Subtitles/4/0/Stream.srt")
        );
        assert_eq!(feed.title.as_deref(), Some("Forced"));
        assert!(feed.is_forced == Some(true) && feed.is_external == Some(true));
    }

    /// TrackRuleTests.forcedOrOut
    #[test]
    fn forced_or_out() {
        assert_eq!(
            rule(
                &[a(1, "ger"), u(2, "ger"), uf(3, "ger")],
                None,
                None,
                false,
                ""
            ),
            Subtitle::Feed(3)
        );
        assert_eq!(
            rule(
                &[a(1, "ger"), u(2, "ger"), u(3, "eng")],
                None,
                None,
                false,
                ""
            ),
            Subtitle::Off
        );
        assert_eq!(
            rule(
                &[a(1, "ger"), uf(2, "eng"), uf(3, "ger")],
                None,
                None,
                false,
                ""
            ),
            Subtitle::Feed(3)
        );
    }

    /// TrackRuleTests.externForced
    #[test]
    fn extern_forced() {
        let s = [
            a(1, "ger"),
            u(2, "eng"),
            ut(7, "ger", true, true, "subrip", None, false),
        ];
        assert_eq!(rule(&s, None, None, false, ""), Subtitle::Feed(7));
    }

    /// TrackRuleTests.railsEpisode
    #[test]
    fn rails_episode() {
        let streams = vec![a(1, "eng"), uf(2, "ger"), u(3, "ger"), u(4, "eng")];
        let eng = imprint(&streams[3], &streams);
        assert_eq!(
            rule(&streams, Some(Choice::Track(eng)), Some(3), true, "Deutsch"),
            Subtitle::Feed(4)
        );
        assert_eq!(
            rule(&streams, Some(Choice::Off), Some(2), false, ""),
            Subtitle::Off
        );
        assert_eq!(
            rule(&streams, None, Some(4), true, "Deutsch"),
            Subtitle::Feed(3)
        );
        assert_eq!(rule(&streams, None, Some(4), false, ""), Subtitle::Feed(2));
        assert_eq!(
            rule(
                &[a(1, "ger"), u(2, "ger"), uf(3, "ger"), uf(4, "ger")],
                None,
                Some(4),
                false,
                ""
            ),
            Subtitle::Feed(4)
        );
        assert_eq!(
            rule(
                &[a(1, "ger"), uf(2, "ger"), u(4, "eng")],
                None,
                Some(4),
                true,
                "Deutsch"
            ),
            Subtitle::Feed(4)
        );
        assert_eq!(rule(&streams, None, Some(-1), false, ""), Subtitle::Feed(2));
    }

    /// TrackRuleTests.hearingImpairedNotPreferred
    #[test]
    fn hearing_impaired_not_preferred() {
        let streams = vec![
            a(1, "eng"),
            ut(2, "ger", false, false, "subrip", None, true),
            uf(3, "ger"),
            u(4, "ger"),
        ];
        assert_eq!(
            rule(&streams, None, None, true, "Deutsch"),
            Subtitle::Feed(4)
        );
        assert_eq!(
            rule(
                &[
                    a(1, "eng"),
                    ut(2, "ger", false, false, "subrip", None, true)
                ],
                None,
                None,
                true,
                "Deutsch"
            ),
            Subtitle::Feed(2)
        );
        let remembered = imprint(&streams[1], &streams);
        let next = vec![
            a(1, "eng"),
            u(2, "ger"),
            ut(3, "ger", false, false, "subrip", None, true),
        ];
        assert_eq!(
            rule(&next, Some(Choice::Track(remembered)), None, false, ""),
            Subtitle::Feed(3)
        );
    }

    /// TrackRuleTests.hearingImpairedRead
    #[test]
    fn hearing_impaired_read() {
        let feed: MediaStream = serde_json::from_str(
            r#"{"Type":"Subtitle","Index":3,"Language":"ger","IsHearingImpaired":true}"#,
        )
        .expect("json");
        assert_eq!(feed.is_hearing_impaired, Some(true));
        let without: MediaStream =
            serde_json::from_str(r#"{"Type":"Subtitle","Index":3}"#).expect("json");
        assert_eq!(without.is_hearing_impaired, None);
        let old: TrackImprint =
            serde_json::from_str(r#"{"sprache":"ger","erzwungen":false,"extern":false}"#)
                .expect("json");
        assert_eq!(old.hearing_impaired, None);
    }

    /// TrackRuleTests.toggleOut
    #[test]
    fn toggle_out() {
        assert_eq!(
            rule(
                &[a(1, "eng"), u(2, "ger"), u(3, "eng")],
                None,
                None,
                false,
                "Deutsch"
            ),
            Subtitle::Off
        );
    }

    /// TrackRuleTests.audioRule
    #[test]
    fn audio_rule() {
        let streams = vec![
            aud(1, "ger", "ac3", 6),
            aud(2, "eng", "truehd", 8),
            aud(3, "eng", "aac", 2),
        ];
        let remembered = imprint(&streams[2], &streams);
        assert_eq!(
            audio(&streams, Some(&remembered), "Deutsch", Some(1), None),
            Some(3)
        );
        assert_eq!(audio(&streams, None, "English", Some(1), None), Some(2));
        assert_eq!(audio(&streams, None, "", Some(2), None), Some(2));
        assert_eq!(audio(&streams, None, "", None, None), None);
    }

    /// TrackRuleTests.nextEpisode
    #[test]
    fn next_episode() {
        let t = |i, l, f, title: &str| ut(i, l, f, false, "subrip", Some(title), false);
        let episode1 = vec![
            a(1, "ger"),
            t(2, "ger", true, "Forced"),
            t(3, "ger", false, "Full"),
        ];
        let selected = TrackImprint::from_feed(&episode1[2], &episode1, Some("Deutsch"));
        let run = |s: &[MediaStream], ai| {
            subtitle(
                s,
                &SubtitleInput {
                    remembered: Some(Choice::Track(selected.clone())),
                    audio_index: Some(ai),
                    ..SubtitleInput::default()
                },
            )
        };
        let episode2 = vec![
            a(0, "ger"),
            t(5, "ger", false, "Full"),
            t(6, "ger", true, "Forced"),
        ];
        assert_eq!(run(&episode2, 0), Subtitle::Feed(5));
        let episode3 = vec![a(0, "ger"), uf(8, "ger"), u(9, "ger")];
        assert_eq!(run(&episode3, 0), Subtitle::Feed(9));
        let episode4 = vec![a(0, "eng"), u(8, "eng")];
        assert_eq!(run(&episode4, 0), Subtitle::Off);
    }

    /// TrackRuleTests.oldEntry
    #[test]
    fn old_entry() {
        let streams = vec![a(1, "eng"), uf(2, "ger"), u(3, "ger")];
        assert_eq!(
            rule(
                &streams,
                Some(Choice::Name("Deutsch".into())),
                None,
                false,
                ""
            ),
            Subtitle::Feed(3)
        );
        assert_eq!(
            rule(
                &streams,
                Some(Choice::Name("Deutsch Forced".into())),
                None,
                false,
                ""
            ),
            Subtitle::Feed(2)
        );
    }

    /// TrackRuleTests.memory
    #[test]
    fn memory() {
        let streams = vec![a(1, "ger"), a(2, "eng")];
        let imp = imprint(&streams[1], &streams);
        let mut subs = HashMap::from([("alt".to_owned(), "English".to_owned())]);
        let mut auds = HashMap::new();
        write_choice(&mut subs, "serie", &Choice::Off);
        write_choice(&mut auds, "serie", &Choice::Track(imp.clone()));
        write_choice(&mut subs, "film", &Choice::Track(imp.clone()));
        assert_eq!(read_choice(&subs, "serie"), Some(Choice::Off));
        assert_eq!(read_audio(&auds, "serie"), Some(imp.clone()));
        assert_eq!(read_choice(&subs, "film"), Some(Choice::Track(imp)));
        assert_eq!(
            read_choice(&subs, "alt"),
            Some(Choice::Name("English".into()))
        );
        assert_eq!(read_choice(&subs, "anderes"), None);
        assert_eq!(read_audio(&auds, "film"), None);
    }

    /// TrackRuleTests.memoryPerAccount
    #[test]
    fn memory_per_account() {
        let streams = vec![a(1, "ger"), a(2, "eng")];
        let imp = imprint(&streams[1], &streams);
        let mut subs = HashMap::from([("42".to_owned(), "English".to_owned())]);
        let mut auds = HashMap::new();
        let jelly = title_key(Some("42"), "e1", Some("user1"));
        assert_eq!(jelly, "user1|42");
        assert_eq!(
            read_choice(&subs, &jelly),
            Some(Choice::Name("English".into()))
        );
        write_choice(&mut subs, &jelly, &Choice::Off);
        assert_eq!(read_choice(&subs, &jelly), Some(Choice::Off));
        let plex = title_key(Some("42"), "e1", Some("plex-M-7"));
        assert_eq!(read_choice(&subs, &plex), None);
        write_choice(&mut auds, &plex, &Choice::Track(imp.clone()));
        assert_eq!(read_audio(&auds, &plex), Some(imp));
        assert_eq!(read_audio(&auds, &jelly), None);
        assert_eq!(title_key(Some("42"), "e1", None), "42");
    }

    /// Ordered choices from another device beat everything (TrackRule.swift:31-34).
    #[test]
    fn undecodable_default_audio() {
        let st: Vec<MediaStream> = serde_json::from_str(
            r#"[{"Index":1,"Type":"Audio","Codec":"truehd","Channels":8,"Language":"eng"},
                {"Index":2,"Type":"Audio","Codec":"ac3","Channels":6,"Language":"eng"}]"#,
        )
        .unwrap();
        assert_eq!(audio(&st, None, "", Some(1), None), Some(1));
        let no_truehd = |s: &MediaStream| s.codec.as_deref() != Some("truehd");
        assert_eq!(
            audio_decodable(&st, None, "", Some(1), None, &no_truehd),
            Some(2)
        );
        assert_eq!(
            audio_decodable(&st, None, "", Some(1), None, &|_| true),
            Some(1)
        );
        assert_eq!(
            audio_decodable(&st, None, "", Some(1), Some(1), &no_truehd),
            Some(1)
        );
        let none = |_: &MediaStream| false;
        assert_eq!(audio_decodable(&st, None, "", Some(1), None, &none), None);
    }

    #[test]
    fn ordered_choice_wins() {
        let streams = vec![a(1, "ger"), a(2, "eng"), uf(3, "ger")];
        assert_eq!(audio(&streams, None, "Deutsch", None, Some(2)), Some(2));
        assert_eq!(audio(&streams, None, "Deutsch", None, Some(9)), Some(1));
        let input = |o| SubtitleInput {
            ordered: Some(o),
            audio_index: Some(1),
            ..SubtitleInput::default()
        };
        assert_eq!(subtitle(&streams, &input(-1)), Subtitle::Off);
        assert_eq!(subtitle(&streams, &input(3)), Subtitle::Feed(3));
        let idx = start_indices(&streams, &StartInput::default());
        assert_eq!(
            idx,
            TrackIndices {
                audio: None,
                subtitle: Some(3)
            }
        );
    }
}
