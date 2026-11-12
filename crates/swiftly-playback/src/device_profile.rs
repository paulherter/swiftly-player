//! The DeviceProfile sent to `PlaybackInfo` (JellyfinKit/DeviceProfile.swift).
//!
//! Jellyfin decides solely from this profile whether it delivers a file untouched (Direct
//! Play), repackages the container (Direct Stream) or re-encodes the video. Swiftly aims to
//! never transcode, so it declares everything the engine can play: every container without a
//! codec list, every subtitle format (a missing format makes the server burn it in), no
//! bitrate limit (DeviceProfile.swift:3-19).
//!
//! The Swift app has two profiles: the engine profile `vlc()` (named "Swiftly (VLC)", also
//! what Aether and the Android app send today) and the narrow `airplay()` profile. The
//! platform flavour is an input here ([`Flavour`]); Media3 and mpv map to the engine profile
//! unchanged because no other profile exists in the Swift code (see NOTES.md).

use serde::{Deserialize, Serialize};

/// Which engine family the profile is built for.
///
/// `Aether` (Apple), `Media3` (Android) and `Mpv` (desktop) all send the engine profile of
/// DeviceProfile.swift:186 today; `AirPlay` is the narrow AVPlayer profile of
/// DeviceProfile.swift:291.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Flavour {
    /// Apple engine (Aether): `DeviceProfile.vlc()`.
    Aether,
    /// Android ExoPlayer/Media3: same wire profile as `vlc()` today.
    Media3,
    /// Desktop libmpv: same wire profile as `vlc()` today.
    Mpv,
    /// Real AirPlay through AVPlayer; `av1` also copies AV1.
    AirPlay {
        /// Also copy AV1 (DeviceProfile.swift:288-291).
        av1: bool,
    },
}

/// Default bitrate limit: practically unlimited (DeviceProfile.swift:186).
pub const DEFAULT_MAX_BITRATE: i64 = 1_000_000_000;

/// The profile sent as `DeviceProfile` in the `PlaybackInfo` body (DeviceProfile.swift:19).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct DeviceProfile {
    /// Profile name.
    pub name: String,
    /// Streaming bitrate limit in bit/s.
    pub max_streaming_bitrate: i64,
    /// Static (direct play) bitrate limit in bit/s.
    pub max_static_bitrate: i64,
    /// Direct play entries.
    pub direct_play_profiles: Vec<DirectPlayProfile>,
    /// Transcoding fallback entries.
    pub transcoding_profiles: Vec<TranscodingProfile>,
    /// Subtitle formats with delivery method.
    pub subtitle_profiles: Vec<SubtitleProfile>,
    /// Codec conditions.
    pub codec_profiles: Vec<CodecProfile>,
}

/// One direct-play entry; a missing codec means any codec (DeviceProfile.swift:39).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct DirectPlayProfile {
    /// Container name.
    pub container: String,
    /// `Video` or `Audio`.
    #[serde(rename = "Type")]
    pub type_: String,
    /// Allowed video codecs (comma list), absent for any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video_codec: Option<String>,
    /// Allowed audio codecs (comma list), absent for any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_codec: Option<String>,
}

/// One transcoding entry (DeviceProfile.swift:53).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct TranscodingProfile {
    /// Container name.
    pub container: String,
    /// `Video`.
    #[serde(rename = "Type")]
    pub type_: String,
    /// Video codecs (comma list).
    pub video_codec: String,
    /// Audio codecs (comma list).
    pub audio_codec: String,
    /// `Streaming`.
    pub context: String,
    /// `hls`.
    #[serde(rename = "Protocol")]
    pub protocol_name: String,
}

/// One subtitle format with its delivery method `Embed` or `External` (DeviceProfile.swift:71).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct SubtitleProfile {
    /// Format name.
    pub format: String,
    /// `Embed` or `External`.
    pub method: String,
}

