#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Translation of `PlexTests.swift` (43 tests). Each test names its Swift counterpart.
mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use futures_executor::block_on;
use swiftly_library::library_filter::{LibraryFilter, Sorting};
use swiftly_model::{ColorRange, DeliveryMethod};
use swiftly_net::Method;
use swiftly_playback::media_server::ServerCapability;
use swiftly_plex::*;
use url::Url;

fn mapper() -> PlexMapper {
    PlexMapper::new()
}

// MARK: Wire and mapping (PlexMappingTests, PlexTests.swift:66)

#[test] // movie, :69
fn movie() {
    let item = mapper().item(&decode_metadata(MOVIE));
    assert_eq!(item.id, "1");
    assert_eq!(item.type_.as_deref(), Some("Movie"));
    assert_eq!(item.production_year, Some(2020)); // arrived as text
    assert_eq!(item.official_rating.as_deref(), Some("12")); // "de/" dropped
    assert_eq!(item.community_rating, Some(7.5));
    assert_eq!(item.critic_rating, Some(80.0));
    assert_eq!(item.run_time_ticks, Some(900_230_000));
    let data = item.user_data.as_ref().expect("user data");
    assert_eq!(data.playback_position_ticks, Some(450_110_000));
    assert_eq!(data.played, Some(false));
    assert_eq!(data.is_favorite, Some(true));
    assert!((data.played_percentage.expect("percent") - 50.0).abs() < 0.1);
    let providers = item.provider_ids.as_ref().expect("providers");
    assert_eq!(providers.len(), 3);
    assert_eq!(providers["Imdb"], "tt0133093");
    assert_eq!(providers["Tmdb"], "603");
    assert_eq!(providers["Tvdb"], "78804");
    assert_eq!(item.premiere_date.as_deref(), Some("2020-01-25T00:00:00Z"));
    let tags = item.image_tags.as_ref().expect("images");
    assert_eq!(tags["Primary"], "/library/metadata/1/thumb/17");
    assert_eq!(tags["Logo"], "/library/metadata/1/clearLogo/17");
    assert_eq!(
        item.backdrop_image_tags,
        Some(vec!["/library/metadata/1/art/17".to_string()])
    );
    assert_eq!(item.genres, Some(vec!["Action".to_string()]));
    assert_eq!(item.production_locations, Some(vec!["USA".to_string()]));
    assert_eq!(
        item.studios
            .as_ref()
            .and_then(|s| s.first())
            .and_then(|s| s.name.as_deref()),
        Some("Bonobostudio")
    );
    let kinds: Vec<_> = item
        .people
        .as_ref()
        .expect("people")
        .iter()
        .map(|p| p.type_.clone().unwrap_or_default())
        .collect();
    assert_eq!(kinds, ["Actor", "Director", "Writer"]);
    assert_eq!(item.actors()[0].role.as_deref(), Some("Neo"));
    assert_eq!(item.direction(), ["Bob Director"]);
}

#[test] // sources, :97
fn sources() {
    let item = mapper().item(&decode_metadata(MOVIE));
    let sources = item.media_sources.expect("sources");
    let ids: Vec<_> = sources
        .iter()
        .map(|s| s.id.clone().unwrap_or_default())
        .collect();
    assert_eq!(ids, ["1", "2"]);
    assert!(
        sources
            .iter()
            .all(|s| s.delivery_method() == DeliveryMethod::DirectPlay)
    );
    let first = &sources[0];
    assert_eq!(first.name.as_deref(), Some("Testfilm.mkv"));
    assert_eq!(first.default_audio_stream_index, Some(2));
    assert_eq!(first.default_subtitle_stream_index, Some(5));
    let streams = first.media_streams.as_ref().expect("streams");
    let index: Vec<_> = streams.iter().map(|s| s.index).collect();
    assert_eq!(index, [Some(1), Some(2), Some(3), Some(4), Some(5)]);
    let types: Vec<_> = streams
        .iter()
        .map(|s| s.type_.clone().unwrap_or_default())
        .collect();
    assert_eq!(types, ["Video", "Audio", "Audio", "Subtitle", "Subtitle"]);
    assert_eq!(streams[0].codec.as_deref(), Some("hevc"));
    assert_eq!(
        streams[0].video_range_type(),
        Some(ColorRange::DolbyVisionHdr10)
    );
    assert_eq!(streams[0].dv_profile(), Some(8));
    assert_eq!(streams[1].language.as_deref(), Some("eng"));
    assert_eq!(streams[1].channels, Some(6));
    assert_eq!(streams[3].is_external, Some(true));
    assert_eq!(streams[3].is_forced, Some(true)); // arrived as "1"
    assert_eq!(
        streams[3].delivery_url.as_deref(),
        Some("/library/streams/4")
    );
    assert_eq!(streams[4].is_external, Some(false)); // inside the container: no key
    assert_eq!(streams[4].delivery_url, None);
}

#[test] // episode, :122
fn episode() {
    let item = mapper().item(&decode_metadata(EPISODE));
    assert_eq!(item.type_.as_deref(), Some("Episode"));
    assert_eq!(item.series_id.as_deref(), Some("3"));
    assert_eq!(item.season_id.as_deref(), Some("4"));
    assert_eq!(item.series_name.as_deref(), Some("Test Show"));
    assert_eq!(item.index_number, Some(2));
    assert_eq!(item.parent_index_number, Some(1));
    assert_eq!(item.user_data.as_ref().and_then(|u| u.played), Some(true));
    assert_eq!(item.parent_backdrop_item_id.as_deref(), Some("3"));
    assert_eq!(
        item.parent_backdrop_image_tags,
        Some(vec!["/library/metadata/3/art/1".to_string()])
    );
    assert_eq!(
        item.series_primary_image_tag.as_deref(),
        Some("/library/metadata/3/thumb/1")
    );
}

