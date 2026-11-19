#![allow(clippy::expect_used, clippy::unwrap_used)]
//! A show with two seasons and no episode (`leafCount` 0) stays out of every Plex list while "Leere Serien ausblenden"
//! is on, and shows again when it is off. The switch is process-wide: one test body in this file.
mod common;

use std::sync::Arc;

use common::*;
use futures_executor::block_on;
use swiftly_library::library_filter::{LibraryFilter, Sorting};
use swiftly_model::switches;
use swiftly_plex::*;
use url::Url;

/// A full show, a show whose seasons exist but hold no episode, a show without a stated count, and a film.
const METADATA: &str = r#"[
  {"ratingKey":"1","type":"show","title":"Full","leafCount":24,"childCount":2},
  {"ratingKey":"2","type":"show","title":"Two seasons, no episodes","leafCount":0,"childCount":2},
  {"ratingKey":"3","type":"show","title":"Count not sent"},
  {"ratingKey":"4","type":"movie","title":"Film"}
]"#;

fn client() -> PlexClient<Stub> {
    let page = format!(r#"{{"MediaContainer":{{"size":4,"totalSize":4,"Metadata":{METADATA}}}}}"#);
    let hubs = format!(
        r#"{{"MediaContainer":{{"Hub":[{{"type":"show","title":"Shows","Metadata":{METADATA}}}]}}}}"#
    );
    let stub = Stub::new(move |r| {
        if r.url.path().starts_with("/hubs/search") {
            (200, hubs.clone())
        } else {
            (200, page.clone())
        }
    });
    PlexClient::new(
        Url::parse("http://stub.test:32400").expect("url"),
        "TOK",
        identity(),
        Arc::clone(&stub),
    )
}

fn names(items: &[swiftly_model::Item]) -> Vec<&str> {
    items.iter().map(|i| i.name.as_str()).collect()
}

#[test]
fn lists_and_search_drop_the_show_without_episodes_unless_the_switch_is_off() {
    let c = client();

    switches::set_hide_empty_series(true);
    let page = block_on(c.list(
        "1",
        Some("Series"),
        Sorting::Name,
        LibraryFilter::All,
        None,
        0,
        50,
    ))
    .expect("list");
    assert_eq!(names(&page.items), ["Full", "Count not sent", "Film"]);
    assert_eq!(page.total, 4, "paging counts the server's entries");
    let shelf = block_on(c.recently_added(Some("1"), 20)).expect("recently added");
    assert_eq!(names(&shelf), ["Full", "Count not sent", "Film"]);
    let found = block_on(c.search("show", 20)).expect("search");
    assert_eq!(names(&found), ["Full", "Count not sent", "Film"]);

    switches::set_hide_empty_series(false);
    let page = block_on(c.list(
        "1",
        Some("Series"),
        Sorting::Name,
        LibraryFilter::All,
        None,
        0,
        50,
    ))
    .expect("list");
    assert_eq!(page.items.len(), 4);
    let found = block_on(c.search("show", 20)).expect("search");
    assert_eq!(found.len(), 4);
    switches::set_hide_empty_series(true);
}
