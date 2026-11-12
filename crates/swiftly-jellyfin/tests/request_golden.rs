//! Golden proof: for every call, the exact method, address, query string order and encoding,
//! headers and body, asserted against a mock transport. The expected values were derived from
//! `Packages/JellyfinKit/Sources/JellyfinKit/JellyfinClient.swift` (line numbers in the comments).
//! No network is touched.
#![allow(clippy::expect_used, clippy::unwrap_used)] // test helpers outside #[test] fns

use futures_executor::block_on;
use serde_json::{Value, json};
use swiftly_jellyfin::{
    ClientConfig, ItemsQuery, JellyfinClient, LoginCode, OwnHeader, OwnHeaders, PendingReport,
    PlayMethod, PostReportOutput, QuickConnectState, ReportPlan, ServerKind, Session, TrackIndices,
};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, Method, MockTransport, TransportReason};

const BASE: &str = "https://tv.example.de";
const AUTH: &str =
    r#"MediaBrowser Client="Swiftly Player", Device="Test", DeviceId="dev", Version="1.0""#;

fn fixture(name: &str) -> String {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn session(kind: ServerKind) -> Session {
    Session {
        access_token: "TOKEN".into(),
        user_id: "u1".into(),
        user_name: "tester".into(),
        server_url: BASE.into(),
        kind,
    }
}

fn client_with(
    mock: MockTransport,
    kind: ServerKind,
    signed_in: bool,
) -> JellyfinClient<MockTransport> {
    let config = ClientConfig::new("dev", "Test", "1.0").kind(kind);
    let c = JellyfinClient::new(mock, BASE, config).expect("client");
    if signed_in {
        c.set_session(Some(session(kind)));
    }
    c
}

fn jf(mock: MockTransport) -> JellyfinClient<MockTransport> {
    client_with(mock, ServerKind::Jellyfin, true)
}

fn last(c: &JellyfinClient<MockTransport>) -> HttpRequest {
    c.transport().last_request().expect("a request was sent")
}

/// A signed-in GET: method, address, `Authorization` with token, `Accept`, nothing else.
fn assert_get(r: &HttpRequest, url: &str) {
    assert_eq!(r.method, Method::Get);
    assert_eq!(r.url.as_str(), url);
    assert_eq!(
        r.header("Authorization"),
        Some(format!("{AUTH}, Token=\"TOKEN\"").as_str())
    );
    assert_eq!(r.header("Accept"), Some("application/json"));
    assert_eq!(r.header("Content-Type"), None);
    assert_eq!(r.body, None);
    assert_eq!(r.headers.len(), 2, "no other headers: {:?}", r.headers);
}

fn assert_json_post(r: &HttpRequest, url: &str, body: &Value) {
    assert_eq!(r.method, Method::Post);
    assert_eq!(r.url.as_str(), url);
    assert_eq!(r.header("Content-Type"), Some("application/json"));
    let sent: Value = serde_json::from_slice(r.body.as_deref().expect("body")).expect("json body");
    assert_eq!(&sent, body);
}

// ---- JellyfinClient.swift:379 ------------------------------------------------------------

#[test]
fn public_system_info_needs_no_session() {
    let mock = MockTransport::new().route(
        "System/Info/Public",
        200,
        r#"{"ServerName":"S","Version":"10.11.0","Id":"i"}"#,
    );
    let c = client_with(mock, ServerKind::Jellyfin, false);
    let info = block_on(c.public_system_info()).expect("info");
    assert_eq!(info.version.as_deref(), Some("10.11.0"));
    let r = last(&c);
    assert_eq!(r.method, Method::Get);
    assert_eq!(r.url.as_str(), "https://tv.example.de/System/Info/Public");
    assert_eq!(
        r.header("Authorization"),
        Some(AUTH),
        "no Token= before sign-in"
    );
}

// :386
#[test]
fn check_reachability_uses_the_short_deadline() {
    let c = client_with(MockTransport::new(), ServerKind::Jellyfin, false);
    block_on(c.check_reachability()).expect("answer");
    assert_eq!(last(&c).timeout, Some(std::time::Duration::from_secs(8)));
    block_on(c.public_system_info()).expect("answer");
    assert_eq!(last(&c).timeout, None);
}

// ---- :390 authenticate + AuthRequestTests.swift:61-100 ---------------------------------

const AUTH_ANSWER: &str =
    r#"{"AccessToken":"tok","ServerId":"s","User":{"Id":"u1","Name":"Testnutzer"}}"#;

fn auth_client() -> JellyfinClient<MockTransport> {
    client_with(
        MockTransport::new().route("Users/AuthenticateByName", 200, AUTH_ANSWER),
        ServerKind::Jellyfin,
        false,
    )
}

#[test]
fn authenticate_sends_username_and_pw_in_jellyfins_spelling() {
    let c = auth_client();
    let s = block_on(c.authenticate("paul", "geheim ✓")).expect("session");
    assert_eq!(
        (
            s.access_token.as_str(),
            s.user_id.as_str(),
            s.server_url.as_str()
        ),
        ("tok", "u1", BASE)
    );
    let r = last(&c);
    assert_json_post(
        &r,
        "https://tv.example.de/Users/AuthenticateByName",
        &json!({"Username": "paul", "Pw": "geheim ✓"}),
    );
    assert_eq!(
        r.body.as_deref().map(<[u8]>::len),
        Some(r#"{"Username":"paul","Pw":"geheim ✓"}"#.len())
    );
    // the session is stored: the next call carries the token
    assert_eq!(
        c.current_session().map(|s| s.user_name),
        Some("Testnutzer".into())
    );
}

#[test]
fn authorization_header_has_no_token_at_login() {
    let c = auth_client();
    block_on(c.authenticate("paul", "x")).expect("session");
    let h = last(&c)
        .header("Authorization")
        .expect("header")
        .to_string();
    assert!(h.starts_with("MediaBrowser "));
    assert!(h.contains(r#"Client="Swiftly Player""#));
    assert!(h.contains(r#"DeviceId="dev""#));
    assert!(!h.contains("Token="));
    assert_eq!(h, AUTH);
}

#[test]
fn authenticate_hits_the_right_endpoint() {
    let c = auth_client();
    block_on(c.authenticate("paul", "x")).expect("session");
    let r = last(&c);
    assert_eq!(
        (r.url.path(), r.method),
        ("/Users/AuthenticateByName", Method::Post)
    );
}

// :1547
#[test]
fn login_failures_are_sorted() {
    let c = client_with(
        MockTransport::new().route("Users/AuthenticateByName", 401, r#"{"AccessToken":"x"}"#),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(
        block_on(c.authenticate("p", "q")),
        Err(ErrorKind::TwoFactor)
    );
    let c = client_with(
        MockTransport::new().route("Users/AuthenticateByName", 401, "Wrong"),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(
        block_on(c.authenticate("p", "q")),
        Err(ErrorKind::Http {
            status: 401,
            body: Some("Wrong".into())
        })
    );
    assert!(c.current_session().is_none());
}

// :417
#[test]
fn sign_off_posts_logout_and_clears_the_session_even_when_it_fails() {
    let c =
        jf(MockTransport::new().route_error("Sessions/Logout", ErrorKind::Network { code: -1009 }));
    block_on(c.sign_off());
    let r = last(&c);
    assert_eq!(
        (r.method, r.url.as_str()),
        (Method::Post, "https://tv.example.de/Sessions/Logout")
    );
    assert_eq!(r.body, None);
    assert!(c.current_session().is_none());
}

// :430
#[test]
fn session_check_is_false_only_for_401_and_403() {
    for (status, expect) in [(200, true), (401, false), (403, false), (500, true)] {
        let c = jf(MockTransport::new().route("Users/u1", status, "{}"));
        assert_eq!(block_on(c.session_applies_still()), expect, "{status}");
        assert_get(&last(&c), "https://tv.example.de/Users/u1");
    }
    let c = jf(MockTransport::new().route_error("Users/u1", ErrorKind::Network { code: -1001 }));
    assert!(
        block_on(c.session_applies_still()),
        "a network error means unknown"
    );
}

// ---- :441 ------------------------------------------------------------------------------

#[test]
fn user_views() {
    let c = jf(MockTransport::new().route("UserViews", 200, &fixture("emby_views.json")));
    let views = block_on(c.user_views(false)).expect("views");
    assert!(views.iter().any(|v| v.name == "Filme"));
    assert_get(&last(&c), "https://tv.example.de/UserViews?userId=u1");
    block_on(c.user_views(true)).expect("views");
    assert_get(
        &last(&c),
        "https://tv.example.de/UserViews?userId=u1&includeHidden=true",
    );
}

// ---- :449-531 --------------------------------------------------------------------------

const FIELDS_LIST: &str =
    "Overview,PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,ChildCount";

#[test]
fn items_defaults() {
    let c = jf(MockTransport::new());
    block_on(c.items(&ItemsQuery::default())).expect("items");
    assert_get(
        &last(&c),
        &format!(
            "https://tv.example.de/Items?userId=u1&Limit=100&StartIndex=0&SortBy=SortName&SortOrder=Ascending&Fields={FIELDS_LIST}&Recursive=false"
        ),
    );
}

#[test]
fn items_with_every_argument_in_swift_order() {
    let c = jf(MockTransport::new());
    let q = ItemsQuery {
        parent_id: Some("lib1".into()),
        limit: 50,
        start_index: 100,
        sort_by: "DateCreated".into(),
        sort_order: "Descending".into(),
        filters: vec!["IsResumable".into(), "IsFavorite".into()],
        is_watched: Some(false),
        recursive: true,
        include_item_types: vec!["Movie".into(), "Series".into()],
        ids: vec!["a".into(), "b".into()],
        person_ids: vec!["p1".into()],
        genres: vec!["Action".into(), "Sci-Fi & Fantasy".into()],
        slim: false,
    };
    block_on(c.items(&q)).expect("items");
    // order: base block, ParentId, IncludeItemTypes, Filters, Ids, PersonIds, Genres (pipe), IsPlayed
    assert_get(
        &last(&c),
        &format!(
            "https://tv.example.de/Items?userId=u1&Limit=50&StartIndex=100&SortBy=DateCreated&SortOrder=Descending&Fields={FIELDS_LIST}&Recursive=true&ParentId=lib1&IncludeItemTypes=Movie,Series&Filters=IsResumable,IsFavorite&Ids=a,b&PersonIds=p1&Genres=Action%7CSci-Fi%20%26%20Fantasy&IsPlayed=false"
        ),
    );
}

#[test]
fn items_slim_drops_limit_start_and_fields_then_appends_lean_flags() {
    let c = jf(MockTransport::new());
    let q = ItemsQuery {
        parent_id: Some("lib1".into()),
        recursive: true,
        slim: true,
        is_watched: Some(true),
        ..Default::default()
    };
    block_on(c.items(&q)).expect("items");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&SortBy=SortName&SortOrder=Ascending&Recursive=true&ParentId=lib1&IsPlayed=true&Fields=SortName,DateCreated&EnableImages=false&EnableUserData=false",
    );
}

// :537
#[test]
fn count_asks_for_one_title_and_reads_the_total() {
    let c = jf(MockTransport::new().route(
        "Items",
        200,
        r#"{"Items":[{"Id":"a","Name":"A"}],"TotalRecordCount":321}"#,
    ));
    assert_eq!(
        block_on(c.count("lib1", &["Movie".into(), "Series".into()])),
        Ok(321)
    );
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&ParentId=lib1&IncludeItemTypes=Movie,Series&Recursive=true&Limit=1&EnableImages=false&EnableUserData=false",
    );
}

// :553
#[test]
fn title_ids() {
    let c = jf(MockTransport::new());
    block_on(c.title_ids("lib1", &["Movie".into()], &[], None)).expect("ids");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&ParentId=lib1&IncludeItemTypes=Movie&Recursive=true&Fields=ProviderIds&EnableImages=false&EnableUserData=false",
    );
    block_on(c.title_ids(
        "lib1",
        &["Movie".into()],
        &["IsFavorite".into()],
        Some(true),
    ))
    .expect("ids");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&ParentId=lib1&IncludeItemTypes=Movie&Recursive=true&Fields=ProviderIds&EnableImages=false&EnableUserData=false&Filters=IsFavorite&IsPlayed=true",
    );
}

// :572
#[test]
fn identifiers_skip_the_request_when_empty() {
    let c = jf(MockTransport::new());
    assert_eq!(block_on(c.identifiers(&[])), Ok(vec![]));
    assert!(c.transport().requests().is_empty());
    block_on(c.identifiers(&["x".into(), "y".into()])).expect("items");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&Ids=x,y&Fields=ProviderIds&EnableImages=false&EnableUserData=false",
    );
}

// :587
#[test]
fn ancestors() {
    let c = jf(MockTransport::new().route("Ancestors", 200, r#"[{"Id":"f","Name":"Folder"}]"#));
    let list = block_on(c.ancestors("m1")).expect("list");
    assert_eq!(list.len(), 1);
    assert_get(
        &last(&c),
        "https://tv.example.de/Items/m1/Ancestors?userId=u1",
    );
}

// :597
#[test]
fn remembered_ids() {
    let c = jf(MockTransport::new());
    block_on(c.remembered_ids(&["Movie".into(), "Series".into()], "SortName", "Ascending"))
        .expect("items");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&Recursive=true&Filters=IsFavorite&IncludeItemTypes=Movie,Series&SortBy=SortName&SortOrder=Ascending&Fields=ProviderIds&EnableImages=false&EnableUserData=false",
    );
}

// :619
#[test]
fn collection_members() {
    let c = jf(MockTransport::new());
    block_on(c.collection_members("box1")).expect("items");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&ParentId=box1&IncludeItemTypes=Movie,Series&Limit=2000&EnableImages=false&EnableUserData=false",
    );
}

// :637
#[test]
fn playlist_entries() {
    let c = jf(MockTransport::new());
    block_on(c.playlist_entries("pl1", false)).expect("items");
    assert_get(
        &last(&c),
        "https://tv.example.de/Playlists/pl1/Items?userId=u1&Limit=2000&Fields=Overview,PrimaryImageAspectRatio,ProviderIds",
    );
    block_on(c.playlist_entries("pl1", true)).expect("items");
    assert_get(
        &last(&c),
        "https://tv.example.de/Playlists/pl1/Items?userId=u1&Limit=2000&Fields=Overview,PrimaryImageAspectRatio,ProviderIds&EnableImages=false&EnableUserData=false",
    );
}

// ---- :669-702 PlaybackInfo --------------------------------------------------------------

#[test]
fn playback_info_body() {
    let c = jf(MockTransport::new().route("PlaybackInfo", 200, &fixture("emby_playbackInfo.json")));
    let profile = json!({"Name": "Swiftly", "MaxStreamingBitrate": 120_000_000});
    let info =
        block_on(c.playback_info("8", &profile, 120_000_000, None, None, None)).expect("info");
    assert_eq!(info.media_sources.len(), 2);
    assert_json_post(
        &last(&c),
        "https://tv.example.de/Items/8/PlaybackInfo",
        &json!({
            "UserId": "u1",
            "DeviceProfile": {"Name": "Swiftly", "MaxStreamingBitrate": 120_000_000},
            "MaxStreamingBitrate": 120_000_000,
            "AutoOpenLiveStream": true,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true
        }),
    );
    // optional fields appear only when set (synthesized Encodable omits nil)
    block_on(c.playback_info("8", &profile, 8_000_000, Some(2), Some(5), Some("src9")))
        .expect("info");
    let sent: Value =
        serde_json::from_slice(last(&c).body.as_deref().expect("body")).expect("json");
    assert_eq!(sent["MaxStreamingBitrate"], 8_000_000);
    assert_eq!(
        (
            sent["AudioStreamIndex"].clone(),
            sent["SubtitleStreamIndex"].clone(),
            sent["MediaSourceId"].clone()
        ),
        (json!(2), json!(5), json!("src9"))
    );
}

// ---- :711 and the rest of the title calls ------------------------------------------------

#[test]
fn item_genres_similar_extras_trailers() {
    let c = jf(MockTransport::new().route("Items/8", 200, &fixture("emby_movie.json")));
    assert_eq!(block_on(c.item("8")).expect("item").name, "Testfilm");
    assert_get(&last(&c), "https://tv.example.de/Items/8?userId=u1");

    let c = jf(MockTransport::new().route(
        "Genres",
        200,
        r#"{"Items":[{"Id":"1","Name":"Action"},{"Id":"2","Name":"Drama"}]}"#,
    ));
    assert_eq!(
        block_on(c.genres()),
        Ok(vec!["Action".to_string(), "Drama".to_string()])
    );
    assert_get(
        &last(&c),
        "https://tv.example.de/Genres?userId=u1&IncludeItemTypes=Movie,Series&Recursive=true&SortBy=SortName",
    );

    // :739 asks for twice the limit, lower-case `limit`
    let c = jf(MockTransport::new());
    block_on(c.similar("8", 12)).expect("similar");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items/8/Similar?userId=u1&limit=24&Fields=ProviderIds",
    );

    // :753 / :941 lenient lists: the broken entry is skipped
    let c = jf(MockTransport::new().route(
        "SpecialFeatures",
        200,
        r#"[{"Id":"a","Name":"Making of"},{"Id":"b"}]"#,
    ));
    assert_eq!(block_on(c.extras("8")).expect("extras").len(), 1);
    assert_get(
        &last(&c),
        "https://tv.example.de/Items/8/SpecialFeatures?userId=u1",
    );
    let c = jf(MockTransport::new().route("LocalTrailers", 200, "[]"));
    assert!(block_on(c.trailers("8")).expect("trailers").is_empty());
    assert_get(
        &last(&c),
        "https://tv.example.de/Items/8/LocalTrailers?userId=u1",
    );
}

// :773
#[test]
fn search_encodes_the_term() {
    let c = jf(MockTransport::new());
    block_on(c.search("Tom & Jerry: Äpfel", 40)).expect("search");
    assert_get(
        &last(&c),
        &format!(
            "https://tv.example.de/Items?userId=u1&searchTerm=Tom%20%26%20Jerry:%20%C3%84pfel&Recursive=true&IncludeItemTypes=Movie,Series&Limit=40&Fields={}",
            "Overview,PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,ChildCount"
        ),
    );
}

// ---- :794-867 user data ---------------------------------------------------------------

#[test]
fn user_record_jellyfin_and_emby() {
    let c = jf(MockTransport::new().route("UserData", 200, r#"{"PlaybackPositionTicks":5,"Played":true,"LastPlayedDate":"2026-09-03T14:10:09.2201736Z"}"#));
    let d = block_on(c.user_record("42")).expect("record");
    assert_eq!(d.playback_position_ticks, Some(5));
    assert_get(
        &last(&c),
        "https://tv.example.de/UserItems/42/UserData?userId=u1",
    );

    // :798 Emby has no read-only user-data path: the title carries the record
    let c = client_with(
        MockTransport::new().route(
            "Items/8",
            200,
            r#"{"Id":"8","Name":"X","UserData":{"PlaybackPositionTicks":9}}"#,
        ),
        ServerKind::Emby,
        true,
    );
    assert_eq!(
        block_on(c.user_record("8"))
            .expect("record")
            .playback_position_ticks,
        Some(9)
    );
    assert_get(
        &last(&c),
        "https://tv.example.de/Users/u1/Items/8?userId=u1",
    );
    let c = client_with(
        MockTransport::new().route("Items/8", 200, r#"{"Id":"8","Name":"X"}"#),
        ServerKind::Emby,
        true,
    );
    assert!(matches!(
        block_on(c.user_record("8")),
        Err(ErrorKind::Decoding(_))
    ));
}

#[test]
fn last_play_and_point_back_post_partial_user_data() {
    let c = jf(MockTransport::new());
    // :811 fractional seconds, UTC, Z
    block_on(c.last_play_set("42", 1_788_444_609.25)).expect("set");
    assert_json_post(
        &last(&c),
        "https://tv.example.de/UserItems/42/UserData?userId=u1",
        &json!({"LastPlayedDate": "2026-09-03T14:10:09.250Z"}),
    );
    // :827
    block_on(c.point_back_set("42")).expect("set");
    assert_json_post(
        &last(&c),
        "https://tv.example.de/UserItems/42/UserData?userId=u1",
        &json!({"PlaybackPositionTicks": 0}),
    );
}

#[test]
fn watchlist_and_watched_use_post_and_delete() {
    let c = jf(MockTransport::new());
    for (on, method) in [(true, Method::Post), (false, Method::Delete)] {
        block_on(c.set_watchlist("42", on)).expect("ok"); // :859
        let r = last(&c);
        assert_eq!(
            (r.method, r.url.as_str()),
            (
                method,
                "https://tv.example.de/UserFavoriteItems/42?userId=u1"
            )
        );
        assert_eq!(r.body, None);
        block_on(c.set_watched("42", on)).expect("ok"); // :867
        let r = last(&c);
        assert_eq!(
            (r.method, r.url.as_str()),
            (method, "https://tv.example.de/UserPlayedItems/42?userId=u1")
        );
    }
    let c = jf(MockTransport::new().route("UserPlayedItems/42", 403, "no"));
    assert_eq!(
        block_on(c.set_watched("42", true)),
        Err(ErrorKind::Http {
            status: 403,
            body: Some("no".into())
        })
    );
}

// ---- :898-1096 series and home rows ---------------------------------------------------

#[test]
fn seasons_and_episodes() {
    let c = jf(MockTransport::new());
    block_on(c.seasons("s1")).expect("ok"); // :898
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/s1/Seasons?userId=u1&isMissing=false&Fields=Overview",
    );
    block_on(c.episodes("s1", None)).expect("ok"); // :909
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/s1/Episodes?userId=u1&isMissing=false&Fields=Overview,MediaSources",
    );
    block_on(c.episodes("s1", Some("se2"))).expect("ok");
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/s1/Episodes?userId=u1&isMissing=false&Fields=Overview,MediaSources&seasonId=se2",
    );
    block_on(c.first_episode("s1")).expect("ok"); // :926
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/s1/Episodes?userId=u1&isMissing=false&Limit=1&Fields=Overview,MediaSources",
    );
}

#[test]
fn metadata_refresh() {
    let c = jf(MockTransport::new()); // :949
    block_on(c.metadata_refresh("42")).expect("ok");
    let r = last(&c);
    assert_eq!(
        (r.method, r.url.as_str()),
        (
            Method::Post,
            "https://tv.example.de/Items/42/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=FullRefresh&replaceAllMetadata=false"
        )
    );
    let c = jf(MockTransport::new().route("Refresh", 500, ""));
    assert_eq!(
        block_on(c.metadata_refresh("42")),
        Err(ErrorKind::Transport(TransportReason::RefreshRejected))
    );
}

#[test]
fn next_episode_of_a_series() {
    // :964
    let c = jf(MockTransport::new().route(
        "Shows/NextUp",
        200,
        r#"{"Items":[{"Id":"e1","Name":"E"}],"TotalRecordCount":1}"#,
    ));
    assert_eq!(
        block_on(c.next_episode_series("s1"))
            .expect("ok")
            .map(|i| i.id),
        Some("e1".into())
    );
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/NextUp?userId=u1&seriesId=s1&Limit=1&Fields=Overview",
    );
    // Jellyfin: nothing found, nothing more asked
    let c = jf(MockTransport::new());
    assert_eq!(block_on(c.next_episode_series("s1")), Ok(None));
    assert_eq!(c.transport().requests().len(), 1);
    // Emby: falls back to the first unwatched episode
    let c = client_with(
        MockTransport::new().route(
            "Shows/s1/Episodes",
            200,
            r#"{"Items":[{"Id":"e0","Name":"E0"}]}"#,
        ),
        ServerKind::Emby,
        true,
    );
    assert_eq!(
        block_on(c.next_episode_series("s1"))
            .expect("ok")
            .map(|i| i.id),
        Some("e0".into())
    );
    assert_eq!(c.transport().requests().len(), 2);
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/s1/Episodes?userId=u1&isMissing=false&Filters=IsUnplayed&Limit=1&Fields=Overview",
    );
}

