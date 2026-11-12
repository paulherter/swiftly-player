//! Which track in the player is which `MediaStream` of the server (JellyfinKit/TrackMapping.swift).
//!
//! By order per type with a cross-check (language and codec must not contradict); a count
//! mismatch assigns only what can be confirmed, the rest stays `None` (TrackMapping.swift:178-190).
//! Sideloaded subtitle files are recognised by the MD5 of their address, else by order.
//! Also: [`PlayerTrack`], [`SubtitleFile`] (external subtitle file mapping) and [`TrackImprint`].

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use swiftly_model::MediaStream;
use swiftly_rules::language;

use crate::playback_plan::server_relative;
use crate::track_label::codec_name_value;
use crate::track_rule::Subtitle;

/// An audio or subtitle track as the player lists it (TrackMapping.swift:8).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlayerTrack {
    /// libVLC-style id: `audio/1`, `spu/3`, sideloaded `<md5>/spu/0`.
    pub identifier: String,
    /// Track name.
    pub name: String,
    /// As reported: `ger`, `German` or empty.
    pub language: Option<String>,
    /// Codec in the spelling of `codec_name_value`.
    pub codec: Option<String>,
    /// Channel count.
    pub channels: Option<i64>,
}

impl PlayerTrack {
    /// Builds a track.
    pub fn new(
        identifier: &str,
        name: &str,
        language: Option<&str>,
        codec: Option<&str>,
        channels: Option<i64>,
    ) -> Self {
        Self {
            identifier: identifier.to_owned(),
            name: name.to_owned(),
            language: language.map(str::to_owned),
            codec: codec.map(str::to_owned),
            channels,
        }
    }

    /// The MD5 prefix of a sideloaded file's track id, else `None` (TrackMapping.swift:27-31).
    pub fn addition_id(&self) -> Option<&str> {
        let first = self.identifier.split('/').find(|p| !p.is_empty())?;
        // Swift `Character.isHexDigit` also accepts the full-width forms (oracle `track_mapping`).
        (first.chars().count() == 32
            && first.chars().all(|c| {
                c.is_ascii_hexdigit() || matches!(c, '０'..='９' | 'Ａ'..='Ｆ' | 'ａ'..='ｆ')
            }))
        .then_some(first)
    }

    /// Subtitles extracted from a video track (`.../cc/...`); the server does not know them
    /// (TrackMapping.swift:35).
    pub fn is_subtitle_out_image(&self) -> bool {
        self.identifier.contains("/cc/")
    }
}

/// A subtitle file next to the film that the player loads separately (TrackMapping.swift:39).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubtitleFile {
    /// Jellyfin's `Index` of the `MediaStream`.
    pub index: i64,
    /// Full address.
    pub address: String,
    /// MD5 of the address as lowercase hex; how the track is recognised in the player.
    pub attribute: Option<String>,
}

