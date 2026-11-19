//! What the server says about a title's file and how the app would play it (read only; nothing is reported, nothing is
//! marked). Uses the app's own sign-in (`SWIFTLY_CONFIG_DIR`, a copy of the app's config dir) and its own planner
//! (`Core::prepare_play`). Prints only facts about the file, never an address with its query or any credential.
//!
//! usage: `SWIFTLY_CONFIG_DIR=<copy of the config dir> cargo run -p swiftly-desktop --example stream_facts -- <item-id>...`

#![allow(clippy::expect_used)]

use std::time::Duration;
use swiftly_desktop::live::Core;
use swiftly_desktop::live_play::{PlayRequest, Prepared};
use swiftly_desktop::live_server::Server;

/// Item fields worth reading; everything else (paths, addresses) stays unprinted.
const FILE_FIELDS: &[&str] = &[
    "Container",
    "Size",
    "Bitrate",
    "RunTimeTicks",
    "VideoType",
    "Protocol",
];
const VIDEO_FIELDS: &[&str] = &[
    "Codec",
    "Profile",
    "Level",
    "BitDepth",
    "PixelFormat",
    "IsInterlaced",
    "VideoRange",
    "VideoRangeType",
    "Width",
    "Height",
    "RealFrameRate",
    "AverageFrameRate",
    "BitRate",
    "RefFrames",
    "IsAVC",
    "NalLengthSize",
    "AspectRatio",
    "ColorSpace",
    "ColorTransfer",
    "ColorPrimaries",
    "ColorRange",
    "TimeBase",
];
const AUDIO_FIELDS: &[&str] = &[
    "Codec",
    "Profile",
    "Channels",
    "ChannelLayout",
    "SampleRate",
    "BitRate",
    "Language",
    "IsDefault",
];
const SUBTITLE_FIELDS: &[&str] = &[
    "Codec",
    "Language",
    "IsExternal",
    "IsTextSubtitleStream",
    "IsForced",
    "IsDefault",
];

fn pick(o: &serde_json::Value, fields: &[&str]) -> String {
    fields
        .iter()
        .filter_map(|f| {
            o.get(*f)
                .filter(|v| !v.is_null())
                .map(|v| format!("{f}={v}"))
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn main() {
    let ids: Vec<String> = std::env::args().skip(1).collect();
    let core = Core::open().expect("open the stores");
    let account = core
        .account()
        .expect("no stored account in SWIFTLY_CONFIG_DIR");
    let server = core.server_for(&account).expect("client");
    for id in ids {
        println!("== item {id}");
        if let Server::Jellyfin(client) = &server {
            let raw = core.handle().block_on(client.raw_json(
                &format!("Items/{id}"),
                &[("userId", account.user_id.as_str())],
            ));
            match raw {
                Ok(item) => {
                    println!(
                        "  {} {:?} S{:?}E{:?} {:?}",
                        item["Type"].as_str().unwrap_or("?"),
                        item["Name"].as_str().unwrap_or("?"),
                        item["ParentIndexNumber"],
                        item["IndexNumber"],
                        item["SeriesName"].as_str().unwrap_or("")
                    );
                    for src in item["MediaSources"].as_array().into_iter().flatten() {
                        println!("  source {}", pick(src, FILE_FIELDS));
                        for s in src["MediaStreams"].as_array().into_iter().flatten() {
                            match s["Type"].as_str() {
                                Some("Video") => println!("    video {}", pick(s, VIDEO_FIELDS)),
                                Some("Audio") => println!("    audio {}", pick(s, AUDIO_FIELDS)),
                                Some("Subtitle") => {
                                    println!("    sub   {}", pick(s, SUBTITLE_FIELDS))
                                }
                                _ => {}
                            }
                        }
                    }
                }
                Err(e) => println!("  item: {e:?}"),
            }
        }
        let pending = core.prepare_play(
            &account,
            PlayRequest {
                item_id: id.clone(),
                since: 0.0,
                source_id: None,
            },
        );
        match pending.0.recv_timeout(Duration::from_secs(30)) {
            Ok(Ok(Prepared::Ready(r))) => {
                let url = r.url();
                let path = url.split('?').next().unwrap_or("");
                // The address up to its query, with the host cut off: the path says direct file or HLS.
                let path = path.splitn(4, '/').nth(3).unwrap_or(path);
                let tech = r.tech();
                println!(
                    "  plan: {} (good={}) path=/{} software_decode={}",
                    tech.map_or("?", |t| t.delivery.as_str()),
                    tech.is_some_and(|t| t.good),
                    path,
                    r.software_decode()
                );
                if let Some(reason) = tech.and_then(|t| t.reason.as_deref()) {
                    println!("  transcode reason: {reason}");
                }
                // The query's parameter names (not values): `Static`, `VideoCodec`, `SubtitleMethod`, ...
                if let Some(q) = url.split_once('?').map(|p| p.1) {
                    let names: Vec<String> = q
                        .split('&')
                        .filter_map(|kv| kv.split_once('='))
                        .filter(|(k, _)| {
                            !k.eq_ignore_ascii_case("api_key")
                                && !k.eq_ignore_ascii_case("ApiKey")
                                && !k.to_ascii_lowercase().contains("token")
                                && !k.to_ascii_lowercase().contains("deviceid")
                        })
                        .map(|(k, v)| {
                            if v.len() < 40 {
                                format!("{k}={v}")
                            } else {
                                k.to_owned()
                            }
                        })
                        .collect::<Vec<_>>();
                    println!("  query: {}", names.join("&"));
                }
            }
            Ok(Err(e)) => println!("  plan failed: {e}"),
            Err(_) => println!("  plan timed out"),
        }
    }
}
