//! The report flow over a fake Seerr: the words go out as one issue, a refusal keeps the form, a sent report stays sent.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;

use futures_executor::block_on;
use swiftly_l10n::Locale;
use swiftly_net::{Method, MockTransport};
use swiftly_seerr::issues::IssueKind;
use swiftly_seerr::{NoCookies, SeerrAccess, SeerrClient};
use swiftly_vm::{
    ReportPhase, SeerrAdminScreen, SeerrHub, SeerrPlace, SeerrReportFlow, Shared, TitleMenuKind,
};

const ADMIN: i64 = 2;

fn base(perms: i64) -> MockTransport {
    MockTransport::new()
        .route(
            "auth/me",
            200,
            &format!(r#"{{"id":2,"displayName":"demo","permissions":{perms}}}"#),
        )
        .route("settings/public", 200, "{}")
        .route("request/count", 200, r#"{"pending":0,"total":0}"#)
        .route("issue/count", 200, r#"{"open":0,"closed":0,"total":0}"#)
        .route(
            "tv/1396",
            200,
            r#"{"id":1396,"name":"Breaking Bad","mediaInfo":{"id":77,"tmdbId":1396,"status":5}}"#,
        )
}

type Flow = Arc<SeerrReportFlow<Shared<MockTransport>, NoCookies>>;

fn flow(world: &Arc<MockTransport>) -> (Flow, Arc<SeerrHub<Shared<MockTransport>, NoCookies>>) {
    let client = SeerrClient::new(
        SeerrAccess::new("https://seerr.test", "connect.sid=x", &[]),
        Shared(Arc::clone(world)),
    );
    let hub = SeerrHub::new(Some(client), "de".into());
    block_on(hub.ensure());
    let admin = SeerrAdminScreen::new(Arc::clone(&hub));
    (SeerrReportFlow::new(admin, Locale::parse("de")), hub)
}

fn posts(world: &MockTransport) -> Vec<String> {
    world
        .requests()
        .iter()
        .filter(|r| r.method == Method::Post && r.url.path().ends_with("/issue"))
        .map(|r| String::from_utf8_lossy(r.body.as_deref().unwrap_or_default()).into_owned())
        .collect()
}

#[test]
fn a_report_goes_out_as_one_issue_with_the_episode_and_the_position() {
    let world = Arc::new(base(ADMIN).route_method(
        Method::Post,
        "issue",
        200,
        r#"{"id":9,"issueType":2,"status":1}"#,
    ));
    let (flow, _) = flow(&world);
    flow.start(SeerrPlace::episode(
        1396,
        "Breaking Bad",
        2,
        3,
        Some(1394.0),
    ));
    flow.set_kind(IssueKind::Audio);
    flow.set_message("Ton läuft versetzt");
    assert_eq!(block_on(flow.send()), ReportPhase::Sent);
    let sent = posts(&world);
    assert_eq!(sent.len(), 1, "one issue");
    for part in [
        "Ton läuft versetzt",
        "\"issueType\":2",
        "\"mediaId\":77",
        "23:14",
    ] {
        assert!(sent[0].contains(part), "{part} in {}", sent[0]);
    }
    // A second press does nothing: it is sent.
    assert_eq!(block_on(flow.send()), ReportPhase::Sent);
    assert_eq!(posts(&world).len(), 1);
    assert_eq!(flow.info().sent_text, "Gemeldet. Danke.");
}

#[test]
fn a_title_seerr_does_not_know_fails_in_words_and_keeps_the_form() {
    let world = Arc::new(base(ADMIN));
    let (flow, _) = flow(&world);
    flow.start(SeerrPlace::title("movie", 999_999, "Unbekannt", None));
    flow.set_message("kaputt");
    let phase = block_on(flow.send());
    assert!(
        matches!(phase, ReportPhase::Failed(ref t) if !t.is_empty()),
        "{phase:?}"
    );
    assert_eq!(flow.info().message, "kaputt");
    assert!(flow.info().can_send, "another try is possible");
}

#[test]
fn nothing_goes_out_without_words() {
    let world = Arc::new(base(ADMIN));
    let (flow, _) = flow(&world);
    flow.start(SeerrPlace::title("tv", 1396, "Breaking Bad", None));
    assert_eq!(block_on(flow.send()), ReportPhase::Editing);
    assert!(posts(&world).is_empty());
}

#[test]
fn the_title_menu_offers_what_the_rights_allow() {
    let world = Arc::new(base(ADMIN));
    let (_, hub) = flow(&world);
    let kinds: Vec<_> = hub.title_menu().iter().map(|e| e.kind).collect();
    assert!(kinds.contains(&TitleMenuKind::ReportProblem));
    assert_eq!(hub.title_menu()[0].text, "Problem melden");
}
