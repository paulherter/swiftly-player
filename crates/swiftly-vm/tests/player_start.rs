//! The play plan of the player screens on real-shaped server answers: the profile per engine,
//! several versions (#33), the resume clock (#43), the starting tracks, sections, chapters and
//! trickplay, the copy on the device and the failures.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::collections::HashMap;
use std::sync::Arc;

use common::account;
use common::script::{Script, host};
use futures_executor::block_on;
use swiftly_jellyfin::TrackIndices;
use swiftly_playback::device_profile::Flavour;
use swiftly_playback::track_rule::{AUDIO_KEY, SUBTITLE_KEY};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{
    DownloadedFile, MemoryDictionaries, NextSource, StartAnswer, StartRequest, StartSettings,
    play_start,
};

const STREAMS: &str = r#"[
 {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"DOVI"},
 {"Index":1,"Type":"Audio","Codec":"truehd","Language":"eng","Channels":8,"IsDefault":true},
 {"Index":2,"Type":"Audio","Codec":"ac3","Language":"ger","Channels":6},
 {"Index":3,"Type":"Audio","Codec":"aac","Language":"jpn","Channels":2,"IsOriginal":true},
 {"Index":4,"Type":"Subtitle","Codec":"subrip","Language":"eng"},
 {"Index":5,"Type":"Subtitle","Codec":"hdmv_pgs_subtitle","Language":"ger"},
 {"Index":6,"Type":"Subtitle","Codec":"srt","Language":"ger","IsExternal":true,"IsForced":true}
]"#;

fn sources(count: usize) -> serde_json::Value {
    let streams: serde_json::Value = serde_json::from_str(STREAMS).unwrap();
    serde_json::Value::Array(
        (0..count)
            .map(|n| {
                serde_json::json!({
                    "Id": format!("s{n}"), "Name": format!("Fassung {n}"), "Container": "mkv",
                    "Size": 10_000_000_000_i64 + n as i64, "SupportsDirectPlay": true,
                    "DefaultAudioStreamIndex": 1, "DefaultSubtitleStreamIndex": -1,
                    "MediaStreams": streams,
                })
            })
            .collect(),
    )
}

fn title(versions: usize, position_ticks: i64) -> serde_json::Value {
    serde_json::json!({
        "Id": "f1", "Name": "Film", "Type": "Movie", "RunTimeTicks": 72_000_000_000_i64,
        "MediaSources": sources(versions),
        "UserData": {"PlaybackPositionTicks": position_ticks}
    })
}

fn server(versions: usize, position_ticks: i64) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path().to_owned();
        let q = r.url.query().unwrap_or("").to_owned();
        if p.contains("/Items/s") {
            // A version is not a title of its own on this server: the title itself answers.
            return None;
        }
        if p.ends_with("/Items/f1") {
            let mut v = title(versions, position_ticks);
            if q.contains("Fields=Chapters") {
                v["Chapters"] = serde_json::json!([
                    {"Name": "Anfang", "StartPositionTicks": 0},
                    {"Name": " Mitte\n", "StartPositionTicks": 10_000_000_000_i64},
                    {"Name": "Ende", "StartPositionTicks": 50_000_000_000_i64}
                ]);
            }
            if q.contains("Fields=Trickplay") {
                v["Trickplay"] = serde_json::json!({"s0": {
                    "160": {"Width": 160, "Height": 90, "TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 720, "Interval": 10000},
                    "320": {"Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 720, "Interval": 10000}
                }});
            }
            return Some(v.to_string());
        }
        if p.ends_with("/Items/f1/PlaybackInfo") {
            let body = String::from_utf8(r.body.clone().unwrap_or_default()).unwrap();
            let mut chosen = sources(versions);
            if let Some(id) = body
                .split("\"MediaSourceId\":\"")
                .nth(1)
                .and_then(|s| s.split('"').next())
            {
                let all = chosen.as_array().unwrap().clone();
                chosen =
                    serde_json::Value::Array(all.into_iter().filter(|s| s["Id"] == id).collect());
            }
            return Some(
                serde_json::json!({"MediaSources": chosen, "PlaySessionId": "ps1"}).to_string(),
            );
        }
        if p.ends_with("/MediaSegments/f1") {
            return Some(
                serde_json::json!({"Items": [
                    {"Type": "Intro", "StartTicks": 100_000_000_i64, "EndTicks": 900_000_000_i64},
                    {"Type": "Outro", "StartTicks": 70_000_000_000_i64, "EndTicks": 72_000_000_000_i64}
                ]})
                .to_string(),
            );
        }
        Some("{}".into())
    })
}