#[test] // show, :137
fn show() {
    let item = mapper().item(&decode_metadata(SHOW));
    assert_eq!(item.type_.as_deref(), Some("Series"));
    assert_eq!(item.child_count, Some(2));
    let data = item.user_data.expect("data");
    assert_eq!(data.unplayed_item_count, Some(6));
    assert_eq!(data.played, Some(false));
}

#[test] // lenientList, :146
fn lenient_list() {
    let listing = PlexListing::from_body(PAGE.as_bytes()).expect("decodes");
    let keys: Vec<_> = listing
        .metadata
        .iter()
        .map(|m| m.rating_key.as_str())
        .collect();
    assert_eq!(keys, ["10", "11"]);
    assert_eq!(listing.total_size, Some(7));
    assert_eq!(listing.metadata[1].year, Some(2002));
}

#[test] // markersAndChapters, :155
fn markers_and_chapters() {
    let m = decode_metadata(MOVIE);
    let segments = mapper().segments(&m.markers, m.duration);
    assert_eq!(segments.len(), 2); // "sponsor" dropped
    assert_eq!(
        segments[0].art,
        swiftly_playback::sections::Art::IntroSegment
    );
    assert_eq!(segments[1].art, swiftly_playback::sections::Art::Credits);
    assert!(segments[0].from == 1.0 && segments[0].until == 61.0);
    assert!((segments[1].until - 90.023).abs() < 0.001); // cut to the runtime
    let chapters = mapper().chapters(&m.chapters);
    assert_eq!(chapters.len(), 2);
    assert_eq!(chapters[0].name, "Start");
    assert_eq!(chapters[1].from, 30.0);
    assert!(chapters[1].name.contains('2')); // "Kapitel 2"
}

#[test] // types, :170
fn types() {
    let mapped: Vec<_> = ["movie", "show", "season", "episode", "collection"]
        .iter()
        .map(|t| PlexMapper::item_type(t))
        .collect();
    assert_eq!(mapped, ["Movie", "Series", "Season", "Episode", "BoxSet"]);
    assert_eq!(PlexMapper::plex_type_number("Episode"), Some(4));
    assert_eq!(PlexMapper::plex_type_number("BoxSet"), None);
}

#[test] // views, :178
fn views() {
    let listing = PlexListing::from_body(SECTIONS.as_bytes()).expect("decodes");
    let views: Vec<_> = listing
        .directories
        .iter()
        .map(|s| mapper().view(s))
        .collect();
    let kinds: Vec<_> = views
        .iter()
        .map(|v| v.collection_type.clone().unwrap_or_default())
        .collect();
    assert_eq!(kinds, ["movies", "tvshows", "music"]);
    let ids: Vec<_> = views.iter().map(|v| v.id.as_str()).collect();
    assert_eq!(ids, ["1", "2", "3"]);
}

// MARK: Playback (PlexPlaybackTests, :190)

fn playback() -> PlexPlayback {
    PlexPlayback::new(Url::parse("http://192.168.1.5:32400").expect("url"), "TOK")
}

#[test] // fileAddress, :195
fn file_address() {
    let p = playback();
    assert_eq!(
        p.file_url("/library/parts/1/17/file.mkv", false)
            .expect("url")
            .as_str(),
        "http://192.168.1.5:32400/library/parts/1/17/file.mkv?X-Plex-Token=TOK"
    );
    assert!(
        p.file_url("/library/parts/1/17/file.mkv", true)
            .expect("url")
            .as_str()
            .contains("download=1")
    );
}

#[test] // images, :203
fn images() {
    let p = playback();
    assert_eq!(
        p.image_url("/library/metadata/1/thumb/17", None, None)
            .expect("url")
            .as_str(),
        "http://192.168.1.5:32400/library/metadata/1/thumb/17?X-Plex-Token=TOK"
    );
    assert_eq!(
        p.image_url("/library/metadata/1/thumb/17", Some(480), None)
            .expect("url")
            .as_str(),
        "http://192.168.1.5:32400/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F1%2Fthumb%2F17&upscale=0&width=4096&height=480&quality=90&X-Plex-Token=TOK"
    );
    assert_eq!(
        p.image_url("https://metadata-static.plex.tv/a.jpg", Some(100), None)
            .expect("url")
            .as_str(),
        "https://metadata-static.plex.tv/a.jpg"
    );
}

#[test] // plan, :213
fn plan() {
    let p = playback();
    let m = decode_metadata(MOVIE);
    let plan = p.plan(&m, None, None, None, "S1").expect("plan");
    assert_eq!(plan.method, DeliveryMethod::DirectPlay);
    assert!(plan.reasons.is_empty());
    assert_eq!(plan.media_source_id.as_deref(), Some("1"));
    assert_eq!(plan.play_session_id.as_deref(), Some("S1"));
    assert_eq!(plan.container.as_deref(), Some("mkv"));
    assert!(
        plan.url
            .ends_with("/library/parts/1/1793487178/file.mkv?X-Plex-Token=TOK")
    );
    assert!(!plan.url.contains("transcode"));

    let other = p.plan(&m, Some("2"), Some(3), Some(4), "S2").expect("plan");
    assert_eq!(other.media_source_id.as_deref(), Some("2"));
    assert!(other.url.contains("/library/parts/2/"));
    let source = other.source.expect("source");
    assert_eq!(source.default_audio_stream_index, Some(3));
    assert_eq!(source.default_subtitle_stream_index, Some(4));
}

