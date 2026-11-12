//! Session tests (SyncPlaySessionTests.swift, SyncPlaySameStepTests.swift) against a simulated
//! player and a recording "server": effects are applied by the test harness.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_net::{ErrorKind, MockTransport};
use swiftly_sync::session::Patience;
use swiftly_sync::syncplay::{CommandArt, Phase, QueueRecord, Reading};
use swiftly_sync::*;

/// A player that counts: position runs only while playing.
struct Probe {
    title: String,
    ready: bool,
    base: f64,
    since: f64,
    running: bool,
    steps: Vec<String>,
    advance_at: Option<f64>,
}

impl Probe {
    fn new(title: &str, spot: f64) -> Self {
        Self {
            title: title.into(),
            ready: true,
            base: spot,
            since: 0.0,
            running: false,
            steps: vec![],
            advance_at: None,
        }
    }
    fn spot(&self, now: f64) -> f64 {
        if self.running {
            self.base + now - self.since
        } else {
            self.base
        }
    }
    fn view(&self, now: f64) -> PlayerView {
        PlayerView {
            title: self.title.clone(),
            ready: self.ready,
            spot: self.spot(now),
        }
    }
    fn apply(&mut self, a: PlayerAction, now: f64) {
        match a {
            PlayerAction::Proceed => {
                self.base = self.spot(now);
                self.since = now;
                self.running = true;
                self.advance_at = Some(now);
                self.steps.push("weiter".into());
            }
            PlayerAction::Halt => {
                self.base = self.spot(now);
                self.running = false;
                self.steps.push("anhalten".into());
            }
            PlayerAction::Jump(t) => {
                self.base = t;
                self.since = now;
                self.steps.push(format!("springen {}", t.round()));
            }
        }
    }
}

/// Harness: session + player + recorded server calls and loaded titles.
struct Rig {
    s: SyncPlaySession,
    p: Probe,
    now: f64,
    calls: Vec<SyncPlayCall>,
    loaded: Vec<(String, f64)>,
    errors: Vec<SyncPlayError>,
}

impl Rig {
    fn new(spot: f64) -> Self {
        let mut s = SyncPlaySession::new();
        s.set_self_name(Some("Paul"));
        Self {
            s,
            p: Probe::new("i1", spot),
            now: 1_800_000_000.0,
            calls: vec![],
            loaded: vec![],
            errors: vec![],
        }
    }
    fn run(&mut self, effects: Vec<Effect>) {
        for e in effects {
            match e {
                Effect::Api { call, .. } => self.calls.push(call),
                Effect::Player(a) => self.p.apply(a, self.now),
                Effect::LoadTitle { title, since } => self.loaded.push((title, since)),
                Effect::Error(e) => self.errors.push(e),
                Effect::Status(_) => {}
            }
        }
    }
    fn accept(&mut self, m: SyncPlayPostDirection) {
        self.s.update_player(self.p.view(self.now));
        let e = self.s.accept(m, self.now);
        self.run(e);
    }
    /// Advances time in 50 ms steps, polling like a platform would.
    fn advance(&mut self, secs: f64) {
        let end = self.now + secs;
        while self.now < end {
            self.now += 0.05;
            if self.s.status().group.is_some() || self.s.next_deadline().is_some() {
                self.s.update_player(self.p.view(self.now));
                let e = self.s.poll(self.now);
                self.run(e);
                let e = self.s.player_tick(self.now);
                self.run(e);
            }
        }
    }
    fn plug_in(&mut self) {
        let e = self.s.plug_in(self.p.view(self.now));
        self.run(e);
    }
    fn all(&self, name: &str) -> Vec<&SyncPlayCall> {
        self.calls.iter().filter(|c| c.name() == name).collect()
    }
    fn group() -> SyncPlayGroup {
        let mut g = SyncPlayGroup::new("g1", "Filmabend");
        g.condition = Some(Phase::Empty);
        g.participant = vec!["Paul".into()];
        g
    }
    fn queue(&self, title: &str, entry: &str, since: f64) -> SyncPlayPostDirection {
        SyncPlayPostDirection::Queue(syncplay::SyncPlayQueue {
            reason: "NewPlaylist".into(),
            state: Some(self.now),
            entries: vec![QueueRecord {
                title: title.into(),
                entry_record: entry.into(),
            }],
            index: 0,
            start_point: since,
            running: false,
        })
    }
    fn loaded(spot: f64) -> Self {
        let mut r = Self::new(spot);
        r.accept(SyncPlayPostDirection::Joined(Self::group()));
        assert!(r.s.status().group.is_some());
        r.plug_in();
        let q = r.queue("i1", "p1", spot);
        r.accept(q);
        r.advance(0.5);
        assert!(!r.all("Ready").is_empty(), "ready reported");
        r
    }
    fn command(
        &self,
        art: CommandArt,
        entry: &str,
        moment: f64,
        spot: Option<f64>,
    ) -> SyncPlayPostDirection {
        SyncPlayPostDirection::Command(SyncPlayCommand {
            group: "g1".into(),
            entry_record: Some(entry.into()),
            art,
            moment,
            spot,
            emitted: None,
        })
    }
}

