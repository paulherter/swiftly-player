//! Differential proof for `ClientConfig::lean_tiles`: a lean answer (no `Overview`, only the
//! poster picture type, no backdrop tags) builds exactly the same tile as the full answer for
//! every item kind the poster rails and grids show. The request side is in
//! `swiftly-jellyfin/tests/lean_tiles.rs`; the demo-server comparison is in `perf-speed.md`.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_jellyfin::{ClientConfig, JellyfinClient, ServerKind, Session};
use swiftly_l10n::Locale;
use swiftly_model::Item;
use swiftly_net::MockTransport;
use swiftly_vm::poster_tiles;

fn client() -> JellyfinClient<MockTransport> {
    let c = JellyfinClient::new(
        MockTransport::new(),
        "https://tv.example.de",
        ClientConfig::new("dev", "Test", "1.0").lean_tiles(true),
    )
    .unwrap();
    c.set_session(Some(Session {
        access_token: "T".into(),
        user_id: "u1".into(),
        user_name: "t".into(),
        server_url: "https://tv.example.de".into(),
        kind: ServerKind::Jellyfin,
    }));
    c
}

/// The server's full answer for a kind and what the lean query would return for the same item.
fn pairs() -> Vec<(serde_json::Value, serde_json::Value)> {
    let mut out = Vec::new();
    for (kind, extra) in [
        ("Movie", serde_json::json!({})),
        ("Series", serde_json::json!({})),
        (
            "Episode",
            serde_json::json!({"SeriesId": "s1", "SeriesName": "Serie", "SeriesPrimaryImageTag": "sp",
                "ParentIndexNumber": 2, "IndexNumber": 5}),
        ),
        ("BoxSet", serde_json::json!({})),
    ] {
        for n in 0..4 {
            let mut full = serde_json::json!({
                "Id": format!("{kind}{n}"), "Name": format!("Titel {n}"), "Type": kind,
                "ProductionYear": 1990 + n, "Overview": "A long description that tiles never show.",
                "RunTimeTicks": 54_000_000_000_i64 + n,
                "ImageTags": {"Primary": format!("p{n}"), "Thumb": "t", "Logo": "l", "Banner": "b"},
                "BackdropImageTags": ["bd1", "bd2"],
                "ImageBlurHashes": {"Primary": {format!("p{n}"): "LEHV6nWB2yk8pyo0adR*.7kCMdnj"}},
                "UserData": {"Played": n % 2 == 0, "IsFavorite": n % 3 == 0,
                    "PlayedPercentage": 12.5, "UnplayedItemCount": n},
            });
            for (k, v) in extra.as_object().unwrap() {
                full[k] = v.clone();
            }
            let mut lean = full.clone();
            let o = lean.as_object_mut().unwrap();
            o.remove("Overview");
            o["ImageTags"] = serde_json::json!({"Primary": format!("p{n}")});
            o["BackdropImageTags"] = serde_json::json!([]);
            out.push((full, lean));
        }
    }
    out
}

#[test]
fn lean_and_full_answers_build_identical_tiles() {
    let c = client();
    let (full, lean): (Vec<Item>, Vec<Item>) = pairs()
        .into_iter()
        .map(|(f, l)| {
            (
                serde_json::from_value::<Item>(f).unwrap(),
                serde_json::from_value::<Item>(l).unwrap(),
            )
        })
        .unzip();
    let a = poster_tiles(&full, &c, Locale::parse("de"));
    let b = poster_tiles(&lean, &c, Locale::parse("de"));
    assert_eq!(a.len(), 16);
    assert_eq!(a, b);
}
