//! Episode / next-up domains: `episode_card` (EpisodesCard.swift), `season_choice` (SeriesState.swift),
//! `watcher_ring` (Watchers.swift), `media_versions` (MediaVersions.swift), `stop_lock` (EpisodesSwitch.swift).
//! Cases are read by `Domain_Episodes.swift` (Tools/Oracle) and `tests/oracle_episodes.rs`.
use crate::Rng;
use serde_json::{Value, json};

/// Numbers that are exact in binary, so the JSON text round trip cannot tip a comparison.
fn number(rng: &mut Rng) -> f64 {
    match rng.below(8) {
        0 => 0.0,
        1 => -(rng.range(0, 4000) as f64) / 8.0,
        2 => rng.range(0, 4000) as f64 / 8.0,
        3 => *rng.pick(&[
            70.0, 70.125, 69.875, 140.0, 140.125, -70.0, 0.125, 5.0, 4.875, 5.125, 1e12, -1e12,
        ]),
        4 => rng.range(0, 100) as f64 / 4.0,
        _ => rng.range(-1000, 1000) as f64,
    }
}

pub fn episode_card() -> Vec<Value> {
    let mut rng = Rng::new(0x4550_4341);
    let mut out = vec![json!({ "op": "constants" })];
    for omega in [9.0, 12.0, 10.0, 0.0, 1.0, 0.5, 100.0, -3.0] {
        out.push(json!({ "op": "spring", "omega": omega }));
    }
    for _ in 0..600 {
        let t = match rng.below(4) {
            0 => rng.range(-50, 50) as f64 / 16.0,
            1 => 0.0,
            2 => rng.range(0, 160) as f64 / 64.0,
            _ => rng.range(0, 40_000) as f64 / 1024.0,
        };
        let omega = *rng.pick(&[9.0, 12.0, 10.0, 0.0, 1.0, 0.5, 100.0, -3.0, 2.5]);
        out.push(json!({ "op": "travel", "t": t, "omega": omega }));
    }
    for _ in 0..300 {
        out.push(json!({ "op": "fade_off", "since": number(&mut rng) / 4.0 }));
    }
    for _ in 0..500 {
        let since = *rng.pick(&[0.0, 4.9375, 5.0, 5.0625, -1.0, 100.0, 1e12]);
        let image = if rng.chance(50) {
            Value::Null
        } else {
            json!(number(&mut rng))
        };
        out.push(json!({ "op": "yields", "since": since, "image": image }));
    }
    for _ in 0..500 {
        let safe = *rng.pick(&[0.0, 100.0, 480.0, 667.0, 800.0, 2000.0, 1e9, -50.0, 1.0]);
        out.push(
            json!({ "op": "width", "tv": rng.chance(50), "safe": safe, "large": rng.chance(50) }),
        );
    }
    for _ in 0..400 {
        out.push(json!({ "op": "dragged", "x": number(&mut rng), "y": number(&mut rng) }));
    }
    for _ in 0..600 {
        out.push(
            json!({ "op": "swiped", "x": number(&mut rng), "y": number(&mut rng),
            "mx": number(&mut rng) * 2.0, "my": number(&mut rng) * 2.0 }),
        );
    }
    for _ in 0..400 {
        let zoom = *rng.pick(&[0.0, 1.0, 0.5, 0.25, 0.75, -0.5, 1.5, 2.0, 0.125]);
        out.push(json!({ "op": "frame", "card": [number(&mut rng), number(&mut rng), number(&mut rng).abs(), number(&mut rng).abs()],
            "whole": [number(&mut rng).abs() * 4.0, number(&mut rng).abs() * 4.0], "zoom": zoom }));
    }
    out
}

fn season(rng: &mut Rng, id: &str) -> Value {
    let mut m = serde_json::Map::new();
    m.insert("Id".into(), json!(id));
    m.insert("Name".into(), json!(format!("Season {id}")));
    m.insert("Type".into(), json!("Season"));
    if rng.chance(80) {
        m.insert("IndexNumber".into(), json!(rng.range(0, 6)));
    }
    Value::Object(m)
}

pub fn season_choice() -> Vec<Value> {
    let mut rng = Rng::new(0x5345_4153);
    let ids = ["s0", "s1", "s2", "s3", "s4", "é", "e\u{301}", "", "S1"];
    let mut out = Vec::new();
    for _ in 0..3000 {
        let list: Vec<Value> = (0..rng.below(6))
            .map(|_| {
                let id = *rng.pick(&ids);
                season(&mut rng, id)
            })
            .collect();
        let hint_id = if rng.chance(40) {
            json!(rng.pick(&ids))
        } else {
            Value::Null
        };
        let hint_number = if rng.chance(40) {
            json!(rng.range(-1, 7))
        } else {
            Value::Null
        };
        let state = if rng.chance(70) {
            let mut m = serde_json::Map::new();
            m.insert("Id".into(), json!("ep"));
            m.insert("Name".into(), json!("Episode"));
            m.insert("Type".into(), json!("Episode"));
            if rng.chance(70) {
                m.insert("SeasonId".into(), json!(rng.pick(&ids)));
            }
            if rng.chance(70) {
                m.insert("ParentIndexNumber".into(), json!(rng.range(-1, 7)));
            }
            Value::Object(m)
        } else {
            Value::Null
        };
        out.push(
            json!({ "list": list, "hintId": hint_id, "hintNumber": hint_number, "state": state }),
        );
    }
    out
}

