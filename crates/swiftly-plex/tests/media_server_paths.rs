#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Behaviour of the Plex `MediaServer` / `HomePageSource` binding (`media_server.rs`) against a
//! scripted server: which requests go out, what comes back, and which error kind each failure
//! (HTTP status, malformed body, empty answer, dropped connection) turns into.
mod common;

use std::sync::{Arc, Mutex};

use common::*;
use futures_executor::block_on;
use swiftly_jellyfin::{ItemsQuery, PendingReport, ServerKind, TrackIndices};
use swiftly_library::ShelfSource;
use swiftly_library::home::HomePageSource;
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport, Method};
use swiftly_playback::device_profile::DeviceProfile;
use swiftly_playback::media_server::MediaServer;
use swiftly_plex::*;
use swiftly_rules::download_quality::DownloadQuality;
use url::Url;

fn client_for<T: HttpTransport + 'static>(t: &Arc<T>) -> PlexClient<T> {
    PlexClient::new(
        Url::parse("http://stub.test:32400").unwrap(),
        "TOK",
        identity(),
        Arc::clone(t),
    )
}

fn mc(inner: &str) -> String {
    format!(r#"{{"MediaContainer":{inner}}}"#)
}

fn row(key: &str, type_: &str, title: &str, extra: &str) -> String {
    format!(r#"{{"ratingKey":"{key}","type":"{type_}","title":"{title}"{extra}}}"#)
}

fn list(rows: &[String], total: Option<i64>) -> String {
    let total = total
        .map(|t| format!(r#","totalSize":{t}"#))
        .unwrap_or_default();
    mc(&format!(
        r#"{{"size":{}{total},"Metadata":[{}]}}"#,
        rows.len(),
        rows.join(",")
    ))
}

fn dirs(rows: &[(&str, &str)]) -> String {
    let d: Vec<String> = rows
        .iter()
        .map(|(k, t)| format!(r#"{{"key":"{k}","title":"{t}"}}"#))
        .collect();
    mc(&format!(
        r#"{{"size":{},"Directory":[{}]}}"#,
        d.len(),
        d.join(",")
    ))
}

/// The healthy server. Library 1 holds films, library 2 series, library 3 music.
fn world(r: &HttpRequest) -> (u16, String) {
    let q = r.url.query().unwrap_or("");
    match r.url.path() {
        "/identity" => (
            200,
            mc(r#"{"machineIdentifier":"M1","version":"1.40.0","claimed":true}"#),
        ),
        "/library/sections" => (200, SECTIONS.into()),
        "/library/sections/1/all" => (
            200,
            list(
                &[
                    row("10", "movie", "Alpha", ""),
                    row("11", "movie", "Beta", ""),
                ],
                Some(2),
            ),
        ),
        "/library/sections/2/all" => (200, list(&[row("20", "show", "Gamma", "")], Some(1))),
        "/library/sections/1/genre" => (200, dirs(&[("5", "Action"), ("6", "drama")])),
        "/library/sections/2/genre" => (200, dirs(&[("7", "Action"), ("8", "Comedy")])),
        "/library/sections/1/recentlyAdded" => (
            200,
            list(
                &[
                    row("10", "movie", "Alpha", r#","addedAt":300"#),
                    row("11", "movie", "Beta", r#","addedAt":100"#),
                    row("12", "show", "Stray", r#","addedAt":999"#),
                ],
                None,
            ),
        ),
        "/library/sections/2/recentlyAdded" => (
            200,
            list(
                &[
                    row("30", "episode", "E1", r#","addedAt":200"#),
                    row("31", "episode", "E2", r#","addedAt":50"#),
                    row("32", "season", "S1", r#","addedAt":900"#),
                ],
                None,
            ),
        ),
        "/library/sections/1/collections" => {
            (200, list(&[row("C9", "collection", "Coll", "")], None))
        }
        "/library/sections/2/collections" => (200, list(&[], None)),
        "/library/collections/C9/children" => (
            200,
            list(
                &[
                    row("10", "movie", "Alpha", ""),
                    row("20", "show", "Gamma", ""),
                ],
                None,
            ),
        ),
        "/library/metadata/1" => (200, MOVIE.into()),
        "/library/metadata/5" => (200, EPISODE.into()),
        "/library/metadata/2" => (200, list(&[row("2", "show", "Serie", "")], None)),
        "/library/metadata/C9" => (200, list(&[row("C9", "collection", "Coll", "")], None)),
        "/library/metadata/2/children" => (
            200,
            list(
                &[
                    row("40", "season", "S1", ""),
                    row("41", "season", "S2", ""),
                    row("42", "movie", "Odd", ""),
                ],
                None,
            ),
        ),
        "/library/metadata/2/allLeaves" => (
            200,
            list(
                &[
                    row("50", "episode", "A", r#","viewCount":1"#),
                    row("51", "episode", "B", r#","viewCount":2"#),
                    row("52", "episode", "C", ""),
                    row("53", "episode", "D", ""),
                ],
                None,
            ),
        ),
        "/library/metadata/3/allLeaves" => (
            200,
            list(
                &[row("60", "episode", "X", ""), row("61", "episode", "Y", "")],
                None,
            ),
        ),
        "/library/metadata/4/allLeaves" => (
            200,
            list(
                &[
                    row("70", "episode", "X", r#","viewCount":1"#),
                    row("71", "episode", "Y", r#","viewCount":1"#),
                ],
                None,
            ),
        ),
        "/library/metadata/40/children" => (
            200,
            list(
                &[
                    row("80", "episode", "S1E1", ""),
                    row("81", "episode", "S1E2", ""),
                ],
                None,
            ),
        ),
        "/library/metadata/1/similar" => (
            200,
            list(
                &[
                    row("1", "movie", "Self", ""),
                    row("10", "movie", "Alpha", ""),
                ],
                None,
            ),
        ),
        "/library/metadata/1/extras" => (
            200,
            list(
                &[row(
                    "51",
                    "clip",
                    "Making of",
                    r#","subtype":"behindTheScenes","Media":[{"id":6,"Part":[{"id":51,"key":"/library/parts/51/1/file.mp4"}]}]"#,
                )],
                None,
            ),
        ),
        "/hubs/continueWatching/items" => (
            200,
            list(
                &[row(
                    "5",
                    "episode",
                    "Pilot",
                    r#","viewOffset":1000,"duration":60000"#,
                )],
                None,
            ),
        ),
        "/library/onDeck" => (200, list(&[row("6", "episode", "Next", "")], None)),
        "/hubs/search" => (
            200,
            mc(&format!(
                r#"{{"Hub":[{{"title":"Movies","type":"movie","Metadata":[{},{}]}},{{"title":"Mixed","Metadata":[{},{}]}}]}}"#,
                row("10", "movie", "Alpha", ""),
                row("77", "track", "Song", ""),
                row("10", "movie", "Alpha", ""),
                row("5", "episode", "Pilot", ""),
            )),
        ),
        "/playlists" => (
            200,
            list(
                &[
                    row("P1", "playlist", "Evening", ""),
                    row("P2", "playlist", "Empty", ""),
                ],
                None,
            ),
        ),
        "/playlists/P1/items" => (
            200,
            list(
                &[
                    row("10", "movie", "Alpha", ""),
                    row("77", "track", "Song", ""),
                ],
                None,
            ),
        ),
        "/playlists/P2/items" => (200, list(&[], None)),
        "/:/timeline"
        | "/:/scrobble"
        | "/:/unscrobble"
        | "/:/rate"
        | "/actions/removeFromContinueWatching"
        | "/library/metadata/1/refresh" => {
            let _ = q;
            (200, String::new())
        }
        _ => (404, String::new()),
    }
}

fn healthy() -> (PlexClient<Stub>, Arc<Stub>) {
    let stub = Stub::new(world);
    (client_for(&stub), stub)
}

/// The healthy server with some paths answered differently first.
fn tweaked(
    over: impl Fn(&HttpRequest) -> Option<(u16, String)> + Send + Sync + 'static,
) -> (PlexClient<Stub>, Arc<Stub>) {
    let stub = Stub::new(move |r| over(r).unwrap_or_else(|| world(r)));
    (client_for(&stub), stub)
}

fn ids(items: &[Item]) -> Vec<&str> {
    items.iter().map(|i| i.id.as_str()).collect()
}

fn paths(stub: &Stub) -> Vec<String> {
    stub.requests()
        .iter()
        .map(|r| r.url.path().to_string())
        .collect()
}

fn query_has(r: &HttpRequest, key: &str, value: &str) -> bool {
    r.url.query_pairs().any(|(k, v)| k == key && v == value)
}

fn http(status: u16) -> ErrorKind {
    ErrorKind::Http {
        status,
        body: Some(String::new()),
    }
}

fn is_http(e: &ErrorKind, status: u16) -> bool {
    matches!(e, ErrorKind::Http { status: s, .. } if *s == status)
}

// MARK: items_page

#[test]
fn ids_are_fetched_in_one_request_per_hundred() {
    let (c, stub) = tweaked(|r| {
        r.url.path().starts_with("/library/metadata/").then(|| {
            let ids = r.url.path().trim_start_matches("/library/metadata/");
            let rows: Vec<String> = ids.split(',').map(|k| row(k, "movie", "T", "")).collect();
            (200, list(&rows, None))
        })
    });
    let wanted: Vec<String> = (0..150).map(|i| i.to_string()).collect();
    let page = block_on(MediaServer::items(
        &c,
        &ItemsQuery {
            ids: wanted.clone(),
            ..ItemsQuery::default()
        },
    ))
    .expect("page");
    assert_eq!(page.items.len(), 150);
    assert_eq!(page.total_record_count, 150);
    assert_eq!(page.items[0].id, "0");
    assert_eq!(page.items[149].id, "149");
    let seen = paths(&stub);
    assert_eq!(seen.len(), 2, "100 + 50");
    assert!(seen[0].ends_with(&wanted[..100].join(",")));
}

#[test]
fn library_page_turns_jellyfin_words_into_plex_filters() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        sort_by: "ProductionYear,SortName".into(),
        sort_order: "Descending".into(),
        filters: vec!["IsResumable".into(), "IsFavorite".into()],
        is_watched: Some(false),
        person_ids: vec!["a".into(), "b".into()],
        start_index: 20,
        limit: 10,
        include_item_types: vec!["Movie".into()],
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &q)).expect("page");
    assert_eq!(ids(&page.items), ["10", "11"]);
    assert_eq!(page.total_record_count, 2);
    let r = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/all")
        .expect("asked");
    assert!(query_has(&r, "sort", "year:desc,titleSort:desc"));
    assert!(query_has(&r, "inProgress", "1"));
    assert!(query_has(&r, "userRating>>", "9"));
    assert!(query_has(&r, "unwatched", "1"));
    assert!(query_has(&r, "actor", "a,b"));
    assert!(query_has(&r, "type", "1"));
    assert_eq!(header(&r, "X-Plex-Container-Start").as_deref(), Some("20"));
    assert_eq!(header(&r, "X-Plex-Container-Size").as_deref(), Some("10"));
}

#[test]
fn watched_true_asks_for_not_unwatched() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        is_watched: Some(true),
        ..ItemsQuery::default()
    };
    block_on(MediaServer::items(&c, &q)).expect("page");
    let r = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path().ends_with("/all"))
        .unwrap();
    assert!(query_has(&r, "unwatched", "0"));
    assert!(query_has(&r, "sort", "titleSort:asc"));
}

#[test]
fn sort_expression_maps_every_known_field() {
    let s = PlexClient::<Stub>::sort_expression;
    assert_eq!(s("DateCreated", "Ascending"), "addedAt:asc");
    assert_eq!(s("DateLastContentAdded", "descending"), "addedAt:desc");
    assert_eq!(s("CommunityRating", "Descending"), "audienceRating:desc");
    assert_eq!(s("PremiereDate", "Ascending"), "originallyAvailableAt:asc");
    assert_eq!(s("Random", "Descending"), "random");
    assert_eq!(
        s("Whatever,,SortName", "Ascending"),
        "titleSort:asc,titleSort:asc"
    );
    assert_eq!(s("", "Ascending"), "");
}

#[test]
fn without_parent_only_film_and_series_libraries_are_asked() {
    let (c, stub) = healthy();
    let page = block_on(MediaServer::items(&c, &ItemsQuery::default())).expect("page");
    assert_eq!(page.total_record_count, 3);
    let seen = paths(&stub);
    assert!(seen.contains(&"/library/sections/1/all".to_string()));
    assert!(seen.contains(&"/library/sections/2/all".to_string()));
    assert!(!seen.contains(&"/library/sections/3/all".to_string()));
}

#[test]
fn a_kind_the_library_cannot_hold_skips_that_library() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        include_item_types: vec!["Series".into()],
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &q)).expect("page");
    assert_eq!(ids(&page.items), ["20"]);
    let all: Vec<HttpRequest> = stub
        .requests()
        .into_iter()
        .filter(|r| r.url.path().ends_with("/all"))
        .collect();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].url.path(), "/library/sections/2/all");
    assert!(query_has(&all[0], "type", "2"));
}

#[test]
fn two_kinds_for_two_libraries_each_get_their_own_type() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        include_item_types: vec!["Movie".into(), "Series".into()],
        ..ItemsQuery::default()
    };
    block_on(MediaServer::items(&c, &q)).expect("page");
    let one = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/all")
        .unwrap();
    let two = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/2/all")
        .unwrap();
    assert!(query_has(&one, "type", "1"));
    assert!(query_has(&two, "type", "2"));
}

#[test]
fn unknown_item_kinds_do_not_filter() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        include_item_types: vec!["Folder".into()],
        ..ItemsQuery::default()
    };
    block_on(MediaServer::items(&c, &q)).expect("page");
    let r = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path().ends_with("/all"))
        .unwrap();
    assert!(!r.url.query_pairs().any(|(k, _)| k == "type"));
}

#[test]
fn genre_names_match_case_insensitively_and_unknown_ones_give_nothing() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        genres: vec!["DRAMA".into(), "action".into()],
        ..ItemsQuery::default()
    };
    block_on(MediaServer::items(&c, &q)).expect("page");
    let r = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/all")
        .unwrap();
    assert!(query_has(&r, "genre", "6,5"));

    let before = stub.requests().len();
    let none = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        genres: vec!["Western".into()],
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &none)).expect("page");
    assert!(page.items.is_empty());
    assert_eq!(page.total_record_count, 0);
    let after: Vec<String> = stub.requests()[before..]
        .iter()
        .map(|r| r.url.path().to_string())
        .collect();
    assert!(!after.contains(&"/library/sections/1/all".to_string()));
}