fn settings() -> StartSettings {
    StartSettings {
        audio_language: String::new(),
        subtitle_language: "ger".into(),
        automatic_subtitles: false,
        max_bitrate: 120_000_000,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
        server_extracts_text: true,
    }
}

fn request(flavour: Flavour) -> StartRequest {
    StartRequest {
        item_id: "f1".into(),
        source_id: None,
        since: None,
        flavour,
        hardware_av1: false,
        no_dolby_vision_decoder: false,
        ask_versions: true,
        downloaded: None,
        ordered: None,
        account_key: Some("acct".into()),
        settings: settings(),
        next: NextSource::None,
    }
}

fn episode_server() -> Arc<Script> {
    Script::new(|r| {
        let p = r.url.path().to_owned();
        if p.ends_with("/Items/e1") {
            return Some(
                serde_json::json!({
                    "Id": "e1", "Name": "Folge 1", "Type": "Episode", "SeriesId": "sr",
                    "RunTimeTicks": 20_000_000_000_i64, "MediaSources": sources(1)
                })
                .to_string(),
            );
        }
        if p.ends_with("/Items/e1/PlaybackInfo") {
            return Some(
                serde_json::json!({"MediaSources": sources(1), "PlaySessionId": "ps1"}).to_string(),
            );
        }
        if p.ends_with("/Shows/sr/Episodes") {
            assert!(r.url.query().unwrap_or("").contains("adjacentTo=e1"));
            return Some(
                serde_json::json!({"Items": [
                    {"Id": "e1", "Name": "Folge 1", "Type": "Episode", "SeriesId": "sr"},
                    {"Id": "e2", "Name": "Folge 2", "Type": "Episode", "SeriesId": "sr"}
                ], "TotalRecordCount": 2})
                .to_string(),
            );
        }
        Some("{}".into())
    })
}

fn episode_request(next: NextSource) -> StartRequest {
    StartRequest {
        item_id: "e1".into(),
        ask_versions: false,
        next,
        ..request(Flavour::Aether)
    }
}

fn asked_series(net: &Arc<Script>) -> bool {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .any(|q| q.url.path().contains("/Shows/"))
}

#[test]
fn the_plan_names_the_next_episode_like_the_old_rule() {
    // Online: the server's `adjacentTo` answer.
    let net = episode_server();
    let rule = NextSource::Rule {
        downloads: Vec::new(),
        without_network: false,
    };
    let r = ready(ask(&net, &episode_request(rule.clone()), None));
    assert_eq!(r.next.as_ref().map(|i| i.id.as_str()), Some("e2"));
    // A film has none, and the server is not asked for it.
    let film = server(1, 0);
    let r = ready(ask(
        &film,
        &StartRequest {
            ask_versions: false,
            next: rule,
            ..request(Flavour::Aether)
        },
        None,
    ));
    assert!(r.next.is_none());
    assert!(!asked_series(&film));
    // Without network the server is not asked either; nothing downloaded means none.
    let off = episode_server();
    let none = NextSource::Rule {
        downloads: Vec::new(),
        without_network: true,
    };
    assert!(
        ready(ask(&off, &episode_request(none), None))
            .next
            .is_none()
    );
    assert!(!asked_series(&off));
    // A group plays without a next episode; a shuffled run names its own.
    let group = episode_server();
    assert!(
        ready(ask(&group, &episode_request(NextSource::None), None))
            .next
            .is_none()
    );
    let given = swiftly_model::Item {
        id: "x9".into(),
        ..Default::default()
    };
    let shuffled = ready(ask(
        &group,
        &episode_request(NextSource::Given(Some(Box::new(given)))),
        None,
    ));
    assert_eq!(shuffled.next.as_ref().map(|i| i.id.as_str()), Some("x9"));
}

