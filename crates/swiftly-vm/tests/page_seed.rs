//! A title page opens complete: the text, the head picture's address and BlurHash come from the list answer that made the
//! tile, and a series' seasons and episodes from the last visit, all before the first request is answered. Frame 1 of
//! the page already has everything that was known; the server's answer only replaces what really differs.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::account;
use common::script::{Script, host, list, param, wait_for};
use swiftly_cache::{CacheConfig, EntityCache};
use swiftly_model::Item;
use swiftly_vm::{
    DetailIntent, DetailVm, EpisodesStatus, HomeIntent, HomePrefs, HomeVm, Host, SearchIntent,
    SearchStatus, SearchVm, SeriesIntent, SeriesSpec, SeriesVm, ViewCache,
};

const HASH: &str = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";

fn cache() -> ViewCache {
    ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap())
}

fn with(cache: &ViewCache) -> Host {
    Host {
        cache: Some(cache.clone()),
        ..host()
    }
}

/// What the tile's host knows: only the name, the type and the resume facts.
fn stand_in(id: &str, kind: &str) -> Item {
    serde_json::from_value(serde_json::json!({"Id": id, "Name": "Die Brücke", "Type": kind}))
        .unwrap()
}

/// The server is gone: nothing may be waited for.
fn silent() -> Arc<Script> {
    let net = Script::new(|_| Some("{}".into()));
    net.offline.store(true, std::sync::atomic::Ordering::SeqCst);
    net
}

#[test]
fn a_film_page_stands_complete_in_frame_one_from_the_list_answer() {
    let cache = cache();
    let scope = ViewCache::scope(&account("TOKEN-A"));
    let listed: Item = serde_json::from_value(serde_json::json!({
        "Id": "m1", "Name": "Die Brücke", "Type": "Movie", "ProductionYear": 1959,
        "Overview": "Ein Dorf, eine Brücke, sieben Jungen.", "Genres": ["Drama", "Krieg"],
        "CommunityRating": 8.1, "OfficialRating": "FSK 12", "RunTimeTicks": 6_000_000_000_i64,
        "ImageTags": {"Primary": "p1", "Logo": "l1"}, "BackdropImageTags": ["b1"],
        "ImageBlurHashes": {"Backdrop": {"b1": HASH}, "Primary": {"p1": HASH}}
    }))
    .unwrap();
    let ticket = cache.ticket(&scope);
    cache.write_page(&ticket, "list", &[listed], Some(1));

    let vm = DetailVm::new(
        silent(),
        with(&cache),
        stand_in("m1", "Movie"),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    // No load, no wait: this is the first frame.
    let hero = vm.hero();
    assert_eq!(
        hero.overview.as_deref(),
        Some("Ein Dorf, eine Brücke, sieben Jungen.")
    );
    assert!(
        hero.secondary_line.contains("Drama"),
        "{}",
        hero.secondary_line
    );
    assert!(
        hero.secondary_line.contains("1959"),
        "{}",
        hero.secondary_line
    );
    assert!(
        hero.image
            .as_ref()
            .is_some_and(|i| i.address.contains("/Items/m1/Images/Backdrop")),
        "{:?}",
        hero.image
    );
    assert!(
        hero.logo.is_some(),
        "the logo's address is known from the tile"
    );
    assert_eq!(hero.image_blur_hash.as_deref(), Some(HASH));
    assert_eq!(hero.age_rating.as_deref(), Some("FSK 12"));
    assert_eq!(hero.community_rating, Some(8.1));
    // A page that asks for the server never replaces the standing text with something emptier.
    vm.send(DetailIntent::Load);
    std::thread::sleep(std::time::Duration::from_millis(30));
    assert_eq!(
        vm.hero().overview.as_deref(),
        Some("Ein Dorf, eine Brücke, sieben Jungen.")
    );
}

fn series_server() -> Arc<Script> {
    Script::new(|r| {
        let p = r.url.path();
        let season = |n: i64| serde_json::json!({"Id": format!("se{n}"), "Name": format!("Staffel {n}"), "Type": "Season", "IndexNumber": n});
        if p.ends_with("/Items/ser") {
            return Some(
                serde_json::json!({"Id": "ser", "Name": "Hafenlichter", "Type": "Series"})
                    .to_string(),
            );
        }
        if p.ends_with("Shows/NextUp") {
            return Some(list(&[], 0));
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(&[season(1), season(2)], 2));
        }
        if p.ends_with("Shows/ser/Episodes") {
            let s = if param(r, "seasonId").as_deref() == Some("se2") {
                2
            } else {
                1
            };
            let rows: Vec<_> = (1..=4)
                .map(|n| serde_json::json!({"Id": format!("e{s}-{n}"), "Name": format!("Folge {n}"), "Type": "Episode",
                    "IndexNumber": n, "ParentIndexNumber": s, "SeasonId": format!("se{s}"), "SeriesId": "ser",
                    "ImageTags": {"Primary": "still"}, "ImageBlurHashes": {"Primary": {"still": HASH}}}))
                .collect();
            return Some(list(&rows, 4));
        }
        Some("{\"Items\":[]}".into())
    })
}

