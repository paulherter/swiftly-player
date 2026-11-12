#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Translation of `PlexMergeTests.swift` (7), `PlexFilesTests.swift` (5) and `PlexServerTests.swift`
//! (16 of 17: the `AccountBundle` test belongs to the accounts crate).
mod common;

use std::sync::{Arc, Mutex};

use common::*;
use futures_executor::block_on;
use futures_util::future::join_all;
use swiftly_jellyfin::{ItemsQuery, PendingReport, ServerKind, Session, TrackIndices};
use swiftly_library::home::HomePageSource;
use swiftly_net::ErrorKind;
use swiftly_playback::device_profile::DeviceProfile;
use swiftly_playback::media_server::{MediaServer, ServerCapability};
use swiftly_plex::merge;
use swiftly_plex::*;
use url::Url;

fn base(host: &str) -> Url {
    Url::parse(&format!("http://{host}:32400")).expect("url")
}

fn client_for(stub: &Arc<Stub>) -> PlexClient<Stub> {
    PlexClient::new(base("stub.test"), "TOK", identity(), Arc::clone(stub))
}

// MARK: PlexMergeTests (PlexMergeTests.swift:7)

struct Entry(&'static str, &'static str, i64, i64);

const KIDS: [Entry; 2] = [
    Entry("k1", "Kinderserie A", 1_000, 2010),
    Entry("k2", "Kinderserie B", 900, 2012),
];
const SERIEN: [Entry; 3] = [
    Entry("s1", "Neue Serie", 5_000, 2024),
    Entry("s2", "Mittlere Serie", 3_000, 2020),
    Entry("s3", "Alte Serie", 800, 2001),
];

fn body(entries: &[Entry], start: usize, size: usize, by_name: bool) -> String {
    let mut sorted: Vec<&Entry> = entries.iter().collect();
    if by_name {
        sorted.sort_by_key(|e| e.1);
    }
    let slice: Vec<&&Entry> = sorted.iter().skip(start).take(size).collect();
    let rows: Vec<String> = slice
        .iter()
        .map(|e| {
            format!(
                r#"{{"ratingKey":"{}","type":"show","title":"{}","addedAt":{},"year":{}}}"#,
                e.0, e.1, e.2, e.3
            )
        })
        .collect();
    format!(
        r#"{{"MediaContainer":{{"size":{},"totalSize":{},"Metadata":[{}]}}}}"#,
        slice.len(),
        entries.len(),
        rows.join(",")
    )
}

fn two_libraries() -> PlexClient<Stub> {
    let stub = Stub::new(|r| {
        let start = header(r, "X-Plex-Container-Start")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let size = header(r, "X-Plex-Container-Size")
            .and_then(|s| s.parse().ok())
            .unwrap_or(100);
        let by_name = r.url.query().unwrap_or("").contains("sort=titleSort");
        match r.url.path() {
            "/library/sections" => (
                200,
                r#"{"MediaContainer":{"size":2,"Directory":[{"key":"1","type":"show","title":"Kids","uuid":"a"},{"key":"2","type":"show","title":"Serien","uuid":"b"}]}}"#.into(),
            ),
            "/library/sections/1/all" | "/library/sections/1/recentlyAdded" => (200, body(&KIDS, start, size, by_name)),
            "/library/sections/2/all" | "/library/sections/2/recentlyAdded" => (200, body(&SERIEN, start, size, by_name)),
            _ => (404, String::new()),
        }
    });
    client_for(&stub)
}

fn series_query(limit: i64, start: i64, by: &str, order: &str) -> ItemsQuery {
    ItemsQuery {
        limit,
        start_index: start,
        sort_by: by.into(),
        sort_order: order.into(),
        recursive: true,
        include_item_types: vec!["Series".into()],
        ..ItemsQuery::default()
    }
}

fn ids(items: &[swiftly_model::Item]) -> Vec<&str> {
    items.iter().map(|i| i.id.as_str()).collect()
}

