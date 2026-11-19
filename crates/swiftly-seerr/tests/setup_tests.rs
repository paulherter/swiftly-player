//! Seerr sign-in and setup: the three ways in, the cause of each failure, the per-server configuration and
//! the one state machine, over a fake transport.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use futures_executor::block_on;
use swiftly_jellyfin::OwnHeader;
use swiftly_net::{ErrorKind, HttpResponse, Method, MockTransport};
use swiftly_seerr::setup::{check_session, sign_in};
use swiftly_seerr::{
    AddressEntry, Attempt, NoCookies, SeerrAccess, SeerrServerConfig, SeerrSessionState,
    SeerrSetup as S, SetupEvent as E, SignInCause as C, SignInKind, SignInMethod as M,
};

const ADDRESS: &str = "https://seerr.example.de";

fn cookie_answer() -> HttpResponse {
    HttpResponse::new(200, "{}").with_header("Set-Cookie", "connect.sid=s%3Aneu; Path=/; HttpOnly")
}

fn jellyfin() -> SignInKind {
    SignInKind::Jellyfin {
        user: "lena".into(),
        password: "geheim".into(),
    }
}
fn local() -> SignInKind {
    SignInKind::Local {
        email: "lena@example.com".into(),
        password: "geheim".into(),
    }
}
fn plex() -> SignInKind {
    SignInKind::Plex {
        token: "plex-token".into(),
    }
}

// ---- the three ways in ----

