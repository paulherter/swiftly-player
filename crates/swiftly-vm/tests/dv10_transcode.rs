//! AV1 Dolby Vision 10.0 (no HDR10 base layer) on a device that shows it green: the plan asks
//! the server for a transcode. Golden: every other title keeps its one request and its plan.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::account;
use common::script::{Script, host};
use futures_executor::block_on;
use swiftly_model::DeliveryMethod;
use swiftly_playback::device_profile::Flavour;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{NextSource, StartAnswer, StartRequest, StartSettings, play_start};

fn video(codec: &str, profile: i64, compat: i64) -> serde_json::Value {
    serde_json::json!([
        {"Index": 0, "Type": "Video", "Codec": codec, "Width": 3840, "Height": 2160,
         "VideoRangeType": "DOVI", "DvProfile": profile, "DvBlSignalCompatibilityId": compat},
        {"Index": 1, "Type": "Audio", "Codec": "eac3", "Language": "eng", "Channels": 6, "IsDefault": true}
    ])
}

/// `transcodes`: whether the server turns direct play off and transcodes when asked to.
fn server(streams: serde_json::Value, transcodes: bool) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path().to_owned();
        if p.ends_with("/Items/f1") {
            return Some(
                serde_json::json!({"Id": "f1", "Name": "Film", "Type": "Movie",
                    "RunTimeTicks": 72_000_000_000_i64,
                    "MediaSources": [{"Id": "s0", "Container": "mkv", "SupportsDirectPlay": true,
                        "MediaStreams": streams}]})
                .to_string(),
            );
        }
        if p.ends_with("/Items/f1/PlaybackInfo") {
            let body: serde_json::Value = serde_json::from_slice(r.body.as_ref().unwrap()).unwrap();
            let direct = body["EnableDirectPlay"] == true;
            let mut source = serde_json::json!({"Id": "s0", "Container": "mkv",
                "SupportsDirectPlay": direct, "SupportsDirectStream": direct,
                "SupportsTranscoding": transcodes, "MediaStreams": streams});
            if !direct && transcodes {
                source["TranscodingUrl"] =
                    "/videos/f1/master.m3u8?MediaSourceId=s0&VideoCodec=hevc".into();
                source["TranscodingSubProtocol"] = "hls".into();
            }
            return Some(
                serde_json::json!({"MediaSources": [source], "PlaySessionId": "ps1"}).to_string(),
            );
        }
        Some("{}".into())
    })
}

fn request(flavour: Flavour) -> StartRequest {
    StartRequest {
        item_id: "f1".into(),
        source_id: None,
        since: None,
        flavour,
        hardware_av1: false,
        no_dolby_vision_decoder: false,
        ask_versions: false,
        downloaded: None,
        ordered: None,
        account_key: Some("acct".into()),
        settings: StartSettings {
            audio_language: String::new(),
            subtitle_language: "ger".into(),
            automatic_subtitles: false,
            max_bitrate: 120_000_000,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            server_extracts_text: true,
        },
        next: NextSource::None,
    }
}

fn play(net: &Arc<Script>, flavour: Flavour) -> Box<swiftly_vm::ReadyStart> {
    play_with(
        net,
        StartRequest {
            hardware_av1: false,
            ..request(flavour)
        },
    )
}

