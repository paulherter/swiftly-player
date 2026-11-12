//! What the Apple detail and series screens render from the cores: version labels, the raw item
//! for the host's play seam, the series proof row, menu, trailer, effects and watchers.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::account;
use common::script::{Script, host, list, param, wait_for};
use swiftly_model::Item;
use swiftly_vm::{
    DetailEffect, DetailIntent, DetailVm, MenuKind, PlayAction, SeriesEffect, SeriesIntent,
    SeriesOptions, SeriesSpec, SeriesVm,
};

fn film_entry() -> Item {
    serde_json::from_value(serde_json::json!({"Id": "f1", "Name": "Eintrag", "Type": "Movie"}))
        .unwrap()
}

fn film_server(fail_flags: bool) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path();
        if fail_flags && (p.contains("UserPlayedItems") || p.contains("UserFavoriteItems")) {
            return None;
        }
        if p.ends_with("/Items/f1") {
            return Some(
                serde_json::json!({"Id": "f1", "Name": "Film", "Type": "Movie",
                "MediaSources": [
                    {"Id": "a", "Name": "  4K  ", "Size": 10_300_000_000_i64,
                     "MediaStreams": [{"Type": "Video", "Codec": "hevc", "Height": 2160}]},
                    {"Id": "b", "Name": " "}
                ]})
                .to_string(),
            );
        }
        Some("{}".into())
    })
}

fn film_vm(net: &Arc<Script>) -> DetailVm<Script> {
    DetailVm::new(net.clone(), host(), film_entry(), Some(account("TOKEN-A"))).unwrap()
}

#[test]
fn version_options_carry_the_label_of_the_choice() {
    let net = film_server(false);
    let vm = film_vm(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.enabled);
    let PlayAction::Choose { versions, .. } = vm.play(None) else {
        panic!("two versions ask");
    };
    assert_eq!(versions[0].name, "  4K  ");
    assert_eq!(versions[0].label, "4K · 2160p · HEVC · 10,3 GB");
    // No name: the word "Fassung", and nothing else to tell it apart.
    assert_eq!(versions[1].label, "Fassung");
}

#[test]
fn detail_item_json_is_the_entry_then_the_fresh_title() {
    let net = film_server(false);
    let vm = film_vm(&net);
    let first: serde_json::Value = serde_json::from_str(&vm.item_json().unwrap()).unwrap();
    assert_eq!(first["Name"], "Eintrag");
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.enabled);
    let fresh: serde_json::Value = serde_json::from_str(&vm.item_json().unwrap()).unwrap();
    assert_eq!(fresh["Id"], "f1");
    assert_eq!(fresh["Name"], "Film");
    assert_eq!(fresh["MediaSources"][0]["Id"], "a");
    // What the host decodes again is the same item.
    let back: Item = serde_json::from_value(fresh).unwrap();
    assert_eq!(back.media_sources.unwrap().len(), 2);
}

#[test]
fn detail_writes_tell_the_host_only_when_the_server_took_them() {
    let ok = film_server(false);
    let vm = film_vm(&ok);
    vm.send(DetailIntent::SetWatched { on: true });
    wait_for("watched", || {
        !vm.take_effects().is_empty() || ok.count("UserPlayedItems/f1") > 1
    });
    vm.send(DetailIntent::SetWatchlist { on: true });
    wait_for("watchlist", || {
        vm.take_effects().contains(&DetailEffect::WatchlistChanged)
    });
    let bad = film_server(true);
    let vm = film_vm(&bad);
    vm.send(DetailIntent::SetWatched { on: true });
    wait_for("reason", || vm.actions().toggle_error.is_some());
    assert!(vm.take_effects().is_empty());
}

// ---- series ----

fn series_entry() -> Item {
    serde_json::from_value(serde_json::json!({"Id": "ser", "Name": "Serie", "Type": "Series"}))
        .unwrap()
}

fn episode(n: usize) -> serde_json::Value {
    serde_json::json!({"Id": format!("e{n}"), "Name": format!("Folge {n}"), "Type": "Episode",
        "IndexNumber": n, "ParentIndexNumber": 1, "SeasonId": "se1", "SeriesId": "ser",
        "UserData": {"PlaybackPositionTicks": 9_000_000_000_i64}})
}