/// A codec profile with conditions (DeviceProfile.swift:81).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct CodecProfile {
    /// `Video`.
    #[serde(rename = "Type")]
    pub type_: String,
    /// Codec the conditions apply to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    /// The conditions.
    pub conditions: Vec<ProfileCondition>,
}

/// One condition of a codec profile (DeviceProfile.swift:93).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ProfileCondition {
    /// Operator such as `EqualsAny`.
    pub condition: String,
    /// Property such as `VideoCodecTag`.
    pub property: String,
    /// Value (`|` separated list).
    pub value: String,
    /// Whether a missing property fails the condition.
    pub is_required: bool,
}

/// Containers the engine opens directly (DeviceProfile.swift:113-120).
pub const VLC_CONTAINERS: &[&str] = &[
    "mkv", "mp4", "mov", "m4v", "avi", "flv", "webm", "asf", "wmv", "ts", "m2ts", "mts", "mpegts",
    "mpg", "mpeg", "vob", "3gp", "3g2", "ogg", "ogv", "ogm", "rm", "rmvb", "divx", "f4v", "mk3d",
    "nsv", "dav", "wtv",
];

/// Containers of pure audio files, in Jellyfin's spelling (DeviceProfile.swift:123-127).
pub const VLC_AUDIO_CONTAINERS: &[&str] = &[
    "mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "wma", "ape", "alac", "mkv", "mka", "webm",
    "wv", "aiff", "aif", "caf", "w64", "au", "tta", "mpc", "ac3", "eac3", "dts", "truehd", "mp2",
];

/// Video codecs the engine decodes (DeviceProfile.swift:131-135).
pub const VLC_VIDEO_CODECS: &[&str] = &[
    "h264",
    "hevc",
    "h265",
    "av1",
    "vp8",
    "vp9",
    "mpeg4",
    "mpeg2video",
    "mpeg1video",
    "vc1",
    "wmv1",
    "wmv2",
    "wmv3",
    "msmpeg4v1",
    "msmpeg4v2",
    "msmpeg4v3",
    "h263",
    "theora",
    "dvvideo",
    "prores",
    "ffv1",
    "mjpeg",
];

/// Audio codecs the engine decodes (DeviceProfile.swift:139-150).
pub const VLC_AUDIO_CODECS: &[&str] = &[
    "aac",
    "aac_latm",
    "ac3",
    "eac3",
    "dts",
    "dca",
    "dtshd",
    "truehd",
    "mlp",
    "mp3",
    "mp2",
    "mp1",
    "flac",
    "alac",
    "vorbis",
    "opus",
    "wmav1",
    "wmav2",
    "wmapro",
    "wmalossless",
    "pcm_s16le",
    "pcm_s16be",
    "pcm_s24le",
    "pcm_s32le",
    "pcm_f32le",
    "pcm_alaw",
    "pcm_mulaw",
    "pcm_bluray",
    "pcm_dvd",
    "cook",
    "sipr",
    "ra_144",
    "ra_288",
    "ape",
    "wavpack",
    "tta",
    "musepack",
    "amr_nb",
    "amr_wb",
    "nellymoser",
    "speex",
    "adpcm_ima_wav",
    "adpcm_ms",
];

/// Subtitle formats delivered inside the container (DeviceProfile.swift:156-166).
const EMBEDDED_SUBTITLES: &[&str] = &[
    "srt",
    "subrip",
    "ass",
    "ssa",
    "vtt",
    "webvtt",
    "mov_text",
    "stpp",
    "ttml",
    "dfxp",
    "sami",
    "smi",
    "microdvd",
    "teletext",
    "dvbsub",
    "dvb_subtitle",
    "pgssub",
    "pgs",
    "hdmv_pgs_subtitle",
    "dvdsub",
    "dvd_subtitle",
    "vobsub",
    "idx",
    "cc_dec",
    "eia_608",
    "subviewer",
    "mpl2",
    "pjs",
    "jacosub",
    "realtext",
];