fn ask(net: &Arc<Script>, r: &StartRequest, memory: Option<&MemoryDictionaries>) -> StartAnswer {
    let m = memory.map(|m| m as &dyn swiftly_vm::TrackMemoryStore);
    block_on(play_start(net.clone(), &host(), &account("TOKEN-A"), r, m)).unwrap()
}

fn ready(a: StartAnswer) -> Box<swiftly_vm::ReadyStart> {
    match a {
        StartAnswer::Ready(r) => r,
        other => panic!("not ready: {other:?}"),
    }
}

fn sent_profile(net: &Arc<Script>) -> serde_json::Value {
    let seen = net.seen.lock().unwrap();
    let r = seen
        .iter()
        .find(|r| r.url.path().ends_with("/PlaybackInfo"))
        .unwrap();
    let body: serde_json::Value = serde_json::from_slice(r.body.as_ref().unwrap()).unwrap();
    body["DeviceProfile"].clone()
}

#[test]
fn each_engine_asks_with_its_own_profile() {
    let aether = server(1, 0);
    ready(ask(&aether, &request(Flavour::Aether), None));
    let av = server(1, 0);
    ready(ask(&av, &request(Flavour::AirPlay { av1: false }), None));
    let av1 = server(1, 0);
    ready(ask(&av1, &request(Flavour::AirPlay { av1: true }), None));
    let a = sent_profile(&aether);
    let b = sent_profile(&av);
    let c = sent_profile(&av1);
    assert_eq!(
        a,
        swiftly_playback::device_profile::DeviceProfile::vlc(120_000_000).to_json()
    );
    assert_eq!(
        b,
        swiftly_playback::device_profile::DeviceProfile::airplay(120_000_000, false).to_json()
    );
    assert_eq!(
        c,
        swiftly_playback::device_profile::DeviceProfile::airplay(120_000_000, true).to_json()
    );
    assert_ne!(a, b);
    assert_ne!(b, c);
}

#[test]
fn the_plan_carries_session_streams_and_the_default_tracks() {
    let net = server(1, 0);
    let r = ready(ask(&net, &request(Flavour::Aether), None));
    assert_eq!(r.plan.play_session_id.as_deref(), Some("ps1"));
    assert_eq!(r.plan.media_source_id.as_deref(), Some("s0"));
    assert_eq!(r.streams.len(), 7);
    // Server default audio (truehd), subtitles: the forced German file (forced track wins when
    // automatic subtitles are off and the server default is "off").
    assert_eq!(r.audio, Some(1));
    assert_eq!(r.subtitle, 6);
    // No series: the memory key is the account and the film's own id.
    assert_eq!(r.track_title, "acct|f1");
    // The raw source rides along: the whole streams (`IsOriginal`) that the reduced list cannot carry.
    let source = r.source.as_ref().expect("the chosen version");
    assert_eq!(source.id.as_deref(), Some("s0"));
    let streams = source.media_streams.as_ref().expect("streams");
    assert_eq!(streams.len(), 7);
    assert_eq!(streams[3].is_original, Some(true));
    // The display facts: Dolby Vision file untouched, the default sound track's codec, a file line.
    assert_eq!(r.display.audio_codec.as_deref(), Some("truehd"));
    assert_eq!(r.display.dolby_vision, Some(0));
    assert!(
        r.display
            .file_row
            .as_deref()
            .is_some_and(|l| l.contains("2160p"))
    );
    assert!(!r.display.episode);
}

