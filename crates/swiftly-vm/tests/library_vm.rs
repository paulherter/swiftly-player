//! The library view model against a scripted server: paging, natural name order, sort and
//! filter, remembered choices, load-more failure, offline, genre page, account switch.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::account;
use common::script::{Script, host, list, movie, param, wait_for};
use swiftly_library::library_filter::Sorting;
use swiftly_library::{
    FilterChoice, KeyValue, LibraryFilter, MemoryKeyValue, RememberGenre, ShelfSource, YearSpan,
};
use swiftly_vm::{
    Badge, FailKind, ImageKind, LibraryIntent, LibrarySpec, LibraryStatus, LibraryVm, Load, part,
};

const N: usize = 150;

/// A library of `N` movies; every 10th is watched, every 7th a favourite.
fn server() -> Arc<Script> {
    Script::new(|r| {
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        let all: Vec<_> = (0..N)
            .map(|n| {
                let mut m = movie(n);
                m["UserData"] =
                    serde_json::json!({"Played": n % 10 == 0, "IsFavorite": n % 7 == 0});
                m
            })
            .collect();
        if let Some(ids) = param(r, "Ids") {
            let ids: Vec<_> = ids.split(',').map(String::from).collect();
            let found: Vec<_> = all
                .iter()
                .filter(|m| ids.contains(&m["Id"].as_str().unwrap().to_owned()))
                .cloned()
                .collect();
            return Some(list(&found, found.len()));
        }
        // Server order for "name" is reversed on purpose: only the client order may show.
        let mut all = all;
        if param(r, "EnableImages").is_some() {
            all.reverse();
            return Some(list(&all, N));
        }
        let since: usize = param(r, "StartIndex")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let limit: usize = param(r, "Limit")
            .and_then(|v| v.parse().ok())
            .unwrap_or(100);
        let page: Vec<_> = all.into_iter().skip(since).take(limit).collect();
        Some(list(&page, N))
    })
}

fn spec(name: Option<&str>, genre: Option<&str>) -> LibrarySpec {
    LibrarySpec {
        source: ShelfSource::new(Some("lib1"), Some("movies"), false, &[]),
        genre: genre.map(String::from),
        remember_name: name.map(String::from),
    }
}

fn vm(net: &Arc<Script>, kv: &Arc<MemoryKeyValue>, spec: LibrarySpec) -> LibraryVm<Script> {
    LibraryVm::new(
        net.clone(),
        host(),
        kv.clone(),
        spec,
        Some(account("TOKEN-A")),
    )
    .unwrap()
}

fn ready(vm: &LibraryVm<Script>) -> bool {
    let s = vm.status();
    s.status == LibraryStatus::Ready && !s.loading_more
}

#[test]
fn first_page_is_naturally_ordered_and_display_ready() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    assert_eq!(vm.status().status, LibraryStatus::Loading);
    let seen = vm.version();
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));

    let grid = vm.grid();
    assert_eq!((grid.tiles.len(), grid.total), (60, 150));
    // The slim list came reversed; the page is in name order.
    assert_eq!(grid.tiles[0].title, "Titel 000");
    assert_eq!(grid.tiles[59].title, "Titel 059");
    // 1 slim list + 1 batch of ids per 30 (NATURAL_BATCH), no paged `Items` call.
    assert!(net.count("EnableImages") >= 1);
    let first = &grid.tiles[0];
    assert_eq!(first.subtitle.as_deref(), Some("2000"));
    assert_eq!(first.image.as_ref().unwrap().kind, ImageKind::Poster);
    assert!(
        first
            .image
            .as_ref()
            .unwrap()
            .address
            .contains("/Items/m0/Images/Primary")
    );
    // m0: watched and favourite; m7: favourite only; m1: nothing.
    assert_eq!(first.badges, [Badge::Watched, Badge::Favorite]);
    assert_eq!(grid.tiles[7].badges, [Badge::Favorite]);
    assert!(grid.tiles[1].badges.is_empty());
    let status = vm.status();
    assert!(status.more_available && !status.load_more_failed);
    let change = futures_executor::block_on(vm.changed(seen));
    assert_eq!(change.parts, part::GRID | part::STATUS);
    // The token never travels in a data request's query.
    assert!(net.urls().iter().all(|u| !u.contains("TOKEN-A")));
}

