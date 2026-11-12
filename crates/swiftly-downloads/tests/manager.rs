//! Replay tests of the download manager state machine: intents in, effects out, no I/O.

#![allow(clippy::expect_used)]

mod common;

use std::collections::{HashMap, HashSet};

use common::*;
use swiftly_downloads::{
    Art, DownloadItem, DownloadManagerState, DownloadQuality, DownloadState, DownloadTask, Effect,
    FileKind, Intent, REASON_NOT_ENOUGH_SPACE, Report, RunningTransfer, TaskParts,
};

const GB: i64 = 1_000_000_000;

struct Run {
    m: DownloadManagerState,
}

impl Run {
    fn new(only_over_wlan: bool, next_auto: bool) -> Self {
        Self {
            m: DownloadManagerState::new(1_000, only_over_wlan, next_auto, Box::new(Fake)),
        }
    }

    fn send(&mut self, intent: Intent) -> Vec<Effect> {
        self.m.handle(intent)
    }

    /// Sign in with a stored list and finish the re-attach lookup with nothing found.
    fn signed_in(only_over_wlan: bool, next_auto: bool, stored: Vec<DownloadItem>) -> Self {
        let mut r = Self::new(only_over_wlan, next_auto);
        r.sign_in(stored);
        r.send(Intent::RunningTransfers(vec![]));
        r
    }

    fn sign_in(&mut self, stored: Vec<DownloadItem>) -> Vec<Effect> {
        self.send(Intent::SignIn {
            account: Some("u1".into()),
            stored,
            client: true,
        })
    }

    fn add(&mut self, items: Vec<DownloadItem>) -> Vec<Effect> {
        self.send(Intent::Add {
            items,
            images: HashMap::new(),
            check_space: false,
        })
    }

    fn state_of(&self, id: &str) -> DownloadState {
        self.m.item(id).expect("item").state
    }

    /// Answer the open `RequestAddress` and return the effects of that.
    fn address(&mut self, fx: &[Effect]) -> Vec<Effect> {
        let (id, generation) = fx.iter().find_map(request).expect("a RequestAddress");
        self.send(Intent::AddressReady {
            id,
            generation,
            address: "https://srv/x".into(),
        })
    }
}

fn request(e: &Effect) -> Option<(String, i64)> {
    match e {
        Effect::RequestAddress { id, generation, .. } => Some((id.clone(), *generation)),
        _ => None,
    }
}

fn requests(fx: &[Effect]) -> Vec<String> {
    fx.iter().filter_map(request).map(|r| r.0).collect()
}

fn started(fx: &[Effect]) -> Option<(TaskParts, Option<Vec<u8>>)> {
    fx.iter().find_map(|e| match e {
        Effect::StartTransfer { parts, resume, .. } => Some((parts.clone(), resume.clone())),
        _ => None,
    })
}

fn persisted(fx: &[Effect]) -> Option<&Vec<DownloadItem>> {
    fx.iter().find_map(|e| match e {
        Effect::Persist(list) => Some(list),
        _ => None,
    })
}

fn cancels(fx: &[Effect]) -> usize {
    fx.iter()
        .filter(|e| matches!(e, Effect::CancelTransfer { .. }))
        .count()
}

fn at(id: &str, seconds: f64) -> DownloadItem {
    DownloadItem {
        created: seconds,
        ..entry(id)
    }
}

// MARK: queue two items, one loads at a time

#[test]
fn queue_two_items_one_loads_at_a_time() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![at("b", 20.0), at("a", 10.0)]);
    // The oldest goes first; the other waits.
    assert_eq!(requests(&fx), ["a"]);
    assert_eq!(r.state_of("a"), DownloadState::Loads);
    assert_eq!(r.state_of("b"), DownloadState::Waits);
    // One write per pass, with both entries.
    assert_eq!(persisted(&fx).map(Vec::len), Some(2));
    // A second tick (any change) does not start the other one.
    assert!(requests(&r.send(Intent::Tick)).is_empty());

    let fx = r.address(&fx);
    let (parts, resume) = started(&fx).expect("transfer starts");
    assert_eq!((parts.id.as_str(), parts.file.as_str()), ("a", "u1-a.mkv"));
    assert!(resume.is_none());
    assert!(r.m.is_running("a"));

    // Finishing a hands over to b, exactly once.
    let fx = r.send(Intent::TransferFinished {
        parts,
        worked: true,
        real_size: None,
    });
    assert_eq!(r.state_of("a"), DownloadState::Done);
    assert_eq!(r.m.item("a").expect("a").loaded, GB);
    assert_eq!(requests(&fx), ["b"]);
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::FetchSections { id } if id == "a"))
    );
    assert!(fx.iter().any(|e| matches!(e, Effect::MeasureSpace)));
    assert_eq!(r.state_of("b"), DownloadState::Loads);
}