#[test] // newestAcrossLibraries, :60
fn newest_across_libraries() {
    let page =
        block_on(two_libraries().items_page(&series_query(10, 0, "DateCreated", "Descending")))
            .expect("page");
    assert_eq!(ids(&page.items), ["s1", "s2", "k1", "k2", "s3"]);
    assert_eq!(page.total_record_count, 5);
}

#[test] // paging, :69
fn paging() {
    let second =
        block_on(two_libraries().items_page(&series_query(2, 2, "DateCreated", "Descending")))
            .expect("page");
    assert_eq!(ids(&second.items), ["k1", "k2"]);
    assert_eq!(second.total_record_count, 5);
}

#[test] // byName, :79
fn by_name() {
    let page = block_on(two_libraries().items_page(&series_query(10, 0, "SortName", "Ascending")))
        .expect("page");
    let names: Vec<_> = page.items.iter().map(|i| i.name.as_str()).collect();
    assert_eq!(
        names,
        [
            "Alte Serie",
            "Kinderserie A",
            "Kinderserie B",
            "Mittlere Serie",
            "Neue Serie"
        ]
    );
}

#[test] // lastAddedByTime, :88
fn last_added_by_time() {
    let c = two_libraries();
    let items = block_on(c.last_added_kinds(None, 20, 4, "Series")).expect("items");
    assert_eq!(ids(&items), ["s1", "s2", "k1", "k2"]);
    let series = block_on(c.new_series(None, 3)).expect("series");
    assert_eq!(ids(&series), ["s1", "s2", "k1"]);
}

fn meta(id: &str, added: i64) -> PlexMetadata {
    let mut m = PlexMetadata::new(id, "show", &format!("t{id}"));
    m.added_at = Some(added);
    m
}

fn keys(list: &[PlexMetadata]) -> Vec<&str> {
    list.iter().map(|m| m.rating_key.as_str()).collect()
}

#[test] // unorderedStays, :99
fn unordered_stays() {
    let runs = vec![vec![meta("1", 1)], vec![meta("2", 9)]];
    assert_eq!(keys(&merge::merged(&runs, Some("random"))), ["1", "2"]);
    assert_eq!(keys(&merge::merged(&runs, None)), ["1", "2"]);
    assert_eq!(
        keys(&merge::merged(&runs, Some("addedAt:desc"))),
        ["2", "1"]
    );
}

#[test] // windowRanges, :106
fn window_ranges() {
    // 5000 + 50 titles, page at 4000: the big run skips what is surely before the page.
    let (ranges, skipped) = merge::window(&[5000, 50], 4000, 60);
    assert_eq!(ranges, [3950..4060, 0..50]);
    assert_eq!(skipped, 3950);
    // Start beyond the end: nothing to fetch.
    let (past, _) = merge::window(&[3, 2], 40, 10);
    assert!(past.iter().all(|r| r.is_empty()));
    // Single page at the start: from 0 up to size, capped by the run.
    assert_eq!(merge::window(&[100, 4], 0, 10).0, [0..10, 0..4]);
}

#[test] // windowedPageEqualsFullMerge, :116
fn windowed_page_equals_full_merge() {
    let sort = Some("addedAt:desc");
    let totals = [37i64, 5, 22];
    // Distinct, strictly descending addedAt per run, interleaved across runs.
    let runs: Vec<Vec<PlexMetadata>> = totals
        .iter()
        .enumerate()
        .map(|(library, total)| {
            (0..*total)
                .map(|n| meta(&format!("{library}-{n}"), 1_000 - (n * 3 + library as i64)))
                .collect()
        })
        .collect();
    let full = merge::merged(&runs, sort);
    for start in [0, 1, 7, 20, 31, 40, 63, 64, 70] {
        for size in [1, 6, 25] {
            let (ranges, skipped) = merge::window(&totals, start, size);
            let parts: Vec<Vec<PlexMetadata>> = runs
                .iter()
                .zip(&ranges)
                .map(|(run, r)| run[r.start as usize..r.end as usize].to_vec())
                .collect();
            let got = merge::page(&parts, skipped, sort, start, size);
            let want: Vec<_> = full
                .iter()
                .skip(start as usize)
                .take(size as usize)
                .cloned()
                .collect();
            assert_eq!(keys(&got), keys(&want), "start {start} size {size}");
        }
    }
}

