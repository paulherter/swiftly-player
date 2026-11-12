//! SyncPlay (`SyncPlay.swift`): control-channel message parsing, group helpers, clock and execution
//! rules, buffering guard, time text. Cases are read by `Domain_SyncPlay.swift` (Tools/Oracle) and
//! `tests/oracle_syncplay.rs`. Times are dyadic fractions (multiples of 1/64) so that the JSON text
//! round trip and the arithmetic are exact in both languages.
use crate::Rng;
use serde_json::{Map, Value, json};

const STAMPS: [&str; 14] = [
    "2026-09-24T10:00:01.5000000Z",
    "2026-09-24T10:00:01.2201736Z",
    "2026-09-24T10:00:01Z",
    "2026-09-24T10:00:01.250Z",
    "2026-09-24T10:00:01.5+02:00",
    "2026-09-24T10:00:01+0200",
    "2026-09-24T10:00:01",
    "2026-09-24T10:00:01.123456789Z",
    "1970-01-01T00:00:00Z",
    "2026-09-24 10:00:01Z",
    "x",
    "",
    "2026-13-45T25:61:61Z",
    "9999-12-31T23:59:59.9999999Z",
];
const IDS: [&str; 8] = [
    "g1",
    "",
    "ünï",
    "a/b",
    "0",
    "👨‍👩‍👧",
    "id with space",
    "e\u{301}",
];
const TICKS: [i64; 10] = [
    0,
    10_000_000,
    123_456_789,
    -5,
    15_000_000,
    9_000_000_000_000,
    1,
    -10_000_000,
    i64::MAX,
    i64::MIN,
];

fn pick_ticks(rng: &mut Rng) -> Value {
    match rng.below(14) {
        0..=7 => json!(*rng.pick(&TICKS)),
        8 => json!(1.5),
        9 => json!(30_000_000.0),
        10 => json!("5"),
        11 => Value::Null,
        12 => json!(1e19),
        _ => json!(true),
    }
}

fn stamp(rng: &mut Rng) -> Value {
    json!(*rng.pick(&STAMPS))
}

fn id(rng: &mut Rng) -> Value {
    json!(*rng.pick(&IDS))
}

fn command_data(rng: &mut Rng) -> Value {
    let mut o = Map::new();
    o.insert("GroupId".into(), id(rng));
    if rng.chance(70) {
        o.insert("PlaylistItemId".into(), id(rng));
    }
    o.insert("When".into(), stamp(rng));
    if rng.chance(75) {
        o.insert("PositionTicks".into(), pick_ticks(rng));
    }
    o.insert(
        "Command".into(),
        json!(*rng.pick(&[
            "Unpause", "Pause", "Stop", "Seek", "unpause", "", "Bogus", "SeekNow"
        ])),
    );
    if rng.chance(60) {
        o.insert("EmittedAt".into(), stamp(rng));
    }
    Value::Object(o)
}

fn group_data(rng: &mut Rng) -> Value {
    let mut o = Map::new();
    o.insert("GroupId".into(), id(rng));
    if rng.chance(85) {
        o.insert(
            "GroupName".into(),
            json!(*rng.pick(&["Movie night", "", "Ünï", "x\u{200B}y", "a\"b"])),
        );
    }
    if rng.chance(80) {
        o.insert(
            "State".into(),
            json!(*rng.pick(&["Idle", "Waiting", "Paused", "Playing", "idle", "", "Other"])),
        );
    }
    if rng.chance(80) {
        let n = rng.below(5);
        let names = ["ann", "ben", "Ann", "ann", "", "é", "e\u{301}"];
        o.insert(
            "Participants".into(),
            json!((0..n).map(|_| *rng.pick(&names)).collect::<Vec<_>>()),
        );
    }
    if rng.chance(70) {
        o.insert("LastUpdatedAt".into(), stamp(rng));
    }
    Value::Object(o)
}

