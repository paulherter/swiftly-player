//! **Playback addresses and plans for Plex, as pure functions** (`PlexPlayback.swift`).
//!
//! Swiftly does not transcode on its own, and Plex makes that easy: the original file is at `Part.key`,
//! and a request with the token in the query is served as a plain ranged download (measured:
//! `206`). So the plan is always direct play and there is no `decision` call and no transcode
//! session. (`/photo/:/transcode` exists, but only scales pictures.) One exception:
//! [`PlexPlayback::transcode_plan`] for a title the device would show wrong (AV1 Dolby Vision 10.0).

use swiftly_model::DeliveryMethod;
use swiftly_playback::playback_plan::{PlaybackPlan, ReasonKind, TranscodeReason};
use url::Url;

use crate::identity::PlexError;
use crate::mapping::PlexMapper;
use crate::wire::{PlexMedia, PlexMetadata, PlexPart, PlexStream};

/// Address builder and plan maker for one server address and token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexPlayback {
    /// The server address.
    pub base: Url,
    /// The token for the query.
    pub token: String,
}

/// The state a `/:/timeline` report names (PlexPlayback.swift:~115).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimelineState {
    /// Playing.
    Playing,
    /// Paused.
    Paused,
    /// Buffering.
    Buffering,
    /// Stopped.
    Stopped,
}

impl TimelineState {
    /// The query value.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Playing => "playing",
            Self::Paused => "paused",
            Self::Buffering => "buffering",
            Self::Stopped => "stopped",
        }
    }
}

/// One file of a title: a part with the media (version) it belongs to (PlexPlayback.swift:146).
#[derive(Debug, Clone, PartialEq)]
pub struct PlexFile {
    /// The version.
    pub media: PlexMedia,
    /// The file.
    pub part: PlexPart,
    /// 1 for the first part of a version.
    pub number: i64,
    /// `MediaSource.id` of this file.
    pub source_id: String,
}

/// What Swift's `URL(string:)` does to text that is not a valid address yet: a space and a `%` that does not start an
/// escape become `%20` / `%25` (the `url` crate would drop a trailing space and keep the bare `%`).
pub(crate) fn escape_stray(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut start = 0;
    for (i, &c) in b.iter().enumerate() {
        let stray = c == b'%'
            && !(i + 2 < b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit());
        if c == b' ' || stray {
            out.push_str(&text[start..i]);
            out.push_str(if c == b' ' { "%20" } else { "%25" });
            start = i + 1;
        }
    }
    out.push_str(&text[start..]);
    out
}

impl PlexPlayback {
    /// An address builder.
    pub fn new(base: Url, token: &str) -> Self {
        Self {
            base,
            token: token.into(),
        }
    }

