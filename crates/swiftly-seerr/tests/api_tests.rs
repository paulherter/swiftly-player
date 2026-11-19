//! The full Seerr API against canned answers (the same shapes the xtask fixture serves):
//! status enum, typed errors, account, discover, search, titles, requests, issues, delete, status words.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;

use futures_executor::block_on;
use swiftly_net::{ErrorKind, HttpResponse, HttpTransport, Method, MockTransport};
use swiftly_seerr::issues::{IssueFilter, IssueKind, IssueQuery, IssueSpec, split_time, with_time};
use swiftly_seerr::perms::bit;
use swiftly_seerr::requests::{RequestFilter, RequestQuery, RequestSpec};
use swiftly_seerr::types::{RequestStatus, SearchResult, SliderKind};
use swiftly_seerr::{
    AskError, Perms, SeerrAccess, SeerrClient, SeerrHit, SeerrState, SeerrStatus, StatusInput,
    status_of,
};

struct Shared(Arc<MockTransport>);
impl HttpTransport for Shared {
    fn send(
        &self,
        r: swiftly_net::HttpRequest,
    ) -> impl std::future::Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        self.0.send(r)
    }
}

fn client(t: MockTransport) -> (SeerrClient<Shared>, Arc<MockTransport>) {
    let t = Arc::new(t);
    let c = SeerrClient::new(
        SeerrAccess::new("https://s.test", "connect.sid=abc", &[]),
        Shared(Arc::clone(&t)),
    );
    (c, t)
}

fn body_of(t: &MockTransport) -> serde_json::Value {
    serde_json::from_slice(&t.last_request().unwrap().body.unwrap()).unwrap()
}

fn query_of(t: &MockTransport) -> String {
    t.last_request()
        .unwrap()
        .url
        .query()
        .unwrap_or("")
        .to_string()
}

const TODAY: &str = "2026-11-14";

// ---- bug 1: the status enum ----

#[test]
fn status_numbers_six_is_blocklisted_seven_is_deleted() {
    assert_eq!(SeerrState::from_raw(6), Some(SeerrState::Blocklisted));
    assert_eq!(SeerrState::from_raw(7), Some(SeerrState::Deleted));
    assert_eq!(SeerrState::Blocklisted.raw(), 6);
    assert_eq!(SeerrState::Deleted.raw(), 7);
    assert!(SeerrState::Deleted.requestable());
    assert!(!SeerrState::Blocklisted.requestable());
}

#[test]
fn unknown_status_never_fails_a_read() {
    for text in ["7", "6", "9", "0", "-3", "null", "\"x\"", "1.5"] {
        let s: SeerrState = serde_json::from_str(text).unwrap();
        let _ = s;
    }
    assert_eq!(
        serde_json::from_str::<SeerrState>("7").unwrap(),
        SeerrState::Deleted
    );
    assert_eq!(
        serde_json::from_str::<SeerrState>("42").unwrap(),
        SeerrState::Opened
    );
    assert_eq!(
        serde_json::from_str::<SeerrState>("null").unwrap(),
        SeerrState::Opened
    );
    // A whole hit with a state of the newer Seerr reads.
    let hit: SeerrHit =
        serde_json::from_str(r#"{"id":1,"art":"movie","titel":"X","stand":7}"#).unwrap();
    assert_eq!(hit.state, SeerrState::Deleted);
}

#[test]
fn search_hits_carry_blocklisted_and_deleted() {
    let body = r#"{"results":[
      {"id":1,"mediaType":"movie","title":"A","mediaInfo":{"status":6}},
      {"id":2,"mediaType":"movie","title":"B","mediaInfo":{"status":7}},
      {"id":3,"mediaType":"movie","title":"C","mediaInfo":{"status":99}}]}"#;
    let hits = swiftly_seerr::Seerr::hit_from_search(body.as_bytes());
    let states: Vec<_> = hits.iter().map(|h| h.state).collect();
    assert_eq!(
        states,
        [
            SeerrState::Blocklisted,
            SeerrState::Deleted,
            SeerrState::Opened
        ]
    );
}

// ---- bug 2: typed errors ----