fn percent(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn with_key(address: String, key: Option<&str>, key_name: &str, replace: bool) -> String {
    let Some(key) = key else { return address };
    let (path, query) = match address.split_once('?') {
        Some((p, q)) => (p.to_owned(), q.to_owned()),
        None => (address, String::new()),
    };
    let has_key = query.split('&').any(|kv| {
        let name = kv.split('=').next().unwrap_or("").to_lowercase();
        ["apikey", "api_key", "x-plex-token"].contains(&name.as_str())
    });
    let item = format!("{key_name}={}", percent(key));
    if replace {
        return format!("{path}?{item}");
    }
    if has_key {
        return format!("{path}?{query}");
    }
    if query.is_empty() {
        format!("{path}?{item}")
    } else {
        format!("{path}?{query}&{item}")
    }
}

fn extract_url(
    server: &str,
    item_id: &str,
    source: &str,
    index: i64,
    suffix: &str,
    key: Option<&str>,
    key_name: &str,
) -> String {
    let base = server.trim_end_matches('/');
    let url = format!("{base}/Videos/{item_id}/{source}/Subtitles/{index}/0/Stream.{suffix}");
    with_key(url, key, key_name, true)
}

fn is_sub(feed: &MediaStream) -> bool {
    feed.type_.as_deref() == Some("Subtitle")
}

/// A subtitle the server hands out as its own file: a file next to the film, or (transcode/HLS, which cannot carry
/// a text track) one the server answers with `DeliveryMethod: External` and a `DeliveryUrl` while `IsExternal`
/// stays false. The old app kept only `IsExternal`; the extension is the transcode case.
fn is_file(feed: &MediaStream) -> bool {
    feed.is_external == Some(true)
        || (feed.delivery_method.as_deref() == Some("External")
            && feed.delivery_url.as_deref().is_some_and(|p| !p.is_empty()))
}

/// On a server transcode (HLS) the server delivers a text track as a file (`DeliveryMethod: External` with an address)
/// while `IsExternal` stays false. The players read `IsExternal` to tell a subtitle file from a track of the container, so
/// the streams of a transcode are marked with this before they are handed over; direct play keeps them as the server sent
/// them (there the track is in the container).
pub fn mark_delivered_files(streams: &mut [MediaStream]) {
    for feed in streams.iter_mut().filter(|f| is_sub(f) && is_file(f)) {
        feed.is_external = Some(true);
    }
}

impl SubtitleFile {
    /// The external subtitles of a source with a full address (TrackMapping.swift:56-72).
    ///
    /// `DeliveryUrl` is server-relative and carries no key; the key is appended as for the
    /// playback address.
    pub fn from_streams(
        streams: &[MediaStream],
        server: &str,
        key: Option<&str>,
        key_name: &str,
        attribute: &dyn Fn(&str) -> Option<String>,
    ) -> Vec<SubtitleFile> {
        streams
            .iter()
            .filter_map(|feed| {
                if !is_sub(feed) || !is_file(feed) {
                    return None;
                }
                let index = feed.index?;
                let path = feed.delivery_url.as_deref().filter(|p| !p.is_empty())?;
                let whole = server_relative(path, server)?;
                let address = with_key(whole, key, key_name, false);
                let attribute = attribute(&address);
                Some(SubtitleFile {
                    index,
                    address,
                    attribute,
                })
            })
            .collect()
    }

    /// Which subtitles travel with a download (TrackMapping.swift:82-100).
    ///
    /// A converted file carries only picture and sound, so embedded text subtitles are added as
    /// server-extracted files; image subtitles cannot be extracted and are missing.
    pub fn with_load(
        streams: &[MediaStream],
        item_id: &str,
        source: Option<&str>,
        server: &str,
        key: Option<&str>,
        key_name: &str,
        converted: bool,
    ) -> Vec<SubtitleFile> {
        let mut files = Self::from_streams(streams, server, key, key_name, &|_| None);
        let Some(source) = source.filter(|s| !s.is_empty()).filter(|_| converted) else {
            return files;
        };
        let already: HashSet<i64> = files.iter().map(|f| f.index).collect();
        for feed in streams {
            if !is_sub(feed) || is_file(feed) {
                continue;
            }
            let Some(index) = feed.index else { continue };
            if already.contains(&index) {
                continue;
            }
            let Some(suffix) = text_suffix(feed.codec.as_deref(), true) else {
                continue;
            };
            let address = extract_url(server, item_id, source, index, suffix, key, key_name);
            files.push(SubtitleFile {
                index,
                address,
                attribute: None,
            });
        }
        files.sort_by_key(|f| f.index);
        files
    }

    /// The subtitle files when the look decides, not the file (TrackMapping.swift:111-133):
    /// every ASS/SSA track is replaced by the server's SRT under the same index.
    pub fn as_plain_text(
        streams: &[MediaStream],
        item_id: &str,
        source: Option<&str>,
        server: &str,
        key: Option<&str>,
        key_name: &str,
        attribute: &dyn Fn(&str) -> Option<String>,
    ) -> Vec<SubtitleFile> {
        let base = Self::from_streams(streams, server, key, key_name, attribute);
        let Some(source) = source.filter(|s| !s.is_empty()) else {
            return base;
        };
        let styled: Vec<i64> = streams
            .iter()
            .filter(|f| is_sub(f) && text_suffix(f.codec.as_deref(), true) == Some("ass"))
            .filter_map(|f| f.index)
            .collect();
        if styled.is_empty() {
            return base;
        }
        let mut files: Vec<SubtitleFile> = base
            .into_iter()
            .filter(|f| !styled.contains(&f.index))
            .collect();
        for index in styled {
            let address = extract_url(server, item_id, source, index, "srt", key, key_name);
            let attribute = attribute(&address);
            files.push(SubtitleFile {
                index,
                address,
                attribute,
            });
        }
        files.sort_by_key(|f| f.index);
        files
    }

    /// The text subtitles AVPlayer's own overlay can draw, one file per text track
    /// (TrackMapping.swift:142-162). Image tracks are never in the list.
    ///
    /// `reads_styled`: the engine reads ASS/SSA files itself (the Apple engine does), so an external
    /// ASS/SSA file next to the film is handed over as it is. The old AVPlayer rule left it out because
    /// AVPlayer cannot draw it; that is no reason to drop it for an engine that can.
    #[allow(clippy::too_many_arguments)] // mirrors the Swift call, every argument is a distinct input
    pub fn for_avplayer(
        streams: &[MediaStream],
        item_id: &str,
        source: Option<&str>,
        server: &str,
        key: Option<&str>,
        key_name: &str,
        server_extracts: bool,
        reads_styled: bool,
    ) -> Vec<SubtitleFile> {
        let external = Self::from_streams(streams, server, key, key_name, &|_| None);
        let mut files = Vec::new();
        for feed in streams.iter().filter(|f| is_sub(f)) {
            let Some(index) = feed.index else { continue };
            if text_suffix(feed.codec.as_deref(), true).is_none() {
                continue;
            }
            if let (true, Some(source)) = (server_extracts, source.filter(|s| !s.is_empty())) {
                let address = extract_url(server, item_id, source, index, "srt", key, key_name);
                files.push(SubtitleFile {
                    index,
                    address,
                    attribute: None,
                });
            } else if let Some(file) = external.iter().find(|f| f.index == index) {
                let path = file.address.split('?').next().unwrap_or("");
                let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
                let codec = feed.codec.as_deref().unwrap_or("").to_lowercase();
                if reads_styled
                    || (!["ass", "ssa"].contains(&ext.as_str())
                        && !["ass", "ssa"].contains(&codec.as_str()))
                {
                    files.push(file.clone());
                }
            }
        }
        files.sort_by_key(|f| f.index);
        files
    }
}

/// The file extension in which the server outputs an embedded text subtitle, `None` for image
/// subtitles (TrackMapping.swift:168-175).
pub fn text_suffix(codec: Option<&str>, keep_file_style: bool) -> Option<&'static str> {
    match codec.map(str::to_lowercase).as_deref() {
        Some("ass" | "ssa") => Some(if keep_file_style { "ass" } else { "srt" }),
        Some(
            "subrip" | "srt" | "webvtt" | "vtt" | "mov_text" | "text" | "tx3g" | "microdvd"
            | "sami" | "smi",
        ) => Some("srt"),
        _ => None,
    }
}

