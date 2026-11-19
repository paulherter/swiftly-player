//! The legacy player core when the switch to the next episode fails: the host (iOS, tvOS, macOS, Android) reads `advance`
//! from every 500 ms tick and calls the switch; a failed switch must not be repeated by the next ticks.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use common::account;
use common::script::{Script, host, wait_for};
use futures_executor::block_on;
use swiftly_cache::{CacheConfig, EntityCache};
use swiftly_vm::{
    LegacyPlayback, PendingReport, PendingSink, ReportDesk, ViewCache, account_client,
};

struct Sink;

impl PendingSink for Sink {
    fn record(&self, _: PendingReport) {}
}

const SOURCES: &str = r#"[{"Id": "s0", "Name": "Fassung", "Container": "mkv", "Size": 1000000000,
 "SupportsDirectPlay": true, "DefaultAudioStreamIndex": 1, "DefaultSubtitleStreamIndex": -1,
 "MediaStreams": [
  {"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080},
  {"Index":1,"Type":"Audio","Codec":"aac","Language":"eng","Channels":2,"IsDefault":true}]}]"#;

/// An episode with a successor whose plan the server cannot give (a 500 on everything about `e2` and `e5`, the
/// episode a user picks). `on_next_plan` runs when the plan of `e2` is asked for, `play_session` names each open.
fn server(
    on_next_plan: impl Fn() + Send + Sync + 'static,
    play_session: impl Fn() -> String + Send + Sync + 'static,
) -> Arc<Script> {
    server_with_segments("{}", on_next_plan, play_session)
}

/// As [`server`], with `segments` as the answer to `/MediaSegments/e1`.
fn server_with_segments(
    segments: &'static str,
    on_next_plan: impl Fn() + Send + Sync + 'static,
    play_session: impl Fn() -> String + Send + Sync + 'static,
) -> Arc<Script> {
    server_of_series(
        segments,
        r#"{"Items": [
            {"Id": "e1", "Name": "Folge 1", "Type": "Episode", "SeriesId": "sr"},
            {"Id": "e2", "Name": "Folge 2", "Type": "Episode", "SeriesId": "sr"}
        ], "TotalRecordCount": 2}"#,
        on_next_plan,
        play_session,
    )
}

/// As [`server_with_segments`], with `episodes` as the answer to `/Shows/sr/Episodes`.
fn server_of_series(
    segments: &'static str,
    episodes: &'static str,
    on_next_plan: impl Fn() + Send + Sync + 'static,
    play_session: impl Fn() -> String + Send + Sync + 'static,
) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path().to_owned();
        if p.contains("/MediaSegments/e1") {
            return Some(segments.to_owned());
        }
        let sources: serde_json::Value = serde_json::from_str(SOURCES).unwrap();
        if p.ends_with("/Items/e1") {
            return Some(
                serde_json::json!({
                    "Id": "e1", "Name": "Folge 1", "Type": "Episode", "SeriesId": "sr",
                    "RunTimeTicks": 15_000_000_000_i64, "MediaSources": sources
                })
                .to_string(),
            );
        }
        if p.ends_with("/Items/e1/PlaybackInfo") {
            return Some(
                serde_json::json!({"MediaSources": sources, "PlaySessionId": play_session()})
                    .to_string(),
            );
        }
        if p.ends_with("/Shows/sr/Episodes") {
            return Some(episodes.to_owned());
        }
        if p.contains("/Items/e2") {
            on_next_plan();
            return None;
        }
        if p.contains("/Items/e5") {
            return None;
        }
        Some("{}".into())
    })
}

fn server_without_the_next_plan() -> Arc<Script> {
    server(|| {}, || "ps1".to_owned())
}

