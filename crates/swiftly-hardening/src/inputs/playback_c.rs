//! Oracle inputs (group C, playback): Delay, BufferLevel, TimeAssumption, FadeTimes,
//! PauseJumpBack and Prebuffer. Swift reads `Date()` in two TimeAssumption rules, so those
//! cases give `since` (seconds) and keep a safe distance from every threshold.
use crate::Rng;
use serde_json::{Value, json};

/// Ops: `ms`, `us`, `shift`, `steps`, `text`, `title`, `soft`, `hold`.
pub fn delay() -> Vec<Value> {
    let ms_values: Vec<i64> = vec![
        0,
        1,
        24,
        25,
        26,
        49,
        50,
        51,
        74,
        75,
        76,
        99,
        100,
        125,
        199,
        200,
        9_949,
        9_950,
        9_975,
        9_999,
        10_000,
        10_024,
        10_025,
        10_049,
        10_050,
        10_075,
        20_000,
        1_000_000,
        i64::from(i32::MAX),
        i64::MAX / 2,
        -1,
        -24,
        -25,
        -26,
        -49,
        -50,
        -51,
        -74,
        -75,
        -76,
        -99,
        -125,
        -199,
        -200,
        -9_949,
        -9_950,
        -9_975,
        -9_999,
        -10_000,
        -10_025,
        -10_075,
        -20_000,
        -1_000_000,
        i64::from(i32::MIN),
        -(i64::MAX / 2),
    ];
    let mut out = vec![];
    for v in &ms_values {
        out.push(json!({ "op": "ms", "v": v }));
    }
    let mut rng = Rng::new(0x444C_4159);
    for _ in 0..600 {
        out.push(json!({ "op": "ms", "v": rng.range(-15_000, 15_000) }));
    }
    for us in [
        0,
        499,
        500,
        501,
        999,
        1_000,
        1_499,
        1_500,
        1_501,
        24_999,
        25_000,
        25_001,
        74_999,
        75_000,
        -499,
        -500,
        -501,
        -1_500,
        -25_000,
        -75_000,
        9_999_999,
        10_000_000,
        -10_000_000,
        1_000_000_000_000,
        -1_000_000_000_000,
        i64::from(i32::MAX),
        i64::from(i32::MIN),
    ] {
        out.push(json!({ "op": "us", "v": us }));
    }
    for _ in 0..400 {
        out.push(json!({ "op": "us", "v": rng.range(-12_000_000, 12_000_000) }));
    }
    for ms in [0, 50, -50, 9_950, -9_950, 10_000, -10_000, 25, 200] {
        for bearing in [-7, -1, 0, 1, 3, 1000] {
            for steps in [-3, 0, 1, 2, 5, 400] {
                out.push(json!({ "op": "shift", "ms": ms, "bearing": bearing, "steps": steps }));
            }
        }
    }
    for n in [-5, 0, 1, 8, 9, 10, 11, 28, 29, 30, 31, 100, 1_000_000] {
        out.push(json!({ "op": "steps", "n": n }));
    }
    for locale in ["en", "de", "ru", "fr", "de-CH", "en-GB"] {
        for ms in [
            0, 50, -50, 5, 150, -150, 1_000, -1_000, 1_050, -1_250, 9_950, -9_950, 10_000, -10_000,
            12_345, 100,
        ] {
            out.push(json!({ "op": "text", "locale": locale, "ms": ms }));
        }
    }
    let titles = ["A", "B", "", "Pilot", "pilot"];
    let series: [Value; 4] = [json!(null), json!("S1"), json!("S2"), json!("")];
    for old_title in titles {
        for new_title in titles {
            for old_series in &series {
                for added in &series {
                    out.push(json!({
                        "op": "title", "ms": 150, "old_title": old_title, "new_title": new_title,
                        "old_series": old_series, "new_series": added
                    }));
                }
            }
        }
    }
    for ms in [0, 200, -200, 10_000] {
        for read in [
            0,
            199_999,
            200_000,
            200_999,
            201_000,
            199_000,
            201_001,
            -200_000,
            -199_001,
            1_000_000,
            10_000_000,
            -10_000_000,
            999,
            1_000,
        ] {
            out.push(json!({ "op": "soft", "ms": ms, "read": read }));
        }
    }
    for _ in 0..200 {
        out.push(json!({ "op": "soft", "ms": rng.range(-200, 200) * 50, "read": rng.range(-11_000_000, 11_000_000) }));
    }
    // Hold counter: absolute times in seconds, gaps around the 0.3 s rail.
    for _ in 0..300 {
        let mut t = 1000.0_f64;
        let mut times = vec![];
        for _ in 0..rng.range(1, 80) {
            // Gaps in 1/1024 s: exact binary numbers, so JSON round trips cannot tip the 0.3 s rail.
            let gap = match rng.below(6) {
                0 => 307,
                1 => 308,
                2 => 306,
                3 => rng.range(0, 614),
                4 => 51,
                _ => rng.range(1024, 2048),
            };
            t += gap as f64 / 1024.0;
            times.push(json!(t));
        }
        out.push(json!({ "op": "hold", "times": times }));
    }
    out
}