#[test]
fn genre_lookup_failure_is_an_error() {
    let (c, _) = tweaked(|r| r.url.path().ends_with("/genre").then(|| (500, "x".into())));
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        genres: vec!["Action".into()],
        ..ItemsQuery::default()
    };
    let err = block_on(MediaServer::items(&c, &q)).expect_err("fails");
    assert!(is_http(&err, 500), "{err:?}");
}

#[test]
fn single_library_total_falls_back_to_size_without_total_size() {
    let (c, _) = tweaked(|r| {
        (r.url.path() == "/library/sections/1/all")
            .then(|| (200, list(&[row("1", "movie", "A", "")], None)))
    });
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &q)).expect("page");
    assert_eq!(page.total_record_count, 1);
}

#[test]
fn a_series_id_without_recursion_lists_its_children_sliced() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        parent_id: Some("2".into()),
        recursive: false,
        include_item_types: vec!["Season".into()],
        start_index: 1,
        limit: 5,
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &q)).expect("page");
    // "Odd" (a movie) is not a season; the page starts after the first season.
    assert_eq!(ids(&page.items), ["41"]);
    assert_eq!(page.total_record_count, 2);
    // The kind of the id is remembered: a second page needs no new look-up.
    block_on(MediaServer::items(&c, &q)).expect("again");
    let lookups = paths(&stub)
        .iter()
        .filter(|p| *p == "/library/metadata/2")
        .count();
    assert_eq!(lookups, 1);
}

