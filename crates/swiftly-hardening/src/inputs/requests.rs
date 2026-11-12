//! Outgoing requests of the Jellyfin / Emby client (`JellyfinClient.swift` and its extensions): every operation
//! with generated parameters (hostile ids, unicode, empty/huge lists, nil options, both server kinds, tokens,
//! device names, base addresses). Read by `Domain_Requests.swift` (Tools/Oracle) and `tests/oracle_requests.rs`.
use crate::Rng;
use serde_json::{Map, Value, json};

const IDS: [&str; 24] = [
    "abc123",
    "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
    "",
    "a b",
    "a/b",
    "a?b=c",
    "a#b",
    "a%2Fb",
    "x..y",
    ".hid",
    "ünï-ñ",
    "👨‍👩‍👧",
    "a&b=c",
    "a+b",
    "%",
    "a\nb",
    "ab\"c",
    "a;b",
    "{x}",
    "k=v",
    "\\",
    "ID UPPER",
    "a:b@c",
    "tab\there",
];
const TOKENS: [&str; 8] = [
    "tok",
    "t\"k",
    "tök 💥",
    "a b+c",
    "",
    "ab/cd?e#f",
    "x&y=z",
    "%41%42",
];
const USERS: [&str; 5] = [
    "uid",
    "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
    "u/id",
    "ü ñ",
    "u?x",
];
const DEVICES: [&str; 5] = ["dev", "ABC-123-def", "dev\"id", "ünï dev", "d e v+1"];
const DEVICE_NAMES: [&str; 9] = [
    "a\u{200B}b\u{FEFF}\u{00AD}\u{2060}c",
    "x\u{E0020}\u{202E}y\u{061C}z",
    "w\u{0085}\u{2028}v",
    "dn",
    "Pauls \"Kiste\"",
    "Zeile\nzwei",
    "ünï 👨‍👩‍👧",
    "",
    "Wohnzimmer-TV",
];
const VERSIONS: [&str; 3] = ["1.0", "1.2.3 (45)", ""];
const PROGRAMS: [&str; 3] = ["Swiftly Player", "Swiftly Player (Android)", "Pro\"gram"];
const BASES: [&str; 8] = [
    "http://example.test:8096",
    "https://h.example/jf",
    "http://h:8096/",
    "http://[::1]:8096",
    "http://192.168.1.5:8096/jellyfin/",
    "https://h.example",
    "http://h.example/a%20b",
    "http://example.test:8096/x/",
];
const TERMS: [&str; 10] = [
    "",
    "star wars",
    "ünï",
    "a&b=c",
    "a+b",
    "100%",
    "x#y",
    "é́",
    "👨‍👩‍👧",
    "a/b?c",
];
const SORTS: [&str; 8] = [
    "SortName",
    "DateCreated",
    "PremiereDate",
    "CommunityRating",
    "Random",
    "Runtime",
    "SortName,ProductionYear",
    "",
];
const FILTER_NAMES: [&str; 6] = [
    "IsResumable",
    "IsFavorite",
    "IsUnplayed",
    "IsPlayed",
    "IsNotFolder",
    "a,b",
];
const TYPES: [&str; 7] = [
    "Movie", "Series", "Episode", "BoxSet", "Playlist", "Season", "ünï",
];
const GENRES: [&str; 6] = [
    "Action",
    "Sci-Fi",
    "Drama, Comedy",
    "a|b",
    "Fantasy & Co",
    "Krimi ünï",
];

// The arguments are built before the generator is lent to `envelope`.
macro_rules! env {
    ($r:expr, $op:expr, $a:expr) => {{
        let a = $a;
        envelope($r, $op, a)
    }};
}

fn pick_str(rng: &mut Rng, list: &[&str]) -> String {
    (*rng.pick(list)).to_owned()
}

fn id(rng: &mut Rng) -> String {
    if rng.chance(3) {
        "a".repeat(3000)
    } else {
        pick_str(rng, &IDS)
    }
}

fn opt_id(rng: &mut Rng) -> Value {
    let v = id(rng);
    if rng.chance(40) {
        Value::Null
    } else {
        json!(v)
    }
}