#[test]
fn a_series_page_reopens_with_seasons_and_episodes_in_frame_one() {
    let cache = cache();
    let first = SeriesVm::new(
        series_server(),
        with(&cache),
        stand_in("ser", "Series"),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    // The very first visit has nothing to show yet.
    assert!(first.seasons().seasons.is_empty());
    first.send(SeriesIntent::Load);
    wait_for("first visit", || {
        first.episodes().status == EpisodesStatus::Ready && !first.episodes().rows.is_empty()
    });
    let seen = first.episodes().rows.clone();
    // The stored shape is written after the page is published; wait for it to land.
    wait_for("shape stored", || {
        let again = SeriesVm::new(
            silent(),
            with(&cache),
            stand_in("ser", "Series"),
            SeriesSpec::default(),
            Some(account("TOKEN-A")),
        )
        .unwrap();
        !again.seasons().seasons.is_empty()
    });

    // The second visit with the server gone: nothing was asked, yet the page is whole.
    let second = SeriesVm::new(
        silent(),
        with(&cache),
        stand_in("ser", "Series"),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    assert_eq!(
        second.seasons().seasons.len(),
        2,
        "the season picker stands in frame 1"
    );
    assert!(second.seasons().selected.is_some());
    assert_eq!(second.episodes().status, EpisodesStatus::Ready);
    assert_eq!(
        second.episodes().rows,
        seen,
        "the episode rows are the ones seen last time"
    );
    assert!(
        second
            .episodes()
            .rows
            .iter()
            .all(|r| r.image_blur_hash.as_deref() == Some(HASH))
    );
}

/// The film the rows and the search say much of: description, genres, picture marks and BlurHashes.
fn listed_film() -> serde_json::Value {
    serde_json::json!({
        "Id": "m1", "Name": "Die Brücke", "Type": "Movie", "ProductionYear": 1959,
        "Overview": "Ein Dorf, eine Brücke, sieben Jungen.", "Genres": ["Drama", "Krieg"],
        "RunTimeTicks": 6_000_000_000_i64, "ImageTags": {"Primary": "p1"}, "BackdropImageTags": ["b1"],
        "ImageBlurHashes": {"Backdrop": {"b1": HASH}, "Primary": {"p1": HASH}}
    })
}

fn frame_one_is_complete(vm: &DetailVm<Script>) {
    let hero = vm.hero();
    assert_eq!(
        hero.overview.as_deref(),
        Some("Ein Dorf, eine Brücke, sieben Jungen.")
    );
    assert!(
        hero.secondary_line.contains("Drama"),
        "{}",
        hero.secondary_line
    );
    assert_eq!(hero.image_blur_hash.as_deref(), Some(HASH));
    assert!(hero.image.is_some(), "the head picture's address stands");
}

#[test]
fn a_page_opened_from_a_home_tile_is_complete_in_frame_one() {
    let cache = cache();
    let rows = Script::new(|r| {
        let path = r.url.path().to_owned();
        if path.ends_with("/Items") || path.ends_with("/Items/Latest") {
            return Some(list(&[listed_film()], 1));
        }
        Some(list(&[], 0))
    });
    let home = HomeVm::new(
        rows,
        with(&cache),
        HomePrefs::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    home.send(HomeIntent::Load);
    wait_for("home rows", || {
        !home.rails().rails.is_empty() && home.rails().rails.iter().any(|r| r.ids == ["m1"])
    });
    wait_for("tiles stored", || {
        cache
            .read_tile(&ViewCache::scope(&account("TOKEN-A")), "m1")
            .is_some()
    });
    // The tile's host knows only the name; the server is gone.
    let vm = DetailVm::new(
        silent(),
        with(&cache),
        stand_in("m1", "Movie"),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    frame_one_is_complete(&vm);
    // The Home tile showed a portrait poster: it never stands in for the wide head (a landscape tile picture would).
    let hero = vm.hero();
    let tile_images = &hero.tile_images;
    assert!(tile_images.is_empty(), "{tile_images:?}");
}

#[test]
fn a_page_opened_from_a_search_hit_is_complete_in_frame_one() {
    let cache = cache();
    let net = Script::new(|r| {
        if r.url.path().ends_with("/Items") {
            return Some(list(&[listed_film()], 1));
        }
        Some("{}".into())
    });
    let gate = Arc::new(common::Gate::default());
    gate.open();
    let kv = Arc::new(swiftly_library::MemoryKeyValue::new());
    let search = SearchVm::new(
        net,
        with(&cache),
        Arc::new(common::script::GateSleeper(gate)),
        kv,
        Some(account("TOKEN-A")),
    )
    .unwrap();
    search.send(SearchIntent::Query {
        text: "brücke".into(),
    });
    wait_for("hits", || search.status().status == SearchStatus::Done);
    let vm = DetailVm::new(
        silent(),
        with(&cache),
        stand_in("m1", "Movie"),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    frame_one_is_complete(&vm);
}

#[test]
fn a_slim_answer_does_not_wipe_what_an_earlier_one_knew() {
    let cache = cache();
    let scope = ViewCache::scope(&account("TOKEN-A"));
    let full: Item = serde_json::from_value(listed_film()).unwrap();
    let slim = stand_in("m1", "Movie");
    cache.note_tiles(&cache.ticket(&scope), &[full]);
    cache.note_tiles(&cache.ticket(&scope), &[slim]);
    let kept = cache.read_tile(&scope, "m1").unwrap();
    assert_eq!(
        kept.overview.as_deref(),
        Some("Ein Dorf, eine Brücke, sieben Jungen.")
    );
}

#[test]
fn the_series_head_picture_of_a_second_visit_is_the_one_the_first_visit_ended_on() {
    let cache = cache();
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/Items/ser") {
            return Some(
                serde_json::json!({"Id": "ser", "Name": "Hafenlichter", "Type": "Series",
                    "BackdropImageTags": ["b1"], "ImageTags": {"Primary": "p1", "Logo": "l1"},
                    "ImageBlurHashes": {"Backdrop": {"b1": HASH}}})
                .to_string(),
            );
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(
                &[
                    serde_json::json!({"Id": "se1", "Name": "Staffel 1", "Type": "Season", "IndexNumber": 1}),
                ],
                1,
            ));
        }
        Some(list(&[], 0))
    });
    let first = SeriesVm::new(
        net,
        with(&cache),
        stand_in("ser", "Series"),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    assert!(
        first.button().image.is_none(),
        "a bare tile names no head picture"
    );
    first.send(SeriesIntent::Load);
    wait_for("fresh head", || first.button().image_blur_hash.is_some());
    let ended = first.button().image.clone();
    assert!(
        ended
            .as_ref()
            .is_some_and(|i| i.address.contains("Backdrop")),
        "{ended:?}"
    );
    wait_for("title stored", || {
        cache
            .read_title(&ViewCache::scope(&account("TOKEN-A")), "ser")
            .is_some()
    });
    let second = SeriesVm::new(
        silent(),
        with(&cache),
        stand_in("ser", "Series"),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    assert_eq!(second.button().image, ended, "same address in frame 1");
}

/// A series server whose viewer is in season `at`; `seasons` are the seasons it has. Optionally every answer fails.
fn series_at(at: i64, seasons: &'static [i64]) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path();
        let season = |n: i64| serde_json::json!({"Id": format!("se{n}"), "Name": format!("Staffel {n}"), "Type": "Season", "IndexNumber": n});
        if p.ends_with("/Items/ser") {
            return Some(
                serde_json::json!({"Id": "ser", "Name": "Hafenlichter", "Type": "Series"})
                    .to_string(),
            );
        }
        let episode = |s: i64, n: i64| {
            serde_json::json!({"Id": format!("e{s}-{n}"), "Name": format!("Folge {n}"), "Type": "Episode",
            "IndexNumber": n, "ParentIndexNumber": s, "SeasonId": format!("se{s}"), "SeriesId": "ser"})
        };
        if p.ends_with("Shows/NextUp") {
            let mut e = episode(at, 2);
            e["UserData"] = serde_json::json!({"PlaybackPositionTicks": 9_000_000_000_i64});
            return Some(list(&[e], 1));
        }
        if p.ends_with("Shows/ser/Seasons") {
            let all: Vec<_> = seasons.iter().map(|n| season(*n)).collect();
            return Some(list(&all, all.len()));
        }
        if p.ends_with("Shows/ser/Episodes") {
            let s = param(r, "seasonId")
                .and_then(|id| id.trim_start_matches("se").parse().ok())
                .unwrap_or(1);
            let rows: Vec<_> = (1..=4).map(|n| episode(s, n)).collect();
            return Some(list(&rows, 4));
        }
        Some("{\"Items\":[]}".into())
    })
}

fn open_series(net: &Arc<Script>, cache: &ViewCache) -> SeriesVm<Script> {
    SeriesVm::new(
        net.clone(),
        with(cache),
        stand_in("ser", "Series"),
        SeriesSpec::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap()
}

/// A first visit with the viewer in season 1; waits until its shape is stored.
fn visited_in_season_one(cache: &ViewCache) {
    let first = open_series(&series_at(1, &[1, 2]), cache);
    first.send(SeriesIntent::Load);
    wait_for("first visit", || {
        first.episodes().status == EpisodesStatus::Ready
            && first.seasons().selected.as_deref() == Some("se1")
    });
    wait_for("shape stored", || {
        let again = open_series(&silent(), cache);
        again.seasons().selected.as_deref() == Some("se1") && !again.episodes().rows.is_empty()
    });
}

#[test]
fn progress_made_elsewhere_moves_the_reopened_page_to_the_viewers_season() {
    let cache = cache();
    visited_in_season_one(&cache);
    let net = series_at(2, &[1, 2]);
    let second = open_series(&net, &cache);
    assert_eq!(
        second.seasons().selected.as_deref(),
        Some("se1"),
        "frame 1 is the seed"
    );
    second.send(SeriesIntent::Load);
    wait_for("season 2 shown", || {
        second.seasons().selected.as_deref() == Some("se2")
            && second
                .episodes()
                .rows
                .first()
                .is_some_and(|r| r.id.starts_with("e2-"))
    });
    assert_eq!(second.button().next_episode.as_deref(), Some("e2-2"));
}

#[test]
fn a_season_the_server_no_longer_has_is_not_asked_for() {
    let cache = cache();
    visited_in_season_one(&cache);
    let net = series_at(2, &[2]);
    let second = open_series(&net, &cache);
    second.send(SeriesIntent::Load);
    wait_for("season 2 shown", || {
        second.seasons().selected.as_deref() == Some("se2")
            && second
                .episodes()
                .rows
                .first()
                .is_some_and(|r| r.id.starts_with("e2-"))
    });
    assert_eq!(net.count("seasonId=se1"), 0, "{:?}", net.urls());
}

#[test]
fn the_season_the_viewer_picked_in_this_visit_stays() {
    let cache = cache();
    visited_in_season_one(&cache);
    let net = series_at(2, &[1, 2]);
    let second = open_series(&net, &cache);
    second.send(SeriesIntent::SelectSeason { id: "se1".into() });
    second.send(SeriesIntent::Load);
    wait_for("loaded", || {
        second.button().label_ready && second.button().next_episode.as_deref() == Some("e2-2")
    });
    assert_eq!(second.seasons().selected.as_deref(), Some("se1"));
}

#[test]
fn a_failed_state_answer_keeps_the_seed_and_is_never_stored() {
    let cache = cache();
    visited_in_season_one(&cache);
    let seed = open_series(&silent(), &cache).button();
    assert!(seed.enabled && seed.next_episode.is_some());
    let net = series_at(1, &[1, 2]);
    *net.force.lock().unwrap() = Some((500, "boom".to_owned()));
    let second = open_series(&net, &cache);
    second.send(SeriesIntent::Load);
    wait_for("failure told", || second.button().state_failed);
    let button = second.button();
    assert_eq!(button.label, seed.label, "the seed's button stays");
    assert_eq!(button.next_episode, seed.next_episode);
    assert!(button.enabled, "not disabled as 'no episodes'");
    assert!(!second.episodes().rows.is_empty(), "the seed's rows stay");
    // Nothing failed was written back: a third visit without a server still opens from the good shape.
    let third = open_series(&silent(), &cache).button();
    assert_eq!(third.next_episode, seed.next_episode);
    assert!(third.enabled);
}

/// The rows of a film page that arrive late keep their place: the cast of the stored copy stands in frame 1, and a film
/// with no stored copy says that a cast row is expected, so the host reserves its height.
#[test]
fn a_film_page_names_the_rows_that_are_still_to_come() {
    let cache = cache();
    let open = |id: &str, kind: &str, cache: &ViewCache| {
        DetailVm::new(
            silent(),
            with(cache),
            stand_in(id, kind),
            Some(account("TOKEN-A")),
        )
        .unwrap()
    };
    let first = open("m-cast", "Movie", &cache);
    assert!(first.bottom().cast.is_empty() && first.bottom().cast_pending);
    assert!(!open("e-cast", "Episode", &cache).bottom().cast_pending);

    let scope = ViewCache::scope(&account("TOKEN-A"));
    let stored: Item = serde_json::from_value(serde_json::json!({
        "Id": "m-cast", "Name": "Die Brücke", "Type": "Movie",
        "People": [{"Id": "p1", "Name": "Ada", "Type": "Actor", "Role": "Rolle"}]
    }))
    .unwrap();
    cache.write_title(&cache.ticket(&scope), &stored);
    let again = open("m-cast", "Movie", &cache);
    let bottom = again.bottom();
    assert!(!bottom.ready, "the page has not asked anything yet");
    assert_eq!(bottom.cast.len(), 1, "the stored cast stands in frame 1");
    assert!(!bottom.cast_pending);
}

/// A never-opened series that a Home row shows is asked ahead: its page opens with the picker and the rows.
#[test]
fn a_series_a_home_row_shows_opens_with_its_seasons_and_episodes() {
    let cache = cache();
    let net = Script::new(|r| {
        let p = r.url.path();
        let season = |n: i64| serde_json::json!({"Id": format!("se{n}"), "Name": format!("Staffel {n}"), "Type": "Season", "IndexNumber": n});
        if p.ends_with("/Items") || p.ends_with("/Items/Latest") {
            return Some(list(
                &[serde_json::json!({"Id": "ser", "Name": "Hafenlichter", "Type": "Series"})],
                1,
            ));
        }
        if p.ends_with("Shows/ser/Seasons") {
            return Some(list(&[season(1), season(2)], 2));
        }
        if p.ends_with("Shows/ser/Episodes") {
            let rows: Vec<_> = (1..=3)
                .map(|n| serde_json::json!({"Id": format!("e1-{n}"), "Name": format!("Folge {n}"), "Type": "Episode",
                    "IndexNumber": n, "ParentIndexNumber": 1, "SeasonId": "se1", "SeriesId": "ser"}))
                .collect();
            return Some(list(&rows, 3));
        }
        Some(list(&[], 0))
    });
    let home = HomeVm::new(
        net,
        with(&cache),
        HomePrefs::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    home.send(HomeIntent::Load);
    wait_for("the series page's shape is stored by the Home rows", || {
        SeriesVm::new(
            silent(),
            with(&cache),
            stand_in("ser", "Series"),
            SeriesSpec::default(),
            Some(account("TOKEN-A")),
        )
        .map(|vm| vm.seasons().seasons.len() == 2 && vm.episodes().rows.len() == 3)
        .unwrap_or(false)
    });
}