/// Jellyfin index per position in the player's track lists (TrackMapping.swift:191).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TrackMapping {
    /// Jellyfin index per position in the audio list.
    pub audio: Vec<Option<i64>>,
    /// Jellyfin index per position in the subtitle list.
    pub subtitle: Vec<Option<i64>>,
}

fn of_type<'a>(
    streams: &'a [MediaStream],
    ty: &str,
    external: Option<bool>,
) -> Vec<&'a MediaStream> {
    streams
        .iter()
        .filter(|s| s.type_.as_deref() == Some(ty))
        .filter(|s| external.is_none_or(|e| (s.is_external == Some(true)) == e))
        .collect()
}

fn embedded_positions(subtitle: &[PlayerTrack]) -> Vec<usize> {
    (0..subtitle.len())
        .filter(|i| subtitle[*i].addition_id().is_none() && !subtitle[*i].is_subtitle_out_image())
        .collect()
}

impl TrackMapping {
    /// Maps the player's lists onto the server's streams (TrackMapping.swift:201-237).
    pub fn compose(
        audio: &[PlayerTrack],
        subtitle: &[PlayerTrack],
        streams: &[MediaStream],
        files: &[SubtitleFile],
    ) -> TrackMapping {
        let audio_streams = of_type(streams, "Audio", Some(false));
        let audio_indices = arrange(&audio.iter().collect::<Vec<_>>(), &audio_streams);

        let mut ut: Vec<Option<i64>> = vec![None; subtitle.len()];
        let mut opened: Vec<&SubtitleFile> = files.iter().collect();
        let mut without: Vec<usize> = Vec::new();
        for (position, track) in subtitle.iter().enumerate() {
            let Some(addition) = track.addition_id() else {
                continue;
            };
            let hit = opened.iter().position(|f| {
                f.attribute
                    .as_ref()
                    .is_some_and(|a| a.to_lowercase() == addition.to_lowercase())
            });
            match hit {
                Some(h) => ut[position] = Some(opened.remove(h).index),
                None => without.push(position),
            }
        }
        // Without attributes only if it adds up: a file that was not loaded would shift the rest.
        if !without.is_empty() && without.len() == opened.len() {
            for (position, file) in without.iter().zip(&opened) {
                ut[*position] = Some(file.index);
            }
        }

        let embedded_pos = embedded_positions(subtitle);
        let ut_streams = of_type(streams, "Subtitle", Some(false));
        let tracks: Vec<&PlayerTrack> = embedded_pos.iter().map(|p| &subtitle[*p]).collect();
        let embedded = arrange(&tracks, &ut_streams);
        for (i, position) in embedded_pos.iter().enumerate() {
            ut[*position] = embedded[i];
        }
        for position in Self::replaced_positions(subtitle, streams, files) {
            ut[position] = None;
        }
        TrackMapping {
            audio: audio_indices,
            subtitle: ut,
        }
    }

