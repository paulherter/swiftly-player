//! Tests for the last single calls and the Quick Connect wait (mock transport).
#![allow(clippy::expect_used)]

use futures_executor::block_on;
use std::cell::Cell;
use swiftly_jellyfin::{
    ClientConfig, DownloadConversion, JellyfinClient, LoginCode, QuickConnectState,
    QuickConnectWait, ServerKind, Session, WaitClock, WaitEvent,
};
use swiftly_net::{ErrorKind, HttpResponse, MockTransport};

fn client(mock: MockTransport, kind: ServerKind) -> JellyfinClient<MockTransport> {
    let c = JellyfinClient::new(
        mock,
        "https://tv.example.de",
        ClientConfig::new("dev1", "Test", "1.0").kind(kind),
    )
    .expect("client");
    c.set_session(Some(Session {
        access_token: "TOKEN".into(),
        user_id: "u1".into(),
        user_name: "n".into(),
        server_url: "https://tv.example.de".into(),
        kind,
    }));
    c
}

fn last_url(c: &JellyfinClient<MockTransport>) -> String {
    c.transport().last_request().expect("req").url.to_string()
}

#[test]
fn download_url_plain_has_no_play_session() {
    let c = client(MockTransport::new(), ServerKind::Jellyfin);
    let u = c.download_url("i1", Some("s1"), None, None).unwrap();
    assert_eq!(
        u.as_str(),
        "https://tv.example.de/Videos/i1/stream?static=true&ApiKey=TOKEN&mediaSourceId=s1"
    );
}

#[test]
fn download_url_converted_and_track_only() {
    let c = client(MockTransport::new(), ServerKind::Jellyfin);
    let conv = DownloadConversion {
        video_bitrate: 4_000_000,
        audio_bitrate: 128_000,
        height: 720,
        width: 1280,
        channels: 2,
    };
    let u = c
        .download_url("i1", Some("s1"), Some(conv), Some(3))
        .unwrap();
    let s = u.as_str();
    assert!(s.starts_with("https://tv.example.de/Videos/i1/stream.mkv?static=false&container=mkv&videoCodec=h264&audioCodec=aac&videoBitRate=4000000&audioBitRate=128000&maxAudioChannels=2&maxHeight=720&maxWidth=1280&AudioStreamIndex=3&deviceId=dev1&"), "{s}");
    assert!(s.ends_with("&mediaSourceId=s1"));
    let u = c.download_url("i1", None, None, Some(2)).unwrap();
    assert!(u.as_str().contains("videoCodec=copy&audioCodec=copy&allowVideoStreamCopy=true&allowAudioStreamCopy=true&AudioStreamIndex=2"));
}

#[test]
fn download_bolt_is_explicit_false_only_and_resets_on_account_switch() {
    let c = client(MockTransport::new(), ServerKind::Jellyfin);
    c.remember_download_allowed(Some(false));
    for r in [
        c.download_url("i1", None, None, None),
        c.download_url("i1", None, None, Some(1)),
    ] {
        assert_eq!(
            r.unwrap_err(),
            ErrorKind::Http {
                status: 403,
                body: Some("EnableContentDownloading".into())
            }
        );
    }
    c.remember_download_allowed(Some(true));
    assert!(c.download_url("i1", None, None, None).is_ok());
    c.remember_download_allowed(Some(false));
    c.set_session(c.current_session());
    assert_eq!(c.download_allowed(), None);
    assert!(c.download_url("i1", None, None, None).is_ok());
}