#[test]
fn episode_post_picks_the_one_after() {
    let list =
        r#"{"Items":[{"Id":"e1","Name":"1"},{"Id":"e2","Name":"2"},{"Id":"e3","Name":"3"}]}"#;
    let c = jf(MockTransport::new().route("Episodes", 200, list));
    assert_eq!(
        block_on(c.episode_post("e2", "s1"))
            .expect("ok")
            .map(|i| i.id),
        Some("e3".into())
    ); // :996
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/s1/Episodes?userId=u1&isMissing=false&adjacentTo=e2&Fields=Overview",
    );
    assert_eq!(block_on(c.episode_post("e3", "s1")), Ok(None));
    assert_eq!(block_on(c.episode_post("zz", "s1")), Ok(None));
}

#[test]
fn home_rows() {
    let c = jf(MockTransport::new());
    block_on(c.resume_items(20)).expect("ok"); // :1009
    assert_get(
        &last(&c),
        "https://tv.example.de/UserItems/Resume?userId=u1&Limit=20&Fields=Overview,PrimaryImageAspectRatio,ProviderIds&MediaTypes=Video",
    );
    block_on(c.next_up(20)).expect("ok"); // :1024
    assert_get(
        &last(&c),
        "https://tv.example.de/Shows/NextUp?userId=u1&Limit=20&Fields=Overview,PrimaryImageAspectRatio,ProviderIds",
    );
    block_on(c.newly_joined(None, 20, false, "Movie,Episode")).expect("ok"); // :1073
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&Limit=20&Recursive=true&SortBy=DateCreated&SortOrder=Descending&IncludeItemTypes=Movie,Episode&IsVirtualItem=false&Fields=Overview,PrimaryImageAspectRatio,ProviderIds",
    );
    block_on(c.newly_joined(Some("lib1"), 8, true, "Episode")).expect("ok");
    assert_get(
        &last(&c),
        "https://tv.example.de/Items?userId=u1&Limit=8&Recursive=true&SortBy=DateCreated&SortOrder=Descending&IncludeItemTypes=Episode&IsVirtualItem=false&Fields=ProviderIds&EnableImages=false&EnableUserData=false&ParentId=lib1",
    );
}