fn ticks_of(c: &SyncPlayCall) -> serde_json::Value {
    c.body().unwrap()
}

#[test]
fn join_and_who_came() {
    let mut r = Rig::new(0.0);
    r.accept(SyncPlayPostDirection::Joined(Rig::group()));
    r.accept(SyncPlayPostDirection::SomeoneJoined("Tom".into()));
    assert_eq!(
        r.s.status().group.as_ref().unwrap().participant,
        ["Paul", "Tom"]
    );
    assert_eq!(
        r.s.status().event.as_ref().unwrap().art,
        session::EventArt::Present("Tom".into())
    );
    assert!(r.s.status().event.as_ref().unwrap().text().contains("Tom"));
    let before = r.s.status().event.as_ref().unwrap().id;
    r.accept(SyncPlayPostDirection::SomeoneJoined("Paul".into()));
    assert_eq!(r.s.status().group.as_ref().unwrap().participant.len(), 3);
    assert_eq!(
        r.s.status().event.as_ref().unwrap().id,
        before,
        "oneself: no notice"
    );
    r.accept(SyncPlayPostDirection::SomeoneLeft("Tom".into()));
    assert_eq!(
        r.s.status().event.as_ref().unwrap().art,
        session::EventArt::Gone("Tom".into())
    );
    r.advance(0.1);
    assert!(
        !r.all("GetUtcTime").is_empty(),
        "the clock starts after joining"
    );
    r.advance(3.2);
    assert!(r.s.status().event.is_none(), "notice disappears after 3 s");
}

#[test]
fn queue_without_player_opens_it_then_reports_ready() {
    let mut r = Rig::new(42.0);
    r.accept(SyncPlayPostDirection::Joined(Rig::group()));
    let q = r.queue("i7", "p1", 42.0);
    r.accept(q);
    assert_eq!(r.loaded, [("i7".to_string(), 42.0)]);
    assert!(r.s.status().belongs_group("i7"));
    r.p.title = "i7".into();
    r.plug_in();
    r.advance(0.5);
    assert!(r.p.steps.contains(&"anhalten".to_string()));
    let ready = ticks_of(r.all("Ready")[0]);
    assert_eq!(ready["PlaylistItemId"], "p1");
    assert_eq!(ready["PositionTicks"], 420_000_000);
    assert_eq!(ready["IsPlaying"], false);
}

#[test]
fn next_at_timestamp() {
    let mut r = Rig::loaded(60.0);
    let moment = r.now + 0.6;
    let c = r.command(CommandArt::Proceed, "p1", moment, Some(60.0));
    r.accept(c);
    r.advance(1.0);
    let at = r.p.advance_at.unwrap();
    assert!(at - moment > -0.05 && at - moment < 0.3, "{}", at - moment);
    assert!(
        !r.p.steps
            .iter()
            .any(|s| s.starts_with("springen") && s != "springen 60")
    );
}

#[test]
fn missed_next_jumps_to_where_group_is() {
    let mut r = Rig::loaded(60.0);
    let c = r.command(CommandArt::Proceed, "p1", r.now - 5.0, Some(60.0));
    r.accept(c);
    r.advance(0.2);
    assert!(r.p.advance_at.is_some());
    assert!(
        r.p.steps.contains(&"springen 65".to_string()),
        "{:?}",
        r.p.steps
    );
}

#[test]
fn new_command_cancels_waiting_one() {
    let mut r = Rig::loaded(60.0);
    r.p.advance_at = None;
    let c = r.command(CommandArt::Proceed, "p1", r.now + 1.0, Some(60.0));
    r.accept(c);
    let c = r.command(CommandArt::Pause, "p1", r.now + 0.1, Some(60.0));
    r.accept(c);
    r.advance(1.4);
    assert!(r.p.advance_at.is_none());
    assert!(r.p.steps.iter().filter(|s| *s == "anhalten").count() >= 2);
}

