//! Domain `counter` (Counter.swift): chains of VLC measurements (real playback, seeks, pauses, counters
//! that jump back, garbage above the limit) and the derived rates. Times are multiples of 1/8 so the
//! JSON text round trip is exact. Read by `Domain_Description.swift` and `tests/oracle_counter.rs`.
use crate::Rng;
use serde_json::{Value, json};

fn raw_json(v: &[u64; 11]) -> Value {
    let keys = [
        "hasRead",
        "unpacked",
        "shown",
        "discarded",
        "tooLate",
        "videoBlocks",
        "audioBlocks",
        "audioPlay",
        "audioLost",
        "damaged",
        "jumps",
    ];
    let mut m = serde_json::Map::new();
    for (k, x) in keys.iter().zip(v) {
        m.insert((*k).to_owned(), json!(x));
    }
    Value::Object(m)
}

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x434F_554E);
    let mut out = Vec::new();
    let dts = [
        0.0, 0.125, 0.5, 1.0, 1.0, 2.0, 2.5, 3.875, 4.0, 4.125, 5.0, 10.0, 19.875, 20.0, 20.125,
        25.0, 60.0, -1.0, -0.125,
    ];
    for case in 0..3500 {
        let mut vals = [0_u64; 11];
        let mut spot = rng.range(0, 7200) as f64 / 8.0;
        let steps_n = rng.range(1, 14);
        let mut steps = Vec::new();
        let fps = rng.range(0, 60) as u64;
        for i in 0..steps_n {
            let dt = if i == 0 {
                0.0
            } else if rng.chance(60) {
                2.0 + rng.range(0, 8) as f64 / 8.0
            } else {
                *rng.pick(&dts)
            };
            let running = rng.chance(88);
            // Totals grow; sometimes they stand still, fall back, or are garbage.
            let grow = if dt > 0.0 { dt } else { 0.0 };
            if rng.chance(90) {
                vals[0] += (grow * rng.range(0, 3_000_000) as f64) as u64;
                vals[1] += (grow * rng.range(0, 3_000_000) as f64) as u64;
                vals[2] += (grow * fps as f64) as u64;
                vals[5] += (grow * (fps + rng.range(0, 3) as u64) as f64) as u64;
                vals[3] += rng.range(0, 3) as u64;
                vals[4] += rng.range(0, 2) as u64;
                vals[6] += (grow * 40.0) as u64;
                vals[7] += (grow * 40.0) as u64;
                vals[8] += rng.range(0, 2) as u64;
                vals[9] += rng.range(0, 2) as u64;
                vals[10] += rng.range(0, 2) as u64;
            } else {
                match rng.below(6) {
                    0 => vals[2] = vals[2].saturating_sub(rng.range(0, 200) as u64),
                    1 => vals[5] = vals[5].saturating_sub(rng.range(0, 200) as u64),
                    2 => vals[0] = vals[0].saturating_sub(rng.range(0, 90_000) as u64),
                    3 => {
                        vals[rng.below(11) as usize] = *rng.pick(&[
                            999_999_999,
                            1_000_000_000,
                            1_000_000_001,
                            5_000_000_000_000_000,
                        ])
                    }
                    4 => vals[1] = vals[0] + rng.range(0, 1000) as u64,
                    _ => vals = [0; 11],
                }
            }
            // The position follows the clock, stands still, jumps or falls back.
            spot += match rng.below(10) {
                0 => rng.range(-2000, 2000) as f64 / 8.0,
                1 => 0.0,
                2 => dt * 0.5,
                _ => dt.max(0.0) * (1.0 + rng.range(0, 2) as f64 / 8.0 - 0.125),
            };
            spot = (spot * 8.0).round() / 8.0;
            let mut step =
                json!({"dt": dt, "spot": spot, "running": running, "raw": raw_json(&vals)});
            if rng.chance(4) {
                step["reset"] = json!(true);
            }
            steps.push(step);
        }
        let bps = if case % 3 == 0 {
            json!([0.0, -5.0, 1.0, 250_000.0, 1.5e6])
        } else {
            json!([125_000.0, 0.5])
        };
        out.push(json!({"t0": 1000.0 + case as f64 / 4.0, "steps": steps, "bps": bps}));
    }
    out
}