/// One season of `count` episodes; the viewer is at the first. `fail_writes` refuses the flags.
fn series_server(count: usize, state: bool, fail_writes: bool) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path();
        if fail_writes && (p.contains("UserPlayedItems") || p.contains("UserFavoriteItems")) {
            return None;
        }
        if p.ends_with("/Items/ser") {
            return Some(
                serde_json::json!({"Id": "ser", "Name": "Serie", "Type": "Series",
                "CommunityRating": 8.1, "OfficialRating": "16", "Overview": "Text"})
                .to_string(),
            );
        }
        if p.ends_with("Shows/NextUp") {
            return Some(if state {
                list(&[episode(1)], 1)
            } else {
                list(&[], 0)
            });
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(
                &[
                    serde_json::json!({"Id": "se1", "Name": "Staffel 1", "Type": "Season",
                    "IndexNumber": 1}),
                ],
                1,
            ));
        }
        if p.ends_with("Shows/ser/Episodes") {
            let all: Vec<_> = (1..=count).map(episode).collect();
            if param(r, "adjacentTo").is_some() {
                return Some(list(&all, count));
            }
            return Some(list(&all, count));
        }
        if p.ends_with("/Items/e1/PlaybackInfo") {
            return Some(
                serde_json::json!({"PlaySessionId": "ps", "MediaSources": [
                    {"Id": "s0", "Container": "mkv", "SupportsDirectPlay": true}]})
                .to_string(),
            );
        }
        if p.ends_with("/Similar")
            || p.ends_with("/SpecialFeatures")
            || p.ends_with("LocalTrailers")
        {
            return Some(if p.ends_with("LocalTrailers") {
                "[]".into()
            } else {
                list(&[], 0)
            });
        }
        if p.ends_with("/Watchers") {
            return Some(
                serde_json::json!([{"UserId": "u1", "UserName": "anna", "PlayCount": 2,
                    "ProgressPercent": 50.0}])
                .to_string(),
            );
        }
        Some("{}".into())
    })
}