// ---- Emby (EmbyTests.swift:73-110) ------------------------------------------------------

#[test]
fn emby_asks_under_the_user_path_with_api_key() {
    let mock = MockTransport::new()
        .route("Views", 200, &fixture("emby_views.json"))
        .route("Items/8", 200, &fixture("emby_movie.json"));
    let c = client_with(mock, ServerKind::Emby, true);
    let views = block_on(c.user_views(false)).expect("views");
    assert_eq!(last(&c).url.path(), "/Users/u1/Views");
    assert!(views.iter().any(|v| v.name == "Filme"));
    let movie = block_on(c.item("8")).expect("movie");
    assert_eq!(last(&c).url.path(), "/Users/u1/Items/8");
    assert_eq!(movie.name, "Testfilm");
    let q = c
        .image_url(&movie, 480)
        .and_then(|u| u.query().map(String::from))
        .unwrap_or_default();
    assert!(q.contains("api_key=TOKEN"), "{q}");
    assert!(!q.contains("ApiKey="), "{q}");
}

#[test]
fn jellyfin_keeps_flat_paths_and_apikey() {
    let mock = MockTransport::new()
        .route("UserViews", 200, &fixture("emby_views.json"))
        .route("Items/8", 200, &fixture("emby_movie.json"));
    let c = jf(mock);
    block_on(c.user_views(false)).expect("views");
    assert_eq!(last(&c).url.path(), "/UserViews");
    let movie = block_on(c.item("8")).expect("movie");
    assert_eq!(last(&c).url.path(), "/Items/8");
    assert!(
        c.image_url(&movie, 480)
            .and_then(|u| u.query().map(String::from))
            .is_some_and(|q| q.contains("ApiKey=TOKEN"))
    );
    assert_eq!(c.server_kind(), ServerKind::Jellyfin);
    // Plex given to this client counts as Jellyfin (:156)
    let plex = JellyfinClient::new(
        MockTransport::new(),
        BASE,
        ClientConfig::new("d", "n", "1").kind(ServerKind::Plex),
    )
    .expect("client");
    assert_eq!(plex.server_kind(), ServerKind::Jellyfin);
}