#[test]
fn other_orders_ask_the_server() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("name", || ready(&vm));
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Latest,
    });
    wait_for("latest", || {
        net.count("SortBy=DateCreated") == 1 && ready(&vm)
    });
    let urls = net.urls();
    let last = urls
        .iter()
        .rev()
        .find(|u| u.contains("SortBy=DateCreated"))
        .unwrap_or_else(|| panic!("{urls:#?}"));
    assert!(
        last.contains("SortOrder=Descending") && last.contains("Limit=60"),
        "{last}"
    );
    assert!(
        last.contains("IncludeItemTypes=Movie") && last.contains("ParentId=lib1"),
        "{last}"
    );
    // Same order again: nothing happens.
    let before = net.urls().len();
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Latest,
    });
    assert_eq!(net.urls().len(), before);
}

#[test]
fn a_change_of_order_while_titles_are_shown_reports_refreshing_until_the_page_arrives() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("name", || ready(&vm));
    assert!(!vm.status().refreshing, "nothing runs once the page is in");
    let shown = vm.grid().tiles.len();
    assert!(shown > 0);

    net.gate.close();
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Latest,
    });
    // The quiet refresh: the old grid stays and the status stays ready, but the run is reported.
    let s = vm.status();
    assert_eq!(
        s.status,
        LibraryStatus::Ready,
        "the old grid stays on screen"
    );
    assert!(s.refreshing, "a run is in flight");
    assert_eq!(vm.grid().tiles.len(), shown);

    net.gate.open();
    wait_for("refreshed", || {
        let s = vm.status();
        s.sorting == Sorting::Latest && !s.refreshing && net.count("SortBy=DateCreated") == 1
    });
    assert_eq!(vm.status().status, LibraryStatus::Ready);
}

#[test]
fn filter_reloads_and_choices_are_remembered_per_place() {
    let net = server();
    let kv = Arc::new(MemoryKeyValue::new());
    let first = vm(&net, &kv, spec(Some("filme"), None));
    first.send(LibraryIntent::Load);
    wait_for("ready", || ready(&first));
    first.send(LibraryIntent::SetFilter {
        filter: LibraryFilter::Unwatched,
    });
    wait_for("filtered", || {
        net.count("IsPlayed=false") >= 1 && ready(&first)
    });
    let url = net
        .urls()
        .into_iter()
        .rev()
        .find(|u| u.contains("IsPlayed"))
        .unwrap();
    assert!(url.contains("IsPlayed=false"), "{url}");
    first.send(LibraryIntent::SetSorting {
        sorting: Sorting::Rating,
    });
    wait_for("rating", || {
        net.count("CommunityRating") == 1 && ready(&first)
    });
    assert_eq!(kv.get("filter.filme").as_deref(), Some("ungesehen"));
    assert_eq!(kv.get("sortierung.filme").as_deref(), Some("bewertung"));

    // The next visit starts from there; another place does not.
    let again = vm(&net, &kv, spec(Some("filme"), None));
    let s = again.status();
    assert_eq!(
        (s.sorting, s.filter),
        (Sorting::Rating, LibraryFilter::Unwatched)
    );
    let other = vm(&net, &kv, spec(Some("serien"), None));
    assert_eq!(other.status().sorting, Sorting::Latest);
}

#[test]
fn the_last_rows_load_more_once_and_the_pages_do_not_overlap() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    // A tile far from the end does nothing.
    vm.send(LibraryIntent::Visible {
        id: "m5".into(),
        columns: 3,
    });
    assert!(!vm.status().loading_more);
    let id = vm.grid().tiles[58].id.clone();
    vm.send(LibraryIntent::Visible {
        id: id.clone(),
        columns: 3,
    });
    vm.send(LibraryIntent::Visible { id, columns: 3 });
    wait_for("120", || vm.grid().tiles.len() == 120 && ready(&vm));
    let titles: Vec<_> = vm.grid().tiles.iter().map(|t| t.id.clone()).collect();
    let mut unique = titles.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), 120);
    vm.send(LibraryIntent::LoadMore);
    wait_for("150", || vm.grid().tiles.len() == 150 && ready(&vm));
    assert!(!vm.status().more_available);
    // Nothing more to fetch: no request.
    let before = net.urls().len();
    vm.send(LibraryIntent::LoadMore);
    assert_eq!(net.urls().len(), before);
}

#[test]
fn a_failed_load_more_keeps_the_grid_and_can_be_retried() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    net.offline.store(true, Ordering::SeqCst);
    vm.send(LibraryIntent::LoadMore);
    wait_for("failed", || vm.status().load_more_failed);
    assert_eq!(
        (vm.grid().tiles.len(), vm.status().status),
        (60, LibraryStatus::Ready)
    );
    net.offline.store(false, Ordering::SeqCst);
    vm.send(LibraryIntent::LoadMore);
    wait_for("retried", || vm.grid().tiles.len() == 120 && ready(&vm));
    assert!(!vm.status().load_more_failed);
}

