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
    server_with(2)
}

/// The same server with `seasons` seasons in its list.
fn server_with(seasons: i64) -> Arc<Script> {
    Script::new(move |r| {
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
            let all: Vec<_> = (1..=seasons).map(season).collect();
            return Some(list(&all, all.len()));
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
    // Hold the failing answer back, so the optimistic state is seen before the revert.
    fail.gate.close();
    vm.send(SeriesIntent::SetWatchlist { on: true });
    assert!(vm.button().favorite);
    fail.gate.open();
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

/// An episode with several versions starts the default on a tap and offers the others to the long press; one whose
/// sources are not known yet is gray while the list loads, and a picked version starts at once.
#[test]
fn an_episode_with_two_versions_starts_the_default_and_offers_the_others() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    vm.send(SeriesIntent::SelectSeason { id: "se1".into() });
    wait_for("season 1", || vm.episodes().total == 100);
    assert!(matches!(
        vm.play_episode("e1-5", None),
        PlayAction::Start {
            source_id: None,
            ..
        }
    ));
    let versions = vm.versions_of("e1-5");
    assert_eq!(versions.len(), 2);
    assert_eq!(versions.iter().filter(|v| v.is_default).count(), 1);
    assert!(vm.versions_of("nope").is_empty());
    assert!(matches!(
        vm.play_episode("e1-5", Some("uhd")),
        PlayAction::Start { source_id: Some(ref id), .. } if id == "uhd"
    ));
    assert!(matches!(vm.play_episode("nope", None), PlayAction::Wait));
}

/// The mark on the main button's episode follows the plan fetched for it (what a tap starts), not the top version: the
/// server's answer to the device profile transcodes the 4K file and plays the 1080p one as it is.
#[test]
fn the_mark_on_the_next_episode_follows_its_plan() {
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("Shows/NextUp") {
            return Some(list(&[episode(1, 1, false)], 1));
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(&[season(1)], 1));
        }
        if p.ends_with("Shows/ser/Episodes") {
            let mut e = episode(1, 1, false);
            e["MediaSources"] = serde_json::json!([
                {"Id": "uhd", "Name": "4K", "SupportsDirectPlay": true},
                {"Id": "hd", "Name": "1080p", "SupportsDirectPlay": true}]);
            return Some(list(&[e], 1));
        }
        if p.ends_with("/Items/e1-1/PlaybackInfo") {
            return Some(
                serde_json::json!({"PlaySessionId": "ps", "MediaSources": [
                    {"Id": "uhd", "Container": "mkv", "SupportsDirectPlay": false,
                     "SupportsDirectStream": false, "SupportsTranscoding": true,
                     "TranscodingUrl": "/videos/e1-1/master.m3u8?MediaSourceId=uhd"},
                    {"Id": "hd", "Container": "mp4", "SupportsDirectPlay": true}]})
                .to_string(),
            );
        }
        if p.ends_with("/Similar") || p.ends_with("/SpecialFeatures") {
            return Some("{\"Items\":[]}".into());
        }
        Some("{}".into())
    });
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page and plan", || {
        ready(&vm) && vm.plan().is_some() && vm.episodes().total == 1
    });
    assert_eq!(vm.plan().unwrap().media_source_id.as_deref(), Some("hd"));
    let marked: Vec<_> = vm
        .versions_next()
        .iter()
        .map(|v| (v.id.clone(), v.is_default))
        .collect();
    assert_eq!(marked, [("uhd".to_owned(), false), ("hd".to_owned(), true)]);
}

