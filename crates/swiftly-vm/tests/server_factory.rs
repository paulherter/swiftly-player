//! The server factory and `ServerClient`: which client is built for which account, what a
//! signed-out client knows, and that each call goes to the right server family.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::script::host;
use futures_executor::block_on;
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_net::{ErrorKind, MockTransport};
use swiftly_playback::media_server::ServerCapability;
use swiftly_vm::{
    AccountRef, ServerClient, capabilities_for, make_client, make_client_from_session,
    make_signed_out_client,
};

type Server = ServerClient<MockTransport>;

fn account(kind: ServerKind, url: &str) -> AccountRef {
    AccountRef {
        base_url: url.into(),
        user_id: "u1".into(),
        token: "TOKEN".into(),
        server_kind: kind,
        device_id: "dev-1".into(),
        plex_machine_id: None,
        plex_account_token: None,
    }
}

fn mock(m: MockTransport) -> Arc<MockTransport> {
    Arc::new(m)
}

fn built(kind: ServerKind, url: &str, m: &Arc<MockTransport>) -> Server {
    make_client(m, &host(), &account(kind, url)).unwrap_or_else(|e| panic!("{e:?}"))
}

#[test]
fn each_kind_gets_its_own_client_family() {
    let m = mock(MockTransport::new());
    for (kind, jellyfin_family) in [
        (ServerKind::Jellyfin, true),
        (ServerKind::Emby, true),
        (ServerKind::Plex, false),
    ] {
        let c = built(kind, "https://srv.example.test:8096", &m);
        assert_eq!(c.kind(), kind);
        assert_eq!(
            matches!(c, ServerClient::Jellyfin(_)),
            jellyfin_family,
            "{kind:?}"
        );
        assert_eq!(c.capabilities(), capabilities_for(kind));
        assert!(
            c.base_url().starts_with("https://srv.example.test:8096"),
            "{}",
            c.base_url()
        );
    }
}

#[test]
fn a_known_account_is_signed_in_with_its_token() {
    let m = mock(MockTransport::new());
    let j = built(ServerKind::Jellyfin, "https://srv.example.test", &m);
    let s = j.current_session().expect("session");
    assert_eq!(
        (s.access_token.as_str(), s.user_id.as_str(), s.kind),
        ("TOKEN", "u1", ServerKind::Jellyfin)
    );
    // The plain Plex route has the token but no plex.tv user: there is no session to show.
    let p = built(ServerKind::Plex, "https://plex.example.test", &m);
    assert!(p.current_session().is_none());
}

#[test]
fn unusable_addresses_are_refused_per_family() {
    let m = mock(MockTransport::new());
    let bad = |kind, url: &str| make_client(&m, &host(), &account(kind, url)).err();
    assert_eq!(
        bad(ServerKind::Plex, "not an address"),
        Some(ErrorKind::InvalidServerUrl)
    );
    assert_eq!(
        bad(ServerKind::Plex, "ftp://plex.example.test"),
        Some(ErrorKind::InvalidServerUrl)
    );
    assert_eq!(
        bad(ServerKind::Jellyfin, ""),
        Some(ErrorKind::InvalidServerUrl)
    );
    assert_eq!(
        make_signed_out_client(&m, &host(), ServerKind::Plex, "mailto:x", "d").err(),
        Some(ErrorKind::InvalidServerUrl)
    );
}

#[test]
fn a_stored_session_gives_kind_address_and_token() {
    let m = mock(MockTransport::new());
    let session = Session {
        access_token: "SESSION-TOKEN".into(),
        user_id: "u9".into(),
        user_name: "n".into(),
        server_url: "https://emby.example.test".into(),
        kind: ServerKind::Emby,
    };
    let c = make_client_from_session(&m, &host(), &session, "dev-2")
        .unwrap_or_else(|e| panic!("{e:?}"));
    assert_eq!(c.kind(), ServerKind::Emby);
    let s = c.current_session().expect("session");
    assert_eq!(
        (s.access_token.as_str(), s.user_id.as_str()),
        ("SESSION-TOKEN", "u9")
    );
    assert!(c.base_url().starts_with("https://emby.example.test"));
}

#[test]
fn a_signed_out_client_has_no_session_and_keeps_its_kind() {
    let m = mock(MockTransport::new());
    for kind in [ServerKind::Jellyfin, ServerKind::Emby] {
        let c = make_signed_out_client(&m, &host(), kind, "https://srv.example.test", "dev")
            .unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(c.kind(), kind);
        assert!(c.current_session().is_none(), "{kind:?}");
        assert!(matches!(c, ServerClient::Jellyfin(_)));
    }
    let p = make_signed_out_client(
        &m,
        &host(),
        ServerKind::Plex,
        "https://plex.example.test",
        "dev",
    )
    .unwrap_or_else(|e| panic!("{e:?}"));
    assert!(matches!(p, ServerClient::Plex(_)));
    assert_eq!(p.kind(), ServerKind::Plex);
    assert!(
        p.current_session()
            .is_none_or(|s| s.access_token.is_empty()),
        "no token before plex.tv sign-in"
    );
}

#[test]
fn a_clone_is_the_same_kind_and_address() {
    let m = mock(MockTransport::new());
    for kind in [ServerKind::Jellyfin, ServerKind::Plex] {
        let c = built(kind, "https://srv.example.test", &m);
        let d = c.clone();
        assert_eq!((d.kind(), d.base_url()), (c.kind(), c.base_url()));
    }
}