pub fn watcher_ring() -> Vec<Value> {
    let mut rng = Rng::new(0x5741_5443);
    let counts = [
        "0",
        "1",
        "5",
        "10",
        "-3",
        "3.0",
        "3.5",
        "\"4\"",
        "null",
        "1e2",
        "9223372036854775807",
        "9223372036854775808",
        "1e300",
        "true",
        "[]",
    ];
    let percents = [
        "0",
        "50",
        "99.5",
        "100",
        "100.5",
        "-20",
        "1e2",
        "\"50\"",
        "null",
        "NaN",
        "1e300",
        "-0.0",
        "33.333333333333336",
        "250",
        "[]",
    ];
    let names = ["\"Anna\"", "\"\"", "null", "5", "\"é\"", "[]"];
    let tags = ["\"t\"", "null", "7", "\"\""];
    let users = ["\"u1\"", "\"\"", "null", "5", "\"é\"", "[]", "true"];
    let mut out = Vec::new();
    for _ in 0..2500 {
        let mut parts = Vec::new();
        if rng.chance(95) {
            parts.push(format!("\"UserId\":{}", rng.pick(&users)));
        }
        let fields: [(&str, &[&str]); 6] = [
            ("UserName", &names),
            ("ImageTag", &tags),
            ("PlayCount", &counts),
            ("ProgressPercent", &percents),
            ("WatchedCount", &counts),
            ("TotalCount", &counts),
        ];
        for (key, pool) in fields {
            if rng.chance(55) {
                parts.push(format!("\"{key}\":{}", rng.pick(pool)));
            }
        }
        out.push(json!(format!("{{{}}}", parts.join(","))));
    }
    out.push(json!("[]"));
    out.push(json!("null"));
    out.push(json!("{}"));
    out.push(json!("5"));
    out.push(json!("\"x\""));
    out
}

const SOURCE_NAMES: &[&str] = &[
    "4K",
    "4k",
    " 4K ",
    "1080p",
    "Director's Cut",
    "director's cut",
    "Fassung",
    "",
    "  ",
    "\u{200B}",
    "4K\u{FEFF}",
    "ß",
    "SS",
    "ss",
    "İ",
    "i",
    "É",
    "é",
    "e\u{301}",
    "\u{a0}4K\u{a0}",
    "4K\n",
    "\t4K",
];
const SOURCE_IDS: &[&str] = &["a", "b", "c", "d", "e", ""];

fn source(rng: &mut Rng) -> Value {
    let mut m = serde_json::Map::new();
    if rng.chance(85) {
        m.insert("Id".into(), json!(rng.pick(SOURCE_IDS)));
    }
    if rng.chance(85) {
        m.insert("Name".into(), json!(rng.pick(SOURCE_NAMES)));
    }
    if rng.chance(75) {
        let streams: Vec<Value> = (0..rng.below(3))
            .map(|_| {
                let ty = *rng.pick(&["Video", "Audio", "Video", "Subtitle"]);
                let mut s = serde_json::Map::new();
                s.insert("Type".into(), json!(ty));
                s.insert("Index".into(), json!(rng.range(0, 4)));
                if rng.chance(85) {
                    s.insert(
                        "Height".into(),
                        json!(*rng.pick(&[0, -1, 480, 720, 1080, 1080, 2160])),
                    );
                }
                Value::Object(s)
            })
            .collect();
        m.insert("MediaStreams".into(), json!(streams));
    }
    Value::Object(m)
}

fn sources(rng: &mut Rng) -> Value {
    if rng.chance(10) {
        return Value::Null;
    }
    json!((0..rng.below(5)).map(|_| source(rng)).collect::<Vec<_>>())
}

pub fn media_versions() -> Vec<Value> {
    let mut rng = Rng::new(0x4D56_4552);
    let mut out = Vec::new();
    for _ in 0..4000 {
        out.push(match rng.below(3) {
            0 => json!({ "op": "choices", "sources": sources(&mut rng) }),
            1 => {
                json!({ "op": "start", "sources": sources(&mut rng), "downloaded": rng.chance(20) })
            }
            _ => {
                json!({ "op": "matching", "previous": source(&mut rng), "next": sources(&mut rng) })
            }
        });
    }
    out
}

pub fn stop_lock() -> Vec<Value> {
    let mut rng = Rng::new(0x5354_4F50);
    let items = ["i1", "i2", "é", ""];
    let sessions = ["s1", "s2", "", "e\u{301}"];
    let mut out = Vec::new();
    for _ in 0..800 {
        let ops: Vec<Value> = (0..rng.range(1, 40))
            .map(|_| {
                let session = if rng.chance(50) { Value::Null } else { json!(rng.pick(&sessions)) };
                json!({
                    "op": *rng.pick(&["started", "accept", "failed", "allowed", "accept", "allowed"]),
                    "item": rng.pick(&items),
                    "session": session,
                })
            })
            .collect();
        out.push(json!(ops));
    }
    out
}