fn queue_data(rng: &mut Rng) -> Value {
    let mut o = Map::new();
    o.insert(
        "Reason".into(),
        json!(*rng.pick(&[
            "NewPlaylist",
            "SetCurrentItem",
            "NextItem",
            "PreviousItem",
            "RemoveItems",
            "Queue",
            "Shuffle",
            "",
            "newplaylist"
        ])),
    );
    if rng.chance(80) {
        o.insert("LastUpdate".into(), stamp(rng));
    }
    if rng.chance(85) {
        let n = rng.below(4);
        let items: Vec<Value> = (0..n)
            .map(|_| {
                let mut e = Map::new();
                e.insert("ItemId".into(), id(rng));
                e.insert("PlaylistItemId".into(), id(rng));
                if rng.chance(30) {
                    e.insert("Extra".into(), json!(1));
                }
                Value::Object(e)
            })
            .collect();
        o.insert("Playlist".into(), Value::Array(items));
    }
    if rng.chance(80) {
        o.insert(
            "PlayingItemIndex".into(),
            json!(*rng.pick(&[0i64, 1, -1, 2, 99, i64::MAX, i64::MIN])),
        );
    }
    if rng.chance(70) {
        o.insert("StartPositionTicks".into(), pick_ticks(rng));
    }
    if rng.chance(70) {
        o.insert("IsPlaying".into(), json!(rng.chance(50)));
    }
    Value::Object(o)
}

fn message(rng: &mut Rng) -> Value {
    match rng.below(11) {
        0..=2 => json!({ "MessageType": "SyncPlayCommand", "Data": command_data(rng) }),
        _ => {
            let (kind, data) = match rng.below(10) {
                0 | 1 => ("GroupJoined", group_data(rng)),
                2 => ("GroupLeft", Value::Null),
                3 => (
                    *rng.pick(&[
                        "NotInGroup",
                        "GroupDoesNotExist",
                        "LibraryAccessDenied",
                        "Unknown",
                        "",
                    ]),
                    json!(""),
                ),
                4 => ("UserJoined", json!(*rng.pick(&["ann", "", "é", "x\"y"]))),
                5 => ("UserLeft", json!(*rng.pick(&["ben", "", "e\u{301}"]))),
                6 | 7 => {
                    let mut o = Map::new();
                    o.insert(
                        "State".into(),
                        json!(*rng.pick(&["Idle", "Waiting", "Paused", "Playing", "Weird"])),
                    );
                    if rng.chance(60) {
                        o.insert(
                            "Reason".into(),
                            json!(*rng.pick(&["Buffer", "Ready", "Unpause", ""])),
                        );
                    }
                    ("StateUpdate", Value::Object(o))
                }
                _ => ("PlayQueue", queue_data(rng)),
            };
            let mut inner = Map::new();
            if rng.chance(95) {
                inner.insert("GroupId".into(), id(rng));
            }
            inner.insert("Type".into(), json!(kind));
            if !data.is_null() || rng.chance(50) {
                inner.insert("Data".into(), data);
            }
            let ty = if rng.chance(97) {
                "SyncPlayGroupUpdate"
            } else {
                *rng.pick(&[
                    "Sessions",
                    "SyncPlayCommand ",
                    "syncplaygroupupdate",
                    "KeepAlive",
                ])
            };
            json!({ "MessageType": ty, "Data": Value::Object(inner) })
        }
    }
}

/// One random structural change somewhere in the tree: drop a key, or replace a value by another type.
fn mutate(rng: &mut Rng, v: &mut Value) {
    fn pointers(v: &Value, here: &str, out: &mut Vec<String>) {
        out.push(here.to_owned());
        match v {
            Value::Object(o) => o
                .iter()
                .for_each(|(k, c)| pointers(c, &format!("{here}/{k}"), out)),
            Value::Array(a) => a
                .iter()
                .enumerate()
                .for_each(|(i, c)| pointers(c, &format!("{here}/{i}"), out)),
            _ => {}
        }
    }
    let mut all = vec![];
    pointers(v, "", &mut all);
    let path = rng.pick(&all).clone();
    let Some(target) = v.pointer_mut(&path) else {
        return;
    };
    let replacement = match rng.below(9) {
        0 => Value::Null,
        1 => json!(0),
        2 => json!(-1),
        3 => json!(""),
        4 => json!("x"),
        5 => json!([]),
        6 => json!({}),
        7 => json!(true),
        _ => json!(1.5),
    };
    match (&mut *target, rng.below(3)) {
        (Value::Object(o), 0) if !o.is_empty() => {
            let keys: Vec<String> = o.keys().cloned().collect();
            let k = rng.pick(&keys).clone();
            o.remove(&k);
        }
        (t, _) => *t = replacement,
    }
}