#[test]
fn nothing_starts_without_a_client() {
    let mut r = Run::new(false, false);
    r.send(Intent::SignIn {
        account: Some("u1".into()),
        stored: vec![],
        client: false,
    });
    r.send(Intent::RunningTransfers(vec![]));
    let fx = r.add(vec![entry("a")]);
    assert!(requests(&fx).is_empty());
    assert_eq!(r.state_of("a"), DownloadState::Waits);
}

#[test]
fn adding_the_same_id_twice_is_ignored() {
    let mut r = Run::signed_in(false, false, vec![]);
    r.add(vec![entry("a"), entry("a")]);
    r.add(vec![entry("a")]);
    assert_eq!(r.m.entries().len(), 1);
}

// MARK: Wi-Fi only

#[test]
fn wifi_only_blocks_on_cellular_and_resumes_on_wifi() {
    let mut r = Run::signed_in(true, false, vec![]);
    // The network is not known yet: nothing starts, nothing stops.
    let fx = r.add(vec![entry("a")]);
    assert!(requests(&fx).is_empty());
    assert_eq!(r.state_of("a"), DownloadState::Waits);
    // Cellular: still nothing.
    let fx = r.send(Intent::NetworkChanged {
        wlan: false,
        none: false,
    });
    assert!(requests(&fx).is_empty());
    assert_eq!(r.state_of("a"), DownloadState::Waits);
    // Wi-Fi: it starts.
    let fx = r.send(Intent::NetworkChanged {
        wlan: true,
        none: false,
    });
    assert_eq!(requests(&fx), ["a"]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");

    // Back to cellular: it goes back into the queue (waiting, not paused), resume data wanted.
    let fx = r.send(Intent::NetworkChanged {
        wlan: false,
        none: false,
    });
    assert_eq!(cancels(&fx), 1);
    assert!(fx.iter().any(|e| matches!(
        e,
        Effect::CancelTransfer {
            want_resume_data: true,
            ..
        }
    )));
    assert_eq!(r.state_of("a"), DownloadState::Waits);
    assert!(!r.m.is_running("a"));
    // The platform's cancellation report arrives late, with the old generation: ignored.
    r.send(Intent::TransferFailed {
        parts: parts.clone(),
        reason: "cancelled".into(),
        resume: None,
    });
    assert_eq!(r.state_of("a"), DownloadState::Waits);
    // The resume data follows the cancel.
    let new_generation = r.m.generation_of("a").expect("generation");
    r.send(Intent::ResumeData {
        id: "a".into(),
        generation: new_generation,
        data: vec![1, 2, 3],
    });

    // Wi-Fi again: it starts with the resume data.
    let fx = r.send(Intent::NetworkChanged {
        wlan: true,
        none: false,
    });
    assert_eq!(requests(&fx), ["a"]);
    let fx = r.address(&fx);
    let (parts2, resume) = started(&fx).expect("running again");
    assert_eq!(resume, Some(vec![1, 2, 3]));
    assert!(parts2.generation > parts.generation);
}

#[test]
fn switching_wifi_only_off_lets_cellular_load() {
    let mut r = Run::signed_in(true, false, vec![]);
    r.send(Intent::NetworkChanged {
        wlan: false,
        none: false,
    });
    assert!(requests(&r.add(vec![entry("a")])).is_empty());
    let fx = r.send(Intent::SetOnlyOverWlan(false));
    assert_eq!(requests(&fx), ["a"]);
}

#[test]
fn unchanged_network_report_does_nothing() {
    let mut r = Run::signed_in(false, false, vec![]);
    let first = r.send(Intent::NetworkChanged {
        wlan: true,
        none: false,
    });
    assert!(
        first
            .iter()
            .any(|e| matches!(e, Effect::Report(Report::Network { .. })))
    );
    assert!(
        r.send(Intent::NetworkChanged {
            wlan: true,
            none: false
        })
        .is_empty()
    );
}

// MARK: space

#[test]
fn space_short_gives_a_failure_reason() {
    let mut r = Run::signed_in(false, false, vec![]);
    r.send(Intent::SpaceChanged(2 * GB));
    // 1 GB reserve: a 5 GB title does not fit; the 0.5 GB one behind it does.
    let big = DownloadItem {
        bytes: 5 * GB,
        ..at("big", 1.0)
    };
    let small = DownloadItem {
        bytes: GB / 2,
        ..at("small", 2.0)
    };
    let fx = r.add(vec![big, small]);
    let item = r.m.item("big").expect("big");
    assert_eq!(item.state, DownloadState::Error);
    assert_eq!(item.reason.as_deref(), Some(REASON_NOT_ENOUGH_SPACE));
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::Report(Report::Failed { id, .. }) if id == "big"))
    );
    // The failure did not block the queue.
    assert_eq!(requests(&fx), ["small"]);
    // Failed titles are kept on the list and the reason is persisted.
    let list = persisted(&fx).expect("persisted");
    assert_eq!(
        list.iter()
            .find(|p| p.id == "big")
            .and_then(|p| p.reason.as_deref()),
        Some(REASON_NOT_ENOUGH_SPACE)
    );
    // Resume after space was freed.
    r.send(Intent::SpaceChanged(50 * GB));
    r.send(Intent::Resume("big".into()));
    assert_eq!(r.state_of("big"), DownloadState::Waits);
}