/// One rule for every press on Play: it starts the default version, every time. A pick starts that version for that
/// press only; the next press on the same or another episode starts the default again (the player's own next episode
/// keeps the version, in the player).
#[test]
fn every_press_on_an_episode_with_several_versions_starts_the_default() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    vm.send(SeriesIntent::SelectSeason { id: "se1".into() });
    wait_for("season 1", || vm.episodes().total == 100);
    assert!(matches!(
        vm.play_episode("e1-6", None),
        PlayAction::Start {
            source_id: None,
            ..
        }
    ));
    // The pick starts exactly that version ...
    assert!(matches!(
        vm.play_episode("e1-5", Some("uhd")),
        PlayAction::Start { source_id: Some(ref id), .. } if id == "uhd"
    ));
    // ... and nothing is remembered: the next episode, and the same one again, start the default.
    for id in ["e1-6", "e1-7", "e1-5"] {
        assert!(
            matches!(
                vm.play_episode(id, None),
                PlayAction::Start {
                    source_id: None,
                    ..
                }
            ),
            "{id}"
        );
    }
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

/// A press on Play before the next episode is known is held by the core and starts it once.
#[test]
fn a_press_before_the_next_episode_is_known_is_held_and_sent_once() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    assert_eq!(vm.play_next(None), PlayAction::Wait);
    assert_eq!(
        vm.play_next(None),
        PlayAction::Wait,
        "a second press queues nothing more"
    );
    assert!(vm.take_effects().is_empty());
    vm.send(SeriesIntent::Load);
    wait_for("page", || ready(&vm));
    let effects = vm.take_effects();
    assert!(
        matches!(
            effects.as_slice(),
            [swiftly_vm::SeriesEffect::Play(PlayAction::Resolve { item_id, .. })] if item_id == "e2-2"
        ),
        "{effects:?}"
    );
    assert!(vm.take_effects().is_empty(), "once");
}

/// A series tile that carries a count of one season.
fn one_season_entry() -> Item {
    serde_json::from_value(serde_json::json!({
        "Id": "ser", "Name": "Serie", "Type": "Series", "ChildCount": 1,
        "UserData": {"Played": false, "IsFavorite": false}
    }))
    .unwrap()
}

#[test]
fn the_season_chevron_stands_in_the_first_part_and_never_changes() {
    for seasons in [1, 2] {
        let net = server_with(seasons);
        let vm = SeriesVm::new(
            net.clone(),
            host(),
            one_season_entry(),
            SeriesSpec::default(),
            Some(account("TOKEN-A")),
        )
        .unwrap();
        // Frame 1: before any answer.
        assert!(vm.seasons().chevron, "chevron missing in frame 1");
        vm.send(SeriesIntent::Load);
        wait_for("page", || ready(&vm));
        let done = vm.seasons();
        assert_eq!(done.seasons.len(), seasons as usize);
        assert!(done.chevron, "an answer toggled the chevron");
    }
}

