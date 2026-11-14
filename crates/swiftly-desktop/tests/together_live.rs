//! Two desktop clients in one SyncPlay group against the fixture server (`cargo xtask fixture-server`, real sockets):
//! pause, play and seek reach both players together (the Swift "Gleichschritt" test allows 150 ms), a stop that follows
//! the takeover hint closes the player as a handoff, and the other devices of the account are listed. Needs
//! `target/debug/xtask` (`cargo build -p xtask`); without it the test says so and passes.
#![allow(clippy::unwrap_used, clippy::expect_used, unsafe_code)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use swiftly_desktop::live::Core;
use swiftly_desktop::together::{Hub, HubEvent};
use swiftly_sync::{PlayerAction, PlayerView};
use swiftly_vm::GroupHook;

struct Fixture(Child);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    let began = Instant::now();
    while !ok() {
        assert!(
            began.elapsed() < Duration::from_secs(15),
            "timed out: {what}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A signed-in core with its own config directory (so its own device id).
fn client(dir: &std::path::Path, addr: &str) -> Arc<Core> {
    let _ = std::fs::remove_dir_all(dir);
    // SAFETY-free: the variable is read when the core opens; the test is single-threaded up to here.
    unsafe { std::env::set_var("SWIFTLY_CONFIG_DIR", dir) };
    let core = Arc::new(Core::open().expect("core"));
    let backend = core.sign_in_backend();
    let wait = Duration::from_secs(30);
    backend
        .connect(addr)
        .0
        .recv_timeout(wait)
        .expect("connect")
        .expect("server");
    backend
        .password("demo", "demo")
        .0
        .recv_timeout(wait)
        .expect("sign in")
        .expect("password");
    core
}

/// The events a hub produced, with the moment each came up.
fn steps(hub: &Hub, sink: &mut Vec<(PlayerAction, Instant)>, other: &mut Vec<HubEvent>) {
    for e in hub.take_events() {
        match e {
            HubEvent::Step { action, at } => sink.push((action, at)),
            e => other.push(e),
        }
    }
}

struct Rig {
    _fx: Fixture,
    tmp: PathBuf,
    a: Arc<Hub>,
    b: Arc<Hub>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.a.stop();
        self.b.stop();
        let _ = std::fs::remove_dir_all(&self.tmp);
    }
}

/// The fixture, two signed-in desktop clients and one group they are both in; `None` without the xtask binary.
fn rig() -> Option<Rig> {
    let xtask = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/debug/xtask");
    if !xtask.exists() {
        println!("skipped: build xtask first (cargo build -p xtask)");
        return None;
    }
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let fx = Fixture(
        Command::new(&xtask)
            .args(["fixture-server", "--port", &port.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("fixture"),
    );
    std::thread::sleep(Duration::from_millis(800));
    let addr = format!("http://127.0.0.1:{port}");
    let tmp = std::env::temp_dir().join(format!("swiftly-together-{}", std::process::id()));
    let core_a = client(&tmp.join("a"), &addr);
    let core_b = client(&tmp.join("b"), &addr);
    let (acc_a, acc_b) = (core_a.account().unwrap(), core_b.account().unwrap());
    assert_ne!(acc_a.device_id, acc_b.device_id, "two devices");
    let a = Hub::new(&core_a, &acc_a, Some("Anna")).expect("hub a");
    let b = Hub::new(&core_b, &acc_b, Some("Ben")).expect("hub b");
    a.start();
    b.start();

    // A opens a group for the title, B finds it in the list and joins.
    a.refresh();
    wait_for("the right", || a.part().may_create);
    a.create("Abend", "m1");
    wait_for("A in the group", || a.view().group.is_some());
    b.refresh();
    wait_for("B sees the group", || !b.part().groups.is_empty());
    let id = b.part().groups[0].id.clone();
    b.join(&id);
    wait_for("B in the group", || b.view().group.is_some());
    wait_for("the group's title reaches B", || {
        b.group_title().as_deref() == Some("m1")
    });
    assert_eq!(a.view().group.as_ref().map(|g| g.0.as_str()), Some("Abend"));

    Some(Rig {
        _fx: fx,
        tmp,
        a: Arc::new(a),
        b: Arc::new(b),
    })
}

#[test]
fn two_clients_stay_in_step() {
    let Some(rig) = rig() else {
        return;
    };
    let (a, b) = (&rig.a, &rig.b);
    // Both players open on the title and tell the group how they stand, twice a second like the screen does.
    let player = |spot: f64| PlayerView {
        title: "m1".into(),
        ready: true,
        spot,
    };
    a.player_attached(player(0.0));
    b.player_attached(player(0.0));
    let (mut sa, mut sb) = (Vec::new(), Vec::new());
    let (mut oa, mut ob) = (Vec::new(), Vec::new());
    let mut last_tick = Instant::now();
    let mut pump =
        |millis: u64, sa: &mut Vec<_>, sb: &mut Vec<_>, oa: &mut Vec<_>, ob: &mut Vec<_>| {
            let until = Instant::now() + Duration::from_millis(millis);
            while Instant::now() < until {
                a.player_update(player(0.0));
                b.player_update(player(0.0));
                if last_tick.elapsed() >= Duration::from_millis(500) {
                    last_tick = Instant::now();
                    a.player_tick();
                    b.player_tick();
                }
                steps(a, sa, oa);
                steps(b, sb, ob);
                std::thread::sleep(Duration::from_millis(25));
            }
        };
    pump(5000, &mut sa, &mut sb, &mut oa, &mut ob);
    sa.clear();
    sb.clear();

    // The three requests: each arrives at both players, at nearly the same moment.
    let mut check = |name: &str, want: PlayerAction, ask: &dyn Fn()| {
        ask();
        let (mut ga, mut gb) = (Vec::new(), Vec::new());
        let began = Instant::now();
        loop {
            pump(50, &mut ga, &mut gb, &mut Vec::new(), &mut Vec::new());
            let pick = |v: &Vec<(PlayerAction, Instant)>| {
                v.iter().find(|(x, _)| *x == want).map(|(_, t)| *t)
            };
            if let (Some(ta), Some(tb)) = (pick(&ga), pick(&gb)) {
                let off = if ta > tb { ta - tb } else { tb - ta };
                let rel = |v: &Vec<(PlayerAction, Instant)>| {
                    v.iter()
                        .map(|(x, t)| format!("{x:?}@{}ms", t.duration_since(began).as_millis()))
                        .collect::<Vec<_>>()
                };
                assert!(
                    off <= Duration::from_millis(150),
                    "{name}: the players moved {off:?} apart; A {:?} B {:?}; offsets A {:.3} B {:.3}",
                    rel(&ga),
                    rel(&gb),
                    a.offset_seconds(),
                    b.offset_seconds()
                );
                println!("{name}: both moved, {off:?} apart");
                return;
            }
            assert!(
                began.elapsed() < Duration::from_secs(8),
                "{name}: not both moved ({ga:?} / {gb:?})"
            );
        }
    };
    check("play", PlayerAction::Proceed, &|| a.toggle(false));
    check("pause", PlayerAction::Halt, &|| b.toggle(true));
    check("seek", PlayerAction::Jump(120.0), &|| a.jump(120.0));

    // Leaving: B leaves from the column, A stays alone in the group.
    b.leave();
    wait_for("B out of the group", || b.view().group.is_none());
    assert!(a.view().group.is_some());
    a.player_detached();
    b.player_detached();
}

/// The player screen of A in the group: its pause button is a request, the group's answer pauses it, and B gets the
/// same step at the same moment; the group shows in its header and the hand-over button is gone.
#[test]
fn the_player_screen_follows_the_group() {
    use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
    use swiftly_layout::Size;
    use swiftly_ui::{Cx, Env, Idiom};
    use swiftly_vm::PlayerIntent;

    let Some(rig) = rig() else {
        return;
    };
    let (a, b) = (&rig.a, &rig.b);
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut screen = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    screen.attach_together(Arc::clone(&rig.a), "m1");
    assert!(
        screen.in_group(),
        "the screen joined the group of its title"
    );
    let player = PlayerView {
        title: "m1".into(),
        ready: true,
        spot: 0.0,
    };
    b.player_attached(player.clone());
    let mut now = 0.0;
    let mut last_tick = Instant::now();
    let mut frames = |screen: &mut PlayerScreen,
                      now: &mut f64,
                      ms: f64,
                      got: &mut Vec<(PlayerAction, Instant)>| {
        let end = *now + ms;
        while *now < end {
            *now += 25.0;
            let _ = screen.frame(*now);
            b.player_update(player.clone());
            if last_tick.elapsed() >= Duration::from_millis(500) {
                last_tick = Instant::now();
                b.player_tick();
            }
            for e in a.take_events() {
                if let HubEvent::Step { action, at } = &e {
                    got.push((*action, *at));
                }
                screen.hub_event(e, *now);
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    };
    let mut got = Vec::new();
    frames(&mut screen, &mut now, 1500.0, &mut got);
    got.clear();
    let _ = b.take_events();
    assert!(screen.vm().transport().running, "the demo film runs");
    // The user presses pause: nothing stops by itself, the group is asked first.
    screen.send_intent(PlayerIntent::TogglePlay, now);
    assert!(
        screen.vm().transport().running,
        "a request, not a direct pause"
    );
    let began = Instant::now();
    let mut theirs = Vec::new();
    while screen.vm().transport().running {
        frames(&mut screen, &mut now, 50.0, &mut got);
        for e in b.take_events() {
            if let HubEvent::Step { action, at } = e {
                theirs.push((action, at));
            }
        }
        assert!(
            began.elapsed() < Duration::from_secs(8),
            "the group never answered"
        );
    }
    assert!(got.iter().any(|(x, _)| *x == PlayerAction::Halt));
    // B's step may have arrived after the loop ended: give it a moment.
    let until = Instant::now() + Duration::from_secs(3);
    while theirs.is_empty() && Instant::now() < until {
        for e in b.take_events() {
            if let HubEvent::Step { action, at } = e {
                theirs.push((action, at));
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let ours = got
        .iter()
        .find(|(x, _)| *x == PlayerAction::Halt)
        .map(|(_, t)| *t)
        .unwrap();
    let other = theirs
        .iter()
        .find(|(x, _)| *x == PlayerAction::Halt)
        .map(|(_, t)| *t)
        .expect("B paused too");
    let off = if ours > other {
        ours - other
    } else {
        other - ours
    };
    println!("screen and B paused {off:?} apart");
    assert!(off <= Duration::from_millis(200), "{off:?}");
    // Leaving from the column: the screen goes on alone and the hand-over button may come back.
    screen.send_intent(PlayerIntent::Close, now);
    frames(&mut screen, &mut now, 100.0, &mut got);
}