/// `{text}`: a control-channel message; `{kind: "list", text}`: a `SyncPlay/List` body.
pub fn read() -> Vec<Value> {
    let mut rng = Rng::new(0x5359_4E43);
    let mut out: Vec<Value> = vec![];
    let fixed = [
        "",
        " ",
        "{}",
        "[]",
        "null",
        "0",
        "\"x\"",
        "garbage",
        "{\"MessageType\":\"SyncPlayCommand\"}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\"}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{}}",
        "{\"MessageType\":null,\"Data\":{}}",
        "{\"MessageType\":1}",
        "{\"MessageType\":\"KeepAlive\",\"Data\":1}",
        "\u{FEFF}{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"GroupLeft\"}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"GroupLeft\"}} trailing",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"GroupLeft\"},\"Data\":{\"Type\":\"NotInGroup\"}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"MessageType\":\"x\",\"Data\":{\"Type\":\"GroupLeft\"}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"UserJoined\",\"Type\":\"UserLeft\",\"Data\":\"a\"}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"GroupLeft\"}}\u{0}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"UserJoined\",\"Data\":\"\\ud800\"}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"UserJoined\",\"Data\":\"\\u00e9\"}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"UserJoined\",\"Data\":\"a\"}} ",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"PlayQueue\",\"Data\":{\"Reason\":\"NewPlaylist\",\"PlayingItemIndex\":1e0}}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"PlayQueue\",\"Data\":{\"Reason\":\"NewPlaylist\",\"PlayingItemIndex\":1.0}}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"PlayQueue\",\"Data\":{\"Reason\":\"NewPlaylist\",\"StartPositionTicks\":9223372036854775808}}}",
        "{\"MessageType\":\"SyncPlayGroupUpdate\",\"Data\":{\"Type\":\"PlayQueue\",\"Data\":{\"Reason\":\"NewPlaylist\",\"StartPositionTicks\":-9223372036854775808}}}",
    ];
    for t in fixed {
        out.push(json!({ "kind": "message", "text": t }));
    }
    // valid messages, then structurally damaged ones
    for _ in 0..1800 {
        let m = message(&mut rng);
        out.push(json!({ "kind": "message", "text": m.to_string() }));
    }
    for _ in 0..2200 {
        let mut m = message(&mut rng);
        for _ in 0..rng.range(1, 2) {
            mutate(&mut rng, &mut m);
        }
        out.push(json!({ "kind": "message", "text": m.to_string() }));
    }
    // group list bodies
    for t in ["[]", "", "{}", "null", "[{}]", "[1]", "[null]"] {
        out.push(json!({ "kind": "list", "text": t }));
    }
    for _ in 0..800 {
        let n = rng.below(4);
        let mut items: Vec<Value> = (0..n).map(|_| group_data(&mut rng)).collect();
        if rng.chance(35) && !items.is_empty() {
            let i = rng.below(items.len() as u64) as usize;
            mutate(&mut rng, &mut items[i]);
        }
        out.push(json!({ "kind": "list", "text": Value::Array(items).to_string() }));
    }
    out
}

