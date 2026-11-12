//! `ClientConfig::lean_tiles`: the tile requests ask for what the tiles show and nothing more;
//! with the switch off (the Swift goldens) nothing changes.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use futures_executor::block_on;
use swiftly_jellyfin::{ClientConfig, ItemsQuery, JellyfinClient, ServerKind, Session};
use swiftly_net::MockTransport;

const BASE: &str = "https://tv.example.de";

fn client(lean: bool) -> JellyfinClient<MockTransport> {
    let config = ClientConfig::new("dev", "Test", "1.0").lean_tiles(lean);
    let c = JellyfinClient::new(MockTransport::new(), BASE, config).expect("client");
    c.set_session(Some(Session {
        access_token: "T".into(),
        user_id: "u1".into(),
        user_name: "t".into(),
        server_url: BASE.into(),
        kind: ServerKind::Jellyfin,
    }));
    c
}

fn url(c: &JellyfinClient<MockTransport>) -> String {
    c.transport()
        .last_request()
        .expect("request")
        .url
        .to_string()
}

#[test]
fn lean_rows_drop_description_and_extra_pictures() {
    let c = client(true);
    block_on(c.resume_items(20)).expect("ok");
    assert_eq!(
        url(&c),
        "https://tv.example.de/UserItems/Resume?userId=u1&Limit=20&Fields=PrimaryImageAspectRatio,ProviderIds&MediaTypes=Video&ImageTypeLimit=1&EnableTotalRecordCount=false"
    );
    block_on(c.next_up(20)).expect("ok");
    assert_eq!(
        url(&c),
        "https://tv.example.de/Shows/NextUp?userId=u1&Limit=20&Fields=PrimaryImageAspectRatio,ProviderIds&EnableImageTypes=Primary&ImageTypeLimit=1&EnableTotalRecordCount=false"
    );
    block_on(c.newly_joined(None, 20, false, "Movie,Episode")).expect("ok");
    assert!(url(&c).contains("Fields=PrimaryImageAspectRatio,ProviderIds&EnableImageTypes=Primary&ImageTypeLimit=1&EnableTotalRecordCount=false"));
    block_on(c.items(&ItemsQuery::default())).expect("ok");
    let u = url(&c);
    assert!(
        u.contains("Fields=PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,ChildCount")
    );
    assert!(u.ends_with("&EnableImageTypes=Primary&ImageTypeLimit=1"));
    assert!(!u.contains("Overview"));
}

#[test]
fn off_keeps_the_swift_requests() {
    let c = client(false);
    block_on(c.next_up(20)).expect("ok");
    assert_eq!(
        url(&c),
        "https://tv.example.de/Shows/NextUp?userId=u1&Limit=20&Fields=Overview,PrimaryImageAspectRatio,ProviderIds"
    );
}