/// The core on `net`, with `host`'s cache if it has one.
fn core_on(net: &Arc<Script>, host: &swiftly_vm::Host) -> LegacyPlayback<Script> {
    let acct = account("T1");
    let client = Arc::new(account_client(net, host, &acct).unwrap());
    let desk = ReportDesk::jellyfin(
        client,
        &acct.user_id,
        Arc::clone(&host.spawner),
        Arc::clone(&host.clock),
        Arc::new(Sink),
    );
    LegacyPlayback::new(net, host, &acct, Arc::new(desk)).unwrap()
}

/// The core's own clock (`Run::now`) is real time: the end-of-file advance waits five seconds after opening.
fn after_the_ramp() {
    std::thread::sleep(std::time::Duration::from_millis(5200));
}

fn posts(net: &Script, suffix: &str) -> usize {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .filter(|q| q.url.path().ends_with(suffix))
        .count()
}

/// The host's side of one tick of the 25-minute file at `position`: the picture runs.
fn tick_at(core: &LegacyPlayback<Script>, position: f64) -> bool {
    let out: serde_json::Value =
        serde_json::from_str(&core.playback_tick(1500.0, position, true, true, true, false, false))
            .unwrap();
    out["weiterschalten"].as_bool().unwrap_or(false)
}

/// A tick at the end of the file.
fn tick(core: &LegacyPlayback<Script>) -> bool {
    tick_at(core, 1499.5)
}

/// The card runs out at the end of the file, the host switches, and the switch fails; the next ticks do not ask again.
fn fail_the_switch_at_the_end(core: &LegacyPlayback<Script>) {
    assert!((0..400).any(|_| tick(core)), "the countdown never ran out");
    let answer = block_on(core.episode_switch("", 1499.5));
    assert!(answer.contains("gescheitert"), "no plan: {answer}");
    assert!((0..20).all(|_| !tick(core)), "a failed attempt is repeated");
}

#[test]
fn a_failed_switch_is_not_repeated_by_the_ticks_that_follow() {
    let net = server_without_the_next_plan();
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    after_the_ramp();

    // The card counts down at the end of the file; when it runs out the tick says "advance" and the host switches.
    let mut attempts = 0;
    let mut failed_at = None;
    for n in 0..400 {
        if tick(&core) {
            attempts += 1;
            let answer = block_on(core.episode_switch("", 1499.5));
            assert!(answer.contains("gescheitert"), "no plan: {answer}");
            failed_at = Some(n);
            break;
        }
    }
    assert!(failed_at.is_some(), "the countdown never ran out");

    // The next twenty ticks (ten seconds) at the end of the same file: a host that follows `advance` must not try again.
    for _ in 0..20 {
        if tick(&core) {
            attempts += 1;
            block_on(core.episode_switch("", 1499.5));
        }
    }
    wait_for("the re-reported start", || {
        posts(&net, "/Sessions/Playing") >= 2
    });
    assert_eq!(attempts, 1, "one attempt per title end");
    assert_eq!(
        net.urls()
            .iter()
            .filter(|u| u.contains("/Items/e2/PlaybackInfo"))
            .count()
            + posts(&net, "/Items/e2"),
        1,
        "the next episode's plan was asked for once"
    );
    assert_eq!(posts(&net, "/Sessions/Playing/Stopped"), 1, "one stop");
    // The old episode runs on after the failed switch, so it reports its start once more (the server saw it stopped);
    // that happens once, not on every tick.
    assert_eq!(
        posts(&net, "/Sessions/Playing"),
        2,
        "start, and one start after the failure"
    );

    // The user can still press Next: a deliberate switch is tried (and fails again, with its notice).
    let again = block_on(core.episode_switch("", 1499.5));
    assert!(again.contains("gescheitert"));
    assert_eq!(posts(&net, "/Sessions/Playing/Stopped"), 2);
}

/// A pick of the user's own that fails is not the switch the tick asks for: the end of the file and the card still
/// advance afterwards (the first version of the latch blocked them for the rest of the title).
#[test]
fn a_failed_pick_of_the_user_leaves_the_advance_at_the_end_alone() {
    let net = server_without_the_next_plan();
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    after_the_ramp();

    let answer = block_on(core.episode_switch("e5", 1400.0));
    assert!(answer.contains("gescheitert"), "no plan for e5: {answer}");

    assert!(
        (0..400).any(|_| tick(&core)),
        "the title ends and the tick never asks to advance"
    );
}

