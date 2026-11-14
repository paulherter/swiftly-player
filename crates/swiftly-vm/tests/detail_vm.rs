//! The detail view model against a scripted server: fresh title completes the entry, Play is
//! gray until the versions are known, resume label, version choice, watched and watchlist
//! toggles (switch at once, put back on failure), bottom sections arriving together.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::account;
use common::script::{Script, host, list, wait_for};
use swiftly_model::Item;
use swiftly_vm::{DetailIntent, DetailVm, PlayAction, part};

fn entry() -> Item {
    serde_json::from_value(serde_json::json!({
        "Id": "f1", "Name": "Film", "Type": "Movie", "ProductionYear": 2019,
        "UserData": {"Played": false, "IsFavorite": false}
    }))
    .unwrap()
}

fn full(sources: usize, position_ticks: i64) -> serde_json::Value {
    let sources: Vec<_> = (0..sources)
        .map(|n| serde_json::json!({"Id": format!("s{n}"), "Name": format!("V{n}")}))
        .collect();
    serde_json::json!({
        "Id": "f1", "Name": "Film", "Type": "Movie", "ProductionYear": 2019,
        "RunTimeTicks": 72_000_000_000_i64, "Genres": ["Drama", "Krimi", "Mist"],
        "Overview": "Text", "MediaSources": sources,
        "People": [{"Id": "p1", "Name": "A", "Type": "Actor", "Role": "R"},
                   {"Id": "p2", "Name": "B", "Type": "Director"}],
        "UserData": {"Played": true, "IsFavorite": true, "PlaybackPositionTicks": position_ticks}
    })
}

fn server(sources: usize, position_ticks: i64) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path();
        if p.ends_with("/Items/f1") {
            return Some(full(sources, position_ticks).to_string());
        }
        if p.ends_with("/Similar") {
            let a = serde_json::json!({"Id": "f1", "Name": "Film", "Type": "Movie"});
            let b = serde_json::json!({"Id": "o1", "Name": "Anderer", "Type": "Movie"});
            return Some(list(&[a, b.clone(), b], 3));
        }
        if p.ends_with("/SpecialFeatures") {
            return Some(
                serde_json::json!([{"Id": "x1", "Name": "Making of", "Type": "Video"}]).to_string(),
            );
        }
        Some("{}".into())
    })
}

fn vm(net: &Arc<Script>) -> DetailVm<Script> {
    DetailVm::new(net.clone(), host(), entry(), Some(account("TOKEN-A"))).unwrap()
}

#[test]
fn play_is_gray_until_the_fresh_title_is_here() {
    let net = server(1, 0);
    let vm = vm(&net);
    assert!(!vm.actions().play.enabled);
    assert_eq!(vm.play(None), PlayAction::Wait);
    assert_eq!(vm.actions().play.label, "Abspielen");
    vm.send(DetailIntent::Load);
    wait_for("fresh title", || vm.actions().play.enabled);
    assert_eq!(
        vm.play(None),
        PlayAction::Start {
            item_id: "f1".into(),
            since: 0.0,
            source_id: None
        }
    );
    // The fresh title brings the toggles and the facts.
    assert!(vm.actions().watched && vm.actions().favorite);
    assert_eq!(vm.actions().favorite_caption, "Gemerkt");
    assert_eq!(
        vm.hero().secondary_line,
        "2019 · 2 Std. 0 Min. · Drama, Krimi"
    );
    assert_eq!(vm.hero().directors, vec!["B".to_owned()]);
}

#[test]
fn failed_fresh_load_enables_play_and_resolves() {
    let net = Script::new(|_| None);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("failure", || vm.actions().play.enabled);
    assert!(matches!(vm.play(None), PlayAction::Resolve { .. }));
}