#[test]
fn each_way_posts_its_own_body_to_its_own_path() {
    for (kind, path, body) in [
        (
            jellyfin(),
            "/api/v1/auth/jellyfin",
            r#"{"password":"geheim","username":"lena"}"#,
        ),
        (
            local(),
            "/api/v1/auth/local",
            r#"{"email":"lena@example.com","password":"geheim"}"#,
        ),
        (plex(), "/api/v1/auth/plex", r#"{"authToken":"plex-token"}"#),
    ] {
        let t =
            MockTransport::new().route_response(path.rsplit('/').next().unwrap(), cookie_answer());
        let a = block_on(sign_in(&t, &NoCookies, ADDRESS, &kind, &[])).unwrap();
        let req = t.last_request().unwrap();
        assert_eq!(req.method, Method::Post);
        assert_eq!(req.url.path(), path);
        assert_eq!(req.header("Content-Type"), Some("application/json"));
        assert_eq!(req.header("Cookie"), None, "no old cookie when signing in");
        assert_eq!(String::from_utf8(req.body.unwrap()).unwrap(), body);
        assert_eq!(a.cookie, "connect.sid=s%3Aneu");
        assert_eq!(a.address, ADDRESS);
    }
}

#[test]
fn secrets_never_show_in_debug() {
    let text = format!("{:?} {:?} {:?}", jellyfin(), local(), plex());
    assert!(
        !text.contains("geheim") && !text.contains("plex-token"),
        "{text}"
    );
}

#[test]
fn gateway_headers_go_along_and_stay_with_the_connection() {
    let headers = vec![OwnHeader::new("CF-Access-Client-Id", "id")];
    let t = MockTransport::new().route_response("auth/local", cookie_answer());
    let a = block_on(sign_in(&t, &NoCookies, ADDRESS, &local(), &headers)).unwrap();
    assert_eq!(
        t.last_request().unwrap().header("CF-Access-Client-Id"),
        Some("id")
    );
    assert_eq!(a.headers, headers);
}

#[test]
fn a_typed_address_without_scheme_tries_the_second_one() {
    let t = MockTransport::new().route_response("auth/plex", cookie_answer());
    let a = block_on(sign_in(&t, &NoCookies, "seerr.example.de", &plex(), &[])).unwrap();
    assert_eq!(a.address, ADDRESS);
}

// ---- why a sign-in fails: one cause each ----

fn fails(method_kind: &SignInKind, status: u16, body: &str) -> C {
    let t = MockTransport::new().route(
        match method_kind.method() {
            M::Jellyfin => "auth/jellyfin",
            M::Local => "auth/local",
            M::Plex => "auth/plex",
        },
        status,
        body,
    );
    block_on(sign_in(&t, &NoCookies, ADDRESS, method_kind, &[])).unwrap_err()
}

#[test]
fn causes_of_a_failed_sign_in() {
    // Wrong name, e-mail or password: 401 for Jellyfin, 403 "Access denied." for a local account.
    assert_eq!(
        fails(&jellyfin(), 401, r#"{"message":"Unauthorized"}"#),
        C::Wrong(M::Jellyfin)
    );
    assert_eq!(
        fails(&local(), 403, r#"{"message":"Access denied."}"#),
        C::Wrong(M::Local)
    );
    // A Plex account Seerr does not let in.
    assert_eq!(
        fails(&plex(), 403, r#"{"message":"Access denied."}"#),
        C::NoAccess(M::Plex)
    );
    // Seerr in the other mode: the way is switched off (the old "The server reported an error" 500).
    assert_eq!(
        fails(
            &jellyfin(),
            500,
            r#"{"error":"Jellyfin login is disabled"}"#
        ),
        C::Disabled(M::Jellyfin)
    );
    assert_eq!(
        fails(
            &local(),
            500,
            r#"{"error":"Password sign-in is disabled."}"#
        ),
        C::Disabled(M::Local)
    );
    assert_eq!(
        fails(&plex(), 500, r#"{"error":"Plex login is disabled"}"#),
        C::Disabled(M::Plex)
    );
    // Seerr cannot reach its own media server.
    assert_eq!(
        fails(
            &jellyfin(),
            500,
            r#"{"message":"The provided Jellyfin server URL is invalid or cannot be reached"}"#
        ),
        C::MediaServerUnreachable
    );
    assert_eq!(fails(&jellyfin(), 404, "<html>nope</html>"), C::NoSeerr);
    assert_eq!(fails(&jellyfin(), 502, ""), C::Unreachable);
    assert_eq!(
        fails(&local(), 500, r#"{"message":"Something went wrong"}"#),
        C::ServerError(500)
    );
    assert_eq!(fails(&plex(), 418, ""), C::ServerError(418));
}

#[test]
fn transport_failures_have_their_own_causes() {
    let kind = jellyfin();
    let t = MockTransport::new().route_response(
        "auth/jellyfin",
        HttpResponse::new(200, "<html>Sign in</html>").with_header("Content-Type", "text/html"),
    );
    assert_eq!(
        block_on(sign_in(&t, &NoCookies, ADDRESS, &kind, &[])).unwrap_err(),
        C::LoginPage
    );
    // 200 but no session cookie anywhere.
    let t = MockTransport::new().route("auth/jellyfin", 200, "{}");
    assert_eq!(
        block_on(sign_in(&t, &NoCookies, ADDRESS, &kind, &[])).unwrap_err(),
        C::NoSession
    );
    let t = MockTransport::new().route_error("auth/jellyfin", ErrorKind::Network { code: -1004 });
    assert_eq!(
        block_on(sign_in(&t, &NoCookies, ADDRESS, &kind, &[])).unwrap_err(),
        C::Unreachable
    );
    assert_eq!(
        block_on(sign_in(
            &MockTransport::new(),
            &NoCookies,
            "   ",
            &kind,
            &[]
        ))
        .unwrap_err(),
        C::BadAddress
    );
}

#[test]
fn the_old_jellyfin_calls_keep_their_sentences() {
    use swiftly_seerr::SeerrClient;
    let t = MockTransport::new().route("auth/jellyfin", 403, "{}");
    let e = block_on(SeerrClient::sign_in(&t, &NoCookies, ADDRESS, "a", "b", &[])).unwrap_err();
    assert_eq!(
        e,
        ErrorKind::Transport(swiftly_net::TransportReason::Other(
            "Name oder Passwort stimmen nicht.".into()
        ))
    );
}

#[test]
fn the_stored_session_is_looked_up() {
    let access = SeerrAccess::new(ADDRESS, "connect.sid=a", &[]);
    let t = MockTransport::new().route("auth/me", 200, "{}");
    assert_eq!(
        block_on(check_session::<_, NoCookies>(&t, &access)),
        SeerrSessionState::Valid
    );
    let t = MockTransport::new().route("auth/me", 403, "{}");
    assert_eq!(
        block_on(check_session::<_, NoCookies>(&t, &access)),
        SeerrSessionState::Invalid
    );
}

// ---- configured once per server ----

#[test]
fn the_server_configuration_round_trips_and_cleans_the_address() {
    let headers = vec![OwnHeader::new("X-Gateway", "t")];
    let c = SeerrServerConfig::typed("seerr.example.de/", &headers).unwrap();
    assert_eq!(c.address, ADDRESS);
    assert_eq!(
        SeerrServerConfig::from_json(c.to_json().as_bytes()),
        Some(c)
    );
    assert_eq!(SeerrServerConfig::typed("", &[]), None);
    // Damaged or empty stored values read as "not set up", never as a crash.
    assert_eq!(SeerrServerConfig::from_json(b"kaputt"), None);
    assert_eq!(SeerrServerConfig::from_json(br#"{"address":" "}"#), None);
    assert!(!c_json_has_secret(&SeerrServerConfig::of(
        &SeerrAccess::new(ADDRESS, "connect.sid=geheim", &[])
    )));
}

fn c_json_has_secret(c: &SeerrServerConfig) -> bool {
    c.to_json().contains("sid") || c.to_json().contains("geheim")
}

fn begin(is_admin: bool, config: Option<SeerrServerConfig>, stored: Option<SeerrAccess>) -> S {
    S::new()
        .transition(E::Begin {
            is_admin,
            config,
            stored,
        })
        .unwrap()
}

fn config() -> SeerrServerConfig {
    SeerrServerConfig::typed(ADDRESS, &[]).unwrap()
}

#[test]
fn only_the_admin_is_asked_for_the_address_and_only_once() {
    // Admin, nothing set up: the address row.
    assert_eq!(
        begin(true, None, None),
        S::NotConnected {
            entry: AddressEntry::Ask
        }
    );
    // Another profile of the same server: the address is known, no row; it only signs in.
    let other = begin(false, Some(config()), None);
    assert_eq!(
        other,
        S::NotConnected {
            entry: AddressEntry::Known {
                address: ADDRESS.into(),
                editable: false
            }
        }
    );
    // A profile of a server nobody set up: one sentence, no way to sign in.
    let none = begin(false, None, None);
    assert_eq!(
        none,
        S::NotConnected {
            entry: AddressEntry::NotSetUp
        }
    );
    assert!(none.transition(E::Try(Attempt::By(M::Local))).is_err());
    // Nobody but the admin may change the address.
    assert!(other.transition(E::EditAddress).is_err());
    let admin = begin(true, Some(config()), None);
    assert_eq!(
        admin.transition(E::EditAddress).unwrap(),
        S::NotConnected {
            entry: AddressEntry::Ask
        }
    );
}

#[test]
fn the_admins_first_sign_in_fixes_the_address_for_everyone() {
    let access = SeerrAccess::new(ADDRESS, "connect.sid=a", &[]);
    let s = begin(true, None, None)
        .transition(E::Try(Attempt::By(M::Local)))
        .unwrap()
        .transition(E::Signed(access.clone()))
        .unwrap();
    assert_eq!(
        s,
        S::Connected {
            access,
            entry: AddressEntry::Known {
                address: ADDRESS.into(),
                editable: true
            }
        }
    );
    // "Trennen" keeps the server's address: signing in again needs no new entry.
    assert_eq!(
        s.transition(E::Disconnect).unwrap(),
        S::NotConnected {
            entry: AddressEntry::Known {
                address: ADDRESS.into(),
                editable: true
            }
        }
    );
}

// ---- the one state machine ----

#[test]
fn a_stored_session_is_looked_up_first() {
    let access = SeerrAccess::new(ADDRESS, "connect.sid=a", &[]);
    let looking = begin(false, Some(config()), Some(access.clone()));
    assert!(matches!(
        looking,
        S::SigningIn {
            attempt: Attempt::Session,
            ..
        }
    ));
    let ok = looking
        .clone()
        .transition(E::Checked {
            state: SeerrSessionState::Valid,
            access: access.clone(),
        })
        .unwrap();
    assert!(matches!(ok, S::Connected { .. }));
    // Gone: back to the form (the host then signs in by itself).
    let gone = looking
        .clone()
        .transition(E::Checked {
            state: SeerrSessionState::Invalid,
            access: access.clone(),
        })
        .unwrap();
    assert!(matches!(gone, S::NotConnected { .. }));
    let off = looking
        .transition(E::Checked {
            state: SeerrSessionState::Unreachable,
            access,
        })
        .unwrap();
    assert!(matches!(
        off,
        S::Failed {
            cause: C::Unreachable,
            ..
        }
    ));
}

#[test]
fn a_refused_automatic_sign_in_asks_for_the_other_ways() {
    let signing = begin(false, Some(config()), None)
        .transition(E::Try(Attempt::Automatic))
        .unwrap();
    for cause in [
        C::Wrong(M::Jellyfin),
        C::NoAccess(M::Jellyfin),
        C::Disabled(M::Jellyfin),
    ] {
        let failed = signing.clone().transition(E::Failed(cause)).unwrap();
        assert!(matches!(
            failed,
            S::Failed {
                cause: C::NotViaMediaServer,
                ..
            }
        ));
        // The failure keeps the form: the next try is the user's choice.
        assert!(failed.transition(E::Try(Attempt::By(M::Local))).is_ok());
    }
    // A network failure stays what it is.
    let failed = signing.transition(E::Failed(C::Unreachable)).unwrap();
    assert!(matches!(
        failed,
        S::Failed {
            cause: C::Unreachable,
            ..
        }
    ));
}

#[test]
fn moves_in_the_wrong_state_are_refused() {
    let access = SeerrAccess::new(ADDRESS, "connect.sid=a", &[]);
    let signing = begin(true, None, None)
        .transition(E::Try(Attempt::By(M::Plex)))
        .unwrap();
    // Never two runs at once, never a new Begin in the middle of one.
    assert!(
        signing
            .clone()
            .transition(E::Try(Attempt::By(M::Local)))
            .is_err()
    );
    assert!(
        signing
            .clone()
            .transition(E::Begin {
                is_admin: true,
                config: None,
                stored: None
            })
            .is_err()
    );
    assert!(signing.clone().transition(E::Disconnect).is_err());
    // A result without a sign-in running.
    assert!(
        begin(true, None, None)
            .transition(E::Signed(access.clone()))
            .is_err()
    );
    assert!(
        begin(true, None, None)
            .transition(E::Failed(C::Unreachable))
            .is_err()
    );
    // The session look-up is not a sign-in.
    assert!(
        begin(false, Some(config()), None)
            .transition(E::Try(Attempt::Session))
            .is_err()
    );
}