#[test]
fn the_display_of_an_episode_names_the_series_and_the_next_card() {
    let net = episode_server();
    let rule = NextSource::Rule {
        downloads: Vec::new(),
        without_network: false,
    };
    let r = ready(ask(&net, &episode_request(rule), None));
    assert!(r.display.episode);
    assert_eq!(r.display.next.as_ref().map(|n| n.id.as_str()), Some("e2"));
    // The server's list entry carries no numbers: the card shows the name, the header the title itself.
    assert_eq!(
        r.display.next.as_ref().map(|n| n.abbreviation.as_str()),
        Some("Folge 2")
    );
    assert_eq!(r.display.header_line, "Folge 1");
    assert_eq!(r.display.series, None);
}

#[test]
fn several_versions_are_asked_first_and_the_pick_starts_that_one() {
    // #33: with several versions and nothing picked the answer is the choice, not a start.
    let net = server(2, 0);
    let StartAnswer::Choose {
        versions, since, ..
    } = ask(&net, &request(Flavour::Aether), None)
    else {
        panic!("expected the version choice");
    };
    assert_eq!(versions.len(), 2);
    assert_eq!(versions[1].id, "s1");
    assert_eq!(since, 0.0);
    assert_eq!(
        net.count("/PlaybackInfo"),
        0,
        "no plan is fetched for nothing"
    );
    let mut picked = request(Flavour::Aether);
    picked.source_id = Some("s1".into());
    let r = ready(ask(&net, &picked, None));
    assert_eq!(r.plan.media_source_id.as_deref(), Some("s1"));
    // A caller that cannot ask gets the server's default.
    let mut silent = request(Flavour::Aether);
    silent.ask_versions = false;
    let r = ready(ask(&net, &silent, None));
    assert!(r.plan.media_source_id.is_some());
}

#[test]
fn the_resume_clock_follows_the_old_rule() {
    // #43: under a minute starts over, near the end starts over, otherwise the position.
    for (ticks, expect) in [
        (300_000_000_i64, 0.0),
        (1_800_000_000, 180.0),
        (71_500_000_000, 0.0),
        (71_000_000_000, 7100.0),
        (36_000_000_000, 3600.0),
    ] {
        let net = server(1, ticks);
        let r = ready(ask(&net, &request(Flavour::Aether), None));
        assert!(
            (r.start_at - expect).abs() < 1e-9,
            "{ticks}: {}",
            r.start_at
        );
    }
    // A given start beats the remembered one ("play from start", a remote order).
    let net = server(1, 36_000_000_000);
    let mut from_start = request(Flavour::Aether);
    from_start.since = Some(0.0);
    assert_eq!(ready(ask(&net, &from_start, None)).start_at, 0.0);
}

#[test]
fn sections_chapters_and_trickplay_arrive_with_the_start() {
    let net = server(1, 0);
    let r = ready(ask(&net, &request(Flavour::Aether), None));
    assert_eq!(r.sections.len(), 2);
    assert!((r.sections[0].from - 10.0).abs() < 1e-9);
    assert_eq!(r.chapters.len(), 3);
    assert_eq!(r.chapters[1].name, "Mitte");
    let t = r.trickplay.expect("trickplay");
    assert_eq!(t.width, 320);
}

#[test]
fn the_starting_tracks_follow_memory_then_default_and_an_order_beats_both() {
    let net = server(1, 0);
    // Remembered subtitle: off for this film.
    let mut memory = MemoryDictionaries::default();
    memory.0.insert(
        SUBTITLE_KEY.into(),
        HashMap::from([("acct|f1".into(), String::new())]),
    );
    let r = ready(ask(&net, &request(Flavour::Aether), Some(&memory)));
    assert_eq!(r.subtitle, -1);
    // An order from another client wins.
    let mut ordered = request(Flavour::Aether);
    ordered.ordered = Some(TrackIndices {
        audio: Some(3),
        subtitle: Some(4),
    });
    let r = ready(ask(&net, &ordered, Some(&memory)));
    assert_eq!((r.audio, r.subtitle), (Some(3), 4));
    // Audio language from the settings.
    let mut german = request(Flavour::Aether);
    german.settings.audio_language = "Deutsch".into();
    let r = ready(ask(&net, &german, None));
    assert_eq!(r.audio, Some(2));
    let _ = AUDIO_KEY;
}