    /// Escapes everything but the unreserved characters (`escape`, PlexPlayback.swift:~125).
    pub fn escape(text: &str) -> String {
        let mut out = String::with_capacity(text.len());
        for b in text.bytes() {
            if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
                out.push(b as char);
            } else {
                out.push_str(&format!("%{b:02X}"));
            }
        }
        out
    }

    /// `base` + path + query. The path may contain `:` (`/:/timeline`), so the text is joined
    /// by hand (PlexPlayback.swift:23).
    pub fn url(&self, path: &str, query: &[(String, String)], with_token: bool) -> Option<Url> {
        let mut text = self.base.as_str().trim_end_matches('/').to_string();
        if !path.starts_with('/') {
            text.push('/');
        }
        text.push_str(path);
        let mut pairs: Vec<(String, String)> = query.to_vec();
        if with_token {
            pairs.push(("X-Plex-Token".into(), self.token.clone()));
        }
        if !pairs.is_empty() {
            text.push('?');
            text.push_str(
                &pairs
                    .iter()
                    .map(|(k, v)| format!("{}={}", Self::escape(k), Self::escape(v)))
                    .collect::<Vec<_>>()
                    .join("&"),
            );
        }
        Url::parse(&escape_stray(&text)).ok()
    }

    /// The file itself. For a player this is the address: it cannot set headers, so the token
    /// goes in the query (:38).
    pub fn file_url(&self, part_key: &str, download: bool) -> Option<Url> {
        let query = if download {
            vec![("download".to_string(), "1".to_string())]
        } else {
            vec![]
        };
        self.url(part_key, &query, true)
    }

    /// A subtitle next to the file (`Stream.key`); a track inside the container has none
    /// (:45).
    pub fn subtitle_url(&self, stream: &PlexStream) -> Option<Url> {
        if stream.stream_type != 3 {
            return None;
        }
        self.url(stream.key.as_deref()?, &[], true)
    }

    /// A picture, scaled by the server when a size is given. `path` is what Plex wrote in
    /// `thumb` / `art`; a person's `thumb` is already an absolute address and stays one (:53).
    pub fn image_url(
        &self,
        path: &str,
        max_height: Option<i64>,
        max_width: Option<i64>,
    ) -> Option<Url> {
        if path.starts_with("http://") || path.starts_with("https://") {
            return Url::parse(path).ok();
        }
        if max_height.is_none() && max_width.is_none() {
            return self.url(path, &[], true);
        }
        // Measured: the scaler answers `400` unless both `width` and `height` are given, and
        // with `minSize=1` it covers the box instead of fitting into it. So: no `minSize`, and
        // the side the caller left open gets a limit no picture reaches.
        let open = 4096;
        let query = vec![
            ("url".to_string(), path.to_string()),
            ("upscale".into(), "0".into()),
            ("width".into(), max_width.unwrap_or(open).to_string()),
            ("height".into(), max_height.unwrap_or(open).to_string()),
            ("quality".into(), "90".into()),
        ];
        self.url("/photo/:/transcode", &query, true)
    }

    /// Preview pictures when scrubbing: the BIF file of a part (`404` if the server has not
    /// made them) (:68).
    pub fn preview_index_url(&self, part_id: i64) -> Option<Url> {
        self.url(&format!("/library/parts/{part_id}/indexes/sd"), &[], true)
    }

    /// Picks the version and builds the direct play plan (:80). `media_source_id` is the
    /// version the user chose; without it (or with an unknown one) the first file.
    pub fn plan(
        &self,
        metadata: &PlexMetadata,
        media_source_id: Option<&str>,
        audio_stream_id: Option<i64>,
        subtitle_stream_id: Option<i64>,
        session_id: &str,
    ) -> Result<PlaybackPlan, PlexError> {
        let file = Self::file(metadata, media_source_id).ok_or(PlexError::NoFile)?;
        let address = self
            .file_url(&file.part.key, false)
            .ok_or(PlexError::NoFile)?;
        let mut source = PlexMapper::new().media_source(&file, metadata.duration);
        // The caller's choice becomes the source's default, so the player starts on it.
        if let Some(a) = audio_stream_id {
            source.default_audio_stream_index = Some(a);
        }
        if let Some(s) = subtitle_stream_id {
            source.default_subtitle_stream_index = Some(s);
        }
        Ok(PlaybackPlan {
            url: address.to_string(),
            method: DeliveryMethod::DirectPlay,
            media_source_id: Some(file.source_id.clone()),
            play_session_id: Some(session_id.to_string()),
            container: file
                .part
                .container
                .clone()
                .or_else(|| file.media.container.clone()),
            reasons: vec![],
            source: Some(source),
            offline_video_codec: None,
            item_id: None,
        })
    }

    /// The universal transcoder's HLS address for one file: the server converts the video (tone
    /// mapped, no Dolby Vision) and the player opens it like any stream. `identity` are the
    /// `X-Plex-*` client fields as query pairs, because a player cannot set headers. `None` when
    /// the file has no place in the metadata.
    pub fn transcode_url(
        &self,
        metadata: &PlexMetadata,
        file: &PlexFile,
        session_id: &str,
        identity: &[(String, String)],
    ) -> Option<Url> {
        let media_index = metadata.media.iter().position(|m| m.id == file.media.id)?;
        let part_index = usize::try_from(file.number - 1).ok()?;
        let mut query = crate::PlexDecision::transcode_query(
            &metadata.rating_key,
            media_index,
            part_index,
            session_id,
        );
        query.extend(identity.iter().cloned());
        self.url("/video/:/transcode/universal/start.m3u8", &query, true)
    }

    /// The plan for the same file as a server transcode: the direct plan with the transcoder's
    /// address, delivery `Transcode` and the video as the reason.
    pub fn transcode_plan(
        &self,
        direct: &PlaybackPlan,
        metadata: &PlexMetadata,
        file: &PlexFile,
        session_id: &str,
        identity: &[(String, String)],
    ) -> Option<PlaybackPlan> {
        let url = self.transcode_url(metadata, file, session_id, identity)?;
        let mut plan = direct.clone();
        plan.url = url.to_string();
        plan.method = DeliveryMethod::Transcode;
        plan.reasons = vec![TranscodeReason {
            kind: ReasonKind::Video,
            codec: plan.video_codec().unwrap_or("av1").to_owned(),
            detail: None,
        }];
        Some(plan)
    }

    /// The part a plan belongs to (needed for progress and track choice) (:108).
    pub fn part(metadata: &PlexMetadata, media_source_id: Option<&str>) -> Option<PlexPart> {
        Self::file(metadata, media_source_id).map(|f| f.part)
    }

    /// **Every playable file of a title**, in the order the server lists them. The first part
    /// of a version keeps the plain `Media` id (what was stored and sent before); further
    /// parts of the same version get `<id>-<number>` (:114).
    pub fn files(metadata: &PlexMetadata) -> Vec<PlexFile> {
        metadata
            .media
            .iter()
            .flat_map(|media| {
                media
                    .parts
                    .iter()
                    .enumerate()
                    .map(move |(offset, part)| PlexFile {
                        media: media.clone(),
                        part: part.clone(),
                        number: offset as i64 + 1,
                        source_id: if offset == 0 {
                            media.id.to_string()
                        } else {
                            format!("{}-{}", media.id, offset + 1)
                        },
                    })
            })
            .collect()
    }

    /// The file a source id names; without a (known) id the first one (:122).
    pub fn file(metadata: &PlexMetadata, media_source_id: Option<&str>) -> Option<PlexFile> {
        let all = Self::files(metadata);
        let named = media_source_id.and_then(|id| all.iter().find(|f| f.source_id == id).cloned());
        named.or_else(|| all.into_iter().next())
    }

    /// The query of `/:/timeline`. Offsets are milliseconds; Swiftly counts ticks (:133).
    pub fn timeline_query(
        rating_key: &str,
        state: TimelineState,
        position_ticks: i64,
        duration_milliseconds: Option<i64>,
    ) -> Vec<(String, String)> {
        let mut query = vec![
            ("ratingKey".to_string(), rating_key.to_string()),
            ("key".into(), format!("/library/metadata/{rating_key}")),
            ("state".into(), state.as_str().into()),
            ("time".into(), (position_ticks / 10_000).max(0).to_string()),
            ("identifier".into(), "com.plexapp.plugins.library".into()),
        ];
        if let Some(d) = duration_milliseconds.filter(|d| *d > 0) {
            query.push(("duration".into(), d.to_string()));
        }
        query
    }
}
