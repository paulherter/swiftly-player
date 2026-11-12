//! `DownloadAudio.swift` (choice logic) and `Downloads.swift` (rules, item methods, path parts).
//! Items are written in the persisted Swift format (`konto`, `titel`, `stand`, dates as seconds
//! since the Apple reference date) so both sides decode them with their real decoder. Integers stay
//! far below 2^53 and sums far below i64::MAX (Swift traps on overflow, Rust wraps or saturates).
use crate::Rng;
use serde_json::{Map, Value, json};

const LANGS: &[&str] = &[
    "ger",
    "deu",
    "de",
    "German",
    "Deutsch",
    "eng",
    "en",
    "English",
    "ENG",
    "fre",
    "fra",
    "jpn",
    "ja",
    "Japanese",
    "rus",
    "und",
    "zxx",
    "",
    "  ",
    "DE",
    "Eng",
    "pt-BR",
    "zh",
    "chi",
    "spa",
    "ita",
    "xx",
    "Deutsch (Germany)",
    "\u{00A0}ger",
    "Ger\u{0301}",
    "é",
    "日本語",
    "ukr",
];
const CODECS: &[&str] = &[
    "ac3", "eac3", "dts", "aac", "truehd", "flac", "opus", "AC3", "E-AC-3", "", "mp3",
];
const PREFS: &[&str] = &[
    "", "", "de", "en", "ger", "eng", "fr", "ja", "German", "Deutsch", "xx", "ru",
];

fn audio_stream(rng: &mut Rng, index: i64) -> Value {
    let mut m = Map::new();
    let ty = match rng.below(10) {
        0 => "Video",
        1 => "Subtitle",
        _ => "Audio",
    };
    m.insert("Type".into(), json!(ty));
    if rng.chance(93) {
        m.insert("Index".into(), json!(index));
    }
    if rng.chance(80) {
        m.insert("Language".into(), json!(*rng.pick(LANGS)));
    }
    if rng.chance(80) {
        m.insert("Codec".into(), json!(*rng.pick(CODECS)));
    }
    if rng.chance(70) {
        m.insert("Channels".into(), json!(*rng.pick(&[1, 2, 6, 8, 0, 3])));
    }
    if rng.chance(50) {
        m.insert("IsDefault".into(), json!(rng.chance(40)));
    }
    if rng.chance(30) {
        m.insert(
            "DisplayTitle".into(),
            json!(*rng.pick(&["Stereo", "", "German - AC3", "Track"])),
        );
    }
    Value::Object(m)
}

fn streams(rng: &mut Rng) -> Vec<Value> {
    let n = rng.below(6) as i64;
    let mut base = rng.below(3) as i64;
    (0..n)
        .map(|_| {
            // Mostly consecutive indices, sometimes a repeat (hostile server).
            base += if rng.chance(8) { 0 } else { 1 };
            audio_stream(rng, base)
        })
        .collect()
}

/// `DownloadAudio`: options, offered, preselected, index, language key.
pub fn download_audio() -> Vec<Value> {
    let mut rng = Rng::new(0x4441_5544);
    let mut out = vec![];
    for _ in 0..4000 {
        let st = streams(&mut rng);
        let sel: Vec<Value> = (0..rng.below(4))
            .map(|_| json!(streams(&mut rng)))
            .collect();
        let choice = match rng.below(4) {
            0 => json!({ "k": "all" }),
            1 => json!({ "k": "track", "i": rng.below(7) as i64 }),
            _ => {
                json!({ "k": "language", "key": *rng.pick(&["de", "en", "fr", "ja", "ru", "xx", "", "ger", "DE"]) })
            }
        };
        out.push(json!({
            "streams": st, "selection": sel, "choice": choice,
            "mode": if rng.chance(50) { "track" } else { "language" },
            "pref": *rng.pick(PREFS), "index": rng.below(7) as i64,
        }));
    }
    out
}

const IDS: &[&str] = &["a", "b", "c", "d", "e", "f1", "f2", "", "ünï", "a/b", "x y"];
const ACCOUNTS: &[&str] = &["u1", "u1", "u1", "u2", ""];
const SERIES: &[&str] = &["s1", "s2", "s3", "é"];
const BYTES: &[i64] = &[
    0,
    1,
    1000,
    999_999,
    1_000_000,
    1_073_741_824,
    5_000_000_000,
    40_000_000_000,
    -5,
];
const TICKS: &[i64] = &[
    0,
    1,
    10_000_000,
    4_000_000_000,
    36_000_000_000,
    60_000_000_000,
    -10_000_000,
];
const STATES: &[&str] = &[
    "wartet",
    "laedt",
    "angehalten",
    "fertig",
    "fertig",
    "fertig",
    "fehler",
];
const QUALITIES: &[&str] = &["original", "hd1080", "hd720", "sd480"];
const CONTAINERS: &[&str] = &["mkv", "mp4", "avi", "", "m4v", "weird/..", "MKV"];

