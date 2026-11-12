//! What the player should do, and why (JellyfinKit/PlaybackPlan.swift).
//!
//! Direct Play, Direct Stream, or transcode; with the never-transcode rule: without an
//! address to convert the original file plays and is called Direct Play
//! (PlaybackPlan.swift:137-142). When the server does transcode, [`TranscodeReason`] says which
//! stream is to blame (PlaybackPlan.swift:196-229).
//!
//! URLs are plain strings. UI sentences (`summary`, `TranscodeReason.text`) are catalog
//! strings and live in the l10n crate; here only the data and the German source keys.

use std::collections::HashSet;

use swiftly_model::{DeliveryMethod, MediaSource, PlaybackInfoResponse};

use crate::device_profile::{DeviceProfile, VLC_AUDIO_CODECS, VLC_VIDEO_CODECS};

/// Errors of plan building (JellyfinClient.swift:52 and the URL guard in PlaybackPlan.swift:154).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanError {
    /// The server refused with a reason: `NotAllowed`, `NoCompatibleStream`, ...
    PlaybackRejected(String),
    /// The server address could not be combined with the transcoding path.
    InvalidServerUrl,
}

/// What the player opens and how (PlaybackPlan.swift:8).
#[derive(Debug, Clone, PartialEq)]
pub struct PlaybackPlan {
    /// Address to open.
    pub url: String,
    /// Delivery method.
    pub method: DeliveryMethod,
    /// Chosen media source id.
    pub media_source_id: Option<String>,
    /// Session id for reports; `None` offline.
    pub play_session_id: Option<String>,
    /// Container of the source.
    pub container: Option<String>,
    /// Why the server transcodes; empty unless `method` is `Transcode`.
    pub reasons: Vec<TranscodeReason>,
    /// The chosen source.
    pub source: Option<MediaSource>,
    /// Video codec of a file on the device as remembered at download time
    /// (PlaybackPlan.swift:20).
    pub offline_video_codec: Option<String>,
    /// The item the plan is for; `None` for files on the device (PlaybackPlan.swift:23).
    pub item_id: Option<String>,
}

impl PlaybackPlan {
    /// Whether the delivery loses nothing (PlaybackPlan.swift:25).
    pub fn is_lossless(&self) -> bool {
        self.method.is_lossless()
    }

    /// The codec the software-decoder decision depends on: the source's video codec, else the
    /// one remembered for a downloaded file (PlaybackPlan.swift:30).
    pub fn video_codec(&self) -> Option<&str> {
        self.source
            .as_ref()
            .and_then(|s| s.video_codec())
            .or(self.offline_video_codec.as_deref())
    }

    /// Whether the player should open with the software decoder right away
    /// (PlaybackPlan.swift:29-32, `FirstFrame.softwareFromStart`).
    pub fn software_decoder(&self) -> bool {
        crate::first_frame::software_from_start(self.video_codec(), self.method)
    }

    /// A plan for a file already on the device (PlaybackPlan.swift:68-75).
    ///
    /// Direct Play without a session and without reasons: it is the unchanged original.
    pub fn from_slab(
        file: &str,
        container: Option<&str>,
        media_source_id: Option<&str>,
        video_codec: Option<&str>,
    ) -> Self {
        Self {
            url: file.to_owned(),
            method: DeliveryMethod::DirectPlay,
            media_source_id: media_source_id.map(str::to_owned),
            play_session_id: None,
            container: container.map(str::to_owned),
            reasons: Vec::new(),
            source: None,
            offline_video_codec: video_codec.map(str::to_owned),
            item_id: None,
        }
    }