#[test]
fn a_collection_id_lists_its_members() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        parent_id: Some("C9".into()),
        include_item_types: vec!["Movie".into()],
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &q)).expect("page");
    assert_eq!(ids(&page.items), ["10"]);
    assert!(paths(&stub).contains(&"/library/collections/C9/children".to_string()));
}

#[test]
fn an_id_the_server_does_not_know_is_taken_for_a_collection() {
    let (c, stub) = tweaked(|r| match r.url.path() {
        "/library/metadata/99" => Some((500, "boom".into())),
        "/library/collections/99/children" => {
            Some((200, list(&[row("10", "movie", "A", "")], None)))
        }
        _ => None,
    });
    let q = ItemsQuery {
        parent_id: Some("99".into()),
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &q)).expect("page");
    assert_eq!(ids(&page.items), ["10"]);
    // A failed look-up is not remembered.
    block_on(MediaServer::items(&c, &q)).expect("again");
    let lookups = paths(&stub)
        .iter()
        .filter(|p| *p == "/library/metadata/99")
        .count();
    assert_eq!(lookups, 2);
}

#[test]
fn a_library_number_whose_metadata_is_a_movie_stays_the_library() {
    let (c, stub) = healthy();
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: false,
        ..ItemsQuery::default()
    };
    let page = block_on(MediaServer::items(&c, &q)).expect("page");
    assert_eq!(ids(&page.items), ["10", "11"]);
    assert!(paths(&stub).contains(&"/library/sections/1/all".to_string()));
}

#[test]
fn errors_of_the_library_list_keep_their_kind() {
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        ..ItemsQuery::default()
    };
    let (c, _) =
        tweaked(|r| (r.url.path() == "/library/sections/1/all").then(|| (503, "down".into())));
    let err = block_on(MediaServer::items(&c, &q)).expect_err("503");
    assert!(is_http(&err, 503), "{err:?}");

    let (c, _) = tweaked(|r| (r.url.path() == "/library/sections").then(|| (401, String::new())));
    assert_eq!(
        block_on(MediaServer::items(&c, &q)).expect_err("401"),
        ErrorKind::NotAuthenticated
    );

    let (c, _) = tweaked(|r| {
        (r.url.path() == "/library/sections/1/all").then(|| (200, "<html>nope</html>".into()))
    });
    assert!(matches!(
        block_on(MediaServer::items(&c, &q)).expect_err("bad body"),
        ErrorKind::Decoding(_)
    ));

    let (c, _) =
        tweaked(|r| (r.url.path() == "/library/sections/1/all").then(|| (200, String::new())));
    assert!(matches!(
        block_on(MediaServer::items(&c, &q)).expect_err("empty body"),
        ErrorKind::Decoding(_)
    ));
}

#[test]
fn a_failing_library_fails_the_merged_page() {
    let (c, _) =
        tweaked(|r| (r.url.path() == "/library/sections/2/all").then(|| (500, "x".into())));
    let err = block_on(MediaServer::items(&c, &ItemsQuery::default())).expect_err("fails");
    assert!(is_http(&err, 500), "{err:?}");
}

// MARK: home page

#[test]
fn shelves_come_from_their_plex_routes() {
    let (c, stub) = healthy();
    let resume = block_on(HomePageSource::resume_items(&c, 12)).expect("resume");
    assert_eq!(ids(&resume), ["5"]);
    let deck = block_on(HomePageSource::next_up(&c, 7)).expect("deck");
    assert_eq!(ids(&deck), ["6"]);
    let r = stub.requests();
    assert_eq!(
        header(&r[0], "X-Plex-Container-Size").as_deref(),
        Some("12")
    );
    assert_eq!(r[0].url.path(), "/hubs/continueWatching/items");
    assert_eq!(header(&r[1], "X-Plex-Container-Size").as_deref(), Some("7"));
    assert!(HomePageSource::merges_libraries(&c));
}

#[test]
fn shelf_failures_are_error_kinds_or_none() {
    let (c, _) = tweaked(|r| match r.url.path() {
        "/hubs/continueWatching/items" => Some((500, "x".into())),
        "/library/onDeck" => Some((401, String::new())),
        "/library/sections" => Some((502, String::new())),
        _ => None,
    });
    assert!(is_http(
        &block_on(HomePageSource::resume_items(&c, 5)).unwrap_err(),
        500
    ));
    assert_eq!(
        block_on(HomePageSource::next_up(&c, 5)).unwrap_err(),
        ErrorKind::NotAuthenticated
    );
    assert!(block_on(HomePageSource::libraries(&c)).is_none());
    assert!(block_on(HomePageSource::last_added(&c, None, 10, 5)).is_none());
    assert!(block_on(HomePageSource::new_series(&c, None, 5)).is_none());
}

#[test]
fn libraries_are_the_film_and_series_libraries() {
    let (c, _) = healthy();
    let views = block_on(HomePageSource::libraries(&c)).expect("views");
    assert_eq!(ids(&views), ["1", "2"]);
}

#[test]
fn last_added_weaves_films_and_episodes_by_date() {
    let (c, stub) = healthy();
    let found = block_on(HomePageSource::last_added(&c, None, 20, 10)).expect("rows");
    // The stray show in the film library and the season in the series library are dropped.
    assert_eq!(ids(&found), ["10", "30", "11", "31"]);
    let film_ask = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/recentlyAdded")
        .unwrap();
    assert!(query_has(&film_ask, "type", "1"));
    assert_eq!(
        header(&film_ask, "X-Plex-Container-Size").as_deref(),
        Some("20")
    );
    let ep_ask = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/2/recentlyAdded")
        .unwrap();
    assert!(query_has(&ep_ask, "type", "4"));
}

#[test]
fn last_added_is_cut_to_the_shown_count_and_one_library() {
    let (c, stub) = healthy();
    let found = block_on(HomePageSource::last_added(&c, Some("1"), 50, 1)).expect("rows");
    assert_eq!(ids(&found), ["10"]);
    // The fetch size is capped at twice the shown count.
    let ask = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/recentlyAdded")
        .unwrap();
    assert_eq!(header(&ask, "X-Plex-Container-Size").as_deref(), Some("2"));
    assert!(!paths(&stub).contains(&"/library/sections/2/recentlyAdded".to_string()));
}

#[test]
fn new_arrivals_skip_kinds_plex_has_no_number_for() {
    let (c, stub) = healthy();
    let found = block_on(HomePageSource::new_arrivals(&c, "Movie,Folder,", 20, 10)).expect("rows");
    assert_eq!(ids(&found), ["10", "11"]);
    assert!(!paths(&stub).contains(&"/library/sections/2/recentlyAdded".to_string()));
}