// MARK: PlexFilesTests (PlexFilesTests.swift:6)

const SPLIT: &str = r#"{"MediaContainer":{"size":1,"Metadata":[{
  "ratingKey":"9","type":"movie","title":"Geteilt","duration":7200000,
  "Media":[
    {"id":11,"duration":7200000,"container":"mkv","Part":[
      {"id":101,"key":"/library/parts/101/1/file.mkv","duration":3600000,"file":"/m/Geteilt cd1.mkv","size":10,"container":"mkv",
       "Stream":[{"id":1,"streamType":1,"codec":"h264","height":1080}]},
      {"id":102,"key":"/library/parts/102/1/file.mkv","duration":3600000,"size":11,"container":"mkv",
       "Stream":[{"id":2,"streamType":1,"codec":"h264","height":1080}]}]},
    {"id":12,"duration":7200000,"container":"mp4","Part":[
      {"id":103,"key":"/library/parts/103/1/file.mp4","duration":7200000,"file":"/m/Geteilt 720.mp4","size":5,"container":"mp4",
       "Stream":[{"id":3,"streamType":1,"codec":"h264","height":720}]}]},
    {"id":13,"Part":[]}]
}]}}"#;

#[test] // sources, :26
fn files_are_versions() {
    let item = PlexMapper::new().item(&decode_metadata(SPLIT));
    let sources = item.media_sources.expect("sources");
    let ids: Vec<_> = sources
        .iter()
        .map(|s| s.id.clone().unwrap_or_default())
        .collect();
    assert_eq!(ids, ["11", "11-2", "12"]);
    assert_eq!(sources[0].name.as_deref(), Some("Geteilt cd1.mkv"));
    assert!(!sources[1].name.clone().unwrap_or_default().is_empty());
    assert_eq!(sources[2].name.as_deref(), Some("Geteilt 720.mp4"));
    // `MediaVersions.choices` counts three as well: every source has an id.
    assert_eq!(sources.len(), 3);
}

#[test] // plan, :38
fn files_plan() {
    let playback = PlexPlayback::new(Url::parse("http://h:32400").expect("url"), "T");
    let m = decode_metadata(SPLIT);
    let plan = |id: Option<&str>| playback.plan(&m, id, None, None, "S").expect("plan");
    assert!(plan(None).url.contains("/library/parts/101/"));
    let second = plan(Some("11-2"));
    assert!(second.url.contains("/library/parts/102/"));
    assert_eq!(second.media_source_id.as_deref(), Some("11-2"));
    assert_eq!(second.source.and_then(|s| s.id).as_deref(), Some("11-2"));
    assert!(plan(Some("12")).url.contains("/library/parts/103/"));
    // An unknown id falls back to the first file instead of failing.
    assert_eq!(plan(Some("99")).media_source_id.as_deref(), Some("11"));
    assert_eq!(
        PlexPlayback::part(&m, Some("11-2")).map(|p| p.id),
        Some(102)
    );
}

#[test] // extras, :60
fn extras_and_trailers() {
    let body = r#"{"MediaContainer":{"size":3,"Metadata":[
      {"ratingKey":"50","type":"clip","subtype":"trailer","title":"Trailer","duration":1000,
       "Media":[{"id":5,"Part":[{"id":50,"key":"/library/parts/50/1/file.mp4","container":"mp4"}]}]},
      {"ratingKey":"51","type":"clip","subtype":"behindTheScenes","title":"Making of","duration":2000,
       "Media":[{"id":6,"Part":[{"id":51,"key":"/library/parts/51/1/file.mp4","container":"mp4"}]}]},
      {"ratingKey":"52","type":"clip","subtype":"trailer","title":"Online"}]}}"#;
    let stub = Stub::always(200, body);
    let c = client_for(&stub);
    let trailers = block_on(MediaServer::trailer(&c, "9")).expect("trailers");
    assert_eq!(ids(&trailers), ["50"]);
    let extras = block_on(MediaServer::extras(&c, "9")).expect("extras");
    assert_eq!(ids(&extras), ["51"]);
    assert_eq!(extras[0].media_type.as_deref(), Some("Video"));
    assert_eq!(stub.requests()[0].url.path(), "/library/metadata/9/extras");
    let gone = client_for(&Stub::always(404, ""));
    assert!(
        block_on(MediaServer::extras(&gone, "9"))
            .expect("extras")
            .is_empty()
    );
}