fn play_with(net: &Arc<Script>, request: StartRequest) -> Box<swiftly_vm::ReadyStart> {
    match block_on(play_start(
        net.clone(),
        &host(),
        &account("TOKEN-A"),
        &request,
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

#[test]
fn av1_dolby_vision_10_0_is_transcoded_by_the_server() {
    for flavour in [
        Flavour::Media3,
        Flavour::Mpv,
        Flavour::AirPlay { av1: true },
    ] {
        let net = server(video("av1", 10, 0), true);
        let r = play(&net, flavour);
        assert_eq!(r.plan.method, DeliveryMethod::Transcode, "{flavour:?}");
        assert!(r.plan.url.contains("master.m3u8"), "{}", r.plan.url);
        let bodies = asked(&net);
        assert_eq!(bodies.len(), 2);
        assert_eq!(bodies[0]["EnableDirectPlay"], true);
        assert_eq!(bodies[1]["EnableDirectPlay"], false);
        assert_eq!(bodies[1]["EnableDirectStream"], false);
        assert_eq!(bodies[1]["EnableTranscoding"], true);
        // Same profile, same bitrate: only the two flags differ.
        let (mut a, mut b) = (bodies[0].clone(), bodies[1].clone());
        for body in [&mut a, &mut b] {
            body["EnableDirectPlay"] = true.into();
            body["EnableDirectStream"] = true.into();
        }
        assert_eq!(a, b);
    }
}

#[test]
fn the_apple_engine_direct_plays_av1_dolby_vision_10_0_with_hardware_av1() {
    let hw = |flavour| StartRequest {
        hardware_av1: true,
        ..request(flavour)
    };
    // Aether on a device with hardware AV1 decode (M3+, A17 Pro+): one request, direct play.
    let net = server(video("av1", 10, 0), true);
    let r = play_with(&net, hw(Flavour::Aether));
    assert_eq!(r.plan.method, DeliveryMethod::DirectPlay);
    assert_eq!(asked(&net).len(), 1);
    // Without it (M1/M2, older iPhone): the server transcodes.
    let net = server(video("av1", 10, 0), true);
    let r = play_with(
        &net,
        StartRequest {
            hardware_av1: false,
            ..request(Flavour::Aether)
        },
    );
    assert_eq!(r.plan.method, DeliveryMethod::Transcode);
    // AVPlayer and Android show it wrong whatever the hardware reports.
    for flavour in [Flavour::AirPlay { av1: true }, Flavour::Media3] {
        let net = server(video("av1", 10, 0), true);
        assert_eq!(
            play_with(&net, hw(flavour)).plan.method,
            DeliveryMethod::Transcode,
            "{flavour:?}"
        );
    }
}

#[test]
fn a_server_that_cannot_transcode_keeps_the_original_plan() {
    // The engine's refusal message stays for this case.
    let net = server(video("av1", 10, 0), false);
    let r = play(&net, Flavour::Media3);
    assert_eq!(r.plan.method, DeliveryMethod::DirectPlay);
    assert!(!r.plan.url.contains("master.m3u8"));
    assert_eq!(asked(&net).len(), 2);
}

#[test]
fn every_other_title_keeps_its_one_request_and_direct_play() {
    for (codec, profile, compat) in [
        ("av1", 10, 1),
        ("av1", 10, 4),
        ("hevc", 8, 1),
        ("hevc", 5, 0),
        ("hevc", 7, 6),
    ] {
        let net = server(video(codec, profile, compat), true);
        let r = play(&net, Flavour::Media3);
        assert_eq!(
            r.plan.method,
            DeliveryMethod::DirectPlay,
            "{codec} {profile}.{compat}"
        );
        let bodies = asked(&net);
        assert_eq!(bodies.len(), 1, "{codec} {profile}.{compat}");
        assert_eq!(bodies[0]["EnableDirectPlay"], true);
    }
}

#[test]
fn dolby_vision_5_is_transcoded_only_on_a_device_without_a_dolby_vision_decoder() {
    let none = |flavour| StartRequest {
        no_dolby_vision_decoder: true,
        ..request(flavour)
    };
    let net = server(video("hevc", 5, 0), true);
    let r = play_with(&net, none(Flavour::Media3));
    assert_eq!(r.plan.method, DeliveryMethod::Transcode);
    assert!(r.plan.url.contains("master.m3u8"), "{}", r.plan.url);
    assert_eq!(asked(&net).len(), 2);
    // With a decoder (the default) profile 5 stays direct; profile 8 stays direct even without one (HEVC base layer).
    let net = server(video("hevc", 5, 0), true);
    assert_eq!(
        play(&net, Flavour::Media3).plan.method,
        DeliveryMethod::DirectPlay
    );
    let net = server(video("hevc", 8, 1), true);
    assert_eq!(
        play_with(&net, none(Flavour::Media3)).plan.method,
        DeliveryMethod::DirectPlay
    );
}
