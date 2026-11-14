//! The series view model off the happy path: signed out, account switch (late answers of the old
//! account are dropped), the stored copy and cache events, failing flags and lists, retry, cast of the
//! resume episode. Complements `series_vm.rs`.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use common::account;
use common::script::{Script, host, list, wait_for};
use swiftly_cache::{CacheConfig, EntityCache};
use swiftly_model::Item;
use swiftly_vm::{EpisodesStatus, Host, PlayAction, SeriesIntent, SeriesSpec, SeriesVm, ViewCache};

fn entry() -> Item {
    serde_json::from_value(serde_json::json!({
        "Id": "ser", "Name": "Serie", "Type": "Series",
        "UserData": {"Played": true, "IsFavorite": true}
    }))
    .unwrap()
}

fn episode(n: usize) -> serde_json::Value {
    serde_json::json!({"Id": format!("e{n}"), "Name": format!("Folge {n}"), "Type": "Episode",
        "IndexNumber": n, "ParentIndexNumber": 1, "SeasonId": "se1", "SeriesId": "ser",
        "UserData": {"Played": false}})
}

/// One season with three episodes; the viewer is at E2, whose cast is listed. `episodes_up` switches
/// the episode list off for the failure tests; the flag calls always succeed.
fn server(episodes_up: Arc<AtomicBool>) -> Arc<Script> {
    server_with(episodes_up, true, false)
}

/// `state_cast`: the resume episode lists people; `series_cast`: the series itself (`GET /Items/ser`) does.
fn server_with(episodes_up: Arc<AtomicBool>, state_cast: bool, series_cast: bool) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path();
        if p.ends_with("/Items/ser") {
            let mut s = serde_json::json!({"Id": "ser", "Name": "Serie", "Type": "Series",
                "ProductionYear": 2015, "CommunityRating": 8.1, "OfficialRating": "TV-MA",
                "Overview": "Full text.", "UserData": {"IsFavorite": false}});
            if series_cast {
                s["People"] = serde_json::json!([
                    {"Id": "p9", "Name": "Anna Test", "Type": "Actor", "Role": "Serie"}
                ]);
            }
            return Some(s.to_string());
        }
        if p.ends_with("Shows/NextUp") {
            let mut e = episode(2);
            if state_cast {
                e["People"] = serde_json::json!([
                    {"Id": "p1", "Name": "Anna", "Type": "Actor", "Role": "Hauptrolle",
                     "PrimaryImageTag": "t1"},
                    {"Id": "p2", "Name": "Regie", "Type": "Director"}
                ]);
            }
            return Some(list(&[e], 1));
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(
                &[
                    serde_json::json!({"Id": "se1", "Name": "Staffel 1", "Type": "Season", "IndexNumber": 1}),
                ],
                1,
            ));
        }
        if p.ends_with("Shows/ser/Episodes") {
            if !episodes_up.load(Ordering::SeqCst) {
                return None;
            }
            return Some(list(&[episode(1), episode(2), episode(3)], 3));
        }
        if p.ends_with("/Similar") || p.ends_with("/SpecialFeatures") {
            return Some("{\"Items\":[]}".into());
        }
        Some("{}".into())
    })
}

fn up() -> Arc<AtomicBool> {
    Arc::new(AtomicBool::new(true))
}

fn vm_with(
    net: &Arc<Script>,
    host: Host,
    account_: Option<swiftly_vm::AccountRef>,
) -> SeriesVm<Script> {
    SeriesVm::new(net.clone(), host, entry(), SeriesSpec::default(), account_).unwrap()
}

fn ready(vm: &SeriesVm<Script>) -> bool {
    vm.button().label_ready && vm.episodes().status != EpisodesStatus::Loading
}

#[test]
fn signed_out_asks_nothing_and_every_action_is_inert() {
    let net = server(up());
    let vm = vm_with(&net, host(), None);
    vm.send(SeriesIntent::Load);
    vm.send(SeriesIntent::Refresh);
    vm.send(SeriesIntent::RetryEpisodes);
    vm.send(SeriesIntent::SetEpisodeWatched {
        id: "e1".into(),
        on: true,
    });
    vm.send(SeriesIntent::MarkSeasonWatched);
    vm.send(SeriesIntent::SelectSeason { id: "se1".into() });
    // The retry flag is raised even without a server, but nothing is sent.
    assert!(net.urls().is_empty(), "{:?}", net.urls());
    assert!(!vm.button().enabled);
    assert_eq!(vm.play_next(None), PlayAction::Wait);
    assert_eq!(vm.play_episode("e1", None), PlayAction::Wait);
    // The toggles come from the list entry until a server says otherwise.
    assert!(vm.button().watched && vm.button().favorite);
}

