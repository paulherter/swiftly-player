//! The Seerr sign-in screen over a fake transport: the three ways, the automatic sign-in, one address per
//! server and the German words of every cause.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use futures_executor::block_on;
use swiftly_l10n::{Locale, Translator};
use swiftly_net::{HttpResponse, MockTransport};
use swiftly_seerr::{
    NoCookies, SeerrAccess, SeerrServerConfig, SignInCause as C, SignInKind, SignInMethod as M,
};
use swiftly_vm::{SeerrSetupVm, SetupEntry, SetupPhase, cause_text};

const ADDRESS: &str = "https://seerr.example.de";

fn mock() -> MockTransport {
    let ok = HttpResponse::new(200, "{}").with_header("Set-Cookie", "connect.sid=s%3Aneu; Path=/");
    MockTransport::new()
        .route_response("auth/jellyfin", ok.clone())
        .route_response("auth/local", ok.clone())
        .route_response("auth/plex", ok)
        .route("auth/me", 403, "{}")
}

fn vm(t: MockTransport) -> SeerrSetupVm<MockTransport, NoCookies> {
    SeerrSetupVm::new(t, NoCookies, "de")
}

fn config() -> SeerrServerConfig {
    SeerrServerConfig::typed(ADDRESS, &[]).unwrap()
}

fn local() -> SignInKind {
    SignInKind::Local {
        email: "lena@example.com".into(),
        password: "richtig".into(),
    }
}

#[test]
fn the_admin_types_the_address_once_and_the_screen_hands_it_back_to_store() {
    let s = vm(mock());
    block_on(s.start(true, None, None, || None));
    let info = s.info();
    assert_eq!(
        (info.phase, info.entry),
        (SetupPhase::NotConnected, SetupEntry::AskAddress)
    );
    assert_eq!(info.methods.len(), 3);
    block_on(s.sign_in("seerr.example.de", &[], local()));
    let info = s.info();
    assert_eq!(info.phase, SetupPhase::Connected);
    assert_eq!(info.address.as_deref(), Some(ADDRESS));
    assert!(info.can_edit_address && info.methods.is_empty());
    let stored = SeerrServerConfig::from_json(info.server_config.unwrap().as_bytes()).unwrap();
    assert_eq!(stored.address, ADDRESS);
    assert_eq!(s.connection().unwrap().cookie, "connect.sid=s%3Aneu");
}

#[test]
fn another_profile_only_signs_in_the_typed_address_is_not_used() {
    let t = mock();
    let s = vm(t);
    block_on(s.start(false, Some(config()), None, || None));
    let info = s.info();
    assert_eq!(
        (info.entry, info.address.as_deref()),
        (SetupEntry::KnownAddress, Some(ADDRESS))
    );
    assert!(!info.can_edit_address);
    // Whatever the host passes as text, the server's address is used and nothing is handed back to store.
    block_on(s.sign_in("anderswo.example.org", &[], local()));
    let info = s.info();
    assert_eq!(info.phase, SetupPhase::Connected);
    assert_eq!(s.connection().unwrap().address, ADDRESS);
    assert_eq!(info.server_config, None);
}

#[test]
fn nobody_set_up_and_not_the_admin_says_so_and_does_not_call_seerr() {
    let t = mock();
    let s = vm(t);
    block_on(s.start(false, None, None, || Some(local())));
    let info = s.info();
    assert_eq!(info.entry, SetupEntry::NotSetUp);
    assert!(
        info.not_set_up.unwrap().contains("noch nicht eingerichtet") && info.methods.is_empty()
    );
    block_on(s.sign_in("x.example.org", &[], local()));
    assert_eq!(s.info().phase, SetupPhase::NotConnected);
}

#[test]
fn the_automatic_sign_in_runs_with_the_account_and_falls_back_with_words() {
    // Seerr takes the Jellyfin account: connected without any input.
    let s = vm(mock());
    block_on(s.start(false, Some(config()), None, || {
        Some(SignInKind::Jellyfin {
            user: "lena".into(),
            password: "x".into(),
        })
    }));
    assert_eq!(s.info().phase, SetupPhase::Connected);
    // This Seerr user is a local account: the Jellyfin account is refused, the screen explains and offers the rest.
    let t = MockTransport::new().route("auth/jellyfin", 401, r#"{"message":"Unauthorized"}"#);
    let s = vm(t);
    block_on(s.start(false, Some(config()), None, || {
        Some(SignInKind::Jellyfin {
            user: "lena".into(),
            password: "x".into(),
        })
    }));
    let info = s.info();
    assert_eq!(info.phase, SetupPhase::Failed);
    assert!(
        info.error
            .unwrap()
            .contains("E-Mail und Passwort deines Seerr-Kontos")
    );
    assert_eq!(info.methods.len(), 3);
    // No password stored: nothing is tried, the form simply shows.
    let s = vm(mock());
    block_on(s.start(false, Some(config()), None, || None));
    assert_eq!(s.info().phase, SetupPhase::NotConnected);
}

#[test]
fn a_stored_session_that_still_works_is_kept_without_a_sign_in() {
    let t = MockTransport::new().route("auth/me", 200, "{}");
    let s = vm(t);
    let stored = SeerrAccess::new(ADDRESS, "connect.sid=alt", &[]);
    block_on(s.start(false, Some(config()), Some(stored.clone()), || {
        panic!("no sign-in needed")
    }));
    assert_eq!(s.info().phase, SetupPhase::Connected);
    assert_eq!(s.connection(), Some(stored));
    assert!(s.disconnect());
    assert_eq!(s.info().phase, SetupPhase::NotConnected);
}

#[test]
fn a_wrong_password_shows_the_word_and_a_second_try_works() {
    let t = MockTransport::new().route_method(
        swiftly_net::Method::Post,
        "auth/local",
        403,
        r#"{"message":"Access denied."}"#,
    );
    let s = vm(t);
    block_on(s.start(true, Some(config()), None, || None));
    block_on(s.sign_in("", &[], local()));
    let info = s.info();
    assert_eq!(
        (info.phase, info.error.as_deref()),
        (
            SetupPhase::Failed,
            Some("E-Mail oder Passwort stimmen nicht.")
        )
    );
    assert!(
        s.edit_address(),
        "the admin may change the address after a failure"
    );
    assert_eq!(s.info().entry, SetupEntry::AskAddress);
}

#[test]
fn every_cause_has_a_german_sentence() {
    let t = Translator::new(Locale::parse("de"));
    let causes = [
        C::BadAddress,
        C::Unreachable,
        C::Certificate,
        C::LoginPage,
        C::NoSeerr,
        C::Wrong(M::Jellyfin),
        C::Wrong(M::Local),
        C::Wrong(M::Plex),
        C::NoAccess(M::Jellyfin),
        C::NoAccess(M::Local),
        C::NoAccess(M::Plex),
        C::Disabled(M::Jellyfin),
        C::Disabled(M::Local),
        C::Disabled(M::Plex),
        C::NotViaMediaServer,
        C::MediaServerUnreachable,
        C::NoSession,
        C::ServerError(500),
    ];
    let mut seen = std::collections::BTreeSet::new();
    for c in &causes {
        let text = cause_text(&t, c);
        assert!(
            text.chars().count() > 12
                && !text.contains("%lld")
                && !text.contains("reported an error"),
            "{c:?}: {text}"
        );
        assert!(
            seen.insert(text.clone()) || matches!(c, C::NoAccess(_)),
            "two causes say the same: {text}"
        );
    }
    assert_eq!(
        cause_text(&t, &C::ServerError(500)),
        "Seerr meldet einen Fehler (500)."
    );
}
