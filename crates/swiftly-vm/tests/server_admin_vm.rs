//! The server page against a scripted Jellyfin: the one state (loading, ready, failed, not allowed), the once-and-live
//! reads that run only while the page is on screen, the questions before restart and stop, the finished stream cards,
//! the log screen and the rule for the Profile rows.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Poll, Waker};

use common::account;
use common::script::{Script, host, wait_for};
use swiftly_jellyfin::ServerKind;
use swiftly_l10n::Locale;
use swiftly_net::Method;
use swiftly_vm::{
    HubSectionKind, ServerAdminAsk, ServerAdminIntent, ServerAdminState, ServerAdminVm,
    ServerBadgeKind, ServerLogsIntent, ServerLogsState, ServerLogsVm, Sleeper, profile_entry,
};

/// A real 10 ms between two live reads, so a test sees ticks without a hot loop.
struct Ticks;

impl Sleeper for Ticks {
    fn sleep(&self, _seconds: f64) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        let done = Arc::new(AtomicBool::new(false));
        let waker: Arc<std::sync::Mutex<Option<Waker>>> = Arc::default();
        let (d, w) = (done.clone(), waker.clone());
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(10));
            d.store(true, Ordering::SeqCst);
            if let Some(w) = w.lock().unwrap().take() {
                w.wake();
            }
        });
        Box::pin(std::future::poll_fn(move |cx| {
            *waker.lock().unwrap() = Some(cx.waker().clone());
            if done.load(Ordering::SeqCst) {
                Poll::Ready(())
            } else {
                Poll::Pending
            }
        }))
    }
}

const SESSIONS: &str = r#"[
 {"Id":"s1","UserId":"u","UserName":"Andrey","Client":"Jellyfin Web","DeviceName":"Safari","RemoteEndPoint":"172.30.212.2",
  "NowPlayingItem":{"Id":"m","Name":"Tenzing","Type":"Movie","ProductionYear":2026,"RunTimeTicks":75330000000,
    "ImageTags":{"Primary":"t"},
    "MediaStreams":[{"Type":"Video","Codec":"hevc","Width":3840,"Height":1600,"VideoRangeType":"DOVIWithHDR10","BitRate":25000000,"Index":0},
                    {"Type":"Audio","Codec":"ac3","Channels":6,"BitRate":640000,"Index":1}]},
  "PlayState":{"PositionTicks":0,"IsPaused":true,"PlayMethod":"DirectPlay"}},
 {"Id":"idle","UserName":"X"}]"#;