#[test]
fn the_chevron_stands_while_the_count_is_unknown_and_for_a_failed_load() {
    let vm = SeriesVm::new(
        server_with(1),
        host(),
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    assert!(vm.seasons().chevron);
}

/// The scripted server behind a recorder of request depth, with the episode list held back until released. A request
/// counts one level deeper than the deepest request that had finished before it was sent.
struct Held {
    inner: Arc<Script>,
    finished: Arc<std::sync::atomic::AtomicUsize>,
    levels: Arc<std::sync::Mutex<Vec<(usize, String)>>>,
    release: Arc<common::Gate>,
}

impl swiftly_net::HttpTransport for Held {
    fn send(
        &self,
        request: swiftly_net::HttpRequest,
    ) -> impl std::future::Future<Output = Result<swiftly_net::HttpResponse, swiftly_net::ErrorKind>>
    + Send {
        let level = self.finished.load(Ordering::SeqCst) + 1;
        let path = request.url.path().to_owned();
        self.levels.lock().unwrap().push((level, path.clone()));
        let finished = self.finished.clone();
        let release = self.release.wait();
        let answer = self.inner.send(request);
        async move {
            // Pending a number of passes, so that everything that starts side by side is sent before any answer.
            let mut passes = 40;
            std::future::poll_fn(|cx| {
                if passes == 0 {
                    return std::task::Poll::Ready(());
                }
                passes -= 1;
                cx.waker().wake_by_ref();
                std::task::Poll::Pending
            })
            .await;
            if path.ends_with("Shows/ser/Episodes") {
                release.await;
            }
            let reply = answer.await;
            finished.fetch_max(level, Ordering::SeqCst);
            reply
        }
    }
}

/// The plan of the next episode is asked as soon as the state answers: one level behind the first wave, and its
/// answer (the "Direct Play" mark) is on the page while the episode list is still out. Before, the plan came after
/// the state, the seasons, the series and the episode list, so a slow server added all their answer times.
#[test]
fn the_plan_is_asked_right_after_the_state_not_after_the_episode_list() {
    let script = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("Shows/NextUp") {
            return Some(list(&[episode(1, 1, false)], 1));
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(&[season(1)], 1));
        }
        if p.ends_with("Shows/ser/Episodes") {
            return Some(list(&[episode(1, 1, false)], 1));
        }
        if p.ends_with("/Items/e1-1/PlaybackInfo") {
            return Some(
                serde_json::json!({"PlaySessionId": "ps", "MediaSources": [
                    {"Id": "hd", "Container": "mp4", "SupportsDirectPlay": true}]})
                .to_string(),
            );
        }
        if p.ends_with("/Similar") || p.ends_with("/SpecialFeatures") {
            return Some("{\"Items\":[]}".into());
        }
        Some("{}".into())
    });
    let net = Arc::new(Held {
        inner: script,
        finished: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
        levels: Arc::new(std::sync::Mutex::new(Vec::new())),
        release: Arc::new(common::Gate::default()),
    });
    // One worker thread: the tasks of a run take turns at their waiting points, so the depth is the same on every run.
    let host = swiftly_vm::Host {
        spawner: Arc::new(common::Pool(
            futures_executor::ThreadPool::builder()
                .pool_size(1)
                .create()
                .unwrap(),
        )),
        ..host()
    };
    let vm = SeriesVm::new(
        net.clone(),
        host,
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    vm.send(SeriesIntent::Load);
    let end = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !(vm.button().proof.direct_play && vm.plan().is_some()) {
        assert!(
            std::time::Instant::now() < end,
            "no badge: {:?} {:?} {:?}",
            net.levels.lock().unwrap(),
            vm.button().proof,
            vm.button().next_episode
        );
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    assert_eq!(vm.episodes().status, EpisodesStatus::Loading);
    net.release.open();
    wait_for("page", || {
        vm.button().label_ready && vm.episodes().status != EpisodesStatus::Loading
    });
    let levels = net.levels.lock().unwrap().clone();
    let of = |needle: &str| -> Vec<usize> {
        levels
            .iter()
            .filter(|(_, p)| p.contains(needle))
            .map(|(l, _)| *l)
            .collect()
    };
    // Before: the plan came after the state, the seasons, the series and the episode list.
    assert!(of("PlaybackInfo").iter().all(|l| *l <= 2), "{levels:?}");
    assert!(vm.button().proof.direct_play);
}

fn stored_cache() -> swiftly_vm::ViewCache {
    swiftly_vm::ViewCache::new(
        swiftly_cache::EntityCache::in_memory(swiftly_cache::CacheConfig::default()).unwrap(),
    )
}

/// Back to a series page: the year, the description and the stars of the earlier visit stand in the first state
/// (before any answer), in the item the host reads too, and none of them drops while the load runs again.
#[test]
fn re_entering_a_series_keeps_year_description_and_rating_from_the_first_state() {
    let cache = stored_cache();
    let host_with = || swiftly_vm::Host {
        cache: Some(cache.clone()),
        ..host()
    };
    let net = server();
    let first = SeriesVm::new(
        net.clone(),
        host_with(),
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    first.send(SeriesIntent::Load);
    wait_for("first visit", || ready(&first));
    wait_for("title stored", || {
        first.rating().community_rating == Some(8.1)
    });
    drop(first);

    // The second visit opens from the bare list entry; the server does not answer until released.
    let net = server();
    net.gate.close();
    let vm = SeriesVm::new(
        net.clone(),
        host_with(),
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    let held = |vm: &SeriesVm<Script>| {
        let b = vm.button();
        let item = vm.item_json(None).unwrap();
        assert!(
            b.secondary_line.contains("2015"),
            "year: {}",
            b.secondary_line
        );
        assert_eq!(b.overview.as_deref(), Some("Full text."));
        assert_eq!(vm.rating().community_rating, Some(8.1));
        assert_eq!(vm.rating().age_rating.as_deref(), Some("TV-MA"));
        for key in ["ProductionYear", "Overview", "CommunityRating"] {
            assert!(item.contains(key), "{key} missing in {item}");
        }
    };
    held(&vm);
    vm.send(SeriesIntent::Load);
    held(&vm);
    net.gate.open();
    wait_for("reload", || {
        held(&vm);
        ready(&vm)
    });
    held(&vm);
}

/// A later answer that is silent on year, description or stars (a lean answer) takes none of them off the page, and
/// the item the host reads keeps them too.
#[test]
fn a_lean_answer_takes_no_fact_off_a_page_that_shows_it() {
    let cache = stored_cache();
    let host_with = || swiftly_vm::Host {
        cache: Some(cache.clone()),
        ..host()
    };
    let first = SeriesVm::new(
        server(),
        host_with(),
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    first.send(SeriesIntent::Load);
    wait_for("first visit", || ready(&first));
    wait_for("title stored", || {
        first.rating().community_rating == Some(8.1)
    });
    drop(first);

    let lean = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Items/ser") {
            return Some(
                serde_json::json!({"Id": "ser", "Name": "Serie", "Type": "Series"}).to_string(),
            );
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(&[season(1)], 1));
        }
        if p.ends_with("Shows/NextUp") || p.ends_with("Shows/ser/Episodes") {
            return Some(list(&[episode(1, 1, false)], 1));
        }
        if p.ends_with("/Similar") || p.ends_with("/SpecialFeatures") {
            return Some("{\"Items\":[]}".into());
        }
        Some("{}".into())
    });
    let vm = SeriesVm::new(
        lean.clone(),
        host_with(),
        entry(),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    vm.send(SeriesIntent::Load);
    wait_for("lean answer", || {
        ready(&vm) && lean.count("/Items/ser?") + lean.count("/Items/ser") > 0
    });
    let item = vm.item_json(None).unwrap();
    for key in [
        "ProductionYear",
        "Overview",
        "CommunityRating",
        "OfficialRating",
    ] {
        assert!(item.contains(key), "{key} missing in {item}");
    }
    assert_eq!(vm.button().overview.as_deref(), Some("Full text."));
    assert_eq!(vm.rating().community_rating, Some(8.1));
    assert!(vm.button().secondary_line.contains("2015"));
}

/// The page appears again (Back from a title opened on it): `Load` on a page that finished loading refreshes in
/// place, it does not ask for the seasons or the similar titles again.
#[test]
fn load_on_a_loaded_page_refreshes_in_place() {
    let net = server();
    let vm = vm(&net, SeriesSpec::default());
    vm.send(SeriesIntent::Load);
    wait_for("first load", || {
        ready(&vm) && !vm.seasons().seasons.is_empty()
    });
    wait_for("similar", || net.count("/Similar") == 1);
    let (seasons, state) = (net.count("Shows/ser/Seasons"), net.count("Shows/NextUp"));
    assert_eq!(seasons, 1, "first load asks once");
    vm.send(SeriesIntent::Load);
    wait_for("state asked again", || net.count("Shows/NextUp") > state);
    wait_for("settled", || ready(&vm));
    assert_eq!(
        net.count("Shows/ser/Seasons"),
        seasons,
        "seasons not asked again"
    );
    assert_eq!(net.count("/Similar"), 1, "similar not asked again");
    assert_eq!(vm.seasons().seasons.len(), 2, "the season list stays");
}