#[test]
fn sheet_check_refuses_a_batch_that_does_not_fit() {
    let mut r = Run::signed_in(false, false, vec![]);
    r.send(Intent::SpaceChanged(10 * GB));
    let watched_done = DownloadItem {
        state: DownloadState::Done,
        watched: true,
        bytes: 3 * GB,
        ..at("old", 0.0)
    };
    r.add(vec![watched_done]);
    let big = DownloadItem {
        bytes: 20 * GB,
        ..at("big", 1.0)
    };
    let fx = r.send(Intent::Add {
        items: vec![big],
        images: HashMap::new(),
        check_space: true,
    });
    let Some(Report::NotEnoughSpace(info)) = fx.iter().find_map(|e| match e {
        Effect::Report(report @ Report::NotEnoughSpace(_)) => Some(report.clone()),
        _ => None,
    }) else {
        panic!("expected NotEnoughSpace");
    };
    assert!(!info.suffices && !info.suffices_to_clean_up());
    assert_eq!(info.dispensable.len(), 1);
    assert!(r.m.item("big").is_none());
    assert!(persisted(&fx).is_none());
}

#[test]
fn unknown_space_never_blocks() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![DownloadItem {
        bytes: 500 * GB,
        ..entry("huge")
    }]);
    assert_eq!(requests(&fx), ["huge"]);
}

// MARK: relaunch re-attach

#[test]
fn relaunch_reattaches_a_running_transfer() {
    let a = DownloadItem {
        state: DownloadState::Loads,
        bytes: 100,
        loaded: 10,
        ..at("a", 1.0)
    };
    let b = at("b", 2.0);
    let other = DownloadItem {
        account: "u2".into(),
        ..entry("x")
    };
    let mut r = Run::new(false, false);
    let fx = r.sign_in(vec![a, b, other.clone()]);
    // What was mid-download waits again, and the tick holds still until the lookup answers.
    assert!(fx.iter().any(|e| matches!(e, Effect::FindRunningTransfers)));
    assert!(requests(&fx).is_empty());
    assert_eq!(r.state_of("a"), DownloadState::Waits);

    // The system still has a's transfer (generation 77) and one for a title that is gone.
    let desc = DownloadTask::description("a", 77, "u1-a.mkv");
    let ghost = DownloadTask::description("zzz", 5, "u1-zzz.mkv");
    let fx = r.send(Intent::RunningTransfers(vec![
        RunningTransfer {
            description: Some(desc),
            suspended: true,
            bytes_received: 60,
        },
        RunningTransfer {
            description: Some(ghost),
            suspended: false,
            bytes_received: 1,
        },
        RunningTransfer {
            description: Some("garbage".into()),
            suspended: false,
            bytes_received: 1,
        },
    ]));
    assert_eq!(r.state_of("a"), DownloadState::Loads);
    assert!(r.m.is_running("a"));
    assert_eq!(r.m.generation_of("a"), Some(77));
    // Adopted: not started a second time, b keeps waiting, the ghost is cancelled, a resumes.
    assert!(requests(&fx).is_empty());
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::ResumeTransfer { id } if id == "a"))
    );
    assert!(fx.iter().any(
        |e| matches!(e, Effect::CancelTransfer { id, want_resume_data: false, .. } if id == "zzz")
    ));
    assert_eq!(r.m.item("a").expect("a").loaded, 60);
    assert_eq!(r.state_of("b"), DownloadState::Waits);

    // Callbacks with the adopted generation count; the old process's numbers do not matter.
    let parts = TaskParts::new("a", 77, "u1-a.mkv");
    r.send(Intent::Progress {
        parts: parts.clone(),
        loaded: 80,
        total: 100,
        now: 10.0,
    });
    assert_eq!(r.m.item("a").expect("a").loaded, 80);
    let fx = r.send(Intent::TransferFinished {
        parts,
        worked: true,
        real_size: None,
    });
    assert_eq!(r.state_of("a"), DownloadState::Done);
    assert_eq!(requests(&fx), ["b"]);
    // The other account's entry survives the write.
    let list = persisted(&fx).expect("persisted");
    assert!(list.contains(&other));
    assert_eq!(list.first(), Some(&other));
}