#[test]
fn a_flag_call_that_fails_puts_the_toggle_back_with_the_reason() {
    let net = Script::new(|r| {
        if r.url.path().contains("UserPlayedItems") {
            None
        } else {
            Some("{}".into())
        }
    });
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    // The entry is already watched: switching it off must come back to "watched".
    assert!(vm.button().watched);
    vm.send(SeriesIntent::SetWatched { on: false });
    assert!(!vm.button().watched, "switches at once");
    wait_for("revert", || vm.button().toggle_error.is_some());
    assert!(vm.button().watched, "put back");
    assert_eq!(vm.button().message, vm.button().toggle_error);
    // A new attempt clears the old reason before it asks again.
    vm.send(SeriesIntent::SetWatchlist { on: false });
    wait_for("second reason", || net.count("UserFavoriteItems") == 1);
    assert_eq!(net.count("UserPlayedItems/ser"), 1);
}

#[test]
fn a_season_that_cannot_be_marked_says_why_and_a_marked_episode_reloads_the_list() {
    let up = up();
    let net = server(up.clone());
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    // Success: the list is asked again after the flag, with the flag sent for that episode.
    let before = net.count("Shows/ser/Episodes");
    vm.send(SeriesIntent::SetEpisodeWatched {
        id: "e3".into(),
        on: true,
    });
    wait_for("episodes again", || {
        net.count("Shows/ser/Episodes") > before
    });
    assert_eq!(net.count("UserPlayedItems/e3"), 1);
    assert_eq!(vm.episodes().rows.len(), 3);
    // Failure: only the server's answer for the flag decides; here the flag route breaks.
    let broken = Script::new(|r| {
        let p = r.url.path();
        if p.contains("UserPlayedItems") {
            return None;
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(
                &[
                    serde_json::json!({"Id": "se1", "Name": "Staffel 1", "Type": "Season", "IndexNumber": 1}),
                ],
                1,
            ));
        }
        if p.ends_with("Shows/ser/Episodes") {
            return Some(list(&[episode(1)], 1));
        }
        Some("{\"Items\":[]}".into())
    });
    let vm2 = vm_with(&broken, host(), Some(account("TOKEN-A")));
    vm2.send(SeriesIntent::Load);
    wait_for("page", || {
        vm2.seasons().selected.is_some() && vm2.episodes().rows.len() == 1
    });
    vm2.send(SeriesIntent::MarkSeasonWatched);
    wait_for("reason", || vm2.button().message.is_some());
    let text = vm2.button().message.clone().unwrap();
    assert!(!text.contains("gesehen vermerkt"), "{text}");
    // The list was not asked again after a failed mark.
    assert_eq!(broken.count("UserPlayedItems/se1"), 1);
}

#[test]
fn retry_episodes_recovers_a_list_that_failed() {
    let up = up();
    up.store(false, Ordering::SeqCst);
    let net = server(up.clone());
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    vm.send(SeriesIntent::Load);
    wait_for("disturbed", || {
        vm.episodes().status == EpisodesStatus::Disturbed
    });
    assert!(vm.episodes().rows.is_empty());
    up.store(true, Ordering::SeqCst);
    vm.send(SeriesIntent::RetryEpisodes);
    wait_for("ready", || vm.episodes().status == EpisodesStatus::Ready);
    assert_eq!(vm.episodes().rows.len(), 3);
}

#[test]
fn a_failed_list_after_a_good_one_keeps_what_is_shown() {
    let up = up();
    let net = server(up.clone());
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    up.store(false, Ordering::SeqCst);
    vm.send(SeriesIntent::Refresh);
    wait_for("asked", || net.count("Shows/ser/Episodes") >= 2);
    vm.send(SeriesIntent::MoreEpisodes);
    assert_eq!(vm.episodes().rows.len(), 3);
    assert_eq!(vm.episodes().status, EpisodesStatus::Ready);
}

#[test]
fn the_cast_comes_from_the_resume_episode_with_its_own_pictures() {
    let net = server(up());
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    assert!(vm.more().cast.is_empty());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm) && !vm.more().cast.is_empty());
    let cast = vm.more().cast.clone();
    // Only the actor, not the director.
    assert_eq!(cast.len(), 1);
    assert_eq!(cast[0].name, "Anna");
    assert!(
        cast[0]
            .image
            .as_ref()
            .is_some_and(|i| i.address.contains("/Items/p1/Images/"))
    );
}

#[test]
fn the_cast_falls_back_to_the_series_people_of_the_fresh_item() {
    // The resume episode lists nobody and the list entry has no people: the series item the page loads does.
    let net = server_with(up(), false, true);
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm) && !vm.more().cast.is_empty());
    let cast = vm.more().cast.clone();
    assert_eq!(cast.len(), 1);
    assert_eq!(cast[0].name, "Anna Test");
}

fn headers_of(net: &Script, path_part: &str) -> Vec<String> {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.url.path().contains(path_part))
        .flat_map(|r| {
            r.headers
                .iter()
                .map(|(_, v)| v.clone())
                .chain(std::iter::once(r.url.to_string()))
        })
        .collect()
}