#[test]
fn user_data_raw_round_trip() {
    let c = client(
        MockTransport::new().route("/UserItems/i1/UserData", 200, r#"{"PlayCount":3}"#),
        ServerKind::Jellyfin,
    );
    let raw = block_on(c.user_data_raw("i1")).unwrap();
    assert_eq!(raw, br#"{"PlayCount":3}"#);
    assert_eq!(
        last_url(&c),
        "https://tv.example.de/UserItems/i1/UserData?userId=u1"
    );
    block_on(c.user_data_back_put("i1", raw)).unwrap();
    let r = c.transport().last_request().unwrap();
    assert_eq!(r.method, swiftly_net::Method::Post);
    assert_eq!(r.body.as_deref(), Some(&br#"{"PlayCount":3}"#[..]));
}

#[test]
fn watchers_read_and_plugin_absence_is_learned() {
    let body = r#"[{"UserId":"a","UserName":"Anna","PlayCount":2,"WatchedCount":7,"TotalCount":10},
                   {"UserId":"b","ProgressPercent":40.0}]"#;
    let c = client(
        MockTransport::new().route("/JellyTwiggy/Items/i1/Watchers", 200, body),
        ServerKind::Jellyfin,
    );
    let list = block_on(c.watchers("i1")).unwrap();
    assert_eq!(list[0].name, "Anna");
    assert!((list[0].ring() - 0.7).abs() < 1e-9);
    assert_eq!(list[1].name, "");
    assert!((list[1].ring() - 0.4).abs() < 1e-9);

    // 404 once: not proof. Two different titles: absent, no more requests.
    let c = client(
        MockTransport::new().fallback(HttpResponse::new(404, "")),
        ServerKind::Jellyfin,
    );
    assert!(block_on(c.watchers("a")).is_none());
    assert!(!c.watchers_plugin_missing());
    assert!(block_on(c.watchers("b")).is_none());
    assert!(c.watchers_plugin_missing());
    let n = c.transport().requests().len();
    assert!(block_on(c.watchers("c")).is_none());
    assert_eq!(c.transport().requests().len(), n);

    // 405 is proof at once; Emby never asks.
    let c = client(
        MockTransport::new().fallback(HttpResponse::new(405, "")),
        ServerKind::Jellyfin,
    );
    assert!(block_on(c.watchers("a")).is_none());
    assert!(c.watchers_plugin_missing());
    let c = client(MockTransport::new(), ServerKind::Emby);
    assert!(block_on(c.watchers("a")).is_none());
    assert!(c.transport().requests().is_empty());
}

#[test]
fn ancestors_is_pre_travel() {
    let c = client(
        MockTransport::new().route("/Items/i1/Ancestors", 200, "[]"),
        ServerKind::Jellyfin,
    );
    assert!(block_on(c.ancestors("i1")).unwrap().is_empty());
    assert_eq!(
        last_url(&c),
        "https://tv.example.de/Items/i1/Ancestors?userId=u1"
    );
}

// ---- Quick Connect wait ------------------------------------------------------------------

#[test]
fn wait_asks_on_the_beat_and_counts_down_rounded_up() {
    let mut w = QuickConnectWait::with(0.0, 10.0, 2.0);
    assert_eq!(w.first(0.0), WaitEvent::Rest(10));
    let s = w.tick(1.0);
    assert_eq!((s.event, s.ask), (Some(WaitEvent::Rest(9)), false));
    let s = w.tick(2.0);
    assert_eq!((s.event, s.ask), (Some(WaitEvent::Rest(8)), true));
    assert_eq!(w.answer(QuickConnectState::Opened), None);
    let s = w.tick(3.0);
    assert!(!s.ask);
    // back from the background: the beat has passed, asks at the first tick
    let s = w.tick(8.5);
    assert_eq!((s.event, s.ask), (Some(WaitEvent::Rest(2)), true));
}

#[test]
fn wait_ends_on_approval_expiry_or_deadline() {
    let mut w = QuickConnectWait::with(0.0, 10.0, 2.0);
    w.tick(2.0);
    assert_eq!(
        w.answer(QuickConnectState::Released),
        Some(WaitEvent::Released)
    );
    assert!(w.is_finished());
    assert_eq!(w.tick(4.0).event, None);

    let mut w = QuickConnectWait::with(0.0, 10.0, 2.0);
    w.tick(2.0);
    assert_eq!(
        w.answer(QuickConnectState::Expired),
        Some(WaitEvent::End(QuickConnectState::Expired))
    );

    // a network error does not end it; at the deadline the sentence says "failed"
    let mut w = QuickConnectWait::with(0.0, 10.0, 2.0);
    w.tick(2.0);
    assert_eq!(w.answer(QuickConnectState::Failed), None);
    assert!(!w.is_finished());
    assert_eq!(
        w.tick(10.0).event,
        Some(WaitEvent::End(QuickConnectState::Failed))
    );
    // never asked: plain deadline = expired
    let mut w = QuickConnectWait::with(0.0, 1.0, 2.0);
    assert_eq!(
        w.tick(1.0).event,
        Some(WaitEvent::End(QuickConnectState::Expired))
    );
}

struct FakeClock(Cell<f64>);
impl WaitClock for FakeClock {
    fn now(&self) -> f64 {
        self.0.get()
    }
    async fn sleep(&self, seconds: f64) {
        self.0.set(self.0.get() + seconds);
    }
}

fn code() -> LoginCode {
    LoginCode {
        code: "123456".into(),
        confidential: "sec".into(),
    }
}

#[test]
fn driver_stops_at_approval_and_on_cancel() {
    let c = client(
        MockTransport::new().route("/QuickConnect/Connect", 200, r#"{"Authenticated":true}"#),
        ServerKind::Jellyfin,
    );
    let mut events = Vec::new();
    block_on(
        c.quick_connect_wait(&code(), &FakeClock(Cell::new(0.0)), |e| {
            events.push(e);
            true
        }),
    );
    assert_eq!(events.last(), Some(&WaitEvent::Released));
    assert_eq!(
        events[..3],
        [
            WaitEvent::Rest(300),
            WaitEvent::Rest(299),
            WaitEvent::Rest(298)
        ]
    );
    assert_eq!(c.transport().requests().len(), 1);

    // cancel: no further question
    let c = client(
        MockTransport::new().route("/QuickConnect/Connect", 200, r#"{"Authenticated":false}"#),
        ServerKind::Jellyfin,
    );
    let mut n = 0;
    block_on(
        c.quick_connect_wait(&code(), &FakeClock(Cell::new(0.0)), |_| {
            n += 1;
            n < 4
        }),
    );
    assert!(c.transport().requests().len() <= 1);
}

// QuickConnect.swift: the approving side.
#[test]
fn quick_connect_share_posts_the_code_without_user_id() {
    let c = client(
        MockTransport::new().route("/QuickConnect/Authorize", 200, "true"),
        ServerKind::Jellyfin,
    );
    block_on(c.quick_connect_share("  123456\n")).expect("approved");
    let req = c.transport().last_request().expect("req");
    assert_eq!(
        req.url.as_str(),
        "https://tv.example.de/QuickConnect/Authorize?code=123456"
    );
    assert_eq!(format!("{:?}", req.method), "Post");
}

#[test]
fn quick_connect_share_failures() {
    let run = |status: u16, body: &str| {
        let c = client(
            MockTransport::new().route("/QuickConnect/Authorize", status, body),
            ServerKind::Jellyfin,
        );
        block_on(c.quick_connect_share("1234"))
    };
    assert_eq!(run(200, "false"), Err(ErrorKind::QuickConnectExpired));
    assert!(run(200, "true").is_ok());
    assert!(matches!(run(403, ""), Err(ErrorKind::Transport(_))));
    assert_eq!(
        run(503, ""),
        Err(ErrorKind::Transport(
            swiftly_net::TransportReason::QuickConnectDisabled
        ))
    );
    assert!(matches!(
        run(500, "boom"),
        Err(ErrorKind::Http { status: 500, .. })
    ));
    // Too short: no request is made.
    let c = client(MockTransport::new(), ServerKind::Jellyfin);
    assert!(block_on(c.quick_connect_share(" 12 ")).is_err());
    assert!(c.transport().last_request().is_none());
    // No session: not authenticated.
    let c = client(MockTransport::new(), ServerKind::Jellyfin);
    c.set_session(None);
    assert_eq!(
        block_on(c.quick_connect_share("123456")),
        Err(ErrorKind::NotAuthenticated)
    );
}

#[test]
fn quick_connect_enabled_reads_true_only_on_200() {
    let run = |status: u16, body: &str| {
        let c = client(
            MockTransport::new().route("/QuickConnect/Enabled", status, body),
            ServerKind::Jellyfin,
        );
        block_on(c.quick_connect_enabled())
    };
    assert!(run(200, "true"));
    assert!(!run(200, "false"));
    assert!(!run(503, "true"));
}

/// Contract line 2: one failed poll (network gone for a moment) does not end the wait; the next
/// question goes out and an approval after it still signs in.
#[test]
fn quick_connect_wait_asks_again_after_one_failed_poll() {
    use swiftly_jellyfin::QuickConnectState;
    use swiftly_jellyfin::QuickConnectWait;
    let mut wait = QuickConnectWait::start(0.0);
    let mut now = 0.0;
    let mut asked = 0;
    let mut released = false;
    for _ in 0..40 {
        now += 1.0;
        let step = wait.tick(now);
        if step.ask {
            asked += 1;
            let state = if asked == 1 {
                QuickConnectState::Failed
            } else {
                QuickConnectState::Released
            };
            if wait.answer(state) == Some(WaitEvent::Released) {
                released = true;
            }
        }
        if wait.is_finished() {
            break;
        }
        assert!(asked <= 2, "kept asking after the approval");
    }
    assert_eq!(asked, 2, "a failed poll was not asked again");
    assert!(released && wait.is_finished());
}