#[test] // noFile, :232
fn no_file() {
    let m = decode_metadata(SHOW);
    assert_eq!(
        playback().plan(&m, None, None, None, "S").err(),
        Some(PlexError::NoFile)
    );
}

#[test] // subtitles, :238
fn subtitles() {
    let m = decode_metadata(MOVIE);
    let streams = &m.media[0].parts[0].streams;
    let p = playback();
    assert_eq!(
        p.subtitle_url(&streams[3]).expect("url").as_str(),
        "http://192.168.1.5:32400/library/streams/4?X-Plex-Token=TOK"
    );
    assert!(p.subtitle_url(&streams[4]).is_none());
    assert!(p.subtitle_url(&streams[1]).is_none());
}

#[test] // timeline, :248
fn timeline() {
    let q = PlexPlayback::timeline_query("7", TimelineState::Paused, 123_450_000, Some(90_000));
    let get = |k: &str| q.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
    assert_eq!(get("time").as_deref(), Some("12345"));
    assert_eq!(get("state").as_deref(), Some("paused"));
    assert_eq!(get("key").as_deref(), Some("/library/metadata/7"));
    assert_eq!(get("duration").as_deref(), Some("90000"));
}

fn bif(pictures: &[(u32, &[u8])], multiplier: u32) -> Vec<u8> {
    let le = |v: u32| v.to_le_bytes().to_vec();
    let mut out = vec![0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A];
    out.extend(le(0));
    out.extend(le(pictures.len() as u32));
    out.extend(le(multiplier));
    out.extend([0u8; 44]);
    let mut offset = 64 + (pictures.len() as u32 + 1) * 8;
    let (mut table, mut body) = (Vec::new(), Vec::new());
    for (ms, bytes) in pictures {
        let unit = if multiplier == 0 { 1000 } else { multiplier };
        table.extend(le(ms / unit));
        table.extend(le(offset));
        body.extend(*bytes);
        offset += bytes.len() as u32;
    }
    table.extend(le(0xFFFF_FFFF));
    table.extend(le(offset));
    [out, table, body].concat()
}

#[test] // bifLookup, :278
fn bif_lookup() {
    let file = PlexBif::parse(&bif(
        &[(0, &[1, 1, 1]), (10_000, &[2, 2]), (20_000, &[3])],
        0,
    ))
    .expect("bif");
    let ms: Vec<_> = file.frames.iter().map(|f| f.milliseconds).collect();
    assert_eq!(ms, [0, 10_000, 20_000]);
    assert_eq!(file.image_at_seconds(0.0), Some(vec![1, 1, 1]));
    assert_eq!(file.image_at_seconds(9.9), Some(vec![1, 1, 1]));
    assert_eq!(file.image_at_seconds(10.0), Some(vec![2, 2]));
    assert_eq!(file.image_at_seconds(15.0), Some(vec![2, 2]));
    assert_eq!(file.image_at_seconds(9_999.0), Some(vec![3]));
    assert_eq!(file.image_at_seconds(-4.0), Some(vec![1, 1, 1]));
    assert_eq!(file.image_at_seconds(f64::NAN), None);
    assert_eq!(file.interval(), 10_000);
}