#[test]
fn error_403_quota_names_the_quota() {
    let e = AskError::from_answer(403, r#"{"message":"Series Quota exceeded."}"#, true);
    assert_eq!(e, AskError::QuotaExceeded("Series Quota exceeded.".into()));
    assert_eq!(e.server_text(), Some("Series Quota exceeded."));
    assert!(!e.is_session_lost());
}

#[test]
fn error_403_other_reasons() {
    assert_eq!(
        AskError::from_answer(
            403,
            r#"{"message":"You do not have permission to make this request."}"#,
            true
        ),
        AskError::NoPermission
    );
    assert_eq!(
        AskError::from_answer(403, r#"{"message":"This title is blocklisted."}"#, true),
        AskError::Blocked
    );
    // The session guard of Seerr answers with `error`, not `message`; so does an empty body.
    assert_eq!(
        AskError::from_answer(
            403,
            r#"{"status":403,"error":"You do not have permission to access this endpoint"}"#,
            true
        ),
        AskError::SessionLost
    );
    assert_eq!(AskError::from_answer(403, "", true), AskError::SessionLost);
    assert_eq!(AskError::from_answer(401, "", false), AskError::SessionLost);
}

#[test]
fn error_409_and_others() {
    assert_eq!(AskError::from_answer(409, "{}", true), AskError::Exists);
    assert_eq!(
        AskError::from_answer(409, r#"{"message":"Request is not pending."}"#, false),
        AskError::Conflict("Request is not pending.".into())
    );
    assert_eq!(AskError::from_answer(404, "", false), AskError::NotFound);
    assert_eq!(
        AskError::from_answer(500, r#"{"message":"boom"}"#, false),
        AskError::Failed {
            status: 500,
            text: "boom".into()
        }
    );
    assert_eq!(
        AskError::from_answer(502, "", false),
        AskError::Failed {
            status: 502,
            text: "HTTP 502".into()
        }
    );
}

fn request_with(
    status: u16,
    body: &str,
) -> Result<swiftly_seerr::requests::RequestOutcome, AskError> {
    let (c, _) = client(MockTransport::new().route("request", status, body));
    block_on(c.request(&RequestSpec::new("movie", 5), Perms(bit::REQUEST)))
}

#[test]
fn request_409_is_a_duplicate_not_a_success() {
    assert_eq!(request_with(409, "{}").unwrap_err(), AskError::Exists);
}

#[test]
fn request_403_quota_keeps_the_server_text() {
    assert_eq!(
        request_with(403, r#"{"message":"Movie Quota exceeded."}"#).unwrap_err(),
        AskError::QuotaExceeded("Movie Quota exceeded.".into())
    );
    assert_eq!(
        request_with(403, r#"{"message":"Blocklisted media"}"#).unwrap_err(),
        AskError::Blocked
    );
}

#[test]
fn request_202_means_no_season_left() {
    assert_eq!(request_with(202, "{}").unwrap_err(), AskError::NoSeasons);
}

#[test]
fn request_success_tells_auto_approval() {
    let ok = request_with(201, r#"{"id":9,"status":2,"type":"movie","is4k":false}"#).unwrap();
    assert!(ok.auto_approved);
    assert_eq!(ok.request.id, 9);
    let waits = request_with(201, r#"{"id":10,"status":1}"#).unwrap();
    assert!(!waits.auto_approved);
    assert_eq!(waits.request.status, RequestStatus::Pending);
}

#[test]
fn request_transport_failure_is_network() {
    let (c, _) =
        client(MockTransport::new().route_error("request", ErrorKind::Network { code: -1009 }));
    let e = block_on(c.request(&RequestSpec::new("movie", 5), Perms(bit::REQUEST))).unwrap_err();
    assert_eq!(e, AskError::Network(ErrorKind::Network { code: -1009 }));
}

#[test]
fn old_ask_for_keeps_its_behaviour() {
    let run = |status, body: &str| {
        let (c, _) = client(MockTransport::new().route("request", status, body));
        block_on(c.ask_for("movie", 5, None))
    };
    assert!(run(201, "{}").is_ok());
    assert!(run(409, "{}").is_ok());
    assert!(run(401, "").is_err());
    // A used-up quota now says so instead of "session invalid".
    let quota = format!(
        "{:?}",
        run(403, r#"{"message":"Quota exceeded."}"#).unwrap_err()
    );
    assert!(quota.contains("Quota exceeded."), "{quota}");
}

// ---- account, settings ----

#[test]
fn me_decodes_the_permission_bitmask() {
    let (c, t) = client(MockTransport::new().route(
        "auth/me",
        200,
        r#"{"id":4,"displayName":"Lena","jellyfinUsername":"lena","permissions":4194336,"requestCount":3,"avatar":"/a.png"}"#,
    ));
    let me = block_on(c.me()).unwrap();
    assert_eq!((me.id, me.name().as_str()), (4, "Lena"));
    let p = me.perms();
    assert!(p.can_request_movie() && p.can_request_tv() && p.can_create_issues());
    assert!(!p.is_admin() && !p.can_manage_requests() && !p.can_view_issues());
    assert!(!p.can_request_4k("movie") && !p.can_choose_advanced());
    assert_eq!(t.last_request().unwrap().url.path(), "/api/v1/auth/me");
    assert_eq!(
        t.last_request()
            .unwrap()
            .headers
            .iter()
            .find(|(n, _)| n == "Cookie")
            .map(|(_, v)| v.as_str()),
        Some("connect.sid=abc")
    );
}

#[test]
fn admin_implies_everything() {
    let p = Perms(bit::ADMIN);
    assert!(
        p.can_request_4k("tv")
            && p.can_choose_advanced()
            && p.can_manage_requests()
            && p.can_manage_issues()
            && p.auto_approves("tv", true)
    );
    let u = Perms(bit::REQUEST_MOVIE | bit::AUTO_APPROVE_MOVIE | bit::REQUEST_4K_MOVIE);
    assert!(u.can_request("movie") && !u.can_request("tv"));
    assert!(u.auto_approves("movie", false) && !u.auto_approves("movie", true));
    assert!(u.can_request_4k("movie") && !u.can_request_4k("tv"));
    assert!(Perms(bit::VIEW_ISSUES).can_view_issues());
    assert!(!Perms(bit::CREATE_ISSUES).can_view_issues());
}

#[test]
fn quota_limit_used_remaining() {
    let (c, t) = client(MockTransport::new().route(
        "quota",
        200,
        r#"{"movie":{"days":7,"limit":3,"used":1,"remaining":2,"restricted":false},
            "tv":{"days":7,"limit":3,"used":2,"remaining":1,"restricted":false}}"#,
    ));
    let q = block_on(c.quota(4)).unwrap();
    assert_eq!(t.last_request().unwrap().url.path(), "/api/v1/user/4/quota");
    assert_eq!(q.tv.left(), Some(1));
    assert_eq!(q.part("tv").days, Some(7));
    assert!(q.tv.has_limit() && !q.tv.used_up() && !q.movie.used_up());
    // Used up, by the flag or by the numbers.
    let up = |text: &str| {
        let (c, _) = client(MockTransport::new().route("quota", 200, text));
        block_on(c.quota(4)).unwrap()
    };
    assert!(
        up(r#"{"tv":{"days":7,"limit":3,"used":3,"remaining":0,"restricted":true}}"#)
            .tv
            .used_up()
    );
    assert!(up(r#"{"tv":{"limit":3,"used":3}}"#).tv.used_up());
    // Unlimited (admin): nothing to show.
    let free = up(r#"{"movie":{"used":4,"restricted":false},"tv":{"used":0,"restricted":false}}"#);
    assert!(!free.movie.has_limit() && free.movie.left().is_none() && !free.movie.used_up());
}

#[test]
fn public_settings_and_sliders() {
    let (c, _) = client(MockTransport::new().route(
        "settings/public",
        200,
        r#"{"applicationTitle":"Kino","movie4kEnabled":true,"series4kEnabled":false,"partialRequestsEnabled":true,"mediaServerType":2,"enableSpecialEpisodes":null}"#,
    ));
    let s = block_on(c.public_settings()).unwrap();
    assert!(s.four_k_enabled("movie") && !s.four_k_enabled("tv") && s.partial_requests_enabled);
    assert_eq!(s.application_title.as_deref(), Some("Kino"));
    assert!(!s.enable_special_episodes);

    let (c, t) = client(MockTransport::new().route(
        "settings/discover",
        200,
        r#"[{"id":1,"type":2,"enabled":true,"title":null,"data":null},
            {"id":2,"type":4,"enabled":true},
            {"id":3,"type":3,"enabled":true},
            {"id":4,"type":999,"enabled":true},
            {"id":5,"type":9,"enabled":false},
            {"id":6,"type":14,"enabled":true,"title":"Krimi","data":"80"},
            {"id":7,"type":7,"enabled":true}]"#,
    ));
    let sliders = block_on(c.discover_sliders()).unwrap();
    let kinds: Vec<_> = sliders.iter().map(|s| s.kind).collect();
    assert_eq!(
        kinds,
        [
            SliderKind::RecentRequests,
            SliderKind::Trending,
            SliderKind::MovieGenre,
            SliderKind::UpcomingMovies
        ]
    );
    assert_eq!(sliders[2].title.as_deref(), Some("Krimi"));
    assert_eq!(sliders[2].data.as_deref(), Some("80"));
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/settings/discover"
    );
}

// ---- discover ----

const PAGE: &str = r#"{"page":1,"totalPages":3,"totalResults":50,"results":[
  {"id":10,"mediaType":"movie","title":"Nordstern","releaseDate":"2026-05-01","posterPath":"/n.jpg","voteAverage":7.4,
   "mediaInfo":{"id":5,"tmdbId":10,"status":3,"downloadStatus":[{"size":1000,"sizeLeft":380,"timeLeft":"00:12:03","status":"downloading"}]}},
  {"id":11,"mediaType":"tv","name":"Meerblick","firstAirDate":"2025-02-02"},
  {"id":12,"title":"No type","releaseDate":"2026-01-01"}]}"#;

#[test]
fn discover_sections_hit_their_paths() {
    type Call = Box<dyn Fn(&SeerrClient<Shared>) -> bool>;
    let cases: Vec<(&str, Call)> = vec![
        (
            "discover/trending",
            Box::new(|c| block_on(c.trending(1)).is_ok()),
        ),
        (
            "discover/movies",
            Box::new(|c| block_on(c.popular_movies(1)).is_ok()),
        ),
        (
            "discover/tv",
            Box::new(|c| block_on(c.popular_tv(1)).is_ok()),
        ),
        (
            "discover/movies/upcoming",
            Box::new(|c| block_on(c.upcoming_movies(1)).is_ok()),
        ),
        (
            "discover/tv/upcoming",
            Box::new(|c| block_on(c.upcoming_tv(1)).is_ok()),
        ),
        (
            "discover/movies/genre/28",
            Box::new(|c| block_on(c.by_genre("movie", 28, 1)).is_ok()),
        ),
        (
            "discover/tv/genre/18",
            Box::new(|c| block_on(c.by_genre("tv", 18, 1)).is_ok()),
        ),
        (
            "discover/movies/studio/2",
            Box::new(|c| block_on(c.by_studio(2, 1)).is_ok()),
        ),
        (
            "discover/tv/network/213",
            Box::new(|c| block_on(c.by_network(213, 1)).is_ok()),
        ),
        (
            "discover/movies/language/de",
            Box::new(|c| block_on(c.by_language("movie", "de", 1)).is_ok()),
        ),
        (
            "discover/tv/language/ja",
            Box::new(|c| block_on(c.by_language("tv", "ja", 1)).is_ok()),
        ),
        (
            "discover/keyword/9715/movies",
            Box::new(|c| block_on(c.by_keyword(9715, 1)).is_ok()),
        ),
    ];
    for (path, call) in cases {
        let (c, t) = client(MockTransport::new().route("", 200, PAGE));
        assert!(call(&c), "{path}");
        assert_eq!(
            t.last_request().unwrap().url.path(),
            format!("/api/v1/{path}"),
            "{path}"
        );
        assert!(query_of(&t).contains("page=1"), "{path}");
    }
}

#[test]
fn discover_page_cards_carry_media_and_art() {
    let (c, t) = client(MockTransport::new().route("discover/movies", 200, PAGE));
    let p = block_on(c.popular_movies(2)).unwrap();
    assert_eq!(query_of(&t), "page=2");
    assert_eq!((p.page, p.total_pages, p.total_results), (1, 3, 50));
    assert!(p.has_more());
    assert_eq!(p.results.len(), 3);
    let n = &p.results[0];
    assert_eq!((n.hit.id, n.hit.state), (10, SeerrState::Loads));
    assert_eq!(n.release_date.as_deref(), Some("2026-05-01"));
    assert_eq!(n.rating, Some(7.4));
    assert_eq!(n.media.as_ref().unwrap().id, 5);
    // A missing mediaType takes the section's art.
    assert_eq!(p.results[2].hit.art, "movie");
    assert_eq!(p.results[1].hit.art, "tv");
    // The card of a running download names its percent and time.
    assert_eq!(
        n.status(TODAY, false),
        SeerrStatus::Fetching {
            percent: 62,
            eta_seconds: Some(723)
        }
    );
}

#[test]
fn genre_tiles_and_recently_requested() {
    let (c, t) = client(MockTransport::new().route(
        "genreslider/movie",
        200,
        r#"[{"id":28,"name":"Action","backdrops":["/a.jpg","/b.jpg"]},{"id":35,"name":null,"backdrops":null}]"#,
    ));
    let g = block_on(c.genre_tiles("movie")).unwrap();
    assert_eq!(
        (g[0].id, g[0].backdrops.len(), g[1].backdrops.len()),
        (28, 2, 0)
    );
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/discover/genreslider/movie"
    );

    let (c, t) = client(MockTransport::new().route(
        "request",
        200,
        r#"{"pageInfo":{"pages":1,"pageSize":6,"results":1,"page":1},"results":[{"id":3,"status":1,"type":"tv","media":{"tmdbId":7777,"mediaType":"tv","status":2}}]}"#,
    ));
    let r = block_on(c.recently_requested(6)).unwrap();
    assert_eq!(r[0].media.as_ref().unwrap().tmdb_id, Some(7777));
    assert!(query_of(&t).contains("sort=added") && query_of(&t).contains("take=6"));
}

// ---- search ----

#[test]
fn search_keeps_people_and_collections() {
    let (c, t) = client(MockTransport::new().route(
        "search",
        200,
        r#"{"page":1,"totalPages":1,"totalResults":4,"results":[
          {"id":1,"mediaType":"movie","title":"Nordstern","releaseDate":"2024-01-01"},
          {"id":2,"mediaType":"person","name":"Anna Test","profilePath":"/p.jpg","knownForDepartment":"Acting"},
          {"id":3,"mediaType":"collection","name":"Nord-Reihe","posterPath":"/c.jpg"},
          {"id":4,"mediaType":"keyword","name":"ignored"}]}"#,
    ));
    let p = block_on(c.search("nord süd", 2)).unwrap();
    assert_eq!(query_of(&t), "query=nord%20s%C3%BCd&page=2");
    assert_eq!(p.results.len(), 3);
    assert!(matches!(&p.results[0], SearchResult::Title(c) if c.hit.title == "Nordstern"));
    assert!(
        matches!(&p.results[1], SearchResult::Person(x) if x.name == "Anna Test" && x.known_for.as_deref() == Some("Acting"))
    );
    assert!(matches!(&p.results[2], SearchResult::Collection(x) if x.id == 3));
}

#[test]
fn search_fails_typed() {
    let (c, _) = client(MockTransport::new().route("search", 503, ""));
    assert_eq!(
        block_on(c.search("x", 1)).unwrap_err(),
        AskError::Failed {
            status: 503,
            text: "HTTP 503".into()
        }
    );
    let (c, _) = client(MockTransport::new().route("search", 200, "no json"));
    assert!(matches!(
        block_on(c.search("x", 1)).unwrap_err(),
        AskError::Network(ErrorKind::Decoding(_))
    ));
}

// ---- titles ----

const SERIES: &str = r#"{"id":7777,"name":"Küstenwache","overview":" Ein Revier. ","firstAirDate":"2024-03-01",
  "genres":[{"name":"Krimi"},{"name":"Drama"},{"name":"Nord"}],"episodeRunTime":[45],"voteAverage":8.1,"status":"Returning Series",
  "seasons":[{"seasonNumber":0,"episodeCount":2},
             {"seasonNumber":1,"episodeCount":8,"airDate":"2024-03-01"},
             {"seasonNumber":2,"episodeCount":10},
             {"seasonNumber":3,"episodeCount":10,"airDate":"2026-01-10"},
             {"seasonNumber":4,"episodeCount":6,"airDate":"2026-12-24"}],
  "credits":{"cast":[{"id":1,"name":"Anna Test","character":"Kommissarin","profilePath":"/a.jpg"},{"id":2,"name":null}]},
  "mediaInfo":{"id":31,"tmdbId":7777,"status":4,"status4k":1,
    "requests":[{"id":71,"status":1,"is4k":false,"seasons":[{"seasonNumber":4,"status":1}],"requestedBy":{"id":5,"displayName":"Lena"}}],
    "seasons":[{"seasonNumber":1,"status":1},{"seasonNumber":2,"status":5},{"seasonNumber":3,"status":3}],
    "downloadStatus":[
      {"size":100,"sizeLeft":50,"timeLeft":"00:10:00","episode":{"seasonNumber":3,"episodeNumber":1}},
      {"size":100,"sizeLeft":26,"timeLeft":"00:20:00","episode":{"seasonNumber":3,"episodeNumber":2}}],
    "downloadStatus4k":[]}}"#;

#[test]
fn title_page_with_seasons_and_downloads() {
    let (c, t) = client(
        MockTransport::new()
            .route(
                "tv/7777/season/2",
                200,
                r#"{"airDate":"2025-01-05","episodes":[]}"#,
            )
            .route("tv/7777", 200, SERIES),
    );
    let info = block_on(c.title("tv", 7777)).unwrap();
    assert_eq!(info.title, "Küstenwache");
    assert_eq!(info.overview.as_deref(), Some("Ein Revier."));
    assert_eq!(info.genres.len(), 3);
    assert_eq!(info.runtime, Some(45));
    assert_eq!(info.cast.len(), 1);
    assert_eq!(info.seasons.len(), 4, "specials are left out");
    // Every season is asked for (episodes and days); the one without a date takes its day from the page.
    let paths: Vec<_> = t
        .requests()
        .iter()
        .map(|r| r.url.path().to_string())
        .collect();
    assert_eq!(paths.iter().filter(|p| p.contains("/season/")).count(), 4);
    assert_eq!(info.seasons[1].air_date.as_deref(), Some("2025-01-05"));
    let media = info.media.as_ref().unwrap();
    assert_eq!(
        (media.id, media.status, media.status4k),
        (31, SeerrState::PartWayPresent, SeerrState::Opened)
    );
    assert_eq!(
        media.requests[0].requested_by.as_ref().unwrap().name(),
        "Lena"
    );
    assert_eq!(media.download_status.len(), 2);

    // Per season: S1 unknown, S2 there, S3 fetching 1 - 76/200 = 62 %, S4 waits.
    assert_eq!(info.status(TODAY, false, Some(1)), SeerrStatus::Requestable);
    assert_eq!(info.status(TODAY, false, Some(2)), SeerrStatus::Available);
    assert_eq!(
        info.status(TODAY, false, Some(3)),
        SeerrStatus::Fetching {
            percent: 62,
            eta_seconds: Some(1200)
        }
    );
    assert_eq!(info.status(TODAY, false, Some(4)), SeerrStatus::Waits);
    assert_eq!(info.status(TODAY, false, None), SeerrStatus::Partial);
    // The 4K lane has nothing.
    assert_eq!(info.status(TODAY, true, None), SeerrStatus::Requestable);
}

#[test]
fn movie_title_reads_collection_and_missing_media() {
    let (c, t) = client(MockTransport::new().route(
        "movie/2001",
        200,
        r#"{"id":2001,"title":"Nordstern","releaseDate":"2026-06-01","runtime":101,"belongsToCollection":{"id":55,"name":"Nord-Reihe","posterPath":"/c.jpg"},"mediaInfo":null}"#,
    ));
    let m = block_on(c.title("movie", 2001)).unwrap();
    assert_eq!(m.collection.as_ref().unwrap().id, 55);
    assert!(m.media.is_none());
    assert_eq!(m.status(TODAY, false, None), SeerrStatus::Requestable);
    assert_eq!(t.requests().len(), 1, "a film asks for nothing more");
    let (c, _) = client(MockTransport::new().route("movie/9", 404, ""));
    assert_eq!(
        block_on(c.title("movie", 9)).unwrap_err(),
        AskError::NotFound
    );
}

#[test]
fn related_merges_recommendations_and_similar() {
    let rec = r#"{"results":[{"id":1,"title":"A"},{"id":2,"title":"B"}]}"#;
    let sim = r#"{"results":[{"id":2,"title":"B"},{"id":3,"title":"C"}]}"#;
    let (c, t) = client(
        MockTransport::new()
            .route("tv/7/recommendations", 200, rec)
            .route("tv/7/similar", 200, sim),
    );
    let r = block_on(c.related("tv", 7)).unwrap();
    let ids: Vec<_> = r.iter().map(|x| x.hit.id).collect();
    assert_eq!(ids, [1, 2, 3]);
    assert!(r.iter().all(|x| x.hit.art == "tv"));
    assert_eq!(t.requests().len(), 2);
    // One half down: the other still counts; both down: the error.
    let (c, _) = client(
        MockTransport::new()
            .route("tv/7/recommendations", 500, "")
            .route("tv/7/similar", 200, sim),
    );
    assert_eq!(block_on(c.related("tv", 7)).unwrap().len(), 2);
    let (c, _) = client(
        MockTransport::new()
            .route("tv/7/recommendations", 500, "")
            .route("tv/7/similar", 500, ""),
    );
    assert!(block_on(c.related("tv", 7)).is_err());
}

#[test]
fn collection_person_and_credits() {
    let (c, t) = client(MockTransport::new().route(
        "collection/55",
        200,
        r#"{"id":55,"name":"Nord-Reihe","overview":"","parts":[
          {"id":2001,"title":"Nordstern","releaseDate":"2026-06-01","mediaInfo":{"status":3}},
          {"id":1001,"title":"Nord 2","releaseDate":"2020-01-01","mediaInfo":{"status":5}}]}"#,
    ));
    let col = block_on(c.collection(55)).unwrap();
    assert_eq!(col.parts.len(), 2);
    assert!(col.parts.iter().all(|p| p.hit.art == "movie"));
    assert_eq!(col.parts[1].hit.state, SeerrState::Present);
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/collection/55"
    );

    let (c, _) = client(MockTransport::new().route(
        "person/7",
        200,
        r#"{"id":7,"name":"Anna Test","biography":"Bio","birthday":"1980-05-01","knownForDepartment":"Acting"}"#,
    ));
    let p = block_on(c.person(7)).unwrap();
    assert_eq!(
        (p.name.as_deref(), p.birthday.as_deref()),
        (Some("Anna Test"), Some("1980-05-01"))
    );

    let (c, t) = client(MockTransport::new().route(
        "combined_credits",
        200,
        r#"{"cast":[{"id":1000,"mediaType":"movie","title":"Film 0","mediaInfo":{"status":5}},
                    {"id":1000,"mediaType":"movie","title":"Film 0"},
                    {"id":2002,"mediaType":"movie","title":"Frei","releaseDate":"2025-01-01"}],
            "crew":[{"id":7777,"mediaType":"tv","name":"Küstenwache"}]}"#,
    ));
    let cr = block_on(c.person_credits(7)).unwrap();
    assert_eq!((cr.cast.len(), cr.crew.len()), (2, 1));
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/person/7/combined_credits"
    );
}