/// A switch that fails late belongs to the title it started on: a title opened meanwhile must not carry its mark.
#[test]
fn a_late_failure_does_not_mark_a_title_opened_meanwhile() {
    let asked = Arc::new(AtomicBool::new(false));
    let opens = Arc::new(AtomicUsize::new(0));
    let net = {
        let asked = Arc::clone(&asked);
        let opens = Arc::clone(&opens);
        server(
            move || {
                asked.store(true, Ordering::SeqCst);
                // The plan request is slow, and then it fails.
                std::thread::sleep(std::time::Duration::from_millis(600));
            },
            move || format!("ps{}", opens.fetch_add(1, Ordering::SeqCst)),
        )
    };
    let core = Arc::new(core_on(&net, &host()));
    block_on(core.open("e1", "")).unwrap();
    let switch = {
        let core = Arc::clone(&core);
        std::thread::spawn(move || block_on(core.episode_switch("", 1499.5)))
    };
    wait_for("the plan request of the next episode", || {
        asked.load(Ordering::SeqCst)
    });
    // The user opens the title again (a new play session) while the switch still waits for its plan.
    block_on(core.open("e1", "")).unwrap();
    let answer = switch.join().unwrap();
    assert!(answer.contains("gescheitert"), "no plan for e2: {answer}");
    after_the_ramp();

    assert!(
        (0..400).any(|_| tick(&core)),
        "the new title was marked by the failure of the old one"
    );
}

/// After a failed switch the end of the file does not ask again, but a seek back well before the end is a new run
/// up to the end: it advances then.
#[test]
fn playing_to_the_end_again_after_a_seek_back_advances_again() {
    let net = server_without_the_next_plan();
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    after_the_ramp();
    fail_the_switch_at_the_end(&core);

    // The user seeks two minutes back (the host reports the jump), and plays on to the end, half a second per tick.
    core.jump_reported(1380.0);
    for _ in 0..4 {
        assert!(!tick_at(&core, 1380.0));
    }
    let second_run = (0..640).map(|n| (1380.0 + 0.5 * f64::from(n)).min(1499.5));
    assert!(
        second_run
            .into_iter()
            .any(|position| tick_at(&core, position)),
        "the second run to the end never asks to advance"
    );
}

/// The link to the server comes back after a real outage: the failure may have been the outage's, so the end of the
/// file asks again.
#[test]
fn an_advance_asks_again_when_the_server_link_comes_back() {
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    let mut host = host();
    host.cache = Some(cache.clone());
    let net = server_without_the_next_plan();
    let core = core_on(&net, &host);
    block_on(core.open("e1", "")).unwrap();
    after_the_ramp();
    fail_the_switch_at_the_end(&core);

    cache.link_came_back();
    assert!(
        (0..400).any(|_| tick(&core)),
        "the end of the file never asks again after the link came back"
    );
}

// MARK: The end of an episode that no outro reaches the end of the file of (17.11.).

/// One tick of a `duration` file at `position`: the picture runs until the end of the file, then it stands there.
fn tick_of(core: &LegacyPlayback<Script>, duration: f64, position: f64) -> (bool, bool) {
    let running = position < duration;
    let out: serde_json::Value = serde_json::from_str(
        &core.playback_tick(duration, position, true, running, true, false, false),
    )
    .unwrap();
    (
        out["einblendung"].as_str() == Some("karte"),
        out["weiterschalten"].as_bool().unwrap_or(false),
    )
}

