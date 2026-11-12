//! Plex through the search and library view models: the hub search with its groups, and the
//! watched and watchlist toggles (scrobble and rating) against a scripted Plex server.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::script::{GateSleeper, Script, host, wait_for};
use swiftly_library::{MemoryKeyValue, ShelfSource};
use swiftly_plex::{PlexClient, PlexIdentity};
use swiftly_vm::{
    LibraryIntent, LibrarySpec, LibraryVm, SearchIntent, SearchKind, SearchStatus, SearchVm, Shared,
};

fn plex(net: &Arc<Script>) -> Arc<PlexClient<Shared<Script>>> {
    let identity = PlexIdentity::new("client-1", "1.0", "macOS", "Mac", "Test");
    Arc::new(PlexClient::new(
        "https://plex.example.test".parse().unwrap(),
        "TOKEN",
        identity,
        Arc::new(Shared(net.clone())),
    ))
}

fn open_gate() -> Arc<common::Gate> {
    let gate = Arc::new(common::Gate::default());
    gate.open();
    gate
}

fn server() -> Arc<Script> {
    Script::new(|r| {
        if r.url.path().ends_with("/hubs/search") {
            return Some(
                serde_json::json!({"MediaContainer": {"Hub": [
                    {"type": "movie", "Metadata": [
                        {"ratingKey": "10", "type": "movie", "title": "Dark Plex", "year": 2020}]},
                    {"type": "show", "Metadata": [
                        {"ratingKey": "11", "type": "show", "title": "Dark Show"}]},
                    {"type": "artist", "Metadata": [
                        {"ratingKey": "12", "type": "artist", "title": "Dark Band"}]}
                ]}})
                .to_string(),
            );
        }
        Some("{}".into())
    })
}

#[test]
fn plex_search_groups_movies_and_series_only() {
    let net = server();
    let vm = SearchVm::new(
        net.clone(),
        host(),
        Arc::new(GateSleeper(open_gate())),
        Arc::new(MemoryKeyValue::new()),
        None,
    )
    .unwrap();
    assert_eq!(vm.status().status, SearchStatus::SignedOut);
    vm.set_plex(Some(plex(&net)));
    assert_eq!(vm.status().status, SearchStatus::Idle);
    vm.send(SearchIntent::Pick {
        term: "dark".into(),
    });
    wait_for("done", || vm.status().status == SearchStatus::Done);
    let kinds: Vec<_> = vm.results().groups.iter().map(|g| g.kind).collect();
    assert_eq!(kinds, [SearchKind::Movies, SearchKind::Series]);
    assert_eq!(vm.results().groups[0].tiles[0].title, "Dark Plex");
}

#[test]
fn plex_toggles_scrobble_and_rate() {
    let net = server();
    let vm = LibraryVm::new(
        net.clone(),
        host(),
        Arc::new(MemoryKeyValue::new()),
        LibrarySpec {
            source: ShelfSource::new(Some("lib1"), Some("movies"), false, &[]),
            genre: None,
            remember_name: None,
        },
        None,
    )
    .unwrap();
    vm.set_plex(Some(plex(&net)));
    vm.send(LibraryIntent::SetWatched {
        id: "10".into(),
        on: true,
    });
    vm.send(LibraryIntent::SetWatchlist {
        id: "10".into(),
        on: true,
    });
    wait_for("calls", || {
        net.count("/:/scrobble") == 1 && net.count("/:/rate") == 1
    });
    assert!(net.urls().iter().any(|u| u.contains("rating=10")));
}

// ---- a Plex account from the AccountRef: library paging and the detail page ----

use swiftly_jellyfin::ServerKind;
use swiftly_library::library_filter::Sorting;
use swiftly_library::{LibraryFilter, ShelfSource as Source};
use swiftly_model::Item;
use swiftly_vm::{
    AccountRef, DetailIntent, DetailVm, HomeIntent, HomeVm, LibraryStatus, PlayAction, RailKind,
    Status, plex_client_for,
};

const SECTIONS: &str = include_str!("../../swiftly-plex/tests/fixtures/sections.json");
const PAGE: &str = include_str!("../../swiftly-plex/tests/fixtures/page.json");
const MOVIE: &str = include_str!("../../swiftly-plex/tests/fixtures/movie.json");

fn plex_account() -> AccountRef {
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

fn param(net: &Script, path: &str, name: &str) -> Vec<String> {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.url.path().ends_with(path))
        .filter_map(|r| {
            common::script::param(r, name).or_else(|| {
                r.headers
                    .iter()
                    .find(|(n, _)| n.eq_ignore_ascii_case(name))
                    .map(|(_, v)| v.clone())
            })
        })
        .collect()
}