#[test]
fn a_failing_recently_added_list_gives_none() {
    let (c, _) = tweaked(|r| {
        (r.url.path() == "/library/sections/2/recentlyAdded").then(|| (500, "x".into()))
    });
    assert!(block_on(HomePageSource::last_added(&c, None, 20, 10)).is_none());
}

#[test]
fn new_series_and_latest_title_use_the_newest_of_a_library() {
    let (c, stub) = tweaked(|r| match r.url.path() {
        "/library/sections/2/all" => Some((
            200,
            list(
                &[
                    // The server answers newest first (`sort=addedAt:desc`).
                    row("21", "show", "Delta", r#","addedAt":20"#),
                    row("20", "show", "Gamma", r#","addedAt":10"#),
                ],
                None,
            ),
        )),
        _ => None,
    });
    let series = block_on(HomePageSource::new_series(&c, None, 5)).expect("series");
    assert_eq!(ids(&series), ["21", "20"]);
    let ask = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/2/all")
        .unwrap();
    assert!(query_has(&ask, "sort", "addedAt:desc"));

    let one = block_on(HomePageSource::latest_title(&c, "2", false, 1)).expect("newest");
    assert_eq!(ids(&one), ["21"]);
    let by_key = block_on(HomePageSource::new_series(&c, Some("99"), 5)).expect("empty");
    assert!(by_key.is_empty(), "no such library");
}

#[test]
fn latest_title_of_a_collection_is_its_first_members() {
    let (c, _) = healthy();
    let members = block_on(HomePageSource::latest_title(&c, "C9", true, 1)).expect("members");
    assert_eq!(ids(&members), ["10"]);
    let (down, _) = tweaked(|r| {
        r.url
            .path()
            .contains("collections")
            .then(|| (500, "x".into()))
    });
    assert!(block_on(HomePageSource::latest_title(&down, "C9", true, 1)).is_none());
}

#[test]
fn title_by_genre_and_person_report_the_total() {
    let (c, stub) = healthy();
    let genre = block_on(HomePageSource::title(&c, "Action", 10)).expect("genre");
    assert_eq!(ids(&genre), ["10", "11", "20"]);
    let by_genre = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/all")
        .unwrap();
    assert!(query_has(&by_genre, "genre", "5"));
    assert!(query_has(&by_genre, "sort", "addedAt:desc"));

    let (items, total) =
        block_on(MediaServer::title_with_number_person(&c, "55", 10, 0)).expect("person");
    assert_eq!(total, 3);
    assert_eq!(items.len(), 3);
    let (items, total) =
        block_on(MediaServer::title_with_number_genre(&c, "Action", 10, 0)).expect("genre");
    assert_eq!((items.len(), total), (3, 3));

    let (down, _) = tweaked(|r| r.url.path().ends_with("/all").then(|| (500, "x".into())));
    assert!(block_on(MediaServer::title_with_number_person(&down, "55", 10, 0)).is_none());
    assert!(block_on(HomePageSource::title(&down, "Action", 10)).is_none());
}

#[test]
fn the_log_sink_gets_lines_from_the_source() {
    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = Arc::clone(&lines);
    let stub = Stub::new(world);
    let c = client_for(&stub).with_log(Arc::new(move |l| sink.lock().unwrap().push(l.to_string())));
    HomePageSource::log(&c, "hello");
    assert_eq!(*lines.lock().unwrap(), ["hello"]);
}

// MARK: server identity and session

#[test]
fn system_info_reads_the_identity() {
    let (c, stub) = healthy();
    let info = block_on(MediaServer::public_system_info(&c)).expect("info");
    assert_eq!(info.id.as_deref(), Some("M1"));
    assert_eq!(info.version.as_deref(), Some("1.40.0"));
    assert_eq!(info.server_name, None);
    assert_eq!(info.product_name, None);
    let again = block_on(MediaServer::check_reachability(&c)).expect("info");
    assert_eq!(again.id.as_deref(), Some("M1"));
    assert!(paths(&stub).iter().all(|p| p == "/identity"));
    assert_eq!(MediaServer::kind(&c), ServerKind::Plex);
    assert_eq!(MediaServer::base_url(&c), "http://stub.test:32400/");
    assert!(block_on(MediaServer::current_session(&c)).is_none());
}

#[test]
fn identity_without_machine_or_with_errors_fails_by_kind() {
    let (c, _) = tweaked(|r| (r.url.path() == "/identity").then(|| (200, mc(r#"{"size":0}"#))));
    assert!(matches!(
        block_on(MediaServer::public_system_info(&c)).unwrap_err(),
        ErrorKind::Decoding(_)
    ));
    let (c, _) = tweaked(|r| (r.url.path() == "/identity").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::check_reachability(&c)).unwrap_err(),
        500
    ));
}

#[test]
fn the_token_check_signs_out_only_for_401() {
    let (ok, _) = healthy();
    assert!(block_on(MediaServer::session_applies_still(&ok)));
    let (rejected, _) = tweaked(|_| Some((401, String::new())));
    assert!(!block_on(MediaServer::session_applies_still(&rejected)));
    let (broken, _) = tweaked(|_| Some((500, String::new())));
    assert!(block_on(MediaServer::session_applies_still(&broken)));
}

#[test]
fn sign_in_with_a_password_is_unsupported() {
    let (c, stub) = healthy();
    let err = block_on(MediaServer::authenticate(&c, "u", "p")).unwrap_err();
    assert_eq!(PlexError::from_kind(err), PlexError::Unsupported);
    assert!(stub.requests().is_empty());
}

// MARK: lists

#[test]
fn genres_are_unique_and_sorted_without_regard_to_case() {
    let (c, stub) = healthy();
    let names = block_on(MediaServer::genres(&c)).expect("genres");
    assert_eq!(names, ["Action", "Comedy", "drama"]);
    assert!(!paths(&stub).contains(&"/library/sections/3/genre".to_string()));
    let (down, _) =
        tweaked(|r| (r.url.path() == "/library/sections/2/genre").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::genres(&down)).unwrap_err(),
        500
    ));
    let (none, _) =
        tweaked(|r| (r.url.path() == "/library/sections").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::genres(&none)).unwrap_err(),
        500
    ));
}

#[test]
fn search_keeps_films_series_and_episodes_once() {
    let (c, stub) = healthy();
    let found = block_on(MediaServer::search(&c, "  alp ", 8)).expect("found");
    assert_eq!(ids(&found), ["10", "5"]);
    let r = &stub.requests()[0];
    assert_eq!(r.url.path(), "/hubs/search");
    assert!(query_has(r, "query", "alp"));
    assert!(query_has(r, "limit", "8"));
    // A blank term asks nothing.
    let before = stub.requests().len();
    assert!(
        block_on(MediaServer::search(&c, "   ", 8))
            .expect("empty")
            .is_empty()
    );
    assert_eq!(stub.requests().len(), before);
    let (down, _) = tweaked(|r| (r.url.path() == "/hubs/search").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::search(&down, "a", 1)).unwrap_err(),
        500
    ));
}

#[test]
fn playlists_keep_only_video_entries() {
    let (c, stub) = healthy();
    let dir = block_on(MediaServer::playlist_directory(&c)).expect("directory");
    assert_eq!(dir.all.len(), 2);
    assert_eq!(dir.all[0].item.id, "P1");
    assert_eq!(dir.all[0].movies, 1);
    assert_eq!(dir.all[1].movies + dir.all[1].episodes, 0);
    assert_eq!(
        stub.requests()[0]
            .url
            .query_pairs()
            .find(|(k, _)| k == "playlistType")
            .map(|(_, v)| v.to_string()),
        Some("video".into())
    );
    let entries = block_on(MediaServer::playlist_entries(&c, "P1", true)).expect("entries");
    assert_eq!(ids(&entries), ["10"]);
}