    /// Positions of embedded tracks that a side file replaces (TrackMapping.swift:242-259).
    pub fn replaced_positions(
        subtitle: &[PlayerTrack],
        streams: &[MediaStream],
        files: &[SubtitleFile],
    ) -> HashSet<usize> {
        let taken: HashSet<i64> = files.iter().map(|f| f.index).collect();
        let embedded_indices: HashSet<i64> = streams
            .iter()
            .filter(|f| is_sub(f) && f.is_external != Some(true))
            .filter_map(|f| f.index)
            .filter(|i| taken.contains(i))
            .collect();
        let mut result = HashSet::new();
        if embedded_indices.is_empty() {
            return result;
        }
        let embedded_pos = embedded_positions(subtitle);
        let ut_streams = of_type(streams, "Subtitle", Some(false));
        let tracks: Vec<&PlayerTrack> = embedded_pos.iter().map(|p| &subtitle[*p]).collect();
        let order = arrange(&tracks, &ut_streams);
        for (i, position) in embedded_pos.iter().enumerate() {
            if order[i].is_some_and(|idx| embedded_indices.contains(&idx)) {
                result.insert(*position);
            }
        }
        result
    }

    /// The wanted tracks as a position per type, before opening (TrackMapping.swift:273-286).
    pub fn start_positions(
        streams: &[MediaStream],
        audio: Option<i64>,
        subtitle: Subtitle,
        files: &[SubtitleFile],
    ) -> (Option<usize>, Option<usize>) {
        let audio_streams = of_type(streams, "Audio", Some(false));
        let ut_streams = of_type(streams, "Subtitle", Some(false));
        let audio_position =
            audio.and_then(|i| audio_streams.iter().position(|s| s.index == Some(i)));
        let mut ut_position = None;
        if let Subtitle::Feed(index) = subtitle
            && !files.iter().any(|f| f.index == index)
        {
            ut_position = ut_streams.iter().position(|s| s.index == Some(index));
        }
        (audio_position, ut_position)
    }

    /// Position of a Jellyfin audio index in the player's list.
    pub fn audio_position(&self, index: i64) -> Option<usize> {
        self.audio.iter().position(|i| *i == Some(index))
    }

    /// Position of a Jellyfin subtitle index in the player's list.
    pub fn subtitle_position(&self, index: i64) -> Option<usize> {
        self.subtitle.iter().position(|i| *i == Some(index))
    }
}

/// A list of one type: by position if everything fits, otherwise only what can be confirmed
/// (TrackMapping.swift:293-306).
fn arrange(tracks: &[&PlayerTrack], streams: &[&MediaStream]) -> Vec<Option<i64>> {
    if tracks.len() == streams.len() && tracks.iter().zip(streams).all(|(t, s)| compatible(t, s)) {
        return streams.iter().map(|s| s.index).collect();
    }
    let mut since = 0;
    tracks
        .iter()
        .map(|track| {
            let hit = (since..streams.len())
                .find(|i| compatible(track, streams[*i]) && used(track, streams[*i]))?;
            since = hit + 1;
            streams[hit].index
        })
        .collect()
}

fn compatible(track: &PlayerTrack, feed: &MediaStream) -> bool {
    if let (Some(a), Some(b)) = (
        lang(track.language.as_deref()),
        lang(feed.language.as_deref()),
    ) && a != b
    {
        return false;
    }
    if let (Some(a), Some(b)) = (&track.codec, codec_name_value(feed.codec.as_deref()))
        && *a != b
    {
        return false;
    }
    true
}

fn used(track: &PlayerTrack, feed: &MediaStream) -> bool {
    if let Some(a) = lang(track.language.as_deref())
        && Some(a) == lang(feed.language.as_deref())
    {
        return true;
    }
    if let Some(a) = &track.codec
        && Some(a) == codec_name_value(feed.codec.as_deref()).as_ref()
    {
        return true;
    }
    false
}

/// Only languages that can be recognised reliably count as a contradiction
/// (TrackMapping.swift:325-328).
fn lang(raw: Option<&str>) -> Option<&'static str> {
    let raw = raw.filter(|r| !r.is_empty())?;
    language::detected(raw)
}

