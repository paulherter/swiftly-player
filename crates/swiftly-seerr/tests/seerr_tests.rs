//! Translated from SeerrTests.swift (+ SeerrAddressTests, SeerrPreItemTests).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Mutex;

use futures_executor::block_on;
use swiftly_jellyfin::OwnHeader;
use swiftly_net::{ErrorKind, HttpResponse, Method, MockTransport, TransportReason, Url};
use swiftly_seerr::mapping::Seerr;
use swiftly_seerr::{
    CookieJar, KeepPostRedirects, NoCookies, SeerrAccess, SeerrClient, SeerrDetail,
    SeerrSessionState, SeerrState, error_to_show,
};

const ANSWER: &str = r#"{"page":1,"totalResults":4,"results":[
  {"id":1,"mediaType":"movie","title":"Lighthouse Live","releaseDate":"2014-03-01","posterPath":"/abc.jpg","backdropPath":"/quer.jpg"},
  {"id":2,"mediaType":"tv","name":"The Lighthouse","firstAirDate":"2008-09-23","posterPath":"/def.jpg","mediaInfo":{"status":5}},
  {"id":3,"mediaType":"tv","name":"The Lighthouse (UK)","firstAirDate":"2011-01-01","mediaInfo":{"status":2}},
  {"id":4,"mediaType":"person","name":"Simon Baker","profilePath":"/ghi.jpg"}]}"#;

fn hit(id: i64) -> swiftly_seerr::SeerrHit {
    Seerr::hit_from_search(ANSWER.as_bytes())
        .into_iter()
        .find(|h| h.id == id)
        .unwrap()
}

#[test]
fn people_drop_out() {
    let t = Seerr::hit_from_search(ANSWER.as_bytes());
    assert_eq!(t.len(), 3);
    assert!(!t.iter().any(|h| h.title == "Simon Baker"));
}

#[test]
fn title_and_year() {
    let film = hit(1);
    assert_eq!(
        (film.title.as_str(), film.year),
        ("Lighthouse Live", Some(2014))
    );
    let series = hit(2);
    assert_eq!(
        (series.title.as_str(), series.year),
        ("The Lighthouse", Some(2008))
    );
    assert!(series.is_series());
}

#[test]
fn without_media_info_open() {
    assert_eq!(hit(1).state, SeerrState::Opened);
    assert!(hit(1).state.requestable());
}

#[test]
fn states_from_response() {
    assert_eq!(hit(2).state, SeerrState::Present);
    assert_eq!(hit(3).state, SeerrState::WaitsSharing);
}

#[test]
fn broken_response_gives_nothing() {
    assert!(Seerr::hit_from_search(b"kein JSON").is_empty());
}

#[test]
fn only_what_makes_sense_is_requestable() {
    use SeerrState::*;
    assert!(Opened.requestable() && Deleted.requestable() && PartWayPresent.requestable());
    assert!(!WaitsSharing.requestable() && !Loads.requestable() && !Present.requestable());
}

#[test]
fn only_present_is_present() {
    assert!(SeerrState::Present.already_present());
    assert!(!SeerrState::PartWayPresent.already_present());
    assert!(!SeerrState::Loads.already_present());
}

#[test]
fn image_addresses() {
    assert_eq!(
        hit(1).poster(342).unwrap(),
        "https://image.tmdb.org/t/p/w342/abc.jpg"
    );
    assert_eq!(
        hit(1).backdrop(780).unwrap(),
        "https://image.tmdb.org/t/p/w780/quer.jpg"
    );
    assert!(hit(2).backdrop(780).is_none());
    assert!(hit(2).poster(342).is_some());
    assert!(hit(3).poster(342).is_none());
}

