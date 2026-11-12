//! Planted secrets: every value that is a token or password must be absent from `Debug` and error text.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use swiftly_jellyfin::{ServerKind, Session};
use swiftly_net::{ErrorKind, HttpRequest, HttpTransport, Method, ReqwestTransport, Url};

const SECRET: &str = "PLANTED-SECRET-c0ffee42";

fn session() -> Session {
    Session {
        access_token: SECRET.into(),
        user_id: "u1".into(),
        user_name: "paul".into(),
        server_url: format!("https://server.test/?ApiKey={SECRET}"),
        kind: ServerKind::Jellyfin,
    }
}

#[test]
fn session_and_account_debug_hide_tokens() {
    let s = session();
    assert!(!format!("{s:?}").contains(SECRET));
    assert!(
        format!("{s:?}").contains("paul"),
        "non-secret fields stay readable"
    );
    let plex = swiftly_plex::PlexSessionDetails {
        machine_identifier: "m".into(),
        server_name: "n".into(),
        account_token: SECRET.into(),
        is_local: true,
        is_relay: false,
        home_user_uuid: None,
        user_image: None,
    };
    assert!(!format!("{plex:?}").contains(SECRET));
    let account = swiftly_accounts::Account {
        session: s,
        plex: Some(plex),
    };
    assert!(!format!("{account:?}").contains(SECRET));
    let pin = swiftly_plex::PlexPin {
        id: 1,
        code: SECRET.into(),
        auth_token: Some(SECRET.into()),
        expires_in: None,
        expires_at: None,
    };
    assert!(!format!("{pin:?}").contains(SECRET));
}

#[test]
fn image_address_debug_hides_the_token() {
    let base = Url::parse("https://server.test").expect("url");
    let a = swiftly_images::ImageAddress::new(base, Some(SECRET.into()), ServerKind::Jellyfin);
    assert!(!format!("{a:?}").contains(SECRET));
}

#[test]
fn bundle_json_is_only_for_the_secret_store_not_for_debug() {
    let account = swiftly_accounts::Account {
        session: session(),
        plex: None,
    };
    let bundle = swiftly_accounts::AccountBundle::new(account);
    assert!(!format!("{bundle:?}").contains(SECRET));
}

/// A failing request (nothing listens on the port) must not put the query token into the error.
#[test]
fn transport_errors_never_contain_the_query_token() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("rt");
    let t = ReqwestTransport::new().expect("transport");
    for address in [
        format!("http://127.0.0.1:9/Items?ApiKey={SECRET}"),
        format!("http://user:{SECRET}@127.0.0.1:9/x?X-Plex-Token={SECRET}"),
    ] {
        let request = HttpRequest::new(Method::Get, Url::parse(&address).expect("url"));
        let err: ErrorKind = rt.block_on(t.send(request)).expect_err("nothing listens");
        let shown = format!("{err:?}");
        assert!(!shown.contains(SECRET), "{shown}");
    }
    // A broken proxy address errors while the transport is built; that text must not echo the address.
    let bad = swiftly_net::TlsOptions {
        proxy: Some(format!("http://user:{SECRET}@[::bad")),
        ..Default::default()
    };
    if let Err(e) = ReqwestTransport::with_tls(swiftly_net::TransportConfig::default(), &bad) {
        assert!(!format!("{e:?}").contains(SECRET));
    }
}