#[test]
fn playlist_failures_surface() {
    let (c, _) = tweaked(|r| (r.url.path() == "/playlists/P1/items").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::playlist_directory(&c)).unwrap_err(),
        500
    ));
    assert!(is_http(
        &block_on(MediaServer::playlist_entries(&c, "P1", false)).unwrap_err(),
        500
    ));
    let (c, _) = tweaked(|r| (r.url.path() == "/playlists").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::playlist_directory(&c)).unwrap_err(),
        500
    ));
}

#[test]
fn collections_are_listed_per_library_with_their_members() {
    let (c, stub) = healthy();
    let dir = block_on(MediaServer::collection_directory(&c, &[])).expect("directory");
    assert_eq!(dir.all.len(), 1);
    assert_eq!(dir.all[0].item.id, "C9");
    assert!(dir.all[0].movies.contains("10"));
    assert!(dir.all[0].series_list.contains("20"));
    assert!(!paths(&stub).contains(&"/library/sections/3/collections".to_string()));

    // Restricted to the series library, the film library's collection is not asked for.
    let (c2, stub2) = healthy();
    let views = vec![Item::new("2", "Serien", Some("CollectionFolder"))];
    let dir = block_on(MediaServer::collection_directory(&c2, &views)).expect("directory");
    assert!(dir.all.is_empty());
    assert!(!paths(&stub2).contains(&"/library/sections/1/collections".to_string()));
}

#[test]
fn collection_failures_surface() {
    let (c, _) = tweaked(|r| {
        (r.url.path() == "/library/collections/C9/children").then(|| (500, String::new()))
    });
    assert!(is_http(
        &block_on(MediaServer::collection_directory(&c, &[])).unwrap_err(),
        500
    ));
    let (c, _) = tweaked(|r| {
        (r.url.path() == "/library/sections/1/collections").then(|| (500, String::new()))
    });
    assert!(is_http(
        &block_on(MediaServer::collection_directory(&c, &[])).unwrap_err(),
        500
    ));
    let (c, _) = tweaked(|r| (r.url.path() == "/library/sections").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::collection_directory(&c, &[])).unwrap_err(),
        500
    ));
}

#[test]
fn title_filter_gathers_the_chosen_libraries() {
    let (c, stub) = healthy();
    let source = ShelfSource::new(None, None, false, &["1", "2"]);
    let filter = block_on(MediaServer::title_filter(
        &c,
        &source,
        &["IsResumable".into()],
        Some(false),
    ))
    .expect("filter");
    assert_eq!(filter.total, 3);
    let ask = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/all")
        .unwrap();
    assert!(query_has(&ask, "inProgress", "1"));
    assert!(query_has(&ask, "unwatched", "1"));
    assert_eq!(
        header(&ask, "X-Plex-Container-Size").as_deref(),
        Some("100000")
    );

    let (down, _) =
        tweaked(|r| (r.url.path() == "/library/sections/2/all").then(|| (500, String::new())));
    assert!(is_http(
        &block_on(MediaServer::title_filter(&down, &source, &[], None)).unwrap_err(),
        500
    ));
}

#[test]
fn the_watchlist_is_the_favourite_rating() {
    let (c, stub) = healthy();
    let page = block_on(MediaServer::remembered_items(
        &c,
        &["Movie".into()],
        "DateCreated",
        "Descending",
        0,
        20,
    ))
    .expect("page");
    assert_eq!(ids(&page.items), ["10", "11"]);
    assert!(
        stub.requests()
            .iter()
            .any(|r| query_has(r, "userRating>>", "9") && query_has(r, "sort", "addedAt:desc"))
    );
    let (down, _) = tweaked(|r| r.url.path().ends_with("/all").then(|| (500, String::new())));
    assert!(
        block_on(MediaServer::remembered_items(
            &down,
            &[],
            "SortName",
            "Ascending",
            0,
            5
        ))
        .is_err()
    );
}

#[test]
fn natural_order_lists_fetch_the_page_by_id() {
    let (c, stub) = healthy();
    let collator = swiftly_rules::natural_order::NaturalCollator::new("en").expect("collator");
    let q = ItemsQuery {
        parent_id: Some("1".into()),
        recursive: true,
        ..ItemsQuery::default()
    };
    let all = block_on(c.natural_list(&q, &collator)).expect("list");
    assert_eq!(ids(&all), ["10", "11"]);
    let ask = stub
        .requests()
        .into_iter()
        .find(|r| r.url.path() == "/library/sections/1/all")
        .unwrap();
    assert_eq!(
        header(&ask, "X-Plex-Container-Size").as_deref(),
        Some("100000")
    );

    let (c2, stub2) = tweaked(|r| {
        r.url.path().starts_with("/library/metadata/").then(|| {
            let keys = r.url.path().trim_start_matches("/library/metadata/");
            let rows: Vec<String> = keys
                .split(',')
                .rev()
                .map(|k| row(k, "movie", "T", ""))
                .collect();
            (200, list(&rows, None))
        })
    });
    let page = block_on(c2.natural_page(&all, 1, 5)).expect("page");
    assert_eq!(ids(&page.items), ["11"]);
    assert_eq!(page.total_record_count, 2);
    assert_eq!(stub2.requests().len(), 1);
    let empty = block_on(c2.natural_page(&all, 9, 5)).expect("empty");
    assert!(empty.items.is_empty());
    assert_eq!(empty.total_record_count, 2);
    assert_eq!(stub2.requests().len(), 1, "an empty slice asks nothing");
}

// MARK: titles

#[test]
fn a_title_and_its_neighbours() {
    let (c, _) = healthy();
    assert_eq!(
        block_on(MediaServer::item(&c, "1")).unwrap().name,
        "Testfilm"
    );
    let similar = block_on(MediaServer::similar(&c, "1", 5)).expect("similar");
    assert_eq!(
        ids(&similar),
        ["10"],
        "the title itself is not its own neighbour"
    );
    assert!(is_http(
        &block_on(MediaServer::item(&c, "404")).unwrap_err(),
        404
    ));
    let empty =
        tweaked(|r| (r.url.path() == "/library/metadata/1").then(|| (200, list(&[], None)))).0;
    assert_eq!(
        block_on(MediaServer::item(&empty, "1")).unwrap_err(),
        ErrorKind::NoPlayableSource
    );
    assert!(block_on(MediaServer::similar(&healthy().0, "9", 3)).is_err());
}

#[test]
fn extras_and_trailers_fail_with_the_server_status() {
    let (c, _) = tweaked(|r| {
        r.url
            .path()
            .ends_with("/extras")
            .then(|| (500, String::new()))
    });
    assert!(is_http(
        &block_on(MediaServer::extras(&c, "1")).unwrap_err(),
        500
    ));
    assert!(is_http(
        &block_on(MediaServer::trailer(&c, "1")).unwrap_err(),
        500
    ));
    let (ok, _) = healthy();
    assert!(block_on(MediaServer::trailer(&ok, "1")).unwrap().is_empty());
    assert_eq!(
        ids(&block_on(MediaServer::extras(&ok, "1")).unwrap()),
        ["51"]
    );
}

#[test]
fn seasons_and_episodes() {
    let (c, stub) = healthy();
    let seasons = block_on(MediaServer::seasons(&c, "2")).expect("seasons");
    assert_eq!(ids(&seasons), ["40", "41", "42"]);
    let all = block_on(MediaServer::episodes(&c, "2", None)).expect("all");
    assert_eq!(ids(&all), ["50", "51", "52", "53"]);
    let season = block_on(MediaServer::episodes(&c, "2", Some("40"))).expect("season");
    assert_eq!(ids(&season), ["80", "81"]);
    assert!(paths(&stub).contains(&"/library/metadata/40/children".to_string()));
    assert!(is_http(
        &block_on(MediaServer::seasons(&c, "999")).unwrap_err(),
        404
    ));
    assert!(is_http(
        &block_on(MediaServer::episodes(&c, "999", None)).unwrap_err(),
        404
    ));
}