// ---- requests ----

#[test]
fn request_body_follows_the_permissions() {
    let mut spec = RequestSpec::new("tv", 7777).with_seasons(&[3, 4]);
    spec.is4k = true;
    spec.server_id = Some(1);
    spec.profile_id = Some(4);
    spec.root_folder = Some("/tv".into());
    spec.language_profile_id = Some(2);
    spec.tags = vec![8];
    let user = spec.body(Perms(bit::REQUEST));
    assert_eq!(
        user,
        serde_json::json!({"mediaType":"tv","mediaId":7777,"seasons":[3,4]})
    );
    let admin = spec.body(Perms(bit::ADMIN));
    assert_eq!(admin["is4k"], true);
    assert_eq!(admin["serverId"], 1);
    assert_eq!(admin["profileId"], 4);
    assert_eq!(admin["rootFolder"], "/tv");
    assert_eq!(admin["languageProfileId"], 2);
    assert_eq!(admin["tags"], serde_json::json!([8]));
    // 4K without the advanced choice.
    let four = spec.body(Perms(bit::REQUEST_TV | bit::REQUEST_4K_TV));
    assert_eq!(four["is4k"], true);
    assert!(four.get("profileId").is_none());
    // A series without a choice asks for all seasons; a film never sends seasons.
    assert_eq!(
        RequestSpec::new("tv", 1).body(Perms(bit::REQUEST))["seasons"],
        "all"
    );
    assert!(
        RequestSpec::new("movie", 1)
            .body(Perms(bit::REQUEST))
            .get("seasons")
            .is_none()
    );
}

