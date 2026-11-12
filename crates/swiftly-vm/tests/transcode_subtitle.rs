//! A chosen bitmap subtitle on a plan that transcodes (DV 10 transcode, bitrate limit): the plan asks the
//! server again naming the track, with the bitmap formats as `Encode`, so the server burns it in. Golden:
//! direct play, text tracks and a copying transcode keep their one request. The server below answers like
//! Jellyfin does: the transcoding address names `SubtitleMethod=Encode` only when the request named a track
//! and the profile asked its format as `Encode`.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::account;
use common::script::{Script, host};
use futures_executor::block_on;
use swiftly_model::DeliveryMethod;
use swiftly_playback::device_profile::Flavour;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{
    NextSource, StartAnswer, StartRequest, StartSettings, play_plan_only, play_start,
};

fn streams(codec: &str, profile: i64, subtitle_codec: &str) -> serde_json::Value {
    serde_json::json!([
        {"Index": 0, "Type": "Video", "Codec": codec, "Width": 3840, "Height": 2160,
         "VideoRangeType": "DOVI", "DvProfile": profile, "DvBlSignalCompatibilityId": 0},
        {"Index": 1, "Type": "Audio", "Codec": "eac3", "Language": "eng", "Channels": 6, "IsDefault": true},
        {"Index": 3, "Type": "Subtitle", "Codec": subtitle_codec, "Language": "ger", "IsDefault": true,
         "IsTextSubtitleStream": subtitle_codec == "subrip"}
    ])
}

/// How the server delivers: `first` is what it answers a plain request with (`Some(reasons)`: a
/// transcode for these reasons), `forced` is the transcode after a request with direct play off.
fn server(streams: serde_json::Value, first: Option<&'static str>) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path().to_owned();
        if p.ends_with("/Items/f1") {
            return Some(
                serde_json::json!({"Id": "f1", "Name": "Film", "Type": "Movie",
                    "RunTimeTicks": 72_000_000_000_i64,
                    "MediaSources": [{"Id": "s0", "Container": "mkv", "SupportsDirectPlay": true,
                        "DefaultSubtitleStreamIndex": 3, "MediaStreams": streams}]})
                .to_string(),
            );
        }
        if p.ends_with("/Items/f1/PlaybackInfo") {
            let body: serde_json::Value = serde_json::from_slice(r.body.as_ref().unwrap()).unwrap();
            let direct = body["EnableDirectPlay"] == true;
            let mut source = serde_json::json!({"Id": "s0", "Container": "mkv", "DefaultSubtitleStreamIndex": 3,
                "SupportsDirectPlay": direct && first.is_none(), "SupportsDirectStream": direct && first.is_none(),
                "SupportsTranscoding": true, "MediaStreams": streams});
            if !direct || first.is_some() {
                let reasons = first.unwrap_or("VideoCodecNotSupported");
                let mut url = format!(
                    "/videos/f1/master.m3u8?MediaSourceId=s0&VideoCodec=hevc&TranscodeReasons={reasons}"
                );
                // The burn-in: the track is named and its format is asked as Encode.
                let named = body["SubtitleStreamIndex"].as_i64().filter(|i| *i >= 0);
                let encode = body["DeviceProfile"]["SubtitleProfiles"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|s| s["Method"] == "Encode" && s["Format"] == "pgssub");
                if let (Some(i), true) = (named, encode) {
                    url.push_str(&format!("&SubtitleMethod=Encode&SubtitleStreamIndex={i}"));
                }
                source["TranscodingUrl"] = url.into();
                source["TranscodingSubProtocol"] = "hls".into();
            }
            return Some(
                serde_json::json!({"MediaSources": [source], "PlaySessionId": "ps1"}).to_string(),
            );
        }
        Some("{}".into())
    })
}

