//! The progress reporters (`ClientReporter` for Jellyfin, `PlexReporter` for Plex): strict order
//! through one drain task, the stop lock, kept stops, and what each server is sent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_net::{ErrorKind, HttpRequest, MockTransport};
use swiftly_plex::{PlexClient, PlexIdentity};
use swiftly_vm::{
    ClientReporter, Clock, PendingReport, PendingSink, PlexReporter, ReportKind, ReportMessage,
    Reporter, Shared, Spawner,
};

#[derive(Default)]
struct Kept(Mutex<Vec<PendingReport>>);
impl PendingSink for Kept {
    fn record(&self, report: PendingReport) {
        self.0.lock().unwrap().push(report);
    }
}
impl Kept {
    fn all(&self) -> Vec<PendingReport> {
        self.0.lock().unwrap().clone()
    }
}

struct Inline;
impl Spawner for Inline {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        futures_executor::block_on(task);
    }
}

/// Collects the drain tasks so a test decides when they run.
#[derive(Default)]
struct Deferred(Mutex<Vec<Pin<Box<dyn Future<Output = ()> + Send>>>>);
impl Spawner for Deferred {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        self.0.lock().unwrap().push(task);
    }
}
impl Deferred {
    fn count(&self) -> usize {
        self.0.lock().unwrap().len()
    }
    fn run_all(&self) {
        let tasks: Vec<_> = std::mem::take(&mut *self.0.lock().unwrap());
        for t in tasks {
            futures_executor::block_on(t);
        }
    }
}

struct Fixed;
impl Clock for Fixed {
    fn now(&self) -> f64 {
        42.0
    }
}

fn jellyfin(
    mock: &Arc<MockTransport>,
) -> Arc<swiftly_jellyfin::JellyfinClient<Shared<MockTransport>>> {
    let config = swiftly_jellyfin::ClientConfig::new("dev", "Test", "1.0");
    let c = swiftly_jellyfin::JellyfinClient::new(
        Shared(mock.clone()),
        "https://tv.example.test",
        config,
    )
    .unwrap();
    c.set_session(Some(swiftly_jellyfin::Session {
        access_token: "T".into(),
        user_id: "u".into(),
        user_name: String::new(),
        server_url: "https://tv.example.test".into(),
        kind: swiftly_jellyfin::ServerKind::Jellyfin,
    }));
    Arc::new(c)
}

fn plex(mock: &Arc<MockTransport>) -> Arc<PlexClient<Shared<MockTransport>>> {
    let identity = PlexIdentity::new("client-1", "1.0", "macOS", "Mac", "Test");
    Arc::new(PlexClient::new(
        "https://plex.example.test".parse().unwrap(),
        "TOKEN",
        identity,
        Arc::new(Shared(mock.clone())),
    ))
}

fn msg(kind: ReportKind, item: &str, session: &str, seconds: f64) -> ReportMessage {
    ReportMessage {
        kind,
        item_id: item.into(),
        plan: ReportPlan {
            play_session_id: Some(session.into()),
            media_source_id: Some("m1".into()),
            method: PlayMethod::DirectPlay,
        },
        seconds,
        runtime_ms: None,
        tracks: swiftly_jellyfin::TrackIndices::default(),
    }
}

fn q(r: &HttpRequest, key: &str) -> Option<String> {
    r.url
        .query_pairs()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.into_owned())
}

fn paths(mock: &MockTransport) -> Vec<String> {
    mock.requests()
        .iter()
        .map(|r| r.url.path().to_owned())
        .collect()
}

fn states(mock: &MockTransport) -> Vec<String> {
    mock.requests()
        .iter()
        .map(|r| q(r, "state").unwrap_or_default())
        .collect()
}

fn plex_reporter(
    mock: &Arc<MockTransport>,
    duration_ms: Option<i64>,
    spawner: Arc<dyn Spawner>,
    kept: &Arc<Kept>,
) -> PlexReporter<MockTransport> {
    PlexReporter::new(
        plex(mock),
        "acc",
        duration_ms,
        spawner,
        Arc::new(Fixed),
        kept.clone(),
    )
}

fn jelly_reporter(
    mock: &Arc<MockTransport>,
    spawner: Arc<dyn Spawner>,
    kept: &Arc<Kept>,
) -> ClientReporter<MockTransport> {
    ClientReporter::new(
        jellyfin(mock),
        "acc",
        spawner,
        Arc::new(Fixed),
        kept.clone(),
    )
}

// ---------------------------------------------------------------------- Plex

