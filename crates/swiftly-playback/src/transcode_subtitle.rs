//! A subtitle on a stream the server transcodes.
//!
//! The engine profile lists every bitmap format (PGS, VobSub) as `Embed`, which is right for direct play:
//! the engine draws them. A transcoded HLS stream cannot carry them, so the picture arrives without
//! subtitles, unless the server burns the track in (`SubtitleMethod=Encode`). The server only does that
//! when the request names the track. This module is the one rule for the start and for a change while
//! the stream plays: `Replan` means "ask the server again with this subtitle and reload at the same
//! position", `Engine` means "the engine switches, nothing reloads" (direct play and direct stream, and
//! text tracks the engine or the HLS side delivers).

use swiftly_model::MediaStream;

use crate::device_profile::{DeviceProfile, SubtitleProfile};

/// Bitmap subtitle codecs: the server cannot hand them to a transcoded stream, only burn them in.
pub const BITMAP_CODECS: &[&str] = &[
    "pgssub",
    "pgs",
    "hdmv_pgs_subtitle",
    "dvdsub",
    "dvd_subtitle",
    "vobsub",
    "dvbsub",
    "dvb_subtitle",
];

/// Whether `codec` is a bitmap subtitle format.
pub fn is_bitmap(codec: &str) -> bool {
    let c = codec.to_lowercase();
    BITMAP_CODECS.contains(&c.as_str())
}

/// What a subtitle choice needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubtitleDelivery {
    /// The engine switches by itself; nothing reloads.
    Engine,
    /// A new plan with this subtitle, then a reload at the same position.
    Replan,
}

/// Transcode reasons after which the video is only copied: a copy cannot take a burn-in without turning
/// into a re-encode, so the subtitle stays with the engine there.
const COPY_REASONS: &[&str] = &[
    "ContainerNotSupported",
    "AudioCodecNotSupported",
    "AudioIsExternal",
    "SecondaryAudioNotSupported",
    "AudioChannelsNotSupported",
    "AudioProfileNotSupported",
    "AudioSampleRateNotSupported",
    "AudioBitDepthNotSupported",
    "AudioBitrateNotSupported",
    "UnknownAudioStreamInfo",
    "VideoCodecTagNotSupported",
];

/// The query pairs of an address (keys lower-cased).
fn pairs(url: &str) -> Vec<(String, String)> {
    let query = url
        .split_once('?')
        .map_or("", |(_, q)| q.split('#').next().unwrap_or(""));
    query
        .split('&')
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.to_lowercase(), v.to_owned()))
        .collect()
}

fn value<'a>(all: &'a [(String, String)], key: &str) -> Option<&'a str> {
    all.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}

/// What the stream's address says about the subtitle: `plex` for a Plex transcode (it always names
/// `subtitles=`, and burns text too), and the index burned into the picture, if any.
fn burn_of(url: &str) -> (bool, Option<i64>) {
    let all = pairs(url);
    if let Some(mode) = value(&all, "subtitles") {
        let id = (mode == "burn")
            .then(|| value(&all, "subtitlestreamid").and_then(|v| v.parse().ok()))
            .flatten();
        return (true, id);
    }
    let encode = value(&all, "subtitlemethod").is_some_and(|m| m.eq_ignore_ascii_case("encode"));
    let id = encode
        .then(|| value(&all, "subtitlestreamindex").and_then(|v| v.parse().ok()))
        .flatten();
    (false, id)
}

/// The subtitle index burned into the transcoded picture, if the address says so.
pub fn burned_in(url: &str) -> Option<i64> {
    burn_of(url).1
}

/// Whether the transcode re-encodes the video. Unknown reasons count as a re-encode: showing the track
/// wins over saving the work. Only a list made of audio, container and tag reasons means a copy.
pub fn reencodes_video(url: &str) -> bool {
    let all = pairs(url);
    let Some(reasons) = value(&all, "transcodereasons").filter(|r| !r.is_empty()) else {
        return true;
    };
    !reasons
        .split(',')
        .all(|r| COPY_REASONS.iter().any(|c| c.eq_ignore_ascii_case(r)))
}

/// Does choosing subtitle `wanted` (`-1` off) need a new plan?
///
/// - Not a transcode: never (the engine switches).
/// - A burned-in track is part of the picture: any other choice, also "off", needs a new plan; the same
///   track needs nothing.
/// - Nothing burned: a Plex transcode burns every track (text too), so any track needs a plan; Jellyfin
///   delivers text itself, so only a bitmap track on a transcode that re-encodes the video does.
pub fn delivery(
    transcoding: bool,
    url: &str,
    streams: &[MediaStream],
    wanted: i64,
) -> SubtitleDelivery {
    if !transcoding {
        return SubtitleDelivery::Engine;
    }
    let (plex, burned) = burn_of(url);
    match burned {
        Some(b) if b == wanted => SubtitleDelivery::Engine,
        Some(_) => SubtitleDelivery::Replan,
        None if wanted < 0 => SubtitleDelivery::Engine,
        None if plex => SubtitleDelivery::Replan,
        None => {
            let bitmap = streams
                .iter()
                .find(|s| s.index == Some(wanted))
                .and_then(|s| s.codec.as_deref())
                .is_some_and(is_bitmap);
            if bitmap && reencodes_video(url) {
                SubtitleDelivery::Replan
            } else {
                SubtitleDelivery::Engine
            }
        }
    }
}