#[test]
fn offline_and_empty_are_told_apart() {
    let net = server();
    net.offline.store(true, Ordering::SeqCst);
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("offline", || vm.status().status == LibraryStatus::Offline);
    assert!(vm.grid().tiles.is_empty());

    let empty = Script::new(|_| Some(list(&[], 0)));
    let vm = LibraryVm::new(
        empty,
        host(),
        Arc::new(MemoryKeyValue::new()),
        spec(None, None),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    vm.send(LibraryIntent::Load);
    wait_for("empty", || vm.status().status == LibraryStatus::Empty);
}

#[test]
fn a_genre_page_asks_for_its_genre_in_both_orders() {
    let net = server();
    let vm = vm(
        &net,
        &Arc::new(MemoryKeyValue::new()),
        spec(None, Some("Sci-Fi")),
    );
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    assert!(
        net.urls()
            .iter()
            .filter(|u| u.contains("EnableImages"))
            .all(|u| u.contains("Genres=Sci-Fi"))
    );
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Rating,
    });
    wait_for("rating", || net.count("CommunityRating") == 1 && ready(&vm));
    let url = net
        .urls()
        .into_iter()
        .rev()
        .find(|u| u.contains("CommunityRating"))
        .unwrap();
    assert!(url.contains("Genres=Sci-Fi"), "{url}");
}

#[test]
fn an_account_switch_clears_the_grid_and_loads_the_new_account() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    vm.send(LibraryIntent::AccountSwitched { account: None });
    assert_eq!(vm.status().status, LibraryStatus::SignedOut);
    assert!(vm.grid().tiles.is_empty());
    vm.send(LibraryIntent::AccountSwitched {
        account: Some(account("TOKEN-B")),
    });
    wait_for("ready again", || ready(&vm));
    assert_eq!(vm.grid().tiles.len(), 60);
    let seen = net.seen.lock().unwrap();
    let last = seen.last().unwrap();
    assert!(last.header("Authorization").unwrap().contains("TOKEN-B"));
}

#[test]
fn toggles_ask_the_server_first_then_update_and_reload() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    assert!(vm.grid().tiles[1].badges.is_empty());
    vm.send(LibraryIntent::SetWatched {
        id: "m1".into(),
        on: true,
    });
    vm.send(LibraryIntent::SetWatchlist {
        id: "m1".into(),
        on: true,
    });
    // Not optimistic: nothing changes before the server has answered (the reload shows it).
    wait_for("reload", || {
        net.count("UserPlayedItems/m1") == 1 && net.count("UserFavoriteItems/m1") == 1
    });
    let seen = net.seen.lock().unwrap();
    let played = seen
        .iter()
        .find(|r| r.url.path().contains("UserPlayedItems/m1"))
        .unwrap();
    assert_eq!(played.method, swiftly_net::Method::Post);
    drop(seen);
    // The script does not store the change; the reload after success asks the library again.
    wait_for("reload", || net.count("SortBy=SortName") >= 2);
}

#[test]
fn a_failed_toggle_changes_nothing_and_says_why() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    net.offline.store(true, Ordering::SeqCst);
    vm.send(LibraryIntent::SetWatched {
        id: "m1".into(),
        on: true,
    });
    wait_for("error", || vm.status().toggle_error.is_some());
    assert!(vm.grid().tiles[1].badges.is_empty());
    net.offline.store(false, Ordering::SeqCst);
    vm.send(LibraryIntent::SetWatched {
        id: "m1".into(),
        on: true,
    });
    wait_for("cleared", || {
        net.count("UserPlayedItems/m1") == 2 && vm.status().toggle_error.is_none()
    });
}