fn opt_pick(rng: &mut Rng, pool: &[&str]) -> Value {
    let v = pick_str(rng, pool);
    if rng.chance(40) {
        Value::Null
    } else {
        json!(v)
    }
}

fn opt_bool(rng: &mut Rng) -> Value {
    let v = rng.chance(50);
    if rng.chance(40) {
        Value::Null
    } else {
        json!(v)
    }
}

fn opt_range(rng: &mut Rng, lo: i64, hi: i64) -> Value {
    let v = rng.range(lo, hi);
    if rng.chance(40) {
        Value::Null
    } else {
        json!(v)
    }
}

fn opt_num(rng: &mut Rng, pool: &[i64]) -> Value {
    let v = *rng.pick(pool);
    if rng.chance(40) {
        Value::Null
    } else {
        json!(v)
    }
}

fn list(rng: &mut Rng, pool: &[&str], max: u64) -> Value {
    let n = rng.below(max + 1);
    if rng.chance(3) {
        return Value::Array((0..300).map(|i| json!(format!("id{i}"))).collect());
    }
    Value::Array((0..n).map(|_| json!(rng.pick(pool))).collect())
}

fn int(rng: &mut Rng) -> i64 {
    *rng.pick(&[
        0, 1, 2, 10, 12, 20, 40, 100, 500, 2000, -1, 99_999, 1_000_000,
    ])
}

fn envelope(rng: &mut Rng, op: &str, a: Value) -> Value {
    let mut c = Map::new();
    c.insert("op".into(), json!(op));
    c.insert(
        "kind".into(),
        json!(if rng.chance(40) { "emby" } else { "jellyfin" }),
    );
    c.insert("base".into(), json!(rng.pick(&BASES)));
    c.insert("tok".into(), json!(rng.pick(&TOKENS)));
    c.insert("uid".into(), json!(rng.pick(&USERS)));
    c.insert("dev".into(), json!(rng.pick(&DEVICES)));
    c.insert("dname".into(), json!(rng.pick(&DEVICE_NAMES)));
    c.insert("ver".into(), json!(rng.pick(&VERSIONS)));
    c.insert("prog".into(), json!(rng.pick(&PROGRAMS)));
    if rng.chance(8) {
        c.insert("no_session".into(), json!(true));
    }
    c.insert("a".into(), a);
    Value::Object(c)
}

fn items_args(rng: &mut Rng) -> Value {
    json!({
        "parent": opt_id(rng),
        "limit": int(rng), "start": int(rng),
        "sort_by": pick_str(rng, &SORTS), "sort_order": if rng.chance(50) { "Ascending" } else { "Descending" },
        "filters": list(rng, &FILTER_NAMES, 3),
        "watched": opt_bool(rng),
        "recursive": rng.chance(50),
        "types": list(rng, &TYPES, 3),
        "ids": list(rng, &IDS, 4),
        "people": list(rng, &IDS, 3),
        "genres": list(rng, &GENRES, 3),
        "slim": rng.chance(25),
    })
}

fn plan_args(rng: &mut Rng) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("id".into(), json!(id(rng)));
    m.insert(
        "method".into(),
        json!(rng.pick(&["direct_play", "direct_stream", "transcode"])),
    );
    m.insert("source".into(), opt_id(rng));
    m.insert("play".into(), opt_id(rng));
    m.insert(
        "ticks".into(),
        json!(*rng.pick(&[0_i64, 1, 10_000_000, 36_000_000_000, 9_000_000_000_000])),
    );
    m.insert("audio".into(), opt_range(rng, -1, 9));
    m.insert("subtitle".into(), opt_range(rng, -1, 9));
    m.insert("paused".into(), json!(rng.chance(50)));
    m
}

