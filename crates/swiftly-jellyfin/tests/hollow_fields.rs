//! The list requests ask the server for what the core needs to hide an empty series (`ChildCount`, `RecursiveItemCount`),
//! and ask for it only while "Leere Serien ausblenden" is on. The switch is process-wide: one test body in this file.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use futures_executor::block_on;
use swiftly_jellyfin::{ClientConfig, ItemsQuery, JellyfinClient, ServerKind, Session};
use swiftly_model::switches;
use swiftly_net::MockTransport;

const BASE: &str = "https://tv.example.de";

/// A library page: a full series, one with two seasons and no episode at all (what a series manager leaves on disk),
/// one with only placeholder entries (the server counts none of them) and one that is only a placeholder itself.
const PAGE: &str = r#"{"Items":[
  {"Id":"full","Name":"Full","Type":"Series","ChildCount":2,"RecursiveItemCount":20},
  {"Id":"two-seasons-no-episodes","Name":"Hollow","Type":"Series","ChildCount":2,"RecursiveItemCount":0},
  {"Id":"virtual-only","Name":"Placeholder","Type":"Series","ChildCount":1,"RecursiveItemCount":3,"LocationType":"Virtual"},
  {"Id":"film","Name":"Film","Type":"Movie"}
],"TotalRecordCount":4}"#;

fn client() -> JellyfinClient<MockTransport> {
    let c = JellyfinClient::new(
        MockTransport::new()
            .route("Items", 200, PAGE)
            .route("Similar", 200, PAGE),
        BASE,
        ClientConfig::new("dev", "Test", "1.0"),
    )
    .expect("client");
    c.set_session(Some(Session {
        access_token: "T".into(),
        user_id: "u1".into(),
        user_name: "t".into(),
        server_url: BASE.into(),
        kind: ServerKind::Jellyfin,
    }));
    c
}

fn asked(c: &JellyfinClient<MockTransport>) -> String {
    c.transport()
        .last_request()
        .expect("request")
        .url
        .to_string()
}

fn ids(items: &[swiftly_model::Item]) -> Vec<&str> {
    items.iter().map(|i| i.id.as_str()).collect()
}

#[test]
fn every_series_list_asks_for_the_counts_while_the_switch_is_on_and_drops_the_empty_ones() {
    let c = client();
    let library = ItemsQuery {
        parent_id: Some("lib".into()),
        include_item_types: vec!["Series".into()],
        recursive: true,
        ..Default::default()
    };
    let slim = ItemsQuery {
        slim: true,
        ..library.clone()
    };

    switches::set_hide_empty_series(true);
    // Library (full, lean and the alphabet index), search, collection and "more like this" all ask and all drop.
    let page = block_on(c.items(&library)).expect("library");
    assert!(
        asked(&c).contains("ChildCount,RecursiveItemCount"),
        "{}",
        asked(&c)
    );
    assert_eq!(ids(&page.items), ["full", "film"]);
    assert_eq!(
        page.total_record_count, 4,
        "paging counts the server's entries"
    );
    block_on(c.items(&slim)).expect("slim");
    assert!(
        asked(&c).contains("Fields=SortName,DateCreated,ChildCount,RecursiveItemCount"),
        "{}",
        asked(&c)
    );
    let found = block_on(c.search("hollow", 20)).expect("search");
    assert!(
        asked(&c).contains("ChildCount,RecursiveItemCount"),
        "{}",
        asked(&c)
    );
    assert_eq!(ids(&found), ["full", "film"]);
    let members = block_on(c.collection_members("box")).expect("collection");
    assert!(
        asked(&c).ends_with("&Fields=ChildCount,RecursiveItemCount"),
        "{}",
        asked(&c)
    );
    assert_eq!(ids(&members), ["full", "film"]);
    let similar = block_on(c.similar("x", 5)).expect("similar");
    assert!(
        asked(&c).contains("Fields=ProviderIds,ChildCount,RecursiveItemCount"),
        "{}",
        asked(&c)
    );
    assert_eq!(ids(&similar), ["full", "film"]);

    // Switched off: no extra server work, and nothing is hidden.
    switches::set_hide_empty_series(false);
    let page = block_on(c.items(&library)).expect("library");
    assert!(!asked(&c).contains("RecursiveItemCount"), "{}", asked(&c));
    assert_eq!(
        ids(&page.items),
        ["full", "two-seasons-no-episodes", "virtual-only", "film"]
    );
    block_on(c.collection_members("box")).expect("collection");
    assert!(!asked(&c).contains("Fields="), "{}", asked(&c));
    switches::set_hide_empty_series(true);
}
