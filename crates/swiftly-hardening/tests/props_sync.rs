//! Random server message streams (duplicates, reorderings, late joins) against the SyncPlay
//! session. A failure prints the seed; replay with `HARDENING_SEED=<n>`.

mod common;

use swiftly_hardening::Rng;
use swiftly_sync::session::{Effect, PlayerAction, PlayerView, SyncPlaySession};
use swiftly_sync::syncplay::{
    CommandArt, Phase, QueueRecord, Reading, SyncPlayCommand, SyncPlayGroup, SyncPlayPostDirection,
    SyncPlayQueue,
};

const TITLE: &str = "title-1";
const OFFSET: f64 = 0.5;

struct Local {
    spot: f64,
    running: bool,
    jumps: Vec<f64>,
    loaded_title: bool,
}

impl Local {
    fn apply(&mut self, effects: &[Effect]) {
        for e in effects {
            match e {
                Effect::Player(PlayerAction::Proceed) => self.running = true,
                Effect::Player(PlayerAction::Halt) => self.running = false,
                Effect::Player(PlayerAction::Jump(s)) => {
                    assert!(s.is_finite(), "session asked for a non-finite seek: {s}");
                    self.spot = *s;
                    self.jumps.push(*s);
                }
                Effect::LoadTitle { .. } => self.loaded_title = true,
                _ => {}
            }
        }
    }
}

fn group() -> SyncPlayGroup {
    let mut g = SyncPlayGroup::new("g1", "Movie night");
    g.condition = Some(Phase::Running);
    g
}

fn command(rng: &mut Rng, now: f64) -> SyncPlayCommand {
    let art = *rng.pick(&[
        CommandArt::Proceed,
        CommandArt::Pause,
        CommandArt::Jump,
        CommandArt::Stop,
    ]);
    let server_now = now + OFFSET;
    let moment = match rng.below(4) {
        0 => server_now - rng.unit() * 20.0,
        1 => server_now + rng.unit() * 5.0,
        2 => server_now,
        _ => server_now - 1.0e6 * rng.unit(),
    };
    let spot = match rng.below(6) {
        0 => None,
        1 => Some(-rng.unit() * 50.0),
        2 => Some(1.0e9),
        _ => Some(rng.unit() * 3000.0),
    };
    SyncPlayCommand {
        group: "g1".into(),
        entry_record: if rng.chance(70) {
            Some("e1".into())
        } else {
            None
        },
        art,
        moment,
        spot,
        emitted: rng.chance(60).then(|| moment - rng.unit()),
    }
}

fn message(rng: &mut Rng, now: f64) -> SyncPlayPostDirection {
    match rng.below(14) {
        0..=6 => SyncPlayPostDirection::Command(command(rng, now)),
        7 => SyncPlayPostDirection::Condition(
            *rng.pick(&[Phase::Empty, Phase::Waits, Phase::Halted, Phase::Running]),
            None,
        ),
        8 => SyncPlayPostDirection::SomeoneJoined("anna".into()),
        9 => SyncPlayPostDirection::SomeoneLeft("anna".into()),
        10 => SyncPlayPostDirection::Queue(SyncPlayQueue {
            reason: "NewPlaylist".into(),
            state: Some(now + OFFSET),
            entries: vec![QueueRecord {
                title: TITLE.into(),
                entry_record: "e1".into(),
            }],
            index: *rng.pick(&[0, 0, 1, -1, 99]),
            start_point: rng.unit() * 100.0,
            running: rng.chance(50),
        }),
        11 => SyncPlayPostDirection::ConnectionLost,
        12 => SyncPlayPostDirection::ConnectionAgain,
        _ => SyncPlayPostDirection::Joined(group()),
    }
}

fn setup(now: f64) -> (SyncPlaySession, Local) {
    let mut s = SyncPlaySession::new();
    let g = group();
    let _ = s.join(&g);
    let _ = s.accepted(now);
    let _ = s.accept(SyncPlayPostDirection::Joined(g), now);
    for k in 0..4 {
        let t = now + f64::from(k) * 0.01;
        let _ = s.time_measured(
            Reading {
                sent: t,
                server_receive: t + OFFSET + 0.025,
                server_sent: t + OFFSET + 0.026,
                receive: t + 0.051,
            },
            now,
        );
    }
    let _ = s.plug_in(PlayerView {
        title: TITLE.into(),
        ready: true,
        spot: 0.0,
    });
    (
        s,
        Local {
            spot: 0.0,
            running: false,
            jumps: vec![],
            loaded_title: false,
        },
    )
}

