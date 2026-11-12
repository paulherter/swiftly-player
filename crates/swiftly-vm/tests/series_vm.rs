//! The series view model against a scripted server: state, seasons and episodes arriving
//! together, season choice by hint, season switch, button label, failure vs empty, paging of
//! the episode list, mark season watched, toggles.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::account;
use common::script::{Script, host, list, param, wait_for};
use swiftly_model::Item;
use swiftly_vm::{
    EPISODES_STEP, EpisodesStatus, PlayAction, SeriesIntent, SeriesSpec, SeriesVm, part,
};

fn entry() -> Item {
    serde_json::from_value(serde_json::json!({
        "Id": "ser", "Name": "Serie", "Type": "Series", "Genres": ["Drama"], "ChildCount": 9,
        "UserData": {"Played": false, "IsFavorite": false}
    }))
    .unwrap()
}

fn season(n: i64) -> serde_json::Value {
    serde_json::json!({"Id": format!("se{n}"), "Name": format!("Staffel {n}"),
        "Type": "Season", "IndexNumber": n})
}

fn episode(season: i64, n: usize, played: bool) -> serde_json::Value {
    serde_json::json!({"Id": format!("e{season}-{n}"), "Name": format!("Folge {n}"),
        "Type": "Episode", "IndexNumber": n, "ParentIndexNumber": season,
        "SeasonId": format!("se{season}"), "RunTimeTicks": 27_000_000_000_i64,
        "SeriesId": "ser", "ImageTags": {"Primary": "still"},
        "ParentBackdropItemId": "ser", "ParentBackdropImageTags": ["bd"],
        "UserData": {"Played": played}})
}

/// Two seasons, 100 episodes in the first, 3 in the second. The viewer is at S2 E2 (started).
fn server() -> Arc<Script> {
    Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Items/ser") {
            return Some(
                serde_json::json!({"Id": "ser", "Name": "Serie", "Type": "Series",
                "ProductionYear": 2015, "CommunityRating": 8.1, "OfficialRating": "TV-MA",
                "Overview": "Full text.", "UserData": {"IsFavorite": true}})
                .to_string(),
            );
        }
        if p.ends_with("Shows/NextUp") {
            let mut e = episode(2, 2, false);
            e["UserData"] = serde_json::json!({"PlaybackPositionTicks": 9_000_000_000_i64});
            return Some(list(&[e], 1));
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(&[season(1), season(2)], 2));
        }
        if p.ends_with("Shows/ser/Episodes") {
            let n = match param(r, "seasonId").as_deref() {
                Some("se1") => 100,
                _ => 3,
            };
            let s = if param(r, "seasonId").as_deref() == Some("se1") {
                1
            } else {
                2
            };
            let all: Vec<_> = (1..=n)
                .map(|i| {
                    let mut e = episode(s, i, i == 1);
                    if s == 1 && i == 5 {
                        // Two versions, as a server groups them (#33).
                        e["MediaSources"] = serde_json::json!([
                            {"Id": "hd", "Name": "1080p"}, {"Id": "uhd", "Name": "4K"}]);
                    }
                    if s == 1 && i == 6 {
                        e["MediaSources"] = serde_json::json!([
                            {"Id": "hd6", "Name": "1080p"}, {"Id": "uhd6", "Name": " 4k "}]);
                    }
                    if s == 1 && i == 7 {
                        // Other names, same resolutions.
                        e["MediaSources"] = serde_json::json!([
                            {"Id": "a7", "Name": "Cut A", "MediaStreams": [{"Type": "Video", "Height": 1080}]}, {"Id": "b7", "Name": "Cut B", "MediaStreams": [{"Type": "Video", "Height": 2160}]}]);
                    }
                    if s == 1 && i == 8 {
                        e["MediaSources"] = serde_json::json!([
                            {"Id": "a8", "Name": "Cut C", "MediaStreams": [{"Type": "Video", "Height": 480}]}, {"Id": "b8", "Name": "Cut D", "MediaStreams": [{"Type": "Video", "Height": 720}]}]);
                    }
                    e
                })
                .collect();
            return Some(list(&all, n));
        }
        if p.ends_with("/Similar") || p.ends_with("/SpecialFeatures") {
            return Some("{\"Items\":[]}".into());
        }
        Some("{}".into())
    })
}

fn vm(net: &Arc<Script>, spec: SeriesSpec) -> SeriesVm<Script> {
    SeriesVm::new(net.clone(), host(), entry(), spec, Some(account("TOKEN-A"))).unwrap()
}