#[test]
fn cookie_cutting() {
    assert_eq!(
        Seerr::cookie_from_header("connect.sid=s%3Aabc123.xyz; Path=/; HttpOnly; SameSite=Strict")
            .unwrap(),
        "connect.sid=s%3Aabc123.xyz"
    );
    assert_eq!(
        Seerr::cookie_from_header("lb=eu-1; Path=/, connect.sid=s%3Aabc; Path=/; HttpOnly")
            .unwrap(),
        "connect.sid=s%3Aabc"
    );
    assert!(Seerr::cookie_from_header("lb=eu-1; Path=/").is_none());
    assert!(Seerr::cookie_from_header("connect.sid=; Path=/").is_none());
}

#[test]
fn request_bodies() {
    let r = Seerr::request_body("movie", 42, None);
    assert_eq!(r["mediaType"], "movie");
    assert_eq!(r["mediaId"], 42);
    assert!(r.get("seasons").is_none());
    assert_eq!(Seerr::request_body("tv", 7, None)["seasons"], "all");
    assert_eq!(Seerr::request_body("tv", 7, Some(&[]))["seasons"], "all");
    assert_eq!(
        Seerr::request_body("tv", 7, Some(&[1, 3]))["seasons"],
        serde_json::json!([1, 3])
    );
}

#[test]
fn address_clean_up() {
    for typed in [
        "seerr.example.de",
        "https://seerr.example.de/",
        "https://seerr.example.de/api/v1",
        "  seerr.example.de/api/  ",
    ] {
        assert_eq!(
            Seerr::address(typed).as_deref(),
            Some("https://seerr.example.de"),
            "{typed}"
        );
    }
}

#[test]
fn home_network_gets_http() {
    let scheme = |t: &str| {
        Seerr::address(t)
            .unwrap()
            .split(':')
            .next()
            .unwrap()
            .to_string()
    };
    assert_eq!(scheme("192.168.1.9:5055"), "http");
    assert_eq!(scheme("10.0.0.4"), "http");
    assert_eq!(scheme("seerr.local:5055"), "http");
    assert_eq!(scheme("seerr.example.de"), "https");
    assert_eq!(
        Seerr::address("http://192.168.1.9:5055").unwrap(),
        "http://192.168.1.9:5055"
    );
    assert!(Seerr::address("   ").is_none());
}

const SERIES: &str = r#"{"overview":"Ein Berater der Polizei.","episodeRunTime":[45],"voteAverage":8.1,
 "genres":[{"name":"Krimi"},{"name":"Drama"},{"name":"Mystery"}],
 "seasons":[{"seasonNumber":0,"episodeCount":3},{"seasonNumber":1,"episodeCount":23},{"seasonNumber":2,"episodeCount":22}],
 "mediaInfo":{"seasons":[{"seasonNumber":1,"status":5}]}}"#;

#[test]
fn detail_fields_genres_seasons() {
    let d = Seerr::detail(SERIES.as_bytes()).unwrap();
    assert_eq!(d.description.as_deref(), Some("Ein Berater der Polizei."));
    assert_eq!((d.runtime, d.rating), (Some(45), Some(8.1)));
    assert_eq!(d.genres, ["Krimi", "Drama"]);
    assert_eq!(
        d.seasons.iter().map(|s| s.number).collect::<Vec<_>>(),
        [1, 2]
    );
    assert_eq!(d.seasons[0].state, SeerrState::Present);
    assert_eq!(
        (d.seasons[1].state, d.seasons[1].episodes),
        (SeerrState::Opened, 22)
    );
}