/// Small pure helpers: `other`, `status`, `queue`, `raw` enums, `ticks`, `pause`, constants.
pub fn misc() -> Vec<Value> {
    let mut rng = Rng::new(0x4D49_5343);
    let names = ["ann", "ben", "Ann", "", "é", "e\u{301}", "cy", "ann "];
    let mut out = vec![json!({ "op": "consts" })];
    for _ in 0..600 {
        let n = rng.below(7);
        let participant: Vec<&str> = (0..n).map(|_| *rng.pick(&names)).collect();
        let me = if rng.chance(25) {
            Value::Null
        } else {
            json!(*rng.pick(&names))
        };
        out.push(json!({ "op": "other", "participant": participant, "me": me }));
    }
    for _ in 0..200 {
        let rights = match rng.below(6) {
            0 => Value::Null,
            1 => json!("CreateAndJoinGroups"),
            2 => json!("JoinGroups"),
            3 => json!("None"),
            4 => json!("none"),
            _ => json!("Other"),
        };
        let title = *rng.pick(&["t1", "t2", "", "é", "e\u{301}"]);
        let queue_title = if rng.chance(25) {
            Value::Null
        } else {
            json!(*rng.pick(&["t1", "t2", "", "é"]))
        };
        out.push(json!({ "op": "status", "rights": rights, "in_group": rng.chance(60), "queue_title": queue_title, "title": title }));
    }
    for _ in 0..300 {
        let reason = *rng.pick(&[
            "NewPlaylist",
            "SetCurrentItem",
            "NextItem",
            "PreviousItem",
            "RemoveItems",
            "Queue",
            "Shuffle",
            "",
            "nextitem",
        ]);
        out.push(json!({ "op": "queue", "reason": reason, "entries": rng.below(4), "index": rng.range(-2, 5) }));
    }
    for raw in [
        "Idle", "Waiting", "Paused", "Playing", "idle", "", "Other", "Playing ",
    ] {
        out.push(json!({ "op": "phase", "raw": raw }));
    }
    for raw in [
        "Unpause", "Pause", "Stop", "Seek", "unpause", "", "Play", "SeekNow",
    ] {
        out.push(json!({ "op": "art", "raw": raw }));
    }
    for _ in 0..300 {
        let t = match rng.below(4) {
            0 => *rng.pick(&TICKS),
            1 => rng.range(-100_000_000, 100_000_000),
            2 => rng.range(-4_000_000_000_000, 4_000_000_000_000),
            _ => rng.next_u64() as i64,
        };
        out.push(json!({ "op": "seconds", "ticks": t }));
    }
    for _ in 0..300 {
        let s = match rng.below(4) {
            0 => rng.range(-1000, 1000) as f64 / 64.0,
            1 => rng.range(-1_000_000, 1_000_000) as f64 / 1024.0,
            2 => *rng.pick(&[
                0.0,
                0.00000005,
                0.00000015,
                0.00000025,
                -0.00000005,
                0.5,
                1.0,
                1e-7,
                123.456_789_5,
                2.5e-7,
                8.0e11,
                -8.0e11,
            ]),
            _ => rng.range(-800_000_000_000, 800_000_000_000) as f64 / 7.0,
        };
        out.push(json!({ "op": "ticks", "seconds": s }));
    }
    for c in [-1i64, 0, 1, 2, 3, 4, 8, 9, 100] {
        out.push(json!({ "op": "pause", "count": c }));
    }
    out
}

fn dy(rng: &mut Rng, span: i64) -> f64 {
    rng.range(-span, span) as f64 / 64.0
}

fn reading(rng: &mut Rng) -> Value {
    let sent = rng.range(0, 6400) as f64 / 64.0;
    let off = dy(rng, 6400);
    let up = rng.range(0, 640) as f64 / 64.0;
    let srv = rng.range(0, 64) as f64 / 64.0;
    let down = rng.range(0, 640) as f64 / 64.0;
    let (sr, ss, re) = if rng.chance(8) {
        (dy(rng, 640), dy(rng, 640), dy(rng, 640)) // hostile: unrelated clocks, negative runtimes
    } else {
        (
            sent + off + up,
            sent + off + up + srv,
            sent + up + srv + down,
        )
    };
    json!({ "sent": sent, "server_receive": sr, "server_sent": ss, "receive": re })
}

fn command(rng: &mut Rng) -> Value {
    let art = *rng.pick(&["Unpause", "Pause", "Stop", "Seek"]);
    let spot = match rng.below(6) {
        0 => Value::Null,
        1 => json!(dy(rng, 3200)),
        2 => json!(1.0e9),
        _ => json!(rng.range(0, 190_000) as f64 / 64.0),
    };
    let entry = match rng.below(4) {
        0 => Value::Null,
        1 => json!("e2"),
        _ => json!("e1"),
    };
    json!({ "art": art, "moment": rng.range(0, 6400) as f64 / 64.0 + dy(rng, 640), "spot": spot, "entry": entry })
}