/// Subtitle formats loaded as separate files (DeviceProfile.swift:176). External VobSub
/// (`dvdsub`) is deliberately absent: Jellyfin cannot deliver it raw.
const EXTERNAL_SUBTITLES: &[&str] = &[
    "srt", "subrip", "ass", "ssa", "vtt", "webvtt", "sub", "idx", "smi", "pgssub",
];

/// All subtitle profiles of the engine profile: Embed first, then External
/// (DeviceProfile.swift:155-179).
pub fn vlc_subtitle_profiles() -> Vec<SubtitleProfile> {
    let embed = EMBEDDED_SUBTITLES.iter().map(|f| SubtitleProfile {
        format: (*f).to_owned(),
        method: "Embed".to_owned(),
    });
    let external = EXTERNAL_SUBTITLES.iter().map(|f| SubtitleProfile {
        format: (*f).to_owned(),
        method: "External".to_owned(),
    });
    embed.chain(external).collect()
}

fn direct_entry(container: &str, type_: &str) -> DirectPlayProfile {
    DirectPlayProfile {
        container: container.to_owned(),
        type_: type_.to_owned(),
        video_codec: None,
        audio_codec: None,
    }
}

/// `VideoRangeType` values AirPlay shows (no enhancement-layer Dolby Vision, no invalid).
pub const AIRPLAY_RANGES: &str =
    "SDR|HDR10|HLG|HDR10Plus|DOVI|DOVIWithSDR|DOVIWithHDR10|DOVIWithHLG|DOVIWithHDR10Plus";

impl DeviceProfile {
    /// The profile for a platform flavour with the given bitrate limit.
    pub fn for_flavour(flavour: Flavour, max_bitrate: i64) -> Self {
        match flavour {
            Flavour::Aether | Flavour::Media3 | Flavour::Mpv => Self::vlc(max_bitrate),
            Flavour::AirPlay { av1 } => Self::airplay(max_bitrate, av1),
        }
    }

    /// The engine profile, name "Swiftly (VLC)" (DeviceProfile.swift:186-236).
    ///
    /// One direct-play entry per container without a codec restriction: an allow list can only
    /// be too short (DeviceProfile.swift:189-198). The fallback is HLS with h264/aac.
    pub fn vlc(max_bitrate: i64) -> Self {
        let mut direct: Vec<DirectPlayProfile> = VLC_CONTAINERS
            .iter()
            .map(|c| direct_entry(c, "Video"))
            .collect();
        direct.extend(
            VLC_AUDIO_CONTAINERS
                .iter()
                .map(|c| direct_entry(c, "Audio")),
        );
        Self {
            name: "Swiftly (VLC)".to_owned(),
            max_streaming_bitrate: max_bitrate,
            max_static_bitrate: max_bitrate,
            direct_play_profiles: direct,
            transcoding_profiles: vec![TranscodingProfile {
                container: "ts".to_owned(),
                type_: "Video".to_owned(),
                video_codec: "h264".to_owned(),
                audio_codec: "aac".to_owned(),
                context: "Streaming".to_owned(),
                protocol_name: "hls".to_owned(),
            }],
            subtitle_profiles: vlc_subtitle_profiles(),
            codec_profiles: Vec::new(),
        }
    }

    /// The narrow AirPlay profile, name "Swiftly (AirPlay)" (DeviceProfile.swift:291-349).
    ///
    /// Text subtitles only (a bitmap format would be burned in), HEVC direct only with the
    /// tag AVFoundation accepts (`hvc1|dvh1`, not required so Matroska is unaffected).
    pub fn airplay(max_bitrate: i64, av1: bool) -> Self {
        Self::airplay_with(max_bitrate, av1, false)
    }

