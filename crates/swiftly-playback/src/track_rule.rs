//! Which audio and subtitle track is on when playback starts (JellyfinKit/TrackRule.swift).
//!
//! Decided from Jellyfin's `MediaStream`s, not from the names in the player.
//!
//! Audio, top to bottom: ordered by another device, chosen by hand for this title or series, the
//! app's audio language, the device language, the title's original-language track, the server
//! default, else the file (TrackRule.swift:8-14, with the device and original steps added). The
//! audio language "Original" ([`ORIGINAL_WISH`]) moves the original-language track in front of the
//! device language.
//!
//! Subtitles: ordered, remembered (incl. off), automatic subtitles when the audio is not in the
//! wanted language (the subtitle language from the settings, else the device language; full track
//! before SDH; on unless the settings turn it off, see [`AUTOMATIC_SUBTITLES_DEFAULT`]), the server default (any if automatic, else forced only), forced (audio language
//! first; when the device language chose the audio, in that language only), else off. Never the first track (TrackRule.swift:15-28).
//!
//! A language is a settings key ("Deutsch", what `tonSprache` and `utSprache` hold) or a locale
//! tag of the device ("de-DE"); [`in_language`] compares either with a track's language.

use std::collections::HashMap;

use swiftly_jellyfin::TrackIndices;
use swiftly_model::MediaStream;
use swiftly_rules::language;

use crate::original_audio::{canonical as canonical_code, is_original};
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

/// The two-letter code of a language in any spelling; `None` for none or an undetermined one.
fn canonical(raw: Option<&str>) -> Option<String> {
    canonical_code(raw).filter(|code| !code.is_empty())
}

/// The value of the audio language setting (`tonSprache`) that asks for the title's original language
/// instead of a fixed one. Every other value is a language key ("Deutsch"); empty is "as the file".
pub const ORIGINAL_WISH: &str = "Original";

/// Is the audio language of the settings the "Original" entry?
pub fn is_original_wish(setting: &str) -> bool {
    setting == ORIGINAL_WISH
}

/// Automatic subtitles (`utAuto`) are on until the settings turn them off: a subtitle in the wanted language starts
/// whenever the chosen audio is not in that language. The one default every host reads (a host that finds no stored
/// value passes this one); the settings core's key default is the same value (guarded by a test there).
pub const AUTOMATIC_SUBTITLES_DEFAULT: bool = true;

/// Does the title's original-language track take part in the choice?
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum OriginalStep<'a> {
    /// No: the choice is the old one (settings, then the server).
    #[default]
    Off,
    /// Yes. The title's `OriginalLanguage` when it names one; a track the server flags as original
    /// counts either way (`original_audio::is_original`).
    On(Option<&'a str>),
}

/// The languages the audio start looks for, in the order of the rule: the audio language from the
/// settings, the device language, the title's original language.
///
/// The setting value [`ORIGINAL_WISH`] is the original step moved in front of the device step (see
/// [`LanguageWishes::steps`]); a title with no track of its original language then goes on with the device
/// language and the server's default.
#[derive(Debug, Clone, Copy, Default)]
pub struct LanguageWishes<'a> {
    /// `tonSprache`: a settings key ("Deutsch"), empty for "as the file".
    pub setting: &'a str,
    /// The language of the device as the system names it ("de-DE", "pt_BR", "zh-Hans-CN"); `None`
    /// or empty when the host does not know it.
    pub device: Option<&'a str>,
    /// The original-language step.
    pub original: OriginalStep<'a>,
}

impl<'a> LanguageWishes<'a> {
    /// Only the settings: what the old app did.
    pub fn setting_only(setting: &'a str) -> Self {
        Self {
            setting,
            ..Self::default()
        }
    }

    /// The steps in the order they are tried, those without a wish left out.
    fn steps(&self) -> Vec<Step> {
        let mut steps = Vec::new();
        let original = match self.original {
            OriginalStep::On(language) => Some(language.map(str::to_owned)),
            OriginalStep::Off => None,
        };
        if is_original_wish(self.setting) {
            // "Original" asked for by the setting: first, even where the host gives no title language (a track the
            // server flags as original still counts).
            steps.push(Step::Original(original.clone().flatten()));
        } else if !self.setting.is_empty() {
            steps.push(Step::Setting(self.setting.to_owned()));
        }
        if let Some(key) = self.device.and_then(device_language_key) {
            steps.push(Step::Device(key));
        }
        if let Some(language) = original
            && !is_original_wish(self.setting)
        {
            steps.push(Step::Original(language));
        }
        steps
    }
}

/// One step of the audio rule.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Step {
    /// The language of the settings: a track whose language key is this one, as the old app compared.
    Setting(String),
    /// The language of the device: a track in this language by key or by code ([`in_language`]).
    Device(String),
    /// The track of the title's original language.
    Original(Option<String>),
}

impl Step {
    /// Does the step want this language (a settings key or a code) as it stands in a list of languages?
    fn takes_language(&self, language: &str) -> bool {
        match self {
            Self::Setting(key) => language_key(Some(language)).as_deref() == Some(key),
            Self::Device(wanted) => in_language(Some(language), wanted),
            // The key of a language ("日本語") is a name, not a code: it is compared by the code of the language.
            Self::Original(original) => {
                let code = language_code(language);
                is_original(
                    code.as_deref().or(Some(language)),
                    None,
                    original.as_deref(),
                )
            }
        }
    }

    fn takes(&self, track: &MediaStream) -> bool {
        match self {
            Self::Setting(key) => language_key(track.language.as_deref()).as_deref() == Some(key),
            Self::Device(wanted) => in_language(track.language.as_deref(), wanted),
            Self::Original(original) => {
                is_original(track.language.as_deref(), Some(track), original.as_deref())
            }
        }
    }
}

/// The two-letter code of a settings key ("日本語" gives "ja"); `None` for text that is no key of the list.
pub fn language_code(key: &str) -> Option<String> {
    language::ALL
        .iter()
        .find(|entry| entry.name == key)
        .and_then(|entry| entry.shape.iter().find_map(|shape| canonical(Some(shape))))
}

/// A language the subtitles or the audio are wanted in, and how a track is compared with it.
#[derive(Debug, Clone, Copy)]
enum Wanted<'a> {
    /// A key from the settings ("Deutsch"): by language key, as the old app compared.
    Setting(&'a str),
    /// The device language as a key or code: [`in_language`].
    Device(&'a str),
}

impl Wanted<'_> {
    fn takes(&self, track_language: Option<&str>) -> bool {
        match self {
            Self::Setting(key) => setting_takes(key, track_language),
            Self::Device(wanted) => in_language(track_language, wanted),
        }
    }
}

/// Does a track language fit a settings key? A key of the short list ("Deutsch") by language key, as the old app
/// compared; a key beyond it (the picker stores the two-letter code, "et") by code, so "est" and "et" are one
/// language.
fn setting_takes(key: &str, track_language: Option<&str>) -> bool {
    if language_key(track_language).as_deref() == Some(key) {
        return true;
    }
    let is_code = key.len() == 2 && key.bytes().all(|b| b.is_ascii_lowercase());
    is_code && canonical(track_language).as_deref() == Some(key)
}