#[test]
fn jump_plays_then_halts_and_reports_target() {
    let mut r = Rig::loaded(60.0);
    let before = r.all("Ready").len();
    let c = r.command(CommandArt::Jump, "p1", r.now, Some(120.0));
    r.accept(c);
    r.advance(1.0);
    let i = r.p.steps.iter().rposition(|s| s == "springen 120").unwrap();
    assert_eq!(
        r.p.steps[i..].iter().take(3).collect::<Vec<_>>(),
        ["springen 120", "weiter", "anhalten"]
    );
    assert!(r.all("Ready").len() > before);
    assert_eq!(
        ticks_of(r.all("Ready").last().unwrap())["PositionTicks"],
        1_200_000_000
    );
}

#[test]
fn command_for_other_entry_waits() {
    let mut r = Rig::loaded(60.0);
    r.p.advance_at = None;
    let c = r.command(CommandArt::Proceed, "p9", r.now, Some(0.0));
    r.accept(c);
    r.advance(0.3);
    assert!(r.p.advance_at.is_none());
}

#[test]
fn leave_remembers_group_and_finish_forgets() {
    let mut r = Rig::loaded(60.0);
    let e = r.s.detach(r.now);
    r.run(e);
    assert!(r.s.status().group.is_none());
    assert_eq!(r.s.status().last_leave.as_ref().unwrap().id, "g1");
    assert!(!r.s.in_player());
    assert_eq!(r.all("Leave").len(), 1);
    let e = r.s.finish(r.now);
    r.run(e);
    assert!(r.s.status().last_leave.is_none());
    // The strip disappears by itself after eight seconds as well.
    let mut r = Rig::loaded(60.0);
    let e = r.s.detach(r.now);
    r.run(e);
    r.advance(8.2);
    assert!(r.s.status().last_leave.is_none());
}

#[test]
fn denied_request_comes_as_error() {
    let mut s = SyncPlaySession::new();
    let e = s.bit_toggle(true, 10.0);
    assert!(matches!(
        &e[0],
        Effect::Api {
            call: SyncPlayCall::Pause,
            ..
        }
    ));
    let e = s.call_failed(
        &SyncPlayCall::Pause,
        ErrorKind::Http {
            status: 403,
            body: None,
        },
        10.1,
    );
    assert!(e.contains(&Effect::Error(SyncPlayError::NotReleased)));
}

#[test]
fn missing_group_cleans_up() {
    let mut r = Rig::loaded(60.0);
    r.accept(SyncPlayPostDirection::DoesNotExist);
    assert!(r.s.status().group.is_none() && r.s.status().queue_title.is_none());
    assert_eq!(r.errors, [SyncPlayError::DoesNotExist]);
}

#[test]
fn account_switch_leaves_with_old_client() {
    let mut r = Rig::loaded(60.0);
    let e = r.s.finish(r.now);
    assert!(e.iter().any(|x| matches!(
        x,
        Effect::Api {
            call: SyncPlayCall::Leave,
            previous_account: true
        }
    )));
    assert!(r.s.status().group.is_none() && r.s.status().last_leave.is_none());
}

#[test]
fn episode_selection_sets_queue() {
    let mut r = Rig::loaded(60.0);
    let e = r.s.bit_title("i2", 30.0, r.now);
    r.run(e);
    let b = ticks_of(r.all("SetNewQueue").last().unwrap());
    assert_eq!(b["StartPositionTicks"], 300_000_000);
    assert_eq!(b["PlayingQueue"], serde_json::json!(["i2"]));
}

#[test]
fn create_and_join_flow() {
    let mut r = Rig::new(0.0);
    let e = r.s.create("  ", "i1");
    r.run(e);
    assert!(matches!(r.calls[0], SyncPlayCall::Create { ref name } if name == "Filmabend"));
    assert!(r.s.status().works);
    assert!(
        r.s.create("x", "i1")
            .iter()
            .all(|e| !matches!(e, Effect::Api { .. })),
        "no second start while working"
    );
    let e = r.s.accepted(r.now);
    r.run(e);
    r.accept(SyncPlayPostDirection::Joined(Rig::group()));
    assert!(!r.s.status().works);
    // Mute channel: no GroupJoined within five seconds.
    let mut r = Rig::new(0.0);
    let e = r.s.join(&Rig::group());
    r.run(e);
    let e = r.s.accepted(r.now);
    r.run(e);
    r.advance(5.2);
    assert_eq!(r.errors, [SyncPlayError::NoResponse]);
    assert_eq!(r.all("Leave").len(), 1);
    assert!(!r.s.status().works);
}