    /// [`Self::airplay`] plus, when `range_guard` is set, an optional `VideoRangeType`
    /// condition on HEVC that lists the ranges AirPlay can show. Dolby Vision with an
    /// enhancement layer (profile 7), invalid and unknown ranges are left out, so the server
    /// does not remux them and drop the DV record (issue #49). `false` equals `airplay()`.
    pub fn airplay_with(max_bitrate: i64, av1: bool, range_guard: bool) -> Self {
        let video_codecs = if av1 { "h264,hevc,av1" } else { "h264,hevc" };
        let direct = ["mp4", "m4v", "mov"]
            .iter()
            .map(|c| DirectPlayProfile {
                container: (*c).to_owned(),
                type_: "Video".to_owned(),
                video_codec: Some(video_codecs.to_owned()),
                audio_codec: Some("aac,ac3,eac3,alac,flac,mp3".to_owned()),
            })
            .collect();
        let subtitle = ["vtt", "webvtt", "srt", "subrip"]
            .iter()
            .map(|f| SubtitleProfile {
                format: (*f).to_owned(),
                method: "External".to_owned(),
            })
            .collect();
        Self {
            name: "Swiftly (AirPlay)".to_owned(),
            max_streaming_bitrate: max_bitrate,
            max_static_bitrate: max_bitrate,
            direct_play_profiles: direct,
            transcoding_profiles: vec![TranscodingProfile {
                container: "mp4".to_owned(),
                type_: "Video".to_owned(),
                video_codec: video_codecs.to_owned(),
                audio_codec: "aac,ac3,eac3".to_owned(),
                context: "Streaming".to_owned(),
                protocol_name: "hls".to_owned(),
            }],
            subtitle_profiles: subtitle,
            codec_profiles: vec![CodecProfile {
                type_: "Video".to_owned(),
                codec: Some("hevc".to_owned()),
                conditions: {
                    let mut c = vec![ProfileCondition {
                        condition: "EqualsAny".to_owned(),
                        property: "VideoCodecTag".to_owned(),
                        value: "hvc1|dvh1".to_owned(),
                        is_required: false,
                    }];
                    if range_guard {
                        c.push(ProfileCondition {
                            condition: "EqualsAny".to_owned(),
                            property: "VideoRangeType".to_owned(),
                            value: AIRPLAY_RANGES.to_owned(),
                            is_required: false,
                        });
                    }
                    c
                },
            }],
        }
    }