#[test] // tokenRejected, :83
fn token_rejected() {
    let c = client_for(&Stub::always(401, ""));
    let told = counter();
    let t = Arc::clone(&told);
    c.on_unauthorized(Some(Arc::new(move || {
        next(&t);
    })));
    let rejected = Err(PlexError::Request(ErrorKind::NotAuthenticated));
    assert_eq!(block_on(c.sections()).map(|_| ()), rejected);
    assert_eq!(block_on(c.sections()).map(|_| ()), rejected);
    assert_eq!(count(&told), 1);
    c.unauthorized_handled();
    assert_eq!(block_on(c.sections()).map(|_| ()), rejected);
    assert_eq!(count(&told), 2);
}

#[test] // downloadAudioHidden, :99
fn download_audio_hidden() {
    let c = client_for(&Stub::always(200, ""));
    let defaults = block_on(MediaServer::account_defaults(&c)).expect("defaults");
    assert!(!defaults.download_quality_selectable());
}

// MARK: PlexMediaServerTests (PlexServerTests.swift:21)

fn library_server() -> (PlexClient<Stub>, Arc<Stub>) {
    let stub = Stub::new(|r| match r.url.path() {
        "/library/sections" => (200, SECTIONS.into()),
        "/library/sections/1/all" | "/library/sections/2/all" => (200, PAGE.into()),
        "/library/metadata/1" => (200, MOVIE.into()),
        "/:/timeline" => (200, String::new()),
        _ => (404, String::new()),
    });
    (client_for(&stub), stub)
}

#[test] // identityAndHelpers, :46
fn identity_and_capabilities() {
    let (c, _) = library_server();
    assert_eq!(MediaServer::kind(&c), ServerKind::Plex);
    assert_eq!(MediaServer::capabilities(&c), PlexFeatures::capabilities());
    let missing = PlexFeatures::missing();
    for gone in [
        ServerCapability::QuickConnect,
        ServerCapability::SyncPlay,
        ServerCapability::RemoteControl,
        ServerCapability::PlayOnOtherDevice,
        ServerCapability::SettingsSync,
    ] {
        assert!(!MediaServer::capabilities(&c).contains(&gone));
        assert!(missing.contains(&gone));
    }
    assert!(
        PlexFeatures::capabilities()
            .iter()
            .all(|c| !missing.contains(c))
    );
    // `as? QuickSignIn` etc.: the Rust client simply does not implement those traits.
}

#[test] // libraries, :60
fn libraries() {
    let (c, _) = library_server();
    let views = block_on(MediaServer::user_views(&c, false)).expect("views");
    // The music library is not shown: the app plays films and series.
    assert_eq!(ids(&views), ["1", "2"]);
    let page = block_on(MediaServer::items(
        &c,
        &ItemsQuery {
            limit: 5,
            ..ItemsQuery::default()
        },
    ))
    .expect("page");
    assert!(!page.items.is_empty());
    assert!(page.total_record_count >= page.items.len() as i64);
    let one = block_on(MediaServer::items(
        &c,
        &ItemsQuery {
            parent_id: Some("1".into()),
            limit: 5,
            ..ItemsQuery::default()
        },
    ))
    .expect("page");
    assert_eq!(ids(&one.items), ["10", "11"]);
    assert_eq!(
        block_on(MediaServer::item(&c, "1")).expect("item").name,
        "Testfilm"
    );
}

