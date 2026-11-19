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
use swiftly_vm::{DetailIntent, DetailVm, PlayAction, PlayReadiness, ProofPhase, part};

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
    assert!(!vm.actions().play.ready.is_ready());
    assert_eq!(vm.play(None), PlayAction::Wait);
    assert_eq!(vm.actions().play.label, "Abspielen");
    vm.send(DetailIntent::Load);
    wait_for("fresh title", || vm.actions().play.ready.is_ready());
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
    wait_for("failure", || vm.actions().play.ready.is_ready());
    assert!(matches!(vm.play(None), PlayAction::Resolve { .. }));
}

/// Decision: a tap on Play starts the default version at once, even with several; the choice is the
/// long press (`versions()`), and a pick starts that version.
#[test]
fn several_versions_start_the_default_and_a_pick_starts_that_one() {
    let net = server(2, 0);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.ready.is_ready());
    assert_eq!(
        vm.play(None),
        PlayAction::Start {
            item_id: "f1".into(),
            since: 0.0,
            source_id: None
        }
    );
    let versions = vm.versions();
    assert_eq!(versions.len(), 2);
    assert_eq!(versions[1].id, "s1");
    assert_eq!(
        versions.iter().filter(|v| v.is_default).count(),
        1,
        "exactly one default is marked"
    );
    assert!(
        versions[0].is_default,
        "on a tie the top version of the server's order is the default"
    );
    assert!(matches!(
        vm.play(Some("s1")),
        PlayAction::Start { source_id: Some(s), .. } if s == "s1"
    ));
    // A copy on the device starts without a choice: there is nothing to pick between.
    vm.send(DetailIntent::Downloaded { on: true });
    assert!(vm.versions().is_empty());
    assert!(matches!(
        vm.play(None),
        PlayAction::Start {
            source_id: None,
            ..
        }
    ));
}

/// The mark of the long press is the version a tap starts, and a tap starts the live plan's version. The server's answer to
/// the device profile can rule the top version out (the 4K file is over the bitrate cap and would be transcoded, the 1080p
/// file plays as it is), while the title's own source list says nothing about that (every source lists direct play).
#[test]
fn the_mark_follows_the_live_plan_not_the_top_version() {
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Items/f1") {
            return Some(
                serde_json::json!({"Id": "f1", "Name": "Film", "Type": "Movie", "MediaSources": [
                    {"Id": "uhd", "Name": "4K", "Container": "mkv", "SupportsDirectPlay": true},
                    {"Id": "hd", "Name": "1080p", "Container": "mp4", "SupportsDirectPlay": true}]})
                .to_string(),
            );
        }
        if p.ends_with("/Items/f1/PlaybackInfo") {
            return Some(
                serde_json::json!({"PlaySessionId": "ps", "MediaSources": [
                    {"Id": "uhd", "Container": "mkv", "SupportsDirectPlay": false,
                     "SupportsDirectStream": false, "SupportsTranscoding": true,
                     "TranscodingUrl": "/videos/f1/master.m3u8?MediaSourceId=uhd"},
                    {"Id": "hd", "Container": "mp4", "SupportsDirectPlay": true}]})
                .to_string(),
            );
        }
        Some("{}".into())
    });
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("plan", || {
        vm.plan().is_some() && vm.actions().play.ready.is_ready()
    });
    let plan = vm.plan().unwrap();
    assert_eq!(plan.media_source_id.as_deref(), Some("hd"));
    let marked: Vec<_> = vm
        .versions()
        .iter()
        .map(|v| (v.id.clone(), v.is_default))
        .collect();
    assert_eq!(
        marked,
        [("uhd".to_owned(), false), ("hd".to_owned(), true)],
        "the check mark sits on the version the plan (and so the tap) starts"
    );
}

