//! Real-looking server answers (sanitized Emby 4.10 responses taken from
//! `EmbyFixtures.swift`) decoded with the same assertions as `EmbyTests.swift`.

#![allow(clippy::expect_used)]

use std::collections::HashSet;

use swiftly_model::{
    AuthenticationResult, DeliveryMethod, Item, ItemKind, ItemsResponse, PlaybackInfoResponse,
};

fn load(name: &str) -> String {
    std::fs::read_to_string(format!(
        "{}/tests/fixtures/{name}",
        env!("CARGO_MANIFEST_DIR")
    ))
    .expect("fixture")
}

/// EmbyTests.swift:169 `decodeAuthentication`.
#[test]
fn authentication() {
    let r: AuthenticationResult =
        serde_json::from_str(&load("emby_authenticate.json")).expect("decode");
    assert_eq!(r.access_token, "TOKEN");
    assert_eq!(r.user.name, "tester");
    assert_eq!(r.server_id.as_deref(), Some("SERVER"));
}

/// EmbyTests.swift:176 `decodeMovie`.
#[test]
fn movie_with_two_versions() {
    let movie: Item = serde_json::from_str(&load("emby_movie.json")).expect("decode");
    assert_eq!(movie.name, "Testfilm");
    assert_eq!(movie.id, "8");
    assert_eq!(movie.kind(), ItemKind::Movie);
    assert!(!movie.is_container());
    let sources = movie.media_sources.as_ref().expect("sources");
    assert_eq!(sources.len(), 2);
    let names: HashSet<&str> = sources.iter().filter_map(|s| s.name.as_deref()).collect();
    assert_eq!(names, ["1080p", "720p"].into_iter().collect());
    let first = &sources[0];
    let streams = first.media_streams.as_ref().expect("streams");
    let count = |t: &str| {
        streams
            .iter()
            .filter(|s| s.type_.as_deref() == Some(t))
            .count()
    };
    assert_eq!(count("Audio"), 2);
    assert_eq!(count("Subtitle"), 1);
    // Extra facts the Swift model reads from the same sample.
    assert_eq!(first.height(), Some(1080));
    assert_eq!(first.video_codec(), Some("h264"));
    assert_eq!(first.delivery_method(), DeliveryMethod::DirectPlay);
    let video = first.video_track().expect("video");
    assert_eq!(video.frame_rate(), Some(24.0));
    assert!(
        movie
            .image_tags
            .as_ref()
            .is_some_and(|t| t.contains_key("Primary"))
    );
}

/// EmbyTests.swift:188 `decodePlaybackInfo`.
#[test]
fn playback_info_direct_play() {
    let info: PlaybackInfoResponse =
        serde_json::from_str(&load("emby_playbackInfo.json")).expect("decode");
    assert_eq!(info.media_sources.len(), 2);
    let first = &info.media_sources[0];
    assert_eq!(first.supports_direct_play, Some(true));
    assert!(first.transcoding_url.is_none());
}

/// EmbyTests.swift:91 `embyRequests`: the views list contains "Filme".
#[test]
fn views_contain_filme() {
    let views: ItemsResponse = serde_json::from_str(&load("emby_views.json")).expect("decode");
    assert!(views.items.iter().any(|i| i.name == "Filme"));
    assert_eq!(views.total_record_count, 4);
    assert!(
        views
            .items
            .iter()
            .all(|i| i.kind() == ItemKind::Folder && i.is_container())
    );
}
