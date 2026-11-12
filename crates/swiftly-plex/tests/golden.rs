#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Golden tests over `MockTransport`: the exact method, path, query and headers of every
//! Plex call listed in apple-logic.md 2.5 and 1.3. Each case cites the Swift line it mirrors.
mod common;

use std::sync::Arc;

use common::*;
use futures_executor::block_on;
use swiftly_library::library_filter::{LibraryFilter, Sorting};
use swiftly_net::{HttpRequest, MockTransport};
use swiftly_playback::media_server::MediaServer;
use swiftly_plex::*;
use url::Url;

fn mock() -> Arc<MockTransport> {
    Arc::new(
        MockTransport::new()
            .route_fixture("/library/metadata/1", "tests/fixtures/movie.json")
            .route_fixture("/api/v2/pins", "tests/fixtures/pin_fresh.json")
            .route_fixture("/api/v2/resources", "tests/fixtures/resources.json"),
    )
}

fn client(t: &Arc<MockTransport>) -> PlexClient<MockTransport> {
    PlexClient::new(
        Url::parse("http://192.168.1.5:32400").expect("url"),
        "TOK",
        identity(),
        Arc::clone(t),
    )
}

/// `METHOD /path?query` of the newest request.
fn line(t: &MockTransport) -> String {
    let r = t.last_request().expect("a request");
    format!(
        "{} {}{}",
        r.method.as_str(),
        r.url.path(),
        r.url.query().map(|q| format!("?{q}")).unwrap_or_default()
    )
}

fn newest(t: &MockTransport) -> HttpRequest {
    t.last_request().expect("a request")
}

fn ignore<T, E>(_: Result<T, E>) {}

#[test]
fn every_server_call_has_url_query_and_headers() {
    let t = mock();
    let c = client(&t);
    let mut got: Vec<(&str, String)> = Vec::new();
    macro_rules! case {
        ($label:expr, $call:expr) => {{
            ignore(block_on($call));
            got.push(($label, line(&t)));
        }};
    }
    // PlexClient.swift:342
    case!("identity", c.info());
    // :354, :365
    case!("sections", c.sections());
    // :395 (sort, type, filter, paging in headers)
    case!(
        "all",
        c.list(
            "2",
            Some("Series"),
            Sorting::Rating,
            LibraryFilter::All,
            Some("5"),
            10,
            20
        )
    );
    // :413
    case!("genre", c.genres_of_section("2"));
    // :421
    case!("continueWatching", c.continue_watching(20));
    // :427
    case!("onDeck", c.on_deck(20));
    // :432
    case!("recentlyAdded", c.recently_added(None, 24));
    case!("recentlyAddedSection", c.recently_added(Some("3"), 24));
    // :438
    case!("hubs", c.hubs(None));
    case!("hubsSection", c.hubs(Some("3")));
    // :445
    case!("search", c.search("Matrix", 40));
    // :457
    case!("detail", c.detail("1"));
    // :469, :478, :483, :491
    case!("children", c.children("3"));
    case!("allLeaves", c.episodes_of("3", None));
    case!("similar", c.similar_to("3", 12));
    case!("extras", c.clips("3"));
    // :498, :502, :507, :512
    case!("collections", c.collections("1"));
    case!("collectionChildren", c.collection_items("8"));
    case!("playlists", c.playlists());
    case!("playlistItems", c.playlist_items("9"));
    // :518
    case!("titlesByFilter", c.titles("1", "actor", "10", 0, 60));
    // :528 (+ PlexClient+MediaServer.swift:337)
    case!("scrobble", c.set_watched_key("7", true));
    case!("unscrobble", c.set_watched_key("7", false));
    // :534
    case!("rate", c.set_favorite("7", true));
    // :545
    case!("selectTracks", c.choose_tracks(2, Some(3), None));
    // :641
    case!(
        "timeline",
        c.report_timeline("7", TimelineState::Stopped, 100_000_000, Some(90_000))
    );
    // PlexClient+MediaServer.swift:330, :343
    case!("refresh", MediaServer::metadata_refresh(&c, "7"));
    case!(
        "removeFromContinueWatching",
        MediaServer::point_back_set(&c, "7")
    );
    // :615 preview index (Part 1 of the movie fixture has `indexes: sd`)
    case!("bifIndex", c.previews("1", None));

    let expect: &[(&str, &str)] = &[
        ("identity", "GET /identity"),
        ("sections", "GET /library/sections"),
        (
            "all",
            "GET /library/sections/2/all?sort=audienceRating%3Adesc&type=2&genre=5",
        ),
        ("genre", "GET /library/sections/2/genre"),
        ("continueWatching", "GET /hubs/continueWatching/items"),
        ("onDeck", "GET /library/onDeck"),
        ("recentlyAdded", "GET /library/recentlyAdded"),
        (
            "recentlyAddedSection",
            "GET /library/sections/3/recentlyAdded",
        ),
        ("hubs", "GET /hubs"),
        ("hubsSection", "GET /hubs/sections/3"),
        ("search", "GET /hubs/search?query=Matrix&limit=40"),
        (
            "detail",
            "GET /library/metadata/1?includeChapters=1&includeMarkers=1",
        ),
        ("children", "GET /library/metadata/3/children"),
        ("allLeaves", "GET /library/metadata/3/allLeaves"),
        ("similar", "GET /library/metadata/3/similar?count=12"),
        ("extras", "GET /library/metadata/3/extras"),
        ("collections", "GET /library/sections/1/collections"),
        ("collectionChildren", "GET /library/collections/8/children"),
        ("playlists", "GET /playlists?playlistType=video"),
        ("playlistItems", "GET /playlists/9/items"),
        ("titlesByFilter", "GET /library/sections/1/all?actor=10"),
        (
            "scrobble",
            "PUT /:/scrobble?key=7&identifier=com.plexapp.plugins.library",
        ),
        (
            "unscrobble",
            "PUT /:/unscrobble?key=7&identifier=com.plexapp.plugins.library",
        ),
        (
            "rate",
            "PUT /:/rate?key=7&identifier=com.plexapp.plugins.library&rating=10",
        ),
        (
            "selectTracks",
            "PUT /library/parts/2?allParts=1&audioStreamID=3&subtitleStreamID=0",
        ),
        (
            "timeline",
            "POST /:/timeline?ratingKey=7&key=%2Flibrary%2Fmetadata%2F7&state=stopped&time=10000&identifier=com.plexapp.plugins.library&duration=90000",
        ),
        ("refresh", "PUT /library/metadata/7/refresh"),
        (
            "removeFromContinueWatching",
            "PUT /actions/removeFromContinueWatching?ratingKey=7",
        ),
        (
            "bifIndex",
            "GET /library/parts/1/indexes/sd?X-Plex-Token=TOK",
        ),
    ];
    assert_eq!(got.len(), expect.len());
    for ((label, line), (elabel, eline)) in got.iter().zip(expect) {
        assert_eq!(label, elabel);
        assert_eq!(line, eline, "{label}");
    }
}