/// The one rule: a press starts the default version (resume or start) and the resume position rides along; the pick of
/// the long press starts that version at the same position. Nothing is remembered between presses.
#[test]
fn the_press_starts_the_default_with_several_versions_and_keeps_the_resume_position() {
    let net = server(2, 18_000_000_000);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.ready.is_ready());
    assert!(matches!(
        vm.play(None),
        PlayAction::Start { since, source_id: None, .. } if (since - 1800.0).abs() < 1e-9
    ));
    assert!(matches!(
        vm.play_from_start(None),
        PlayAction::Start { since, source_id: None, .. } if since == 0.0
    ));
    assert!(matches!(
        vm.play(Some("s1")),
        PlayAction::Start { since, source_id: Some(ref s), .. } if (since - 1800.0).abs() < 1e-9 && s == "s1"
    ));
    // The pick is not kept: the next press starts the default again.
    assert!(matches!(
        vm.play(None),
        PlayAction::Start {
            source_id: None,
            ..
        }
    ));
    // One version: no question.
    let net = server(1, 18_000_000_000);
    let one = self::vm(&net);
    one.send(DetailIntent::Load);
    wait_for("title", || one.actions().play.ready.is_ready());
    assert!(matches!(
        one.play(None),
        PlayAction::Start { since, source_id: None, .. } if (since - 1800.0).abs() < 1e-9
    ));
    // ... and nothing to choose between: the long press has no entries (so it does nothing).
    assert!(one.versions().is_empty());
}

#[test]
fn never_started_title_shows_its_runtime_under_play() {
    // No resume point: the reserved slot shows the runtime instead of staying empty.
    let net = server(1, 0);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.ready.is_ready());
    let play = vm.actions().play.clone();
    assert_eq!(play.label, "Abspielen");
    assert_eq!(play.remaining.as_deref(), Some("2 Std. 0 Min."));
}

#[test]
fn resume_label_and_remaining_time() {
    // 30 minutes of 2 hours.
    let net = server(1, 18_000_000_000);
    let vm = vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.ready.is_ready());
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
    assert!(!vm.actions().play.ready.is_ready());
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

/// Before the title answers, a seed that names no head picture shows none (the tile picture or its blur stands in; a
/// portrait poster would be stretched into the landscape frame). Once the title has answered, a movie without a backdrop
/// takes its poster for the head image.
#[test]
fn a_movie_without_a_backdrop_takes_its_poster_for_the_head_image_once_the_title_answered() {
    let net = Script::new(|r| {
        if r.url.path().ends_with("/Items/f1") {
            let mut v = full(1, 0);
            v["ImageTags"] = serde_json::json!({"Primary": "pt"});
            return Some(v.to_string());
        }
        Some("{}".into())
    });
    let item: Item = serde_json::from_value(serde_json::json!({
        "Id": "f1", "Name": "Film", "Type": "Movie",
        "ImageTags": {"Primary": "pt"}
    }))
    .unwrap();
    let vm = DetailVm::new(net, host(), item, Some(account("TOKEN-A"))).unwrap();
    assert!(
        vm.hero().image.is_none(),
        "no stretched poster before the answer"
    );
    vm.send(DetailIntent::Load);
    wait_for("the poster as head image", || vm.hero().image.is_some());
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

/// The page opens from the tile that was tapped. When that tile knows where the user stopped, the first frame already
/// words the button ("Fortsetzen ab ..."), and the same text stays when the fresh title arrives: the label never swaps.
#[test]
fn the_label_is_final_in_the_first_frame_when_the_tile_knows_the_position() {
    // 30 minutes of 2 hours, as the list entry (the same numbers the fresh title will carry).
    let net = server(1, 18_000_000_000);
    let mut stopped = entry();
    stopped.run_time_ticks = Some(72_000_000_000);
    stopped.user_data.as_mut().unwrap().playback_position_ticks = Some(18_000_000_000);
    let vm = DetailVm::new(net.clone(), host(), stopped, Some(account("TOKEN-A"))).unwrap();
    let first = vm.actions().play.clone();
    assert_eq!(first.label, "Fortsetzen ab 30 Min.");
    assert_eq!(first.remaining.as_deref(), Some("Noch 90 Min."));
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.ready.is_ready());
    assert_eq!(vm.actions().play.label, first.label);
}

