//! Differential oracle, PlaybackTick: `swiftly-rules::playback_tick` against the real Swift
//! `PlaybackTick` (Tools/Oracle, Domain_PlaybackTick.swift). Deliberate difference kept out of the
//! cases: fresh window 8 s (Swift) against 25 s (Rust), issue #43, pinned in `time_assumption`.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_rules::playback_tick::{
    Jump, Reading, Snapshot, compute, jumped, new_title, target_by, time_adopt,
};

const BASE: f64 = 1_000_000.0;

fn f(v: &Value) -> f64 {
    match v.as_str() {
        Some("nan") => f64::NAN,
        Some("inf") => f64::INFINITY,
        Some("-inf") => f64::NEG_INFINITY,
        _ => v.as_f64().unwrap_or(0.0),
    }
}
fn b(v: &Value) -> bool {
    v.as_bool().unwrap_or(false)
}
fn num(v: f64) -> Value {
    if v.is_nan() {
        json!("nan")
    } else if v.is_infinite() {
        json!(if v > 0.0 { "inf" } else { "-inf" })
    } else {
        json!(v)
    }
}
fn state(s: &Snapshot) -> Value {
    json!({
        "position": num(s.position), "duration": num(s.duration), "running": s.running,
        "first": s.first_image_present, "tracks": s.tracks_set, "start": s.start_reported,
        "since_msg": num(s.since_message), "after_change": s.after_change,
        "leap": s.leap.map_or(Value::Null, |l| json!({ "target": num(l.target), "since_t": l.since - BASE })),
    })
}

#[test]
fn playback_tick() {
    assert_equal("playback_tick", |c| {
        let st = &c["state"];
        let mut s = Snapshot {
            position: f(&st["position"]),
            duration: f(&st["duration"]),
            running: b(&st["running"]),
            first_image_present: b(&st["first"]),
            tracks_set: b(&st["tracks"]),
            start_reported: b(&st["start"]),
            since_message: f(&st["since_msg"]),
            after_change: b(&st["after_change"]),
            leap: None,
        };
        if st["leap"].is_object() {
            s.leap = Some(Jump {
                target: f(&st["leap"]["target"]),
                since: BASE + f(&st["leap"]["since_t"]),
            });
        }
        let mut results = vec![];
        for o in c["ops"].as_array().unwrap() {
            let now = BASE + f(&o["t"]);
            match o["op"].as_str().unwrap() {
                "tick" => {
                    let m = Reading {
                        duration: f(&o["duration"]),
                        position: f(&o["position"]),
                        good_point: f(&o["good_point"]),
                        shows_image: b(&o["shows"]),
                        seeks_to_start: b(&o["seeks"]),
                        running: b(&o["running"]),
                        has_audio_tracks: b(&o["audio"]),
                    };
                    let job = compute(
                        &mut s,
                        &m,
                        b(&o["restoring"]),
                        b(&o["at_push"]),
                        now - f(&o["since"]),
                        now,
                    );
                    results.push(json!({
                        "state": state(&s),
                        "job": { "screen": job.loading_screen_gone, "tracks": job.tracks_apply,
                                 "start": job.start_report, "progress": job.progress_report },
                    }));
                }
                "adopt" => {
                    time_adopt(
                        &mut s,
                        f(&o["reported"]),
                        b(&o["at_push"]),
                        now - f(&o["since"]),
                        now,
                    );
                    results.push(json!({ "state": state(&s) }));
                }
                "jumped" => {
                    jumped(&mut s, f(&o["target"]), now);
                    results.push(json!({ "state": state(&s) }));
                }
                "target_by" => {
                    results.push(json!({ "target": num(target_by(f(&o["seconds"]), &s)) }))
                }
                "new_title" => {
                    new_title(&mut s, b(&o["start_reported"]));
                    results.push(json!({ "state": state(&s) }));
                }
                _ => panic!("bad op"),
            }
        }
        Value::Array(results)
    });
}