/// `{op: "raw"|"calc", ...}`.
pub fn buffer_level() -> Vec<Value> {
    let mut out = vec![];
    for raw in [
        "normal",
        "schlecht",
        "sehrSchlecht",
        "bad",
        "veryBad",
        "Normal",
        "",
        "NORMAL",
        "schlecht ",
        "sehr schlecht",
    ] {
        out.push(json!({ "raw": raw, "bps": 0 }));
    }
    let bps = [
        0,
        -1,
        1,
        2,
        3,
        7,
        100,
        999,
        1_000,
        64_000,
        128_000,
        500_000,
        1_000_000,
        2_500_000,
        8_000_000,
        20_000_000,
        40_000_000,
        80_000_000,
        100_000_000,
        1_000_000_000,
        1_000_000_000_000,
        i64::MAX,
        i64::MIN,
        -8_000_000,
    ];
    for raw in ["normal", "schlecht", "sehrSchlecht"] {
        for b in bps {
            out.push(json!({ "raw": raw, "bps": b }));
        }
    }
    let mut rng = Rng::new(0x4255_4646);
    for _ in 0..600 {
        let raw = *rng.pick(&["normal", "schlecht", "sehrSchlecht"]);
        let b = rng.range(-1000, 1_000_000_000);
        let b = if rng.chance(30) { b / 1000 + 1 } else { b };
        out.push(json!({ "raw": raw, "bps": b }));
    }
    out
}

/// The first six cases pin the one deliberate difference (fresh window 8 s in Swift, 25 s in Rust,
/// issue #43); everything else keeps backward jumps out of 8...25 s after opening.
pub fn time_assumption() -> Vec<Value> {
    let mut out = vec![];
    for since in [9.0, 12.0, 15.0, 20.0, 24.0, 10.0] {
        out.push(json!({ "op": "position", "reported": 100.0, "until_from": 1000.0, "since": since, "after_change": false }));
    }
    let nan_or = |v: f64, rng: &mut Rng| {
        if rng.chance(3) {
            json!("nan")
        } else {
            json!(v)
        }
    };
    let mut rng = Rng::new(0x5441_5353);
    let sinces = [
        0.0, 0.5, 3.0, 7.5, 7.9, 8.1, 11.5, 11.9, 12.1, 13.0, 24.5, 24.9, 25.1, 30.0, 100.0, 1e6,
    ];
    for _ in 0..3000 {
        let since = if rng.chance(60) {
            *rng.pick(&sinces)
        } else {
            rng.unit() * 40.0
        };
        // Stay 0.02 s away from every threshold the wall clock could tip over.
        let near = [8.0, 12.0, 25.0].iter().any(|t| (since - t).abs() < 0.02);
        let since = if near { since + 0.2 } else { since };
        let after_change = rng.chance(50);
        let reported = match rng.below(5) {
            0 => *rng.pick(&[-5.0, 0.0, 0.5, 0.5001, 0.4999, 1.0]),
            1 => since + 5.0 + (rng.unit() - 0.5) * 2.0 + 0.03,
            2 => rng.unit() * 200.0,
            3 => 1000.0 - 30.0 + (rng.unit() - 0.5) * 4.0 + 0.001,
            _ => rng.unit() * 8000.0,
        };
        let until_from = if rng.chance(40) {
            1000.0
        } else {
            rng.unit() * 8000.0
        };
        let backward = reported < until_from - 30.0;
        if backward && (8.0..25.0).contains(&since) {
            continue;
        }
        if rng.chance(75) {
            out.push(json!({
                "op": "position", "reported": nan_or(reported, &mut rng), "until_from": until_from, "since": since, "after_change": after_change
            }));
        } else {
            out.push(json!({
                "op": "present", "shows": rng.chance(50), "seeks": rng.chance(50), "since": since
            }));
        }
    }
    for v in [false, true] {
        for s in [0u64, 1, 2, u64::MAX] {
            for a in [false, true] {
                out.push(json!({ "op": "belongs", "video": v, "shown": s, "after_change": a }));
            }
        }
    }
    out
}