#[test]
fn relaunch_without_a_surviving_transfer_starts_again() {
    let a = DownloadItem {
        state: DownloadState::Loads,
        bytes: 100,
        loaded: 10,
        ..at("a", 1.0)
    };
    let mut r = Run::new(false, false);
    r.sign_in(vec![a]);
    let fx = r.send(Intent::RunningTransfers(vec![]));
    assert_eq!(requests(&fx), ["a"]);
}

#[test]
fn a_callback_for_an_unknown_title_is_ignored() {
    // A title that is not on the list: the callback changes nothing and writes nothing.
    let mut r = Run::signed_in(
        false,
        false,
        vec![DownloadItem {
            state: DownloadState::Waits,
            ..entry("a")
        }],
    );
    let late = TaskParts::new("ghost", 3, "f");
    assert!(
        r.send(Intent::TransferFinished {
            parts: late,
            worked: true,
            real_size: None
        })
        .is_empty()
    );
}

#[test]
fn account_switch_stops_the_old_account_and_saves_it_first() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    r.address(&fx);
    let fx = r.send(Intent::SignIn {
        account: Some("u2".into()),
        stored: vec![entry("a")],
        client: true,
    });
    // Old account saved before anything changes, its transfer cancelled, no resume data kept.
    assert!(matches!(fx.first(), Some(Effect::Persist(list)) if list.len() == 1));
    assert_eq!(cancels(&fx), 1);
    assert!(!r.m.is_running("a"));
    // The new account's list shows only its own entries: the stored "a" belongs to u1.
    assert!(r.m.entries().is_empty());
}

// MARK: remove while loading

#[test]
fn remove_while_loading_cancels_deletes_and_ignores_late_callbacks() {
    let mut r = Run::signed_in(false, false, vec![]);
    let item = DownloadItem {
        series_identifier: Some("S".into()),
        art: Art::Episode,
        ..entry("a")
    };
    let fx = r.add(vec![item]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");

    let fx = r.send(Intent::Remove(vec!["a".into()]));
    assert!(fx.iter().any(
        |e| matches!(e, Effect::CancelTransfer { id, want_resume_data: false, .. } if id == "a")
    ));
    let deleted: HashSet<(FileKind, String)> = fx
        .iter()
        .filter_map(|e| match e {
            Effect::DeleteFile { kind, name } => Some((*kind, name.clone())),
            _ => None,
        })
        .collect();
    for expected in [
        (FileKind::Media, "u1-a.mkv"),
        (FileKind::Subtitles, "u1-a.mkv.untertitel"),
        (FileKind::Image, "u1-a.jpg"),
        // It was the last episode of its series: poster and header go too.
        (FileKind::Image, "u1-S.jpg"),
        (FileKind::Image, "u1-S-kopf.jpg"),
    ] {
        assert!(
            deleted.contains(&(expected.0, expected.1.to_owned())),
            "missing {expected:?}"
        );
    }
    assert!(r.m.entries().is_empty());
    assert!(matches!(persisted(&fx), Some(list) if list.is_empty()));
    assert!(fx.iter().any(|e| matches!(e, Effect::MeasureSpace)));
    assert!(!r.m.is_running("a"));

    // The cancellation report and a finished callback of the removed task change nothing.
    assert!(
        r.send(Intent::TransferFailed {
            parts: parts.clone(),
            reason: "x".into(),
            resume: None
        })
        .is_empty()
    );
    assert!(
        r.send(Intent::TransferFinished {
            parts,
            worked: true,
            real_size: None
        })
        .is_empty()
    );
    assert!(r.m.entries().is_empty());
}

#[test]
fn remove_before_the_address_arrives_starts_nothing() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    let (id, generation) = fx.iter().find_map(request).expect("request");
    r.send(Intent::Remove(vec!["a".into()]));
    let fx = r.send(Intent::AddressReady {
        id,
        generation,
        address: "u".into(),
    });
    assert!(started(&fx).is_none());
    assert!(!r.m.is_running("a"));
}