/// Advances the local player by `dt` and lets the session tick.
fn step(s: &mut SyncPlaySession, l: &mut Local, now: &mut f64, dt: f64) {
    *now += dt;
    if l.running {
        l.spot += dt;
    }
    s.update_player(PlayerView {
        title: TITLE.into(),
        ready: true,
        spot: l.spot,
    });
    let e = s.player_tick(*now);
    l.apply(&e);
    let e = s.poll(*now);
    l.apply(&e);
}

fn case(seed: u64, converge: bool) {
    let mut rng = Rng::new(seed ^ 0x5C);
    let mut now = 1000.0;
    let (mut s, mut l) = setup(now);
    let mut last: Option<SyncPlayPostDirection> = None;
    for i in 0..120 {
        let roll = rng.below(100);
        if roll < 55 {
            let m = if roll < 10 && last.is_some() {
                last.clone().unwrap_or(SyncPlayPostDirection::Leave)
            } else {
                message(&mut rng, now)
            };
            last = Some(m.clone());
            let e = s.accept(m.clone(), now);
            l.apply(&e);
            if roll < 10 {
                // Same-step duplicate: nothing may move the player backwards.
                let jumps_before = l.jumps.len();
                let target_before = l.jumps.last().copied();
                let e = s.accept(m, now);
                l.apply(&e);
                if let (Some(t0), Some(t1)) = (target_before, l.jumps.get(jumps_before))
                    && l.jumps.len() > jumps_before
                {
                    assert!(
                        *t1 >= t0 - 1e-6,
                        "step {i}: duplicate message sought backwards {t0} -> {t1}"
                    );
                }
            }
        } else if roll < 62 {
            // The user seeks or toggles locally.
            let e = if rng.chance(50) {
                let e = s.bit_toggle(l.running, now);
                l.running = !l.running;
                e
            } else {
                let to = rng.unit() * 100.0;
                l.spot = to;
                s.bit_jump(to, now)
            };
            l.apply(&e);
        } else if roll < 66 {
            let e = s.accept(SyncPlayPostDirection::Leave, now);
            l.apply(&e);
        }
        step(&mut s, &mut l, &mut now, rng.unit() * 2.0);
        if let Some(d) = s.next_deadline() {
            assert!(d.is_finite(), "step {i}: non-finite next deadline");
        }
    }
    // Convergence: rejoin, one final unpause, then a quiet period; the player follows the group.
    if !converge || l.loaded_title {
        return; // a title switch is a different scenario
    }
    let e = s.accept(SyncPlayPostDirection::Joined(group()), now);
    l.apply(&e);
    // As the server does on every join: the queue follows `GroupJoined`. After a `Leave` in the chaos
    // phase the session has dropped its queue and loaded entry (`allBackSet`), and without a queue it
    // rightly ignores commands (`loadedFor == nil`), exactly like the Swift session.
    let e = s.accept(
        SyncPlayPostDirection::Queue(SyncPlayQueue {
            reason: "NewPlaylist".into(),
            state: Some(now + OFFSET),
            entries: vec![QueueRecord {
                title: TITLE.into(),
                entry_record: "e1".into(),
            }],
            index: 0,
            start_point: 0.0,
            running: false,
        }),
        now,
    );
    l.apply(&e);
    for _ in 0..20 {
        step(&mut s, &mut l, &mut now, 0.5);
    }
    let start = 40.0 + rng.unit() * 100.0;
    let moment = now + OFFSET;
    let e = s.accept(
        SyncPlayPostDirection::Command(SyncPlayCommand {
            group: "g1".into(),
            entry_record: Some("e1".into()),
            art: CommandArt::Proceed,
            moment,
            spot: Some(start),
            emitted: None,
        }),
        now,
    );
    l.apply(&e);
    let t0 = now;
    for _ in 0..80 {
        step(&mut s, &mut l, &mut now, 0.25);
    }
    if l.loaded_title || s.status().group.is_none() {
        return;
    }
    let should = start + (now - t0);
    assert!(l.running, "player does not run after the final unpause");
    assert!(
        (l.spot - should).abs() <= 3.0,
        "did not converge: local {} vs group {should}",
        l.spot
    );
}

#[test]
fn syncplay_random_message_streams() {
    common::for_seeds("props_sync", 300, |seed| case(seed, false));
}

/// F-prop-03 (driver gap, fixed in the driver): after a `Leave` the session forgets its queue and the
/// loaded entry, so the final rejoin must be followed by the queue message, as the real server sends it.
#[test]
fn syncplay_converges_after_final_unpause() {
    common::for_seeds("props_sync", 300, |seed| case(seed, true));
}