fn ready(vm: &SeriesVm<Script>) -> bool {
    vm.button().label_ready && vm.episodes().status != EpisodesStatus::Loading
}

#[test]
fn opens_in_the_season_the_viewer_is_in() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    assert_eq!(vm.button().label, "Lädt…");
    assert!(!vm.button().label_ready);
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    assert_eq!(vm.seasons().selected.as_deref(), Some("se2"));
    assert_eq!(vm.episodes().rows.len(), 3);
    assert_eq!(vm.button().label, "Fortsetzen S2 · F2");
    assert_eq!(vm.button().remaining.as_deref(), Some("Noch 30 Min."));
    assert_eq!(vm.button().next_episode.as_deref(), Some("e2-2"));
    assert!(vm.button().favorite);
    assert_eq!(vm.button().secondary_line, "2015 · 2 Staffeln · Drama");
    assert_eq!(vm.episodes().rows[0].code.as_deref(), Some("S2 · F1"));
    assert_eq!(vm.episodes().rows[0].runtime.as_deref(), Some("45 Min."));
    // Each row shows its OWN picture, never the series backdrop (reported on the iPhone).
    let own = vm.episodes().rows[0].image.clone().map(|i| i.address);
    assert!(
        own.as_deref()
            .is_some_and(|a| a.contains("/Items/e2-1/Images/Primary")),
        "{own:?}"
    );
    assert!(matches!(
        vm.play_next(None),
        PlayAction::Resolve { ref item_id, since } if item_id == "e2-2" && (since - 900.0).abs() < 1e-9
    ));
}

#[test]
fn hint_from_the_episode_wins_and_paging_grows_by_forty() {
    let net = server();
    let vm = vm(
        &net,
        SeriesSpec {
            start_season_id: None,
            start_season_number: Some(1),
        },
    );
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    assert_eq!(vm.seasons().selected.as_deref(), Some("se1"));
    let e = vm.episodes();
    assert_eq!(
        (e.rows.len(), e.total, e.more_available),
        (EPISODES_STEP, 100, true)
    );
    assert!(e.rows[0].watched && !e.rows[1].watched);
    vm.send(SeriesIntent::MoreEpisodes);
    vm.send(SeriesIntent::MoreEpisodes);
    let e = vm.episodes();
    assert_eq!((e.rows.len(), e.more_available), (100, false));
}

#[test]
fn season_switch_clears_then_fills_and_remembers() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    vm.send(SeriesIntent::SelectSeason { id: "se1".into() });
    assert_eq!(vm.seasons().selected.as_deref(), Some("se1"));
    assert!(vm.episodes().rows.is_empty());
    assert_eq!(vm.episodes().status, EpisodesStatus::Loading);
    wait_for("season 1", || vm.episodes().total == 100);
    // Back: seen before, shown at once.
    vm.send(SeriesIntent::SelectSeason { id: "se2".into() });
    assert_eq!(vm.episodes().rows.len(), 3);
}

#[test]
fn offline_is_told_apart_from_empty() {
    let net = server();
    net.offline.store(true, Ordering::SeqCst);
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("failure", || {
        vm.button().label_ready || vm.seasons().disturbed
    });
    assert!(vm.seasons().disturbed);
    assert_eq!(vm.episodes().status, EpisodesStatus::Disturbed);
    assert_eq!(vm.button().label, "Keine Folgen");

    let empty = Script::new(|r| {
        if r.url.path().ends_with("Seasons") || r.url.path().ends_with("Episodes") {
            return Some(list(&[], 0));
        }
        Some("{}".into())
    });
    let vm = SeriesVm::new(
        empty,
        host(),
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    vm.send(SeriesIntent::Load);
    wait_for("empty", || vm.button().label_ready);
    assert!(!vm.seasons().disturbed);
    assert_eq!(vm.button().label, "Keine Folgen");
}

#[test]
fn mark_season_watched_asks_says_so_and_reloads() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    let before = net.count("Shows/NextUp");
    vm.send(SeriesIntent::MarkSeasonWatched);
    wait_for("notice", || vm.button().message.is_some());
    assert_eq!(
        vm.button().message.as_deref(),
        Some("Staffel 2 ist als gesehen vermerkt.")
    );
    assert_eq!(net.count("UserPlayedItems/se2"), 1);
    wait_for("reload", || net.count("Shows/NextUp") > before);
    vm.send(SeriesIntent::DismissMessage);
    assert!(vm.button().message.is_none());
}

