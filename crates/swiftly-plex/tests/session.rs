#![allow(clippy::expect_used, clippy::unwrap_used)]
//! The Plex part of a session: how sign-in builds it, how it is stored and read back (including the
//! broken and the older shapes), and the keys derived from it with and without the Plex block.

use serde_json::json;
use swiftly_jellyfin::ServerKind;
use swiftly_net::ErrorKind;
use swiftly_plex::{
    PlexAccountSession, PlexChosenConnection, PlexError, PlexServerResource, PlexSessionDetails,
    identity_of_address,
};

fn resource(token: Option<&str>) -> PlexServerResource {
    let mut v =
        json!({"clientIdentifier": "MACHINE1", "name": "Home server", "provides": "server"});
    if let Some(t) = token {
        v["accessToken"] = json!(t);
    }
    PlexServerResource::parse(&v).expect("resource")
}

fn connection(uri: &str, local: bool, relay: bool) -> PlexChosenConnection {
    PlexChosenConnection {
        machine_identifier: "MACHINE1".into(),
        uri: uri.into(),
        is_local: local,
        is_relay: relay,
    }
}

fn bare(url: &str) -> PlexAccountSession {
    let full = PlexAccountSession::from_server(
        &resource(None),
        &connection(url, false, false),
        "ACC",
        "42",
        "Ann",
        None,
        None,
    );
    PlexAccountSession { plex: None, ..full }
}

#[test]
fn from_server_uses_the_servers_token_and_keeps_the_account_token_aside() {
    let s = PlexAccountSession::from_server(
        &resource(Some("SHARED")),
        &connection("http://192.168.1.5:32400", true, false),
        "ACC",
        "42",
        "Ann",
        Some("uuid-1"),
        Some("https://plex.tv/u/1.png"),
    );
    assert_eq!(s.session.access_token, "SHARED");
    assert_eq!(s.session.user_id, "42");
    assert_eq!(s.session.user_name, "Ann");
    assert_eq!(s.session.server_url, "http://192.168.1.5:32400");
    assert_eq!(s.session.kind, ServerKind::Plex);
    let p = s.plex.expect("plex block");
    assert_eq!(p.account_token, "ACC");
    assert_eq!(p.machine_identifier, "MACHINE1");
    assert_eq!(p.server_name, "Home server");
    assert!(p.is_local && !p.is_relay);
    assert_eq!(p.home_user_uuid.as_deref(), Some("uuid-1"));
    assert_eq!(p.user_image.as_deref(), Some("https://plex.tv/u/1.png"));
}

#[test]
fn from_server_falls_back_to_the_account_token_for_an_owned_server() {
    let s = PlexAccountSession::from_server(
        &resource(None),
        &connection("https://x.plex.direct:32400", false, true),
        "ACC",
        "7",
        "Bob",
        None,
        None,
    );
    assert_eq!(s.session.access_token, "ACC");
    let p = s.plex.expect("plex block");
    assert!(!p.is_local && p.is_relay);
    assert_eq!(p.home_user_uuid, None);
    assert_eq!(p.user_image, None);
}

#[test]
fn moved_changes_only_the_route_flags() {
    let mut d = PlexSessionDetails::new("M", "Home", "ACC");
    d.home_user_uuid = Some("u".into());
    d.user_image = Some("img".into());
    let to_relay = d.moved(&connection("http://r:1", false, true));
    assert!(to_relay.is_relay && !to_relay.is_local);
    assert_eq!(to_relay.machine_identifier, "M");
    assert_eq!(to_relay.account_token, "ACC");
    assert_eq!(to_relay.home_user_uuid.as_deref(), Some("u"));
    assert_eq!(to_relay.user_image.as_deref(), Some("img"));
    let home = to_relay.moved(&connection("http://l:1", true, false));
    assert!(home.is_local && !home.is_relay);
    // The original is untouched.
    assert!(!d.is_local && !d.is_relay);
}

#[test]
fn debug_never_shows_the_plex_token() {
    let mut d = PlexSessionDetails::new("M", "Home", "SECRET-ACCOUNT-TOKEN");
    d.home_user_uuid = Some("uuid-9".into());
    let text = format!("{d:?}");
    assert!(!text.contains("SECRET-ACCOUNT-TOKEN"));
    assert!(text.contains("[redacted]"));
    assert!(text.contains("uuid-9") && text.contains("Home"));
    let s = PlexAccountSession::from_server(
        &resource(Some("SERVER-SECRET")),
        &connection("http://h:1", false, false),
        "SECRET-ACCOUNT-TOKEN",
        "1",
        "A",
        None,
        None,
    );
    let all = format!("{s:?}");
    assert!(!all.contains("SECRET-ACCOUNT-TOKEN") && !all.contains("SERVER-SECRET"));
}