/// The chips of the proof row are final all at once: `Waiting` until the title and the plan have both answered, then
/// `Settled` with every chip in the same part, so a host never draws one chip before the others.
#[test]
fn the_proof_row_settles_in_one_step_with_all_its_chips() {
    let net = rich_server();
    let vm = vm(&net);
    assert_eq!(vm.actions().proof.phase, ProofPhase::Waiting);
    vm.send(DetailIntent::Load);
    // Watch every published state: whenever a chip is there, the phase is Settled and all chips are there.
    let end = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        // One snapshot per look: the phase and the chips must come from the same published part.
        let p = vm.actions().proof.clone();
        if p.phase != ProofPhase::Waiting {
            break;
        }
        assert!(!p.visible, "visible only once settled");
        assert!(std::time::Instant::now() < end, "never settled");
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    let proof = vm.actions().proof.clone();
    assert!(proof.visible);
    assert!(proof.direct_play);
    assert_eq!(proof.rating.as_deref(), Some("7,5"));
    assert_eq!(proof.age_rating.as_deref(), Some("ab 12"));
}

/// A placeholder without a file still settles (so a host stops drawing skeletons), but shows no chip.
#[test]
fn a_placeholder_settles_with_no_chip() {
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
    wait_for("settled", || {
        vm.actions().proof.phase == ProofPhase::Settled
    });
    assert!(!vm.actions().proof.visible);
}

/// Play looks the same from frame 1; a press before the versions are known is held by the core (one
/// state, `PlayReadiness::Waiting { queued }`) and starts the title once when they arrive.
#[test]
fn a_press_before_the_fresh_title_is_held_and_starts_the_title_once() {
    let net = server(1, 0);
    let vm = vm(&net);
    assert_eq!(
        vm.actions().play.ready,
        PlayReadiness::Waiting { queued: false }
    );
    assert_eq!(
        vm.actions().play.label,
        "Abspielen",
        "the label is there in frame 1"
    );
    assert_eq!(vm.play(None), PlayAction::Wait);
    assert_eq!(
        vm.play(None),
        PlayAction::Wait,
        "a second press does not queue a second start"
    );
    assert_eq!(
        vm.actions().play.ready,
        PlayReadiness::Waiting { queued: true }
    );
    assert!(vm.take_effects().is_empty());
    vm.send(DetailIntent::Load);
    wait_for("fresh title", || vm.actions().play.ready.is_ready());
    let start = PlayAction::Start {
        item_id: "f1".into(),
        since: 0.0,
        source_id: None,
    };
    assert_eq!(vm.take_effects(), [swiftly_vm::DetailEffect::Play(start)]);
    assert!(vm.take_effects().is_empty(), "once");
    // A later press decides at once and holds nothing.
    assert!(matches!(vm.play(None), PlayAction::Start { .. }));
    assert!(vm.take_effects().is_empty());
}

#[test]
fn a_held_press_from_the_start_ignores_the_resume_point() {
    let net = server(1, 600_000_000);
    let vm = vm(&net);
    assert_eq!(vm.play_from_start(None), PlayAction::Wait);
    vm.send(DetailIntent::Load);
    wait_for("fresh title", || vm.actions().play.ready.is_ready());
    let start = PlayAction::Start {
        item_id: "f1".into(),
        since: 0.0,
        source_id: None,
    };
    assert_eq!(vm.take_effects(), [swiftly_vm::DetailEffect::Play(start)]);
}

#[test]
fn a_held_press_resolves_when_the_fresh_load_failed() {
    let net = Script::new(|_| None);
    let vm = vm(&net);
    assert_eq!(vm.play(None), PlayAction::Wait);
    vm.send(DetailIntent::Load);
    wait_for("failure", || vm.actions().play.ready.is_ready());
    assert!(matches!(
        vm.take_effects().as_slice(),
        [swiftly_vm::DetailEffect::Play(PlayAction::Resolve { .. })]
    ));
}
