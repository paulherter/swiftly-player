//! Differential oracle, `Counter` (Tools/Oracle, Domain_Description.swift): chains of measurements through
//! the real Swift struct and `swiftly_rules::counter`.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_rules::counter::{Counter, RawValues};

fn raw(v: &Value) -> RawValues {
    let u = |k: &str| v[k].as_i64().unwrap_or(0).max(0) as u64;
    RawValues {
        has_read: u("hasRead"),
        unpacked: u("unpacked"),
        shown: u("shown"),
        discarded: u("discarded"),
        too_late: u("tooLate"),
        video_blocks: u("videoBlocks"),
        audio_blocks: u("audioBlocks"),
        audio_play: u("audioPlay"),
        audio_lost: u("audioLost"),
        damaged: u("damaged"),
        jumps: u("jumps"),
    }
}

#[test]
fn counter() {
    assert_equal("counter", |c| {
        let bps: Vec<f64> = c["bps"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_f64().unwrap_or(0.0))
            .collect();
        let mut time = c["t0"].as_f64().unwrap_or(0.0);
        let mut before: Option<Counter> = None;
        let mut out = Vec::new();
        for s in c["steps"].as_array().unwrap() {
            time += s["dt"].as_f64().unwrap_or(0.0);
            if s["reset"].as_bool() == Some(true) {
                before = None;
            }
            let counter = Counter::new(
                raw(&s["raw"]),
                s["spot"].as_f64().unwrap_or(0.0),
                s["running"].as_bool().unwrap_or(false),
                before.as_ref(),
                time,
            );
            let Some(counter) = counter else {
                out.push(Value::Null);
                continue;
            };
            before = Some(counter);
            out.push(json!({
                "input": counter.input, "demuxer": counter.demuxer,
                "shows": counter.shows_per_second, "decoded": counter.decoded_per_second,
                "run": counter.run_share, "pre": counter.pre_advice_bytes(),
                "reserve": bps.iter().map(|b| counter.reserve_seconds(*b)).collect::<Vec<_>>(),
            }));
        }
        Value::Array(out)
    });
}