#[test]
fn failed_create_resets_works_and_reports() {
    let mut s = SyncPlaySession::new();
    s.create("n", "i1");
    let e = s.call_failed(
        &SyncPlayCall::Create { name: "n".into() },
        ErrorKind::Http {
            status: 403,
            body: None,
        },
        1.0,
    );
    assert!(!s.status().works);
    assert!(e.contains(&Effect::Error(SyncPlayError::NotReleased)));
}

#[test]
fn teardown_with_reentry_rejoins_group() {
    let mut r = Rig::loaded(60.0);
    r.s.patience = Patience {
        conduit: 5.0,
        attempts: 3,
        answer: 1.0,
        pause: 0.05,
    };
    let ready_before = r.all("Ready").len();
    r.accept(SyncPlayPostDirection::ConnectionLost);
    r.advance(0.1);
    assert_eq!(r.s.status().group.as_ref().unwrap().id, "g1");
    assert!(r.all("Join").is_empty());
    r.accept(SyncPlayPostDirection::ConnectionAgain);
    r.advance(0.1);
    assert!(matches!(r.all("Join")[0], SyncPlayCall::Join { group, .. } if group == "g1"));
    r.accept(SyncPlayPostDirection::Joined(Rig::group()));
    r.advance(0.2);
    assert!(r.all("Ready").len() > ready_before);
    assert_eq!(ticks_of(r.all("Ready").last().unwrap())["IsPlaying"], false);
    assert_eq!(r.s.status().group.as_ref().unwrap().id, "g1");
    assert!(r.errors.is_empty());
}

#[test]
fn teardown_without_answer_reports_loss() {
    let mut r = Rig::loaded(60.0);
    r.s.patience = Patience {
        conduit: 5.0,
        attempts: 2,
        answer: 0.1,
        pause: 0.02,
    };
    r.accept(SyncPlayPostDirection::ConnectionLost);
    r.accept(SyncPlayPostDirection::ConnectionAgain);
    r.advance(1.0);
    assert!(r.s.status().group.is_none());
    assert_eq!(r.all("Join").len(), 2);
    assert_eq!(r.errors, [SyncPlayError::ConnectionLost]);
    assert!(!r.errors[0].text().is_empty());
}

#[test]
fn line_never_returns() {
    let mut r = Rig::loaded(60.0);
    r.s.patience = Patience {
        conduit: 0.1,
        attempts: 1,
        answer: 0.1,
        pause: 0.02,
    };
    r.accept(SyncPlayPostDirection::ConnectionLost);
    r.advance(0.3);
    assert!(r.s.status().group.is_none());
    assert!(r.all("Join").is_empty());
}

#[test]
fn teardown_without_group_does_nothing() {
    let mut r = Rig::new(0.0);
    r.accept(SyncPlayPostDirection::ConnectionLost);
    r.accept(SyncPlayPostDirection::ConnectionAgain);
    r.advance(0.2);
    assert!(r.all("Join").is_empty());
}

#[test]
fn old_queue_update_is_ignored() {
    let mut r = Rig::loaded(60.0);
    let mut old = r.queue("i2", "p2", 0.0);
    if let SyncPlayPostDirection::Queue(q) = &mut old {
        q.state = Some(r.now - 100.0);
    }
    r.accept(old);
    assert_eq!(r.s.status().queue_title.as_deref(), Some("i1"));
}

#[test]
fn waiting_for_all_notice_and_buffering_report() {
    let mut r = Rig::loaded(60.0);
    let mut g = Rig::group();
    g.condition = Some(Phase::Running);
    r.accept(SyncPlayPostDirection::Joined(g));
    r.accept(SyncPlayPostDirection::Condition(
        Phase::Waits,
        Some("Buffer".into()),
    ));
    assert_eq!(
        r.s.status().event.as_ref().unwrap().art,
        session::EventArt::WaitsOnAll
    );
    // The group runs; the player stands still for 3 s: "Buffering", then movement: "Ready".
    let c = r.command(CommandArt::Proceed, "p1", r.now - 0.1, Some(60.0));
    r.accept(c);
    r.p.running = false; // frozen picture
    r.advance(3.5);
    assert_eq!(r.all("Buffering").len(), 1);
    r.p.running = true;
    r.p.since = r.now;
    r.p.base += 1.0;
    let ready_before = r.all("Ready").len();
    r.advance(0.5);
    assert!(r.all("Ready").len() > ready_before);
}