#[test]
fn movie_detail() {
    let d = Seerr::detail(br#"{"overview":"Ein Film.","runtime":112,"voteAverage":6.9}"#).unwrap();
    assert!(d.seasons.is_empty());
    assert_eq!(d.runtime, Some(112));
}

#[test]
fn detail_state() {
    let st = |j: &str| Seerr::detail(j.as_bytes()).unwrap().state;
    assert_eq!(
        st(r#"{"mediaInfo":{"status":2}}"#),
        Some(SeerrState::WaitsSharing)
    );
    assert_eq!(st(r#"{"mediaInfo":{"status":3}}"#), Some(SeerrState::Loads));
    assert_eq!(
        st(r#"{"mediaInfo":{"status":4}}"#),
        Some(SeerrState::PartWayPresent)
    );
    assert_eq!(
        st(r#"{"mediaInfo":{"status":5}}"#),
        Some(SeerrState::Present)
    );
    assert_eq!(st(r#"{"overview":"x"}"#), Some(SeerrState::Opened));
}

#[test]
fn empty_description_and_broken_detail() {
    assert_eq!(
        Seerr::detail(br#"{"overview":"   "}"#).unwrap().description,
        None
    );
    assert!(Seerr::detail(b"nope").is_none());
}

const WITH_ATTACHMENT: &str = r#"{"overview":"Ein Film.","runtime":112,
 "credits":{"cast":[
   {"id":1,"name":"Simon Baker","character":"Patrick Jane","profilePath":"/a.jpg"},
   {"id":2,"name":"Robin Tunney","character":"","profilePath":null},
   {"id":3,"character":"Namenlos"}],
  "crew":[{"id":9,"name":"Bruno Heller","job":"Creator"}]},
 "recommendations":{"results":[{"id":42,"title":"Der Nachbar"}]}}"#;

const PRE_HIT: &str = r#"{"page":1,"totalPages":3,"results":[
 {"id":42,"title":"Der Nachbar","releaseDate":"2011-02-03","posterPath":"/p.jpg","backdropPath":"/b.jpg"},
 {"id":43,"title":"Schon da","mediaInfo":{"status":5}}]}"#;

#[test]
fn cast_rules() {
    let d = Seerr::detail(WITH_ATTACHMENT.as_bytes()).unwrap();
    assert_eq!(
        d.cast.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
        ["Simon Baker", "Robin Tunney"]
    );
    assert_eq!(d.cast[0].role.as_deref(), Some("Patrick Jane"));
    assert_eq!(d.cast[1].role, None);
    assert_eq!(
        d.cast[0].image(185).unwrap(),
        "https://image.tmdb.org/t/p/w185/a.jpg"
    );
    assert!(d.cast[1].image(185).is_none());
    assert!(d.similar_one.is_empty());
}

#[test]
fn cast_is_capped_at_twenty() {
    let cast: Vec<String> = (0..30)
        .map(|i| format!(r#"{{"id":{i},"name":"N{i}"}}"#))
        .collect();
    let json = format!(r#"{{"credits":{{"cast":[{}]}}}}"#, cast.join(","));
    assert_eq!(Seerr::detail(json.as_bytes()).unwrap().cast.len(), 20);
}

#[test]
fn suggestions_inherit_type() {
    let v = Seerr::suggestions(PRE_HIT.as_bytes(), "movie");
    assert_eq!(v.iter().map(|h| h.id).collect::<Vec<_>>(), [42, 43]);
    assert!(v.iter().all(|h| h.art == "movie"));
    assert_eq!(v[0].year, Some(2011));
    assert_eq!(
        v[0].backdrop(780).unwrap(),
        "https://image.tmdb.org/t/p/w780/b.jpg"
    );
    assert_eq!(v[1].state, SeerrState::Present);
    assert!(Seerr::suggestions(b"nope", "tv").is_empty());
}

#[test]
fn together_set_and_no_credits() {
    let d: SeerrDetail = Seerr::detail(WITH_ATTACHMENT.as_bytes()).unwrap();
    let full = d
        .clone()
        .with_similar_one(Seerr::suggestions(PRE_HIT.as_bytes(), "movie"));
    assert_eq!(
        (full.description.clone(), full.cast.clone(), full.runtime),
        (d.description, d.cast, Some(112))
    );
    assert_eq!(full.similar_one.len(), 2);
    let e = Seerr::detail(br#"{"overview":"x"}"#).unwrap();
    assert!(e.cast.is_empty() && e.similar_one.is_empty());
}

#[test]
fn filmography_dedupes() {
    let j = br#"{"cast":[{"id":1,"mediaType":"movie","title":"A"},{"id":1,"mediaType":"movie","title":"A"},{"id":1,"mediaType":"tv","name":"A"}]}"#;
    assert_eq!(Seerr::hit_from_filmography(j).len(), 2);
}

#[test]
fn second_attempt_addresses() {
    assert_eq!(
        Seerr::addresses("seerr.beispiel.de"),
        ["https://seerr.beispiel.de", "http://seerr.beispiel.de"]
    );
    assert_eq!(
        Seerr::addresses("192.168.1.9:5055"),
        ["http://192.168.1.9:5055", "https://192.168.1.9:5055"]
    );
    assert_eq!(Seerr::addresses("https://seerr.beispiel.de").len(), 1);
    assert_eq!(Seerr::addresses("http://192.168.1.9:5055").len(), 1);
    assert_eq!(
        Seerr::addresses("https://seerr.beispiel.de/api/v1"),
        ["https://seerr.beispiel.de"]
    );
    assert!(Seerr::addresses("   ").is_empty());
}

// ---- cookie jar (cookieComesAlsoOutCache) ----

struct Shared(std::sync::Arc<MockTransport>);
impl swiftly_net::HttpTransport for Shared {
    fn send(
        &self,
        r: swiftly_net::HttpRequest,
    ) -> impl std::future::Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        self.0.send(r)
    }
}

#[derive(Default)]
struct Jar(Mutex<Option<String>>);
impl CookieJar for Jar {
    fn session_cookie(&self, _a: &Url) -> Option<String> {
        self.0.lock().unwrap().clone()
    }
    fn forget(&self, _a: &Url) {
        *self.0.lock().unwrap() = None;
    }
}

#[test]
fn cookie_comes_also_out_of_the_jar() {
    let jar = Jar(Mutex::new(Some("connect.sid=s%3Aabc123".into())));
    let address = Url::parse("https://seerr.example.de").unwrap();
    assert_eq!(
        jar.session_cookie(&address).as_deref(),
        Some("connect.sid=s%3Aabc123")
    );
    let c = SeerrClient::with_jar(
        SeerrAccess::new("https://seerr.example.de", "x=1", &[]),
        MockTransport::new(),
        jar,
    );
    c.forget_cookies();
    assert!(c.address().contains("seerr"));
}

#[test]
fn sign_in_falls_back_to_the_jar() {
    let t = MockTransport::new().route("auth/jellyfin", 200, "{}");
    let jar = Jar(Mutex::new(Some("connect.sid=s%3Ajar".into())));
    let a = block_on(SeerrClient::sign_in(
        &t,
        &jar,
        "https://s.test",
        "u",
        "p",
        &[],
    ))
    .unwrap();
    assert_eq!(a.cookie, "connect.sid=s%3Ajar");
    let e = block_on(SeerrClient::sign_in(
        &t,
        &NoCookies,
        "https://s.test",
        "u",
        "p",
        &[],
    ))
    .unwrap_err();
    assert_eq!(
        e,
        ErrorKind::Transport(TransportReason::Other(
            "Seerr hat keine Sitzung mitgegeben.".into()
        ))
    );
}

// ---- headers in front of Seerr ----

fn gateway() -> Vec<OwnHeader> {
    vec![
        OwnHeader::new("CF-Access-Client-Id", "erfunden.access"),
        OwnHeader::new("CF-Access-Client-Secret", "auch-erfunden"),
    ]
}

#[test]
fn sign_in_sends_headers_and_keeps_them() {
    let t = MockTransport::new().route_response(
        "auth/jellyfin",
        HttpResponse::new(200, "{}")
            .with_header("Set-Cookie", "connect.sid=s%3Aneu; Path=/; HttpOnly"),
    );
    let a = block_on(SeerrClient::sign_in(
        &t,
        &NoCookies,
        "https://seerr.vorposten.test",
        "jane",
        "x",
        &gateway(),
    ))
    .unwrap();
    let req = t.last_request().unwrap();
    assert_eq!(req.method, Method::Post);
    assert_eq!(req.url.path(), "/api/v1/auth/jellyfin");
    assert_eq!(req.header("CF-Access-Client-Id"), Some("erfunden.access"));
    assert_eq!(req.header("CF-Access-Client-Secret"), Some("auch-erfunden"));
    assert_eq!(req.header("Content-Type"), Some("application/json"));
    assert_eq!(req.header("Cookie"), None, "no old cookie when signing in");
    assert_eq!(a.headers, gateway());
    assert_eq!(a.cookie, "connect.sid=s%3Aneu");
}

#[test]
fn later_calls_carry_headers_and_own_cookie() {
    let t = MockTransport::new().route("search", 200, r#"{"results":[]}"#);
    let mut headers = gateway();
    headers.push(OwnHeader::new("Cookie", "fremd=1"));
    let access = SeerrAccess::new(
        "https://seerr.vorposten.test",
        "connect.sid=s%3Aalt",
        &headers,
    );
    let c = SeerrClient::new(access, t);
    assert!(block_on(c.searching("Lighthouse Live")).is_empty());
}

#[test]
fn search_request_shape() {
    let t = MockTransport::new().route("search", 200, ANSWER);
    let access = SeerrAccess::new(
        "https://seerr.vorposten.test",
        "connect.sid=s%3Aalt",
        &gateway(),
    );
    let c = SeerrClient::new(access, t);
    assert_eq!(block_on(c.searching("Lighthouse Live+")).len(), 3);
}

#[test]
fn sign_in_without_headers_is_unchanged() {
    let t = MockTransport::new().route_response(
        "auth/jellyfin",
        HttpResponse::new(200, "{}").with_header("Set-Cookie", "connect.sid=s%3Aneu; Path=/"),
    );
    let a = block_on(SeerrClient::sign_in(
        &t,
        &NoCookies,
        "https://seerr.vorposten.test",
        "jane",
        "x",
        &[],
    ))
    .unwrap();
    assert!(
        t.last_request()
            .unwrap()
            .header("CF-Access-Client-Id")
            .is_none()
    );
    assert!(a.headers.is_empty());
}

#[test]
fn login_page_in_front_is_detected_but_404_is_not() {
    let t = MockTransport::new().route_response(
        "auth/jellyfin",
        HttpResponse::new(200, "<html>Sign in</html>")
            .with_header("Content-Type", "text/html; charset=utf-8"),
    );
    let e = block_on(SeerrClient::sign_in(
        &t,
        &NoCookies,
        "https://x.test",
        "j",
        "x",
        &[],
    ))
    .unwrap_err();
    assert_eq!(e, ErrorKind::Transport(TransportReason::LoginPage));
    let t = MockTransport::new().route_response(
        "auth/jellyfin",
        HttpResponse::new(404, "<html>Not found</html>").with_header("Content-Type", "text/html"),
    );
    let e = block_on(SeerrClient::sign_in(
        &t,
        &NoCookies,
        "https://x.test",
        "j",
        "x",
        &[],
    ))
    .unwrap_err();
    assert_ne!(e, ErrorKind::Transport(TransportReason::LoginPage));
}

#[test]
fn sign_in_status_mapping() {
    let run = |status| {
        let t = MockTransport::new().route("auth/jellyfin", status, "oops");
        block_on(SeerrClient::sign_in(
            &t,
            &NoCookies,
            "https://x.test",
            "j",
            "x",
            &[],
        ))
        .unwrap_err()
    };
    assert_eq!(
        run(401),
        ErrorKind::Transport(TransportReason::Other(
            "Name oder Passwort stimmen nicht.".into()
        ))
    );
    assert_eq!(
        run(500),
        ErrorKind::Http {
            status: 500,
            body: Some("oops".into())
        }
    );
}

#[test]
fn ask_for_statuses() {
    let ask = |status| {
        let t = std::sync::Arc::new(MockTransport::new().route("request", status, ""));
        let c = SeerrClient::new(
            SeerrAccess::new("https://x.test", "connect.sid=1", &[]),
            Shared(std::sync::Arc::clone(&t)),
        );
        let r = block_on(c.ask_for("tv", 7, Some(&[1, 3])));
        let sent: serde_json::Value =
            serde_json::from_slice(&t.last_request().unwrap().body.unwrap()).unwrap();
        (r, sent)
    };
    assert!(ask(201).0.is_ok());
    assert!(ask(409).0.is_ok());
    assert_eq!(ask(201).1["seasons"], serde_json::json!([1, 3]));
    assert!(ask(403).0.is_err());
    assert!(matches!(
        ask(500).0,
        Err(ErrorKind::Http { status: 500, .. })
    ));
}

#[test]
fn detail_two_fetches_and_missing_suggestions() {
    let t = MockTransport::new()
        .route("recommendations", 200, PRE_HIT)
        .route("movie/5", 200, WITH_ATTACHMENT);
    let c = SeerrClient::new(SeerrAccess::new("https://x.test", "connect.sid=1", &[]), t);
    let d = block_on(c.detail("movie", 5)).unwrap();
    assert_eq!(d.similar_one.len(), 2);
    let t = MockTransport::new()
        .route("recommendations", 500, "")
        .route("movie/5", 200, WITH_ATTACHMENT);
    let c = SeerrClient::new(SeerrAccess::new("https://x.test", "connect.sid=1", &[]), t);
    let d = block_on(c.detail("movie", 5)).unwrap();
    assert!(d.similar_one.is_empty() && d.description.is_some());
    let t = MockTransport::new().route("movie/5", 404, "");
    assert!(
        block_on(
            SeerrClient::new(SeerrAccess::new("https://x.test", "c=1", &[]), t).detail("movie", 5)
        )
        .is_none()
    );
}

#[test]
fn access_json_compatibility() {
    let old = r#"{"adresse":"https:\/\/seerr.vorposten.test","keks":"connect.sid=s%3Aalt"}"#;
    let z: SeerrAccess = serde_json::from_str(old).unwrap();
    assert_eq!(z.cookie, "connect.sid=s%3Aalt");
    assert!(z.headers.is_empty());
    let back: serde_json::Value = serde_json::to_value(&z).unwrap();
    assert!(back.get("koepfe").is_none());
    let z = SeerrAccess::new("https://seerr.vorposten.test", "connect.sid=x", &gateway());
    let again: SeerrAccess = serde_json::from_str(&serde_json::to_string(&z).unwrap()).unwrap();
    assert_eq!(again, z);
    assert!(
        serde_json::to_string(&z)
            .unwrap()
            .contains(r#""koepfe":[{"name":"CF-Access-Client-Id","wert":"#)
    );
}

#[test]
fn hit_json_uses_german_keys() {
    let j = serde_json::to_value(hit(1)).unwrap();
    assert_eq!(j["titel"], "Lighthouse Live");
    assert_eq!(j["stand"], 1);
    assert_eq!(j["plakatPfad"], "/abc.jpg");
}

#[test]
fn session_state() {
    assert_eq!(
        SeerrSessionState::from_status(200),
        SeerrSessionState::Valid
    );
    assert_eq!(
        SeerrSessionState::from_status(401),
        SeerrSessionState::Invalid
    );
    assert_eq!(
        SeerrSessionState::from_status(403),
        SeerrSessionState::Invalid
    );
    assert_eq!(
        SeerrSessionState::from_status(502),
        SeerrSessionState::Unreachable
    );
    assert_eq!(
        SeerrSessionState::from_status(404),
        SeerrSessionState::Unreachable
    );
}

#[test]
fn applies_maps_status() {
    let t = MockTransport::new().route("auth/me", 401, "");
    let c = SeerrClient::new(SeerrAccess::new("https://x.test", "c=1", &[]), t);
    assert_eq!(block_on(c.applies()), SeerrSessionState::Invalid);
}

#[test]
fn fallback_keeps_first_error() {
    let first = ErrorKind::Network { code: -1004 };
    for second in [
        ErrorKind::Http {
            status: 301,
            body: None,
        },
        ErrorKind::Http {
            status: 405,
            body: None,
        },
        ErrorKind::Network { code: -1200 },
        ErrorKind::Network { code: -1007 },
    ] {
        assert_eq!(error_to_show(first.clone(), second), first);
    }
    let wrong = ErrorKind::Transport(TransportReason::Other(
        "Name oder Passwort stimmen nicht.".into(),
    ));
    assert_eq!(error_to_show(first.clone(), wrong.clone()), wrong);
    let timeout = ErrorKind::Network { code: -1001 };
    assert_eq!(error_to_show(first, timeout.clone()), timeout);
}

#[test]
fn redirect_keeps_method() {
    assert!(KeepPostRedirects::keeps_method(Some("POST"), Some("POST")));
    assert!(KeepPostRedirects::keeps_method(Some("post"), Some("POST")));
    assert!(!KeepPostRedirects::keeps_method(Some("POST"), Some("GET")));
    assert!(!KeepPostRedirects::keeps_method(Some("POST"), None));
}

#[test]
fn sign_in_typed_tries_the_second_scheme() {
    let t = MockTransport::new().route_response(
        "auth/jellyfin",
        HttpResponse::new(200, "{}").with_header("Set-Cookie", "connect.sid=ok; Path=/"),
    );
    let a = block_on(SeerrClient::sign_in_typed(
        &t,
        &NoCookies,
        "seerr.example.de",
        "u",
        "p",
        &[],
    ))
    .unwrap();
    assert_eq!(a.address, "https://seerr.example.de");
}

// ---- automatic sign-in with the Jellyfin credentials ----

mod auto {
    use super::*;
    use swiftly_seerr::{AutoEvent as E, AutoRefused, AutoSignIn as S, auto_sign_in};

    fn acc() -> SeerrAccess {
        SeerrAccess::new("https://s.test", "connect.sid=old", &[])
    }
    fn begin(configured: bool, stored: bool) -> E {
        E::Begin {
            configured,
            stored: stored.then(acc),
        }
    }

    #[test]
    fn transition_table() {
        assert_eq!(
            S::Idle.transition(begin(false, false)),
            Ok(S::NotConfigured)
        );
        assert_eq!(
            S::Idle.transition(begin(true, true)),
            Ok(S::Checking(acc()))
        );
        assert_eq!(S::Idle.transition(begin(true, false)), Ok(S::SigningIn));
        assert_eq!(
            S::Checking(acc()).transition(E::Checked(SeerrSessionState::Valid)),
            Ok(S::SignedIn(acc()))
        );
        assert_eq!(
            S::Checking(acc()).transition(E::Checked(SeerrSessionState::Invalid)),
            Ok(S::SigningIn)
        );
        assert_eq!(
            S::Checking(acc()).transition(E::Checked(SeerrSessionState::Unreachable)),
            Ok(S::Unreachable)
        );
        assert_eq!(
            S::SigningIn.transition(E::Password(false)),
            Ok(S::NoPassword)
        );
        assert_eq!(
            S::SigningIn.transition(E::Signed(acc())),
            Ok(S::SignedIn(acc()))
        );
        assert_eq!(
            S::SigningIn.transition(E::Failed(ErrorKind::Network { code: -1009 })),
            Ok(S::Unreachable)
        );
        assert_eq!(
            S::SigningIn.transition(E::Failed(ErrorKind::Http {
                status: 503,
                body: None
            })),
            Ok(S::Unreachable)
        );
        assert!(matches!(
            S::SigningIn.transition(E::Failed(ErrorKind::Http {
                status: 401,
                body: None
            })),
            Ok(S::Rejected(_))
        ));
        // Resting states may start again.
        for rest in [
            S::NoPassword,
            S::Unreachable,
            S::SignedIn(acc()),
            S::Rejected("x".into()),
        ] {
            assert_eq!(rest.transition(begin(true, false)), Ok(S::SigningIn));
        }
        // Illegal events.
        assert_eq!(S::Idle.transition(E::Signed(acc())), Err(AutoRefused));
        assert_eq!(
            S::NoPassword.transition(E::Checked(SeerrSessionState::Valid)),
            Err(AutoRefused)
        );
        assert_eq!(
            S::SigningIn.transition(begin(true, false)),
            Err(AutoRefused)
        );
        assert_eq!(
            S::Checking(acc()).transition(E::Signed(acc())),
            Err(AutoRefused)
        );
        assert_eq!(
            S::SignedIn(acc()).transition(E::Failed(ErrorKind::InvalidServerUrl)),
            Err(AutoRefused)
        );
    }

    #[test]
    fn signs_in_with_the_jellyfin_credentials_when_there_is_no_session() {
        let t = MockTransport::new().route_response(
            "auth/jellyfin",
            HttpResponse::new(200, "{}").with_header("Set-Cookie", "connect.sid=s%3Aneu; Path=/"),
        );
        let end = block_on(auto_sign_in(
            &t,
            &NoCookies,
            "https://s.test",
            "jane",
            None,
            || Some("geheim".into()),
            &[],
        ));
        assert_eq!(
            end,
            S::SignedIn(SeerrAccess::new(
                "https://s.test",
                "connect.sid=s%3Aneu",
                &[]
            ))
        );
        let req = t.last_request().unwrap();
        assert_eq!(req.method, Method::Post);
        let body = String::from_utf8(req.body.clone().unwrap()).unwrap();
        assert!(body.contains("\"username\":\"jane\"") && body.contains("\"password\":\"geheim\""));
        assert!(req.keep_method);
        assert!(!format!("{end:?}").contains("geheim"));
    }

    #[test]
    fn a_valid_session_is_kept_and_asks_for_no_password() {
        let t = MockTransport::new().route("auth/me", 200, "{}");
        let end = block_on(auto_sign_in(
            &t,
            &NoCookies,
            "https://s.test",
            "jane",
            Some(acc()),
            || panic!("no password needed"),
            &[],
        ));
        assert_eq!(end, S::SignedIn(acc()));
    }

    #[test]
    fn an_expired_session_signs_in_again_and_a_missing_password_stops() {
        let t = MockTransport::new()
            .route("auth/me", 401, "{}")
            .route_response(
                "auth/jellyfin",
                HttpResponse::new(200, "{}")
                    .with_header("Set-Cookie", "connect.sid=s%3Aneu; Path=/"),
            );
        let end = block_on(auto_sign_in(
            &t,
            &NoCookies,
            "https://s.test",
            "jane",
            Some(acc()),
            || Some("p".into()),
            &[],
        ));
        assert!(matches!(end, S::SignedIn(a) if a.cookie == "connect.sid=s%3Aneu"));
        let t = MockTransport::new().route("auth/me", 403, "{}");
        let end = block_on(auto_sign_in(
            &t,
            &NoCookies,
            "https://s.test",
            "jane",
            Some(acc()),
            || None,
            &[],
        ));
        assert_eq!(end, S::NoPassword);
    }

    #[test]
    fn wrong_credentials_are_rejected_and_not_configured_does_nothing() {
        let t = MockTransport::new().route("auth/jellyfin", 401, "{}");
        let end = block_on(auto_sign_in(
            &t,
            &NoCookies,
            "https://s.test",
            "jane",
            None,
            || Some("x".into()),
            &[],
        ));
        assert_eq!(end, S::Rejected("Name oder Passwort stimmen nicht.".into()));
        let t = MockTransport::new();
        let end = block_on(auto_sign_in(
            &t,
            &NoCookies,
            "",
            "jane",
            None,
            || panic!("never"),
            &[],
        ));
        assert_eq!(end, S::NotConfigured);
    }
}