#[test]
fn all_across_libraries_shows_each_work_once() {
    // Two libraries share the work "Titel 2" (same Tmdb id, different item ids).
    let net = Script::new(|r| {
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        let film = |id: &str, n: usize, tmdb: &str| {
            let mut m = movie(n);
            m["Id"] = id.into();
            m["ProviderIds"] = serde_json::json!({"Tmdb": tmdb});
            m
        };
        let a = [film("a0", 0, "0"), film("a1", 1, "1"), film("a2", 2, "2")];
        let b = [film("b2", 2, "2"), film("b3", 3, "3")];
        let everything: Vec<_> = a.iter().chain(b.iter()).cloned().collect();
        match param(r, "ParentId").as_deref() {
            Some("l1") => return Some(list(&a, 3)),
            Some("l2") => return Some(list(&b, 2)),
            _ => {}
        }
        if let Some(ids) = param(r, "Ids") {
            let found: Vec<_> = everything
                .iter()
                .filter(|m| ids.split(',').any(|i| m["Id"] == i))
                .cloned()
                .collect();
            return Some(list(&found, found.len()));
        }
        Some(list(&everything, everything.len()))
    });
    let spec = LibrarySpec {
        source: ShelfSource::new(None, Some("movies"), false, &["l1", "l2"]),
        genre: None,
        remember_name: None,
    };
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec);
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    let grid = vm.grid();
    let titles: Vec<_> = grid.tiles.iter().map(|t| t.title.as_str()).collect();
    assert_eq!(titles, ["Titel 000", "Titel 001", "Titel 002", "Titel 003"]);
    assert_eq!(grid.total, 4);
    // Both libraries were asked for their ids.
    assert_eq!(net.count("ParentId=l1"), 1);
    assert_eq!(net.count("ParentId=l2"), 1);
}

#[test]
fn the_letter_strip_finds_keys_and_jump_targets() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    let strip = vm.alphabet();
    // Every title is "Titel nnn": one letter, so there is no strip to jump between.
    assert_eq!(strip.entries.len(), 1);
    assert_eq!(strip.entries[0].letter, "T");
    assert_eq!(strip.entries[0].first, 0);
    assert!(!strip.is_useful());
    assert_eq!(vm.key_of("m0", &strip).as_deref(), Some("T"));
    assert_eq!(vm.key_of("nope", &strip), None);
    assert_eq!(vm.jump_target("T", &strip), Some(0));
    assert_eq!(vm.jump_target("Z", &strip), None);
}

#[test]
fn the_strip_of_another_order_is_empty_and_fetches_nothing() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Erscheinung,
    });
    wait_for("ready", || {
        ready(&vm) && vm.status().sorting == Sorting::Erscheinung
    });
    let before = net.urls().len();
    futures_executor::block_on(vm.load_alphabet());
    assert_eq!(
        net.urls().len(),
        before,
        "no whole-list fetch for a strip nobody draws"
    );
    let strip = vm.alphabet();
    assert!(strip.entries.is_empty() && !strip.is_useful());
}

/// Merkliste edge: the last remembered title is removed; the server answers the reload with an empty list, and the view
/// model ends `Empty` with no tiles (the screen then shows its empty state), not stuck on the old tile or `Loading`.
#[test]
fn removing_the_last_watchlist_title_leaves_an_empty_grid() {
    let gone = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = gone.clone();
    let net = Script::new(move |r| {
        if r.method != swiftly_net::Method::Get && r.url.path().contains("UserFavoriteItems") {
            flag.store(true, Ordering::SeqCst);
            return Some("{}".into());
        }
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        if flag.load(Ordering::SeqCst) {
            return Some(list(&[], 0));
        }
        let mut m = movie(0);
        m["UserData"] = serde_json::json!({"Played": false, "IsFavorite": true});
        Some(list(&[m], 1))
    });
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::SetFilter {
        filter: LibraryFilter::Watchlist,
    });
    vm.send(LibraryIntent::Load);
    wait_for("one title", || ready(&vm) && vm.grid().tiles.len() == 1);
    vm.send(LibraryIntent::SetWatchlist {
        id: "m0".into(),
        on: false,
    });
    wait_for("empty", || {
        gone.load(Ordering::SeqCst)
            && vm.status().status == LibraryStatus::Empty
            && vm.grid().tiles.is_empty()
    });
    assert_eq!(vm.status().filter, LibraryFilter::Watchlist);
    assert!(vm.status().toggle_error.is_none());
}

#[test]
fn a_failed_load_names_its_kind_and_unreachable_stays_offline() {
    let cases = [
        (500, "{}", Load::Failed(FailKind::Server)),
        (401, "{}", Load::Failed(FailKind::Denied)),
        (200, "not json", Load::Failed(FailKind::Unreadable)),
    ];
    for (status, body, expected) in cases {
        let net = server();
        *net.force.lock().unwrap() = Some((status, body.to_owned()));
        let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
        vm.send(LibraryIntent::Load);
        wait_for("failed", || vm.status().status == LibraryStatus::Offline);
        assert_eq!(vm.load(), expected, "status {status}");
        // The next load that gets through forgets the reason.
        *net.force.lock().unwrap() = None;
        vm.send(LibraryIntent::Load);
        wait_for("ready", || vm.status().status == LibraryStatus::Ready);
        assert_eq!(vm.load(), Load::Loaded);
    }
    let net = server();
    net.offline.store(true, Ordering::SeqCst);
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("offline", || vm.status().status == LibraryStatus::Offline);
    assert_eq!(vm.load(), Load::Offline);
}