/// `{op, t, ...}`.
pub fn fade_times() -> Vec<Value> {
    let mut out = vec![];
    let mut rng = Rng::new(0x4641_4445);
    let mut grid: Vec<f64> = (-20..=140).map(|i| f64::from(i) / 100.0).collect();
    grid.extend([
        0.12, 0.34, 0.119_999, 0.120_001, 1e-9, -1e-9, 1e9, -1e9, 0.5,
    ]);
    for t in &grid {
        for op in ["in", "out", "inout", "pages"] {
            out.push(json!({ "op": op, "t": t }));
        }
    }
    for _ in 0..800 {
        let t = rng.unit() * 1.4 - 0.2;
        out.push(json!({ "op": "pages", "t": t * 0.4 }));
        out.push(json!({ "op": *rng.pick(&["in", "out", "inout"]), "t": t }));
    }
    let ctrl = [0.0, 0.25, 0.42, 0.58, 1.0, 0.1, 0.9, -0.2, 1.3, 2.0, -1.0];
    for _ in 0..2500 {
        out.push(json!({
            "op": "bezier", "t": rng.unit() * 1.2 - 0.1,
            "x1": rng.pick(&ctrl), "y1": rng.pick(&ctrl), "x2": rng.pick(&ctrl), "y2": rng.pick(&ctrl)
        }));
    }
    out
}

/// `{op: "jump"|"now"|"fresh"|"load", ...}`.
pub fn pause_prebuffer() -> Vec<Value> {
    let mut out = vec![];
    let mut rng = Rng::new(0x5041_5553);
    let pos = [-1.0, 0.0, 0.1, 4.9, 5.0, 5.1, 30.0, 1000.0, 1e9];
    let paused: [Value; 6] = [
        json!(null),
        json!(0.0),
        json!(100.0),
        json!(-50.0),
        json!(1e6),
        json!(999_000.0),
    ];
    for p in pos {
        for ps in &paused {
            for now in [0.0, 100.0, 699.0, 700.0, 701.0, 1_000_000.0, 1_000_000.5] {
                for g in [false, true] {
                    out.push(json!({ "op": "jump", "position": p, "paused": ps, "now": now, "group": g }));
                }
            }
        }
    }
    for p in ["nan", "inf", "-inf"] {
        out.push(
            json!({ "op": "jump", "position": p, "paused": 0.0, "now": 1000.0, "group": false }),
        );
    }
    for _ in 0..800 {
        let paused = if rng.chance(15) {
            Value::Null
        } else {
            json!(rng.unit() * 2000.0)
        };
        out.push(json!({
            "op": "jump", "position": rng.unit() * 400.0 - 20.0, "paused": paused,
            "now": rng.unit() * 3000.0, "group": rng.chance(20)
        }));
    }
    let credits: [Value; 5] = [
        json!(null),
        json!(0.0),
        json!(-5.0),
        json!(1000.0),
        json!(5000.0),
    ];
    for dur in [-1.0, 0.0, 299.0, 300.0, 300.5, 1000.0, 1500.0, 5400.0, 1e9] {
        for p in [
            -1.0, 0.0, 0.5, 100.0, 120.0, 1000.0, 1320.0, 1321.0, 5219.0, 5220.0, 5221.0, 5400.0,
            1e9,
        ] {
            for c in &credits {
                for fav in [false, true] {
                    out.push(json!({ "op": "now", "position": p, "duration": dur, "credits": c, "favorable": fav }));
                }
            }
        }
    }
    for _ in 0..800 {
        let dur = rng.unit() * 8000.0;
        let c = if rng.chance(30) {
            Value::Null
        } else {
            json!(rng.unit() * dur)
        };
        out.push(json!({ "op": "now", "position": rng.unit() * dur, "duration": dur, "credits": c, "favorable": rng.chance(80) }));
    }
    for p in ["nan", "inf"] {
        out.push(json!({ "op": "now", "position": p, "duration": 1000.0, "credits": null, "favorable": true }));
    }
    for prepared in [0.0, 1000.0, -5.0] {
        for d in [-1.0, 0.0, 1.0, 599.0, 600.0, 601.0, 1e6] {
            out.push(json!({ "op": "fresh", "prepared": prepared, "now": prepared + d }));
        }
    }
    let urls = [
        "http://host/a",
        "https://host/a",
        "HTTP://host/a",
        "HTTPS://host:8920/Videos/1/stream?static=true",
        "Http://host",
        "hTTps://host",
        "ftp://host/a",
        "file:///tmp/a.mkv",
        "file:/tmp/a.mkv",
        "/tmp/a.mkv",
        "movie.mkv",
        "//host/a",
        "http:/host",
        "http:host",
        "https:",
        "http",
        "ws://host",
        "wss://host",
        "rtsp://host/a",
        "custom+scheme://host",
        "x-http://host",
        "http+x://host",
        "http.x://host",
        "http://",
        "https://[::1]:8096/a",
        "http://user:pw@host/a",
        "http://h%C3%A9/a",
        "http://host/a b",
        "capacitor://localhost",
        "data:text/plain,a",
        "mailto:a@b.c",
        "http://\u{00E9}.de/a",
        "HTTP:///a",
        "tel:123",
        "javascript:alert(1)",
    ];
    for u in urls {
        for m in ["Direct Play", "Direct Stream", "Transcode"] {
            out.push(json!({ "op": "load", "url": u, "method": m }));
        }
    }
    out
}