#[test] // unsupported, :80
fn unsupported() {
    let (c, stub) = library_server();
    assert!(block_on(MediaServer::library_shares(&c, &[])).is_empty());
    let err = block_on(MediaServer::authenticate(&c, "u", "p")).expect_err("unsupported");
    assert_eq!(PlexError::from_kind(err), PlexError::Unsupported);
    let defaults = block_on(MediaServer::account_defaults(&c)).expect("defaults");
    assert_eq!(defaults.convert_allowed, Some(false));
    assert!(stub.requests().is_empty());
}

#[test] // playback, :93
fn playback_and_reports() {
    let (c, stub) = library_server();
    let plan = block_on(MediaServer::playback_plan(
        &c,
        "1",
        &DeviceProfile::vlc(40_000_000),
        None,
        None,
        None,
    ))
    .expect("plan")
    .expect("some");
    assert_eq!(plan.method, swiftly_model::DeliveryMethod::DirectPlay);
    assert!(plan.url.contains("X-Plex-Token=TOK"));
    block_on(async {
        MediaServer::report_start(&c, "1", &plan, 0, TrackIndices::default())
            .await
            .expect("ok");
        MediaServer::report_progress(&c, "1", &plan, 100_000_000, false, TrackIndices::default())
            .await
            .expect("ok");
        MediaServer::report_stopped(&c, "1", &plan, 200_000_000)
            .await
            .expect("ok");
    });
    let timeline: Vec<_> = stub
        .requests()
        .into_iter()
        .filter(|r| r.url.path() == "/:/timeline")
        .collect();
    assert_eq!(timeline.len(), 3);
    let states: Vec<_> = timeline
        .iter()
        .map(|r| {
            r.url
                .query_pairs()
                .find(|(k, _)| k == "state")
                .map(|(_, v)| v.to_string())
                .unwrap_or_default()
        })
        .collect();
    assert_eq!(states, ["playing", "playing", "stopped"]);
}

#[test] // late, :113
fn late_report() {
    let (c, stub) = library_server();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let report = PendingReport::new("1", "plex-MACHINE1-42", 300_000_000, now + 60.0);
    let done = block_on(MediaServer::report_later(&c, std::slice::from_ref(&report)));
    assert_eq!(done, [report.id()]);
    assert!(
        stub.requests()
            .iter()
            .any(|r| r.url.path() == "/:/timeline")
    );
}

fn plex_session(machine: &str, host: &str, user: &str) -> PlexAccountSession {
    PlexAccountSession {
        session: Session {
            access_token: "SERVERTOKEN".into(),
            user_id: user.into(),
            user_name: "Ann".into(),
            server_url: format!("http://{host}:32400"),
            kind: ServerKind::Plex,
        },
        plex: Some(PlexSessionDetails {
            is_local: true,
            ..PlexSessionDetails::new(machine, "Home", "ACCOUNT")
        }),
    }
}

#[test] // accountState, :124
fn account_state() {
    let stub = Stub::always(200, "");
    let c = PlexClient::from_session(
        &plex_session("MACHINE1", "plex.test", "42"),
        identity(),
        stub,
        None,
    )
    .expect("client");
    assert_eq!(
        c.current_session().map(|s| s.session.user_id),
        Some("42".into())
    );
    block_on(MediaServer::sign_off(&c));
    assert!(c.current_session().is_none());
    let bare = client_for(&Stub::always(200, ""));
    assert!(bare.current_session().is_none());
}

// MARK: PlexSessionTests (PlexServerTests.swift:150)

#[test] // roundTrip, :153
fn session_round_trip() {
    let session = plex_session("MACHINE1", "plex.test", "42");
    let back =
        PlexAccountSession::from_json(&session.to_json().expect("encodes")).expect("decodes");
    assert_eq!(back, session);
    assert!(
        back.plex
            .as_ref()
            .is_some_and(|p| p.machine_identifier == "MACHINE1")
            && back.session.kind == ServerKind::Plex
    );
    let jelly = Session {
        access_token: "t".into(),
        user_id: "1".into(),
        user_name: "p".into(),
        server_url: "https://j.example.com".into(),
        kind: ServerKind::Jellyfin,
    };
    let text = serde_json::to_string(&jelly).expect("encodes");
    assert!(!text.contains("plex") && !text.contains("kind"));
}

