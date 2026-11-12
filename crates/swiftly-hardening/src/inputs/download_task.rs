//! DownloadTask (JellyfinKit/DownloadTask.swift): task description text, dismantle, applies.
use crate::Rng;
use serde_json::{Value, json};

const SEP: &str = "\u{1F}";

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x444F_574E);
    let ids = ["abc", "", "id with space", "ünï", "a\u{1F}b", "0", "👨‍👩‍👧"];
    let files = [
        "movie.mkv",
        "",
        "a\u{1F}b.mkv",
        "\u{1F}",
        "x\u{1F}\u{1F}y",
        "Straße.mp4",
        "dir/file",
        " ",
        "5",
    ];
    let gens: [i64; 9] = [0, 1, -1, 42, i64::MAX, i64::MIN, 7, 100, 9];
    let gen_texts = [
        "0",
        "1",
        "-1",
        "+5",
        "007",
        " 5",
        "5 ",
        "",
        "x",
        "٣",
        "１２",
        "9223372036854775807",
        "9223372036854775808",
        "-9223372036854775808",
        "-9223372036854775809",
        "1.5",
        "0x10",
        "--1",
        "+",
        "-",
        "1e3",
        "\u{1F}",
        "12abc",
    ];
    let mut out = vec![];
    // description + dismantle round trip
    for _ in 0..100 {
        let id = *rng.pick(&ids);
        let file = *rng.pick(&files);
        let generation = *rng.pick(&gens);
        out.push(json!({ "id": id, "gen": generation, "file": file, "reported": generation, "current": if rng.chance(30) { Value::Null } else { json!(rng.range(-2, 3)) }, "text": Value::Null }));
    }
    // raw text from the system (old forms, junk)
    for g in gen_texts {
        for (a, b) in [
            ("abc", "f.mkv"),
            ("abc", "a\u{1F}b"),
            ("", "f"),
            ("abc", ""),
        ] {
            let text = format!("{a}{SEP}{g}{SEP}{b}");
            out.push(json!({ "id": "x", "gen": 0, "file": "x", "reported": 3, "current": 3, "text": text }));
        }
    }
    for t in [
        Value::Null,
        json!(""),
        json!("abc"),
        json!("abc\u{1F}file"),
        json!("\u{1F}file"),
        json!("abc\u{1F}"),
        json!("\u{1F}"),
        json!("\u{1F}\u{1F}"),
        json!("a\u{1F}b\u{1F}c\u{1F}d"),
        json!("a\u{1F}\u{1F}c"),
    ] {
        out.push(
            json!({ "id": "x", "gen": 0, "file": "x", "reported": 1, "current": 2, "text": t }),
        );
    }
    out
}