#[test]
fn headers_of_a_server_call() {
    // PlexIdentity.swift:56 and PlexClient.swift:~245: Accept, identity, token, session, paging.
    let t = mock();
    let c = client(&t);
    ignore(block_on(c.list(
        "1",
        None,
        Sorting::Name,
        LibraryFilter::All,
        None,
        50,
        25,
    )));
    let r = newest(&t);
    let want = [
        ("Accept", "application/json"),
        ("X-Plex-Client-Identifier", "cid"),
        ("X-Plex-Product", "Swiftly Player"),
        ("X-Plex-Version", "1.0"),
        ("X-Plex-Platform", "macOS"),
        ("X-Plex-Device", "Mac"),
        ("X-Plex-Device-Name", "Test Mac"),
        ("X-Plex-Token", "TOK"),
        ("X-Plex-Container-Start", "50"),
        ("X-Plex-Container-Size", "25"),
    ];
    for (name, value) in want {
        assert_eq!(r.header(name), Some(value), "{name}");
    }
    assert_eq!(
        r.header("X-Plex-Session-Identifier"),
        Some(c.session_id.as_str())
    );
    assert_eq!(r.timeout, Some(std::time::Duration::from_secs(20)));
    // The token is a header here, never in the query of a REST call.
    assert!(!r.url.as_str().contains("X-Plex-Token"));
}

#[test]
fn plex_tv_calls() {
    // PlexAccount.swift:129, :166, :194, :207, :220, :236
    let t = mock();
    let svc = PlexAccountService::new(identity(), Arc::clone(&t));
    let pin = block_on(svc.start_pin(true)).expect("pin");
    assert_eq!(line(&t), "POST /api/v2/pins?strong=true");
    assert_eq!(newest(&t).url.host_str(), Some("plex.tv"));
    ignore(block_on(svc.check_pin(&pin)));
    assert_eq!(line(&t), "GET /api/v2/pins/4711?code=ABCD1234");
    ignore(block_on(svc.validate("T")));
    assert_eq!(line(&t), "GET /api/v2/user");
    assert_eq!(newest(&t).header("X-Plex-Token"), Some("T"));
    ignore(block_on(svc.servers("T")));
    assert_eq!(
        line(&t),
        "GET /api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1"
    );
    assert_eq!(newest(&t).url.host_str(), Some("clients.plex.tv"));
    ignore(block_on(svc.home_users("T")));
    assert_eq!(line(&t), "GET /api/v2/home/users");
    let user =
        PlexHomeUser::parse(&serde_json::json!({"id": 2, "uuid": "uuid-kid"})).expect("user");
    ignore(block_on(svc.switch_user(&user, Some("12 4"), "T")));
    assert_eq!(
        line(&t),
        "POST /api/v2/home/users/uuid-kid/switch?pin=12%204"
    );
    assert_eq!(
        svc.link_page().expect("url").as_str(),
        "https://plex.tv/link"
    );
}

#[test]
fn address_builders() {
    // PlexPlayback.swift:38-68: file, download, subtitle, photo transcode, preview index.
    let p = PlexPlayback::new(
        Url::parse("https://plex.example.de:32400/").expect("url"),
        "TOK",
    );
    assert_eq!(
        p.file_url("/library/parts/5/9/file.mkv", true)
            .expect("url")
            .as_str(),
        "https://plex.example.de:32400/library/parts/5/9/file.mkv?download=1&X-Plex-Token=TOK"
    );
    assert_eq!(
        p.image_url("/library/metadata/5/art/9", None, Some(1280))
            .expect("url")
            .as_str(),
        "https://plex.example.de:32400/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F5%2Fart%2F9&upscale=0&width=1280&height=4096&quality=90&X-Plex-Token=TOK"
    );
    assert_eq!(
        p.preview_index_url(7).expect("url").as_str(),
        "https://plex.example.de:32400/library/parts/7/indexes/sd?X-Plex-Token=TOK"
    );
}