#[test]
fn to_json_writes_the_plex_block_only_when_present() {
    let with = PlexAccountSession::from_server(
        &resource(Some("T")),
        &connection("http://h:1", true, false),
        "ACC",
        "1",
        "A",
        Some("uu"),
        None,
    );
    let v: serde_json::Value = serde_json::from_str(&with.to_json().expect("encodes")).unwrap();
    assert_eq!(v["plex"]["machineIdentifier"], "MACHINE1");
    assert_eq!(v["plex"]["homeUserUUID"], "uu");
    assert_eq!(v["plex"]["isLocal"], true);
    // An unset optional field is left out, not written as null.
    assert!(v["plex"].get("userImage").is_none());
    let without = bare("http://h:1");
    let v: serde_json::Value = serde_json::from_str(&without.to_json().expect("encodes")).unwrap();
    assert!(v.get("plex").is_none());
    let back = PlexAccountSession::from_json(&without.to_json().unwrap()).expect("decodes");
    assert_eq!(back, without);
}

#[test]
fn from_json_treats_null_and_missing_plex_block_as_none() {
    let base = r#""accessToken":"t","userID":"1","userName":"p","serverURL":"http://h:32400","kind":"plex""#;
    let null =
        PlexAccountSession::from_json(&format!("{{{base},\"plex\":null}}")).expect("null block");
    assert_eq!(null.plex, None);
    assert_eq!(null.session.user_id, "1");
    let missing = PlexAccountSession::from_json(&format!("{{{base}}}")).expect("no block");
    assert_eq!(missing.plex, None);
}

fn decoding(r: Result<PlexAccountSession, PlexError>) -> bool {
    matches!(r, Err(PlexError::Request(ErrorKind::Decoding(_))))
}

#[test]
fn from_json_reports_broken_input_as_a_decoding_error() {
    // Not JSON at all, and JSON that is not an object.
    assert!(decoding(PlexAccountSession::from_json("not json")));
    assert!(decoding(PlexAccountSession::from_json("")));
    assert!(decoding(PlexAccountSession::from_json("[1,2]")));
    // The shared session is incomplete.
    assert!(decoding(PlexAccountSession::from_json(
        r#"{"accessToken":"t"}"#
    )));
    // The Plex block lacks the required machine identifier.
    let json = r#"{"accessToken":"t","userID":"1","userName":"p","serverURL":"http://h","kind":"plex",
        "plex":{"accountToken":"A"}}"#;
    assert!(decoding(PlexAccountSession::from_json(json)));
    // The Plex block is not an object.
    let json = r#"{"accessToken":"t","userID":"1","userName":"p","serverURL":"http://h","kind":"plex","plex":7}"#;
    assert!(decoding(PlexAccountSession::from_json(json)));
}

#[test]
fn without_the_plex_block_keys_fall_back_to_the_address() {
    let s = bare("https://Server.Example.com/");
    assert_eq!(s.account_key(), "plex:https://Server.Example.com/|42");
    assert_eq!(s.server_identity(), "https://server.example.com");
    assert_eq!(s.server_suffix(), "|https://Server.Example.com/");
    // No machine id to put in front: the plain user id.
    assert_eq!(s.storage_account(), "42");
}

#[test]
fn with_the_plex_block_keys_ignore_the_address() {
    let s = PlexAccountSession::from_server(
        &resource(None),
        &connection("http://10.0.0.2:32400", true, false),
        "ACC",
        "42",
        "Ann",
        None,
        None,
    );
    assert_eq!(s.server_identity(), "plex:MACHINE1");
    assert_eq!(s.server_suffix(), "|plex:MACHINE1");
    assert_eq!(s.storage_account(), "plex-MACHINE1-42");
    assert_eq!(s.account_key(), "plex:MACHINE1|42");
}

#[test]
fn identity_of_address_lowercases_and_trims_only_trailing_slashes() {
    assert_eq!(identity_of_address("HTTP://H:1///"), "http://h:1");
    assert_eq!(identity_of_address("http://h:1/path/"), "http://h:1/path");
    assert_eq!(identity_of_address(""), "");
    assert_eq!(identity_of_address("/"), "");
}
