//! The Plex side of the old `Kern` calls on the core: download post, library sections, collections and playlists,
//! against a scripted Plex server (the same shapes `cargo xtask fixture-server` serves to the emulators).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::script::{Script, host};
use swiftly_jellyfin::ServerKind;
use swiftly_vm::{AccountRef, LegacyPlexDetail, LegacySection};

const SECTIONS: &str = include_str!("../../swiftly-plex/tests/fixtures/sections.json");
const MOVIE: &str = include_str!("../../swiftly-plex/tests/fixtures/movie.json");

fn account() -> AccountRef {
    AccountRef {
        base_url: "https://plex.example.test".into(),
        user_id: "u1".into(),
        token: "TOKEN".into(),
        server_kind: ServerKind::Plex,
        device_id: "dev-1".into(),
        plex_machine_id: None,
        plex_account_token: None,
    }
}

fn server() -> Arc<Script> {
    Script::new(|r| {
        let p = r.url.path();
        let meta = |l: &str| Some(format!(r#"{{"MediaContainer":{{"Metadata":[{l}]}}}}"#));
        Some(if p.ends_with("/library/sections") {
            SECTIONS.into()
        } else if p.ends_with("/library/sections/1/collections") {
            return meta(
                r#"{"ratingKey":"40","type":"collection","title":"Sammlung","childCount":1}"#,
            );
        } else if p.ends_with("/collections/40/children") || p.ends_with("/playlists/41/items") {
            return meta(
                &(10..13)
                    .map(|k| {
                        format!(
                            r#"{{"ratingKey":"{k}","type":"movie","title":"Film {k}","year":2020}}"#
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(","),
            );
        } else if p.ends_with("/playlists") {
            return meta(
                r#"{"ratingKey":"41","type":"playlist","title":"Liste","playlistType":"video","leafCount":1}"#,
            );
        } else if p.ends_with("/library/metadata/1") {
            MOVIE.into()
        } else {
            r#"{"MediaContainer":{"size":0}}"#.into()
        })
    })
}

#[test]
fn plex_download_item_posts_the_first_part_of_the_movie() {
    futures_executor::block_on(async {
        let net = server();
        let d = LegacyPlexDetail::new(&net, &host(), &account()).unwrap();
        let answer: serde_json::Value =
            serde_json::from_str(&d.download_item(&["1".into()]).await).unwrap();
        let post = &answer[0]["posten"];
        assert_eq!(post["id"], "1", "{answer}");
        assert!(post.is_object(), "{answer}");
        assert!(net.count("/library/metadata/1") >= 1);
        // An unknown title is left out, not an error.
        assert_eq!(d.download_item(&["999".into()]).await, "[]");
    });
}

#[test]
fn plex_sections_collections_and_playlists_answer_from_the_core() {
    futures_executor::block_on(async {
        let net = server();
        let s = LegacySection::new(&net, &host(), &account()).unwrap();
        let c = s.collections("movies").await.unwrap();
        assert!(c.contains("Sammlung"), "{c} {:?}", net.urls());
        let p = s.playlists("movies").await.unwrap();
        assert!(p.contains("Liste"), "{p}");
        let o = s.section_offering("movies", "").await.unwrap();
        assert!(!o.is_empty());
        assert!(net.count("/library/sections") >= 1);
    });
}