/// What the next episode should recognise about a track: similarity instead of name
/// (TrackMapping.swift:337). Serialised with the German keys of the stored snapshots.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackImprint {
    /// Language as reported.
    #[serde(rename = "sprache", default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    /// Codec.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    /// Track title.
    #[serde(rename = "titel", default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Forced flag.
    #[serde(rename = "erzwungen")]
    pub forced: bool,
    /// Channel count (audio).
    #[serde(rename = "kanaele", default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<i64>,
    /// Position among the tracks of the same type at the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<i64>,
    /// External file.
    #[serde(rename = "extern")]
    pub extern_: bool,
    /// Player's track name, for information only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Hearing impaired (SDH); absent in older snapshots, where it does not count.
    #[serde(
        rename = "hoergeschaedigt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub hearing_impaired: Option<bool>,
}

impl TrackImprint {
    /// From a server stream (TrackMapping.swift:372-380).
    pub fn from_feed(feed: &MediaStream, streams: &[MediaStream], name: Option<&str>) -> Self {
        let art: Vec<&MediaStream> = streams.iter().filter(|s| s.type_ == feed.type_).collect();
        let is_audio = feed.type_.as_deref() == Some("Audio");
        Self {
            language: feed.language.clone(),
            codec: feed.codec.clone(),
            title: feed.title.clone(),
            forced: feed.is_forced == Some(true),
            channels: if is_audio { feed.channels } else { None },
            position: art.iter().position(|s| **s == *feed).map(|p| p as i64),
            extern_: feed.is_external == Some(true),
            name: name.map(str::to_owned),
            hearing_impaired: (feed.type_.as_deref() == Some("Subtitle"))
                .then_some(feed.is_hearing_impaired == Some(true)),
        }
    }

    /// From a player track that could not be assigned to a stream (TrackMapping.swift:383-388).
    pub fn from_track(track: &PlayerTrack) -> Self {
        Self {
            language: track.language.clone(),
            codec: None,
            title: None,
            forced: language::sounds_forced(&track.name),
            channels: track.channels,
            position: None,
            extern_: track.addition_id().is_some(),
            name: Some(track.name.clone()),
            hearing_impaired: None,
        }
    }

    /// The stream closest to the snapshot, or `None` (TrackMapping.swift:394-413).
    ///
    /// A remembered language must match: English is no substitute for German.
    pub fn best<'a>(&self, streams: &'a [MediaStream], art: &str) -> Option<&'a MediaStream> {
        let remembered = language_key(self.language.as_deref());
        let mut best: Option<(&MediaStream, i32)> = None;
        for (position, feed) in streams
            .iter()
            .filter(|s| s.type_.as_deref() == Some(art))
            .enumerate()
        {
            if let Some(r) = &remembered
                && language_key(feed.language.as_deref()).as_ref() != Some(r)
            {
                continue;
            }
            let mut points = if remembered.is_none() { 0 } else { 3 };
            if self
                .title
                .as_deref()
                .is_some_and(|t| !t.is_empty() && Some(t) == feed.title.as_deref())
            {
                points += 2;
            }
            if self.forced == (feed.is_forced == Some(true)) {
                points += 2;
            }
            if let Some(h) = self.hearing_impaired
                && h == (feed.is_hearing_impaired == Some(true))
            {
                points += 2;
            }
            if let Some(c) = &self.codec
                && codec_name_value(Some(c)) == codec_name_value(feed.codec.as_deref())
            {
                points += 1;
            }
            if Some(position as i64) == self.position {
                points += 1;
            }
            if let Some(ch) = self.channels
                && Some(ch) == feed.channels
            {
                points += 1;
            }
            if self.extern_ == (feed.is_external == Some(true)) {
                points += 1;
            }
            if best.is_none_or(|(_, p)| points > p) {
                best = Some((feed, points));
            }
        }
        // Without a language a chance coincidence is not enough.
        best.filter(|(_, p)| *p >= 3).map(|(f, _)| f)
    }
}