fn library_server() -> Arc<Script> {
    Script::new(|r| {
        let path = r.url.path();
        if path.ends_with("/library/sections") {
            Some(SECTIONS.into())
        } else if path.ends_with("/all") {
            Some(PAGE.replace(
                r#""title":"One""#,
                r#""title":"One","thumb":"/library/metadata/10/thumb/1""#,
            ))
        } else {
            Some(r#"{"MediaContainer":{"size":0}}"#.into())
        }
    })
}

#[test]
fn the_client_is_built_from_a_plex_account_only() {
    let net = library_server();
    let host = host();
    assert!(
        plex_client_for(&net, &host, &plex_account())
            .unwrap()
            .is_some()
    );
    let mut jelly = plex_account();
    jelly.server_kind = ServerKind::Jellyfin;
    assert!(plex_client_for(&net, &host, &jelly).unwrap().is_none());
    let mut bad = plex_account();
    bad.base_url = "not an address".into();
    assert!(plex_client_for(&net, &host, &bad).is_err());
}

#[test]
fn a_plex_library_loads_sorts_filters_and_pages() {
    let net = library_server();
    let vm = LibraryVm::new(
        net.clone(),
        host(),
        Arc::new(MemoryKeyValue::new()),
        LibrarySpec {
            source: Source::new(Some("1"), Some("movies"), false, &[]),
            genre: None,
            remember_name: None,
        },
        Some(plex_account()),
    )
    .unwrap();
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Latest,
    });
    wait_for("ready", || vm.status().status == LibraryStatus::Ready);
    // The entry without a ratingKey is dropped; the others are Plex poster tiles.
    let titles: Vec<_> = vm.grid().tiles.iter().map(|t| t.title.clone()).collect();
    assert_eq!(titles, ["One", "Two"]);
    assert_eq!(vm.grid().total, 7);
    assert!(vm.status().more_available);
    assert!(
        vm.grid().tiles[0]
            .image
            .as_ref()
            .is_some_and(|i| i.address.contains("plex.example.test"))
    );
    assert_eq!(param(&net, "/all", "sort"), ["addedAt:desc"]);
    assert_eq!(param(&net, "/all", "X-Plex-Container-Start"), ["0"]);

    vm.send(LibraryIntent::LoadMore);
    wait_for("second page", || net.count("/all") == 2);
    // The next page starts after the titles shown (the dropped entry is not counted).
    assert_eq!(param(&net, "/all", "X-Plex-Container-Start")[1], "2");

    vm.send(LibraryIntent::SetFilter {
        filter: LibraryFilter::Unwatched,
    });
    wait_for("filtered", || net.count("/all") == 3);
    assert_eq!(param(&net, "/all", "unwatched").last().unwrap(), "1");
}

fn detail_server() -> Arc<Script> {
    Script::new(|r| {
        let path = r.url.path();
        if path.ends_with("/library/metadata/1") {
            Some(MOVIE.into())
        } else {
            Some(r#"{"MediaContainer":{"size":0}}"#.into())
        }
    })
}

fn entry() -> Item {
    serde_json::from_value(serde_json::json!({"Id": "1", "Name": "Testfilm", "Type": "Movie"}))
        .unwrap()
}

#[test]
fn a_plex_detail_page_has_the_plan_and_the_proof_row() {
    let net = detail_server();
    let vm = DetailVm::new(net.clone(), host(), entry(), Some(plex_account())).unwrap();
    assert!(!vm.actions().proof.visible);
    vm.send(DetailIntent::Load);
    wait_for("plan", || vm.actions().proof.visible && vm.bottom().ready);
    let plan = vm.plan().expect("plan");
    assert!(plan.is_lossless(), "Plex plays the file directly");
    assert!(vm.actions().proof.direct_play);
    assert!(vm.bottom().file.is_some());
    // Plex keeps no list of who watched a title.
    assert!(vm.bottom().watchers.is_empty());
    assert!(vm.hero().image.is_some());
    assert!(matches!(
        vm.play(None),
        PlayAction::Start { .. } | PlayAction::Choose { .. }
    ));

    vm.send(DetailIntent::SetWatched { on: true });
    wait_for("scrobble", || net.count("/:/scrobble") == 1);
}

// ---- the Plex start page ----

#[test]
fn plex_start_page_fills_the_rails_from_the_plex_client() {
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.ends_with("/hubs/continueWatching/items") || p.ends_with("/library/onDeck") {
            return Some(PAGE.into());
        }
        if p.ends_with("/library/sections") {
            return Some(SECTIONS.into());
        }
        if p.contains("/recentlyAdded") {
            return Some(PAGE.into());
        }
        Some("{}".into())
    });
    let vm = HomeVm::new(
        net.clone(),
        host(),
        swiftly_vm::HomePrefs::default(),
        Some(AccountRef {
            server_kind: ServerKind::Plex,
            ..plex_account()
        }),
    )
    .unwrap();
    vm.send(HomeIntent::Load);
    wait_for("ready", || {
        let s = vm.status();
        s.status == Status::Ready && !s.preview && !s.refreshing
    });
    let rails = vm.rails();
    let resume = &rails.rails[0];
    assert_eq!(resume.kind, RailKind::ContinueWatching);
    // The broken entry without a rating key is dropped by the mapper, as in Swift.
    assert_eq!(resume.ids, ["10", "11"]);
    assert_eq!(resume.tiles[0].title, "One");
    assert!(net.count("/hubs/continueWatching/items") >= 1);
    assert!(net.count("/library/onDeck") >= 1);
    assert_eq!(net.count("/UserItems/Resume"), 0);
}