    /// Builds the plan from the server response (PlaybackPlan.swift:115-173).
    ///
    /// `stream_url(item_id, source_id, play_session_id)` gives the original-file address.
    /// A named `preferred_source_id` beats the cheapest version if the server still has it.
    pub fn make<F>(
        response: &PlaybackInfoResponse,
        item_id: &str,
        profile: &DeviceProfile,
        stream_url: F,
        server_base: &str,
        preferred_source_id: Option<&str>,
    ) -> Result<Option<Self>, PlanError>
    where
        F: FnOnce(&str, Option<&str>, Option<&str>) -> Result<String, PlanError>,
    {
        let picked = preferred_source_id.and_then(|id| {
            response
                .media_sources
                .iter()
                .find(|s| s.id.as_deref() == Some(id))
        });
        let Some(source) = picked.or_else(|| best_source(&response.media_sources)) else {
            return match response.error_code.as_deref() {
                Some(reason) if !reason.is_empty() => {
                    Err(PlanError::PlaybackRejected(reason.to_owned()))
                }
                _ => Ok(None),
            };
        };

        // Without a TranscodingUrl the original plays and is called Direct Play.
        let method = if source.transcoding_url.is_none() {
            DeliveryMethod::DirectPlay
        } else {
            source.delivery_method()
        };

        let url = match (&source.transcoding_url, method) {
            (Some(path), m) if m != DeliveryMethod::DirectPlay => {
                server_relative(path, server_base).ok_or(PlanError::InvalidServerUrl)?
            }
            _ => stream_url(
                item_id,
                source.id.as_deref(),
                response.play_session_id.as_deref(),
            )?,
        };

        Ok(Some(Self {
            url,
            method,
            media_source_id: source.id.clone(),
            play_session_id: response.play_session_id.clone(),
            container: source.container.clone(),
            reasons: if method == DeliveryMethod::Transcode {
                diagnose(source, profile)
            } else {
                Vec::new()
            },
            source: Some(source.clone()),
            offline_video_codec: None,
            item_id: Some(item_id.to_owned()),
        }))
    }
}

/// The stream that stops direct playback (PlaybackPlan.swift:79).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscodeReason {
    /// Which stream.
    pub kind: ReasonKind,
    /// Codec or container name.
    pub codec: String,
    /// Extra detail.
    pub detail: Option<ReasonDetail>,
}

/// Kind of a [`TranscodeReason`] (PlaybackPlan.swift:80).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReasonKind {
    /// Video track.
    Video,
    /// Audio track.
    Audio,
    /// Subtitle track.
    Subtitle,
    /// Container.
    Container,
}

impl ReasonKind {
    /// Swift `rawValue` (an identifier; the label is a catalog string).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Video => "Video",
            Self::Audio => "Audio",
            Self::Subtitle => "Untertitel",
            Self::Container => "Container",
        }
    }
}

/// Detail of a reason; the sentences are catalog strings (PlaybackPlan.swift:205-223).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReasonDetail {
    /// "nicht im Profil deklariert" (container).
    NotDeclared,
    /// "würde eingebrannt" (subtitle).
    WouldBurnIn,
    /// "\(n) Kanäle" (audio).
    Channels(i64),
}

impl ReasonDetail {
    /// German source text, which is also the catalog key (`{n}` stands for the count).
    pub fn source_text(&self) -> &'static str {
        match self {
            Self::NotDeclared => "nicht im Profil deklariert",
            Self::WouldBurnIn => "würde eingebrannt",
            Self::Channels(_) => "{n} Kanäle",
        }
    }
}

/// The source that takes the least work; on a tie the server's order stays
/// (PlaybackPlan.swift:184-194).
pub fn best_source(sources: &[MediaSource]) -> Option<&MediaSource> {
    let mut best: Option<&MediaSource> = None;
    for s in sources {
        match best {
            Some(b) if rank(s) >= rank(b) => {}
            _ => best = Some(s),
        }
    }
    best
}

fn rank(source: &MediaSource) -> i32 {
    match source.delivery_method() {
        DeliveryMethod::DirectPlay => 0,
        DeliveryMethod::DirectStream => 1,
        DeliveryMethod::Transcode => 2,
    }
}