fn series_vm(net: &Arc<Script>) -> SeriesVm<Script> {
    SeriesVm::new(
        net.clone(),
        host(),
        series_entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap()
}

fn loaded(vm: &SeriesVm<Script>) {
    vm.send(SeriesIntent::Load);
    wait_for("page", || {
        vm.button().label_ready && vm.button().proof.visible && !vm.more().similar_loads
    });
}

#[test]
fn series_proof_row_waits_for_the_plan_of_the_state_episode() {
    let net = series_server(3, true, false);
    let vm = series_vm(&net);
    assert!(!vm.button().proof.visible);
    loaded(&vm);
    let proof = vm.button().proof.clone();
    assert!(proof.direct_play && proof.hint.is_none());
    assert_eq!(proof.rating.as_deref(), Some("8,1"));
    assert_eq!(proof.age_rating.as_deref(), Some("ab 16"));
    assert!(vm.plan().is_some());
    assert!(net.count("Items/e1/PlaybackInfo") >= 1);
}

#[test]
fn series_without_a_state_has_no_plan_and_shows_the_row_at_once() {
    let net = series_server(0, false, false);
    let vm = series_vm(&net);
    loaded(&vm);
    assert!(vm.plan().is_none());
    assert!(!vm.button().proof.direct_play);
    assert_eq!(net.count("PlaybackInfo"), 0);
    let texts: Vec<_> = vm.more_menu().into_iter().map(|e| e.text).collect();
    assert_eq!(
        texts,
        [
            "Zufällig abspielen",
            "Staffel 1 als gesehen",
            "Metadaten neu einlesen"
        ]
    );
}

#[test]
fn series_menu_follows_title_actions_for_series() {
    let net = series_server(3, true, false);
    let vm = series_vm(&net);
    loaded(&vm);
    let list = vm.more_menu();
    let texts: Vec<_> = list.iter().map(|e| e.text.as_str()).collect();
    assert_eq!(
        texts,
        [
            "Folge von vorn abspielen",
            "Nächste Folge abspielen",
            "Zufällig abspielen",
            "Staffel 1 als gesehen",
            "Metadaten neu einlesen"
        ]
    );
    assert_eq!(
        list[3].kind,
        MenuKind::MarkSeasonWatched {
            name: "Staffel 1".into()
        }
    );
    vm.send(SeriesIntent::Options(SeriesOptions {
        together: true,
        download_button: true,
        play_on: vec![("d1".into(), "Wohnzimmer".into())],
        ..SeriesOptions::default()
    }));
    let texts: Vec<_> = vm.more_menu().into_iter().map(|e| e.text).collect();
    assert_eq!(
        texts,
        [
            "Trailer",
            "Abspielen auf „Wohnzimmer“",
            "Folge von vorn abspielen",
            "Gemeinsam schauen",
            "Zufällig abspielen",
            "Staffel 1 als gesehen",
            "Metadaten neu einlesen"
        ]
    );
}

#[test]
fn series_menu_plays_from_start_the_next_episode_and_leaves_shuffle_to_the_host() {
    let net = series_server(3, true, false);
    let vm = series_vm(&net);
    loaded(&vm);
    vm.send(SeriesIntent::Menu(MenuKind::PlayEpisodeFromStart));
    assert_eq!(
        vm.take_effects(),
        [SeriesEffect::Play(PlayAction::Resolve {
            item_id: "e1".into(),
            since: 0.0
        })]
    );
    vm.send(SeriesIntent::Menu(MenuKind::Shuffle));
    assert_eq!(vm.take_effects(), [SeriesEffect::Menu(MenuKind::Shuffle)]);
    vm.send(SeriesIntent::Menu(MenuKind::NextEpisode));
    wait_for("next", || vm.button().effect_seq >= 3);
    assert_eq!(
        vm.take_effects(),
        [SeriesEffect::Play(PlayAction::Resolve {
            item_id: "e2".into(),
            since: 0.0
        })]
    );
    // The host can fetch the raw episode for its play seam.
    let raw: serde_json::Value = serde_json::from_str(&vm.item_json(Some("e2")).unwrap()).unwrap();
    assert_eq!(raw["Name"], "Folge 2");
    assert!(vm.item_json(Some("nope")).is_none());
}

#[test]
fn nothing_after_the_last_episode_says_so() {
    let net = series_server(1, true, false);
    let vm = series_vm(&net);
    loaded(&vm);
    vm.send(SeriesIntent::Menu(MenuKind::NextEpisode));
    wait_for("notice", || vm.button().message.is_some());
    assert_eq!(
        vm.button().message.as_deref(),
        Some("Danach kommt nichts mehr.")
    );
    assert!(vm.take_effects().is_empty());
}

#[test]
fn series_trailer_metadata_and_item_json() {
    let net = series_server(3, true, false);
    let vm = series_vm(&net);
    loaded(&vm);
    vm.send(SeriesIntent::Trailer);
    wait_for("hint", || vm.button().message.is_some());
    assert_eq!(
        vm.button().message.as_deref(),
        Some("Für diesen Titel liegt kein Trailer vor.")
    );
    vm.send(SeriesIntent::DismissMessage);
    vm.send(SeriesIntent::Menu(MenuKind::RefreshMetadata));
    wait_for("refresh", || vm.button().message.is_some());
    assert_eq!(
        vm.button().message.as_deref(),
        Some("Der Server liest die Metadaten neu ein.")
    );
    let series: serde_json::Value = serde_json::from_str(&vm.item_json(None).unwrap()).unwrap();
    assert_eq!(series["Overview"], "Text");
}

#[test]
fn series_writes_tell_the_host_only_when_the_server_took_them() {
    let ok = series_server(3, true, false);
    let vm = series_vm(&ok);
    vm.send(SeriesIntent::SetWatched { on: true });
    wait_for("watched", || vm.button().effect_seq >= 1);
    assert_eq!(vm.take_effects(), [SeriesEffect::StateChanged]);
    vm.send(SeriesIntent::SetWatchlist { on: true });
    wait_for("watchlist", || vm.button().effect_seq >= 2);
    assert_eq!(vm.take_effects(), [SeriesEffect::WatchlistChanged]);
    let bad = series_server(3, true, true);
    let vm = series_vm(&bad);
    vm.send(SeriesIntent::SetWatched { on: true });
    wait_for("reason", || vm.button().toggle_error.is_some());
    assert!(vm.take_effects().is_empty());
}

#[test]
fn series_watchers_follow_the_option() {
    let net = series_server(3, true, false);
    let off = series_vm(&net);
    loaded(&off);
    assert!(off.more().watchers.is_empty());
    let on = series_vm(&net);
    on.send(SeriesIntent::Options(SeriesOptions {
        watchers_shown: true,
        ..SeriesOptions::default()
    }));
    loaded(&on);
    let w = on.more().watchers.clone();
    assert_eq!(w.len(), 1);
    assert_eq!((w[0].initial.as_str(), w[0].ring), ("A", 0.5));
}