// F-cast-01: time word times multiplier, both up to 2^32, does not fit an i64.
#[test]
fn bif_hostile_multiplier_saturates() {
    let mut data = bif(&[(4_000_000_000, &[1]), (4_000_000_001, &[2])], 1);
    data[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
    let file = PlexBif::parse(&data).expect("bif");
    assert_eq!(file.frames[0].milliseconds, i64::MAX);
    assert_eq!(file.interval(), 0);
    assert_eq!(file.image_at_seconds(1e30), Some(vec![2]));
}

#[test] // bifBad, :291
fn bif_bad() {
    assert!(PlexBif::parse(&[]).is_none());
    assert!(PlexBif::parse(&[0u8; 100]).is_none());
    let good = bif(&[(0, &[1, 1, 1]), (10_000, &[2, 2])], 0);
    assert!(PlexBif::parse(&good[..good.len() - 2]).is_none());
    assert!(PlexBif::parse(&good[..70]).is_none());
}

// MARK: Capabilities (PlexFeaturesTests, :303)

#[test] // list, :305
fn features() {
    use ServerCapability::*;
    let can = PlexFeatures::capabilities();
    for no in [
        SyncPlay,
        QuickConnect,
        RemoteControl,
        SettingsSync,
        PlayOnOtherDevice,
        PublicUsers,
        Seerr,
    ] {
        assert!(!can.contains(&no));
    }
    for yes in [
        IntroSegments,
        Chapters,
        Downloads,
        Favorites,
        MarkWatched,
        Collections,
        Playlists,
        Trickplay,
    ] {
        assert!(can.contains(&yes));
    }
    let mut all = can.clone();
    all.extend(PlexFeatures::missing());
    all.sort();
    assert_eq!(all, ServerCapability::ALL.to_vec());
}

// MARK: plex.tv (PlexAccountTests, :322)

fn service(stub: &Arc<Stub>) -> PlexAccountService<Stub> {
    PlexAccountService::with_bases(
        identity(),
        Arc::clone(stub),
        "http://stub.test",
        "http://stub.test",
        "https://app.plex.tv",
    )
}

#[test] // authURL, :331
fn auth_url() {
    let svc = PlexAccountService::new(identity(), Stub::always(200, "{}"));
    let url = svc
        .auth_url(&PlexPin::new(1, "ABCD1234"), None)
        .expect("url");
    assert_eq!(
        url.as_str(),
        "https://app.plex.tv/auth#?clientID=cid&code=ABCD1234&context%5Bdevice%5D%5Bproduct%5D=Swiftly%20Player"
    );
}

#[test] // startPin, :339
fn start_pin() {
    let stub = Stub::always(201, PIN_FRESH);
    let pin = block_on(service(&stub).start_pin(true)).expect("pin");
    assert!(pin.id == 4711 && pin.code == "ABCD1234" && pin.auth_token.is_none());
    let req = &stub.requests()[0];
    assert_eq!(req.method, Method::Post);
    assert_eq!(req.url.path(), "/api/v2/pins");
    assert_eq!(req.url.query(), Some("strong=true"));
    assert_eq!(
        header(req, "X-Plex-Client-Identifier").as_deref(),
        Some("cid")
    );
    assert_eq!(
        header(req, "X-Plex-Product").as_deref(),
        Some("Swiftly Player")
    );
    assert_eq!(header(req, "Accept").as_deref(), Some("application/json"));
    assert_eq!(header(req, "X-Plex-Token"), None);
}

#[test] // waitForToken, :354
fn wait_for_token() {
    let calls = counter();
    let c = Arc::clone(&calls);
    let stub = Stub::new(move |_| {
        if next(&c) < 3 {
            (200, PIN_FRESH.into())
        } else {
            (200, PIN_DONE.into())
        }
    });
    let token = block_on(service(&stub).await_token(
        &PlexPin::new(4711, "ABCD1234"),
        Duration::from_millis(5),
        Duration::from_secs(5),
        &sleeper(),
    ))
    .expect("token");
    assert_eq!(token, "ACCOUNTTOKEN");
    assert_eq!(count(&calls), 3);
    assert_eq!(stub.requests()[0].url.path(), "/api/v2/pins/4711");
}

#[test] // waitSurvivesOneHiccup, :367
fn wait_survives_one_hiccup() {
    let calls = counter();
    let c = Arc::clone(&calls);
    let stub = Stub::new(move |_| match next(&c) {
        1 => (503, String::new()),
        2 => (200, PIN_FRESH.into()),
        _ => (200, PIN_DONE.into()),
    });
    let token = block_on(service(&stub).await_token(
        &PlexPin::new(4711, "ABCD1234"),
        Duration::from_millis(5),
        Duration::from_secs(5),
        &sleeper(),
    ))
    .expect("token");
    assert_eq!(token, "ACCOUNTTOKEN");
}

#[test] // expired, :382
fn expired() {
    let gone = Stub::always(404, "");
    let r = block_on(service(&gone).await_token(
        &PlexPin::new(1, "X"),
        Duration::from_millis(5),
        Duration::from_secs(5),
        &sleeper(),
    ));
    assert_eq!(r, Err(PlexError::PinExpired));
    let slow = Stub::always(200, PIN_FRESH);
    let r = block_on(service(&slow).await_token(
        &PlexPin::new(1, "X"),
        Duration::from_millis(5),
        Duration::from_millis(30),
        &sleeper(),
    ));
    assert_eq!(r, Err(PlexError::PinExpired));
}

#[test] // validate, :396
fn validate() {
    let ok = Stub::always(200, r#"{"id":7,"title":"Paul","uuid":"u"}"#);
    match block_on(service(&ok).validate("t")).expect("state") {
        TokenState::Valid(user) => assert!(user.title == "Paul" && user.id == "7"),
        TokenState::Invalid => panic!("expected valid"),
    }
    let no = Stub::always(401, "");
    assert_eq!(
        block_on(service(&no).validate("t")),
        Ok(TokenState::Invalid)
    );
    let down = Stub::always(500, "");
    assert!(block_on(service(&down).validate("t")).is_err());
}

#[test] // servers, :412
fn servers() {
    let stub = Stub::always(200, RESOURCES);
    let list = block_on(service(&stub).servers("acct")).expect("servers");
    let machines: Vec<_> = list.iter().map(|s| s.machine_identifier.as_str()).collect();
    assert_eq!(machines, ["MACHINE1", "MACHINE2"]);
    assert_eq!(list[0].access_token.as_deref(), Some("SERVERTOKEN"));
    assert!(list[0].owned && !list[1].owned);
    let c = &list[0].connections;
    assert_eq!(c.len(), 4);
    assert!(c[0].is_local && !c[0].is_https && !c[0].is_relay);
    assert!(c[1].is_https && c[1].is_local);
    assert!(!c[2].is_local && !c[2].is_relay);
    assert!(c[3].is_relay);
    let req = &stub.requests()[0];
    assert_eq!(header(req, "X-Plex-Token").as_deref(), Some("acct"));
    assert!(req.url.query().unwrap_or("").contains("includeRelay=1"));
}

#[test] // home, :430
fn home() {
    let stub = Stub::new(|r| match r.url.path() {
        "/api/v2/home/users" => (200, HOME_USERS.into()),
        "/api/v2/home/users/uuid-kid/switch" => {
            if r.url.query() == Some("pin=1234") {
                (201, r#"{"authToken":"KIDTOKEN"}"#.into())
            } else {
                (401, String::new())
            }
        }
        _ => (404, String::new()),
    });
    let svc = service(&stub);
    let users = block_on(svc.home_users("acct")).expect("users");
    let titles: Vec<_> = users.iter().map(|u| u.title.as_str()).collect();
    assert_eq!(titles, ["Owner", "Kid"]);
    assert!(users[1].is_protected && users[1].is_restricted && !users[1].is_admin);
    assert_eq!(
        block_on(svc.switch_user(&users[1], Some("1234"), "acct")),
        Ok("KIDTOKEN".into())
    );
    assert_eq!(
        block_on(svc.switch_user(&users[1], Some("0000"), "acct")),
        Err(PlexError::ProfilePinWrong)
    );
    assert_eq!(stub.requests().last().expect("seen").method, Method::Post);
}

#[test] // headerSafe, :450
fn header_safe() {
    let id = PlexIdentity::new("c", "1", "iOS", "iPhone", "Pauls\nGerät");
    let headers = id.headers(None, None);
    let name = headers
        .iter()
        .find(|(n, _)| n == "X-Plex-Device-Name")
        .expect("header");
    assert_eq!(name.1, "PaulsGerät");
    assert_ne!(
        PlexIdentity::make_client_id(),
        PlexIdentity::make_client_id()
    );
}

// MARK: Which address (PlexConnectionTests, :461)

fn conn(uri: &str, local: bool, relay: bool, https: bool, v6: bool) -> PlexConnectionInfo {
    PlexConnectionInfo::new(uri, https, local, relay, v6)
}

fn set() -> Vec<PlexConnectionInfo> {
    vec![
        conn("https://relay", false, true, true, false),
        conn("https://remote", false, false, true, false),
        conn("https://local-s", true, false, true, false),
        conn("http://local", true, false, false, false),
        conn("https://local-6", true, false, true, true),
    ]
}

fn uris(list: &[PlexConnectionInfo]) -> Vec<&str> {
    list.iter().map(|c| c.uri.as_str()).collect()
}

fn server(connections: Vec<PlexConnectionInfo>) -> PlexServerResource {
    let json = serde_json::json!({
        "clientIdentifier": "M", "name": "S", "provides": "server", "owned": true,
        "connections": serde_json::to_value(&connections).expect("encodes"),
    });
    PlexServerResource::parse(&json).expect("server")
}

#[test] // order, :478
fn order() {
    assert_eq!(
        uris(&PlexConnector::ranked(&set(), false, None)),
        [
            "http://local",
            "https://local-s",
            "https://local-6",
            "https://remote",
            "https://relay"
        ]
    );
}

#[test] // httpsRequired, :484
fn https_required() {
    let ranked = PlexConnector::ranked(&set(), true, None);
    let order = uris(&ranked);
    assert_eq!(order[0], "https://local-s");
    let at = |u: &str| order.iter().position(|x| *x == u).expect("present");
    assert!(at("http://local") > at("https://local-6"));
}

#[test] // remembered, :491
fn remembered() {
    let ranked = PlexConnector::ranked(&set(), false, Some("https://remote"));
    assert_eq!(ranked[0].uri, "https://remote");
}

fn connector(
    probe: impl Fn(&str) -> (bool, Duration) + Send + Sync + 'static,
    grace: Duration,
) -> PlexConnector {
    let probe: Probe = Arc::new(move |c: PlexConnectionInfo| {
        let (answer, delay) = probe(&c.uri);
        Box::pin(async move {
            nap(delay).await;
            answer
        })
    });
    PlexConnector::new(grace, sleeper(), probe)
}

#[test] // bestAnswering, :505
fn best_answering() {
    let c = connector(
        |uri| match uri {
            "http://local" | "https://local-s" | "https://local-6" => (false, Duration::ZERO),
            "https://remote" => (true, Duration::from_millis(60)),
            _ => (true, Duration::ZERO), // the relay answers at once
        },
        PlexConnector::GRACE,
    );
    let chosen = block_on(c.choose(&server(set()), None)).expect("chosen");
    assert_eq!(chosen.uri, "https://remote");
    assert!(!chosen.is_local && !chosen.is_relay);
}

#[test] // doesNotWait, :522
fn does_not_wait() {
    let started = Instant::now();
    let c = connector(
        |uri| {
            (
                true,
                if uri == "http://local" {
                    Duration::ZERO
                } else {
                    Duration::from_secs(10)
                },
            )
        },
        PlexConnector::GRACE,
    );
    let chosen = block_on(c.choose(&server(set()), None)).expect("chosen");
    assert!(chosen.uri == "http://local" && chosen.is_local);
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test] // graceEnds, :535
fn grace_ends() {
    let started = Instant::now();
    let c = connector(
        |uri| match uri {
            "http://local" | "https://local-s" | "https://local-6" => {
                (false, Duration::from_secs(10))
            } // a dead LAN address
            _ => (true, Duration::ZERO),
        },
        Duration::from_millis(200),
    );
    let chosen = block_on(c.choose(&server(set()), None)).expect("chosen");
    assert_eq!(chosen.uri, "https://remote");
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test] // none, :550
fn none_answers() {
    let c = connector(|_| (false, Duration::ZERO), PlexConnector::GRACE);
    assert_eq!(
        block_on(c.choose(&server(set()), None)),
        Err(PlexError::ServerUnreachable)
    );
    assert_eq!(
        block_on(c.choose(&server(vec![]), None)),
        Err(PlexError::ServerUnreachable)
    );
}

#[test] // rememberedFirst, :561
fn remembered_first() {
    let asked = counter();
    let a = Arc::clone(&asked);
    let probe: Probe = Arc::new(move |_| {
        next(&a);
        Box::pin(async { true })
    });
    let c = PlexConnector::new(PlexConnector::GRACE, sleeper(), probe);
    let memory = PlexChosenConnection {
        machine_identifier: "M".into(),
        uri: "https://remote".into(),
        is_local: false,
        is_relay: false,
    };
    let chosen = block_on(c.choose(&server(set()), Some(&memory))).expect("chosen");
    assert_eq!(chosen.uri, memory.uri);
    assert_eq!(count(&asked), 1);
}

#[test] // probeChecksMachine, :573
fn probe_checks_machine() {
    let stub = Stub::always(200, IDENTITY);
    let base = Url::parse("http://stub.test:32400").expect("url");
    let ask = |machine: &str| {
        block_on(PlexConnector::identity_matches(
            stub.as_ref(),
            &base,
            &identity(),
            "t",
            machine,
            Duration::from_secs(2),
        ))
    };
    assert!(ask("MACHINE1"));
    assert!(!ask("OTHER"));
}

// MARK: Client against a stub server (PlexClientTests, :589)

fn client(stub: &Arc<Stub>) -> PlexClient<Stub> {
    PlexClient::new(
        Url::parse("http://stub.test:32400").expect("url"),
        "TOK",
        identity(),
        Arc::clone(stub),
    )
}

#[test] // list, :599
fn list() {
    let stub = Stub::always(200, PAGE);
    let page = block_on(client(&stub).list(
        "1",
        Some("Series"),
        Sorting::Latest,
        LibraryFilter::Unwatched,
        None,
        50,
        25,
    ))
    .expect("page");
    let ids: Vec<_> = page.items.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids, ["10", "11"]);
    assert_eq!(page.total, 7);
    let req = &stub.requests()[0];
    assert_eq!(req.url.path(), "/library/sections/1/all");
    let query = req.url.query().unwrap_or("");
    assert!(query.contains("sort=addedAt%3Adesc"));
    assert!(query.contains("type=2"));
    assert!(query.contains("unwatched=1"));
    assert_eq!(header(req, "X-Plex-Container-Start").as_deref(), Some("50"));
    assert_eq!(header(req, "X-Plex-Container-Size").as_deref(), Some("25"));
    assert_eq!(header(req, "X-Plex-Token").as_deref(), Some("TOK"));
}

#[test] // filters, :617
fn filters() {
    let stub = Stub::always(200, PAGE);
    let c = client(&stub);
    block_on(c.list(
        "1",
        None,
        Sorting::Name,
        LibraryFilter::Watchlist,
        None,
        0,
        50,
    ))
    .expect("page");
    block_on(c.list("1", None, Sorting::Name, LibraryFilter::Begun, None, 0, 50)).expect("page");
    let queries: Vec<_> = stub
        .requests()
        .iter()
        .map(|r| r.url.query().unwrap_or("").to_string())
        .collect();
    assert!(queries[0].contains("userRating%3E%3E=9"));
    assert!(queries[1].contains("inProgress=1"));
}

#[test] // detail, :627
fn detail() {
    let stub = Stub::always(200, MOVIE);
    let detail = block_on(client(&stub).detail("1")).expect("detail");
    assert_eq!(detail.item.id, "1");
    assert!(detail.segments.len() == 2 && detail.chapters.len() == 2);
    let query = stub.requests()[0].url.query().unwrap_or("").to_string();
    assert!(query.contains("includeMarkers=1") && query.contains("includeChapters=1"));
}

#[test] // writes, :637
fn writes() {
    let stub = Stub::always(200, "");
    let c = client(&stub);
    block_on(async {
        c.set_watched_key("7", true).await.expect("ok");
        c.set_watched_key("7", false).await.expect("ok");
        c.set_favorite("7", true).await.expect("ok");
        c.set_favorite("7", false).await.expect("ok");
        c.report_timeline("7", TimelineState::Playing, 50_000_000, Some(90_000))
            .await
            .expect("ok");
    });
    let seen = stub.requests();
    let line = |i: usize| format!("{} {}", seen[i].method.as_str(), seen[i].url.path());
    assert_eq!(line(0), "PUT /:/scrobble");
    assert_eq!(line(1), "PUT /:/unscrobble");
    assert!(line(2) == "PUT /:/rate" && seen[2].url.query().unwrap_or("").contains("rating=10"));
    assert!(seen[3].url.query().unwrap_or("").contains("rating=-1"));
    assert_eq!(line(4), "POST /:/timeline");
    assert!(seen[4].url.query().unwrap_or("").contains("time=5000"));
    assert_eq!(
        header(&seen[4], "X-Plex-Session-Identifier"),
        Some(c.session_id.clone())
    );
}

#[test] // unauthorized, :657
fn unauthorized() {
    let stub = Stub::always(401, "");
    let c = client(&stub);
    assert_eq!(
        block_on(c.sections()).err(),
        Some(PlexError::Request(swiftly_net::ErrorKind::NotAuthenticated))
    );
    assert_eq!(block_on(c.token_works()), Ok(false));
}

#[test] // additive: the play decision (Swift never asks)
fn direct_play_decision_reads_the_verdict() {
    let stub = Stub::new(|r| {
        assert_eq!(r.url.path(), "/video/:/transcode/universal/decision");
        (
            200,
            r#"{"MediaContainer":{"generalDecisionCode":1000,"directPlayDecisionCode":1000}}"#
                .into(),
        )
    });
    let c = client(&stub);
    let d = block_on(c.direct_play_decision("1", 0, 0)).expect("decision");
    assert!(d.allows_direct_play());
    let sent = &stub.requests()[0];
    assert!(
        sent.url
            .query()
            .unwrap_or_default()
            .contains("directPlay=1")
    );
    assert_eq!(sent.header("X-Plex-Token"), Some("TOK"));
    assert_eq!(
        c.notifications_url().expect("socket").as_str(),
        "ws://stub.test:32400/:/websockets/notifications?X-Plex-Token=TOK"
    );
}

#[test] // previewsMissing, :664
fn previews_missing() {
    let stub = Stub::new(|r| {
        if r.url.path().starts_with("/library/parts/") {
            (404, String::new())
        } else {
            (200, MOVIE.into())
        }
    });
    assert!(
        block_on(client(&stub).previews("1", None))
            .expect("ok")
            .is_none()
    );
}

#[test] // plan, :672
fn plan_and_download() {
    let stub = Stub::always(200, MOVIE);
    let c = client(&stub);
    let plan = block_on(c.plan_for("1", None, None, None)).expect("plan");
    assert_eq!(plan.method, DeliveryMethod::DirectPlay);
    assert_eq!(plan.play_session_id.as_deref(), Some(c.session_id.as_str()));
    let download = block_on(c.download_url_of("1", Some("2"))).expect("url");
    assert!(download.as_str().contains("/library/parts/2/"));
    assert!(download.as_str().contains("download=1"));
    assert_eq!(download.host_str(), Some("stub.test"));
}

/// The movie fixture with its first video stream as the given codec and Dolby Vision profile.
fn movie_with_video(codec: &str, profile: i64, compat: i64) -> String {
    let mut v: serde_json::Value = serde_json::from_str(MOVIE).expect("fixture");
    let video = &mut v["MediaContainer"]["Metadata"][0]["Media"][0]["Part"][0]["Stream"][0];
    video["codec"] = codec.into();
    video["DOVIPresent"] = true.into();
    video["DOVIProfile"] = profile.into();
    video["DOVIBLCompatID"] = compat.into();
    v.to_string()
}

/// AV1 Dolby Vision 10.0 on a device that shows it green: the plan is the universal transcoder
/// when the server says yes, the original file when it says no; every other title is untouched.
#[test]
fn dolby_vision_10_0_av1_is_transcoded_when_the_server_agrees() {
    use swiftly_playback::device_profile::Flavour;
    let serve = |movie: String, code: i64| {
        Stub::new(move |r| {
            if r.url.path() == "/video/:/transcode/universal/decision" {
                (
                    200,
                    format!(r#"{{"MediaContainer":{{"generalDecisionCode":{code}}}}}"#),
                )
            } else {
                (200, movie.clone())
            }
        })
    };
    let ask = |stub: &Arc<Stub>, flavour: Flavour, hardware_av1: bool| {
        block_on(client(stub).plan_for_device(
            "1",
            None,
            None,
            None,
            (
                flavour,
                swiftly_playback::dolby_vision::HostDecoders::av1(hardware_av1),
            ),
        ))
        .expect("plan")
    };

    let yes = serve(movie_with_video("av1", 10, 0), 1001);
    let plan = ask(&yes, Flavour::Aether, false);
    assert_eq!(plan.method, DeliveryMethod::Transcode);
    assert!(
        plan.url
            .contains("/video/:/transcode/universal/start.m3u8?"),
        "{}",
        plan.url
    );
    for part in [
        "path=%2Flibrary%2Fmetadata%2F1",
        "protocol=hls",
        "directPlay=0",
        "directStream=0",
        "mediaIndex=0",
        "partIndex=0",
        "X-Plex-Token=TOK",
        "X-Plex-Client-Identifier=",
    ] {
        assert!(plan.url.contains(part), "{part} missing in {}", plan.url);
    }
    // The decision asked with direct play and direct stream off.
    let decision = yes
        .requests()
        .into_iter()
        .find(|r| r.url.path().ends_with("/decision"))
        .expect("decision");
    assert!(
        decision
            .url
            .query()
            .unwrap_or_default()
            .contains("directPlay=0")
    );

    // The server refuses (2000): the original file, as before.
    let no = serve(movie_with_video("av1", 10, 0), 2000);
    assert_eq!(
        ask(&no, Flavour::Aether, false).method,
        DeliveryMethod::DirectPlay
    );

    // The Apple engine with hardware AV1 is left alone: no extra request at all.
    let mac = serve(movie_with_video("av1", 10, 0), 1001);
    assert_eq!(
        ask(&mac, Flavour::Aether, true).method,
        DeliveryMethod::DirectPlay
    );
    assert!(
        mac.requests()
            .iter()
            .all(|r| !r.url.path().ends_with("/decision"))
    );

    // Golden: other titles give the same plan as `plan_for` and never ask the server.
    for (codec, profile, compat) in [("av1", 10, 1), ("hevc", 8, 1), ("hevc", 5, 0)] {
        let stub = serve(movie_with_video(codec, profile, compat), 1001);
        let mut new = ask(&stub, Flavour::Aether, false);
        let mut old = block_on(client(&stub).plan_for("1", None, None, None)).expect("plan");
        // The session id is random per client call.
        new.play_session_id = None;
        old.play_session_id = None;
        assert_eq!(new, old, "{codec} {profile}.{compat}");
        assert!(
            stub.requests()
                .iter()
                .all(|r| !r.url.path().ends_with("/decision"))
        );
    }
}

#[test] // search, :683
fn search() {
    let body = r#"{"MediaContainer":{"size":2,"Hub":[
      {"hubIdentifier":"movie","title":"Movies","type":"movie","Metadata":[{"ratingKey":"1","type":"movie","title":"A"}]},
      {"hubIdentifier":"actor","title":"Actors","type":"actor","Metadata":[{"ratingKey":"9","type":"person","title":"B"}]}]}}"#;
    let stub = Stub::always(200, body);
    let c = client(&stub);
    assert!(block_on(c.search("  ", 40)).expect("ok").is_empty());
    assert!(stub.requests().is_empty());
    let found = block_on(c.search("a b+c", 40)).expect("ok");
    assert_eq!(
        found.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
        ["1"]
    );
    assert!(
        stub.requests()[0]
            .url
            .query()
            .unwrap_or("")
            .contains("query=a%20b%2Bc")
    );
}