pub fn requests_http() -> Vec<Value> {
    let mut rng = Rng::new(0x5251_4854);
    let mut out = vec![];
    let r = &mut rng;
    // (op, cases, argument builder) -- the simple "id" operations first.
    let id_ops = [
        "item",
        "ancestors",
        "collection",
        "extras",
        "trailers",
        "user_record",
        "point_back",
        "user_data_raw",
        "watchers",
        "seasons",
        "first_episode",
        "refresh",
        "next_series",
        "sections",
        "account_defaults",
        "count_id",
    ];
    for op in id_ops {
        for _ in 0..30 {
            let op_name = if op == "count_id" { "count" } else { op };
            let mut a = json!({ "id": id(r) });
            if op == "count_id" {
                a["types"] = list(r, &TYPES, 3);
            }
            out.push(env!(r, op_name, a));
        }
    }
    for _ in 0..200 {
        out.push(env!(r, "items", items_args(r)));
    }
    // The documented combinations once each, with and without a parent.
    for (filters, watched, sort) in [
        (vec!["IsResumable"], Value::Null, "DatePlayed"),
        (vec!["IsFavorite"], json!(true), "SortName"),
        (vec![], json!(false), "DateCreated"),
        (vec!["IsUnplayed", "IsFavorite"], Value::Null, "Random"),
    ] {
        for slim in [false, true] {
            for kind in ["jellyfin", "emby"] {
                let mut c = env!(
                    r,
                    "items",
                    json!({
                        "parent": "p1", "limit": 50, "start": 100, "sort_by": sort, "sort_order": "Descending", "filters": filters,
                        "watched": watched, "recursive": true, "types": ["Movie", "Series"], "ids": [], "people": ["x", "y"],
                        "genres": ["Action", "Drama, Comedy"], "slim": slim,
                    })
                );
                c["kind"] = json!(kind);
                out.push(c);
            }
        }
    }
    for _ in 0..25 {
        out.push(env!(r, "title_ids", json!({ "id": id(r), "types": list(r, &TYPES, 3), "filters": list(r, &FILTER_NAMES, 3), "watched": opt_bool(r) })));
        out.push(env!(r, "identifiers", json!({ "ids": list(r, &IDS, 5) })));
        out.push(env!(r, "remembered", json!({ "types": list(r, &TYPES, 3), "sort_by": pick_str(r, &SORTS), "sort_order": if r.chance(50) { "Ascending" } else { "Descending" } })));
        out.push(env!(
            r,
            "playlist",
            json!({ "id": id(r), "lean": r.chance(50) })
        ));
        out.push(env!(r, "similar", json!({ "id": id(r), "limit": int(r) })));
        out.push(env!(
            r,
            "search",
            json!({ "term": pick_str(r, &TERMS), "limit": int(r) })
        ));
        out.push(env!(
            r,
            "episodes",
            json!({ "id": id(r), "season": opt_id(r) })
        ));
        out.push(env!(
            r,
            "episode_post",
            json!({ "id": id(r), "series": id(r) })
        ));
        out.push(env!(r, "resume", json!({ "limit": int(r) })));
        out.push(env!(r, "next_up", json!({ "limit": int(r) })));
        out.push(env!(r, "newly", json!({ "parent": opt_id(r), "limit": int(r), "slim": r.chance(50), "types": pick_str(r, &["Movie,Episode", "Series", "Movie"]) })));
        out.push(env!(r, "views", json!({ "hidden": r.chance(50) })));
        out.push(env!(
            r,
            "watchlist",
            json!({ "id": id(r), "on": r.chance(50) })
        ));
        out.push(env!(
            r,
            "watched",
            json!({ "id": id(r), "on": r.chance(50) })
        ));
        out.push(env!(r, "user_data_put", json!({ "id": id(r), "raw": pick_str(r, &["{\"Played\":true}", "{}", "not json", "{\"x\":\"ü\"}", "[1,2]"]) })));
        out.push(env!(r, "last_play", json!({ "id": id(r), "ms": *r.pick(&[0_i64, 1, 999, 1000, 1_700_000_000_123, 1_700_000_000_000, 4_102_444_800_999, -1000]) })));
        out.push(env!(
            r,
            "foreign",
            json!({ "id": id(r), "cmd": *r.pick(&["Pause", "Unpause", "Stop"]) })
        ));
        out.push(env!(
            r,
            "hint",
            json!({ "id": id(r), "device": pick_str(r, &DEVICE_NAMES) })
        ));
        out.push(env!(
            r,
            "trickplay",
            json!({ "id": id(r), "source": opt_id(r) })
        ));
        out.push(env!(
            r,
            "chapters",
            json!({ "id": id(r), "source": opt_id(r) })
        ));
        out.push(env!(r, "stop_encoding", json!({ "play": opt_id(r) })));
        out.push(env!(r, "playback_info", json!({
            "id": id(r), "profile": if r.chance(70) { "vlc" } else { "airplay" }, "av1": r.chance(50),
            "max_bitrate": *r.pick(&[1_000_000_000_i64, 20_000_000, 0, 120_000_000]),
            "override": opt_num(r, &[8_000_000_i64, 0, 1_000_000_000]),
            "audio": opt_range(r, -1, 9), "subtitle": opt_range(r, -1, 9), "source": opt_id(r),
        })));
        out.push(env!(r, "report_start", Value::Object(plan_args(r))));
        out.push(env!(r, "report_progress", Value::Object(plan_args(r))));
        out.push(env!(r, "report_stopped", Value::Object(plan_args(r))));
    }
    // No arguments.
    for op in [
        "system_info",
        "sign_off",
        "still",
        "genres",
        "sessions",
        "capabilities",
        "qc_start",
        "qc_enabled",
        "qc_public",
    ] {
        for _ in 0..8 {
            out.push(env!(r, op, json!({})));
        }
    }
    for _ in 0..25 {
        out.push(env!(r, "authenticate", json!({ "user": pick_str(r, &["paul", "", "ünï ñ", "a\"b", "a b+c", "👨‍👩‍👧", "x\\y"]), "pw": pick_str(r, &["", "pw", "p\"w", "pässwörd 💥", "a&b=c", "\u{0}x"]) })));
        out.push(env!(
            r,
            "qc_released",
            json!({ "secret": pick_str(r, &["s3", "", "a b+c", "ü&=", "x/y?z"]), "code": "123456" })
        ));
        out.push(env!(
            r,
            "qc_share",
            json!({ "code": pick_str(r, &["123456", "", "12 34", "ünï", "a&b=c"]) })
        ));
        out.push(env!(
            r,
            "qc_signin",
            json!({ "secret": pick_str(r, &["s3", "", "a b+c", "ü&=", "x/y?z"]), "code": "1" })
        ));
    }
    // Addresses the client builds without a request.
    let perms = [Value::Null, json!("allowed"), json!("denied")];
    for _ in 0..40 {
        let mut a = json!({ "id": id(r), "source": opt_id(r), "play": opt_id(r) });
        out.push(env!(r, "u_stream", a.clone()));
        let mut c = env!(r, "u_download", a.clone());
        c["perm"] = r.pick(&perms).clone();
        out.push(c);
        a["quality"] = json!(r.pick(&["original", "hd1080", "hd720", "sd480"]));
        a["audio"] = opt_range(r, 0, 9);
        let mut c = env!(r, "u_download_q", a);
        c["perm"] = r.pick(&perms).clone();
        out.push(c);
        out.push(env!(r, "u_image", json!({ "id": id(r), "primary": opt_pick(r, &["tag", "ü", "a b", "t/g?x", "1234abcd"]), "size": int(r) })));
        out.push(env!(r, "u_backdrop", json!({ "id": id(r), "backdrop": opt_pick(r, &["tag", "ü", "a b", "t/g?x"]), "size": int(r) })));
        out.push(env!(
            r,
            "u_trickplay",
            json!({ "id": id(r), "source": opt_id(r), "width": int(r), "sheet": int(r) })
        ));
        out.push(env!(
            r,
            "u_user_image",
            json!({ "id": id(r), "mark": opt_pick(r, &["tag", "ü", "a b"]), "border": int(r) })
        ));
    }
    // A reply that is not 200 changes nothing about the request, but the Emby fallback chains do depend on the body.
    for status in [401, 404, 500] {
        out.push(
            env!(r, "next_series", json!({ "id": "s1" }))
                .as_object()
                .map(|o| {
                    let mut o = o.clone();
                    o.insert("status".into(), json!(status));
                    Value::Object(o)
                })
                .unwrap(),
        );
    }
    out
}