/// The language key for a locale tag of the device: "de-DE" and "de_AT" give "Deutsch", "pt-BR"
/// gives "Português", the keys `tonSprache` and `utSprache` hold. A language the settings do not
/// list gives its two-letter code ("et"); [`in_language`] understands both. `None` for an empty or
/// undetermined tag. Needed because [`swiftly_rules::language::detected`] reads track names, not
/// locales (`detected("de")` is `None`: "de" is an ordinary word elsewhere).
pub fn device_language_key(tag: &str) -> Option<String> {
    let mut code = canonical(Some(tag))?;
    // Names the Java and Android locales still use, and Norwegian Nynorsk.
    match code.as_str() {
        "iw" => code = "he".to_owned(),
        "in" => code = "id".to_owned(),
        "nn" => code = "no".to_owned(),
        _ => {}
    }
    let listed = language::ALL.iter().find(|entry| {
        entry
            .shape
            .iter()
            .any(|shape| canonical(Some(shape)).as_deref() == Some(code.as_str()))
    });
    Some(listed.map_or(code, |entry| entry.name.to_owned()))
}

/// Is a track in `wanted`: a settings key ("Deutsch"), a locale tag ("de-DE") or any code or name
/// of the language? Unknown ("und") is in no language. Used for the device language, which is a
/// code the files spell in different ways; the settings compare by key alone, as the old app did.
pub fn in_language(track_language: Option<&str>, wanted: &str) -> bool {
    if wanted.is_empty() {
        return false;
    }
    if language_key(track_language).as_deref() == Some(wanted) {
        return true;
    }
    match (canonical(track_language), canonical(Some(wanted))) {
        (Some(own), Some(want)) => own == want,
        _ => false,
    }
}

/// Which of `languages` (settings keys or codes, for example the languages a selection of files holds) the audio rule
/// wants first, by the steps of [`audio_decodable`]: the settings, then the device, then the original language.
pub fn first_wished_language(languages: &[String], wishes: &LanguageWishes<'_>) -> Option<String> {
    wishes.steps().iter().find_map(|step| {
        languages
            .iter()
            .find(|language| step.takes_language(language))
            .cloned()
    })
}

/// The audio index to start with (TrackRule.swift:45-61), by the settings alone, as the old app did.
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
        &LanguageWishes::setting_only(preferred_language),
        server_default,
        ordered,
        &|_| true,
    )
}

/// The audio index to start with: the order of another device, the choice by hand (also from an
/// earlier episode of the series), then the languages of [`LanguageWishes`] in their order, then
/// the server's default, else `None` (the file decides). With the question "can the engine decode
/// this audio track?" (issue #50): a track it cannot decode is never chosen by memory, language or
/// server default; when the server's default is such a track, the first decodable one (same
/// language first) takes its place. An order from another device is kept.
pub fn audio_decodable(
    streams: &[MediaStream],
    remembered: Option<&TrackImprint>,
    wishes: &LanguageWishes<'_>,
    server_default: Option<i64>,
    ordered: Option<i64>,
    can_decode: &dyn Fn(&MediaStream) -> bool,
) -> Option<i64> {
    audio_pick(
        streams,
        remembered,
        wishes,
        server_default,
        ordered,
        can_decode,
    )
    .and_then(|pick| pick.index)
}

/// Which rule chose the audio track of a start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioBy {
    /// The order of another device.
    Order,
    /// The choice by hand for this title or series.
    Memory,
    /// The audio language of the settings.
    Setting,
    /// The language of the device.
    Device,
    /// The title's original language.
    Original,
    /// The server's default track.
    ServerDefault,
}

/// The audio track a start chose and the rule that chose it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioPick {
    /// Jellyfin's `Index` (`None` for a stream the file gives no index).
    pub index: Option<i64>,
    /// The rule that decided.
    pub by: AudioBy,
}

/// [`audio_decodable`] that also says which rule decided, `None` when none did (the file decides). The subtitle rule needs
/// it: a forced track of another language is only kept off when the DEVICE step chose the audio.
pub fn audio_pick(
    streams: &[MediaStream],
    remembered: Option<&TrackImprint>,
    wishes: &LanguageWishes<'_>,
    server_default: Option<i64>,
    ordered: Option<i64>,
    can_decode: &dyn Fn(&MediaStream) -> bool,
) -> Option<AudioPick> {
    let pick = |index: Option<i64>, by: AudioBy| Some(AudioPick { index, by });
    let all_tracks = tracks_of(streams, "Audio");
    if let Some(o) = ordered
        && all_tracks.iter().any(|t| t.index == Some(o))
    {
        return pick(Some(o), AudioBy::Order);
    }
    let usable: Vec<MediaStream> = streams
        .iter()
        .filter(|s| s.type_.as_deref() != Some("Audio") || can_decode(s))
        .cloned()
        .collect();
    let tracks = tracks_of(&usable, "Audio");
    if let Some(hit) = remembered.and_then(|r| r.best(&usable, "Audio")) {
        return pick(hit.index, AudioBy::Memory);
    }
    for step in wishes.steps() {
        let mut of_language = tracks.iter().copied().filter(|t| step.takes(t));
        // The language of the settings keeps what the old app did (the first track of it). The device and the original
        // language, which are new, take the main track of the language, and never a commentary or an audio description
        // that is merely the only track of it: then the next step decides.
        let (hit, by) = match step {
            Step::Setting(_) => (of_language.next(), AudioBy::Setting),
            Step::Device(_) => (
                main_track(of_language.filter(|t| !is_extra_audio(t)), server_default),
                AudioBy::Device,
            ),
            Step::Original(_) => (
                main_track(of_language.filter(|t| !is_extra_audio(t)), server_default),
                AudioBy::Original,
            ),
        };
        if let Some(hit) = hit {
            return pick(hit.index, by);
        }
    }
    if let Some(s) = server_default {
        if tracks.iter().any(|t| t.index == Some(s)) {
            return pick(Some(s), AudioBy::ServerDefault);
        }
        if let Some(lost) = all_tracks.iter().find(|t| t.index == Some(s)) {
            let key = language_key(lost.language.as_deref());
            let same = tracks
                .iter()
                .find(|t| key.is_some() && language_key(t.language.as_deref()) == key);
            return same.or(tracks.first()).map(|t| AudioPick {
                index: t.index,
                by: AudioBy::ServerDefault,
            });
        }
    }
    None
}

/// Words in the title of an audio track that mark a commentary or an audio description, not the film's own sound.
const EXTRA_AUDIO_WORDS: &[&str] = &[
    "comment",
    "kommentar",
    "commentaire",
    "comentario",
    "commento",
    "audio description",
    "audiodescription",
    "audio-description",
    "audiodeskription",
    "audio-deskription",
    "audiobeschreibung",
    "audiodescripci",
    "audiodescri\u{e7}",
    "descriptive",
    "h\u{f6}rfilm",
    "hoerfilm",
];

/// Short words that mark an audio description when they stand alone in the title ("Deutsch (AD)"), not inside another word.
const EXTRA_AUDIO_TOKENS: &[&str] = &["ad"];

/// A commentary or an audio description: by the title the file gives it, or flagged for the hearing impaired.
fn is_extra_audio(track: &MediaStream) -> bool {
    track.is_hearing_impaired == Some(true)
        || [track.title.as_deref(), track.display_title.as_deref()]
            .into_iter()
            .flatten()
            .any(|text| {
                let text = text.to_lowercase();
                EXTRA_AUDIO_WORDS.iter().any(|word| text.contains(word))
                    || text
                        .split(|c: char| !c.is_alphanumeric())
                        .any(|token| EXTRA_AUDIO_TOKENS.contains(&token))
            })
}