#[test]
fn the_series_poster_stays_while_another_episode_is_left() {
    let mut r = Run::signed_in(false, false, vec![]);
    let e1 = DownloadItem {
        state: DownloadState::Done,
        ..episode_entry("e1", "S", "s1", 1, 1)
    };
    let e2 = DownloadItem {
        state: DownloadState::Done,
        ..episode_entry("e2", "S", "s1", 1, 2)
    };
    r.add(vec![e1, e2]);
    let fx = r.send(Intent::Remove(vec!["e1".into()]));
    assert!(
        !fx.iter()
            .any(|e| matches!(e, Effect::DeleteFile { name, .. } if name == "u1-s1.jpg"))
    );
    let fx = r.send(Intent::Remove(vec!["e2".into()]));
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::DeleteFile { name, .. } if name == "u1-s1.jpg"))
    );
}

// MARK: pause, resume, failures

#[test]
fn a_pause_is_not_an_error() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    let fx = r.send(Intent::Halt("a".into()));
    assert_eq!(cancels(&fx), 1);
    assert_eq!(r.state_of("a"), DownloadState::Halted);
    // The cancellation arrives as an error with the old generation: ignored.
    r.send(Intent::TransferFailed {
        parts,
        reason: "cancelled".into(),
        resume: None,
    });
    assert_eq!(r.state_of("a"), DownloadState::Halted);
    assert!(r.m.item("a").expect("a").reason.is_none());
    // Resume: queues and starts again.
    let fx = r.send(Intent::Resume("a".into()));
    assert_eq!(requests(&fx), ["a"]);
}

#[test]
fn pause_and_quick_resume_ignores_the_old_cancellation() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    let fx = r.address(&fx);
    let (old, _) = started(&fx).expect("running");
    r.send(Intent::Halt("a".into()));
    let fx = r.send(Intent::Resume("a".into()));
    let fx = r.address(&fx);
    let (new, _) = started(&fx).expect("running again");
    // The old task's cancellation lands now; it must not hit the new task.
    r.send(Intent::TransferFailed {
        parts: old,
        reason: "cancelled".into(),
        resume: None,
    });
    assert_eq!(r.state_of("a"), DownloadState::Loads);
    assert!(r.m.is_running("a"));
    r.send(Intent::TransferFinished {
        parts: new,
        worked: true,
        real_size: None,
    });
    assert_eq!(r.state_of("a"), DownloadState::Done);
}

#[test]
fn failure_without_resume_data_is_an_error_with_reason_and_the_next_one_starts() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![at("a", 1.0), at("b", 2.0)]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    let fx = r.send(Intent::TransferFailed {
        parts,
        reason: "HTTP 401".into(),
        resume: None,
    });
    let a = r.m.item("a").expect("a");
    assert_eq!(
        (a.state, a.reason.as_deref()),
        (DownloadState::Error, Some("HTTP 401"))
    );
    assert_eq!(requests(&fx), ["b"]);
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::Report(Report::Failed { id, .. }) if id == "a"))
    );
}

#[test]
fn failure_with_resume_data_is_a_pause() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    r.send(Intent::TransferFailed {
        parts,
        reason: "net".into(),
        resume: Some(vec![9]),
    });
    let a = r.m.item("a").expect("a");
    assert_eq!((a.state, a.reason), (DownloadState::Halted, None));
    // Resuming uses the data.
    let fx = r.send(Intent::Resume("a".into()));
    let fx = r.address(&fx);
    assert_eq!(started(&fx).and_then(|s| s.1), Some(vec![9]));
}