#[test]
fn a_copy_on_the_device_plays_without_the_plan_request() {
    let net = server(1, 1_800_000_000);
    let mut r = request(Flavour::Aether);
    r.downloaded = Some(DownloadedFile {
        file: "file:///var/Downloads/f1.mkv".into(),
        container: Some("mkv".into()),
        source: Some("s0".into()),
        video_codec: Some("hevc".into()),
        sections: Some(vec![swiftly_playback::sections::Segment::new(
            swiftly_playback::sections::Art::IntroSegment,
            5.0,
            50.0,
        )]),
        subtitle_files: Vec::new(),
    });
    let ready = ready(ask(&net, &r, None));
    assert_eq!(net.count("/PlaybackInfo"), 0);
    assert_eq!(ready.plan.url, "file:///var/Downloads/f1.mkv");
    assert!(ready.plan.play_session_id.is_none());
    assert_eq!(ready.sections.len(), 1);
    assert_eq!(ready.start_at, 180.0);
}

#[test]
fn a_rejection_and_a_missing_source_are_told_apart() {
    let rejected = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Items/f1") {
            return Some(title(1, 0).to_string());
        }
        if p.ends_with("/PlaybackInfo") {
            return Some(
                serde_json::json!({"MediaSources": [], "ErrorCode": "NotAllowed"}).to_string(),
            );
        }
        Some("{}".into())
    });
    let mut one = request(Flavour::Aether);
    one.ask_versions = false;
    assert!(matches!(ask(&rejected, &one, None), StartAnswer::Failed(_)));
    let none = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Items/f1") {
            return Some(title(1, 0).to_string());
        }
        if p.ends_with("/PlaybackInfo") {
            return Some(serde_json::json!({"MediaSources": []}).to_string());
        }
        Some("{}".into())
    });
    assert!(matches!(ask(&none, &one, None), StartAnswer::NoSource));
}

/// An external ASS file next to the film goes to the engines that draw it themselves (Apple engine, desktop, Media3).
/// Media3 was missing from that list: the Android app listed no track for it.
#[test]
fn an_external_styled_file_reaches_the_media3_engine() {
    let streams = serde_json::json!([
        {"Index":0,"Type":"Video","Codec":"h264","Width":320,"Height":180},
        {"Index":1,"Type":"Audio","Codec":"aac","Language":"eng","Channels":2,"IsDefault":true},
        {"Index":2,"Type":"Subtitle","Codec":"ass","Language":"eng","IsExternal":true,"IsTextSubtitleStream":true,
         "DeliveryMethod":"External","DeliveryUrl":"/Videos/f1/s0/Subtitles/2/0/Stream.ssa"}
    ]);
    let source = serde_json::json!([{"Id":"s0","Name":"A","Container":"mp4","Size":1000,"SupportsDirectPlay":true,
        "DefaultAudioStreamIndex":1,"DefaultSubtitleStreamIndex":-1,"MediaStreams":streams}]);
    let item = serde_json::json!({"Id":"f1","Name":"Film","Type":"Movie","RunTimeTicks":100_000_000_i64,"MediaSources":source});
    let net = Script::new(move |r| {
        let p = r.url.path().to_owned();
        if p.ends_with("/Items/f1") {
            return Some(item.to_string());
        }
        if p.ends_with("/Items/f1/PlaybackInfo") {
            return Some(
                serde_json::json!({"MediaSources":source,"PlaySessionId":"ps"}).to_string(),
            );
        }
        Some("{}".into())
    });
    for flavour in [Flavour::Aether, Flavour::Mpv, Flavour::Media3] {
        let mut r = request(flavour);
        r.ask_versions = false;
        r.settings.server_extracts_text = false;
        let files: Vec<i64> = ready(ask(&net, &r, None))
            .subtitle_files
            .iter()
            .map(|f| f.index)
            .collect();
        assert_eq!(files, vec![2], "{flavour:?}");
    }
}