/// The Merkliste shows movies AND series (the Mac's `WatchlistModel`), and the kind pill narrows it: the query asks for
/// the kind's types over every library, the choice is remembered, and the same kind again is a no-op.
#[test]
fn the_merkliste_page_mixes_movies_and_series_and_the_kind_narrows_it() {
    let net = Script::new(|r| {
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        let fav = |mut v: serde_json::Value| {
            v["UserData"] = serde_json::json!({"Played": false, "IsFavorite": true});
            v
        };
        let mut show = fav(movie(2));
        show["Type"] = "Series".into();
        let both = [fav(movie(1)), show];
        let found: Vec<_> = if let Some(ids) = param(r, "Ids") {
            both.into_iter()
                .filter(|m| ids.contains(m["Id"].as_str().unwrap()))
                .collect()
        } else {
            let types = param(r, "IncludeItemTypes").unwrap_or_default();
            both.into_iter()
                .filter(|m| types.contains(m["Type"].as_str().unwrap()))
                .collect()
        };
        let n = found.len();
        Some(list(&found, n))
    });
    let kv = Arc::new(MemoryKeyValue::new());
    let vm = vm(&net, &kv, spec(None, None));
    assert_eq!(
        vm.remembered_kind(),
        RememberGenre::All,
        "nothing chosen yet means both kinds"
    );
    assert!(vm.set_remember_kind(RememberGenre::All));
    wait_for("both kinds", || ready(&vm) && vm.grid().tiles.len() == 2);
    assert_eq!(vm.status().filter, LibraryFilter::Watchlist);
    let url = net
        .urls()
        .into_iter()
        .rev()
        .find(|u| u.contains("IncludeItemTypes"))
        .unwrap();
    assert!(
        url.contains("IsFavorite")
            && url.contains("Movie")
            && url.contains("Series")
            && !url.contains("ParentId"),
        "{url}"
    );
    assert!(
        !vm.set_remember_kind(RememberGenre::All),
        "the same kind again changes nothing"
    );

    assert!(vm.set_remember_kind(RememberGenre::SeriesList));
    wait_for("series only", || ready(&vm) && vm.grid().tiles.len() == 1);
    assert_eq!(vm.remembered_kind(), RememberGenre::SeriesList);
    assert_eq!(kv.get("gattung.merkliste").as_deref(), Some("tvshows"));
    assert!(vm.set_remember_kind(RememberGenre::Movies));
    wait_for("movies only", || {
        ready(&vm) && vm.grid().tiles.len() == 1 && vm.grid().tiles[0].id == "m1"
    });
    assert!(vm.set_remember_kind(RememberGenre::All));
    wait_for("both again", || ready(&vm) && vm.grid().tiles.len() == 2);
}

/// Merkliste: the order starts at "latest" (DateCreated, newest first, `WatchlistModel.sorting = .latest`), and a
/// remembered choice of the viewer wins.
#[test]
fn the_merkliste_starts_with_the_newest_saved_first() {
    let net = Script::new(|r| {
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        let mut m = movie(1);
        m["UserData"] = serde_json::json!({"Played": false, "IsFavorite": true});
        Some(list(&[m], 1))
    });
    let kv = Arc::new(MemoryKeyValue::new());
    let first = vm(&net, &kv, spec(Some("merkliste"), None));
    assert!(first.set_remember_kind(RememberGenre::All));
    wait_for("grid", || ready(&first));
    assert_eq!(first.status().sorting, Sorting::Latest);
    let url = net
        .urls()
        .into_iter()
        .rev()
        .find(|u| u.contains("IncludeItemTypes"))
        .unwrap();
    assert!(
        url.contains("SortBy=DateCreated") && url.contains("SortOrder=Descending"),
        "{url}"
    );
    // A stored choice stays.
    let kv2 = Arc::new(MemoryKeyValue::new());
    kv2.set("sortierung.merkliste", "bewertung");
    let vm2 = vm(&net, &kv2, spec(Some("merkliste"), None));
    assert!(vm2.set_remember_kind(RememberGenre::All));
    wait_for("grid 2", || ready(&vm2));
    assert_eq!(vm2.status().sorting, Sorting::Rating);
}