#[test]
fn next_episode_is_the_one_after_the_last_watched() {
    let (c, _) = healthy();
    let next = block_on(MediaServer::next_episode_series(&c, "2"))
        .expect("ok")
        .expect("some");
    assert_eq!(next.id, "52");
    // Nothing watched: nothing to continue.
    assert!(
        block_on(MediaServer::next_episode_series(&c, "3"))
            .unwrap()
            .is_none()
    );
    // Everything watched: finished.
    assert!(
        block_on(MediaServer::next_episode_series(&c, "4"))
            .unwrap()
            .is_none()
    );
    assert!(is_http(
        &block_on(MediaServer::next_episode_series(&c, "999")).unwrap_err(),
        404
    ));
}

#[test]
fn episode_after_an_episode() {
    let (c, _) = healthy();
    let post = block_on(MediaServer::episode_post(&c, "50", "2"))
        .unwrap()
        .expect("some");
    assert_eq!(post.id, "51");
    assert!(
        block_on(MediaServer::episode_post(&c, "53", "2"))
            .unwrap()
            .is_none(),
        "last one"
    );
    assert!(
        block_on(MediaServer::episode_post(&c, "zzz", "2"))
            .unwrap()
            .is_none(),
        "unknown one"
    );
    assert!(block_on(MediaServer::episode_post(&c, "50", "999")).is_err());
}

#[test]
fn state_in_series_prefers_the_next_then_the_first_episode() {
    let (c, _) = healthy();
    assert_eq!(
        block_on(MediaServer::state_in_series(&c, "2")).unwrap().id,
        "52"
    );
    assert_eq!(
        block_on(MediaServer::state_in_series(&c, "3")).unwrap().id,
        "60"
    );
    // All watched: the checked variant falls back to the first episode too.
    assert_eq!(
        block_on(MediaServer::state_in_series_checked(&c, "4"))
            .unwrap()
            .unwrap()
            .id,
        "70"
    );
    assert!(block_on(MediaServer::state_in_series(&c, "999")).is_none());
    assert!(is_http(
        &block_on(MediaServer::state_in_series_checked(&c, "999")).unwrap_err(),
        404
    ));
    let (empty, _) = tweaked(|r| {
        (r.url.path() == "/library/metadata/8/allLeaves").then(|| (200, list(&[], None)))
    });
    assert!(
        block_on(MediaServer::state_in_series_checked(&empty, "8"))
            .unwrap()
            .is_none()
    );
}

// MARK: marks and commands

fn only_request(stub: &Stub, path: &str) -> HttpRequest {
    let hits: Vec<HttpRequest> = stub
        .requests()
        .into_iter()
        .filter(|r| r.url.path() == path)
        .collect();
    assert_eq!(hits.len(), 1, "{path}");
    hits.into_iter().next().unwrap()
}

#[test]
fn watched_marks_are_put_requests() {
    let (c, stub) = healthy();
    block_on(MediaServer::set_watched(&c, "7", true)).expect("played");
    block_on(MediaServer::set_watched(&c, "7", false)).expect("unplayed");
    let on = only_request(&stub, "/:/scrobble");
    assert_eq!(on.method, Method::Put);
    assert!(query_has(&on, "key", "7"));
    assert!(query_has(&on, "identifier", "com.plexapp.plugins.library"));
    let off = only_request(&stub, "/:/unscrobble");
    assert_eq!(off.method, Method::Put);
    assert!(query_has(&off, "key", "7"));
    assert_eq!(header(&on, "X-Plex-Token").as_deref(), Some("TOK"));
}

#[test]
fn favourites_are_ratings_of_ten_or_removed() {
    let (c, stub) = healthy();
    block_on(MediaServer::set_watchlist(&c, "7", true)).expect("on");
    block_on(MediaServer::set_watchlist(&c, "7", false)).expect("off");
    let rates: Vec<HttpRequest> = stub
        .requests()
        .into_iter()
        .filter(|r| r.url.path() == "/:/rate")
        .collect();
    assert_eq!(rates.len(), 2);
    assert!(query_has(&rates[0], "rating", "10"));
    assert!(query_has(&rates[1], "rating", "-1"));
    assert!(
        rates
            .iter()
            .all(|r| r.method == Method::Put && query_has(r, "key", "7"))
    );
}

#[test]
fn refresh_and_take_back_are_put_requests() {
    let (c, stub) = healthy();
    block_on(MediaServer::metadata_refresh(&c, "1")).expect("refresh");
    block_on(MediaServer::point_back_set(&c, "1")).expect("removed");
    assert_eq!(
        only_request(&stub, "/library/metadata/1/refresh").method,
        Method::Put
    );
    let back = only_request(&stub, "/actions/removeFromContinueWatching");
    assert_eq!(back.method, Method::Put);
    assert!(query_has(&back, "ratingKey", "1"));
}

#[test]
fn commands_fail_with_the_status_the_server_gave() {
    let (c, _) = tweaked(|_| Some((500, "boom".into())));
    for result in [
        block_on(MediaServer::metadata_refresh(&c, "1")),
        block_on(MediaServer::point_back_set(&c, "1")),
        block_on(MediaServer::set_watched(&c, "1", true)),
        block_on(MediaServer::set_watchlist(&c, "1", true)),
    ] {
        match result.unwrap_err() {
            ErrorKind::Http { status: 500, body } => assert_eq!(body.as_deref(), Some("boom")),
            other => panic!("{other:?}"),
        }
    }
    let (c, _) = tweaked(|_| Some((401, String::new())));
    assert_eq!(
        block_on(MediaServer::set_watched(&c, "1", false)).unwrap_err(),
        ErrorKind::NotAuthenticated
    );
}

// MARK: pictures and playback

#[test]
fn poster_addresses_are_scaled_by_the_server() {
    let (c, _) = healthy();
    let item = block_on(MediaServer::item(&c, "1")).unwrap();
    let url = block_on(MediaServer::image_url(&c, &item, 300)).expect("address");
    let url = Url::parse(&url).unwrap();
    assert_eq!(url.path(), "/photo/:/transcode");
    assert!(url.query_pairs().any(|(k, v)| k == "height" && v == "300"));
    assert!(
        url.query_pairs()
            .any(|(k, v)| k == "url" && v == "/library/metadata/1/thumb/17")
    );
    assert!(
        url.query_pairs()
            .any(|(k, v)| k == "X-Plex-Token" && v == "TOK")
    );
    let bare = Item::new("x", "No picture", Some("Movie"));
    assert!(block_on(MediaServer::image_url(&c, &bare, 300)).is_none());
}

#[test]
fn a_plan_can_choose_the_version_and_reports_the_duration() {
    let (c, stub) = healthy();
    let profile = DeviceProfile::vlc(40_000_000);
    let plan = block_on(MediaServer::playback_plan(
        &c,
        "1",
        &profile,
        None,
        None,
        Some("2"),
    ))
    .unwrap()
    .unwrap();
    assert!(plan.url.contains("/library/parts/2/"), "{}", plan.url);
    block_on(MediaServer::report_progress(
        &c,
        "1",
        &plan,
        100_000_000,
        true,
        TrackIndices::default(),
    ))
    .unwrap();
    let t = only_request(&stub, "/:/timeline");
    assert_eq!(t.method, Method::Post);
    assert!(query_has(&t, "state", "paused"));
    assert!(query_has(&t, "time", "10000"));
    assert!(query_has(&t, "ratingKey", "1"));
    assert!(t.url.query_pairs().any(|(k, _)| k == "duration"));
}