/// Compares the file's streams with what the profile allows (PlaybackPlan.swift:197-229).
pub fn diagnose(source: &MediaSource, profile: &DeviceProfile) -> Vec<TranscodeReason> {
    let mut found = Vec::new();

    let declared: HashSet<&str> = profile
        .direct_play_profiles
        .iter()
        .map(|p| p.container.as_str())
        .collect();
    if let Some(container) = &source.container
        && !container.split(',').any(|c| declared.contains(c))
    {
        found.push(TranscodeReason {
            kind: ReasonKind::Container,
            codec: container.clone(),
            detail: Some(ReasonDetail::NotDeclared),
        });
    }

    let subs: HashSet<&str> = profile
        .subtitle_profiles
        .iter()
        .map(|s| s.format.as_str())
        .collect();

    for stream in source.media_streams.iter().flatten() {
        let Some(codec) = stream.codec.as_deref().map(str::to_lowercase) else {
            continue;
        };
        match stream.type_.as_deref() {
            Some("Video") if !VLC_VIDEO_CODECS.contains(&codec.as_str()) => {
                found.push(TranscodeReason {
                    kind: ReasonKind::Video,
                    codec,
                    detail: None,
                });
            }
            Some("Audio") if !VLC_AUDIO_CODECS.contains(&codec.as_str()) => {
                found.push(TranscodeReason {
                    kind: ReasonKind::Audio,
                    detail: stream.channels.map(ReasonDetail::Channels),
                    codec,
                });
            }
            Some("Subtitle") if !subs.contains(codec.as_str()) => {
                found.push(TranscodeReason {
                    kind: ReasonKind::Subtitle,
                    codec,
                    detail: Some(ReasonDetail::WouldBurnIn),
                });
            }
            _ => {}
        }
    }
    found
}

/// Appends a server-relative path to the server address, keeping the address's own path
/// (ServerURL.swift:25-47).
///
/// A reverse proxy often publishes Jellyfin under a subpath; resolving per RFC 3986 would
/// drop it. A complete address (with a scheme) stays as it is. The fragment is dropped.
pub fn server_relative(detail: &str, base: &str) -> Option<String> {
    server_relative_raw(detail, base).map(|s| escape_like_foundation(&s))
}

/// What `URL(string:)` makes of the characters that may not stand in a path or query: blank,
/// control and non-ASCII characters and `" < > \ ^ ` { | }` become `%XX` (UTF-8, upper case), a `%`
/// without two hex digits behind it becomes `%25`. The part up to the end of the authority is left alone
/// (F-oracle-R02: Swift returns `absoluteString`, so a server path with a blank or umlaut came out escaped).
fn escape_like_foundation(text: &str) -> String {
    let Some(start) = text.find("://").map(|i| i + 3) else {
        return text.to_owned();
    };
    let end = text[start..]
        .find(['/', '?', '#'])
        .map_or(text.len(), |i| start + i);
    let (head, tail) = text.split_at(end);
    let bytes = tail.as_bytes();
    let mut out = String::with_capacity(text.len() + 8);
    out.push_str(head);
    for (i, &b) in bytes.iter().enumerate() {
        let hex_follows = bytes
            .get(i + 1)
            .zip(bytes.get(i + 2))
            .is_some_and(|(x, y)| x.is_ascii_hexdigit() && y.is_ascii_hexdigit());
        if (b == b'%' && !hex_follows) || b <= 0x20 || b >= 0x7F || b"\"<>\\^`{|}".contains(&b) {
            out.push_str(&format!("%{b:02X}"));
        } else {
            out.push(char::from(b));
        }
    }
    out
}

fn server_relative_raw(detail: &str, base: &str) -> Option<String> {
    if has_scheme(detail) {
        return Some(detail.to_owned());
    }
    let base_no_fragment = base.split('#').next().unwrap_or(base);
    let base_no_query = base_no_fragment
        .split('?')
        .next()
        .unwrap_or(base_no_fragment);
    if !has_scheme(base_no_query) {
        return None;
    }
    let ahead = base_no_query.trim_end_matches('/');
    let rel = detail.split('#').next().unwrap_or(detail);
    // `URLComponents(string: "//cdn.de/x")` reads "cdn.de" as the host and only the path "/x" is used (F-oracle-E07).
    let rel = match rel.strip_prefix("//") {
        Some(after) => after.find(['/', '?']).map_or("", |i| &after[i..]),
        None => rel,
    };
    let (rel_path, rel_query) = match rel.split_once('?') {
        Some((p, q)) => (p, Some(q)),
        None => (rel, None),
    };
    let behind = rel_path.trim_start_matches('/');
    let mut out = format!("{ahead}/{behind}");
    if let Some(q) = rel_query {
        out.push('?');
        out.push_str(q);
    }
    Some(out)
}