impl DeviceProfile {
    /// The same profile with every bitmap format asked as `Encode` (burned into the picture), for a request
    /// that names a bitmap subtitle on a plan that transcodes anyway. Never for the first request: there
    /// the bitmap formats stay `Embed`, so direct play keeps them for the engine.
    #[must_use]
    pub fn burning_bitmap_subtitles(&self) -> Self {
        let mut profile = self.clone();
        profile
            .subtitle_profiles
            .retain(|p| !BITMAP_CODECS.contains(&p.format.to_lowercase().as_str()));
        profile
            .subtitle_profiles
            .extend(BITMAP_CODECS.iter().map(|f| SubtitleProfile {
                format: (*f).to_owned(),
                method: "Encode".to_owned(),
            }));
        profile
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(index: i64, codec: &str) -> MediaStream {
        MediaStream {
            index: Some(index),
            codec: Some(codec.into()),
            type_: Some("Subtitle".into()),
            ..MediaStream::default()
        }
    }

    fn streams() -> Vec<MediaStream> {
        vec![
            stream(3, "hdmv_pgs_subtitle"),
            stream(4, "subrip"),
            stream(5, "dvd_subtitle"),
        ]
    }

    const HLS: &str = "/videos/f/master.m3u8?MediaSourceId=s0&VideoCodec=h264&TranscodeReasons=VideoCodecNotSupported";

    #[test]
    fn direct_play_and_direct_stream_never_replan() {
        for wanted in [-1, 3, 4, 5] {
            assert_eq!(
                delivery(false, "/stream?static=true", &streams(), wanted),
                SubtitleDelivery::Engine
            );
        }
    }

    #[test]
    fn a_bitmap_track_on_a_reencoding_transcode_replans_a_text_track_does_not() {
        assert_eq!(delivery(true, HLS, &streams(), 3), SubtitleDelivery::Replan);
        assert_eq!(delivery(true, HLS, &streams(), 5), SubtitleDelivery::Replan);
        assert_eq!(delivery(true, HLS, &streams(), 4), SubtitleDelivery::Engine);
        assert_eq!(
            delivery(true, HLS, &streams(), -1),
            SubtitleDelivery::Engine
        );
        // Unknown index: nothing to burn.
        assert_eq!(delivery(true, HLS, &streams(), 9), SubtitleDelivery::Engine);
    }

    #[test]
    fn a_copying_transcode_keeps_the_bitmap_with_the_engine() {
        let copy = "/videos/f/master.m3u8?VideoCodec=hevc&TranscodeReasons=ContainerNotSupported,AudioCodecNotSupported";
        assert_eq!(
            delivery(true, copy, &streams(), 3),
            SubtitleDelivery::Engine
        );
        let mixed = "/videos/f/master.m3u8?TranscodeReasons=ContainerNotSupported,VideoBitDepthNotSupported";
        assert_eq!(
            delivery(true, mixed, &streams(), 3),
            SubtitleDelivery::Replan
        );
        // No reasons named (the forced DV 10 transcode): counts as a re-encode.
        assert_eq!(
            delivery(true, "/videos/f/master.m3u8?VideoCodec=hevc", &streams(), 3),
            SubtitleDelivery::Replan
        );
    }

    #[test]
    fn a_burned_track_is_part_of_the_picture() {
        let burned = format!("{HLS}&SubtitleMethod=Encode&SubtitleStreamIndex=3");
        assert_eq!(burned_in(&burned), Some(3));
        assert_eq!(
            delivery(true, &burned, &streams(), 3),
            SubtitleDelivery::Engine
        );
        for other in [-1, 4, 5] {
            assert_eq!(
                delivery(true, &burned, &streams(), other),
                SubtitleDelivery::Replan,
                "{other}"
            );
        }
        // `SubtitleMethod=External` with an index is not a burn.
        let external = format!("{HLS}&SubtitleMethod=External&SubtitleStreamIndex=4");
        assert_eq!(burned_in(&external), None);
    }

    #[test]
    fn plex_burns_every_track_text_too() {
        let none = "/video/:/transcode/universal/start.m3u8?subtitles=none&protocol=hls";
        assert_eq!(
            delivery(true, none, &streams(), 4),
            SubtitleDelivery::Replan
        );
        assert_eq!(
            delivery(true, none, &streams(), -1),
            SubtitleDelivery::Engine
        );
        let burn = "/video/:/transcode/universal/start.m3u8?subtitles=burn&subtitleStreamID=4";
        assert_eq!(burned_in(burn), Some(4));
        assert_eq!(
            delivery(true, burn, &streams(), 4),
            SubtitleDelivery::Engine
        );
        assert_eq!(
            delivery(true, burn, &streams(), 3),
            SubtitleDelivery::Replan
        );
        assert_eq!(
            delivery(true, burn, &streams(), -1),
            SubtitleDelivery::Replan
        );
    }

    #[test]
    fn the_burning_profile_asks_bitmaps_as_encode_and_leaves_the_rest() {
        let base = DeviceProfile::vlc(120_000_000);
        let burn = base.burning_bitmap_subtitles();
        for format in ["pgssub", "hdmv_pgs_subtitle", "dvdsub", "vobsub", "dvbsub"] {
            let methods: Vec<&str> = burn
                .subtitle_profiles
                .iter()
                .filter(|p| p.format == format)
                .map(|p| p.method.as_str())
                .collect();
            assert_eq!(methods, ["Encode"], "{format}");
        }
        let text = |p: &DeviceProfile| {
            p.subtitle_profiles
                .iter()
                .filter(|s| !is_bitmap(&s.format))
                .cloned()
                .collect::<Vec<_>>()
        };
        assert_eq!(text(&base), text(&burn));
        assert_eq!(base.direct_play_profiles, burn.direct_play_profiles);
        assert_eq!(base.transcoding_profiles, burn.transcoding_profiles);
        // The base profile is untouched: its bitmap formats stay Embed for direct play.
        assert!(
            base.subtitle_profiles
                .iter()
                .any(|p| p.format == "pgssub" && p.method == "Embed")
        );
    }
}