#[test]
fn plan_failures_keep_their_kind() {
    let profile = DeviceProfile::vlc(40_000_000);
    let (c, _) = healthy();
    assert!(is_http(
        &block_on(MediaServer::playback_plan(
            &c, "404", &profile, None, None, None
        ))
        .unwrap_err(),
        404
    ));
    // A title without any file cannot be played.
    let err = block_on(MediaServer::playback_plan(
        &c, "2", &profile, None, None, None,
    ))
    .unwrap_err();
    assert!(err != ErrorKind::NotAuthenticated, "{err:?}");
    let (bad, _) = tweaked(|r| (r.url.path() == "/library/metadata/1").then(|| (200, "{".into())));
    assert!(matches!(
        block_on(MediaServer::playback_plan(
            &bad, "1", &profile, None, None, None
        ))
        .unwrap_err(),
        ErrorKind::Decoding(_)
    ));
}

#[test]
fn download_address_is_the_original_file() {
    let (c, _) = healthy();
    let url = block_on(MediaServer::download_url(
        &c,
        "1",
        None,
        DownloadQuality::Original,
        None,
    ))
    .unwrap();
    let url = Url::parse(&url).unwrap();
    assert_eq!(url.path(), "/library/parts/1/1793487178/file.mkv");
    assert!(url.query_pairs().any(|(k, v)| k == "download" && v == "1"));
    assert!(
        url.query_pairs()
            .any(|(k, v)| k == "X-Plex-Token" && v == "TOK")
    );
    let second = block_on(MediaServer::download_url(
        &c,
        "1",
        Some("2"),
        DownloadQuality::Original,
        Some(3),
    ))
    .unwrap();
    assert!(second.contains("/library/parts/2/"), "{second}");
}

#[test]
fn download_without_a_file_is_a_no_file_error() {
    let (c, _) = tweaked(|r| {
        (r.url.path() == "/library/metadata/9")
            .then(|| (200, list(&[row("9", "movie", "Bare", "")], None)))
    });
    let err = block_on(MediaServer::download_url(
        &c,
        "9",
        None,
        DownloadQuality::Original,
        None,
    ))
    .unwrap_err();
    assert_eq!(PlexError::from_kind(err), PlexError::NoFile);
    let err = block_on(MediaServer::download_url(
        &c,
        "404",
        None,
        DownloadQuality::Original,
        None,
    ))
    .unwrap_err();
    assert!(is_http(&err, 404));
}

#[test]
fn skip_segments_and_chapters_come_from_the_detail() {
    let (c, _) = healthy();
    let segments = block_on(MediaServer::sections(&c, "1"));
    assert!(!segments.is_empty());
    assert_eq!(
        block_on(MediaServer::segments_to_store(&c, "1"))
            .unwrap()
            .len(),
        segments.len()
    );
    let chapters = block_on(MediaServer::chapter(&c, "1", None));
    assert_eq!(chapters.len(), 2);
    // A failing detail is an empty list for the player, but "unknown" for the cache.
    assert!(block_on(MediaServer::sections(&c, "404")).is_empty());
    assert!(block_on(MediaServer::segments_to_store(&c, "404")).is_none());
    assert!(block_on(MediaServer::chapter(&c, "404", None)).is_empty());
}

// MARK: preview pictures (binary answers)

fn jpeg(tag: u8) -> Vec<u8> {
    vec![
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x24, 0x00, 0x40, 0x03, 0x01, 0x22, 0x00,
        0x02, 0x11, 0x01, 0x03, 0x11, 0x01, tag, 0xFF, 0xD9,
    ]
}

fn bif(frames: &[Vec<u8>]) -> Vec<u8> {
    let mut out = vec![0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A];
    out.extend(0u32.to_le_bytes());
    out.extend((frames.len() as u32).to_le_bytes());
    out.extend(1000u32.to_le_bytes());
    out.resize(64, 0);
    let mut offset = 64 + (frames.len() as u32 + 1) * 8;
    let mut table = Vec::new();
    for (i, f) in frames.iter().enumerate() {
        table.extend((i as u32 * 10).to_le_bytes());
        table.extend(offset.to_le_bytes());
        offset += f.len() as u32;
    }
    table.extend(u32::MAX.to_le_bytes());
    table.extend(offset.to_le_bytes());
    out.extend(table);
    for f in frames {
        out.extend(f);
    }
    out
}

/// A transport that can answer bytes.
struct Bytes {
    index: Mutex<Option<(u16, Vec<u8>)>>,
    seen: Mutex<Vec<HttpRequest>>,
}

impl Bytes {
    fn new(index: Option<(u16, Vec<u8>)>) -> Arc<Self> {
        Arc::new(Self {
            index: Mutex::new(index),
            seen: Mutex::new(Vec::new()),
        })
    }
    fn asked(&self, path: &str) -> usize {
        self.seen
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.url.path() == path)
            .count()
    }
}

impl HttpTransport for Bytes {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        self.seen.lock().unwrap().push(request.clone());
        Ok(match request.url.path() {
            "/library/metadata/1" => HttpResponse::new(200, MOVIE),
            "/library/metadata/5" => HttpResponse::new(200, EPISODE),
            "/library/parts/1/indexes/sd" => match self.index.lock().unwrap().clone() {
                Some((status, body)) => HttpResponse::new(status, body),
                None => return Err(ErrorKind::Cancelled),
            },
            _ => HttpResponse::new(404, ""),
        })
    }
}

#[test]
fn preview_pictures_are_single_images_with_a_fixed_step() {
    let t = Bytes::new(Some((200, bif(&[jpeg(1), jpeg(2), jpeg(3)]))));
    let c = client_for(&t);
    let tp = block_on(MediaServer::trickplay(&c, "1", None, 320)).expect("trickplay");
    assert_eq!((tp.width, tp.height), (64, 36));
    assert_eq!((tp.tiles_wide, tp.tiles_up), (1, 1));
    assert_eq!(tp.count, 3);
    assert_eq!(tp.interval, 10_000);
    let sheet = block_on(MediaServer::trickplay_sheet(&c, "1", None, 320, 2)).expect("sheet");
    assert_eq!(sheet, jpeg(3));
    assert!(block_on(MediaServer::trickplay_sheet(&c, "1", None, 320, 3)).is_none());
    assert!(block_on(MediaServer::trickplay_sheet(&c, "1", None, 320, -1)).is_none());
    assert_eq!(
        t.asked("/library/parts/1/indexes/sd"),
        1,
        "the file is fetched once"
    );
    let r = t
        .seen
        .lock()
        .unwrap()
        .iter()
        .find(|r| r.url.path().contains("indexes"))
        .cloned()
        .unwrap();
    assert_eq!(header(&r, "Accept").as_deref(), Some("*/*"));
    assert!(
        r.url
            .query_pairs()
            .any(|(k, v)| k == "X-Plex-Token" && v == "TOK")
    );
}

#[test]
fn a_single_picture_has_no_step_and_so_no_trickplay() {
    let c = client_for(&Bytes::new(Some((200, bif(&[jpeg(1)])))));
    assert!(block_on(MediaServer::trickplay(&c, "1", None, 320)).is_none());
    assert_eq!(
        block_on(MediaServer::trickplay_sheet(&c, "1", None, 320, 0)),
        Some(jpeg(1))
    );
}

#[test]
fn pictures_that_are_no_jpeg_have_no_size() {
    let c = client_for(&Bytes::new(Some((
        200,
        bif(&[vec![1, 2, 3, 4, 5, 6], vec![7, 8, 9, 10, 11]]),
    ))));
    assert!(block_on(MediaServer::trickplay(&c, "1", None, 320)).is_none());
}