fn server() -> Arc<Script> {
    Script::new(|r| {
        let path = r.url.path().to_owned();
        match path.as_str() {
            "/System/Info" => Some(r#"{"ServerName":"lysnet","Version":"10.11.2","HasPendingRestart":true}"#.into()),
            "/Items/Counts" => Some(r#"{"MovieCount":1204,"SeriesCount":2,"EpisodeCount":40}"#.into()),
            "/Items" => Some(r#"{"Items":[],"TotalRecordCount":5}"#.into()),
            "/Sessions" => Some(SESSIONS.into()),
            "/ScheduledTasks" => Some(r#"[{"Id":"a","Name":"Scan","State":"Running","CurrentProgressPercentage":42.4}]"#.into()),
            "/System/Info/Storage" => Some(
                r#"{"ProgramDataFolder":{"Path":"/config","FreeSpace":50,"UsedSpace":50,"DeviceId":"/"}}"#.into(),
            ),
            "/System/Logs" => Some(r#"[{"Name":"a.log","Size":1500000,"DateModified":"2026-11-17T10:00:00.0000000Z"}]"#.into()),
            "/System/Logs/Log" => Some("one\ntwo\n".into()),
            p if p.starts_with("/JellyTwiggy/") => None,
            _ => Some("{}".into()),
        }
    })
}

fn vm(net: &Arc<Script>) -> ServerAdminVm<Script> {
    ServerAdminVm::new(net.clone(), host(), Arc::new(Ticks), &account("TOKEN")).unwrap()
}

fn ready(vm: &ServerAdminVm<Script>) -> bool {
    matches!(vm.part().state, ServerAdminState::Ready { .. })
}

fn page(vm: &ServerAdminVm<Script>) -> swiftly_vm::ServerAdminPage {
    match &vm.part().state {
        ServerAdminState::Ready { page } => page.clone(),
        other => panic!("not ready: {other:?}"),
    }
}

fn posts(net: &Script) -> Vec<String> {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.method != Method::Get)
        .map(|r| format!("{:?} {}", r.method, r.url.path()))
        .collect()
}

#[test]
fn the_page_appears_whole_with_counts_tasks_streams_and_drives() {
    let net = server();
    let vm = vm(&net);
    assert!(matches!(vm.part().state, ServerAdminState::Loading));
    assert_eq!(net.urls().len(), 0, "nothing is sent before Start");
    vm.send(ServerAdminIntent::Start);
    wait_for("the page", || ready(&vm));
    let p = page(&vm);
    assert_eq!(
        (p.name.as_str(), p.version.as_str()),
        ("lysnet", "(10.11.2)")
    );
    assert_eq!(vm.part().title, "lysnet");
    assert_eq!(p.counts[0].text, "1.204");
    // No plugin: the filters answer 5 for every bucket -> 4K 5, HD 0, SD 5.
    assert_eq!(
        p.resolutions.iter().map(|n| n.value).collect::<Vec<_>>(),
        [5, 0, 5]
    );
    assert_eq!(
        (
            p.tasks[0].name.as_str(),
            p.tasks[0].progress_text.as_deref()
        ),
        ("Scan", Some("42 %"))
    );
    assert_eq!(p.streams.len(), 1);
    let s = &p.streams[0];
    assert_eq!(s.id, "s1/m");
    assert_eq!(
        s.badges
            .iter()
            .map(|b| (b.kind, b.text.as_str()))
            .collect::<Vec<_>>(),
        [
            (ServerBadgeKind::Resolution, "4K"),
            (ServerBadgeKind::Range, "DV"),
            (ServerBadgeKind::Video, "HEVC"),
            (ServerBadgeKind::Audio, "AC-3 5.1"),
        ]
    );
    assert_eq!(s.delivery_line, "Direct Play · 26 Mb/s");
    assert_eq!(s.device_line, "Safari · Jellyfin Web · 172.30.212.2");
    assert!(!s.cautionary && s.paused);
    assert!(p.load.is_none());
    assert_eq!(
        (p.disks[0].free_text.as_str(), p.disks[0].title.as_str()),
        ("50%", "Jellyfin")
    );
    // A restart waits: the row says so.
    assert!(p.actions[1].accent && p.actions[1].under.is_some());
    vm.send(ServerAdminIntent::Stop);
}

#[test]
fn live_reads_run_only_while_the_page_is_on_screen() {
    let net = server();
    let vm = vm(&net);
    vm.send(ServerAdminIntent::Start);
    wait_for("the page", || ready(&vm));
    wait_for("three live reads", || net.count("/Sessions") >= 3);
    // The counts are read once, however often the live part ticks.
    assert_eq!(net.count("/Items/Counts"), 1);
    vm.send(ServerAdminIntent::Stop);
    std::thread::sleep(std::time::Duration::from_millis(60));
    let after_stop = net.count("/Sessions");
    std::thread::sleep(std::time::Duration::from_millis(120));
    assert_eq!(net.count("/Sessions"), after_stop, "no read after Stop");
    vm.send(ServerAdminIntent::Start);
    wait_for("reading again", || net.count("/Sessions") > after_stop);
    assert_eq!(
        net.count("/Items/Counts"),
        1,
        "the counts are not asked again"
    );
    vm.send(ServerAdminIntent::Stop);
}

#[test]
fn restart_asks_first_and_only_a_yes_sends_it() {
    let net = server();
    let vm = vm(&net);
    vm.send(ServerAdminIntent::Start);
    wait_for("the page", || ready(&vm));
    vm.send(ServerAdminIntent::AskRestart);
    assert!(matches!(page(&vm).ask, ServerAdminAsk::Restart { .. }));
    vm.send(ServerAdminIntent::Cancel);
    assert_eq!(page(&vm).ask, ServerAdminAsk::Nothing);
    assert!(posts(&net).is_empty());
    vm.send(ServerAdminIntent::AskRestart);
    vm.send(ServerAdminIntent::Confirm { message: None });
    wait_for("the restart", || page(&vm).notice.is_some());
    assert_eq!(page(&vm).notice.as_deref(), Some("Der Server startet neu."));
    assert_eq!(posts(&net), ["Post /System/Restart"]);
    vm.send(ServerAdminIntent::Stop);
}

#[test]
fn a_stream_is_stopped_with_the_message_the_administrator_wrote() {
    let net = server();
    let vm = vm(&net);
    vm.send(ServerAdminIntent::Start);
    wait_for("the page", || ready(&vm));
    vm.send(ServerAdminIntent::AskStopStream {
        session_id: "s1".into(),
    });
    let ServerAdminAsk::StopStream { line, message, .. } = page(&vm).ask else {
        panic!("no question")
    };
    assert!(
        line.contains("Tenzing") && line.contains("Andrey"),
        "{line}"
    );
    assert!(!message.is_empty());
    vm.send(ServerAdminIntent::Confirm {
        message: Some("Bis gleich".into()),
    });
    wait_for("stop and message", || posts(&net).len() == 2);
    assert_eq!(
        posts(&net),
        [
            "Post /Sessions/s1/Playing/Stop",
            "Post /Sessions/s1/Message"
        ]
    );
    vm.send(ServerAdminIntent::Stop);
}

#[test]
fn an_account_that_is_no_administrator_is_not_allowed_and_a_failure_can_be_retried() {
    let net = server();
    *net.force.lock().unwrap() = Some((403, "forbidden".into()));
    let vm = vm(&net);
    vm.send(ServerAdminIntent::Start);
    wait_for("not allowed", || {
        matches!(vm.part().state, ServerAdminState::NotAllowed { .. })
    });

    let net = server();
    *net.force.lock().unwrap() = Some((500, "{}".into()));
    let vm = ServerAdminVm::new(net.clone(), host(), Arc::new(Ticks), &account("TOKEN")).unwrap();
    vm.send(ServerAdminIntent::Start);
    wait_for("failed", || {
        matches!(vm.part().state, ServerAdminState::Failed { .. })
    });
    *net.force.lock().unwrap() = None;
    vm.send(ServerAdminIntent::Retry);
    wait_for("ready after retry", || ready(&vm));
    vm.send(ServerAdminIntent::Stop);
}

#[test]
fn the_log_screen_lists_files_opens_one_and_goes_back() {
    let net = server();
    let logs = ServerLogsVm::new(net.clone(), host(), &account("TOKEN")).unwrap();
    logs.send(ServerLogsIntent::Load);
    wait_for("the list", || {
        matches!(logs.part().state, ServerLogsState::Files { .. })
    });
    let ServerLogsState::Files { rows } = logs.part().state.clone() else {
        panic!()
    };
    assert_eq!(
        (
            rows[0].name.as_str(),
            rows[0].size_text.as_str(),
            rows[0].day.as_deref()
        ),
        ("a.log", "1,5 MB", Some("2026-11-17"))
    );
    logs.send(ServerLogsIntent::Open {
        name: "a.log".into(),
    });
    wait_for("the file", || {
        matches!(logs.part().state, ServerLogsState::Text { .. })
    });
    assert_eq!(logs.part().title, "a.log");
    logs.send(ServerLogsIntent::Back);
    assert!(matches!(logs.part().state, ServerLogsState::Files { .. }));
}

#[test]
fn only_a_jellyfin_administrator_gets_the_server_row_and_plex_none() {
    let de = Locale::parse("de");
    let kinds = |k, admin| {
        profile_entry(&de, k, admin, None)
            .map(|e| e.sections.iter().map(|s| s.kind).collect::<Vec<_>>())
    };
    assert_eq!(
        kinds(ServerKind::Jellyfin, true),
        Some(vec![HubSectionKind::Server])
    );
    assert_eq!(kinds(ServerKind::Jellyfin, false), None);
    assert_eq!(kinds(ServerKind::Plex, true), None);
    assert_eq!(kinds(ServerKind::Emby, true), None);
    let mut plex = account("TOKEN");
    plex.server_kind = ServerKind::Plex;
    assert!(ServerAdminVm::new(server(), host(), Arc::new(Ticks), &plex).is_err());
}