#[test]
fn no_address_fails_the_title() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    let (id, generation) = fx.iter().find_map(request).expect("request");
    r.send(Intent::AddressFailed {
        id,
        generation,
        reason: swiftly_downloads::REASON_NO_ADDRESS.into(),
    });
    let a = r.m.item("a").expect("a");
    assert_eq!(a.state, DownloadState::Error);
    assert_eq!(
        a.reason.as_deref(),
        Some(swiftly_downloads::REASON_NO_ADDRESS)
    );
}

#[test]
fn file_could_not_be_stored() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    r.send(Intent::TransferFinished {
        parts,
        worked: false,
        real_size: None,
    });
    let a = r.m.item("a").expect("a");
    assert_eq!(
        (a.state, a.reason.as_deref()),
        (
            DownloadState::Error,
            Some(swiftly_downloads::REASON_NOT_STORED)
        )
    );
}

#[test]
fn all_halt_pauses_everything_and_all_remove_clears() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![at("a", 1.0), at("b", 2.0), at("c", 3.0)]);
    r.address(&fx);
    r.send(Intent::AllHalt);
    for id in ["a", "b", "c"] {
        assert_eq!(r.state_of(id), DownloadState::Halted, "{id}");
    }
    assert!(!r.m.is_running("a"));
    let fx = r.send(Intent::AllRemove);
    assert!(r.m.entries().is_empty());
    assert_eq!(
        fx.iter()
            .filter(|e| matches!(
                e,
                Effect::DeleteFile {
                    kind: FileKind::Media,
                    ..
                }
            ))
            .count(),
        3
    );
}

// MARK: progress and persistence

#[test]
fn progress_is_live_not_persisted_and_throttled() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![DownloadItem {
        bytes: 0,
        ..entry("a")
    }]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    // The first report always shows; the size comes from the response.
    let fx = r.send(Intent::Progress {
        parts: parts.clone(),
        loaded: 10,
        total: 1_000,
        now: 0.0,
    });
    assert!(fx.is_empty(), "progress never writes the list");
    let a = r.m.item("a").expect("a");
    assert_eq!((a.loaded, a.bytes), (10, 1_000));
    // Too early and too little: not shown.
    r.send(Intent::Progress {
        parts: parts.clone(),
        loaded: 11,
        total: 1_000,
        now: 0.2,
    });
    assert_eq!(r.m.item("a").expect("a").loaded, 10);
    r.send(Intent::Progress {
        parts: parts.clone(),
        loaded: 500,
        total: 1_000,
        now: 2.0,
    });
    assert_eq!(r.m.item("a").expect("a").loaded, 500);
    // A foreign generation is ignored.
    let stale = TaskParts::new("a", parts.generation - 1, "f");
    r.send(Intent::Progress {
        parts,
        loaded: 900,
        total: 1_000,
        now: 9.0,
    });
    r.send(Intent::Progress {
        parts: stale,
        loaded: 1,
        total: 1_000,
        now: 20.0,
    });
    assert_eq!(r.m.item("a").expect("a").loaded, 900);
    // Pausing moves the live numbers into the persisted entry.
    let fx = r.send(Intent::Halt("a".into()));
    let list = persisted(&fx).expect("persisted");
    assert_eq!(list[0].loaded, 900);
}

#[test]
fn a_built_file_starts_from_scratch_and_takes_the_real_size() {
    let mut r = Run::signed_in(false, false, vec![]);
    let small = DownloadItem {
        runtime_ticks: Some(36_000_000_000),
        ..entry("a")
    }
    .in_quality(DownloadQuality::Sd480);
    let estimate = small.bytes;
    let mut partial = small;
    partial.loaded = estimate / 2;
    let fx = r.add(vec![partial]);
    assert_eq!(r.m.item("a").expect("a").loaded, 0);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    r.send(Intent::TransferFinished {
        parts,
        worked: true,
        real_size: Some(123_456),
    });
    let a = r.m.item("a").expect("a");
    assert_eq!(
        (a.bytes, a.loaded, a.state),
        (123_456, 123_456, DownloadState::Done)
    );
}

#[test]
fn a_zero_byte_file_is_an_error_not_done() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![entry("a")]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    r.send(Intent::TransferFinished {
        parts,
        worked: true,
        real_size: Some(0),
    });
    assert_eq!(r.m.item("a").expect("a").state, DownloadState::Error);
}

