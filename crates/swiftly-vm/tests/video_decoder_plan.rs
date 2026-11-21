//! The plan reads what the device decodes (Android: `MediaCodecList`): a title with no decoder on the device
//! is asked of the server as a transcode, every title it can decode stays direct play, and a title whose
//! start the decoder refused is transcoded whatever its data says.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::account;
use common::script::{Script, host};
use futures_executor::block_on;
use swiftly_model::DeliveryMethod;
use swiftly_playback::device_profile::Flavour;
use swiftly_playback::video_decoders::VideoDecoders;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{NextSource, StartAnswer, StartRequest, StartSettings, play_start};

fn video(codec: &str, bit_depth: i64) -> serde_json::Value {
    serde_json::json!([
        {"Index": 0, "Type": "Video", "Codec": codec, "Width": 1920, "Height": 1080, "BitDepth": bit_depth},
        {"Index": 1, "Type": "Audio", "Codec": "aac", "Language": "eng", "Channels": 2, "IsDefault": true}
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
                    "/videos/f1/master.m3u8?MediaSourceId=s0&VideoCodec=h264".into();
                source["TranscodingSubProtocol"] = "hls".into();
            }
            return Some(
                serde_json::json!({"MediaSources": [source], "PlaySessionId": "ps1"}).to_string(),
            );
        }
        Some("{}".into())
    })
}

fn request(decoders: VideoDecoders) -> StartRequest {
    StartRequest {
        item_id: "f1".into(),
        source_id: None,
        since: None,
        flavour: Flavour::Media3,
        hardware_av1: false,
        no_dolby_vision_decoder: false,
        video_decoders: decoders,
        decoder_refused: false,
        ask_versions: false,
        downloaded: None,
        ordered: None,
        account_key: Some("acct".into()),
        settings: StartSettings {
            audio_language: String::new(),
            subtitle_language: "ger".into(),
            automatic_subtitles: false,
            device_language: None,
            max_bitrate: 120_000_000,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            server_extracts_text: true,
        },
        next: NextSource::None,
    }
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

/// The emulator and many budget phones: H.264 and HEVC Main, no AV1, no 10-bit HEVC.
fn plain_device() -> VideoDecoders {
    VideoDecoders::probed()
        .with("h264", false, 4096, 2304)
        .with("hevc", false, 4096, 2304)
}

/// A recent phone.
fn modern_device() -> VideoDecoders {
    VideoDecoders::probed()
        .with("h264", false, 4096, 2304)
        .with("hevc", true, 8192, 4320)
        .with("av1", true, 8192, 4320)
}

#[test]
fn a_title_without_a_decoder_on_the_device_is_transcoded_by_the_server() {
    for (codec, depth) in [("av1", 8), ("av1", 10), ("hevc", 10)] {
        let net = server(video(codec, depth), true);
        let r = play_with(&net, request(plain_device()));
        assert_eq!(r.plan.method, DeliveryMethod::Transcode, "{codec} {depth}");
        assert!(r.plan.url.contains("master.m3u8"), "{}", r.plan.url);
        let bodies = asked(&net);
        assert_eq!(bodies.len(), 2, "{codec} {depth}");
        assert_eq!(bodies[0]["EnableDirectPlay"], true);
        assert_eq!(bodies[1]["EnableDirectPlay"], false);
        assert_eq!(bodies[1]["EnableDirectStream"], false);
        assert_eq!(bodies[1]["EnableTranscoding"], true);
    }
}

#[test]
fn a_title_the_device_decodes_keeps_its_one_request_and_direct_play() {
    // The plain device decodes H.264 and 8-bit HEVC; the modern one decodes AV1 and 10-bit HEVC as well.
    for (decoders, codec, depth) in [
        (plain_device(), "h264", 8),
        (plain_device(), "hevc", 8),
        (modern_device(), "h264", 8),
        (modern_device(), "hevc", 10),
        (modern_device(), "av1", 10),
        // A host that reports nothing restricts nothing (Apple, desktop, an old Android build).
        (VideoDecoders::default(), "av1", 10),
        (VideoDecoders::default(), "hevc", 10),
    ] {
        let net = server(video(codec, depth), true);
        let r = play_with(&net, request(decoders));
        assert_eq!(r.plan.method, DeliveryMethod::DirectPlay, "{codec} {depth}");
        let bodies = asked(&net);
        assert_eq!(bodies.len(), 1, "{codec} {depth}");
        assert_eq!(bodies[0]["EnableDirectPlay"], true);
    }
}

#[test]
fn a_title_the_decoder_refused_at_the_start_is_transcoded_whatever_it_is() {
    // The device claims everything, the decoder fails at the first frame: the retry asks for a transcode.
    let net = server(video("h264", 8), true);
    let r = play_with(
        &net,
        StartRequest {
            decoder_refused: true,
            ..request(modern_device())
        },
    );
    assert_eq!(r.plan.method, DeliveryMethod::Transcode);
    let bodies = asked(&net);
    assert_eq!(bodies.len(), 2);
    assert_eq!(bodies[1]["EnableDirectPlay"], false);
}

#[test]
fn a_server_that_cannot_transcode_keeps_the_original_plan() {
    // The engine's own error stays for this case.
    let net = server(video("av1", 10), false);
    let r = play_with(&net, request(plain_device()));
    assert_eq!(r.plan.method, DeliveryMethod::DirectPlay);
    assert_eq!(asked(&net).len(), 2);
}