#[test]
fn switching_the_account_starts_over_with_the_new_token() {
    let net = server(up());
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    assert!(
        headers_of(&net, "Shows/ser/Seasons")
            .iter()
            .any(|h| h.contains("TOKEN-A"))
    );
    // Hold the new account's answers so a fast reload cannot finish before the assertion below.
    net.gate.close();
    vm.send(SeriesIntent::SetWatched { on: true });
    vm.send(SeriesIntent::AccountSwitched {
        account: Some(account("TOKEN-B")),
    });
    // Everything of the old account is gone at once: toggles back to the entry's, no episodes.
    assert!(vm.button().watched && vm.button().favorite, "entry values");
    net.gate.open();
    wait_for("second page", || {
        net.count("Shows/ser/Seasons") == 2 && ready(&vm)
    });
    assert!(
        headers_of(&net, "Shows/ser/Seasons")
            .iter()
            .any(|h| h.contains("TOKEN-B"))
    );
    assert_eq!(vm.episodes().rows.len(), 3);
}

#[test]
fn switching_to_signed_out_drops_the_page_and_ignores_late_answers() {
    let net = server(up());
    net.gate.close();
    let vm = vm_with(&net, host(), Some(account("TOKEN-A")));
    vm.send(SeriesIntent::Load);
    wait_for("requests are out", || net.count("Shows/ser/Seasons") == 1);
    vm.send(SeriesIntent::AccountSwitched { account: None });
    net.gate.open();
    // Give the held answers every chance to arrive.
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert!(vm.episodes().rows.is_empty());
    assert!(vm.button().next_episode.is_none());
    assert!(!vm.button().enabled);
    assert!(vm.more().cast.is_empty());
    assert_eq!(vm.play_next(None), PlayAction::Wait);
}

fn cached_host() -> (Host, ViewCache) {
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    (
        Host {
            cache: Some(cache.clone()),
            ..host()
        },
        cache,
    )
}

fn changed(ids: &str) -> swiftly_cache::Invalidation {
    let message = format!(
        r#"{{"MessageType":"LibraryChanged","Data":{{"ItemsAdded":[],"ItemsUpdated":[{ids}],"ItemsRemoved":[]}}}}"#
    );
    swiftly_cache::parse_ws(&message).unwrap()
}

#[test]
fn a_second_visit_paints_the_facts_from_the_stored_copy_while_offline() {
    let (host_a, cache) = cached_host();
    let net = server(up());
    let first = vm_with(&net, host_a, Some(account("TOKEN-A")));
    first.send(SeriesIntent::Load);
    wait_for("page", || {
        ready(&first) && first.rating().community_rating.is_some()
    });

    let offline = server(up());
    offline.offline.store(true, Ordering::SeqCst);
    let host_b = Host {
        cache: Some(cache.clone()),
        ..host()
    };
    let second = vm_with(&offline, host_b, Some(account("TOKEN-A")));
    assert_eq!(
        second.rating().community_rating,
        None,
        "nothing before the load"
    );
    second.send(SeriesIntent::Load);
    wait_for("stored facts", || {
        second.rating().community_rating == Some(8.1)
    });
    assert_eq!(second.rating().age_rating.as_deref(), Some("TV-MA"));
    assert_eq!(second.button().overview.as_deref(), Some("Full text."));

    // Another account never sees the first one's copy.
    let third = vm_with(
        &offline,
        Host {
            cache: Some(cache),
            ..host()
        },
        Some(account("TOKEN-OTHER")),
    );
    third.send(SeriesIntent::Load);
    wait_for("asked", || offline.count("Shows/ser/Seasons") >= 2);
    assert_eq!(third.rating().community_rating, None);
}

#[test]
fn a_cache_event_of_the_account_reloads_once_per_burst_and_other_accounts_do_nothing() {
    let (host_a, cache) = cached_host();
    let net = server(up());
    let vm = vm_with(&net, host_a, Some(account("TOKEN-A")));
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    wait_for("quiet", || {
        net.count("/Items/ser") >= 1 && net.count("/Similar") >= 1
    });
    let scope = ViewCache::scope(&account("TOKEN-A"));
    let state_before = net.count("Shows/NextUp");

    // An event of another account neither reloads nor uses up the burst allowance.
    cache
        .entity_cache()
        .apply_event(&ViewCache::scope(&account("TOKEN-B")), &changed(r#""ser""#));
    std::thread::sleep(std::time::Duration::from_millis(50));
    assert_eq!(net.count("Shows/NextUp"), state_before);

    cache
        .entity_cache()
        .apply_event(&scope, &changed(r#""ser""#));
    wait_for("reload", || net.count("Shows/NextUp") == state_before + 1);
    // The clock stands still: a second event inside the three seconds is part of the same burst.
    cache
        .entity_cache()
        .apply_event(&scope, &changed(r#""ser""#));
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert_eq!(net.count("Shows/NextUp"), state_before + 1);

    // A dropped scope keeps the watcher and reloads nothing; a dropped view stops being served.
    cache.entity_cache().drop_scope(&scope);
    drop(vm);
    cache
        .entity_cache()
        .apply_event(&scope, &changed(r#""ser""#));
    assert_eq!(net.count("Shows/NextUp"), state_before + 1);
}