/// Merkliste (L2): a film that is on the watchlist in two libraries is one tile and one counted work, and the page
/// asks the way the Mac's `rememberedItems` does (slim list, merge per work, then the page by ids).
#[test]
fn the_merkliste_shows_each_work_once() {
    let net = Script::new(|r| {
        let path = r.url.path().to_owned();
        if path.ends_with("/UserViews") {
            return Some(list(
                &[
                    serde_json::json!({"Id": "libA", "Name": "Filme", "Type": "CollectionFolder"}),
                    serde_json::json!({"Id": "libB", "Name": "Filme 4K", "Type": "CollectionFolder"}),
                ],
                2,
            ));
        }
        if path.ends_with("/Ancestors") {
            let lib = if path.contains("/Items/a1/") {
                "libA"
            } else {
                "libB"
            };
            return Some(
                serde_json::json!([{"Id": lib, "Name": "x", "Type": "CollectionFolder"}])
                    .to_string(),
            );
        }
        if !path.ends_with("/Items") {
            return Some("{}".into());
        }
        let both = |id: &str, name: &str| {
            serde_json::json!({"Id": id, "Name": name, "Type": "Movie", "ProviderIds": {"Tmdb": "77"},
                "ImageTags": {"Primary": "p"}})
        };
        let other = serde_json::json!({"Id": "c1", "Name": "Zweitfilm", "Type": "Movie",
            "ProviderIds": {"Tmdb": "5"}, "ImageTags": {"Primary": "p"}});
        let all = vec![both("a1", "Doppelt"), both("a2", "Doppelt"), other];
        if let Some(ids) = param(r, "Ids") {
            let found: Vec<_> = all
                .iter()
                .filter(|m| ids.split(',').any(|i| i == m["Id"].as_str().unwrap()))
                .cloned()
                .collect();
            return Some(list(&found, found.len()));
        }
        Some(list(&all, 3))
    });
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    assert!(vm.set_remember_kind(RememberGenre::Movies));
    wait_for("one tile per work", || {
        ready(&vm) && vm.grid().tiles.len() == 2
    });
    let grid = vm.grid();
    assert_eq!(grid.total, 2, "the count badge counts works");
    let ids: Vec<_> = grid.tiles.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(ids, ["a1", "c1"]);
    assert!(
        net.count("Fields=ProviderIds") >= 1,
        "the slim list asks for provider ids"
    );
}

/// Only the name order has a strip (the whole list, each letter jumps to its first title); recently added, rating and
/// release date return none.
#[test]
fn only_the_name_order_has_a_strip() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    for sorting in [
        Sorting::Name,
        Sorting::Latest,
        Sorting::Rating,
        Sorting::Erscheinung,
    ] {
        vm.send(LibraryIntent::SetSorting { sorting });
        wait_for("sorted", || ready(&vm) && vm.status().sorting == sorting);
        futures_executor::block_on(vm.load_alphabet());
        let strip = vm.alphabet();
        if sorting != Sorting::Name {
            assert!(strip.entries.is_empty(), "{sorting:?}: no strip");
            assert!(!strip.is_useful(), "{sorting:?}: no strip");
            continue;
        }
        assert_eq!(
            strip.count, N,
            "{sorting:?}: the strip must cover the whole list"
        );
        assert!(!strip.entries.is_empty(), "{sorting:?}: no letters");
        // The target is the strip's own position in the whole list (it may lie past the loaded page), and every
        // letter of the strip has one, each its own entry's.
        for e in &strip.entries {
            assert_eq!(
                vm.jump_target(&e.letter, &strip),
                Some(e.first),
                "{sorting:?}: {} jumps elsewhere",
                e.letter
            );
            assert!(e.first < N, "{sorting:?}: jump past the whole list");
        }
    }
}

/// The host asks for keys and jumps before it ever asked for the strip (a page puts its tiles up first): the core
/// builds the strip itself, so every letter still lands on its own first title; a switch of the order rebuilds it.
#[test]
fn keys_and_jumps_do_not_need_the_strip_to_be_asked_for_first() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec(None, None));
    vm.send(LibraryIntent::Load);
    wait_for("ready", || ready(&vm));
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Name,
    });
    wait_for("sorted", || {
        ready(&vm) && vm.status().sorting == Sorting::Name
    });
    futures_executor::block_on(vm.load_alphabet());
    let mut held = None;
    vm.keep_strip(&mut held);
    let strip = held.clone().expect("the strip is built on demand");
    assert_eq!(strip.count, N);
    assert!(!strip.entries.is_empty());
    for e in &strip.entries {
        assert_eq!(
            vm.jump_target(&e.letter, held.as_ref().expect("held")),
            Some(e.first),
            "{}",
            e.letter
        );
    }
    assert!(vm.key_of("m0", held.as_ref().expect("held")).is_some());
    // Another order: the held strip is replaced, not reused.
    vm.send(LibraryIntent::SetSorting {
        sorting: Sorting::Latest,
    });
    wait_for("sorted", || {
        ready(&vm) && vm.status().sorting == Sorting::Latest
    });
    vm.keep_strip(&mut held);
    assert_eq!(held.as_ref().map(|s| s.sorting), Some(Sorting::Latest));
}