#[test]
fn plex_sends_one_timeline_post_per_report_with_state_time_and_duration() {
    let mock = Arc::new(MockTransport::new());
    let kept = Arc::new(Kept::default());
    let r = plex_reporter(&mock, Some(120_000), Arc::new(Inline), &kept);
    r.report(msg(ReportKind::Start, "77", "s1", 0.0));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "77",
        "s1",
        10.0,
    ));
    r.report(msg(ReportKind::Progress { paused: true }, "77", "s1", 20.5));
    r.report(msg(ReportKind::Stop, "77", "s1", 30.0));

    assert_eq!(
        paths(&mock),
        vec!["/:/timeline"; 4],
        "no capabilities report on Plex"
    );
    assert_eq!(
        states(&mock),
        vec!["playing", "playing", "paused", "stopped"]
    );
    let reqs = mock.requests();
    assert!(reqs.iter().all(|r| r.method == swiftly_net::Method::Post));
    let times: Vec<_> = reqs.iter().map(|r| q(r, "time").unwrap()).collect();
    assert_eq!(times, vec!["0", "10000", "20500", "30000"], "milliseconds");
    assert!(
        reqs.iter()
            .all(|r| q(r, "ratingKey").as_deref() == Some("77"))
    );
    assert!(
        reqs.iter()
            .all(|r| q(r, "duration").as_deref() == Some("120000"))
    );
    assert!(kept.all().is_empty());
}

#[test]
fn plex_leaves_out_an_unknown_duration() {
    let mock = Arc::new(MockTransport::new());
    let r = plex_reporter(&mock, None, Arc::new(Inline), &Arc::new(Kept::default()));
    r.report(msg(ReportKind::Start, "77", "s1", 1.0));
    assert_eq!(q(&mock.requests()[0], "duration"), None);
}

#[test]
fn plex_drops_late_progress_and_a_second_stop_until_the_next_start() {
    let mock = Arc::new(MockTransport::new());
    let r = plex_reporter(&mock, None, Arc::new(Inline), &Arc::new(Kept::default()));
    r.report(msg(ReportKind::Start, "77", "s1", 0.0));
    r.report(msg(ReportKind::Stop, "77", "s1", 5.0));
    r.report(msg(ReportKind::Progress { paused: false }, "77", "s1", 6.0));
    r.report(msg(ReportKind::Stop, "77", "s1", 7.0));
    assert_eq!(states(&mock), vec!["playing", "stopped"]);

    // The same title played again is a new start and is reported in full.
    r.report(msg(ReportKind::Start, "77", "s1", 0.0));
    r.report(msg(ReportKind::Progress { paused: false }, "77", "s1", 3.0));
    assert_eq!(
        states(&mock),
        vec!["playing", "stopped", "playing", "playing"]
    );
}

#[test]
fn plex_stop_lock_is_per_play_session() {
    let mock = Arc::new(MockTransport::new());
    let r = plex_reporter(&mock, None, Arc::new(Inline), &Arc::new(Kept::default()));
    r.report(msg(ReportKind::Stop, "77", "old", 5.0));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "77",
        "new",
        1.0,
    ));
    assert_eq!(
        states(&mock),
        vec!["stopped", "playing"],
        "another session is not locked"
    );
}

#[test]
fn plex_keeps_a_stop_that_did_not_get_through_but_not_other_reports() {
    let mock =
        Arc::new(MockTransport::new().route_error("timeline", ErrorKind::Network { code: -1009 }));
    let kept = Arc::new(Kept::default());
    let r = plex_reporter(&mock, Some(60_000), Arc::new(Inline), &kept);
    r.report(msg(ReportKind::Start, "77", "s1", 0.0));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "77",
        "s1",
        10.0,
    ));
    assert!(
        kept.all().is_empty(),
        "a lost start or progress is not kept"
    );
    r.report(msg(ReportKind::Stop, "77", "s1", 90.0));
    let k = kept.all();
    assert_eq!(k.len(), 1);
    assert_eq!(
        (k[0].item_id.as_str(), k[0].account.as_str()),
        ("77", "acc")
    );
    assert_eq!(k[0].ticks, 900_000_000);
    assert!(
        (k[0].moment - 42.0).abs() < f64::EPSILON,
        "stamped by the clock"
    );
}