#[test]
fn emby_user_bound_paths_on_the_wire() {
    let c = client_with(MockTransport::new(), ServerKind::Emby, true);
    block_on(c.resume_items(5)).expect("ok");
    assert_eq!(last(&c).url.path(), "/Users/u1/Items/Resume");
    block_on(c.set_watchlist("9", true)).expect("ok");
    assert_eq!(last(&c).url.path(), "/Users/u1/FavoriteItems/9");
    block_on(c.set_watched("9", false)).expect("ok");
    assert_eq!(last(&c).url.path(), "/Users/u1/PlayedItems/9");
    block_on(c.next_up(5)).expect("ok");
    assert_eq!(last(&c).url.path(), "/Shows/NextUp", "unchanged");
}

// ---- addresses without a request ---------------------------------------------------------

#[test]
fn stream_image_and_trickplay_addresses() {
    let c = jf(MockTransport::new());
    // :1368 order: static, token, mediaSourceId, playSessionId
    assert_eq!(
        c.stream_url("8", Some("ms1"), Some("ps1"))
            .expect("url")
            .as_str(),
        "https://tv.example.de/Videos/8/stream?static=true&ApiKey=TOKEN&mediaSourceId=ms1&playSessionId=ps1"
    );
    assert_eq!(
        c.stream_url("8", None, None).expect("url").as_str(),
        "https://tv.example.de/Videos/8/stream?static=true&ApiKey=TOKEN"
    );
    let emby = client_with(MockTransport::new(), ServerKind::Emby, true);
    assert_eq!(
        emby.stream_url("8", None, None).expect("url").as_str(),
        "https://tv.example.de/Videos/8/stream?static=true&api_key=TOKEN"
    );
    // :1281
    assert_eq!(
        c.trickplay_url("8", Some("ms1"), 320, 2)
            .expect("url")
            .as_str(),
        "https://tv.example.de/Videos/8/Trickplay/320/2.jpg?MediaSourceId=ms1&ApiKey=TOKEN"
    );
    // :1518 / :1502
    let item: swiftly_model::Item = serde_json::from_str(
        r#"{"Id":"8","Name":"X","ImageTags":{"Primary":"tg"},"BackdropImageTags":["bd"]}"#,
    )
    .expect("item");
    assert_eq!(
        c.image_url(&item, 480).expect("url").as_str(),
        "https://tv.example.de/Items/8/Images/Primary?tag=tg&maxHeight=480&quality=90&ApiKey=TOKEN"
    );
    assert_eq!(
        c.backdrop_url(&item, 1200).expect("url").as_str(),
        "https://tv.example.de/Items/8/Images/Backdrop?tag=bd&maxWidth=1200&quality=85&ApiKey=TOKEN"
    );
    let signed_out = client_with(MockTransport::new(), ServerKind::Jellyfin, false);
    assert!(signed_out.image_url(&item, 480).is_none());
    assert!(signed_out.stream_url("8", None, None).is_err());
}