/// The page starts from the bare section (as the desktop builds it) and learns its libraries afterwards: "All" must
/// then read from those libraries, each work once, like the Mac's `LibraryView.source`. Without it every title that
/// lives in two libraries is listed twice, and what sits in libraries of other kinds shows up as movies.
#[test]
fn the_offer_of_libraries_turns_the_bare_section_into_all_libraries_each_work_once() {
    let net = Script::new(|r| {
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        let film = |id: &str, n: usize, tmdb: &str| {
            let mut m = movie(n);
            m["Id"] = id.into();
            m["ProviderIds"] = serde_json::json!({"Tmdb": tmdb});
            m
        };
        let a = [film("a0", 0, "0"), film("a1", 1, "1"), film("a2", 2, "2")];
        let b = [film("b2", 2, "2"), film("b3", 3, "3")];
        // A library of home videos whose clips are typed `Movie` on the server.
        let clips = [film("c9", 9, "99")];
        let everything: Vec<_> = a.iter().chain(&b).chain(&clips).cloned().collect();
        match param(r, "ParentId").as_deref() {
            Some("l1") => return Some(list(&a, 3)),
            Some("l2") => return Some(list(&b, 2)),
            Some("l3") => return Some(list(&clips, 1)),
            _ => {}
        }
        if let Some(ids) = param(r, "Ids") {
            let found: Vec<_> = everything
                .iter()
                .filter(|m| ids.split(',').any(|i| m["Id"] == i))
                .cloned()
                .collect();
            return Some(list(&found, found.len()));
        }
        Some(list(&everything, everything.len()))
    });
    let spec = LibrarySpec {
        source: ShelfSource::new(None, Some("movies"), false, &[]),
        genre: None,
        remember_name: None,
    };
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), spec);
    let library = |id: &str, kind: &str| swiftly_model::Item {
        id: id.into(),
        name: id.into(),
        collection_type: Some(kind.into()),
        ..swiftly_model::Item::default()
    };
    vm.follow_offering(swiftly_playback::section_offering::SectionOffering::new(
        "movies",
        vec![library("l1", "movies"), library("l2", "movies")],
        0,
        0,
    ));
    wait_for("ready", || ready(&vm) && vm.grid().total > 0);
    let grid = vm.grid();
    let titles: Vec<_> = grid.tiles.iter().map(|t| t.title.as_str()).collect();
    assert_eq!(titles, ["Titel 000", "Titel 001", "Titel 002", "Titel 003"]);
    assert_eq!(grid.total, 4);
}

/// Years 2000..2019 (`n % 20`), audio German for every third title and English for the rest, every 10th watched.
fn filter_server() -> Arc<Script> {
    Script::new(|r| {
        if r.url.path().ends_with("/Items/Filters") {
            let years: Vec<_> = (2000..2020).collect();
            return Some(serde_json::json!({ "Years": years }).to_string());
        }
        if !r.url.path().ends_with("/Items") {
            return Some("{}".into());
        }
        let unwatched = param(r, "IsPlayed").as_deref() == Some("false");
        let all: Vec<_> = (0..N)
            .filter(|n| !unwatched || n % 10 != 0)
            .map(|n| {
                let mut m = movie(n);
                m["UserData"] = serde_json::json!({"Played": n % 10 == 0});
                let language = if n % 3 == 0 { "deu" } else { "eng" };
                m["MediaSources"] = serde_json::json!([{"MediaStreams": [{"Type": "Audio", "Language": language}]}]);
                m
            })
            .collect();
        if let Some(ids) = param(r, "Ids") {
            let ids: Vec<_> = ids.split(',').map(String::from).collect();
            let found: Vec<_> = all
                .iter()
                .filter(|m| ids.contains(&m["Id"].as_str().unwrap().to_owned()))
                .cloned()
                .collect();
            return Some(list(&found, found.len()));
        }
        // The whole list in one answer (the natural order, the title ids, the audio scan).
        let total = all.len();
        if param(r, "EnableImages").is_some() {
            return Some(list(&all, total));
        }
        let since: usize = param(r, "StartIndex")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let limit: usize = param(r, "Limit")
            .and_then(|v| v.parse().ok())
            .unwrap_or(100);
        let page: Vec<_> = all.into_iter().skip(since).take(limit).collect();
        Some(list(&page, total))
    })
}