#[test]
fn request_post_goes_out_with_seasons() {
    let (c, t) = client(MockTransport::new().route(
        "request",
        201,
        r#"{"id":88,"status":1,"type":"tv","seasons":[{"seasonNumber":5,"status":1}],"media":{"tmdbId":7777,"status":2}}"#,
    ));
    let spec = RequestSpec::new("tv", 7777).with_seasons(&[5]);
    let out = block_on(c.request(&spec, Perms(bit::REQUEST))).unwrap();
    let req = t.last_request().unwrap();
    assert_eq!(
        (req.method, req.url.path()),
        (Method::Post, "/api/v1/request")
    );
    assert_eq!(body_of(&t)["seasons"], serde_json::json!([5]));
    assert_eq!(out.request.season_numbers(), [5]);
    assert_eq!(out.request.media.unwrap().status, SeerrState::WaitsSharing);
}

#[test]
fn request_list_filters_and_paging() {
    let (c, t) = client(MockTransport::new().route(
        "request",
        200,
        r#"{"pageInfo":{"pages":2,"pageSize":5,"results":7,"page":1},"results":[
          {"id":1,"status":1,"type":"movie","media":{"tmdbId":2002,"mediaType":"movie","status":2},"requestedBy":{"id":4,"displayName":"Lena"}},
          {"id":2,"status":3,"type":"movie","media":{"tmdbId":2003,"status":1}},
          {"id":3,"status":4,"type":"movie","media":{"tmdbId":2007,"status":1}},
          {"id":4,"status":77,"type":"tv","media":{"tmdbId":1,"status":1}}]}"#,
    ));
    let q = RequestQuery {
        filter: RequestFilter::Pending,
        by_modified: true,
        requested_by: Some(4),
        media_type: Some("movie".into()),
        take: 5,
        skip: 10,
    };
    let page = block_on(c.request_list(&q)).unwrap();
    assert_eq!(
        query_of(&t),
        "take=5&skip=10&filter=pending&sort=modified&sortDirection=desc&requestedBy=4&mediaType=movie"
    );
    assert_eq!((page.page_info.pages, page.page_info.results), (2, 7));
    let st: Vec<_> = page.results.iter().map(|r| r.status).collect();
    assert_eq!(
        st,
        [
            RequestStatus::Pending,
            RequestStatus::Declined,
            RequestStatus::Failed,
            RequestStatus::Pending
        ]
    );
    assert_eq!(page.results[0].requested_by.as_ref().unwrap().id, 4);
    let (c, t) = client(MockTransport::new().route("request", 200, "{}"));
    block_on(c.request_list(&RequestQuery::default())).unwrap();
    assert_eq!(
        query_of(&t),
        "take=20&skip=0&filter=all&sort=added&sortDirection=desc"
    );
}

