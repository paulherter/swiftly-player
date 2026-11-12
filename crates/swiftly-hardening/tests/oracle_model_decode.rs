//! Differential oracle, domain `model_decode`: the Rust wire models must decode, re-encode and derive
//! exactly what the real Swift models do (Tools/Oracle, Domain_ModelDecode.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_model::item::UserItemData;
use swiftly_model::{
    Item, ItemKind, ItemsResponse, MediaSource, MediaStream, Person, PlaybackInfoResponse,
};

fn kind_name(k: ItemKind) -> &'static str {
    match k {
        ItemKind::Movie => "movie",
        ItemKind::Series => "series",
        ItemKind::Season => "season",
        ItemKind::Episode => "episode",
        ItemKind::Collection => "collection",
        ItemKind::Playlist => "playlist",
        ItemKind::Folder => "folder",
        ItemKind::Other => "other",
    }
}

fn item_derived(i: &Item) -> Value {
    json!({
        "direction": i.direction(),
        "actors": i.actors().iter().map(|p| p.id.clone()).collect::<Vec<_>>(),
        "container": i.is_container(),
        "share": i.watched_share(),
        "watched": i.is_watched(),
        "seconds": i.runtime_seconds(),
        "kind": kind_name(i.kind()),
        "lastPlay": i.user_data.as_ref().and_then(UserItemData::last_play),
        "series": Item::pre_common_series(i).map(|s| format!("{}|{}", s.id, s.name)),
    })
}

fn stream_derived(s: &MediaStream) -> Value {
    json!({
        "frame": s.frame_rate(),
        "real": s.real_frame_rate(),
        "average": s.average_frame_rate(),
        "dv": s.dv_profile(),
        "dvc": s.dv_bl_signal_compatibility_id(),
        "range": s.video_range_type().map(|r| r.raw_value()),
    })
}

fn source_derived(s: &MediaSource) -> Value {
    let d = s.delivery_method();
    json!({
        "seconds": s.runtime_seconds(),
        "height": s.height(),
        "wire": d.wire_name(),
        "raw": d.raw_value(),
        "lossless": d.is_lossless(),
        "streams": s.media_streams.iter().flatten().map(stream_derived).collect::<Vec<_>>(),
    })
}

macro_rules! decode {
    ($t:ty, $text:expr, $derive:expr) => {
        match serde_json::from_str::<$t>($text) {
            Ok(v) => json!({ "ok": true, "v": serde_json::to_value(&v).unwrap(), "d": ($derive)(&v) }),
            Err(_) => json!({ "ok": false }),
        }
    };
}

#[test]
fn model_decode() {
    assert_equal("model_decode", |c| {
        let text = c["json"].as_str().unwrap();
        match c["kind"].as_str().unwrap() {
            "item" => decode!(Item, text, item_derived),
            "items" => decode!(ItemsResponse, text, |r: &ItemsResponse| {
                json!({ "items": r.items.iter().map(item_derived).collect::<Vec<_>>(), "total": r.total_record_count })
            }),
            "source" => decode!(MediaSource, text, source_derived),
            "stream" => decode!(MediaStream, text, stream_derived),
            "playback" => decode!(PlaybackInfoResponse, text, |p: &PlaybackInfoResponse| {
                json!({ "sources": p.media_sources.iter().map(source_derived).collect::<Vec<_>>() })
            }),
            "user_data" => decode!(
                UserItemData,
                text,
                |u: &UserItemData| json!({ "lastPlay": u.last_play() })
            ),
            "person" => decode!(Person, text, |p: &Person| json!({ "cast": p.is_cast() })),
            other => panic!("kind {other}"),
        }
    });
}