#[test]
fn episode_toggle_failure_says_why_and_series_toggle_goes_back() {
    let fail = Script::new(|r| {
        let p = r.url.path();
        if p.contains("UserPlayedItems") || p.contains("UserFavoriteItems") {
            return None;
        }
        Some("{}".into())
    });
    let vm = SeriesVm::new(
        fail.clone(),
        host(),
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    vm.send(SeriesIntent::SetWatchlist { on: true });
    assert!(vm.button().favorite);
    wait_for("revert", || vm.button().toggle_error.is_some());
    assert!(!vm.button().favorite);
    vm.send(SeriesIntent::SetEpisodeWatched {
        id: "e1".into(),
        on: true,
    });
    wait_for("message", || vm.button().message.is_some());
}

#[test]
fn parts_move_separately() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    let seen = vm.version();
    vm.send(SeriesIntent::SetWatched { on: true });
    let c = futures_executor::block_on(vm.changed(seen));
    assert_eq!(c.parts, part::SERIES_BUTTON);
}

/// F3: the list entry has no stars and no age rating; the fresh series gives both.
#[test]
fn series_page_takes_rating_age_rating_and_overview_from_the_full_series() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    assert_eq!(vm.rating().community_rating, None);
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    let r = vm.rating();
    assert_eq!(r.community_rating, Some(8.1));
    assert_eq!(r.age_rating.as_deref(), Some("TV-MA"));
    assert_eq!(vm.button().overview.as_deref(), Some("Full text."));
}

/// #33: an episode with several versions asks; one whose sources are not known yet is gray while the
/// list loads, and a picked version starts at once.
#[test]
fn an_episode_with_two_versions_asks_which() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    vm.send(SeriesIntent::SelectSeason { id: "se1".into() });
    wait_for("season 1", || vm.episodes().total == 100);
    assert!(matches!(
        vm.play_episode("e1-5", None),
        PlayAction::Choose { ref versions, .. } if versions.len() == 2
    ));
    assert!(matches!(
        vm.play_episode("e1-5", Some("uhd")),
        PlayAction::Start { source_id: Some(ref id), .. } if id == "uhd"
    ));
    assert!(matches!(vm.play_episode("nope", None), PlayAction::Wait));
}

/// The version of the episode played before is kept for the next one (`MediaVersions::matching`): same
/// name (trimmed, any case), else same resolution, else the question is asked again.
#[test]
fn the_next_episode_keeps_the_version_of_the_one_before() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    vm.send(SeriesIntent::SelectSeason { id: "se1".into() });
    wait_for("season 1", || vm.episodes().total == 100);
    // Nothing played yet: it asks.
    assert!(matches!(
        vm.play_episode("e1-6", None),
        PlayAction::Choose { .. }
    ));
    // The user picks 4K on episode 5; episode 6 has two versions on its own ids and starts the 4K one.
    assert!(matches!(
        vm.play_episode("e1-5", Some("uhd")),
        PlayAction::Start { source_id: Some(ref id), .. } if id == "uhd"
    ));
    assert!(matches!(
        vm.play_episode("e1-6", None),
        PlayAction::Start { ref item_id, source_id: Some(ref id), .. } if item_id == "e1-6" && id == "uhd6"
    ));
    // Different names but the same resolution (kept: 2160 p): the 2160 p version of episode 7.
    let kept: swiftly_model::MediaSource =
        serde_json::from_value(serde_json::json!({"Id": "x", "Name": "Other", "MediaStreams": [{"Type": "Video", "Height": 2160}]})).unwrap();
    vm.keep_version(Some(kept));
    assert!(matches!(
        vm.play_episode("e1-7", None),
        PlayAction::Start { source_id: Some(ref id), .. } if id == "b7"
    ));
    // No match by name or resolution: the default applies, which here is to ask.
    assert!(matches!(
        vm.play_episode("e1-8", None),
        PlayAction::Choose { ref versions, .. } if versions.len() == 2
    ));
    // The main button follows the same rule through the episode list only when asked for; forgetting asks again.
    vm.keep_version(None);
    assert!(matches!(
        vm.play_episode("e1-6", None),
        PlayAction::Choose { .. }
    ));
}

/// Line 11 (#6): the page never asks for episodes the server only knows by name (missing files).
#[test]
fn the_series_page_asks_for_no_missing_episodes() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    let asked: Vec<String> = net
        .urls()
        .into_iter()
        .filter(|u| u.contains("Shows/ser/Episodes") || u.contains("Shows/ser/Seasons"))
        .collect();
    assert!(asked.len() >= 2, "{asked:?}");
    for url in &asked {
        assert!(url.to_lowercase().contains("ismissing=false"), "{url}");
    }
}