#[test]
fn several_versions_ask_and_a_pick_starts_it() {
    let net = server(2, 0);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.enabled);
    match vm.play(None) {
        PlayAction::Choose { versions, .. } => {
            assert_eq!(versions.len(), 2);
            assert_eq!(versions[1].id, "s1");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(vm.actions().play.version_title, "Fassung wählen");
    assert!(matches!(
        vm.play(Some("s1")),
        PlayAction::Start { source_id: Some(s), .. } if s == "s1"
    ));
    // A copy on the device starts without asking.
    vm.send(DetailIntent::Downloaded { on: true });
    assert!(matches!(
        vm.play(None),
        PlayAction::Start {
            source_id: None,
            ..
        }
    ));
}

/// The one rule: several versions ask on every press (resume or start), and the resume position rides along; one
/// version starts at once. Nothing is remembered between presses.
#[test]
fn the_press_asks_with_several_versions_and_keeps_the_resume_position() {
    let net = server(2, 18_000_000_000);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.enabled);
    assert!(matches!(
        vm.play(None),
        PlayAction::Choose { since, ref versions, .. } if (since - 1800.0).abs() < 1e-9 && versions.len() == 2
    ));
    assert!(matches!(
        vm.play_from_start(None),
        PlayAction::Choose { since, ref versions, .. } if since == 0.0 && versions.len() == 2
    ));
    assert!(matches!(
        vm.play(Some("s1")),
        PlayAction::Start { since, source_id: Some(ref s), .. } if (since - 1800.0).abs() < 1e-9 && s == "s1"
    ));
    // The pick is not kept: the next press asks again.
    assert!(matches!(vm.play(None), PlayAction::Choose { .. }));
    // One version: no question.
    let net = server(1, 18_000_000_000);
    let one = self::vm(&net);
    one.send(DetailIntent::Load);
    wait_for("title", || one.actions().play.enabled);
    assert!(matches!(
        one.play(None),
        PlayAction::Start { since, source_id: None, .. } if (since - 1800.0).abs() < 1e-9
    ));
}

#[test]
fn resume_label_and_remaining_time() {
    // 30 minutes of 2 hours.
    let net = server(1, 18_000_000_000);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.enabled);
    let play = vm.actions().play.clone();
    assert_eq!(play.label, "Fortsetzen ab 30 Min.");
    assert_eq!(play.remaining.as_deref(), Some("Noch 90 Min."));
    assert!(
        matches!(vm.play(None), PlayAction::Start { since, .. } if (since - 1800.0).abs() < 1e-9)
    );
    assert!(matches!(vm.play_from_start(None), PlayAction::Start { since, .. } if since == 0.0));
}

#[test]
fn bottom_arrives_together_without_self_and_doubles() {
    let net = server(1, 0);
    let vm = vm(&net);
    assert!(!vm.bottom().ready);
    vm.send(DetailIntent::Load);
    wait_for("bottom", || vm.bottom().ready);
    let b = vm.bottom();
    assert_eq!(b.similar.len(), 1);
    assert_eq!(b.similar[0].id, "o1");
    assert_eq!(b.extras.len(), 1);
    assert_eq!(b.cast.len(), 1);
    assert_eq!(b.cast[0].name, "A");
    assert!(!b.similar_failed);
}

#[test]
fn similar_failure_is_told_apart_from_empty() {
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Similar") {
            return None;
        }
        if p.ends_with("/Items/f1") {
            return Some(full(1, 0).to_string());
        }
        Some("[]".into())
    });
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("bottom", || vm.bottom().ready);
    assert!(vm.bottom().similar_failed);
}

#[test]
fn toggle_switches_at_once_and_goes_back_on_failure() {
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.contains("UserFavoriteItems") {
            return None;
        }
        if p.ends_with("/Items/f1") {
            return Some(full(1, 0).to_string());
        }
        Some("{}".into())
    });
    let vm = vm(&net);
    // The list entry says "not watched, not on the watchlist".
    assert!(!vm.actions().watched && !vm.actions().favorite);
    vm.send(DetailIntent::SetWatched { on: true });
    assert!(vm.actions().watched);
    wait_for("request", || net.count("UserPlayedItems/f1") == 1);
    assert!(vm.actions().watched);
    assert!(vm.actions().toggle_error.is_none());
    vm.send(DetailIntent::SetWatchlist { on: true });
    wait_for("revert", || vm.actions().toggle_error.is_some());
    assert!(!vm.actions().favorite);
    assert_eq!(vm.actions().favorite_caption, "Merken");
}

#[test]
fn parts_move_separately() {
    let net = server(1, 0);
    let vm = vm(&net);
    let seen = vm.version();
    vm.send(DetailIntent::SetWatched { on: true });
    let c = futures_executor::block_on(vm.changed(seen));
    assert_eq!(c.parts & part::DETAIL_ACTIONS, part::DETAIL_ACTIONS);
    assert_eq!(c.parts & part::DETAIL_HERO, 0);
    assert_eq!(c.parts & part::DETAIL_BOTTOM, 0);
}

#[test]
fn offline_keeps_the_entry_and_signed_out_cannot_toggle() {
    let net = server(1, 0);
    let vm = DetailVm::new(net.clone(), host(), entry(), None).unwrap();
    assert!(!vm.actions().play.enabled);
    vm.send(DetailIntent::SetWatched { on: true });
    assert_eq!(
        vm.actions().toggle_error.as_deref(),
        Some("Nicht angemeldet.")
    );
    assert!(!vm.actions().watched);
    net.offline.store(true, Ordering::SeqCst);
    assert_eq!(vm.hero().title, "Film");
}