/// `{readings, ...}`: clock table and execution rules.
pub fn clock() -> Vec<Value> {
    let mut rng = Rng::new(0x434C_4F43);
    let mut out = vec![];
    for _ in 0..1500 {
        let n = rng.below(13);
        let readings: Vec<Value> = (0..n).map(|_| reading(&mut rng)).collect();
        let now = rng.range(0, 6400) as f64 / 64.0;
        let local_point = rng.range(-640, 190_000) as f64 / 64.0;
        let entry = if rng.chance(25) {
            Value::Null
        } else {
            json!(*rng.pick(&["e1", "e2"]))
        };
        out.push(json!({
            "readings": readings,
            "now": now,
            "local_point": local_point,
            "command": command(&mut rng),
            "last": if rng.chance(75) { command(&mut rng) } else { Value::Null },
            "entry": entry,
            "target": rng.range(-640, 190_000) as f64 / 64.0,
            "actual": if rng.chance(30) { dy(&mut rng, 640) } else { rng.range(-640, 190_000) as f64 / 64.0 },
            "server_time": rng.range(0, 6400) as f64 / 64.0,
            "local_time": rng.range(0, 6400) as f64 / 64.0,
        }));
    }
    // edge cases around the limits (0.4 and 1.0 s) and equal runtimes
    for d in [
        0.0, 0.25, 0.390625, 0.40625, 0.4375, 0.5, 0.984375, 1.0, 1.015625, 2.0,
    ] {
        for art in ["Unpause", "Pause"] {
            out.push(json!({
                "readings": [{ "sent": 10.0, "server_receive": 10.5, "server_sent": 10.5, "receive": 10.0 }],
                "now": 20.0, "local_point": 100.0,
                "command": { "art": art, "moment": 20.5, "spot": 100.0 + d, "entry": null },
                "last": { "art": "Unpause", "moment": 10.0, "spot": 100.0 - d + 10.5, "entry": "e1" },
                "entry": "e1", "target": 5.0, "actual": 5.0 + d, "server_time": 3.0, "local_time": 4.0
            }));
        }
    }
    out
}

/// `{ticks: [{spot, run, now}]}`: a sequence for one `BufferGuard`, with `reset` marked by `reset: true`.
pub fn buffer() -> Vec<Value> {
    let mut rng = Rng::new(0x4255_4646);
    let mut out = vec![];
    for _ in 0..1500 {
        let n = rng.range(1, 40);
        let mut spot = rng.range(0, 640) as f64 / 64.0;
        let mut now = 100.0;
        let mut ticks = vec![];
        let mode = rng.below(4);
        for _ in 0..n {
            now += match rng.below(4) {
                0 => 0.25,
                1 => 0.5,
                2 => 1.0,
                _ => rng.range(0, 640) as f64 / 128.0,
            };
            spot += match (mode, rng.below(5)) {
                (0, _) => 0.0,
                (_, 0) => 0.0,
                (_, 1) => 0.046875,
                (_, 2) => 0.0546875,
                (_, 3) => -(rng.range(0, 64) as f64) / 16.0,
                _ => rng.range(0, 64) as f64 / 64.0,
            };
            ticks.push(json!({ "spot": spot, "run": rng.chance(if mode == 3 { 50 } else { 85 }), "now": now, "reset": rng.chance(4) }));
        }
        out.push(json!({ "ticks": ticks }));
    }
    out
}

/// `{t}`: `SyncPlay.timeText` for seconds since 1970 (dyadic or whole milliseconds).
pub fn time() -> Vec<Value> {
    let mut rng = Rng::new(0x5449_4D45);
    let mut out = vec![];
    for t in [
        0.0,
        0.5,
        0.0005,
        0.0015,
        1.0,
        -1.0,
        -0.0005,
        -0.5,
        1.7e9,
        1.788_444_609_220_173_6e9,
        253_402_300_799.0,
        253_402_300_800.0,
        -62_135_596_800.0,
        -62_135_596_801.0,
        1e11,
        -1e11,
    ] {
        out.push(json!({ "t": t }));
    }
    for _ in 0..1500 {
        let t = match rng.below(5) {
            0 => rng.range(0, 4_000_000_000) as f64 + rng.range(0, 1023) as f64 / 1024.0,
            1 => rng.range(0, 4_000_000_000_000) as f64 / 1000.0,
            2 => rng.range(-4_000_000_000, 4_000_000_000) as f64 / 8.0,
            3 => {
                rng.range(-60_000_000_000, 250_000_000_000) as f64
                    + rng.range(0, 1023) as f64 / 1024.0
            }
            _ => {
                (rng.range(0, 4_000_000_000) as f64 + 0.0005 + rng.range(0, 999) as f64 / 1000.0)
                    * if rng.chance(30) { -1.0 } else { 1.0 }
            }
        };
        out.push(json!({ "t": t }));
    }
    out
}