#[test]
fn jellyfin_reports_who_it_is_from_the_public_info() {
    let body =
        r#"{"ServerName":"Home","Version":"10.9.0","Id":"abc","ProductName":"Jellyfin Server"}"#;
    let m = mock(MockTransport::new().route("/System/Info/Public", 200, body));
    let c = built(ServerKind::Jellyfin, "https://srv.example.test", &m);
    for info in [
        block_on(c.public_system_info()),
        block_on(c.check_reachability()),
    ] {
        let info = info.expect("info");
        assert_eq!(info.server_name.as_deref(), Some("Home"));
        assert_eq!(info.version.as_deref(), Some("10.9.0"));
        assert_eq!(info.id.as_deref(), Some("abc"));
    }
}

#[test]
fn an_unreachable_server_is_an_error_not_a_default() {
    let m = mock(
        MockTransport::new().route_error("/System/Info/Public", ErrorKind::Network { code: -1004 }),
    );
    let c = built(ServerKind::Jellyfin, "https://srv.example.test", &m);
    assert_eq!(
        block_on(c.public_system_info()).err(),
        Some(ErrorKind::Network { code: -1004 })
    );
    assert_eq!(
        block_on(c.check_reachability()).err(),
        Some(ErrorKind::Network { code: -1004 })
    );
}

#[test]
fn plex_reports_its_machine_id_and_version_from_identity() {
    let body = r#"{"MediaContainer":{"machineIdentifier":"plex-machine","version":"1.41.0"}}"#;
    let m = mock(MockTransport::new().route("/identity", 200, body));
    let c = built(ServerKind::Plex, "https://plex.example.test", &m);
    let info = block_on(c.public_system_info()).expect("info");
    assert_eq!(info.id.as_deref(), Some("plex-machine"));
    assert_eq!(info.version.as_deref(), Some("1.41.0"));
    assert_eq!(info.product_name, None);
    let again = block_on(c.check_reachability()).expect("reachable");
    assert_eq!(again.id, info.id);
}

#[test]
fn plex_has_no_password_sign_in_but_jellyfin_has() {
    let m = mock(MockTransport::new().route(
        "/Users/AuthenticateByName",
        200,
        r#"{"AccessToken":"NEW","User":{"Id":"u7","Name":"anna"}}"#,
    ));
    let j = make_signed_out_client(
        &m,
        &host(),
        ServerKind::Jellyfin,
        "https://srv.example.test",
        "dev",
    )
    .unwrap_or_else(|e| panic!("{e:?}"));
    let s = block_on(j.authenticate("anna", "pw")).expect("session");
    assert_eq!((s.access_token.as_str(), s.user_id.as_str()), ("NEW", "u7"));

    let p = built(ServerKind::Plex, "https://plex.example.test", &m);
    assert!(
        block_on(p.authenticate("anna", "pw")).is_err(),
        "Plex signs in at plex.tv"
    );
    assert!(
        m.requests()
            .iter()
            .all(|r| !r.url.host_str().unwrap_or("").contains("plex")),
        "no request was made to Plex"
    );
}

#[test]
fn jellyfin_playlist_entries_keep_video_in_order_and_drop_songs() {
    let body = r#"{"Items":[
        {"Id":"1","Name":"a","Type":"Movie"},
        {"Id":"2","Name":"b","Type":"Audio","MediaType":"Audio"},
        {"Id":"3","Name":"c","Type":"Episode"},
        {"Id":"4","Name":"d","Type":"MusicVideo"}],"TotalRecordCount":4}"#;
    let m = mock(MockTransport::new().route("/Playlists/p1/Items", 200, body));
    let c = built(ServerKind::Jellyfin, "https://srv.example.test", &m);
    let ids: Vec<String> = block_on(c.playlist_entries("p1"))
        .expect("entries")
        .into_iter()
        .map(|i| i.id)
        .collect();
    assert_eq!(ids, vec!["1", "3", "4"]);
}

#[test]
fn plex_playlist_entries_keep_video_only() {
    let body = r#"{"MediaContainer":{"Metadata":[
        {"ratingKey":"10","type":"movie","title":"A"},
        {"ratingKey":"11","type":"track","title":"Song"},
        {"ratingKey":"12","type":"episode","title":"B"}]}}"#;
    let m = mock(MockTransport::new().route("/playlists/p1/items", 200, body));
    let c = built(ServerKind::Plex, "https://plex.example.test", &m);
    let ids: Vec<String> = block_on(c.playlist_entries("p1"))
        .expect("entries")
        .into_iter()
        .map(|i| i.id)
        .collect();
    assert_eq!(ids, vec!["10", "12"]);
}

#[test]
fn a_person_page_is_none_when_the_server_does_not_answer() {
    for kind in [ServerKind::Jellyfin, ServerKind::Plex] {
        let m = mock(MockTransport::new().fallback(swiftly_net::HttpResponse::new(500, "")));
        let c = built(kind, "https://srv.example.test", &m);
        assert!(
            block_on(c.title_with_number_person("p", 20, 0)).is_none(),
            "{kind:?}"
        );
    }
}

#[test]
fn only_jellyfin_offers_the_jellyfin_only_features() {
    for cap in [
        ServerCapability::QuickConnect,
        ServerCapability::SyncPlay,
        ServerCapability::Seerr,
    ] {
        assert!(swiftly_vm::can(ServerKind::Jellyfin, cap));
        assert!(!swiftly_vm::can(ServerKind::Emby, cap));
    }
}