/// The main track among tracks of one language (the caller leaves commentaries and audio descriptions out): the one the
/// file or the server marks as default, then the one with the most channels. The first of equals.
fn main_track<'a>(
    tracks: impl Iterator<Item = &'a MediaStream>,
    server_default: Option<i64>,
) -> Option<&'a MediaStream> {
    let rank = |t: &MediaStream| {
        let default =
            t.is_default == Some(true) || (server_default.is_some() && t.index == server_default);
        (default, t.channels.unwrap_or(0))
    };
    tracks.reduce(|best, t| if rank(t) > rank(best) { t } else { best })
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
    /// The language of the device chose that audio track ([`AudioBy::Device`]): a forced track of another language then
    /// belongs to another dub. Every other start (the settings, a hand choice, the original language, the server's
    /// default, the order of another device) keeps the old app's first forced track.
    pub audio_by_device: bool,
    /// Audio language from the settings, empty for none (`tonwunsch`).
    pub audio_wish: &'a str,
    /// Subtitle language from the settings.
    pub preferred_language: &'a str,
    /// The language of the device ("de-DE"), `None` when the host does not know it. It stands in
    /// for the subtitle language from the settings when that is empty, and for the audio language
    /// when neither settings name one.
    pub device_language: Option<&'a str>,
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

    let audio_raw = streams
        .iter()
        .find(|s| {
            s.type_.as_deref() == Some("Audio")
                && s.index == input.audio_index
                && input.audio_index.is_some()
        })
        .map(|s| s.language.as_deref());
    let audio_long = audio_raw.and_then(language_key);

    // The subtitle language from the settings, else the device language.
    let device = input.device_language.and_then(device_language_key);
    let wanted = if !input.preferred_language.is_empty() {
        Some(Wanted::Setting(input.preferred_language))
    } else {
        device.as_deref().map(Wanted::Device)
    };
    if input.automatic
        && let Some(wanted) = wanted
    {
        // Without an audio preference the subtitle language counts: anyone who wants German
        // subtitles needs them with English audio. Without that too, the device language.
        // If the audio language is unknown, nothing is guessed.
        // "Original" names no language to compare with: the audio is checked against the subtitle language.
        let should = if input.audio_wish.is_empty() || is_original_wish(input.audio_wish) {
            wanted
        } else {
            Wanted::Setting(input.audio_wish)
        };
        let audio_here = audio_raw.flatten();
        // The device language only stands in for a missing setting: it never subtitles audio that
        // already plays in that language.
        if audio_long.is_some()
            && !should.takes(audio_here)
            && !(matches!(wanted, Wanted::Device(_)) && wanted.takes(audio_here))
        {
            let matching: Vec<&&MediaStream> = tracks
                .iter()
                .filter(|t| wanted.takes(t.language.as_deref()))
                .collect();
            // The full one before the forced one of the same language: anyone who wants
            // subtitles because they do not understand the audio needs everything. And the
            // ordinary one before the one for the hearing impaired.
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
    // The device language chose the audio: a forced track of another language belongs to another dub and is never taken
    // (English subtitles over a German dub); one of that language, or one that names no language (`und`, none), matches.
    // Every other start keeps the old app's first forced track.
    if input.audio_by_device {
        let own = device.as_deref();
        let matching = forced.iter().find(|t| {
            let language = t.language.as_deref();
            canonical(language).is_none() || own.is_some_and(|d| in_language(language, d))
        });
        if let Some(index) = matching.and_then(|t| t.index) {
            return Subtitle::Feed(index);
        }
    } else if let Some(index) = forced.first().and_then(|t| t.index) {
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
    /// The language of the device ("de-DE"), `None` when the host does not know it.
    pub device_language: Option<&'a str>,
    /// The original-language step of the audio choice.
    pub original: OriginalStep<'a>,
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
    let pick = audio_pick(
        streams,
        input.remembered_audio.as_ref(),
        &LanguageWishes {
            setting: input.audio_language,
            device: input.device_language,
            original: input.original,
        },
        input.server_audio,
        None,
        can_decode,
    );
    let audio_index = pick.and_then(|p| p.index);
    let choice = subtitle(
        streams,
        &SubtitleInput {
            remembered: input.remembered_subtitle.clone(),
            server_default: input.server_subtitle,
            automatic: input.automatic,
            audio_index,
            audio_by_device: pick.is_some_and(|p| p.by == AudioBy::Device),
            audio_wish: input.audio_language,
            preferred_language: input.subtitle_language,
            device_language: input.device_language,
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

    /// The bench file `bm-pgs-mkv` (forced English PGS 2, full English PGS 3, English SRT 4, one audio
    /// track without a language) with the start settings of an independent Linux check: the shared rule
    /// is the one choice every platform's player starts with.
    #[test]
    fn the_pgs_bench_file_starts_with_the_shared_rules_choice() {
        let streams = vec![
            MediaStream {
                type_: Some("Audio".into()),
                codec: Some("aac".into()),
                index: Some(1),
                ..MediaStream::default()
            },
            ut(
                2,
                "eng",
                true,
                false,
                "hdmv_pgs_subtitle",
                Some("Forced"),
                false,
            ),
            ut(3, "eng", false, false, "hdmv_pgs_subtitle", None, false),
            ut(4, "eng", false, false, "subrip", None, false),
        ];
        let start =
            |automatic: bool, subtitle_language: &'static str, device: Option<&'static str>| {
                start_indices(
                    &streams,
                    &StartInput {
                        remembered_audio: None,
                        remembered_subtitle: None,
                        server_audio: None,
                        server_subtitle: None,
                        automatic,
                        audio_language: "",
                        subtitle_language,
                        device_language: device,
                        original: OriginalStep::On(None),
                    },
                )
                .subtitle
            };
        // Forced and full English PGS and an English SRT: the rule takes the first track the
        // settings allow, the forced PGS (index 2), whatever the language setting or automatic mode says.
        assert_eq!(start(true, "en", None), Some(2));
        assert_eq!(start(true, "", None), Some(2));
        assert_eq!(start(true, "", Some("de-DE")), Some(2));
        assert_eq!(start(false, "en", None), Some(2));
        assert_eq!(start(false, "", None), Some(2));
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
                audio_by_device: false,
                audio_wish: "",
                preferred_language: wish,
                device_language: None,
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

    /// A language the picker stores by its two-letter code ("et", Estonian: beyond the short table) finds the track
    /// whatever way the file spells it; a language of the short table is still found by its key.
    #[test]
    fn a_subtitle_language_stored_as_a_code_matches_every_spelling() {
        let streams = vec![a(1, "eng"), u(2, "ger"), u(3, "est")];
        assert_eq!(rule(&streams, None, None, true, "et"), Subtitle::Feed(3));
        let streams = vec![a(1, "eng"), u(2, "ger"), u(3, "Estonian")];
        assert_eq!(rule(&streams, None, None, true, "et"), Subtitle::Feed(3));
        // The old key keeps working.
        let streams = vec![a(1, "eng"), u(2, "heb"), u(3, "est")];
        assert_eq!(rule(&streams, None, None, true, "עברית"), Subtitle::Feed(2));
        // No such track: nothing is guessed.
        assert_eq!(
            rule(&[a(1, "eng"), u(2, "ger")], None, None, true, "et"),
            Subtitle::Off
        );
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

    /// A forced track only counts in the language of the audio that plays: another language's forced track (the forced
    /// English track next to a German dub that the device language chose) is never put on.
    #[test]
    fn forced_tracks_only_in_the_audio_language_when_the_device_chose_it() {
        let by_device = |streams: &[MediaStream], server: Option<i64>| {
            subtitle(
                streams,
                &SubtitleInput {
                    audio_index: Some(1),
                    audio_by_device: true,
                    device_language: Some("de-DE"),
                    server_default: server,
                    ..SubtitleInput::default()
                },
            )
        };
        let german_dub = [a(1, "ger"), uf(2, "eng")];
        assert_eq!(by_device(&german_dub, None), Subtitle::Off);
        let german_first = [a(1, "ger"), uf(2, "eng"), uf(3, "ger")];
        assert_eq!(by_device(&german_first, None), Subtitle::Feed(3));
        // English audio an English device chose, with only a German forced track: that track belongs to the German dub.
        let english = [a(1, "eng"), uf(2, "ger")];
        let english_device = subtitle(
            &english,
            &SubtitleInput {
                audio_index: Some(1),
                audio_by_device: true,
                device_language: Some("en-US"),
                ..SubtitleInput::default()
            },
        );
        assert_eq!(english_device, Subtitle::Off);
        // A forced track the server names as default still counts: the server decided it.
        assert_eq!(by_device(&german_dub, Some(2)), Subtitle::Feed(2));
        // Without the device language (the settings chose, or nothing did) the old app's first forced track stays.
        assert_eq!(rule(&german_dub, None, None, false, ""), Subtitle::Feed(2));
        // Audio of an unknown language (the device step never chooses one): nothing to contradict, the first forced track
        // stays too.
        let unknown = [a(1, "und"), uf(2, "eng")];
        assert_eq!(rule(&unknown, None, None, false, ""), Subtitle::Feed(2));
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
            audio_decodable(
                &st,
                None,
                &LanguageWishes::default(),
                Some(1),
                None,
                &no_truehd
            ),
            Some(2)
        );
        assert_eq!(
            audio_decodable(
                &st,
                None,
                &LanguageWishes::default(),
                Some(1),
                None,
                &|_| true
            ),
            Some(1)
        );
        assert_eq!(
            audio_decodable(
                &st,
                None,
                &LanguageWishes::default(),
                Some(1),
                Some(1),
                &no_truehd
            ),
            Some(1)
        );
        let none = |_: &MediaStream| false;
        assert_eq!(
            audio_decodable(&st, None, &LanguageWishes::default(), Some(1), None, &none),
            None
        );
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

    // MARK: Start language: the table of settings x device x tracks x memory

    /// One audio row: the file's tracks (index = position + 1), what is remembered, the wishes.
    struct AudioCase {
        name: &'static str,
        /// Languages of the audio tracks, in file order.
        tracks: &'static [&'static str],
        /// A hand choice made on an earlier title of the key: the languages of its tracks and the
        /// position (0-based) of the one picked.
        remembered: Option<(&'static [&'static str], usize)>,
        setting: &'static str,
        device: Option<&'static str>,
        original: OriginalStep<'static>,
        /// The server's `DefaultAudioStreamIndex`.
        server: Option<i64>,
        /// Index (position + 1) of the track that must start, `None` = the file decides.
        expect: Option<i64>,
    }

    const NO_ORIGINAL: OriginalStep<'static> = OriginalStep::Off;
    const ORIGINAL_JA: OriginalStep<'static> = OriginalStep::On(Some("ja"));
    const ORIGINAL_UNNAMED: OriginalStep<'static> = OriginalStep::On(None);

    fn audio_streams(langs: &[&str]) -> Vec<MediaStream> {
        langs
            .iter()
            .enumerate()
            .map(|(i, l)| a(i as i64 + 1, l))
            .collect()
    }

    #[test]
    fn start_language_audio_table() {
        let cases = [
            // 1) A hand choice wins over everything, also in the next episode.
            AudioCase {
                name: "hand choice English beats setting and device",
                tracks: &["ger", "eng"],
                remembered: Some((&["ger", "eng"], 1)),
                setting: "Deutsch",
                device: Some("de-DE"),
                original: ORIGINAL_JA,
                server: Some(1),
                expect: Some(2),
            },
            AudioCase {
                name: "hand choice found again where the track moved (next episode)",
                tracks: &["eng", "ger"],
                remembered: Some((&["ger", "eng"], 1)),
                setting: "",
                device: Some("de"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(1),
            },
            // 2) The setting, before the device.
            AudioCase {
                name: "setting English beats device German",
                tracks: &["ger", "eng"],
                remembered: None,
                setting: "English",
                device: Some("de-DE"),
                original: NO_ORIGINAL,
                server: Some(1),
                expect: Some(2),
            },
            AudioCase {
                name: "setting Japanese, no such track: the device language follows",
                tracks: &["eng", "ger"],
                remembered: None,
                setting: "日本語",
                device: Some("de"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(2),
            },
            // 3) The device language (the case of the report: English file default, German device).
            AudioCase {
                name: "no setting, German device, English track first",
                tracks: &["eng", "ger"],
                remembered: None,
                setting: "",
                device: Some("de"),
                original: NO_ORIGINAL,
                server: Some(1),
                expect: Some(2),
            },
            AudioCase {
                name: "device tag with region (Apple)",
                tracks: &["eng", "ger"],
                remembered: None,
                setting: "",
                device: Some("de-AT"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(2),
            },
            AudioCase {
                name: "device tag with underscore (Linux)",
                tracks: &["eng", "deu"],
                remembered: None,
                setting: "",
                device: Some("de_DE.UTF-8"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(2),
            },
            AudioCase {
                name: "English device, English second",
                tracks: &["ger", "eng"],
                remembered: None,
                setting: "",
                device: Some("en-US"),
                original: NO_ORIGINAL,
                server: Some(1),
                expect: Some(2),
            },
            AudioCase {
                name: "Korean device: a language the settings list has, by its code",
                tracks: &["eng", "kor"],
                remembered: None,
                setting: "",
                device: Some("ko-KR"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(2),
            },
            AudioCase {
                name: "Estonian device: a language the settings do not list",
                tracks: &["eng", "est"],
                remembered: None,
                setting: "",
                device: Some("et"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(2),
            },
            AudioCase {
                name: "Chinese device with script and region",
                tracks: &["eng", "zho"],
                remembered: None,
                setting: "",
                device: Some("zh-Hans-CN"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(2),
            },
            AudioCase {
                name: "Brazilian Portuguese device",
                tracks: &["eng", "por"],
                remembered: None,
                setting: "",
                device: Some("pt-BR"),
                original: NO_ORIGINAL,
                server: None,
                expect: Some(2),
            },
            // 4) The original-language track.
            AudioCase {
                name: "no track in the device language: the original one",
                tracks: &["eng", "jpn"],
                remembered: None,
                setting: "",
                device: Some("de"),
                original: ORIGINAL_JA,
                server: Some(1),
                expect: Some(2),
            },
            AudioCase {
                name: "device unknown: the original one",
                tracks: &["eng", "jpn"],
                remembered: None,
                setting: "",
                device: None,
                original: ORIGINAL_JA,
                server: Some(1),
                expect: Some(2),
            },
            AudioCase {
                name: "setting without a track and device without a track: the original one",
                tracks: &["eng", "jpn"],
                remembered: None,
                setting: "Deutsch",
                device: Some("de"),
                original: ORIGINAL_JA,
                server: None,
                expect: Some(2),
            },
            AudioCase {
                name: "device language beats the original one",
                tracks: &["jpn", "ger"],
                remembered: None,
                setting: "",
                device: Some("de"),
                original: ORIGINAL_JA,
                server: None,
                expect: Some(2),
            },
            // 5) The server default, then the file.
            AudioCase {
                name: "title names no original: the server default",
                tracks: &["eng", "jpn"],
                remembered: None,
                setting: "",
                device: Some("de"),
                original: ORIGINAL_UNNAMED,
                server: Some(2),
                expect: Some(2),
            },
            AudioCase {
                name: "nothing matches, no server default: the file decides",
                tracks: &["eng", "jpn"],
                remembered: None,
                setting: "",
                device: Some("de"),
                original: NO_ORIGINAL,
                server: None,
                expect: None,
            },
            AudioCase {
                name: "no host language: the old rule (server default)",
                tracks: &["eng", "ger"],
                remembered: None,
                setting: "",
                device: None,
                original: NO_ORIGINAL,
                server: Some(1),
                expect: Some(1),
            },
            AudioCase {
                name: "unknown device language keeps the old rule",
                tracks: &["eng", "ger"],
                remembered: None,
                setting: "",
                device: Some(""),
                original: NO_ORIGINAL,
                server: Some(1),
                expect: Some(1),
            },
            AudioCase {
                name: "tracks of unknown language are no match",
                tracks: &["und", "eng"],
                remembered: None,
                setting: "",
                device: Some("de"),
                original: NO_ORIGINAL,
                server: None,
                expect: None,
            },
        ];
        for case in cases {
            let streams = audio_streams(case.tracks);
            let imprint = case.remembered.map(|(langs, picked)| {
                let earlier = audio_streams(langs);
                TrackImprint::from_feed(&earlier[picked], &earlier, None)
            });
            let got = audio_decodable(
                &streams,
                imprint.as_ref(),
                &LanguageWishes {
                    setting: case.setting,
                    device: case.device,
                    original: case.original,
                },
                case.server,
                None,
                &|_| true,
            );
            assert_eq!(got, case.expect, "audio: {}", case.name);
        }
    }

    #[test]
    fn start_language_audio_skips_what_the_engine_cannot_decode() {
        let streams = vec![
            aud(1, "eng", "aac", 2),
            aud(2, "ger", "truehd", 8),
            aud(3, "ger", "ac3", 6),
        ];
        let wishes = LanguageWishes {
            device: Some("de"),
            ..LanguageWishes::default()
        };
        let no_truehd = |s: &MediaStream| s.codec.as_deref() != Some("truehd");
        assert_eq!(
            audio_decodable(&streams, None, &wishes, None, None, &|_| true),
            Some(2)
        );
        assert_eq!(
            audio_decodable(&streams, None, &wishes, None, None, &no_truehd),
            Some(3)
        );
    }

    #[test]
    fn start_language_a_flagged_original_track_counts_without_a_named_language() {
        let mut streams = audio_streams(&["eng", "jpn"]);
        streams[1].is_original = Some(true);
        let on = LanguageWishes {
            original: ORIGINAL_UNNAMED,
            ..LanguageWishes::default()
        };
        assert_eq!(
            audio_decodable(&streams, None, &on, None, None, &|_| true),
            Some(2)
        );
        // The old rule (settings only) ignores the flag.
        assert_eq!(audio(&streams, None, "", None, None), None);
    }

    #[test]
    fn the_old_audio_rule_ignores_the_device() {
        // `audio` is the settings-only rule the parity tests compare with the old app.
        let streams = audio_streams(&["eng", "ger"]);
        assert_eq!(audio(&streams, None, "", Some(1), None), Some(1));
        assert_eq!(audio(&streams, None, "Deutsch", Some(1), None), Some(2));
    }

    #[test]
    fn device_language_key_maps_locales_to_the_settings_keys() {
        for (tag, key) in [
            ("de", "Deutsch"),
            ("de-DE", "Deutsch"),
            ("de_AT", "Deutsch"),
            ("de_DE.UTF-8", "Deutsch"),
            ("DE", "Deutsch"),
            ("en", "English"),
            ("en-GB", "English"),
            ("fr-CA", "Français"),
            ("es-419", "Español"),
            ("it", "Italiano"),
            ("ja-JP", "日本語"),
            ("ko", "한국어"),
            ("zh-Hant-TW", "中文"),
            ("pt-PT", "Português"),
            ("ru", "Русский"),
            ("uk", "Українська"),
            ("nb-NO", "Norsk"),
            ("nn", "Norsk"),
            ("no", "Norsk"),
            ("iw", "עברית"),
            ("he-IL", "עברית"),
            ("in", "Indonesia"),
            ("id", "Indonesia"),
            ("tr", "Türkçe"),
            ("pl-PL", "Polski"),
            ("nl-NL", "Nederlands"),
            ("sv", "Svenska"),
            ("el", "Ελληνικά"),
        ] {
            assert_eq!(device_language_key(tag).as_deref(), Some(key), "{tag}");
        }
        // Not in the settings list: the two-letter code, which `in_language` still understands.
        assert_eq!(device_language_key("et-EE").as_deref(), Some("et"));
        assert_eq!(device_language_key("is").as_deref(), Some("is"));
        // No language.
        for tag in ["", "und", "  ", "-"] {
            assert_eq!(device_language_key(tag), None, "{tag:?}");
        }
    }

    #[test]
    fn in_language_reads_keys_codes_and_names() {
        assert!(in_language(Some("ger"), "Deutsch"));
        assert!(in_language(Some("deu"), "de"));
        assert!(in_language(Some("German"), "de-DE"));
        assert!(in_language(Some("de"), "Deutsch"));
        assert!(in_language(Some("kor"), "한국어"));
        assert!(in_language(Some("est"), "et"));
        assert!(!in_language(Some("eng"), "Deutsch"));
        assert!(!in_language(Some("und"), "und"));
        assert!(!in_language(None, "de"));
        assert!(!in_language(Some("ger"), ""));
    }

    /// A language the original-language table does not list still matches in every spelling: the 2-letter form of the
    /// device against the 3-letter forms (terminology and bibliographic) a file carries, and the other way round.
    #[test]
    fn in_language_matches_two_and_three_letter_codes_of_every_language() {
        for (file, device) in [
            ("afr", "af-ZA"),
            ("swa", "sw_KE"),
            ("gle", "ga-IE"),
            ("bos", "bs"),
            ("kaz", "kk-KZ"),
            ("mlt", "mt"),
            ("alb", "sq-AL"),
            ("sqi", "sq"),
            ("arm", "hy-AM"),
            ("hye", "hy"),
            ("baq", "eu"),
            ("geo", "ka-GE"),
            ("wel", "cy-GB"),
            ("tib", "bo"),
            ("mao", "mi"),
            ("bur", "my-MM"),
            ("af", "afr"),
            ("ga", "gle"),
            ("cy", "wel"),
        ] {
            assert!(in_language(Some(file), device), "{file} against {device}");
        }
        assert!(!in_language(Some("afr"), "sw-KE"));
    }

    /// Chinese: the macrolanguage code and its varieties are one language for the device wish.
    #[test]
    fn in_language_treats_the_chinese_varieties_as_one_language() {
        for file in ["zh", "zho", "chi", "cmn", "yue"] {
            for device in ["zh", "zh-Hans-CN", "zh-TW", "zh_HK", "yue-HK", "cmn"] {
                assert!(in_language(Some(file), device), "{file} against {device}");
            }
        }
        assert!(!in_language(Some("jpn"), "zh-CN"));
    }

    #[test]
    fn device_language_key_knows_the_languages_the_settings_do_not_list() {
        assert_eq!(device_language_key("af-ZA").as_deref(), Some("af"));
        assert_eq!(device_language_key("swa").as_deref(), Some("sw"));
        assert!(device_language_key("cmn-Hans").is_some());
        assert_eq!(
            device_language_key("cmn-Hans"),
            device_language_key("zh-Hans")
        );
    }

    /// An audio track with the facts the choice among tracks of one language reads.
    fn au(
        index: i64,
        lang: &str,
        channels: i64,
        default: bool,
        title: Option<&str>,
    ) -> MediaStream {
        MediaStream {
            is_default: Some(default),
            title: title.map(str::to_owned),
            display_title: title.map(str::to_owned),
            ..aud(index, lang, "eac3", channels)
        }
    }

    /// The track the start rule takes for a German device with no setting.
    fn german_pick(streams: &[MediaStream]) -> Option<i64> {
        let wishes = LanguageWishes {
            device: Some("de-DE"),
            ..LanguageWishes::default()
        };
        audio_decodable(streams, None, &wishes, None, None, &|_| true)
    }

    /// Several tracks of the chosen language: not the commentary, then the default, then the main (most channels) track.
    #[test]
    fn among_tracks_of_the_chosen_language_the_main_one_is_taken() {
        // [ger commentary, ger main (default)] -> the main track.
        let s = [
            au(1, "ger", 2, false, Some("Kommentar")),
            au(2, "ger", 6, true, None),
        ];
        assert_eq!(german_pick(&s), Some(2));
        // The commentary first in the file, not marked default itself.
        let s = [
            au(1, "ger", 6, true, Some("Audiokommentar des Regisseurs")),
            au(2, "ger", 2, false, None),
        ];
        assert_eq!(
            german_pick(&s),
            Some(2),
            "a commentary loses even to a smaller track"
        );
        // [ger 2.0, ger 5.1 (default)] -> 5.1.
        let s = [au(1, "ger", 2, false, None), au(2, "ger", 6, true, None)];
        assert_eq!(german_pick(&s), Some(2));
        // The default flag before the channel count.
        let s = [au(1, "ger", 6, false, None), au(2, "ger", 2, true, None)];
        assert_eq!(german_pick(&s), Some(2));
        // No default flag: the main track is the one with the most channels; equals keep the first.
        let s = [
            au(1, "ger", 2, false, None),
            au(2, "ger", 6, false, None),
            au(3, "ger", 6, false, None),
        ];
        assert_eq!(german_pick(&s), Some(2));
        // An audio description, by title and by flag.
        let mut flagged = au(1, "ger", 6, true, None);
        flagged.is_hearing_impaired = Some(true);
        let s = [flagged, au(2, "ger", 2, false, None)];
        assert_eq!(german_pick(&s), Some(2));
        let s = [
            au(1, "ger", 6, true, Some("Deutsch Audiodeskription")),
            au(2, "ger", 2, false, None),
        ];
        assert_eq!(german_pick(&s), Some(2));
        // A commentary that is the only track of the language is not the language's track: the next step decides
        // (see `a_commentary_alone_in_the_device_language_is_not_chosen`).
        let s = [
            au(1, "eng", 6, true, None),
            au(2, "ger", 2, false, Some("Kommentar")),
        ];
        assert_eq!(german_pick(&s), None);
        // The server's default index counts like the flag.
        let s = [au(1, "ger", 2, false, None), au(2, "ger", 2, false, None)];
        let wishes = LanguageWishes {
            device: Some("de"),
            ..LanguageWishes::default()
        };
        assert_eq!(
            audio_decodable(&s, None, &wishes, Some(2), None, &|_| true),
            Some(2)
        );
    }

    /// The language of the settings keeps the old app's rule (the first track of the language); only the device and the
    /// original language, which are new, take the main track.
    #[test]
    fn the_settings_language_keeps_the_first_track() {
        let s = [
            au(1, "ger", 2, false, Some("Kommentar")),
            au(2, "ger", 6, true, None),
        ];
        assert_eq!(audio(&s, None, "Deutsch", None, None), Some(1));
        assert_eq!(german_pick(&s), Some(2));
        // The original language takes the main track too.
        let wishes = LanguageWishes {
            original: OriginalStep::On(Some("de")),
            ..LanguageWishes::default()
        };
        assert_eq!(
            audio_decodable(&s, None, &wishes, None, None, &|_| true),
            Some(2)
        );
    }

    /// One subtitle row.
    struct SubtitleCase {
        name: &'static str,
        /// Subtitle tracks (language, forced), index = 10 + position.
        subs: &'static [(&'static str, bool)],
        /// Language of the playing audio track (index 1).
        audio: &'static str,
        automatic: bool,
        /// `utSprache`.
        setting: &'static str,
        /// `tonSprache`.
        audio_setting: &'static str,
        device: Option<&'static str>,
        remembered: Option<Choice>,
        server: Option<i64>,
        expect: Subtitle,
    }

    #[test]
    fn start_language_subtitle_table() {
        let off = Subtitle::Off;
        let feed = |n: i64| Subtitle::Feed(10 + n);
        let cases = [
            SubtitleCase {
                name: "automatic, German device, English audio: the German track",
                subs: &[("eng", false), ("ger", false)],
                audio: "eng",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: Some("de-DE"),
                remembered: None,
                server: None,
                expect: feed(1),
            },
            SubtitleCase {
                name: "automatic, German device, German audio: none",
                subs: &[("eng", false), ("ger", false)],
                audio: "ger",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: None,
                server: None,
                expect: off,
            },
            SubtitleCase {
                name: "not automatic: the device language alone turns nothing on",
                subs: &[("ger", false)],
                audio: "eng",
                automatic: false,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: None,
                server: None,
                expect: off,
            },
            SubtitleCase {
                name: "the subtitle setting wins over the device language",
                subs: &[("eng", false), ("fre", false)],
                audio: "ger",
                automatic: true,
                setting: "Français",
                audio_setting: "",
                device: Some("de"),
                remembered: None,
                server: None,
                expect: feed(1),
            },
            SubtitleCase {
                name: "subtitle setting German, English device, English audio: German track",
                subs: &[("ger", false)],
                audio: "eng",
                automatic: true,
                setting: "Deutsch",
                audio_setting: "",
                device: Some("en"),
                remembered: None,
                server: None,
                expect: feed(0),
            },
            SubtitleCase {
                name: "device language English on English audio: no subtitle from the device",
                subs: &[("eng", false)],
                audio: "eng",
                automatic: true,
                setting: "",
                audio_setting: "Deutsch",
                device: Some("en"),
                remembered: None,
                server: None,
                expect: off,
            },
            SubtitleCase {
                name: "no device language: the old rule",
                subs: &[("ger", false)],
                audio: "eng",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: None,
                remembered: None,
                server: None,
                expect: off,
            },
            SubtitleCase {
                name: "full track before the hearing-impaired one",
                subs: &[("ger", true), ("ger", false)],
                audio: "eng",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: None,
                server: None,
                expect: feed(1),
            },
            SubtitleCase {
                name: "forced track of the audio language is on without any setting",
                subs: &[("eng", false), ("ger", true)],
                audio: "ger",
                automatic: false,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: None,
                server: None,
                expect: feed(1),
            },
            SubtitleCase {
                name: "hand choice off wins over the device language",
                subs: &[("ger", false)],
                audio: "eng",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: Some(Choice::Off),
                server: None,
                expect: off,
            },
            SubtitleCase {
                name: "hand choice name wins over the device language",
                subs: &[("eng", false), ("ger", false)],
                audio: "eng",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: Some(Choice::Name("English".into())),
                server: None,
                expect: feed(0),
            },
            SubtitleCase {
                name: "server default (any, as automatic is on) after the language step found nothing",
                subs: &[("eng", false), ("fre", false)],
                audio: "eng",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: None,
                server: Some(11),
                expect: feed(1),
            },
            SubtitleCase {
                name: "audio language unknown: nothing is guessed",
                subs: &[("ger", false)],
                audio: "und",
                automatic: true,
                setting: "",
                audio_setting: "",
                device: Some("de"),
                remembered: None,
                server: None,
                expect: off,
            },
        ];
        for case in cases {
            let mut streams = vec![a(1, case.audio)];
            for (i, (lang, forced)) in case.subs.iter().enumerate() {
                // `forced` doubles as "hearing impaired" in the SDH row: the language row decides.
                let mut s = ut(10 + i as i64, lang, *forced, false, "subrip", None, false);
                if case.name.starts_with("full track before") {
                    s.is_forced = Some(false);
                    s.is_hearing_impaired = Some(*forced);
                }
                streams.push(s);
            }
            let got = subtitle(
                &streams,
                &SubtitleInput {
                    remembered: case.remembered.clone(),
                    server_default: case.server,
                    automatic: case.automatic,
                    audio_index: Some(1),
                    audio_by_device: case.audio_setting.is_empty() && case.device.is_some(),
                    audio_wish: case.audio_setting,
                    preferred_language: case.setting,
                    device_language: case.device,
                    ordered: None,
                },
            );
            assert_eq!(got, case.expect, "subtitle: {}", case.name);
        }
    }

    /// What `start_indices` picks for a German device (no settings) over these streams.
    fn german_device_start(
        streams: &[MediaStream],
        server_audio: Option<i64>,
        original: OriginalStep<'_>,
    ) -> TrackIndices {
        start_indices(
            streams,
            &StartInput {
                device_language: Some("de-DE"),
                server_audio,
                original,
                ..StartInput::default()
            },
        )
    }

    /// Only a start the DEVICE language decided keeps a forced track of another language off: a forced German track (signs,
    /// songs) next to audio the original step or the server's default chose is still the old app's first forced track.
    #[test]
    fn a_forced_track_of_another_language_is_only_kept_off_when_the_device_step_chose_the_audio() {
        // No German track: the audio comes from the original step (French) or from the server's default (French).
        let streams = [a(1, "eng"), a(2, "fre"), uf(10, "ger")];
        let by_original = german_device_start(&streams, None, OriginalStep::On(Some("fr")));
        assert_eq!(by_original.audio, Some(2));
        assert_eq!(
            by_original.subtitle,
            Some(10),
            "the original step chose the audio"
        );
        let by_server = german_device_start(&streams, Some(2), OriginalStep::Off);
        assert_eq!(by_server.audio, Some(2));
        assert_eq!(
            by_server.subtitle,
            Some(10),
            "the server's default chose the audio"
        );
        // The device step chose the German dub: the forced English track belongs to another dub.
        let dub = [a(1, "eng"), a(2, "ger"), uf(10, "eng")];
        let by_device = german_device_start(&dub, None, OriginalStep::On(Some("en")));
        assert_eq!(by_device.audio, Some(2));
        assert_eq!(by_device.subtitle, Some(-1));
    }

    /// A forced track without a language (`und`, or none at all) counts as matching the audio the device language chose.
    #[test]
    fn an_untagged_forced_track_counts_as_matching_the_device_language_audio() {
        for language in ["und", ""] {
            let mut untagged = uf(10, language);
            if language.is_empty() {
                untagged.language = None;
            }
            let streams = [a(1, "eng"), a(2, "ger"), uf(9, "eng"), untagged];
            let got = german_device_start(&streams, None, OriginalStep::Off);
            assert_eq!(got.audio, Some(2));
            assert_eq!(got.subtitle, Some(10), "language {language:?}");
        }
    }

    /// A commentary or an audio description is never the sound a start chooses because it is the only track of the
    /// device language: the next step decides (the original language, the server's default, else the file).
    #[test]
    fn a_commentary_alone_in_the_device_language_is_not_chosen() {
        let commentary = au(2, "ger", 2, false, Some("Kommentar"));
        let streams = [au(1, "eng", 6, true, None), commentary];
        assert_eq!(german_pick(&streams), None);
        let wishes = LanguageWishes {
            device: Some("de-DE"),
            original: OriginalStep::On(Some("en")),
            ..LanguageWishes::default()
        };
        assert_eq!(
            audio_decodable(&streams, None, &wishes, None, None, &|_| true),
            Some(1)
        );
        let wishes = LanguageWishes {
            device: Some("de-DE"),
            ..LanguageWishes::default()
        };
        assert_eq!(
            audio_decodable(&streams, None, &wishes, Some(1), None, &|_| true),
            Some(1)
        );
        // Every spelling of an extra track.
        for title in [
            "Hörfilmfassung",
            "Hörfilm",
            "Deutsch (AD)",
            "German AD",
            "Audiodeskription",
            "Audio Description",
            "Director's Commentary",
            "Kommentar",
        ] {
            let streams = [
                au(1, "eng", 6, true, None),
                au(2, "ger", 2, false, Some(title)),
            ];
            assert_eq!(german_pick(&streams), None, "{title}");
        }
        // Not a commentary: words that merely contain the letters "ad", and the settings language, which keeps the old
        // app's rule (the first track of the language).
        for title in [
            "Deutsch - Dolby Digital - 5.1",
            "Head Mix",
            "Stereo Download",
        ] {
            let streams = [
                au(1, "eng", 6, true, None),
                au(2, "ger", 2, false, Some(title)),
            ];
            assert_eq!(german_pick(&streams), Some(2), "{title}");
        }
        assert_eq!(audio(&streams, None, "Deutsch", None, None), Some(2));
    }

    #[test]
    fn start_indices_carry_the_device_and_original_language() {
        let mut streams = audio_streams(&["eng", "ger"]);
        streams.push(ut(10, "ger", false, false, "subrip", None, false));
        let got = start_indices(
            &streams,
            &StartInput {
                device_language: Some("de-DE"),
                original: OriginalStep::On(Some("en")),
                ..StartInput::default()
            },
        );
        assert_eq!(
            got,
            TrackIndices {
                audio: Some(2),
                subtitle: Some(-1)
            }
        );
        let got = start_indices(
            &streams,
            &StartInput {
                device_language: Some("fr"),
                original: OriginalStep::On(Some("en")),
                automatic: true,
                ..StartInput::default()
            },
        );
        // No French track: the original (English) one; subtitles in French: none listed.
        assert_eq!(got.audio, Some(1));
    }

    // ---- "Original" as the audio language of the settings, and subtitles on by default ----

    /// A start of a German device with the settings given: `setting` is `tonSprache`, `automatic` is `utAuto`.
    fn start_with(
        streams: &[MediaStream],
        setting: &str,
        automatic: bool,
        original: OriginalStep<'_>,
    ) -> TrackIndices {
        start_indices(
            streams,
            &StartInput {
                audio_language: setting,
                device_language: Some("de-DE"),
                automatic,
                original,
                ..StartInput::default()
            },
        )
    }

    struct OriginalCase {
        name: &'static str,
        audio: &'static [&'static str],
        setting: &'static str,
        original: OriginalStep<'static>,
        /// Audio flagged as the original by the server (1-based position), if any.
        flagged: Option<usize>,
        expect: Option<i64>,
    }

    #[test]
    fn the_original_wish_puts_the_original_language_before_the_device_language() {
        let cases = [
            OriginalCase {
                name: "jpn original with a German track: Original takes the Japanese one",
                audio: &["ger", "jpn"],
                setting: "Original",
                original: ORIGINAL_JA,
                flagged: None,
                expect: Some(2),
            },
            OriginalCase {
                name: "the same title without the wish: the device language wins",
                audio: &["ger", "jpn"],
                setting: "",
                original: ORIGINAL_JA,
                flagged: None,
                expect: Some(1),
            },
            OriginalCase {
                name: "a German original: Original takes the German track",
                audio: &["eng", "ger"],
                setting: "Original",
                original: OriginalStep::On(Some("de")),
                flagged: None,
                expect: Some(2),
            },
            OriginalCase {
                name: "no track of the original language: the device language follows",
                audio: &["eng", "ger"],
                setting: "Original",
                original: OriginalStep::On(Some("fr")),
                flagged: None,
                expect: Some(2),
            },
            OriginalCase {
                name: "the host gives no title language: a track the server flags as original counts",
                audio: &["eng", "ger", "jpn"],
                setting: "Original",
                original: OriginalStep::Off,
                flagged: Some(3),
                expect: Some(3),
            },
            OriginalCase {
                name: "no title language and no flag: the device language follows",
                audio: &["eng", "ger", "jpn"],
                setting: "Original",
                original: OriginalStep::Off,
                flagged: None,
                expect: Some(2),
            },
            OriginalCase {
                name: "a language of the settings is still compared by its key",
                audio: &["ger", "jpn"],
                setting: "English",
                original: ORIGINAL_JA,
                flagged: None,
                expect: Some(1),
            },
        ];
        for case in cases {
            let mut streams = audio_streams(case.audio);
            if let Some(position) = case.flagged {
                streams[position - 1].is_original = Some(true);
            }
            let wishes = LanguageWishes {
                setting: case.setting,
                device: Some("de-DE"),
                original: case.original,
            };
            let got = audio_decodable(&streams, None, &wishes, None, None, &|_| true);
            assert_eq!(got, case.expect, "audio: {}", case.name);
        }
    }

    #[test]
    fn the_original_wish_falls_back_to_the_server_default_without_a_device_language() {
        let streams = audio_streams(&["eng", "jpn"]);
        let wishes = LanguageWishes {
            setting: ORIGINAL_WISH,
            original: OriginalStep::On(Some("fr")),
            ..LanguageWishes::default()
        };
        assert_eq!(
            audio_decodable(&streams, None, &wishes, Some(2), None, &|_| true),
            Some(2)
        );
        assert_eq!(
            audio_decodable(&streams, None, &wishes, None, None, &|_| true),
            None
        );
        // A hand choice still wins over the wish.
        let remembered = imprint(&streams[0], &streams);
        let wishes = LanguageWishes {
            setting: ORIGINAL_WISH,
            original: ORIGINAL_JA,
            ..LanguageWishes::default()
        };
        assert_eq!(
            audio_decodable(&streams, Some(&remembered), &wishes, None, None, &|_| true),
            Some(1)
        );
    }

    #[test]
    fn the_original_wish_leads_the_languages_of_a_selection() {
        let languages = vec!["Deutsch".to_owned(), "日本語".to_owned()];
        let wishes = LanguageWishes {
            setting: ORIGINAL_WISH,
            device: Some("de-DE"),
            original: ORIGINAL_JA,
        };
        assert_eq!(
            first_wished_language(&languages, &wishes).as_deref(),
            Some("日本語")
        );
        let wishes = LanguageWishes {
            setting: "",
            ..wishes
        };
        assert_eq!(
            first_wished_language(&languages, &wishes).as_deref(),
            Some("Deutsch")
        );
    }

    struct AutoCase {
        name: &'static str,
        streams: Vec<MediaStream>,
        setting: &'static str,
        automatic: bool,
        original: OriginalStep<'static>,
        audio: Option<i64>,
        subtitle: i64,
    }

    /// The German subtitle starts when the chosen audio is not German, and only then; the setting can turn it off.
    #[test]
    fn german_subtitles_start_when_the_audio_is_not_german() {
        let cases = [
            AutoCase {
                name: "German device, English-only title: German subtitle on",
                streams: vec![a(1, "eng"), u(10, "eng"), u(11, "ger")],
                setting: "",
                automatic: true,
                original: OriginalStep::On(Some("en")),
                audio: Some(1),
                subtitle: 11,
            },
            AutoCase {
                name: "German device, German track in the file: German audio, no subtitle",
                streams: vec![a(1, "eng"), a(2, "ger"), u(10, "eng"), u(11, "ger")],
                setting: "",
                automatic: true,
                original: OriginalStep::On(Some("en")),
                audio: Some(2),
                subtitle: -1,
            },
            AutoCase {
                name: "setting off (never): no subtitle with English audio",
                streams: vec![a(1, "eng"), u(10, "eng"), u(11, "ger")],
                setting: "",
                automatic: false,
                original: OriginalStep::On(Some("en")),
                audio: Some(1),
                subtitle: -1,
            },
            AutoCase {
                name: "Original on a jpn title with a German track: Japanese audio, German subtitle",
                streams: vec![a(1, "ger"), a(2, "jpn"), u(10, "ger"), u(11, "eng")],
                setting: "Original",
                automatic: true,
                original: ORIGINAL_JA,
                audio: Some(2),
                subtitle: 10,
            },
            AutoCase {
                name: "Original on a German title: German audio, no subtitle",
                streams: vec![a(1, "ger"), a(2, "eng"), u(10, "ger"), u(11, "eng")],
                setting: "Original",
                automatic: true,
                original: OriginalStep::On(Some("de")),
                audio: Some(1),
                subtitle: -1,
            },
            AutoCase {
                name: "no German subtitle in the file: none is invented",
                streams: vec![a(1, "eng"), u(11, "eng")],
                setting: "",
                automatic: true,
                original: OriginalStep::On(Some("en")),
                audio: Some(1),
                subtitle: -1,
            },
            AutoCase {
                name: "the full German track comes before the forced one and before SDH",
                streams: vec![
                    a(1, "eng"),
                    uf(10, "ger"),
                    ut(11, "ger", false, false, "subrip", None, true),
                    u(12, "ger"),
                ],
                setting: "",
                automatic: true,
                original: OriginalStep::On(Some("en")),
                audio: Some(1),
                subtitle: 12,
            },
            AutoCase {
                name: "forced rules unchanged: German audio with an English forced track stays off",
                streams: vec![a(1, "eng"), a(2, "ger"), uf(10, "eng")],
                setting: "",
                automatic: true,
                original: OriginalStep::On(Some("en")),
                audio: Some(2),
                subtitle: -1,
            },
            AutoCase {
                name: "forced rules unchanged: English audio, only a forced English track: it is taken",
                streams: vec![a(1, "eng"), uf(10, "eng")],
                setting: "",
                automatic: true,
                original: OriginalStep::On(Some("en")),
                audio: Some(1),
                subtitle: 10,
            },
        ];
        for case in cases {
            let got = start_with(&case.streams, case.setting, case.automatic, case.original);
            assert_eq!(got.audio, case.audio, "audio: {}", case.name);
            assert_eq!(got.subtitle, Some(case.subtitle), "subtitle: {}", case.name);
        }
    }

    #[test]
    fn the_subtitle_language_of_the_settings_replaces_the_device_language() {
        // English audio, a subtitle language set to French: French, not German.
        let streams = [a(1, "eng"), u(10, "ger"), u(11, "fre")];
        let got = start_indices(
            &streams,
            &StartInput {
                subtitle_language: "Français",
                device_language: Some("de-DE"),
                automatic: AUTOMATIC_SUBTITLES_DEFAULT,
                original: OriginalStep::On(Some("en")),
                ..StartInput::default()
            },
        );
        assert_eq!(got.subtitle, Some(11));
    }

    #[test]
    fn automatic_subtitles_are_on_by_default() {
        const { assert!(AUTOMATIC_SUBTITLES_DEFAULT) };
        assert!(is_original_wish("Original"));
        assert!(!is_original_wish(""));
        assert!(!is_original_wish("Deutsch"));
    }
}