fn request() -> StartRequest {
    StartRequest {
        item_id: "f1".into(),
        source_id: None,
        since: None,
        flavour: Flavour::Mpv,
        hardware_av1: false,
        no_dolby_vision_decoder: false,
        ask_versions: false,
        downloaded: None,
        ordered: None,
        account_key: Some("acct".into()),
        settings: StartSettings {
            audio_language: String::new(),
            subtitle_language: "ger".into(),
            automatic_subtitles: true,
            max_bitrate: 120_000_000,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            server_extracts_text: true,
        },
        next: NextSource::None,
    }
}

fn play(net: &Arc<Script>) -> Box<swiftly_vm::ReadyStart> {
    match block_on(play_start(
        net.clone(),
        &host(),
        &account("TOKEN-A"),
        &request(),
        None,
    ))
    .unwrap()
    {
        StartAnswer::Ready(r) => r,
        other => panic!("not ready: {other:?}"),
    }
}

fn asked(net: &Arc<Script>) -> Vec<serde_json::Value> {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.url.path().ends_with("/PlaybackInfo"))
        .map(|r| serde_json::from_slice(r.body.as_ref().unwrap()).unwrap())
        .collect()
}

fn methods(body: &serde_json::Value, format: &str) -> Vec<String> {
    body["DeviceProfile"]["SubtitleProfiles"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["Format"] == format)
        .map(|s| s["Method"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn a_pgs_track_on_the_dv10_transcode_is_burned_in() {
    let net = server(streams("av1", 10, "hdmv_pgs_subtitle"), None);
    let r = play(&net);
    assert_eq!(r.subtitle, 3);
    assert_eq!(r.plan.method, DeliveryMethod::Transcode);
    assert!(
        r.plan
            .url
            .contains("SubtitleMethod=Encode&SubtitleStreamIndex=3"),
        "{}",
        r.plan.url
    );
    let bodies = asked(&net);
    assert_eq!(bodies.len(), 3, "plain, transcode, with the subtitle");
    // The first two do not name a subtitle and keep the bitmap formats for the engine.
    for body in &bodies[..2] {
        assert!(body["SubtitleStreamIndex"].is_null());
        assert_eq!(methods(body, "pgssub"), ["Embed", "External"]);
    }
    let last = &bodies[2];
    assert_eq!(last["SubtitleStreamIndex"], 3);
    assert_eq!(last["EnableDirectPlay"], false);
    assert_eq!(last["EnableTranscoding"], true);
    assert_eq!(last["MediaSourceId"], "s0");
    for format in ["pgssub", "hdmv_pgs_subtitle", "dvdsub", "vobsub"] {
        assert_eq!(methods(last, format), ["Encode"], "{format}");
    }
    // Text formats and the rest of the profile are as before.
    assert_eq!(methods(last, "srt"), methods(&bodies[0], "srt"));
    assert_eq!(
        last["DeviceProfile"]["TranscodingProfiles"],
        bodies[0]["DeviceProfile"]["TranscodingProfiles"]
    );
    assert_eq!(
        last["MaxStreamingBitrate"],
        bodies[0]["MaxStreamingBitrate"]
    );
}

#[test]
fn a_pgs_track_on_a_bitrate_limit_transcode_is_burned_in_after_one_more_request() {
    let net = server(
        streams("hevc", 8, "hdmv_pgs_subtitle"),
        Some("ContainerBitrateExceedsLimit"),
    );
    let r = play(&net);
    assert!(
        r.plan
            .url
            .contains("SubtitleMethod=Encode&SubtitleStreamIndex=3"),
        "{}",
        r.plan.url
    );
    let bodies = asked(&net);
    assert_eq!(bodies.len(), 2);
    assert!(bodies[0]["SubtitleStreamIndex"].is_null());
    assert_eq!(bodies[1]["SubtitleStreamIndex"], 3);
}

#[test]
fn text_tracks_copying_transcodes_and_direct_play_keep_their_requests() {
    // (title, what the server does first, requests expected, address burns)
    for (what, net, count) in [
        (
            "text on the DV 10 transcode",
            server(streams("av1", 10, "subrip"), None),
            2,
        ),
        (
            "pgs on a copying transcode",
            server(
                streams("hevc", 8, "hdmv_pgs_subtitle"),
                Some("ContainerNotSupported"),
            ),
            1,
        ),
        (
            "pgs on direct play",
            server(streams("hevc", 8, "hdmv_pgs_subtitle"), None),
            1,
        ),
    ] {
        let r = play(&net);
        let bodies = asked(&net);
        assert_eq!(bodies.len(), count, "{what}");
        assert!(
            !r.plan.url.contains("SubtitleMethod=Encode"),
            "{what}: {}",
            r.plan.url
        );
        assert!(
            bodies.iter().all(|b| b["SubtitleStreamIndex"].is_null()),
            "{what}"
        );
        assert!(
            bodies
                .iter()
                .all(|b| methods(b, "pgssub") == ["Embed", "External"]),
            "{what}"
        );
    }
}

#[test]
fn a_subtitle_picked_during_the_transcode_asks_the_plan_again_with_it() {
    let net = server(streams("av1", 10, "hdmv_pgs_subtitle"), None);
    let plan = |subtitle: Option<i64>| {
        block_on(play_plan_only(
            net.clone(),
            &host(),
            &account("TOKEN-A"),
            "f1",
            Flavour::Mpv,
            false,
            120_000_000,
            None,
            subtitle,
        ))
        .unwrap()
        .expect("a plan")
    };
    // No subtitle: the plain plan, nothing burned.
    assert!(!plan(None).url.contains("SubtitleMethod"));
    assert!(!plan(Some(-1)).url.contains("SubtitleMethod"));
    // The PGS track: the plan comes burned in.
    let burned = plan(Some(3));
    assert_eq!(burned.method, DeliveryMethod::Transcode);
    assert!(
        burned
            .url
            .contains("SubtitleMethod=Encode&SubtitleStreamIndex=3"),
        "{}",
        burned.url
    );
}

/// A text track on a transcode: the server cannot carry it in HLS and answers `External` with a file address while
/// `IsExternal` stays false. The tracks handed to the player (desktop, Android) then count it as a subtitle file, so the
/// player loads it; on direct play the same answer is a track of the container and nothing is loaded.
#[test]
fn a_text_track_the_server_delivers_as_a_file_on_a_transcode_is_loaded_by_the_player() {
    use swiftly_playback::player_state::{Command, EngineRequest, Intent, PlayerState};
    let text = serde_json::json!([
        {"Index": 0, "Type": "Video", "Codec": "hevc", "Width": 1920, "Height": 1080},
        {"Index": 1, "Type": "Audio", "Codec": "eac3", "Language": "eng", "Channels": 6, "IsDefault": true},
        {"Index": 3, "Type": "Subtitle", "Codec": "subrip", "Language": "ger", "IsDefault": true, "IsTextSubtitleStream": true,
         "DeliveryMethod": "External", "DeliveryUrl": "/Videos/f1/s0/Subtitles/3/0/Stream.srt"}
    ]);
    let loaded = |net: &Arc<Script>| {
        let r = play(net);
        let state_request = EngineRequest {
            item_id: "f1".into(),
            streams: r.streams.clone(),
            runtime: 7200.0,
            subtitle_files: r.subtitle_files.clone(),
            url: r.plan.url.clone(),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        };
        let mut state = PlayerState::new(state_request, r.audio, r.subtitle);
        let cmds = state.intent(Intent::Start(0.0));
        let load = cmds
            .iter()
            .find_map(|c| {
                if let Command::Load(l) = c {
                    Some(l.clone())
                } else {
                    None
                }
            })
            .unwrap();
        (r.plan.method, load.external_subtitles.len())
    };
    // Transcode (the codec is not supported): the file is loaded.
    assert_eq!(
        loaded(&server(text.clone(), Some("VideoCodecNotSupported"))),
        (DeliveryMethod::Transcode, 1)
    );
    // Direct play: the track is in the container, nothing is loaded.
    assert_eq!(loaded(&server(text, None)), (DeliveryMethod::DirectPlay, 0));
}
