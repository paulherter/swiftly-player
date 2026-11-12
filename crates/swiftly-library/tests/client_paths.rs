//! The loader and the client extensions against a transport that never touches a network
//! (the mock-transport counterpart of `HomePageLoaderTests`, `NaturalPageTests`,
//! `CollectionDirectory` and `PlaylistDirectory` fetches).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::future::Future;
use std::sync::Mutex;

use futures_executor::block_on;
use swiftly_jellyfin::{ClientConfig, JellyfinClient, ServerKind, Session};
use swiftly_library::client_ext::{
    collection_directory, natural_page, playlist_directory, state_in_series_checked,
};
use swiftly_library::{HomeLoader, LoadRequest};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport, MockTransport};

const BASE: &str = "https://tv.example.de";

fn session() -> Session {
    Session {
        access_token: "TOKEN".into(),
        user_id: "u1".into(),
        user_name: "tester".into(),
        server_url: BASE.into(),
        kind: ServerKind::Jellyfin,
    }
}

fn client<T: HttpTransport>(transport: T) -> JellyfinClient<T> {
    let c = JellyfinClient::new(transport, BASE, ClientConfig::new("dev", "Test", "1.0"))
        .expect("client");
    c.set_session(Some(session()));
    c
}

fn items(json_items: &[&str]) -> String {
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{}}}"#,
        json_items.join(","),
        json_items.len()
    )
}

fn ids(v: &[Item]) -> Vec<&str> {
    v.iter().map(|i| i.id.as_str()).collect()
}

/// Answers by what the request asks for; records every request.
struct Routed<F> {
    answer: F,
    seen: Mutex<Vec<HttpRequest>>,
}

impl<F: Fn(&HttpRequest) -> String + Send + Sync> Routed<F> {
    fn new(answer: F) -> Self {
        Self {
            answer,
            seen: Mutex::new(Vec::new()),
        }
    }
}

impl<F: Fn(&HttpRequest) -> String + Send + Sync> HttpTransport for Routed<F> {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let body = (self.answer)(&request);
        self.seen.lock().expect("lock").push(request);
        async move { Ok(HttpResponse::new(200, body)) }
    }
}

fn param(r: &HttpRequest, name: &str) -> Option<String> {
    r.url
        .query_pairs()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.into_owned())
}