#[test] // lean, :168
fn session_lean() {
    let json = r#"{"accessToken":"t","userID":"1","userName":"p","serverURL":"http://h:32400","kind":"plex",
     "plex":{"machineIdentifier":"M","accountToken":"A"}}"#;
    let back = PlexAccountSession::from_json(json).expect("decodes");
    assert_eq!(back.plex, Some(PlexSessionDetails::new("M", "", "A")));
}

#[test] // accountKey, :178
fn account_key() {
    let home = plex_session("MACHINE1", "192.168.1.5", "42");
    let away = plex_session("MACHINE1", "84-1-2-3.abc.plex.direct", "42");
    assert_eq!(home.account_key(), "plex:MACHINE1|42");
    assert_eq!(away.account_key(), home.account_key());
    assert_ne!(
        plex_session("MACHINE2", "192.168.1.5", "42").account_key(),
        home.account_key()
    );
}

#[test] // perServerKeys, :193
fn per_server_keys() {
    assert_eq!(
        identity_of_address("https://Server.example.com/"),
        "https://server.example.com"
    );
    let one = plex_session("A", "h", "42");
    let two = plex_session("B", "h", "42");
    assert_eq!(one.server_suffix(), "|plex:A");
    assert_eq!(one.storage_account(), "plex-A-42");
    assert_ne!(one.storage_account(), two.storage_account());
    assert_ne!(one.server_identity(), two.server_identity());
}

// MARK: PlexReconnectTests (PlexServerTests.swift:225)

fn route(host: &str, local: bool, relay: bool) -> PlexResolvedRoute {
    PlexResolvedRoute {
        connection: PlexChosenConnection {
            machine_identifier: "MACHINE1".into(),
            uri: format!("http://{host}:32400"),
            is_local: local,
            is_relay: relay,
        },
        token: "NEWTOKEN".into(),
    }
}

fn hosts(dead: &'static str, alive: &'static str) -> Arc<Stub> {
    Stub::new(move |r| {
        if r.url.host_str() == Some(dead) {
            (503, String::new())
        } else if r.url.host_str() == Some(alive) {
            (200, SECTIONS.into())
        } else {
            (404, String::new())
        }
    })
}

fn resolver(
    calls: Arc<std::sync::atomic::AtomicUsize>,
    to: PlexResolvedRoute,
    yielding: bool,
) -> Resolver {
    Arc::new(move |details: PlexSessionDetails| {
        assert_eq!(details.machine_identifier, "MACHINE1");
        next(&calls);
        let to = to.clone();
        Box::pin(async move {
            if yielding {
                yield_now().await;
            }
            Ok(to)
        })
    })
}

#[test] // switchesOnError, :235
fn switches_on_error() {
    let stub = hosts("dead.test", "alive.test");
    let calls = counter();
    let c = PlexClient::from_session(
        &plex_session("MACHINE1", "dead.test", "42"),
        identity(),
        Arc::clone(&stub),
        Some(resolver(
            Arc::clone(&calls),
            route("alive.test", false, true),
            false,
        )),
    )
    .expect("client");
    let told = counter();
    let seen: Arc<Mutex<Option<PlexAccountSession>>> = Arc::new(Mutex::new(None));
    let (t, s) = (Arc::clone(&told), Arc::clone(&seen));
    c.on_session_change(Some(Arc::new(move |session| {
        next(&t);
        if let Ok(mut g) = s.lock() {
            *g = Some(session);
        }
    })));
    let views = block_on(c.views()).expect("views");
    assert_eq!(views.len(), 2);
    assert!(count(&calls) == 1 && count(&told) == 1);
    assert_eq!(c.base_url().host_str(), Some("alive.test"));
    let moved = seen.lock().expect("lock").clone().expect("told");
    assert!(
        moved.session.server_url.contains("alive.test") && moved.session.access_token == "NEWTOKEN"
    );
    assert!(
        moved
            .plex
            .as_ref()
            .is_some_and(|p| p.is_relay && !p.is_local)
    );
    assert_eq!(
        moved.account_key(),
        plex_session("MACHINE1", "x", "42").account_key()
    );
    // The old address was asked once, the new one answered.
    assert_eq!(stub.on_host("dead.test").len(), 1);
    assert_eq!(stub.on_host("alive.test").len(), 1);
}