// ---- Plex series page and the detail page's collection rails and cast photos ----

use swiftly_vm::{EpisodesStatus, SeriesIntent, SeriesSpec, SeriesVm};

fn series_server() -> Arc<Script> {
    Script::new(|r| {
        let p = r.url.path();
        let metas = |list: serde_json::Value| {
            Some(serde_json::json!({"MediaContainer": {"Metadata": list}}).to_string())
        };
        if p.ends_with("/library/metadata/3") {
            return Some(include_str!("../../swiftly-plex/tests/fixtures/show.json").into());
        }
        if p.ends_with("/library/metadata/3/children") {
            return metas(serde_json::json!([
                {"ratingKey": "31", "type": "season", "title": "Staffel 1", "index": 1,
                 "parentRatingKey": "3"},
                {"ratingKey": "32", "type": "season", "title": "Staffel 2", "index": 2,
                 "parentRatingKey": "3"}]));
        }
        if p.ends_with("/library/metadata/3/allLeaves") {
            return metas(serde_json::json!([
                {"ratingKey": "311", "type": "episode", "title": "Pilot", "index": 1,
                 "parentIndex": 1, "grandparentRatingKey": "3", "viewCount": 1},
                {"ratingKey": "321", "type": "episode", "title": "Back", "index": 1,
                 "parentIndex": 2, "grandparentRatingKey": "3"}]));
        }
        if p.ends_with("/library/metadata/32/children") {
            return metas(serde_json::json!([
                {"ratingKey": "321", "type": "episode", "title": "Back", "index": 1,
                 "parentIndex": 2, "grandparentRatingKey": "3"}]));
        }
        Some(r#"{"MediaContainer":{"size":0}}"#.into())
    })
}

#[test]
fn a_plex_series_page_has_seasons_episodes_and_the_next_episode() {
    let net = series_server();
    let series: Item = serde_json::from_value(
        serde_json::json!({"Id": "3", "Name": "Test Show", "Type": "Series"}),
    )
    .unwrap();
    let vm = SeriesVm::new(
        net.clone(),
        host(),
        series,
        SeriesSpec::default(),
        Some(plex_account()),
    )
    .unwrap();
    vm.send(SeriesIntent::Load);
    wait_for("page", || {
        vm.button().label_ready && vm.episodes().status == EpisodesStatus::Ready
    });
    assert_eq!(vm.seasons().seasons.len(), 2);
    // Season 1 is watched, so the viewer is in season 2 at its first episode.
    assert_eq!(vm.seasons().selected.as_deref(), Some("32"));
    assert_eq!(vm.episodes().rows.len(), 1);
    assert_eq!(vm.button().next_episode.as_deref(), Some("321"));
    assert!(vm.button().enabled);
    assert_eq!(net.count("/UserItems"), 0);

    vm.send(SeriesIntent::SetWatched { on: true });
    wait_for("scrobble", || net.count("/:/scrobble") == 1);
}

#[test]
fn a_plex_detail_page_has_collection_rails_and_cast_photos() {
    let net = Script::new(|r| {
        let p = r.url.path();
        let metas = |list: serde_json::Value| {
            Some(serde_json::json!({"MediaContainer": {"Metadata": list}}).to_string())
        };
        if p.ends_with("/library/metadata/1") {
            return Some(MOVIE.into());
        }
        if p.ends_with("/library/sections") {
            return Some(SECTIONS.into());
        }
        if p.ends_with("/library/sections/1/collections") {
            return metas(serde_json::json!([
                {"ratingKey": "50", "type": "collection", "title": "Saga"}]));
        }
        if p.ends_with("/library/collections/50/children") {
            return metas(serde_json::json!([
                {"ratingKey": "1", "type": "movie", "title": "Testfilm"},
                {"ratingKey": "2", "type": "movie", "title": "Teil zwei"}]));
        }
        Some(r#"{"MediaContainer":{"size":0}}"#.into())
    });
    let vm = DetailVm::new(net.clone(), host(), entry(), Some(plex_account())).unwrap();
    vm.send(DetailIntent::Load);
    wait_for("bottom", || vm.bottom().ready);
    let bottom = vm.bottom();
    assert_eq!(bottom.collections.len(), 1);
    assert_eq!(bottom.collections[0].title, "Saga");
    let ids: Vec<_> = bottom.collections[0]
        .tiles
        .iter()
        .map(|t| t.id.as_str())
        .collect();
    assert_eq!(ids, ["2"], "the title itself is left out");
    let ann = bottom
        .cast
        .iter()
        .find(|c| c.name == "Ann Actor")
        .expect("cast");
    assert_eq!(
        ann.image.as_ref().map(|i| i.address.as_str()),
        Some("https://metadata-static.plex.tv/a.jpg")
    );
}