/// `ger`, `deu` and "German" are the same language (TrackMapping.swift:416-420).
pub fn language_key(raw: Option<&str>) -> Option<String> {
    let raw = raw.filter(|r| !r.is_empty())?;
    if ["und", "unknown", "mis", "zxx"].contains(&raw.to_lowercase().as_str()) {
        return None;
    }
    Some(language::detected(raw).map_or_else(|| raw.to_lowercase(), str::to_owned))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::track_label::codec_name_value_vlc_id;

    const MD5: &str = "0123456789abcdef0123456789abcdef";

    fn ut(
        index: i64,
        language: &str,
        forced: bool,
        external: bool,
        codec: &str,
        title: Option<&str>,
    ) -> MediaStream {
        MediaStream {
            codec: Some(codec.to_owned()),
            type_: Some("Subtitle".to_owned()),
            language: Some(language.to_owned()),
            index: Some(index),
            is_forced: Some(forced),
            is_external: Some(external),
            title: title.map(str::to_owned),
            delivery_url: external.then(|| format!("/Videos/x/y/Subtitles/{index}/0/Stream.srt")),
            ..MediaStream::default()
        }
    }

    fn sub(index: i64, language: &str) -> MediaStream {
        ut(index, language, false, false, "subrip", None)
    }

    fn audio(index: i64, language: &str, codec: &str, channels: i64) -> MediaStream {
        MediaStream {
            codec: Some(codec.to_owned()),
            type_: Some("Audio".to_owned()),
            language: Some(language.to_owned()),
            channels: Some(channels),
            index: Some(index),
            ..MediaStream::default()
        }
    }

    fn vlc(
        identifier: &str,
        name: &str,
        language: Option<&str>,
        codec: Option<&str>,
    ) -> PlayerTrack {
        PlayerTrack::new(identifier, name, language, codec, None)
    }

    fn file(index: i64, attribute: Option<&str>) -> SubtitleFile {
        SubtitleFile {
            index,
            address: "https://s/x.srt".to_owned(),
            attribute: attribute.map(str::to_owned),
        }
    }

    /// TrackRuleTests.startPositionsJeArt
    #[test]
    fn start_positions_per_type() {
        let streams = [
            audio(1, "ger", "aac", 2),
            audio(2, "eng", "aac", 2),
            sub(3, "ger"),
            sub(4, "eng"),
            ut(5, "fre", false, true, "subrip", None),
        ];
        let a = TrackMapping::start_positions(&streams, Some(2), Subtitle::Feed(4), &[]);
        assert_eq!(a, (Some(1), Some(1)));
        let b = TrackMapping::start_positions(&streams, None, Subtitle::Off, &[]);
        assert_eq!(b, (None, None));
        // An external file does not count when opening.
        let c = TrackMapping::start_positions(&streams, Some(1), Subtitle::Feed(5), &[]);
        assert_eq!(c, (Some(0), None));
    }

    /// TrackRuleTests.multiTrackFile: three audio and sixteen subtitles, libVLC 4 (ids are
    /// server index + 1) and libVLC 3 (ids equal the index); every position hits its own index.
    #[test]
    fn many_tracks_between_audio_tracks() {
        let audio_languages = [(1, "ger"), (7, "eng"), (13, "jpn")];
        let ut_languages = [
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
        let mut streams: Vec<MediaStream> = audio_languages
            .iter()
            .map(|(i, l)| audio(*i, l, "ac3", 6))
            .collect();
        streams.extend(
            ut_languages
                .iter()
                .map(|(i, l, c)| ut(*i, l, *i == 8, false, c, (*i == 9).then_some("SDH"))),
        );
        for (offset, name) in [(1, "libVLC 4"), (0, "libVLC 3")] {
            let audio_tracks: Vec<PlayerTrack> = audio_languages
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
            let sub_tracks: Vec<PlayerTrack> = ut_languages
                .iter()
                .map(|(i, l, c)| {
                    let id = if *c == "ass" {
                        0x2061_7373
                    } else {
                        0x7462_7573
                    };
                    let codec = codec_name_value_vlc_id(id);
                    vlc(
                        &format!("spu/{}", i + offset),
                        "Track",
                        Some(l),
                        codec.as_deref(),
                    )
                })
                .collect();
            let z = TrackMapping::compose(&audio_tracks, &sub_tracks, &streams, &[]);
            let want_audio: Vec<Option<i64>> = audio_languages.iter().map(|a| Some(a.0)).collect();
            let want_sub: Vec<Option<i64>> = ut_languages.iter().map(|a| Some(a.0)).collect();
            assert_eq!(z.audio, want_audio, "{name}");
            assert_eq!(z.subtitle, want_sub, "{name}");
            // And backwards, as choosing by server index needs it.
            for (position, entry) in ut_languages.iter().enumerate() {
                assert_eq!(
                    z.subtitle_position(entry.0),
                    Some(position),
                    "{name} index {}",
                    entry.0
                );
            }
        }
    }

    /// TrackRuleTests.sameNames: the position decides, not the name.
    #[test]
    fn same_names_map_by_position() {
        let streams = [
            audio(1, "ger", "aac", 2),
            ut(2, "ger", true, false, "subrip", None),
            sub(3, "ger"),
        ];
        let z = TrackMapping::compose(
            &[vlc("audio/1", "Deutsch", Some("ger"), Some("AAC"))],
            &[
                vlc("spu/2", "Deutsch", Some("ger"), None),
                vlc("spu/3", "Deutsch", Some("ger"), None),
            ],
            &streams,
            &[],
        );
        assert_eq!(z.audio, [Some(1)]);
        assert_eq!(z.subtitle, [Some(2), Some(3)]);
    }

    /// TrackRuleTests.countSoftOff: with a differing count only what is confirmed is assigned.
    #[test]
    fn count_mismatch_assigns_only_confirmed() {
        // VLC leaves out the middle track.
        let streams = [
            audio(1, "ger", "dts", 2),
            audio(2, "eng", "truehd", 2),
            audio(3, "jpn", "aac", 2),
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
        assert_eq!(z.audio, [Some(1), Some(3)]);
        // Nothing to match: better nothing than a guess.
        let without = TrackMapping::compose(
            &[vlc("audio/1", "Spur 1", None, None)],
            &[],
            &[audio(1, "ger", "aac", 2), audio(2, "eng", "aac", 2)],
            &[],
        );
        assert_eq!(without.audio, [None]);
    }

    /// TrackRuleTests.contradiction: a contradicting language is not mapped blindly by position.
    #[test]
    fn cross_check_mismatch_is_left_open() {
        let streams = [sub(3, "eng"), sub(4, "ger")];
        let z = TrackMapping::compose(
            &[],
            &[vlc("spu/4", "Deutsch", Some("ger"), None)],
            &[sub(4, "ger")],
            &[],
        );
        assert_eq!(z.subtitle, [Some(4)]);
        let swapped = TrackMapping::compose(
            &[],
            &[
                vlc("spu/1", "German", Some("German"), None),
                vlc("spu/2", "English", Some("eng"), None),
            ],
            &streams,
            &[],
        );
        assert_eq!(swapped.subtitle, [Some(4), None]);
    }

    /// TrackRuleTests.externalTrack: a side file through the MD5 of its address, separate from
    /// the embedded ones; without an attribute by order, if it adds up.
    #[test]
    fn sideloaded_file_by_md5_of_its_address() {
        let streams = [
            audio(1, "ger", "aac", 2),
            ut(2, "ger", true, false, "subrip", None),
            ut(5, "eng", false, true, "subrip", None),
        ];
        let files = [file(5, Some(MD5))];
        let z = TrackMapping::compose(
            &[vlc("audio/1", "Deutsch", None, None)],
            &[
                vlc(&format!("{MD5}/spu/0"), "Track 1", None, None),
                vlc("spu/2", "Deutsch", Some("ger"), None),
            ],
            &streams,
            &files,
        );
        assert_eq!(z.subtitle, [Some(5), Some(2)]);
        assert_eq!(z.subtitle_position(5), Some(0));

        let z2 = TrackMapping::compose(
            &[],
            &[
                vlc("spu/2", "D", None, None),
                vlc(&format!("{MD5}/spu/0"), "T", None, None),
            ],
            &streams,
            &[file(5, None)],
        );
        assert_eq!(z2.subtitle, [Some(2), Some(5)]);
    }

    #[test]
    fn sideloaded_id_is_case_insensitive_and_unmatched_stays_open() {
        let streams = [sub(2, "ger"), ut(5, "eng", false, true, "subrip", None)];
        let upper = MD5.to_uppercase();
        let z = TrackMapping::compose(
            &[],
            &[vlc(&format!("{MD5}/spu/0"), "T", None, None)],
            &streams,
            &[file(5, Some(&upper))],
        );
        assert_eq!(z.subtitle, [Some(5)]);
        // Two side tracks but one known file: it does not add up, so the unknown stays open.
        let z = TrackMapping::compose(
            &[],
            &[
                vlc("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/spu/0", "A", None, None),
                vlc("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/spu/0", "B", None, None),
            ],
            &streams,
            &[file(5, None)],
        );
        assert_eq!(z.subtitle, [None, None]);
    }

    #[test]
    fn addition_id_needs_32_hex_characters() {
        assert_eq!(
            vlc(&format!("{MD5}/spu/0"), "", None, None).addition_id(),
            Some(MD5)
        );
        assert_eq!(vlc("spu/3", "", None, None).addition_id(), None);
        assert_eq!(
            vlc("0123456789abcdef0123456789abcdeg/spu/0", "", None, None).addition_id(),
            None
        );
        assert_eq!(vlc("0123/spu/0", "", None, None).addition_id(), None);
    }

    /// Subtitles extracted from the video (`/cc/`) are unknown to the server and stay out of the
    /// order mapping, so the embedded ones keep their positions.
    #[test]
    fn closed_caption_tracks_are_not_mapped() {
        let streams = [sub(2, "ger"), sub(3, "eng")];
        let tracks = [
            vlc("spu/0", "A", Some("ger"), None),
            vlc("cc/0", "Closed captions 1", None, None),
            vlc("video/0/cc/1", "Closed captions 2", None, None),
            vlc("spu/1", "B", Some("eng"), None),
        ];
        assert!(tracks[2].is_subtitle_out_image());
        assert!(!tracks[1].is_subtitle_out_image() || tracks[1].identifier.contains("/cc/"));
        let z = TrackMapping::compose(&[], &tracks, &streams, &[]);
        assert_eq!(z.subtitle[0], Some(2));
        assert_eq!(z.subtitle[2], None);
        assert_eq!(z.subtitle[3], Some(3));
    }

    /// TrackRuleTests.externalAddresses: addresses come from the server, with the key.
    #[test]
    fn side_file_addresses_come_from_the_server_with_key() {
        let streams = [sub(2, "ger"), ut(5, "eng", false, true, "subrip", None)];
        let files = SubtitleFile::from_streams(
            &streams,
            "https://tv.example",
            Some("abc"),
            "ApiKey",
            &|_| Some("m".to_owned()),
        );
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].index, 5);
        assert_eq!(
            files[0].address,
            "https://tv.example/Videos/x/y/Subtitles/5/0/Stream.srt?ApiKey=abc"
        );
        assert_eq!(files[0].attribute.as_deref(), Some("m"));
    }

    fn plain(index: i64, codec: &str, external: bool, path: Option<&str>) -> MediaStream {
        MediaStream {
            codec: Some(codec.to_owned()),
            type_: Some("Subtitle".to_owned()),
            language: Some("eng".to_owned()),
            index: Some(index),
            is_external: Some(external),
            delivery_url: path.map(str::to_owned),
            ..MediaStream::default()
        }
    }

    /// SubtitleLookTests.replacesAss / withoutSource
    #[test]
    fn ass_is_replaced_by_srt_with_the_same_index() {
        let streams = [
            plain(2, "ass", false, None),
            plain(3, "subrip", false, None),
            plain(4, "ssa", true, Some("/x/4.ssa")),
            plain(5, "srt", true, Some("/x/5.srt")),
        ];
        let none = |_: &str| None;
        let files = SubtitleFile::as_plain_text(
            &streams,
            "I",
            Some("S"),
            "https://s.example",
            Some("K"),
            "ApiKey",
            &none,
        );
        assert_eq!(files.iter().map(|f| f.index).collect::<Vec<_>>(), [2, 4, 5]);
        assert_eq!(
            files[0].address,
            "https://s.example/Videos/I/S/Subtitles/2/0/Stream.srt?ApiKey=K"
        );
        assert_eq!(
            files[1].address,
            "https://s.example/Videos/I/S/Subtitles/4/0/Stream.srt?ApiKey=K"
        );
        assert!(files[2].address.contains("/x/5.srt"));
        let without = SubtitleFile::as_plain_text(
            &[plain(2, "ass", false, None)],
            "I",
            None,
            "https://s.example",
            None,
            "ApiKey",
            &none,
        );
        assert!(without.is_empty());
    }

    /// SubtitleLookTests.hidesEmbedded: the embedded ASS track is replaced by the file.
    #[test]
    fn embedded_ass_track_is_replaced_by_the_file() {
        let streams = [
            plain(2, "ass", false, None),
            plain(3, "subrip", false, None),
        ];
        let files = SubtitleFile::as_plain_text(
            &streams,
            "I",
            Some("S"),
            "https://s.example",
            Some("K"),
            "ApiKey",
            &|_| Some(MD5.to_owned()),
        );
        let tracks = [
            vlc("spu/0", "A", Some("eng"), None),
            vlc("spu/1", "B", Some("eng"), None),
            vlc(&format!("{MD5}/spu/0"), "S", None, Some("subrip")),
        ];
        let map = TrackMapping::compose(&[], &tracks, &streams, &files);
        assert_eq!(map.subtitle, [None, Some(3), Some(2)]);
        assert_eq!(map.subtitle_position(2), Some(2));
        assert_eq!(
            TrackMapping::replaced_positions(&tracks, &streams, &files),
            HashSet::from([0])
        );
    }

    /// SubtitleLookTests.startSkipsReplaced
    #[test]
    fn start_skips_a_replaced_track() {
        let streams = [
            plain(2, "ass", false, None),
            plain(3, "subrip", false, None),
        ];
        let files = [file(2, None)];
        assert_eq!(
            TrackMapping::start_positions(&streams, None, Subtitle::Feed(2), &files).1,
            None
        );
        assert_eq!(
            TrackMapping::start_positions(&streams, None, Subtitle::Feed(3), &files).1,
            Some(1)
        );
        assert_eq!(
            TrackMapping::start_positions(&streams, None, Subtitle::Feed(2), &[]).1,
            Some(0)
        );
    }
}