#[test] // singleFlight, :264
fn single_flight() {
    let stub = hosts("dead.test", "alive.test");
    let calls = counter();
    let c = PlexClient::from_session(
        &plex_session("MACHINE1", "dead.test", "42"),
        identity(),
        stub,
        Some(resolver(
            Arc::clone(&calls),
            route("alive.test", false, false),
            true,
        )),
    )
    .expect("client");
    let results = block_on(join_all((0..4).map(|_| c.views())));
    for r in results {
        assert_eq!(r.expect("views").len(), 2);
    }
    assert_eq!(count(&calls), 1);
}

#[test] // noSwitchForAnswers, :286
fn no_switch_for_answers() {
    let stub = Stub::always(401, "");
    let calls = counter();
    let c = PlexClient::from_session(
        &plex_session("MACHINE1", "stub.test", "42"),
        identity(),
        stub,
        Some(resolver(
            Arc::clone(&calls),
            route("elsewhere.test", false, false),
            false,
        )),
    )
    .expect("client");
    assert_eq!(
        block_on(c.views()).err(),
        Some(PlexError::Request(ErrorKind::NotAuthenticated))
    );
    assert_eq!(count(&calls), 0);
    let http = |status| PlexError::Request(ErrorKind::Http { status, body: None });
    assert!(!PlexClient::<Stub>::is_route_problem(&http(404)));
    assert!(PlexClient::<Stub>::is_route_problem(&http(502)));
}

#[test] // withoutAccount, :302
fn without_account() {
    let stub = Stub::always(503, "");
    let c = client_for(&stub);
    assert!(block_on(c.views()).is_err());
    assert_eq!(stub.requests().len(), 1);
}

#[test] // nothingFound, :311
fn nothing_found() {
    let resolver: Resolver = Arc::new(|_| Box::pin(async { Err(PlexError::ServerUnreachable) }));
    let c = PlexClient::from_session(
        &plex_session("MACHINE1", "stub.test", "42"),
        identity(),
        Stub::always(503, ""),
        Some(resolver),
    )
    .expect("client");
    assert_eq!(
        block_on(c.views()).err(),
        Some(PlexError::ServerUnreachable)
    );
}

#[test] // chooseBest, :321
fn choose_best() {
    let stub = Stub::always(200, "");
    let c = PlexClient::from_session(
        &plex_session("MACHINE1", "stub.test", "42"),
        identity(),
        stub,
        Some(resolver(counter(), route("home.test", true, false), false)),
    )
    .expect("client");
    assert_eq!(block_on(c.choose_best_connection()), Ok(true));
    assert_eq!(c.base_url().host_str(), Some("home.test"));
    assert_eq!(block_on(c.choose_best_connection()), Ok(false));
}

// Mock version of PlexRouteTests.staleRoute (:8, live in Swift): a silent stored address makes
// the first request move over after the silence limit.
#[test]
fn stale_route_moves_after_silence() {
    use swiftly_net::{HttpRequest, HttpResponse};
    struct Silent(Arc<Stub>);
    impl swiftly_net::HttpTransport for Silent {
        async fn send(&self, r: HttpRequest) -> Result<HttpResponse, ErrorKind> {
            if r.url.host_str() == Some("dead.test") {
                // Never answers.
                std::future::pending::<()>().await;
            }
            self.0.send(r).await
        }
    }
    let transport = Arc::new(Silent(hosts("none.test", "alive.test")));
    let c = PlexClient::from_session(
        &plex_session("MACHINE1", "dead.test", "42"),
        identity(),
        transport,
        Some(resolver(counter(), route("alive.test", true, false), false)),
    )
    .expect("client")
    .with_sleep(Arc::new(|_| nap(std::time::Duration::from_millis(20))));
    let views = block_on(c.views()).expect("views");
    assert_eq!(views.len(), 2);
    assert_eq!(c.base_url().host_str(), Some("alive.test"));
}