// ---- plan, proof row, file excerpt, trailer, menus, collections, watchers ----

use swiftly_vm::{DetailEffect, DetailOptions, DownloadState, MenuContext, MenuKind};

fn info(sources: serde_json::Value) -> String {
    serde_json::json!({"MediaSources": sources, "PlaySessionId": "ps"}).to_string()
}

fn rich_server() -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path().to_owned();
        let q = r.url.query().unwrap_or("").to_owned();
        if p.ends_with("/Items/f1") {
            let mut v = full(1, 0);
            v["CommunityRating"] = serde_json::json!(7.54);
            v["OfficialRating"] = serde_json::json!("12");
            v["BoxSetIds"] = serde_json::json!(["c1"]);
            return Some(v.to_string());
        }
        if p.ends_with("/Items/f1/PlaybackInfo") || p.ends_with("/Items/t1/PlaybackInfo") {
            return Some(info(serde_json::json!([{
            "Id": "s0", "Container": "mkv", "Size": 10_300_000_000_i64,
            "SupportsDirectPlay": true,
            "MediaStreams": [
                {"Type": "Video", "Codec": "hevc", "Height": 2160},
                {"Type": "Audio", "Codec": "eac3", "Language": "deu"},
                {"Type": "Audio", "Codec": "aac", "Language": "eng"},
                {"Type": "Audio", "Codec": "aac", "Language": "fra"},
            ]}])));
        }
        if p.ends_with("/Items/f1/LocalTrailers") {
            return Some(
                serde_json::json!([{"Id": "t1", "Name": "Trailer", "Type": "Trailer"}]).to_string(),
            );
        }
        if p.ends_with("/Items/f1/Similar") || p.ends_with("/SpecialFeatures") {
            return Some(list(&[], 0));
        }
        if p.ends_with("/UserViews") {
            return Some(list(
                &[serde_json::json!({"Id": "v1", "Name": "Filme", "CollectionType": "movies"})],
                1,
            ));
        }
        if q.contains("BoxSet") {
            return Some(list(
                &[serde_json::json!({"Id": "c1", "Name": "Reihe", "Type": "BoxSet"})],
                1,
            ));
        }
        if q.contains("ParentId=c1") {
            let m = |id: &str| serde_json::json!({"Id": id, "Name": id, "Type": "Movie"});
            return Some(list(&[m("f1"), m("g1"), m("g1"), m("g2")], 4));
        }
        if p.ends_with("/Watchers") {
            return Some(
                serde_json::json!([{"UserId": "u1", "UserName": "anna", "PlayCount": 2, "ProgressPercent": 50.0}])
                    .to_string(),
            );
        }
        Some("{}".into())
    })
}

#[test]
fn plan_proof_row_file_excerpt_collections_and_watchers_arrive() {
    let net = rich_server();
    let vm = vm(&net);
    assert!(!vm.actions().proof.visible);
    vm.send(DetailIntent::Options(Box::new(DetailOptions {
        watchers_shown: true,
        ..DetailOptions::default()
    })));
    vm.send(DetailIntent::Load);
    wait_for("bottom", || vm.bottom().ready && vm.actions().proof.visible);
    let proof = vm.actions().proof.clone();
    assert!(proof.direct_play && proof.hint.is_none());
    assert_eq!(proof.rating.as_deref(), Some("7,5"));
    assert_eq!(proof.age_rating.as_deref(), Some("ab 12"));
    assert!(vm.plan().is_some());
    let file = vm.bottom().file.clone().expect("file excerpt");
    let labels: Vec<_> = file.rows.iter().map(|r| r.label.as_str()).collect();
    assert_eq!(file.title, "Datei");
    assert_eq!(labels, ["Container", "Video", "Ton", "Ton", "Untertitel"]);
    assert!(file.rows[0].value.starts_with("MKV · 10,3 GB"));
    assert_eq!(file.rows[1].value, "2160p · HEVC");
    assert_eq!(file.rows[4].value, "Keine");
    let rails = vm.bottom().collections.clone();
    assert_eq!(rails.len(), 1);
    assert_eq!(rails[0].title, "Reihe");
    // The title itself and the double are gone.
    let ids: Vec<_> = rails[0].tiles.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(ids, ["g1", "g2"]);
    let w = vm.bottom().watchers.clone();
    assert_eq!(w.len(), 1);
    assert_eq!((w[0].initial.as_str(), w[0].ring), ("A", 0.5));
}