fn item(rng: &mut Rng, force_episode: bool) -> Value {
    let mut m = Map::new();
    m.insert("id".into(), json!(*rng.pick(IDS)));
    m.insert("konto".into(), json!(*rng.pick(ACCOUNTS)));
    let episode = force_episode || rng.chance(70);
    m.insert("art".into(), json!(if episode { "folge" } else { "film" }));
    m.insert(
        "titel".into(),
        json!(*rng.pick(&["T", "Pilot", "Zwei", "é"])),
    );
    if episode || rng.chance(10) {
        if rng.chance(90) {
            m.insert(
                "serie".into(),
                json!(*rng.pick(&["Serie A", "Serie B", ""])),
            );
        }
        if rng.chance(92) {
            m.insert("serienId".into(), json!(*rng.pick(SERIES)));
        }
        if rng.chance(80) {
            m.insert("staffel".into(), json!(rng.below(4) as i64));
        }
        if rng.chance(92) {
            m.insert("folge".into(), json!(rng.below(5) as i64));
        }
    }
    if rng.chance(70) {
        m.insert("laufzeitTicks".into(), json!(*rng.pick(TICKS)));
    }
    if rng.chance(60) {
        m.insert("container".into(), json!(*rng.pick(CONTAINERS)));
    }
    m.insert("bytes".into(), json!(*rng.pick(BYTES)));
    if rng.chance(30) {
        m.insert("qualitaet".into(), json!(*rng.pick(QUALITIES)));
    }
    m.insert(
        "geladen".into(),
        json!(*rng.pick(&[0, 1, 500, 1000, 1_000_000, 5_000_000_000_i64, -3])),
    );
    m.insert("stand".into(), json!(*rng.pick(STATES)));
    m.insert("gesehen".into(), json!(rng.chance(40)));
    m.insert(
        "angelegt".into(),
        json!(f64::from(rng.below(6) as u32) * 0.5 + 700_000_000.0),
    );
    m.insert("nochAufDemServer".into(), json!(rng.chance(90)));
    if rng.chance(40) {
        m.insert("stelleTicks".into(), json!(*rng.pick(TICKS)));
    }
    if rng.chance(40) {
        m.insert(
            "zuletzt".into(),
            json!(f64::from(rng.below(8) as u32) * 0.5 + 700_000_000.0),
        );
    }
    if rng.chance(30) {
        m.insert("tonIndex".into(), json!(rng.below(4) as i64));
    }
    if rng.chance(30) {
        m.insert("ersetzt".into(), json!(*rng.pick(IDS)));
    }
    if rng.chance(20) {
        m.insert("bildcodec".into(), json!("hevc"));
    }
    Value::Object(m)
}

fn items(rng: &mut Rng, max: u64) -> Vec<Value> {
    (0..rng.below(max)).map(|_| item(rng, false)).collect()
}

fn opt_bool(rng: &mut Rng) -> Value {
    match rng.below(3) {
        0 => Value::Null,
        1 => json!(true),
        _ => json!(false),
    }
}

fn watch(rng: &mut Rng) -> Value {
    if rng.chance(20) {
        return Value::Null;
    }
    let mut m = Map::new();
    if rng.chance(60) {
        m.insert("PlaybackPositionTicks".into(), json!(*rng.pick(TICKS)));
    }
    if rng.chance(60) {
        m.insert("Played".into(), opt_bool(rng));
    }
    if rng.chance(60) {
        let s = *rng.pick(&[
            "2023-03-12T10:00:00.0000000Z",
            "2023-03-12T10:00:01.5Z",
            "2023-03-12T10:00:02Z",
            "2023-03-12T10:00:00Z",
            "garbage",
            "",
            "1970-01-01T00:00:00Z",
        ]);
        m.insert("LastPlayedDate".into(), json!(s));
    }
    Value::Object(m)
}

/// `MediaServerFactory` (headless part): which kind gives which client capabilities. Headers and
/// endpoints need a transport and have no oracle.
pub fn server_factory() -> Vec<Value> {
    let mut out = vec![];
    for kind in ["jellyfin", "emby", "plex"] {
        for url in [
            "https://a.example",
            "http://192.168.1.2:8096",
            "https://a.example/jellyfin/",
            "http://[::1]:8096",
        ] {
            out.push(json!({ "kind": kind, "url": url }));
        }
    }
    out
}