#[test]
fn requests_without_a_session_fail_before_the_network() {
    let c = client_with(MockTransport::new(), ServerKind::Jellyfin, false);
    assert_eq!(
        block_on(c.user_views(false)),
        Err(ErrorKind::NotAuthenticated)
    );
    assert_eq!(
        block_on(c.report_start("1", &ReportPlan::from_file(), 0, TrackIndices::default())),
        Err(ErrorKind::NotAuthenticated)
    );
    assert!(c.transport().requests().is_empty());
}

// ---- Login.swift ------------------------------------------------------------------------

#[test]
fn public_users_and_their_pictures() {
    let c = client_with(
        MockTransport::new().route(
            "Users/Public",
            200,
            r#"[{"Id":"u9","Name":"Anna","PrimaryImageTag":"t1"},{"Id":"u8","Name":"Ben"}]"#,
        ),
        ServerKind::Jellyfin,
        false,
    );
    let users = block_on(c.public_users()).expect("users");
    assert_eq!(users.len(), 2);
    let r = last(&c);
    assert_eq!(
        (r.method, r.url.as_str()),
        (Method::Get, "https://tv.example.de/Users/Public")
    );
    assert_eq!(
        c.user_image(&users[0], 180).expect("url").as_str(),
        "https://tv.example.de/Users/u9/Images/Primary?tag=t1&fillWidth=180&quality=90"
    );
    assert!(c.user_image(&users[1], 180).is_none());
    // switched off, or unreadable: an empty list, not an error
    let c = client_with(
        MockTransport::new().route("Users/Public", 401, ""),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(block_on(c.public_users()), Ok(vec![]));
    let c = client_with(
        MockTransport::new().route("Users/Public", 200, "nope"),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(block_on(c.public_users()), Ok(vec![]));
}

#[test]
fn quick_connect_flow() {
    let mock = MockTransport::new()
        .route_method(
            Method::Post,
            "QuickConnect/Initiate",
            200,
            r#"{"Secret":"SEC","Code":"123456"}"#,
        )
        .route_method(
            Method::Get,
            "QuickConnect/Connect",
            200,
            r#"{"Authenticated":true}"#,
        )
        .route("Users/AuthenticateWithQuickConnect", 200, AUTH_ANSWER);
    let c = client_with(mock, ServerKind::Jellyfin, false);
    let code = block_on(c.quick_connect_start()).expect("code"); // Login.swift:74
    assert_eq!(
        (code.code.as_str(), code.confidential.as_str()),
        ("123456", "SEC")
    );
    let r = last(&c);
    assert_eq!(
        (r.method, r.url.as_str(), r.body.as_ref()),
        (
            Method::Post,
            "https://tv.example.de/QuickConnect/Initiate",
            None
        )
    );
    assert_eq!(r.header("Content-Type"), None);

    assert_eq!(block_on(c.quick_connect_released(&code)), Ok(true)); // :98
    assert_eq!(
        last(&c).url.as_str(),
        "https://tv.example.de/QuickConnect/Connect?secret=SEC"
    );
    assert_eq!(
        block_on(c.quick_connect_ask_again(&code)),
        QuickConnectState::Released
    );

    let s = block_on(c.sign_in_with_quick_connect(&code)).expect("session"); // :131
    assert_eq!(s.user_id, "u1");
    assert_json_post(
        &last(&c),
        "https://tv.example.de/Users/AuthenticateWithQuickConnect",
        &json!({"Secret": "SEC"}),
    );
    assert!(c.current_session().is_some());
}

#[test]
fn quick_connect_error_cases() {
    let code = LoginCode {
        code: "1".into(),
        confidential: "S".into(),
    };
    let c = client_with(
        MockTransport::new().route("QuickConnect/Initiate", 503, ""),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(
        block_on(c.quick_connect_start()),
        Err(ErrorKind::Transport(TransportReason::QuickConnectDisabled))
    );
    let c = client_with(
        MockTransport::new().route("QuickConnect/Initiate", 500, "boom"),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(
        block_on(c.quick_connect_start()),
        Err(ErrorKind::Http {
            status: 500,
            body: Some("boom".into())
        })
    );
    let c = client_with(
        MockTransport::new().route("QuickConnect/Connect", 404, ""),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(
        block_on(c.quick_connect_released(&code)),
        Err(ErrorKind::QuickConnectExpired)
    );
    assert_eq!(
        block_on(c.quick_connect_ask_again(&code)),
        QuickConnectState::Expired
    );
    let c = client_with(
        MockTransport::new().route("QuickConnect/Connect", 500, ""),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(block_on(c.quick_connect_released(&code)), Ok(false));
    let c = client_with(
        MockTransport::new()
            .route_error("QuickConnect/Connect", ErrorKind::Network { code: -1001 }),
        ServerKind::Jellyfin,
        false,
    );
    assert_eq!(
        block_on(c.quick_connect_ask_again(&code)),
        QuickConnectState::Failed
    );
}

// ---- PlaybackReporting.swift ------------------------------------------------------------

fn plan() -> ReportPlan {
    ReportPlan {
        play_session_id: Some("ps1".into()),
        media_source_id: Some("ms1".into()),
        method: PlayMethod::DirectStream,
    }
}

#[test]
fn reports_start_progress_stopped() {
    let c = jf(MockTransport::new());
    let tracks = TrackIndices {
        audio: Some(1),
        subtitle: Some(3),
    };
    block_on(c.report_start("it1", &plan(), 0, tracks)).expect("ok"); // :46
    assert_json_post(
        &last(&c),
        "https://tv.example.de/Sessions/Playing",
        &json!({"ItemId": "it1", "PlaySessionId": "ps1", "PositionTicks": 0, "IsPaused": false, "MediaSourceId": "ms1", "PlayMethod": "DirectStream", "CanSeek": true, "AudioStreamIndex": 1, "SubtitleStreamIndex": 3}),
    );
    block_on(c.report_progress("it1", &plan(), 123_000_000, true, TrackIndices::default()))
        .expect("ok"); // :55
    assert_json_post(
        &last(&c),
        "https://tv.example.de/Sessions/Playing/Progress",
        &json!({"ItemId": "it1", "PlaySessionId": "ps1", "PositionTicks": 123_000_000, "IsPaused": true, "MediaSourceId": "ms1", "PlayMethod": "DirectStream", "CanSeek": true}),
    );
    // the missing tracks are left out, not sent as null
    assert!(
        !String::from_utf8_lossy(last(&c).body.as_deref().expect("body")).contains("StreamIndex")
    );
    block_on(c.report_stopped("it1", &ReportPlan::from_file(), 5)).expect("ok"); // :62
    assert_json_post(
        &last(&c),
        "https://tv.example.de/Sessions/Playing/Stopped",
        &json!({"ItemId": "it1", "PositionTicks": 5, "IsPaused": false, "PlayMethod": "DirectPlay", "CanSeek": true}),
    );
    assert_eq!(
        last(&c).header("Authorization"),
        Some(format!("{AUTH}, Token=\"TOKEN\"").as_str())
    );
    // key order of the body as Swift declares it
    let c = jf(MockTransport::new());
    block_on(c.report_progress("it1", &plan(), 1, false, TrackIndices::default())).expect("ok");
    let text = String::from_utf8(last(&c).body.expect("body")).expect("utf8");
    assert_eq!(
        text,
        r#"{"ItemId":"it1","PlaySessionId":"ps1","PositionTicks":1,"IsPaused":false,"MediaSourceId":"ms1","PlayMethod":"DirectStream","CanSeek":true}"#
    );
}

#[test]
fn stop_encoding_deletes_the_job_and_is_silent() {
    let c =
        jf(MockTransport::new().route_error("ActiveEncodings", ErrorKind::Network { code: -1005 }));
    block_on(c.stop_encoding("ps 1")); // :72
    let r = last(&c);
    assert_eq!(
        (r.method, r.url.as_str()),
        (
            Method::Delete,
            "https://tv.example.de/Videos/ActiveEncodings?deviceId=dev&playSessionId=ps%201"
        )
    );
    block_on(c.stop_encoding(""));
    assert_eq!(
        c.transport().requests().len(),
        1,
        "an empty session id sends nothing"
    );
}

// ---- PendingReport.swift late report ----------------------------------------------------

#[test]
fn late_report_sent_when_the_server_state_is_older() {
    let c = jf(MockTransport::new().route(
        "UserData",
        200,
        r#"{"PlaybackPositionTicks":0,"LastPlayedDate":"2026-01-01T00:00:00Z"}"#,
    ));
    let m = PendingReport::new("it1", "u1", 600_000_000, 1_788_444_609.0);
    assert_eq!(block_on(c.report_later(&m)), Ok(PostReportOutput::Sent));
    let seen = c.transport().requests();
    let urls: Vec<_> = seen
        .iter()
        .map(|r| format!("{} {}", r.method.as_str(), r.url.as_str()))
        .collect();
    assert_eq!(
        urls,
        [
            "GET https://tv.example.de/UserItems/it1/UserData?userId=u1",
            "POST https://tv.example.de/Sessions/Playing/Stopped",
            "POST https://tv.example.de/UserItems/it1/UserData?userId=u1",
        ]
    );
    let stopped: Value =
        serde_json::from_slice(seen[1].body.as_deref().expect("body")).expect("json");
    assert_eq!(
        stopped,
        json!({"ItemId": "it1", "PositionTicks": 600_000_000, "IsPaused": false, "PlayMethod": "DirectPlay", "CanSeek": true})
    );
    let date: Value = serde_json::from_slice(seen[2].body.as_deref().expect("body")).expect("json");
    assert_eq!(date, json!({"LastPlayedDate": "2026-09-03T14:10:09.000Z"}));
}

#[test]
fn late_report_discarded_when_newer_on_server_or_gone() {
    let c = jf(MockTransport::new().route(
        "UserData",
        200,
        r#"{"LastPlayedDate":"2030-01-01T00:00:00Z"}"#,
    ));
    let m = PendingReport::new("it1", "u1", 1, 1_788_444_609.0);
    assert_eq!(
        block_on(c.report_later(&m)),
        Ok(PostReportOutput::Discarded)
    );
    assert_eq!(c.transport().requests().len(), 1);
    let c = jf(MockTransport::new().route("UserData", 404, ""));
    assert_eq!(
        block_on(c.report_later(&m)),
        Ok(PostReportOutput::Discarded)
    );
    let c = jf(MockTransport::new().route("UserData", 500, ""));
    assert!(
        block_on(c.report_later(&m)).is_err(),
        "other errors leave the report lying"
    );
}

#[test]
fn late_reports_stop_at_the_first_failure() {
    let mock = MockTransport::new()
        .route("UserItems/a/UserData", 200, "{}")
        .route("UserItems/b/UserData", 500, "")
        .route("UserItems/c/UserData", 200, "{}");
    let c = jf(mock);
    let list = [
        PendingReport::new("a", "u1", 1, 10.0),
        PendingReport::new("b", "u1", 1, 20.0),
        PendingReport::new("c", "u1", 1, 30.0),
    ];
    let mut log = Vec::new();
    let done = block_on(c.report_later_all(&list, |l| log.push(l.to_string())));
    assert_eq!(done, ["u1/a"]);
    assert_eq!(log.len(), 2);
    assert!(
        !c.transport()
            .requests()
            .iter()
            .any(|r| r.url.path().contains("/c/"))
    );
}

// ---- error handling of send() -----------------------------------------------------------

#[test]
fn http_error_carries_the_first_400_bytes() {
    let long = "x".repeat(900);
    let c = jf(MockTransport::new().route("System/Info/Public", 500, &long));
    match block_on(c.public_system_info()) {
        Err(ErrorKind::Http {
            status: 500,
            body: Some(b),
        }) => assert_eq!(b.len(), 400),
        other => panic!("{other:?}"),
    }
}

#[test]
fn decode_error_and_gateway_login_page() {
    let c = jf(MockTransport::new().route("System/Info/Public", 200, "not json"));
    assert!(matches!(
        block_on(c.public_system_info()),
        Err(ErrorKind::Decoding(_))
    ));
    // OwnHeadersTests.swift:175: HTML instead of JSON means a gateway answered
    let html = HttpResponse::new(200, "<html>Sign in</html>")
        .with_header("Content-Type", "text/html; charset=utf-8");
    let c = jf(MockTransport::new().route_response("System/Info/Public", html.clone()));
    assert_eq!(
        block_on(c.public_system_info()),
        Err(ErrorKind::Transport(TransportReason::LoginPage))
    );
    // and an immediate 401/403 with a login page
    let mut rejected = html;
    rejected.status = 403;
    let c = jf(MockTransport::new().route_response("System/Info/Public", rejected));
    assert_eq!(
        block_on(c.public_system_info()),
        Err(ErrorKind::Transport(TransportReason::LoginPage))
    );
}

// OwnHeadersTests.swift:150: every request to Jellyfin carries them, ours stay ours
#[test]
fn own_headers_ride_along_but_never_replace_ours() {
    let base = swiftly_net::Url::parse("https://jf.sechs.test").expect("url");
    OwnHeaders::set_down(
        &[
            OwnHeader::new("CF-Access-Client-Id", "erfunden.access"),
            OwnHeader::new("Authorization", "Bearer fremd"),
        ],
        &base,
    );
    let c = JellyfinClient::new(
        MockTransport::new(),
        "https://jf.sechs.test",
        ClientConfig::new("dev", "Test", "1.0"),
    )
    .expect("client");
    block_on(c.public_system_info()).expect("info");
    let r = last(&c);
    OwnHeaders::set_down(&[], &base);
    assert_eq!(r.header("CF-Access-Client-Id"), Some("erfunden.access"));
    assert!(
        r.header("Authorization")
            .is_some_and(|a| a.starts_with("MediaBrowser "))
    );
    // header order: own first, then ours
    assert_eq!(
        r.headers
            .iter()
            .map(|(n, _)| n.as_str())
            .collect::<Vec<_>>(),
        ["CF-Access-Client-Id", "Authorization", "Accept"]
    );
}

#[test]
fn invalid_base_address() {
    assert!(
        JellyfinClient::new(
            MockTransport::new(),
            "not a url",
            ClientConfig::new("d", "n", "1")
        )
        .is_err()
    );
    assert!(
        JellyfinClient::new(
            MockTransport::new(),
            "ftp://x.de",
            ClientConfig::new("d", "n", "1")
        )
        .is_err()
    );
}

#[test]
fn base_path_is_kept() {
    let c = JellyfinClient::new(
        MockTransport::new(),
        "https://proxy.test/jellyfin/",
        ClientConfig::new("d", "n", "1"),
    )
    .expect("client");
    block_on(c.public_system_info()).expect("info");
    assert_eq!(
        last(&c).url.as_str(),
        "https://proxy.test/jellyfin/System/Info/Public"
    );
}

// ---- opt-in live test: never runs by default, URL and user from the environment -----------

#[test]
#[ignore = "needs JF_URL, JF_USER, JF_PASS in the environment and a reachable server"]
#[cfg(feature = "reqwest")]
fn live_sign_in_and_views() {
    use swiftly_net::ReqwestTransport;
    let (Ok(url), Ok(user), Ok(pass)) = (
        std::env::var("JF_URL"),
        std::env::var("JF_USER"),
        std::env::var("JF_PASS"),
    ) else {
        return;
    };
    let transport = ReqwestTransport::new().expect("transport");
    let c = JellyfinClient::new(
        transport,
        &url,
        ClientConfig::new("live-test", "Live Test", "0"),
    )
    .expect("client");
    block_on_tokio(async {
        c.public_system_info().await.expect("info");
        c.authenticate(&user, &pass).await.expect("sign in");
        assert!(!c.user_views(false).await.expect("views").is_empty());
        c.sign_off().await;
    });
}

#[cfg(feature = "reqwest")]
fn block_on_tokio<F: std::future::Future>(f: F) -> F::Output {
    // reqwest needs a tokio runtime; futures-executor has none.
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime")
        .block_on(f)
}