#[test]
fn plex_runs_one_drain_task_in_order_and_starts_another_after_it_ended() {
    let mock = Arc::new(MockTransport::new());
    let spawner = Arc::new(Deferred::default());
    let r = plex_reporter(&mock, None, spawner.clone(), &Arc::new(Kept::default()));
    r.report(msg(ReportKind::Start, "77", "s1", 0.0));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "77",
        "s1",
        10.0,
    ));
    r.report(msg(ReportKind::Progress { paused: true }, "77", "s1", 20.0));
    assert_eq!(
        spawner.count(),
        1,
        "messages queue behind the one drain task"
    );
    assert!(
        mock.requests().is_empty(),
        "nothing is sent before the task runs"
    );
    spawner.run_all();
    // The second progress replaces the first (coalescing: only the newest unsent progress of a session goes out).
    assert_eq!(states(&mock), vec!["playing", "paused"]);

    r.report(msg(ReportKind::Stop, "77", "s1", 30.0));
    assert_eq!(
        spawner.count(),
        1,
        "a finished drain is replaced by a new one"
    );
    spawner.run_all();
    assert_eq!(states(&mock).last().map(String::as_str), Some("stopped"));
}

#[test]
fn plex_a_stop_takes_the_unsent_progress_with_it_and_later_progress_is_not_sent() {
    let mock = Arc::new(MockTransport::new());
    let spawner = Arc::new(Deferred::default());
    let r = plex_reporter(&mock, None, spawner.clone(), &Arc::new(Kept::default()));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "77",
        "s1",
        10.0,
    ));
    r.report(msg(ReportKind::Stop, "77", "s1", 11.0));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "77",
        "s1",
        12.0,
    ));
    spawner.run_all();
    assert_eq!(states(&mock), vec!["stopped"]);
}

// ------------------------------------------------------------------ Jellyfin

#[test]
fn jellyfin_start_reports_capabilities_first_and_survives_their_failure() {
    let mock = Arc::new(
        MockTransport::new().route_error("Capabilities/Full", ErrorKind::InvalidServerUrl),
    );
    let r = jelly_reporter(&mock, Arc::new(Inline), &Arc::new(Kept::default()));
    r.report(msg(ReportKind::Start, "ep1", "s1", 0.0));
    assert_eq!(
        paths(&mock),
        vec!["/Sessions/Capabilities/Full", "/Sessions/Playing"]
    );
}

#[test]
fn jellyfin_runs_one_drain_task_and_a_stop_takes_the_unsent_progress_with_it() {
    let mock = Arc::new(MockTransport::new());
    let spawner = Arc::new(Deferred::default());
    let r = jelly_reporter(&mock, spawner.clone(), &Arc::new(Kept::default()));
    r.report(msg(ReportKind::Progress { paused: true }, "ep1", "s1", 4.0));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "ep1",
        "s1",
        5.0,
    ));
    r.report(msg(ReportKind::Stop, "ep1", "s1", 6.0));
    assert_eq!(spawner.count(), 1);
    assert!(mock.requests().is_empty());
    spawner.run_all();
    assert_eq!(paths(&mock), vec!["/Sessions/Playing/Stopped"]);
}

#[test]
fn jellyfin_keeps_only_a_failed_stop_and_a_new_start_reopens_the_session() {
    let mock = Arc::new(
        MockTransport::new()
            .route_error("Progress", ErrorKind::Network { code: -1005 })
            .route_error("Stopped", ErrorKind::Network { code: -1005 }),
    );
    let kept = Arc::new(Kept::default());
    let r = jelly_reporter(&mock, Arc::new(Inline), &kept);
    r.report(msg(
        ReportKind::Progress { paused: false },
        "ep1",
        "s1",
        4.0,
    ));
    assert!(kept.all().is_empty());
    r.report(msg(ReportKind::Stop, "ep1", "s1", 8.0));
    assert_eq!(kept.all().len(), 1);
    assert_eq!(kept.all()[0].ticks, 80_000_000);

    let before = mock.requests().len();
    r.report(msg(
        ReportKind::Progress { paused: false },
        "ep1",
        "s1",
        9.0,
    ));
    // A stop that did not get through releases the session again (`StopLock::stop_failed`): the position is kept as a
    // pending report and progress goes out as before. After a stop that got through it would be dropped.
    assert_eq!(
        mock.requests().len(),
        before + 1,
        "progress after a failed stop is sent again"
    );
    r.report(msg(ReportKind::Start, "ep1", "s1", 0.0));
    r.report(msg(
        ReportKind::Progress { paused: false },
        "ep1",
        "s1",
        1.0,
    ));
    let after = paths(&mock);
    assert_eq!(
        after[before + 1..],
        [
            "/Sessions/Capabilities/Full",
            "/Sessions/Playing",
            "/Sessions/Playing/Progress"
        ]
    );
}