#[test]
fn changes_in_one_pass_are_written_once() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![at("a", 1.0), at("b", 2.0)]);
    assert_eq!(
        fx.iter()
            .filter(|e| matches!(e, Effect::Persist(_)))
            .count(),
        1
    );
    // Persist is always the last effect of the pass.
    assert!(matches!(fx.last(), Some(Effect::Persist(_))));
}

#[test]
fn images_are_fetched_along() {
    let mut r = Run::signed_in(false, false, vec![]);
    let ep = episode_entry("e1", "S", "s1", 1, 1);
    let images = HashMap::from([
        ("e1".to_owned(), "http://i/e1".to_owned()),
        ("s1".to_owned(), "http://i/s1".to_owned()),
        (
            DownloadManagerState::header_key("s1"),
            "http://i/kopf".to_owned(),
        ),
    ]);
    let fx = r.send(Intent::Add {
        items: vec![ep],
        images,
        check_space: false,
    });
    let names: Vec<(String, String)> = fx
        .iter()
        .filter_map(|e| match e {
            Effect::FetchImage { name, url } => Some((name.clone(), url.clone())),
            _ => None,
        })
        .collect();
    assert_eq!(
        names,
        [
            ("u1-e1.jpg".into(), "http://i/e1".into()),
            ("u1-s1.jpg".into(), "http://i/s1".into()),
            ("u1-s1-kopf.jpg".into(), "http://i/kopf".into()),
        ]
    );
}

#[test]
fn server_follow_marks_missing_titles_and_takes_newer_server_state() {
    use swiftly_model::UserItemData;
    let mut r = Run::signed_in(false, false, vec![]);
    let done = |id: &str| DownloadItem {
        state: DownloadState::Done,
        ..entry(id)
    };
    r.add(vec![done("a"), done("gone")]);
    let state = HashMap::from([(
        "a".to_owned(),
        UserItemData {
            played: Some(true),
            last_played_date: Some("1970-01-01T00:16:40Z".into()),
            ..Default::default()
        },
    )]);
    let fx = r.send(Intent::ServerFollow {
        available: HashSet::from(["a".to_owned()]),
        watch_state: state,
    });
    assert!(r.m.item("a").expect("a").watched);
    assert!(r.m.item("a").expect("a").still_on_the_server);
    assert!(!r.m.item("gone").expect("gone").still_on_the_server);
    assert!(persisted(&fx).is_some());
}

// MARK: next episode

#[test]
fn watched_to_the_end_loads_the_next_episode_and_replaces_the_old_one() {
    let mut r = Run::signed_in(false, true, vec![]);
    r.send(Intent::SpaceChanged(100 * GB));
    let e1 = DownloadItem {
        state: DownloadState::Done,
        runtime_ticks: Some(1_000),
        bytes: 1_000,
        ..episode_entry("e1", "S", "s1", 1, 1)
    };
    r.add(vec![e1]);
    // Watched to the end: marked pending, the successor is looked up.
    let fx = r.send(Intent::PlaybackRemembered {
        id: "e1".into(),
        ticks: 950,
        now: 5.0,
    });
    assert!(fx.iter().any(|e| matches!(e, Effect::LookupSuccessor { id, series_id } if id == "e1" && series_id == "s1")));
    let e1_now = r.m.item("e1").expect("e1");
    assert!(e1_now.watched && e1_now.next_pending == Some(true));
    // A second report while the lookup runs does not start another one.
    let again = r.send(Intent::SmartCatchUp);
    assert!(
        !again
            .iter()
            .any(|e| matches!(e, Effect::LookupSuccessor { .. }))
    );

    let episodes = vec![
        episode_item("e1", 1, 1, vec![]),
        episode_item("e2", 1, 2, vec![]),
    ];
    let fx = r.send(Intent::SuccessorFound {
        id: "e1".into(),
        episodes: Some(episodes),
        image: Some("http://i/e2".into()),
        now: 99.0,
    });
    assert_eq!(requests(&fx), ["e2"]);
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::FetchImage { name, .. } if name == "u1-e2.jpg"))
    );
    let follower = r.m.item("e2").expect("follower");
    assert_eq!(follower.replaces.as_deref(), Some("e1"));
    assert_eq!(follower.created, 99.0);
    assert!(r.m.item("e1").expect("e1").next_pending.is_none());

    // Only when the follower has arrived does the watched episode go.
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("running");
    let fx = r.send(Intent::TransferFinished {
        parts,
        worked: true,
        real_size: None,
    });
    assert!(r.m.item("e1").is_none());
    assert!(fx.iter().any(
        |e| matches!(e, Effect::DeleteFile { kind: FileKind::Media, name } if name == "u1-e1.mkv")
    ));
    assert!(r.m.item("e2").expect("e2").replaces.is_none());
}