#[test]
fn trailer_plays_the_server_file_or_says_there_is_none() {
    let net = rich_server();
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("loaded", || vm.bottom().ready);
    let seen = vm.actions().effect_seq;
    vm.send(DetailIntent::Trailer);
    wait_for("effect", || vm.actions().effect_seq > seen);
    match vm.take_effects().as_slice() {
        [DetailEffect::PlayTrailer { item, plan }] => {
            assert_eq!(item.id, "t1");
            assert!(plan.is_lossless());
        }
        other => panic!("{other:?}"),
    }
    assert!(vm.take_effects().is_empty());

    let none = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/LocalTrailers") {
            return Some("[]".into());
        }
        Some("{}".into())
    });
    let vm2 = DetailVm::new(none, host(), entry(), Some(account("TOKEN-A"))).unwrap();
    vm2.send(DetailIntent::Trailer);
    wait_for("message", || vm2.actions().message.is_some());
    assert_eq!(
        vm2.actions().message.as_deref(),
        Some("Für diesen Titel liegt kein Trailer vor.")
    );
    vm2.send(DetailIntent::DismissMessage);
    assert!(vm2.actions().message.is_none());
}

#[test]
fn menus_follow_the_swift_lists() {
    let net = rich_server();
    let vm = vm(&net);
    let cx = MenuContext {
        download_button: true,
        together: true,
        play_on: vec![("d1".into(), "Wohnzimmer".into())],
        ..MenuContext::default()
    };
    vm.send(DetailIntent::Options(Box::new(DetailOptions {
        download_button: true,
        menu: cx,
        ..DetailOptions::default()
    })));
    // Not begun, not watched: play, mark watched, download, play-on, together.
    let kinds: Vec<_> = vm.tile_menu().into_iter().map(|e| e.kind).collect();
    assert_eq!(kinds[0], MenuKind::Play);
    assert_eq!(kinds[1], MenuKind::MarkWatched);
    assert_eq!(kinds[2], MenuKind::Download);
    assert!(matches!(kinds[3], MenuKind::PlayOn { .. }));
    assert_eq!(kinds[4], MenuKind::Together);
    // The More panel: before the plan only the metadata entry.
    let before: Vec<_> = vm.more_menu().into_iter().map(|e| e.kind).collect();
    assert_eq!(before, [MenuKind::RefreshMetadata]);
    // The download field shows with the feature on, and follows the manager.
    assert!(vm.actions().download.is_some());
    vm.send(DetailIntent::DownloadState(DownloadState::Loading(0.5)));
    assert_eq!(
        vm.actions().download.as_ref().unwrap().state,
        DownloadState::Loading(0.5)
    );
    let seen = vm.actions().effect_seq;
    vm.send(DetailIntent::DownloadPressed);
    assert!(vm.actions().effect_seq > seen);
    assert_eq!(vm.take_effects(), [DetailEffect::OpenDownload]);
    // Reset progress and metadata refresh say what happened.
    vm.send(DetailIntent::Menu(MenuKind::RefreshMetadata));
    wait_for("metadata", || vm.actions().message.is_some());
    assert_eq!(
        vm.actions().message.as_deref(),
        Some("Der Server liest die Metadaten neu ein.")
    );
    vm.send(DetailIntent::Menu(MenuKind::ResetProgress));
    wait_for("reset", || {
        vm.actions().message.as_deref() == Some("Der Fortschritt ist zurückgesetzt.")
    });
}

#[test]
fn a_movie_without_a_backdrop_takes_its_poster_for_the_head_image() {
    let item: Item = serde_json::from_value(serde_json::json!({
        "Id": "f1", "Name": "Film", "Type": "Movie",
        "ImageTags": {"Primary": "pt"}
    }))
    .unwrap();
    let vm = DetailVm::new(rich_server(), host(), item, Some(account("TOKEN-A"))).unwrap();
    assert!(vm.hero().image.is_some());
}

/// A placeholder the server lists without a file (`LocationType: Virtual`): the page says so at once instead of waiting for
/// versions that never come, and shows no "Direct Play" mark.
#[test]
fn a_virtual_title_is_a_placeholder() {
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Items/f1") {
            let mut v = full(0, 0);
            v["LocationType"] = serde_json::json!("Virtual");
            v["MediaSources"] = serde_json::json!(null);
            return Some(v.to_string());
        }
        Some("{}".into())
    });
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("fresh title", || vm.is_placeholder());
    assert!(
        !vm.actions().proof.visible,
        "no Direct Play mark for a placeholder"
    );
}