/// Two devices with clocks 3 s apart execute one server command at the same real moment.
#[test]
fn two_devices_step_together() {
    let reading = |offset: f64, now: f64| Reading {
        sent: now,
        server_receive: now + offset + 0.01,
        server_sent: now + offset + 0.015,
        receive: now + 0.025,
    };
    let mut a = TimeReconcile::new();
    let mut b = TimeReconcile::new();
    let now = 1_800_000_000.0;
    a.record(reading(3.0, now));
    b.record(reading(-2.0, now));
    // The server executes at server time S; each device converts to its own clock.
    let server_when = now + 4.0 + 3.0; // device A's server time of now + 4 s
    let cmd = SyncPlayCommand {
        group: "g".into(),
        entry_record: None,
        art: CommandArt::Proceed,
        moment: server_when,
        spot: Some(10.0),
        emitted: None,
    };
    let wa = a.local_only(server_when);
    let wb = b.local_only(server_when + 2.0 - 3.0 + 0.0);
    assert!((wa - (now + 4.0)).abs() < 0.02);
    let xa = SyncPlayExecution::of(&cmd, now, &a, 10.0);
    assert!((xa.wait - 4.0).abs() < 0.02, "{}", xa.wait);
    let _ = wb;
    let cmd_b = SyncPlayCommand {
        moment: now + 4.0 + (-2.0),
        ..cmd
    };
    let xb = SyncPlayExecution::of(&cmd_b, now, &b, 10.0);
    assert!(
        (xa.wait - xb.wait).abs() < 0.03,
        "{} vs {}",
        xa.wait,
        xb.wait
    );
}

#[test]
fn syncplay_client_builds_the_requests() {
    use swiftly_sync::api::{CallResult, Clock, ServerCtx};
    struct Fixed(std::sync::Mutex<f64>);
    impl Clock for Fixed {
        fn now(&self) -> f64 {
            let mut v = self.0.lock().unwrap();
            *v += 0.05;
            *v
        }
    }
    let t = MockTransport::new()
        .route("GetUtcTime", 200, r#"{"RequestReceptionTime":"2026-09-24T10:00:00.1000000Z","ResponseTransmissionTime":"2026-09-24T10:00:00.1050000Z"}"#)
        .route("SyncPlay/List", 200, r#"[{"GroupId":"g1"}]"#)
        .route("Users/u1", 200, r#"{"Policy":{"SyncPlayAccess":"JoinGroups"}}"#)
        .route("SyncPlay/Join", 403, "no");
    let ctx = ServerCtx {
        base: "https://tv.example.de/".into(),
        user_id: "u1".into(),
        headers: vec![("Authorization".into(), "MediaBrowser Token=\"t\"".into())],
    };
    let c = SyncPlayClient::new(t, Fixed(std::sync::Mutex::new(0.0)), ctx);
    let ex = |call| futures_executor::block_on(c.execute(&call));
    assert!(matches!(
        ex(SyncPlayCall::Right),
        Ok(CallResult::Right(Some(SyncPlayRight::Join)))
    ));
    assert!(matches!(ex(SyncPlayCall::List), Ok(CallResult::Groups(g)) if g.len() == 1));
    let Ok(CallResult::Time(m)) = ex(SyncPlayCall::ServerTime) else {
        panic!("time")
    };
    assert!((m.receive - m.sent - 0.05).abs() < 1e-9);
    let r = ex(SyncPlayCall::Join {
        group: "g1".into(),
        rejoin: false,
    });
    assert_eq!(
        r,
        Err(ErrorKind::Http {
            status: 403,
            body: Some("no".into())
        })
    );
    let ping = SyncPlayCall::Ping { milliseconds: 12 }
        .to_request(&ServerCtx {
            base: "http://h".into(),
            user_id: "u".into(),
            headers: vec![],
        })
        .unwrap();
    assert_eq!(ping.url.as_str(), "http://h/SyncPlay/Ping");
    assert_eq!(ping.header("Content-Type"), Some("application/json"));
}