#[test]
fn request_count_and_single() {
    let (c, t) = client(MockTransport::new().route(
        "request/count",
        200,
        r#"{"total":9,"movie":5,"tv":4,"pending":3,"approved":2,"declined":1,"processing":2,"available":3,"completed":0}"#,
    ));
    let n = block_on(c.request_count()).unwrap();
    assert_eq!((n.total, n.pending, n.processing), (9, 3, 2));
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/request/count"
    );
    let (c, t) = client(MockTransport::new().route("request/12", 200, r#"{"id":12,"status":2}"#));
    assert_eq!(
        block_on(c.request_by_id(12)).unwrap().status,
        RequestStatus::Approved
    );
    assert_eq!(t.last_request().unwrap().method, Method::Get);
}

#[test]
fn cancel_approve_decline_retry() {
    let (c, t) = client(
        MockTransport::new()
            .route("request/5", 204, "")
            .route("request/5/approve", 200, r#"{"id":5,"status":2}"#)
            .route("request/5/decline", 200, r#"{"id":5,"status":3}"#)
            .route("request/5/retry", 200, r#"{"id":5,"status":2}"#),
    );
    block_on(c.cancel_request(5)).unwrap();
    let r = t.last_request().unwrap();
    assert_eq!(
        (r.method, r.url.path()),
        (Method::Delete, "/api/v1/request/5")
    );
    assert!(r.body.is_none());
    assert_eq!(
        block_on(c.approve_request(5)).unwrap().status,
        RequestStatus::Approved
    );
    assert_eq!(t.last_request().unwrap().method, Method::Post);
    let r = block_on(c.decline_request(5)).unwrap();
    assert_eq!(r.status, RequestStatus::Declined);
    assert!(
        t.last_request().unwrap().body.is_none(),
        "a decline carries no reason"
    );
    block_on(c.retry_request(5)).unwrap();
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/request/5/retry"
    );
}

#[test]
fn approve_without_permission_or_pending() {
    let (c, _) = client(MockTransport::new().route(
        "request/5/approve",
        403,
        r#"{"message":"You do not have permission to manage requests."}"#,
    ));
    assert_eq!(
        block_on(c.approve_request(5)).unwrap_err(),
        AskError::NoPermission
    );
    let (c, _) = client(MockTransport::new().route(
        "request/5/approve",
        409,
        r#"{"message":"This request is not pending."}"#,
    ));
    assert_eq!(
        block_on(c.approve_request(5)).unwrap_err(),
        AskError::Conflict("This request is not pending.".into())
    );
    let (c, _) = client(MockTransport::new().route("request/5", 401, ""));
    assert!(block_on(c.cancel_request(5)).unwrap_err().is_session_lost());
}

#[test]
fn service_lists() {
    let (c, t) = client(
        MockTransport::new()
            .route("service/radarr", 200, r#"[{"id":0,"name":"Radarr","isDefault":true,"is4k":false,"activeProfileId":4,"activeDirectory":"/movies"}]"#)
            .route(
                "service/sonarr/1",
                200,
                r#"{"server":{"id":1,"name":"Sonarr"},"profiles":[{"id":4,"name":"HD"}],"rootFolders":[{"path":"/tv"}],"tags":[{"id":8,"label":"kids"}]}"#,
            ),
    );
    let s = block_on(c.service_servers("movie")).unwrap();
    assert_eq!((s[0].is_default, s[0].active_profile_id), (true, Some(4)));
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/service/radarr"
    );
    let d = block_on(c.service_detail("tv", 1)).unwrap();
    assert_eq!(
        (
            d.profiles.len(),
            d.root_folders.len(),
            d.tags[0].label.as_deref()
        ),
        (1, 1, Some("kids"))
    );
}

// ---- issues ----

#[test]
fn issue_time_is_appended_and_parsed_back() {
    assert_eq!(
        with_time("Ton rauscht", Some("23:14")),
        "Ton rauscht · bei 23:14"
    );
    assert_eq!(with_time("Ton rauscht", None), "Ton rauscht");
    assert_eq!(with_time("x", Some("not a time")), "x");
    assert_eq!(
        split_time("Ton rauscht · bei 23:14"),
        ("Ton rauscht", Some("23:14"))
    );
    assert_eq!(split_time("Lang · bei 1:05:23"), ("Lang", Some("1:05:23")));
    assert_eq!(split_time("Kein Ende · bei 5"), ("Kein Ende · bei 5", None));
    assert_eq!(
        split_time("bei 23:14 mitten drin"),
        ("bei 23:14 mitten drin", None)
    );
    assert_eq!(
        split_time("a · bei 23:14 · bei 07:30"),
        ("a · bei 23:14", Some("07:30"))
    );
}

const ISSUE: &str = r#"{"id":4,"issueType":3,"status":1,"problemSeason":2,"problemEpisode":5,"createdAt":"2026-11-10T10:00:00.000Z",
  "media":{"id":31,"tmdbId":7777,"mediaType":"tv","status":4},
  "createdBy":{"id":4,"displayName":"Lena"},
  "comments":[{"id":1,"message":"Untertitel versetzt · bei 23:14","user":{"id":4,"displayName":"Lena"}},
              {"id":2,"message":"Schaue ich mir an","user":{"id":1,"displayName":"Admin"}}]}"#;

#[test]
fn issue_read_with_thread() {
    let (c, t) = client(MockTransport::new().route("issue/4", 200, ISSUE));
    let i = block_on(c.issue(4)).unwrap();
    assert_eq!(t.last_request().unwrap().url.path(), "/api/v1/issue/4");
    assert_eq!(
        (i.issue_type, i.problem_season, i.problem_episode),
        (IssueKind::Subtitles, 2, 5)
    );
    assert!(i.is_open());
    assert_eq!(i.time_mark(), Some("23:14"));
    assert_eq!(i.comments[0].text(), "Untertitel versetzt");
    assert_eq!(i.comments[1].time_mark(), None);
    assert_eq!(i.media.unwrap().tmdb_id, Some(7777));
}

#[test]
fn issue_list_count_and_filters() {
    let (c, t) = client(MockTransport::new().route(
        "issue",
        200,
        &format!(
            r#"{{"pageInfo":{{"pages":1,"pageSize":20,"results":1,"page":1}},"results":[{ISSUE}]}}"#
        ),
    ));
    let q = IssueQuery {
        filter: IssueFilter::Open,
        requested_by: Some(4),
        ..IssueQuery::default()
    };
    let p = block_on(c.issue_list(&q)).unwrap();
    assert_eq!(
        query_of(&t),
        "take=20&skip=0&filter=open&sort=added&requestedBy=4"
    );
    assert_eq!(p.results.len(), 1);
    let (c, t) = client(MockTransport::new().route(
        "issue/count",
        200,
        r#"{"total":3,"video":1,"audio":0,"subtitles":2,"others":0,"open":1,"closed":2}"#,
    ));
    let n = block_on(c.issue_count()).unwrap();
    assert_eq!((n.total, n.open, n.closed, n.subtitles), (3, 1, 2, 2));
    assert_eq!(t.last_request().unwrap().url.path(), "/api/v1/issue/count");
}

#[test]
fn issue_create_comment_resolve_reopen() {
    let (c, t) = client(
        MockTransport::new()
            .route("issue", 201, ISSUE)
            .route("issue/4/comment", 200, ISSUE)
            .route("issue/4/resolved", 200, r#"{"id":4,"status":2}"#)
            .route("issue/4/open", 200, ISSUE),
    );
    let spec = IssueSpec {
        kind: IssueKind::Subtitles,
        message: "Untertitel versetzt".into(),
        media_id: 31,
        season: 2,
        episode: 5,
        at: Some("23:14".into()),
    };
    let i = block_on(c.create_issue(&spec)).unwrap();
    assert_eq!(i.id, 4);
    let r = t.last_request().unwrap();
    assert_eq!((r.method, r.url.path()), (Method::Post, "/api/v1/issue"));
    assert_eq!(
        body_of(&t),
        serde_json::json!({"issueType":3,"message":"Untertitel versetzt · bei 23:14","mediaId":31,"problemSeason":2,"problemEpisode":5})
    );
    block_on(c.comment_issue(4, "Danke")).unwrap();
    assert_eq!(body_of(&t), serde_json::json!({"message":"Danke"}));
    let done = block_on(c.resolve_issue(4)).unwrap();
    assert!(!done.is_open());
    assert_eq!(
        t.last_request().unwrap().url.path(),
        "/api/v1/issue/4/resolved"
    );
    block_on(c.reopen_issue(4)).unwrap();
    assert_eq!(t.last_request().unwrap().url.path(), "/api/v1/issue/4/open");
}

#[test]
fn issue_create_refused_without_permission() {
    let (c, _) = client(MockTransport::new().route(
        "issue",
        403,
        r#"{"message":"You do not have permission to create issues."}"#,
    ));
    let spec = IssueSpec {
        kind: IssueKind::Other,
        message: "x".into(),
        media_id: 1,
        season: 0,
        episode: 0,
        at: None,
    };
    assert_eq!(
        block_on(c.create_issue(&spec)).unwrap_err(),
        AskError::NoPermission
    );
}

// ---- delete ----

#[test]
fn delete_media_and_file() {
    let (c, t) = client(
        MockTransport::new()
            .route("media/31/file", 204, "")
            .route("media/31", 204, ""),
    );
    block_on(c.delete_media_file(31, true)).unwrap();
    let r = t.last_request().unwrap();
    assert_eq!(
        (r.method, r.url.path(), r.url.query()),
        (Method::Delete, "/api/v1/media/31/file", Some("is4k=true"))
    );
    block_on(c.delete_media_file(31, false)).unwrap();
    assert_eq!(query_of(&t), "is4k=false");
    block_on(c.delete_media(31)).unwrap();
    let r = t.last_request().unwrap();
    assert_eq!(
        (r.method, r.url.path()),
        (Method::Delete, "/api/v1/media/31")
    );
    let (c, _) = client(MockTransport::new().route(
        "media/31/file",
        409,
        r#"{"message":"No default server."}"#,
    ));
    assert_eq!(
        block_on(c.delete_media_file(31, false)).unwrap_err(),
        AskError::Conflict("No default server.".into())
    );
    let (c, _) = client(MockTransport::new().route(
        "media/31/file",
        403,
        r#"{"message":"You do not have permission."}"#,
    ));
    assert_eq!(
        block_on(c.delete_media_file(31, false)).unwrap_err(),
        AskError::NoPermission
    );
}

// ---- the status word, one row per case ----

fn info(json: &str) -> swiftly_seerr::types::MediaInfo {
    serde_json::from_str(json).unwrap()
}

fn word(media: Option<&str>, date: Option<&str>, is4k: bool, season: Option<i64>) -> SeerrStatus {
    let m = media.map(info);
    status_of(&StatusInput {
        media: m.as_ref(),
        is4k,
        season,
        release_date: date,
        today: TODAY,
    })
}

#[test]
fn status_table() {
    use SeerrStatus::*;
    // Nothing known.
    assert_eq!(word(None, Some("2020-01-01"), false, None), Requestable);
    assert_eq!(word(None, None, false, None), Requestable);
    assert_eq!(
        word(Some(r#"{"status":1}"#), Some("2020-01-01"), false, None),
        Requestable
    );
    // Not out yet.
    assert_eq!(
        word(None, Some("2026-11-28"), false, None),
        Soon {
            date: "2026-11-28".into(),
            requested: false
        }
    );
    assert_eq!(
        word(None, Some("2026-11-14"), false, None),
        Requestable,
        "today counts as out"
    );
    // Waiting for an admin.
    let waits = r#"{"status":2,"requests":[{"id":1,"status":1}]}"#;
    assert_eq!(word(Some(waits), Some("2020-01-01"), false, None), Waits);
    assert_eq!(word(Some(r#"{"status":2}"#), None, false, None), Waits);
    // Pending while unreleased still waits for the admin first.
    assert_eq!(word(Some(waits), Some("2027-01-01"), false, None), Waits);
    // Approved: searching, or soon when unreleased.
    let approved = r#"{"status":3,"requests":[{"id":1,"status":2}]}"#;
    assert_eq!(
        word(Some(approved), Some("2020-01-01"), false, None),
        Searching
    );
    assert_eq!(
        word(Some(approved), Some("2026-11-28"), false, None),
        Soon {
            date: "2026-11-28".into(),
            requested: true
        }
    );
    assert_eq!(word(Some(r#"{"status":3}"#), None, false, None), Searching);
    // Downloading: percent and the longest time left.
    let dl = r#"{"status":3,"downloadStatus":[{"size":200,"sizeLeft":76,"timeLeft":"01:00:30"}]}"#;
    assert_eq!(
        word(Some(dl), None, false, None),
        Fetching {
            percent: 62,
            eta_seconds: Some(3630)
        }
    );
    let no_time = r#"{"status":3,"downloadStatus":[{"size":0,"sizeLeft":0}]}"#;
    assert_eq!(
        word(Some(no_time), None, false, None),
        Fetching {
            percent: 0,
            eta_seconds: None
        }
    );
    // Partly there, there, blocked.
    assert_eq!(word(Some(r#"{"status":4}"#), None, false, None), Partial);
    assert_eq!(word(Some(r#"{"status":5}"#), None, false, None), Available);
    assert_eq!(word(Some(r#"{"status":6}"#), None, false, None), Blocked);
    assert_eq!(
        word(Some(r#"{"status":6,"status4k":5}"#), None, false, None),
        Blocked
    );
    assert_eq!(
        word(Some(r#"{"status":6,"status4k":5}"#), None, true, None),
        Available
    );
    // Deleted reads as requestable again.
    assert_eq!(
        word(Some(r#"{"status":7}"#), Some("2020-01-01"), false, None),
        Requestable
    );
    // Declined and failed requests.
    let declined = r#"{"status":1,"requests":[{"id":1,"status":3}]}"#;
    assert_eq!(word(Some(declined), None, false, None), Declined);
    let failed = r#"{"status":3,"requests":[{"id":1,"status":4}]}"#;
    assert_eq!(word(Some(failed), None, false, None), Failed);
    // A newer live request beats an older declined one.
    let again = r#"{"status":2,"requests":[{"id":1,"status":3},{"id":2,"status":1}]}"#;
    assert_eq!(word(Some(again), None, false, None), Waits);
    // A completed request does not decide anything.
    assert_eq!(
        word(
            Some(r#"{"status":1,"requests":[{"id":1,"status":5}]}"#),
            None,
            false,
            None
        ),
        Requestable
    );
    // The 4K lane only sees its own requests.
    let k4 = r#"{"status":5,"status4k":2,"requests":[{"id":1,"status":1,"is4k":true}]}"#;
    assert_eq!(word(Some(k4), None, false, None), Available);
    assert_eq!(word(Some(k4), None, true, None), Waits);
    // Unknown numbers never panic (an unknown request status counts as pending).
    assert_eq!(
        word(
            Some(r#"{"status":99,"requests":[{"id":1,"status":99}]}"#),
            None,
            false,
            None
        ),
        Waits
    );
}

#[test]
fn status_words_and_helpers() {
    use SeerrStatus::*;
    assert_eq!(Requestable.word(), "anfragbar");
    assert_eq!(Waits.word(), "wartet");
    assert_eq!(Searching.word(), "wird gesucht");
    assert_eq!(
        Soon {
            date: String::new(),
            requested: false
        }
        .word(),
        "erscheint am"
    );
    assert_eq!(
        Fetching {
            percent: 1,
            eta_seconds: None
        }
        .word(),
        "wird geholt"
    );
    assert_eq!(Partial.word(), "teilweise");
    assert_eq!(Available.word(), "verfügbar");
    assert_eq!(Declined.word(), "abgelehnt");
    assert_eq!(Failed.word(), "fehlgeschlagen");
    assert_eq!(Blocked.word(), "gesperrt");
    assert!(Requestable.can_request() && Partial.can_request() && Declined.can_request());
    assert!(!Blocked.can_request() && !Available.can_request() && !Waits.can_request());
    assert!(
        Soon {
            date: String::new(),
            requested: false
        }
        .can_request()
    );
    assert!(
        !Soon {
            date: String::new(),
            requested: true
        }
        .can_request()
    );
    assert!(Waits.is_requested() && !Declined.is_requested());
    assert!(
        Fetching {
            percent: 1,
            eta_seconds: None
        }
        .rail_rank()
            < Searching.rail_rank()
    );
    assert!(
        Searching.rail_rank() < Waits.rail_rank()
            && Waits.rail_rank()
                < Soon {
                    date: String::new(),
                    requested: true
                }
                .rail_rank()
    );
}

#[test]
fn season_status_reads_the_seasons_list() {
    use SeerrStatus::*;
    let m = r#"{"status":4,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":2},{"seasonNumber":3,"status":3}],
                "requests":[{"id":9,"status":1,"seasons":[{"seasonNumber":2,"status":1}]}]}"#;
    assert_eq!(word(Some(m), None, false, Some(1)), Available);
    assert_eq!(word(Some(m), None, false, Some(2)), Waits);
    assert_eq!(word(Some(m), None, false, Some(3)), Searching);
    assert_eq!(word(Some(m), None, false, Some(4)), Requestable);
    assert_eq!(
        word(Some(m), Some("2027-01-01"), false, Some(4)),
        Soon {
            date: "2027-01-01".into(),
            requested: false
        }
    );
}

#[test]
fn lenient_reads_survive_nulls() {
    let m: swiftly_seerr::types::MediaInfo = serde_json::from_str(
        r#"{"id":null,"tmdbId":null,"status":null,"requests":null,"seasons":null,"downloadStatus":null,"downloadStatus4k":null}"#,
    )
    .unwrap();
    assert_eq!(m.status, SeerrState::Opened);
    assert!(m.requests.is_empty() && m.download_status.is_empty());
    let (c, _) = client(MockTransport::new().route(
        "auth/me",
        200,
        r#"{"id":1,"permissions":null,"displayName":null}"#,
    ));
    assert_eq!(block_on(c.me()).unwrap().permissions, 0);
}