fn has_scheme(text: &str) -> bool {
    let mut chars = text.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    for c in chars {
        if c == ':' {
            return true;
        }
        if !(c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.') {
            return false;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_profile::DEFAULT_MAX_BITRATE;

    fn vlc() -> DeviceProfile {
        DeviceProfile::vlc(DEFAULT_MAX_BITRATE)
    }

    fn plan_json(json: &str) -> Result<Option<PlaybackPlan>, PlanError> {
        let answer: PlaybackInfoResponse = serde_json::from_str(json).expect("json");
        PlaybackPlan::make(
            &answer,
            "x",
            &vlc(),
            |_, _, _| Ok("http://s/x".to_owned()),
            "http://s",
            None,
        )
    }

    /// CompatibilityTests.rejected
    #[test]
    fn rejected() {
        assert!(matches!(
            plan_json(r#"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#),
            Err(PlanError::PlaybackRejected(r)) if r == "NoCompatibleStream"
        ));
        assert!(matches!(
            plan_json(r#"{"ErrorCode":"NotAllowed"}"#),
            Err(PlanError::PlaybackRejected(_))
        ));
        assert_eq!(plan_json(r#"{"MediaSources":[]}"#), Ok(None));
    }

    /// CompatibilityTests.convertForbidden
    #[test]
    fn convert_forbidden() {
        let p = plan_json(
            r#"{"MediaSources":[{"Id":"q","Container":"ogg","SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":false}],"PlaySessionId":"s"}"#,
        )
        .expect("ok")
        .expect("plan");
        assert_eq!(p.method, DeliveryMethod::DirectPlay);
        assert_eq!(p.url, "http://s/x");
    }

    /// CompatibilityTests.conversion
    #[test]
    fn conversion() {
        let p = plan_json(
            r#"{"MediaSources":[{"Id":"q","Container":"mkv","SupportsDirectPlay":false,"SupportsTranscoding":true,"TranscodingUrl":"/videos/x/master.m3u8?MediaSourceId=q"}],"PlaySessionId":"s"}"#,
        )
        .expect("ok")
        .expect("plan");
        assert_eq!(p.method, DeliveryMethod::Transcode);
        assert_eq!(p.url, "http://s/videos/x/master.m3u8?MediaSourceId=q");
    }

    /// CompatibilityTests.ogg
    #[test]
    fn ogg() {
        assert!(
            vlc()
                .direct_play_profiles
                .iter()
                .any(|p| p.container == "ogg" && p.type_ == "Video")
        );
    }

    fn src(id: &str, direct: bool, feed: bool) -> MediaSource {
        MediaSource {
            id: Some(id.to_owned()),
            name: Some(id.to_owned()),
            container: Some("mkv".to_owned()),
            size: Some(1),
            supports_direct_play: Some(direct),
            supports_direct_stream: Some(feed),
            supports_transcoding: Some(true),
            transcoding_url: Some("/t.m3u8".to_owned()),
            media_streams: Some(Vec::new()),
            ..MediaSource::default()
        }
    }

    fn plan(sources: Vec<MediaSource>) -> Option<PlaybackPlan> {
        let response = PlaybackInfoResponse {
            media_sources: sources,
            play_session_id: Some("s".to_owned()),
            error_code: None,
        };
        PlaybackPlan::make(
            &response,
            "abc",
            &vlc(),
            |id, source, _| {
                Ok(format!(
                    "https://x.de/Videos/{id}/stream?mediaSourceId={}",
                    source.unwrap_or("")
                ))
            },
            "https://x.de",
            None,
        )
        .expect("ok")
    }

    /// SourcesSelectionTests.preferredDirectPlay
    #[test]
    fn preferred_direct_play() {
        let r = plan(vec![
            src("umwandeln", false, false),
            src("direkt", true, false),
        ])
        .expect("plan");
        assert_eq!(r.method, DeliveryMethod::DirectPlay);
        assert_eq!(r.media_source_id.as_deref(), Some("direkt"));
    }

    /// SourcesSelectionTests.preferredDirectStream
    #[test]
    fn preferred_direct_stream() {
        let r = plan(vec![
            src("umwandeln", false, false),
            src("umpacken", false, true),
        ])
        .expect("plan");
        assert_eq!(r.method, DeliveryMethod::DirectStream);
        assert_eq!(r.media_source_id.as_deref(), Some("umpacken"));
    }

    /// SourcesSelectionTests.keepsRailsEpisode
    #[test]
    fn keeps_rails_episode() {
        let r = plan(vec![src("eins", true, false), src("zwei", true, false)]).expect("plan");
        assert_eq!(r.media_source_id.as_deref(), Some("eins"));
    }

    /// SourcesSelectionTests.withoutSource
    #[test]
    fn without_source() {
        assert!(plan(Vec::new()).is_none());
    }

    /// MediaVersionsTests.pickedWins
    #[test]
    fn picked_wins() {
        let response = PlaybackInfoResponse {
            media_sources: vec![src("a", true, true), src("b", true, true)],
            play_session_id: Some("s".to_owned()),
            error_code: None,
        };
        let p = PlaybackPlan::make(
            &response,
            "i",
            &vlc(),
            |_, source, _| Ok(format!("https://x/{}", source.unwrap_or(""))),
            "https://x",
            Some("b"),
        )
        .expect("ok")
        .expect("plan");
        assert_eq!(p.media_source_id.as_deref(), Some("b"));
    }

    /// DownloadRulesTests (fromSlab): the plan of a file on the device.
    #[test]
    fn from_slab_is_direct_play() {
        let p = PlaybackPlan::from_slab("/f/a.mkv", Some("mkv"), Some("q1"), Some("xvid"));
        assert_eq!(p.method, DeliveryMethod::DirectPlay);
        assert_eq!(p.media_source_id.as_deref(), Some("q1"));
        assert!(p.reasons.is_empty());
        assert!(p.play_session_id.is_none());
        assert_eq!(p.video_codec(), Some("xvid"));
    }

    /// Reasons name the stream the profile cannot take (PlaybackPlan.swift:197).
    #[test]
    fn diagnose_names_the_stream() {
        let source: MediaSource = serde_json::from_str(
            r#"{"Id":"q","Container":"xyz","MediaStreams":[
              {"Type":"Video","Codec":"bink"},
              {"Type":"Audio","Codec":"foo","Channels":6},
              {"Type":"Subtitle","Codec":"zzz"},
              {"Type":"Audio","Codec":"DTS"}]}"#,
        )
        .expect("json");
        let r = diagnose(&source, &vlc());
        let kinds: Vec<_> = r.iter().map(|x| x.kind).collect();
        assert_eq!(
            kinds,
            vec![
                ReasonKind::Container,
                ReasonKind::Video,
                ReasonKind::Audio,
                ReasonKind::Subtitle
            ]
        );
        assert_eq!(r[2].detail, Some(ReasonDetail::Channels(6)));
    }

    /// ServerURL.serverRelative keeps the proxy subpath.
    // F-oracle-R02
    #[test]
    fn server_relative_escapes_like_url() {
        assert_eq!(
            server_relative("/a b/ä?q=a b", "https://h.de/x y").as_deref(),
            Some("https://h.de/x%20y/a%20b/%C3%A4?q=a%20b")
        );
        assert_eq!(
            server_relative("/Videos/%zz", "http://server").as_deref(),
            Some("http://server/Videos/%25zz")
        );
        assert_eq!(
            server_relative("/a/%41/b", "https://h.de").as_deref(),
            Some("https://h.de/a/%41/b")
        );
        assert_eq!(
            server_relative("/a\\b", "https://h.de").as_deref(),
            Some("https://h.de/a%5Cb")
        );
        assert_eq!(
            server_relative("https://x.de/日本", "https://h.de").as_deref(),
            Some("https://x.de/%E6%97%A5%E6%9C%AC")
        );
    }

    #[test]
    fn server_relative_keeps_subpath() {
        assert_eq!(
            server_relative("/videos/x/master.m3u8?a=b", "https://h.de/jellyfin/").as_deref(),
            Some("https://h.de/jellyfin/videos/x/master.m3u8?a=b")
        );
        assert_eq!(
            server_relative("https://other/y", "https://h.de").as_deref(),
            Some("https://other/y")
        );
    }
}