    /// The profile as the JSON value sent in the `PlaybackInfo` body.
    pub fn to_json(&self) -> serde_json::Value {
        // A struct of plain strings, integers and booleans always serialises.
        serde_json::to_value(self).unwrap_or(serde_json::Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::collections::HashSet;

    fn vlc() -> DeviceProfile {
        DeviceProfile::vlc(DEFAULT_MAX_BITRATE)
    }

    /// DeviceProfileTests.containersCovered
    #[test]
    fn containers_covered() {
        let containers: HashSet<_> = vlc()
            .direct_play_profiles
            .into_iter()
            .map(|p| p.container)
            .collect();
        for critical in ["mkv", "avi", "ts", "m2ts", "webm", "vob"] {
            assert!(containers.contains(critical), "Container {critical} fehlt");
        }
    }

    /// DeviceProfileTests.losslessAudioCodecs
    #[test]
    fn lossless_audio_codecs() {
        for critical in ["dts", "truehd", "mlp", "flac", "opus"] {
            assert!(VLC_AUDIO_CODECS.contains(&critical), "{critical} fehlt");
        }
    }

    /// DeviceProfileTests.bitMapSubtitlesAreEmbedded
    #[test]
    fn bit_map_subtitles_are_embedded() {
        let profile = vlc();
        for format in ["pgssub", "dvdsub", "vobsub", "dvbsub"] {
            let entry = profile
                .subtitle_profiles
                .iter()
                .find(|s| s.format == format);
            assert!(entry.is_some(), "{format} fehlt");
            assert_eq!(entry.map(|e| e.method.as_str()), Some("Embed"));
        }
        assert!(
            !profile
                .subtitle_profiles
                .iter()
                .any(|s| s.method == "Encode")
        );
    }

    /// DeviceProfileTests.externalBitMapSubtitle
    #[test]
    fn external_bit_map_subtitle() {
        let ext: Vec<_> = vlc()
            .subtitle_profiles
            .into_iter()
            .filter(|s| s.method == "External")
            .map(|s| s.format)
            .collect();
        assert!(ext.iter().any(|f| f == "pgssub"));
        assert!(!ext.iter().any(|f| f == "dvdsub"));
    }

    /// DeviceProfileTests.audioContainer
    #[test]
    fn audio_container() {
        let audio: Vec<_> = vlc()
            .direct_play_profiles
            .into_iter()
            .filter(|p| p.type_ == "Audio")
            .collect();
        let names: HashSet<_> = audio.iter().map(|p| p.container.as_str()).collect();
        for c in [
            "mkv", "wv", "aiff", "caf", "w64", "tta", "ac3", "eac3", "dts", "truehd", "webm",
        ] {
            assert!(names.contains(c), "{c}");
        }
        assert!(audio.iter().all(|p| p.audio_codec.is_none()));
    }

    /// DeviceProfileTests.bitrateIsUnbounded
    #[test]
    fn bitrate_is_unbounded() {
        assert!(vlc().max_streaming_bitrate >= 1_000_000_000);
    }

    /// DeviceProfileTests.encodesWithServerKeys
    #[test]
    fn encodes_with_server_keys() {
        let json = vlc().to_json();
        assert!(json.get("DirectPlayProfiles").is_some());
        assert!(json.get("SubtitleProfiles").is_some());
        assert!(json.get("MaxStreamingBitrate").is_some());
        let first = &json["DirectPlayProfiles"][0];
        assert!(first.get("Container").is_some());
        assert_eq!(first["Type"], "Video");
    }

    /// MediaSourceTests.deliveryMethod
    #[test]
    fn delivery_method() {
        use swiftly_model::DeliveryMethod;
        let source = |dp: bool, ds: bool| -> swiftly_model::MediaSource {
            let json =
                format!(r#"{{"Id":"x","SupportsDirectPlay":{dp},"SupportsDirectStream":{ds}}}"#);
            serde_json::from_str(&json).expect("source json")
        };
        assert_eq!(
            source(true, true).delivery_method(),
            DeliveryMethod::DirectPlay
        );
        assert_eq!(
            source(false, true).delivery_method(),
            DeliveryMethod::DirectStream
        );
        assert_eq!(
            source(false, false).delivery_method(),
            DeliveryMethod::Transcode
        );
    }

    /// MediaSourceTests.losslessFlag
    #[test]
    fn lossless_flag() {
        use swiftly_model::DeliveryMethod;
        assert!(DeliveryMethod::DirectPlay.is_lossless());
        assert!(DeliveryMethod::DirectStream.is_lossless());
        assert!(!DeliveryMethod::Transcode.is_lossless());
    }

    /// ProfileGapsTests.noCodecList
    #[test]
    fn no_codec_list() {
        let profile = vlc();
        let video: Vec<_> = profile
            .direct_play_profiles
            .iter()
            .filter(|p| p.type_ == "Video")
            .collect();
        assert!(!video.is_empty());
        for e in video {
            assert!(e.video_codec.is_none(), "{}", e.container);
            assert!(e.audio_codec.is_none(), "{}", e.container);
        }
    }

    /// ProfileGapsTests.subtitleComplete
    #[test]
    fn subtitle_complete() {
        let formats: HashSet<_> = vlc_subtitle_profiles()
            .into_iter()
            .map(|s| s.format)
            .collect();
        for f in [
            "srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "stpp", "ttml", "pgssub",
            "dvdsub", "vobsub", "dvbsub",
        ] {
            assert!(formats.contains(f), "{f} fehlt");
        }
    }

    /// ProfileGapsTests.audioComplete
    #[test]
    fn audio_complete() {
        for c in [
            "dts",
            "dca",
            "dtshd",
            "truehd",
            "mlp",
            "pcm_s16le",
            "pcm_s24le",
            "pcm_s32le",
            "pcm_f32le",
            "pcm_alaw",
            "pcm_mulaw",
            "cook",
            "sipr",
        ] {
            assert!(VLC_AUDIO_CODECS.contains(&c), "{c} fehlt");
        }
    }

    /// ProfileGapsTests.bitrateOpen
    #[test]
    fn bitrate_open() {
        let p = vlc();
        assert!(p.max_streaming_bitrate >= 1_000_000_000);
        assert!(p.max_static_bitrate >= 1_000_000_000);
    }

    #[test]
    fn airplay_range_guard() {
        let plain = DeviceProfile::airplay(DEFAULT_MAX_BITRATE, false);
        assert_eq!(
            plain.to_json(),
            DeviceProfile::airplay_with(DEFAULT_MAX_BITRATE, false, false).to_json()
        );
        let g = DeviceProfile::airplay_with(DEFAULT_MAX_BITRATE, true, true);
        let cond = &g.codec_profiles[0].conditions;
        assert_eq!(cond.len(), 2);
        assert_eq!(cond[1].property, "VideoRangeType");
        assert!(cond[1].value.contains("DOVIWithHDR10") && !cond[1].value.contains("EL"));
        assert!(!cond[1].is_required);
    }

    /// ProfileGapsTests.airplayHevcId
    #[test]
    fn airplay_hevc_id() {
        let profile = DeviceProfile::airplay(DEFAULT_MAX_BITRATE, false);
        let hevc = profile
            .codec_profiles
            .iter()
            .find(|c| c.codec.as_deref() == Some("hevc"))
            .expect("hevc profile");
        let r = &hevc.conditions[0];
        assert_eq!(r.property, "VideoCodecTag");
        assert_eq!(r.condition, "EqualsAny");
        assert_eq!(r.value, "hvc1|dvh1");
        assert!(!r.is_required);
        let json = serde_json::to_string(&profile).expect("json");
        assert!(json.contains(r#""Property":"VideoCodecTag""#));
        assert!(profile.transcoding_profiles[0].video_codec.contains("hevc"));
    }

    // Golden files: the JSON the Swift `JSONEncoder` (sorted keys) produced from
    // DeviceProfile.swift with `swiftc` (tests/golden/*.json).

    fn golden(text: &str) -> Value {
        serde_json::from_str(text).expect("golden json")
    }

    /// Byte-exact comparison of the engine profile against the Swift encoder output.
    #[test]
    fn golden_vlc() {
        let want = golden(include_str!("../tests/golden/vlc.json"));
        assert_eq!(vlc().to_json(), want);
        for f in [Flavour::Aether, Flavour::Media3, Flavour::Mpv] {
            assert_eq!(
                DeviceProfile::for_flavour(f, DEFAULT_MAX_BITRATE).to_json(),
                want
            );
        }
    }

    /// Engine profile with a custom bitrate (`vlc(maxBitrate:)`).
    #[test]
    fn golden_vlc_limited() {
        let want = golden(include_str!("../tests/golden/vlc_8mbit.json"));
        assert_eq!(DeviceProfile::vlc(8_000_000).to_json(), want);
    }

    /// AirPlay profile without and with AV1.
    #[test]
    fn golden_airplay() {
        let plain = golden(include_str!("../tests/golden/airplay.json"));
        let av1 = golden(include_str!("../tests/golden/airplay_av1.json"));
        assert_eq!(
            DeviceProfile::for_flavour(Flavour::AirPlay { av1: false }, DEFAULT_MAX_BITRATE)
                .to_json(),
            plain
        );
        assert_eq!(
            DeviceProfile::for_flavour(Flavour::AirPlay { av1: true }, DEFAULT_MAX_BITRATE)
                .to_json(),
            av1
        );
    }

    /// Serialised string with sorted keys equals the Swift file byte for byte.
    #[test]
    fn golden_vlc_bytes() {
        let want = include_str!("../tests/golden/vlc.json");
        let got = serde_json::to_string(&vlc().to_json()).expect("json");
        // serde_json's Value map is sorted, like the Swift .sortedKeys output.
        assert_eq!(got, want);
    }
}