#[test]
fn home_loads_through_the_client() {
    let mock = MockTransport::new()
        .route(
            "UserItems/Resume",
            200,
            &items(&[r#"{"Id":"a","Name":"A","Type":"Movie"}"#]),
        )
        .route(
            "Shows/NextUp",
            200,
            &items(&[
                r#"{"Id":"a","Name":"A","Type":"Movie"}"#,
                r#"{"Id":"b","Name":"B","Type":"Movie"}"#,
            ]),
        )
        .route(
            "Items",
            200,
            &items(&[
                r#"{"Id":"f1","Name":"F1","Type":"Movie"}"#,
                r#"{"Id":"f2","Name":"F2","Type":"Movie"}"#,
            ]),
        );
    let c = client(mock);
    let home = block_on(HomeLoader::load(&c, &LoadRequest::new(false)));
    assert_eq!(
        ids(home.continue_watching.as_deref().unwrap_or_default()),
        ["a"]
    );
    // What is in continue watching is missing from next up.
    assert_eq!(ids(home.next_episode.as_deref().unwrap_or_default()), ["b"]);
    // Newly joined (slim) then the full entries by id, in the slim order.
    assert_eq!(
        ids(home.recent.as_deref().unwrap_or_default()),
        ["f1", "f2"]
    );
    assert!(!home.disrupted);
    let paths: Vec<String> = c
        .transport()
        .requests()
        .iter()
        .map(|r| r.url.path().to_string())
        .collect();
    assert!(paths.iter().any(|p| p.ends_with("UserItems/Resume")));
    assert!(paths.iter().any(|p| p.ends_with("Shows/NextUp")));
    let by_ids = c
        .transport()
        .requests()
        .into_iter()
        .find(|r| param(r, "Ids").is_some())
        .expect("ids fetch");
    assert_eq!(param(&by_ids, "Ids").as_deref(), Some("f1,f2"));
}

#[test]
fn failed_fetches_are_none_and_disrupted() {
    let mock = MockTransport::new()
        .route("UserItems/Resume", 500, "")
        .route("Shows/NextUp", 500, "")
        .route("Items", 500, "");
    let c = client(mock);
    let home = block_on(HomeLoader::load(&c, &LoadRequest::new(false)));
    assert!(
        home.continue_watching.is_none() && home.next_episode.is_none() && home.recent.is_none()
    );
    assert!(home.disrupted);
}

#[test]
fn one_work_in_two_libraries_stays_in_the_first_library() {
    // The same TMDb id under two ids; a2 lives in the second library, b1 in the first.
    let body = items(&[
        r#"{"Id":"a2","Name":"Film","Type":"Movie","ProviderIds":{"Tmdb":"7"}}"#,
        r#"{"Id":"b1","Name":"Film","Type":"Movie","ProviderIds":{"Tmdb":"7"}}"#,
        r#"{"Id":"c","Name":"Other","Type":"Movie","ProviderIds":{"Tmdb":"8"}}"#,
    ]);
    let views = items(&[
        r#"{"Id":"L1","Name":"Eins","CollectionType":"movies"}"#,
        r#"{"Id":"L2","Name":"Zwei","CollectionType":"movies"}"#,
    ]);
    let mock = MockTransport::new()
        .route("UserItems/Resume", 200, &body)
        .route("Shows/NextUp", 200, &items(&[]))
        .route("UserViews", 200, &views)
        .route("Items/a2/Ancestors", 200, r#"[{"Id":"L2","Name":"Zwei"}]"#)
        .route("Items/b1/Ancestors", 200, r#"[{"Id":"L1","Name":"Eins"}]"#)
        .route("Items", 200, &items(&[]));
    let c = client(mock);
    let home = block_on(HomeLoader::load(&c, &LoadRequest::new(false)));
    // b1 wins (first library), at the position of the first occurrence of the work.
    assert_eq!(
        ids(home.continue_watching.as_deref().unwrap_or_default()),
        ["b1", "c"]
    );
}

#[test]
fn split_rows_fall_back_with_the_mock() {
    // No library of the kind and nothing new: the rows are empty, not missing.
    let mock = MockTransport::new()
        .route("UserItems/Resume", 200, &items(&[]))
        .route("Shows/NextUp", 200, &items(&[]))
        .route("UserViews", 200, &items(&[r#"{"Id":"m","Name":"Medien"}"#]))
        .route("Items", 200, &items(&[]));
    let c = client(mock);
    let home = block_on(HomeLoader::load(&c, &LoadRequest::new(true)));
    assert_eq!(home.new_movies.as_ref().map(Vec::len), Some(0));
    assert_eq!(home.new_series.as_ref().map(Vec::len), Some(0));
    // The series row asks for series first (DateLastContentAdded).
    assert!(
        c.transport()
            .requests()
            .iter()
            .any(
                |r| param(r, "SortBy").as_deref() == Some("DateLastContentAdded")
                    && param(r, "IncludeItemTypes").as_deref() == Some("Series")
            )
    );
}

/// Answers every `Ids` request with the titles it asked for, in reverse order, and counts the ids.
fn spy() -> Routed<impl Fn(&HttpRequest) -> String + Send + Sync> {
    Routed::new(|r| {
        let asked: Vec<String> = param(r, "Ids")
            .map(|v| v.split(',').map(String::from).collect())
            .unwrap_or_default();
        let json: Vec<String> = asked
            .iter()
            .rev()
            .map(|i| format!(r#"{{"Id":"{i}","Name":"{i}","Type":"Movie"}}"#))
            .collect();
        let refs: Vec<&str> = json.iter().map(String::as_str).collect();
        items(&refs)
    })
}

fn per_request(
    c: &JellyfinClient<impl HttpTransport>,
    t: &Routed<impl Fn(&HttpRequest) -> String + Send + Sync>,
) -> Vec<usize> {
    let _ = c;
    t.seen
        .lock()
        .expect("lock")
        .iter()
        .map(|r| param(r, "Ids").map_or(0, |v| v.split(',').count()))
        .collect()
}

#[test]
fn natural_page_in_batches_of_at_most_100_in_list_order() {
    let list: Vec<Item> = (0..250)
        .map(|i| Item::new(format!("t{i}"), format!("Titel {i}"), None))
        .collect();
    let c = client(spy());
    let page = block_on(natural_page(&c, &list, 0, 250)).expect("page");
    let mut sizes = c
        .transport()
        .seen
        .lock()
        .expect("lock")
        .iter()
        .map(|r| param(r, "Ids").map_or(0, |v| v.split(',').count()))
        .collect::<Vec<_>>();
    sizes.sort_unstable();
    assert_eq!(sizes, [50, 100, 100]);
    assert_eq!(ids(&page.items), ids(&list));
    assert_eq!(page.total_record_count, 250);
}

#[test]
fn natural_page_slice_and_empty_page_without_request() {
    let list: Vec<Item> = (0..30)
        .map(|i| Item::new(format!("t{i}"), format!("Titel {i}"), None))
        .collect();
    let c = client(spy());
    let page = block_on(natural_page(&c, &list, 20, 60)).expect("page");
    let want: Vec<String> = (20..30).map(|i| format!("t{i}")).collect();
    assert_eq!(
        page.items.iter().map(|i| i.id.clone()).collect::<Vec<_>>(),
        want
    );
    let empty = block_on(natural_page(&c, &list, 30, 60)).expect("page");
    assert!(empty.items.is_empty());
    assert_eq!(per_request(&c, c.transport()), [10]);
}

#[test]
fn collection_directory_fetches_all_members_in_a_window() {
    let t = Routed::new(|r| {
        if let Some(parent) = param(r, "ParentId") {
            // Members of collection `parent`: one movie that carries the collection's number.
            let n = parent.trim_start_matches('c');
            return items(&[
                &format!(r#"{{"Id":"m{n}a","Name":"x","Type":"Movie"}}"#),
                &format!(r#"{{"Id":"m{n}b","Name":"x","Type":"Movie"}}"#),
            ]);
        }
        let boxes: Vec<String> = (0..8)
            .map(|i| format!(r#"{{"Id":"c{i}","Name":"Box {i}","Type":"BoxSet"}}"#))
            .collect();
        let refs: Vec<&str> = boxes.iter().map(String::as_str).collect();
        items(&refs)
    });
    let c = client(t);
    let dir = block_on(collection_directory(&c, &[])).expect("directory");
    assert_eq!(dir.all.len(), 8);
    assert_eq!(dir.all[0].id(), "c0", "server order is kept");
    assert!(dir.all.iter().all(|c| c.movies.len() == 2));
    assert_eq!(dir.collections("movies").len(), 8);
    assert_eq!(c.transport().seen.lock().expect("lock").len(), 9);
}

#[test]
fn collection_directory_falls_back_to_the_boxsets_folder() {
    let t = Routed::new(|r| match param(r, "ParentId").as_deref() {
        Some("folder") => items(&[r#"{"Id":"c1","Name":"Box","Type":"BoxSet"}"#]),
        Some("c1") => items(&[
            r#"{"Id":"m1","Name":"x","Type":"Movie"}"#,
            r#"{"Id":"m2","Name":"x","Type":"Movie"}"#,
        ]),
        _ => items(&[]),
    });
    let c = client(t);
    let views = [Item {
        collection_type: Some("boxsets".into()),
        ..Item::new("folder", "Sammlungen", None)
    }];
    let dir = block_on(collection_directory(&c, &views)).expect("directory");
    assert_eq!(dir.all.len(), 1);
    assert_eq!(dir.collections("movies").len(), 1);
}

#[test]
fn playlist_directory_keeps_video_lists_and_video_entries() {
    let t = Routed::new(|r| {
        let path = r.url.path().to_string();
        if path.ends_with("Playlists/p1/Items") {
            return items(&[
                r#"{"Id":"m","Name":"x","Type":"Movie","MediaType":"Video"}"#,
                r#"{"Id":"s","Name":"x","Type":"Audio","MediaType":"Audio"}"#,
                r#"{"Id":"e","Name":"x","Type":"Episode","MediaType":"Video"}"#,
            ]);
        }
        items(&[
            r#"{"Id":"p1","Name":"Watchlist","Type":"Playlist","MediaType":"Video"}"#,
            r#"{"Id":"p2","Name":"Musik","Type":"Playlist","MediaType":"Audio"}"#,
        ])
    });
    let c = client(t);
    let dir = block_on(playlist_directory(&c)).expect("directory");
    assert_eq!(dir.all.len(), 1);
    assert_eq!((dir.all[0].movies, dir.all[0].episodes), (1, 1));
    assert_eq!(dir.playlists("movies").len(), 1);
}

#[test]
fn a_failing_member_query_fails_the_whole_directory() {
    // The box set is listed; its member call gets an answer that cannot be read.
    let t = Routed::new(|r| {
        if param(r, "ParentId").is_some() {
            "not json".into()
        } else {
            items(&[r#"{"Id":"c1","Name":"Box","Type":"BoxSet"}"#])
        }
    });
    let c = client(t);
    assert!(block_on(collection_directory(&c, &[])).is_err());
}

#[test]
fn state_in_series_checked_throws_on_a_failed_request() {
    let c = client(MockTransport::new().route("Shows/NextUp", 500, ""));
    assert!(block_on(state_in_series_checked(&c, "s1")).is_err());
}
