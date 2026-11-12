//! `PlaybackTick.swift`: sequences of ticks, jumps, title switches and display updates on one
//! `Snapshot`. Time is explicit: `t` is the clock of the step (multiples of 1/4 s after a fixed
//! base), `since` is "seconds since the start of playback" for the wall-clock reads inside
//! `TimeAssumption`. Two worlds keep the deliberate difference out (fresh window 8 s in Swift,
//! 25 s in Rust, issue #43; pinned in `time_assumption`): the small world never has a backward
//! report, the big world never has `since` in 7.9...25.1 s.
use crate::Rng;
use serde_json::{Map, Value, json};

fn num(rng: &mut Rng, v: f64) -> Value {
    if rng.chance(2) {
        json!("nan")
    } else {
        json!(v)
    }
}

fn leap(rng: &mut Rng, hi: f64) -> Value {
    if rng.chance(40) {
        let target = *rng.pick(&[0.0, 12.5, 29.0, hi * 0.5, hi]);
        // The age against the step clock is a multiple of 1/4 s, ties at 8 s included.
        let since_t = -f64::from(rng.below(48) as u32) * 0.25;
        json!({ "target": target, "since_t": since_t })
    } else {
        Value::Null
    }
}

fn since_for(rng: &mut Rng, small: bool) -> f64 {
    let all = [
        0.1, 1.3, 3.3, 7.6, 8.4, 11.6, 12.4, 17.3, 24.6, 25.4, 40.2, 100.7, 1e6,
    ];
    let big_world = [0.1, 1.3, 3.3, 7.6, 25.4, 40.2, 100.7, 1e6];
    if small {
        *rng.pick(&all)
    } else {
        *rng.pick(&big_world)
    }
}

pub fn playback_tick() -> Vec<Value> {
    let mut rng = Rng::new(0x5054_4943);
    let mut out = vec![];
    for n in 0..4000 {
        let small = n % 2 == 0;
        // Small world: positions and reports stay below 30, so `reported < position - 30` is never true.
        let hi = if small { 29.0 } else { 3590.0 };
        let dur = *rng.pick(&[0.0, 0.0, 29.0, 50.0, 3600.0, 7200.0, -1.0]);
        let dur = if small && dur > 0.0 && dur < 29.0 {
            29.0
        } else {
            dur
        };
        let pos = *rng.pick(&[0.0, 0.25, 1.0, 12.5, hi * 0.5, hi]);
        let state = json!({
            "position": pos,
            "duration": dur,
            "running": rng.chance(50),
            "first": rng.chance(50),
            "tracks": rng.chance(50),
            "start": rng.chance(50),
            "since_msg": *rng.pick(&[0.0, 0.5, 4.0, 9.5, 10.0, 12.0, 9.75]),
            "after_change": rng.chance(30),
            "leap": leap(&mut rng, hi),
        });
        let steps = 1 + rng.below(7);
        let mut t = 0.0;
        let mut ops = vec![];
        for _ in 0..steps {
            t += *rng.pick(&[0.0, 0.25, 0.5, 0.5, 1.0, 2.5, 7.75, 8.0]);
            let mut o = Map::new();
            o.insert("t".into(), json!(t));
            let reported = |rng: &mut Rng| -> Value {
                let v = match rng.below(6) {
                    0 => *rng.pick(&[-5.0, 0.0, 0.5, 0.75, 1.0]),
                    1 => hi * rng.unit(),
                    2 => *rng.pick(&[2.0, 5.5, 6.0, 100.0 * 0.0 + hi]),
                    3 => pos + f64::from(rng.below(9) as u32) * 0.25 - 1.0,
                    4 => pos + 1.75,
                    _ => pos + 2.25,
                };
                let v = if small { v.min(hi) } else { v };
                num(rng, v)
            };
            match rng.below(10) {
                0..=4 => {
                    o.insert("op".into(), json!("tick"));
                    o.insert("since".into(), json!(since_for(&mut rng, small)));
                    o.insert("restoring".into(), json!(rng.chance(25)));
                    o.insert("at_push".into(), json!(rng.chance(15)));
                    o.insert(
                        "duration".into(),
                        json!(*rng.pick(&[0.0, 29.0, 3600.0, 3600.0, 7200.0])),
                    );
                    o.insert("position".into(), reported(&mut rng));
                    o.insert("good_point".into(), reported(&mut rng));
                    o.insert("shows".into(), json!(rng.chance(70)));
                    o.insert("seeks".into(), json!(rng.chance(20)));
                    o.insert("running".into(), json!(rng.chance(60)));
                    o.insert("audio".into(), json!(rng.chance(80)));
                }
                5 | 6 => {
                    o.insert("op".into(), json!("adopt"));
                    o.insert("since".into(), json!(since_for(&mut rng, small)));
                    o.insert("at_push".into(), json!(rng.chance(15)));
                    o.insert("reported".into(), reported(&mut rng));
                }
                7 => {
                    o.insert("op".into(), json!("jumped"));
                    let target = *rng.pick(&[-10.0, 0.0, 5.0, 29.0, hi, hi + 40.0, 4000.0, 1e9]);
                    o.insert(
                        "target".into(),
                        json!(target.min(if small { 29.0 } else { 1e9 })),
                    );
                }
                8 => {
                    o.insert("op".into(), json!("target_by"));
                    o.insert(
                        "seconds".into(),
                        json!(*rng.pick(&[-30.0, -10.0, 10.0, 30.0, 0.0])),
                    );
                }
                _ => {
                    o.insert("op".into(), json!("new_title"));
                    o.insert("start_reported".into(), json!(rng.chance(50)));
                }
            }
            ops.push(Value::Object(o));
        }
        out.push(json!({ "state": state, "ops": ops }));
    }
    out
}