/// Ticks of 500 ms from `from` to the end of the file and `after` seconds beyond it. Returns the position at which the
/// card first showed and the first position at which the tick asked the host to advance (the end of the file counts
/// as `duration`).
fn walk_to_the_end(
    core: &LegacyPlayback<Script>,
    duration: f64,
    from: f64,
    after: f64,
) -> (Option<f64>, Option<f64>) {
    let (mut card, mut advance) = (None, None);
    let mut position = from;
    let mut beyond = 0.0;
    while beyond < after {
        position = (position + 0.5).min(duration);
        if position >= duration {
            beyond += 0.5;
        }
        let (shows, asks) = tick_of(core, duration, position);
        if shows && card.is_none() {
            card = Some(position);
        }
        if asks && advance.is_none() {
            advance = Some(position + beyond);
        }
    }
    (card, advance)
}

#[test]
fn a_short_episode_without_markers_shows_the_card_in_its_last_seconds_and_then_advances() {
    let net = server_without_the_next_plan();
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    // Two minutes: the long-file rules (over five minutes) offered nothing here before.
    let (card, advance) = walk_to_the_end(&core, 120.0, 100.0, 20.0);
    assert!(
        card.is_some_and(|c| (c - 113.0).abs() <= 0.5),
        "card at {card:?}"
    );
    assert!(
        advance.is_some_and(|a| (a - 121.0).abs() <= 1.0),
        "advance at {advance:?}"
    );
}

#[test]
fn a_long_episode_without_markers_shows_the_short_card_and_not_the_thirty_second_one() {
    let net = server_without_the_next_plan();
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    // Twenty-five minutes, no marker: the card used to open 30 s before the end and count to the end of the file.
    let (card, advance) = walk_to_the_end(&core, 1500.0, 1450.0, 20.0);
    assert!(
        card.is_some_and(|c| (c - 1493.0).abs() <= 0.5),
        "card at {card:?}"
    );
    assert!(
        advance.is_some_and(|a| (a - 1501.0).abs() <= 1.0),
        "advance at {advance:?}"
    );
}

#[test]
fn an_outro_that_ends_a_minute_early_shows_the_card_in_the_last_seconds_and_then_advances() {
    // Outro 1300-1440 s of a 1500 s file.
    let net = server_with_segments(
        r#"{"Items":[{"Type":"Outro","StartTicks":13000000000,"EndTicks":14400000000}]}"#,
        || {},
        || "ps1".to_owned(),
    );
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    let (card, advance) = walk_to_the_end(&core, 1500.0, 1450.0, 20.0);
    // The same short card as a file without markers: no 30 second card for either.
    assert!(
        card.is_some_and(|c| (c - 1493.0).abs() <= 0.5),
        "card at {card:?}"
    );
    assert!(
        advance.is_some_and(|a| (a - 1501.0).abs() <= 1.0),
        "advance at {advance:?}"
    );
}

#[test]
fn cancelling_the_closing_card_leaves_the_end_of_the_file_without_an_advance() {
    let net = server_without_the_next_plan();
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    after_the_ramp();
    let mut position = 100.0;
    while position < 114.0 {
        position += 0.5;
        tick_of(&core, 120.0, position);
    }
    assert!(
        tick_of(&core, 120.0, position).0,
        "no card in the last seconds"
    );
    assert!(core.offering_close(), "Back found no card");
    let (card, advance) = walk_to_the_end(&core, 120.0, position, 30.0);
    assert_eq!(card, None, "the card came back");
    assert_eq!(advance, None, "a cancelled card still advanced");
}

#[test]
fn a_last_episode_gets_no_closing_card() {
    let net = server_of_series(
        "{}",
        r#"{"Items": [{"Id": "e1", "Name": "Folge 1", "Type": "Episode", "SeriesId": "sr"}],
            "TotalRecordCount": 1}"#,
        || {},
        || "ps1".to_owned(),
    );
    let core = core_on(&net, &host());
    block_on(core.open("e1", "")).unwrap();
    let (card, advance) = walk_to_the_end(&core, 120.0, 100.0, 20.0);
    assert_eq!((card, advance), (None, None));
}
