//! Domain `settings_sync` (SettingsSync.swift): value coding, entries, what the server holds, who wins.
//! Cases are read by `Domain_Settings.swift` (Tools/Oracle) and `tests/oracle_settings.rs`.
use crate::Rng;
use serde_json::{Value, json};

const NAMES: &[(&str, &str)] = &[
    ("tonSprache", "text"),
    ("utSprache", "text"),
    ("utAuto", "bool"),
    ("utAussehen", "json"),
    ("naechsteAuto", "bool"),
    ("introAbspannAuto", "bool"),
    ("restzeitAlsEnde", "bool"),
    ("vorSek", "int"),
    ("zurueckSek", "int"),
    ("titelAlsLogo", "bool"),
    ("fortschritt", "bool"),
    ("merklisteAn", "bool"),
    ("alphabetAn", "bool"),
    ("neuGetrennt", "bool"),
    ("startReihen", "list"),
    ("startAus", "list"),
    ("genreChips", "bool"),
    ("startGenres", "list"),
    ("startBibliotheken", "json"),
];
const KINDS: &[&str] = &["bool", "int", "text", "list", "json"];
const TEXTS: &[&str] = &[
    "true",
    "false",
    "True",
    "TRUE",
    "1",
    "0",
    "",
    " ",
    "10",
    "0",
    "3600",
    "3601",
    "-1",
    "+5",
    "007",
    "1.5",
    "1e2",
    " 5",
    "5 ",
    "9223372036854775807",
    "99999999999999999999",
    "٣",
    "de",
    "ä",
    "e\u{301}",
    "😀",
    "[]",
    "[\"a\"]",
    "[\"a\",\"b\"]",
    "[\"a/b\"]",
    "[\"a\\/b\"]",
    "[1]",
    "[null]",
    "{}",
    "{\"a\":1}",
    "{\"a\":\"x/y\"}",
    "5",
    "\"s\"",
    "null",
    "true ",
    "[\"é\"]",
    "[\"\\u00e9\"]",
    "[ \"a\" ]",
    "[\"a\",]",
    "{\"a\":}",
    "[1,2",
    "{\"id\":\"1\",\"n\":\"é\"}",
    "[{\"id\":\"1\"}]",
    "\u{FEFF}[]",
    "[]\n",
    "\n{}",
    "{\"a\":1}x",
];

fn text(rng: &mut Rng) -> &'static str {
    rng.pick(TEXTS)
}

fn typed(rng: &mut Rng, kind: &str) -> Value {
    match kind {
        "bool" => json!({ "k": "bool", "v": rng.chance(50) }),
        "int" => json!({ "k": "int", "v": rng.range(-5, 4000) }),
        "list" => {
            json!({ "k": "list", "v": (0..rng.below(4)).map(|_| *rng.pick(&["a", "b/c", "é", "", "😀", "q\"r", "x\\y"])).collect::<Vec<_>>() })
        }
        "json" => {
            json!({ "k": "json", "v": *rng.pick(&["{}", "[]", "{\"a\":1}", "[{\"id\":\"x/y\"}]"]) })
        }
        _ => json!({ "k": "text", "v": *rng.pick(&["de", "", "a b", "ä", "x/y"]) }),
    }
}

fn prefs(rng: &mut Rng) -> Value {
    let mut m = serde_json::Map::new();
    for (name, _) in NAMES {
        if rng.chance(45) {
            m.insert(format!("swiftly.{name}"), json!(text(rng)));
        }
    }
    if rng.chance(85) {
        let c = match rng.below(7) {
            0 => "garbage".to_owned(),
            1 => "".to_owned(),
            2 => "1.5".to_owned(),
            3 => "1e12".to_owned(),
            4 => "-5".to_owned(),
            5 => "1700000000000.4".to_owned(),
            _ => (1_700_000_000_000_i64 + rng.range(-5, 5)).to_string(),
        };
        m.insert("swiftly.changed".into(), json!(c));
    }
    if rng.chance(20) {
        m.insert("other".into(), json!("x"));
        m.insert("swiftly.unknown".into(), json!("1"));
    }
    Value::Object(m)
}

pub fn settings_sync() -> Vec<Value> {
    let mut rng = Rng::new(0x5345_5453);
    let mut out = Vec::new();
    for t in TEXTS {
        for k in KINDS {
            out.push(json!({ "op": "decode", "text": t, "kind": k }));
        }
    }
    for (name, _) in NAMES {
        for suffix in ["", "|srv", "|a|b", "|"] {
            out.push(json!({ "op": "entry", "key": format!("{name}{suffix}") }));
        }
    }
    for key in [
        "",
        "|",
        "unknown",
        "TonSprache",
        "tonSprache ",
        "|tonSprache",
        "vorSek|x|y",
    ] {
        out.push(json!({ "op": "entry", "key": key }));
    }
    for _ in 0..800 {
        out.push(json!({ "op": "remote", "prefs": prefs(&mut rng) }));
    }
    for _ in 0..500 {
        let mut values = serde_json::Map::new();
        for (name, kind) in NAMES {
            if rng.chance(40) {
                values.insert((*name).to_owned(), typed(&mut rng, kind));
            }
        }
        if rng.chance(20) {
            values.insert("notAnEntry".into(), typed(&mut rng, "text"));
        }
        let changed = 1_700_000_000_000_i64 + rng.range(-1_000_000_000, 1_000_000_000);
        out.push(json!({ "op": "fields", "values": values, "changed": changed }));
    }
    for _ in 0..1500 {
        let p = prefs(&mut rng);
        let local = if rng.chance(20) {
            Value::Null
        } else {
            json!(1_700_000_000_000_i64 + rng.range(-5, 5))
        };
        out.push(json!({ "op": "decide", "prefs": p, "local": local, "other": rng.chance(25) }));
    }
    for _ in 0..300 {
        let now = 1_700_000_000_000_i64 + rng.range(-3, 3);
        let last = if rng.chance(25) {
            Value::Null
        } else {
            json!(1_700_000_000_000_i64 + rng.range(-3, 3))
        };
        out.push(json!({ "op": "change_time", "now": now, "last": last }));
    }
    for _ in 0..300 {
        let mut present = serde_json::Map::new();
        for (name, _) in NAMES {
            for suffix in ["", "|srv", "|other"] {
                if rng.chance(18) {
                    present.insert(format!("{name}{suffix}"), json!(text(&mut rng)));
                }
            }
        }
        out.push(json!({ "op": "collect", "suffix": *rng.pick(&["|srv", "", "|other"]), "present": present }));
    }
    out
}