/// `{op, ...}` over `DownloadRules`, `DownloadItem` methods and `PathPart`.
pub fn download_rules() -> Vec<Value> {
    let mut rng = Rng::new(0x4452_554c);
    let mut out = vec![];
    for n in 0..9000 {
        let r = &mut rng;
        let case = match n % 18 {
            0 => {
                json!({ "op": "next_one", "items": items(r, 6), "wlan": r.chance(50), "only": r.chance(50) })
            }
            1 => json!({ "op": "network", "wlan": opt_bool(r), "only": r.chance(50) }),
            2 => {
                json!({ "op": "slot", "items": items(r, 6), "bytes": *r.pick(BYTES), "free": *r.pick(&[0, 100, 1_073_741_824, 1_073_741_825, 2_000_000_000, 100_000_000_000_i64, -1]) })
            }
            3 => {
                json!({ "op": "foot", "bytes": *r.pick(BYTES), "free": *r.pick(&[0, 100, 1_073_741_824, 1_073_741_825, 2_000_000_000, 100_000_000_000_i64, -1]) })
            }
            4 => json!({ "op": "dispensable", "items": items(r, 7) }),
            5 | 6 => json!({ "op": "grouped", "items": items(r, 8) }),
            7 => {
                json!({ "op": "progress_show", "loaded": *r.pick(&[0, 5, 100, 999, 1000, 2000, 50_000_000]), "total": *r.pick(&[0, 100, 1000, 10_000, 1_000_000_000_i64, -5]),
                         "before": if r.chance(25) { Value::Null } else { json!(*r.pick(&[0, 5, 100, 999, 1000, 2000, 50_000_000])) },
                         "elapsed": if r.chance(25) { Value::Null } else { json!(*r.pick(&[0.0, 0.5, 1.0, 1.5, 20.0])) } })
            }
            8 => {
                json!({ "op": "progress", "loaded": *r.pick(&[-5, 0, 5, 999, 1000, 123_456, 5_000_000, 999_999_999, 1_500_000_000, 50_000_000_000_i64]),
                         "total": *r.pick(&[-5, 0, 5, 999, 1000, 999_999, 1_000_000, 123_456_789, 1_000_000_000, 1_500_000_000, 50_000_000_000_i64]),
                         "locale": *r.pick(&["en_US", "de_DE"]) })
            }
            9 => json!({ "op": "next_episode", "items": items(r, 7) }),
            10 => {
                let list: Vec<Value> = (0..r.below(8)).map(|_| item(r, true)).collect();
                let pick = list.first().map_or(json!("a"), |v| v["id"].clone());
                json!({ "op": "episode_post", "items": list, "id": if r.chance(80) { pick } else { json!(*r.pick(IDS)) } })
            }
            11 => {
                json!({ "op": "reached_end", "ticks": *r.pick(TICKS), "runtime": if r.chance(25) { Value::Null } else { json!(*r.pick(&[0, 1, 10_000_000, 100_000_000, 36_000_000_000_i64, -5])) } })
            }
            12 => json!({ "op": "successor", "item": item(r, false), "items": items(r, 6) }),
            13 => json!({ "op": "follow", "item": item(r, false), "watch": watch(r) }),
            14 => {
                let eps: Vec<Value> = (0..r.below(6))
                    .map(|_| {
                        let mut m = Map::new();
                        m.insert("Id".into(), json!(*r.pick(IDS)));
                        m.insert("Name".into(), json!("E"));
                        if r.chance(85) {
                            m.insert("IndexNumber".into(), json!(r.below(5) as i64));
                        }
                        if r.chance(70) {
                            m.insert("ParentIndexNumber".into(), json!(r.below(4) as i64));
                        }
                        Value::Object(m)
                    })
                    .collect();
                json!({ "op": "following", "item": item(r, false), "episodes": eps })
            }
            15 => json!({ "op": "allocation", "items": items(r, 7) }),
            16 => {
                json!({ "op": "item", "item": item(r, false), "ticks": *r.pick(TICKS), "moment": 700_000_100.5 })
            }
            _ => {
                let text = *r.pick(&[
                    "abc",
                    "a/b",
                    "../x",
                    "..",
                    "",
                    "ü",
                    "a b",
                    "A-1_z",
                    "0123456789abcdef0123456789abcdef",
                    "0123456789ABCDEF0123456789abcdef",
                    "0123456789abcdef0123456789abcde",
                    "g123456789abcdef0123456789abcdef",
                    "ａｂ",
                    "日本",
                    "a\u{0301}",
                    "x.y",
                    "mkv",
                    ".mkv",
                    "MKV",
                    "mk v",
                    "mkv/../",
                    "a\u{0}b",
                    "👨‍👩‍👧",
                ]);
                json!({ "op": "path", "text": text, "other": *r.pick(&["u1", "", "a/b", "é"]) })
            }
        };
        out.push(case);
    }
    out
}