#[test]
fn without_an_answer_the_successor_stays_pending() {
    let mut r = Run::signed_in(false, true, vec![]);
    let e1 = DownloadItem {
        state: DownloadState::Done,
        runtime_ticks: Some(1_000),
        ..episode_entry("e1", "S", "s1", 1, 1)
    };
    r.add(vec![e1]);
    r.send(Intent::PlaybackRemembered {
        id: "e1".into(),
        ticks: 990,
        now: 5.0,
    });
    r.send(Intent::SuccessorFound {
        id: "e1".into(),
        episodes: None,
        image: None,
        now: 6.0,
    });
    assert_eq!(r.m.item("e1").expect("e1").next_pending, Some(true));
    // The next contact with the server asks again.
    let fx = r.send(Intent::SmartCatchUp);
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::LookupSuccessor { .. }))
    );
}

#[test]
fn next_episode_off_does_nothing() {
    let mut r = Run::signed_in(false, false, vec![]);
    let e1 = DownloadItem {
        state: DownloadState::Done,
        runtime_ticks: Some(1_000),
        ..episode_entry("e1", "S", "s1", 1, 1)
    };
    r.add(vec![e1]);
    let fx = r.send(Intent::PlaybackRemembered {
        id: "e1".into(),
        ticks: 990,
        now: 5.0,
    });
    assert!(
        !fx.iter()
            .any(|e| matches!(e, Effect::LookupSuccessor { .. }))
    );
    assert!(r.m.item("e1").expect("e1").next_pending.is_none());
}

#[test]
fn the_player_finds_a_finished_file_by_name() {
    let mut r = Run::signed_in(false, false, vec![]);
    r.add(vec![
        DownloadItem {
            state: DownloadState::Done,
            ..entry("a")
        },
        entry("b"),
    ]);
    assert_eq!(r.m.file_for("a").as_deref(), Some("u1-a.mkv"));
    assert_eq!(r.m.file_for("b"), None);
}

#[test]
fn sections_catch_up_and_store() {
    let mut r = Run::signed_in(false, false, vec![]);
    r.add(vec![DownloadItem {
        state: DownloadState::Done,
        ..entry("a")
    }]);
    let fx = r.send(Intent::SectionsCatchUp);
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::FetchSections { id } if id == "a"))
    );
    let fx = r.send(Intent::SectionsFetched {
        id: "a".into(),
        sections: vec![],
    });
    assert_eq!(r.m.item("a").expect("a").sections, Some(vec![]));
    assert!(persisted(&fx).is_some());
    assert!(r.send(Intent::SectionsCatchUp).is_empty());
}

#[test]
fn finished_counts_only_after_the_subtitle_files_are_written() {
    let mut r = Run::signed_in(false, false, vec![]);
    let fx = r.add(vec![at("a", 10.0)]);
    let fx = r.address(&fx);
    let (parts, _) = started(&fx).expect("transfer starts");
    let fx = r.send(Intent::TransferFinished {
        parts,
        worked: true,
        real_size: None,
    });
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::FetchSubtitles { .. }))
    );
    assert!(
        !fx.iter()
            .any(|e| matches!(e, Effect::Report(Report::Done { .. })))
    );
    assert!(r.m.item("a").expect("a").subtitles_pending);
    // A failed fetch keeps it open; the next catch-up asks again.
    r.send(Intent::SubtitlesFetched {
        id: "a".into(),
        ok: false,
    });
    assert!(r.m.item("a").expect("a").subtitles_pending);
    let fx = r.send(Intent::SectionsCatchUp);
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::FetchSubtitles { .. }))
    );
    let fx = r.send(Intent::SubtitlesFetched {
        id: "a".into(),
        ok: true,
    });
    assert!(!r.m.item("a").expect("a").subtitles_pending);
    assert!(
        fx.iter()
            .any(|e| matches!(e, Effect::Report(Report::Done { .. })))
    );
    assert!(persisted(&fx).is_some());
}