/// Recorded shape of a real server's film with a German PGS track: the stream ids are large and unrelated to the file, the
/// `index` is the stream's place in the file. The source must carry that place (`ContainerIndex`) next to the server's own
/// number, or the engine is asked for a track under the stream id and shows nothing (reported: no PGS on a Plex film).
#[test]
fn streams_carry_their_place_in_the_file_for_the_engine() {
    let json = r#"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"215995","type":"movie","title":"PGS-Film","duration":7000000,
      "Media":[{"id":100,"container":"mkv","Part":[{"id":170040,"key":"/library/parts/170040/1/file.mkv","container":"mkv",
       "Stream":[
        {"id":412900,"streamType":1,"codec":"h264","index":0,"height":1080,"width":1920},
        {"id":412905,"streamType":2,"selected":true,"codec":"truehd","index":1,"channels":8,"languageCode":"eng"},
        {"id":412906,"streamType":3,"selected":true,"codec":"pgs","index":3,"languageCode":"deu","displayTitle":"Deutsch (PGS)"},
        {"id":412908,"streamType":3,"codec":"srt","languageCode":"eng","key":"/library/streams/412908"}]}]}]}]}}"#;
    let item = mapper().item(&decode_metadata(json));
    let streams = item
        .media_sources
        .as_ref()
        .and_then(|s| s.first())
        .and_then(|s| s.media_streams.clone())
        .expect("streams");
    let rows: Vec<(Option<i64>, Option<i64>)> = streams
        .iter()
        .map(|s| (s.index, s.container_index))
        .collect();
    // The server's number stays the stream id; the place in the file rides along (none for a file next to the film).
    assert_eq!(
        rows,
        vec![
            (Some(412900), Some(0)),
            (Some(412905), Some(1)),
            (Some(412906), Some(3)),
            (Some(412908), None)
        ]
    );
    // It reaches the Swift side as `ContainerIndex` in the source JSON.
    let source = serde_json::to_string(
        item.media_sources
            .as_ref()
            .and_then(|s| s.first())
            .expect("source"),
    )
    .expect("json");
    assert!(source.contains(r#""ContainerIndex":3"#), "{source}");
}

/// A file next to the film (no `index` on the wire, only a `key`) must reach the engine as a subtitle file to load,
/// or the title lists no subtitle track (reported: Plex film with external SRT + ASS showed none on Android).
#[test]
fn external_streams_without_an_index_become_subtitle_files() {
    let json = r#"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"9003","type":"movie","title":"Ext","duration":7000000,
      "Media":[{"id":9003,"container":"mp4","Part":[{"id":9003,"key":"/library/parts/9003/1/file.mp4","container":"mp4",
       "Stream":[
        {"id":413200,"streamType":1,"codec":"h264","index":0,"height":180,"width":320},
        {"id":413205,"streamType":2,"selected":true,"codec":"aac","index":1,"channels":2,"languageCode":"eng"},
        {"id":413208,"streamType":3,"codec":"srt","languageCode":"eng","displayTitle":"English (SRT)","key":"/library/streams/413208","format":"srt"},
        {"id":413211,"streamType":3,"codec":"ass","languageCode":"eng","displayTitle":"English (ASS)","key":"/library/streams/413211","format":"ass"}]}]}]}]}}"#;
    let item = mapper().item(&decode_metadata(json));
    let streams = item
        .media_sources
        .as_ref()
        .and_then(|s| s.first())
        .and_then(|s| s.media_streams.clone())
        .expect("streams");
    let files = swiftly_playback::track_mapping::SubtitleFile::for_avplayer(
        &streams,
        "9003",
        Some("9003"),
        "http://10.0.2.2:1",
        Some("tok"),
        "X-Plex-Token",
        false,
        true,
    );
    assert_eq!(
        files.iter().map(|f| f.index).collect::<Vec<_>>(),
        vec![413208, 413211],
        "{streams:?}"
    );
}