/// How many of the `N` titles are in the 2010s, German, unwatched.
fn expected(decade: bool, german: bool, unwatched: bool) -> i64 {
    (0..N)
        .filter(|n| !decade || n % 20 >= 10)
        .filter(|n| !german || n % 3 == 0)
        .filter(|n| !unwatched || n % 10 != 0)
        .count() as i64
}

#[test]
fn the_filter_sheet_picks_combine_remember_and_name_the_pill() {
    let net = filter_server();
    let kv = Arc::new(MemoryKeyValue::new());
    // The mock narrows by the whole list in name order, so this visitor picked "By name" earlier.
    kv.set("sortierung.filme", "name");
    let first = vm(&net, &kv, spec(Some("filme"), None));
    first.send(LibraryIntent::Load);
    wait_for("ready", || ready(&first));
    assert_eq!(first.grid().total, N as i64);
    assert_eq!(first.pill_text(), "Alle");

    // Opening the sheet fetches the decades and the languages; every platform draws these lines.
    first.send(LibraryIntent::LoadFilterOptions);
    wait_for("facets", || {
        let sheet = first.filter_sheet(&LibraryFilter::ALL);
        sheet.groups.len() == 3 && sheet.groups.iter().all(|g| !g.loading)
    });
    let lines = first.filter_sheet(&LibraryFilter::ALL).flat_rows();
    let text: Vec<_> = lines
        .iter()
        .map(|l| (l.heading.as_deref(), l.label.as_str()))
        .collect();
    // The most titles first: English (100) before German (50), named in the interface language.
    let english = swiftly_vm::language_name("eng", "de").unwrap_or_else(|| "ENG".into());
    assert_eq!(
        text,
        [
            (None, "Alle"),
            (None, "Angefangen"),
            (None, "Merkliste"),
            (None, "Ungesehen"),
            (Some("Erscheinungsjahr"), "Alle Jahre"),
            (None, "2010\u{2013}2019"),
            (None, "2000\u{2013}2009"),
            (Some("Sprache"), "Alle Sprachen"),
            (None, english.as_str()),
            (None, "Deutsch"),
        ],
        "{text:?}"
    );
    let choice_of = |label: &str| {
        lines
            .iter()
            .find(|l| l.label == label)
            .and_then(|l| l.choice.clone())
            .unwrap()
    };

    // Decade, then language, then status: each pick narrows the previous one.
    first.pick(choice_of("2010\u{2013}2019"));
    wait_for("decade", || {
        first.grid().total == expected(true, false, false) && ready(&first)
    });
    assert_eq!(first.pill_text(), "Alle \u{b7} 2010\u{2013}2019");
    first.pick(choice_of("Deutsch"));
    wait_for("language", || {
        first.grid().total == expected(true, true, false) && ready(&first)
    });
    first.pick(FilterChoice::Status(LibraryFilter::Unwatched));
    wait_for("unwatched", || {
        first.grid().total == expected(true, true, true) && ready(&first)
    });
    assert_eq!(
        first.pill_text(),
        "Ungesehen \u{b7} 2010\u{2013}2019 \u{b7} Deutsch"
    );
    let sheet = first.filter_sheet(&LibraryFilter::ALL);
    assert_eq!(sheet.pill, first.pill_text());
    let picked: Vec<_> = sheet
        .flat_rows()
        .into_iter()
        .filter(|l| l.selected)
        .map(|l| l.label)
        .collect();
    assert_eq!(picked, ["Ungesehen", "2010\u{2013}2019", "Deutsch"]);

    // The next visit of the same place starts narrowed; another place does not.
    let again = vm(&net, &kv, spec(Some("filme"), None));
    assert_eq!(again.pill_text(), first.pill_text());
    let status = again.status();
    assert_eq!(status.years, Some(YearSpan::decade(2010)));
    assert_eq!(status.language.as_deref(), Some("deu"));
    assert_eq!(
        vm(&net, &kv, spec(Some("serien"), None)).pill_text(),
        "Alle"
    );

    // "All years" and "all languages" lift the narrowing again, the status stays.
    first.pick(FilterChoice::Years(None));
    first.pick(FilterChoice::Language(None));
    wait_for("lifted", || {
        first.grid().total == expected(false, false, true) && ready(&first)
    });
    assert_eq!(first.pill_text(), "Ungesehen");
}