#[test]
fn missing_broken_or_failing_previews_are_none() {
    // The server made none: 404, remembered.
    let t = Bytes::new(Some((404, Vec::new())));
    let c = client_for(&t);
    assert!(block_on(MediaServer::trickplay(&c, "1", None, 320)).is_none());
    assert!(block_on(MediaServer::trickplay_sheet(&c, "1", None, 320, 0)).is_none());
    assert_eq!(t.asked("/library/parts/1/indexes/sd"), 1);
    // A half file.
    let half = bif(&[jpeg(1), jpeg(2)]);
    let c = client_for(&Bytes::new(Some((200, half[..70].to_vec()))));
    assert!(block_on(MediaServer::trickplay(&c, "1", None, 320)).is_none());
    // A server error is not remembered as "none".
    let t = Bytes::new(Some((500, Vec::new())));
    let c = client_for(&t);
    assert!(block_on(MediaServer::trickplay(&c, "1", None, 320)).is_none());
    assert!(block_on(c.previews("1", None)).is_err());
    // Cancelled while fetching.
    let c = client_for(&Bytes::new(None));
    assert_eq!(
        block_on(c.previews("1", None)).unwrap_err(),
        PlexError::Request(ErrorKind::Cancelled)
    );
    assert!(block_on(MediaServer::trickplay(&c, "1", None, 320)).is_none());
    // A title whose file has no preview index asks for nothing.
    let t = Bytes::new(Some((200, bif(&[jpeg(1), jpeg(2)]))));
    let c = client_for(&t);
    assert!(block_on(c.previews("5", None)).unwrap().is_none());
    assert_eq!(t.asked("/library/parts/3/indexes/sd"), 0);
}

// MARK: reports

#[test]
fn reports_name_their_state_and_fail_with_the_status() {
    let (c, stub) = healthy();
    let plan = block_on(MediaServer::playback_plan(
        &c,
        "1",
        &DeviceProfile::vlc(1),
        None,
        None,
        None,
    ))
    .unwrap()
    .unwrap();
    block_on(MediaServer::report_start(
        &c,
        "1",
        &plan,
        0,
        TrackIndices::default(),
    ))
    .unwrap();
    block_on(MediaServer::report_progress(
        &c,
        "1",
        &plan,
        50_000_000,
        false,
        TrackIndices::default(),
    ))
    .unwrap();
    block_on(MediaServer::report_stopped(&c, "1", &plan, 60_000_000)).unwrap();
    let states: Vec<String> = stub
        .requests()
        .into_iter()
        .filter(|r| r.url.path() == "/:/timeline")
        .map(|r| {
            let state = r
                .url
                .query_pairs()
                .find(|(k, _)| k == "state")
                .unwrap()
                .1
                .to_string();
            let time = r
                .url
                .query_pairs()
                .find(|(k, _)| k == "time")
                .unwrap()
                .1
                .to_string();
            format!("{state}@{time}")
        })
        .collect();
    assert_eq!(states, ["playing@0", "playing@5000", "stopped@6000"]);

    let (down, _) = tweaked(|r| (r.url.path() == "/:/timeline").then(|| (500, "x".into())));
    assert!(is_http(
        &block_on(MediaServer::report_start(
            &down,
            "1",
            &plan,
            0,
            TrackIndices::default()
        ))
        .unwrap_err(),
        500
    ));
    assert!(is_http(
        &block_on(MediaServer::report_progress(
            &down,
            "1",
            &plan,
            0,
            true,
            TrackIndices::default()
        ))
        .unwrap_err(),
        500
    ));
    assert!(is_http(
        &block_on(MediaServer::report_stopped(&down, "1", &plan, 0)).unwrap_err(),
        500
    ));
}

fn pending(item: &str, ticks: i64, moment: f64) -> PendingReport {
    PendingReport::new(item, "acct", ticks, moment)
}

fn future() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
        + 60.0
}

#[test]
fn a_late_report_older_than_the_servers_last_play_is_dropped_but_settled() {
    let (c, stub) = healthy();
    let old = pending("1", 100_000_000, 1.0);
    let done = block_on(MediaServer::report_later(&c, std::slice::from_ref(&old)));
    assert_eq!(done, [old.id()]);
    assert!(
        !paths(&stub).contains(&"/:/timeline".to_string()),
        "nothing is sent"
    );
}

#[test]
fn a_late_report_sends_a_stopped_timeline_and_logs_it() {
    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = Arc::clone(&lines);
    let stub = Stub::new(world);
    let c = client_for(&stub).with_log(Arc::new(move |l| sink.lock().unwrap().push(l.to_string())));
    let report = pending("1", 300_000_000, future());
    let done = block_on(MediaServer::report_later(&c, std::slice::from_ref(&report)));
    assert_eq!(done, [report.id()]);
    let t = only_request(&stub, "/:/timeline");
    assert!(query_has(&t, "state", "stopped"));
    assert!(query_has(&t, "time", "30000"));
    assert!(query_has(&t, "duration", "90023"));
    let log = lines.lock().unwrap().join("\n");
    assert!(log.contains("Nachmeldung 1 30 s"), "{log}");
}

#[test]
fn a_title_that_is_gone_is_settled_and_the_rest_goes_on() {
    let (c, stub) = healthy();
    let gone = pending("404", 1, future());
    let live = pending("1", 10_000_000, future());
    let done = block_on(MediaServer::report_later(&c, &[gone.clone(), live.clone()]));
    assert_eq!(done, [gone.id(), live.id()]);
    assert_eq!(
        stub.requests()
            .iter()
            .filter(|r| r.url.path() == "/:/timeline")
            .count(),
        1
    );
}

#[test]
fn a_timeline_404_settles_the_report_too() {
    let (c, _) = tweaked(|r| (r.url.path() == "/:/timeline").then(|| (404, String::new())));
    let report = pending("1", 1, future());
    assert_eq!(
        block_on(MediaServer::report_later(&c, std::slice::from_ref(&report))),
        [report.id()]
    );
}

#[test]
fn the_first_real_failure_stops_the_batch_and_keeps_the_rest() {
    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = Arc::clone(&lines);
    let stub = Stub::new(|r| {
        if r.url.path() == "/:/timeline" {
            (500, "x".into())
        } else {
            world(r)
        }
    });
    let c = client_for(&stub).with_log(Arc::new(move |l| sink.lock().unwrap().push(l.to_string())));
    let (a, b) = (pending("1", 1, future()), pending("1", 2, future()));
    assert!(block_on(MediaServer::report_later(&c, &[a, b])).is_empty());
    assert_eq!(
        stub.requests()
            .iter()
            .filter(|r| r.url.path() == "/:/timeline")
            .count(),
        1
    );
    assert!(lines.lock().unwrap()[0].contains("gescheitert"));

    // The detail failing is the same: nothing settled, the batch stops.
    let stub = Stub::new(|r| {
        if r.url.path() == "/library/metadata/1" {
            (500, "x".into())
        } else {
            world(r)
        }
    });
    let c = client_for(&stub);
    let reports = [pending("1", 1, future()), pending("404", 1, future())];
    assert!(block_on(MediaServer::report_later(&c, &reports)).is_empty());
    assert_eq!(stub.requests().len(), 1);
}

#[test]
fn shelf_helpers_are_reachable_without_traits() {
    // `sort_expression` is public API; the rest of the binding is covered above.
    assert_eq!(
        PlexClient::<Stub>::sort_expression("ProductionYear", "Descending"),
        "year:desc"
    );
    let _ = http(500);
}
