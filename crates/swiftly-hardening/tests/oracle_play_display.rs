//! Differential oracle, group "play display": the display facts the core hands the player screens (`swiftly_vm::play_display`)
//! equal the Swift expressions of the screens (Tools/Oracle, Domain_PlayDisplay.swift). English text (the oracle process speaks English).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_images::ImageAddress;
use swiftly_jellyfin::ServerKind;
use swiftly_model::{DeliveryMethod, Item, MediaSource};

fn method(text: &str) -> DeliveryMethod {
    match text {
        "Direct Stream" => DeliveryMethod::DirectStream,
        "Transcode" => DeliveryMethod::Transcode,
        _ => DeliveryMethod::DirectPlay,
    }
}

#[test]
fn play_display() {
    assert_equal("play_display", |c| {
        let item: Item = serde_json::from_value(c["item"].clone()).expect("item");
        let source: Option<MediaSource> = (!c["source"].is_null())
            .then(|| serde_json::from_value(c["source"].clone()).expect("source"));
        let next: Option<Item> = (!c["next"].is_null())
            .then(|| serde_json::from_value(c["next"].clone()).expect("next"));
        let addresses = c["base"]
            .as_str()
            .and_then(|b| url::Url::parse(b).ok())
            .map(|base| {
                ImageAddress::new(
                    base,
                    c["token"].as_str().map(str::to_owned),
                    ServerKind::Jellyfin,
                )
            });
        let d = swiftly_vm::play_display(
            &item,
            method(c["method"].as_str().unwrap_or("")),
            source.as_ref(),
            next.as_ref(),
            addresses.as_ref(),
            swiftly_l10n::Locale::parse("en"),
        );
        json!({
            "context_line": d.context_line,
            "file_row": d.file_row,
            "series": d.series,
            "abbreviation": d.abbreviation,
            "image": d.image,
            "episode": d.episode,
            "season_id": d.season_id,
            "season_number": d.season_number,
            "episode_number": d.episode_number,
            "header_line": d.header_line,
            "secondary_line": d.secondary_line,
            "meta_line": d.meta_line,
            "card_image": d.card_image,
            "dolby_vision": d.dolby_vision,
            "audio_codec": d.audio_codec,
            "next": d.next.map_or(Value::Null, |n| json!({"id": n.id, "name": n.name, "abbreviation": n.abbreviation, "image": n.image})),
        })
    });
}
