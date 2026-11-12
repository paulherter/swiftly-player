//! Oracle inputs (group C, text): PluralCategory, VersionComparison, TimestampFormat.
use crate::Rng;
use serde_json::{Value, json};

/// `{lang, n}`: every language tag the app sees, the counts of the brief, then random counts.
pub fn plural_category() -> Vec<Value> {
    let langs = [
        "de", "en", "ru", "uk", "be", "de-DE", "en-US", "ru-RU", "ru_RU", "uk-UA", "be-BY",
        "de_AT", "en_GB", "pt-BR", "", "r", "e", "RU", "Ru", "rus", "ukr", "ruu", "x", "ja", "и",
    ];
    let counts: [i64; 28] = [
        0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14, 15, 19, 20, 21, 22, 24, 25, 100, 101, 102, 111,
        112, 121, 1000, 1_000_000,
    ];
    let mut out = vec![];
    for lang in langs {
        for n in counts {
            out.push(json!({ "lang": lang, "n": n }));
            if n > 0 {
                out.push(json!({ "lang": lang, "n": -n }));
            }
        }
    }
    let mut rng = Rng::new(0x504C_5543);
    for _ in 0..1500 {
        let lang = *rng.pick(&["de", "en", "ru", "uk", "be", "ru-RU"]);
        let n = rng.range(-1_000_000_000, 1_000_000_000);
        let n = if rng.chance(30) { n / 1000 } else { n };
        out.push(json!({ "lang": lang, "n": n }));
    }
    for n in [i64::MAX, i64::MAX - 1, -i64::MAX, 9_999_999_999_999_999_i64] {
        for lang in ["de", "ru", "uk"] {
            out.push(json!({ "lang": lang, "n": n }));
        }
    }
    out
}

/// `{there, here, build_there, build_here, text}`.
pub fn version_compare() -> Vec<Value> {
    let versions = [
        "1.0.0",
        "1.0",
        "1",
        "1.0.4",
        "1.0.9",
        "1.0.10",
        "1.1",
        "1.1.0",
        "1.1.0.0",
        "1.1.0.1",
        "2.0.0",
        "10.0",
        "9.9.9",
        "",
        ".",
        "..",
        "1..2",
        "1.",
        ".1",
        "1.x",
        "x.1",
        "v1.0.3",
        "1.0.3-beta",
        "1.0.3b2",
        "1.0-rc1",
        "1.2.3.4.5.6",
        "0.0.1",
        "01.002.0003",
        "٣.١",
        "1.½",
        "1.①",
        "1.٢",
        "99999999999999999999.1",
        "9223372036854775807",
        "9223372036854775808",
        "1.0.3\n",
        " 1.0.3",
        "1.0.3 ",
        "1.0.3+7",
        "１.０",
        "1.0.0-0",
        "3.14.15.9265",
        "1.\u{200B}2",
        "1.2\u{301}",
    ];
    let builds: [Value; 9] = [
        json!(null),
        json!(0),
        json!(1),
        json!(6),
        json!(7),
        json!(8),
        json!(-3),
        json!(1_000_000),
        json!(i64::MAX),
    ];
    let texts = [
        "",
        "build 7",
        "Build 7",
        "BUILD 12",
        "Bau 12",
        "bau 3",
        "Umbau 12",
        "Ausbau 3",
        "rebuild 9",
        "Rebuild 9",
        "build 7, build 9",
        "build 9 then build 7",
        "Build 7\nBau 8",
        "build",
        "build ",
        "build x",
        "build 007",
        "build  7",
        "build\t7",
        "build 99999999999999999999",
        "build 9223372036854775807",
        "build 9223372036854775808",
        "bau ٣",
        "build ٣",
        "build ½",
        "build ①",
        "(build 5)",
        "-build 5",
        "1build 5",
        "_build 5",
        "build 5build 6",
        "\u{00E9}build 4",
        "e\u{301}build 4",
        "build \u{301}7",
        "build\u{301} 7",
        "bau\u{00A0}9",
        "build ٣4",
        "BUILD\u{FF11}",
        "İbuild 3",
        "Build 7 · Bau 9 · build 3",
        "ǅbuild 2",
        "Das Bau 4 Update",
        "Neu: bau 12!",
        "release build 1000000",
        "Bau 0",
        "build 0",
        "build 1 build 2 build 3",
        "xbuild 9",
        "x build 9",
        "😀build 9",
        "😀 build 9",
        "build 😀 9",
        "ß build 5",
        "BUILD 5\u{0130}",
        "bau 5 BAU 6",
    ];
    let mut out = vec![];
    for (i, a) in versions.iter().enumerate() {
        for (j, b) in versions.iter().enumerate() {
            if (i + j) % 2 == 0 || a == b {
                out.push(json!({ "there": a, "here": b, "build_there": null, "build_here": 0, "text": "" }));
            }
        }
    }
    let mut rng = Rng::new(0x5645_5253);
    for _ in 0..1500 {
        let a = rng.pick(&versions);
        let b = if rng.chance(40) {
            *a
        } else {
            *rng.pick(&versions)
        };
        out.push(json!({
            "there": a, "here": b, "build_there": rng.pick(&builds), "build_here": rng.range(-2, 9), "text": ""
        }));
    }
    for t in texts {
        out.push(json!({ "there": "1.0", "here": "1.0", "build_there": null, "build_here": 0, "text": t }));
    }
    let atoms = [
        "build ", "bau ", "Build ", "Bau ", "7", "12", " ", "\n", "x", "re", "um", "é", "٣",
        "\u{301}", "9", "0", "-", "(", "\u{00A0}",
    ];
    for _ in 0..800 {
        let n = rng.range(1, 9);
        out.push(json!({ "there": "1.0", "here": "1.0", "build_there": null, "build_here": 0, "text": rng.word(&atoms, n as usize) }));
    }
    out
}

/// `{text}`: Jellyfin timestamps and their hostile cousins.
pub fn timestamp() -> Vec<Value> {
    let fixed = [
        "2026-09-03T14:10:09.2201736Z",
        "2026-09-03T14:10:09Z",
        "2026-09-03T14:10:09.5Z",
        "2026-09-03T14:10:09.123456789Z",
        "2026-09-03T14:10:09.1234567890123Z",
        "2026-09-03T14:10:09.Z",
        "2026-09-03T14:10:09.",
        "2026-09-03T14:10:09",
        "2026-09-03T14:10:09+02:00",
        "2026-09-03T14:10:09-05:30",
        "2026-09-03T14:10:09+0200",
        "2026-09-03T14:10:09+02",
        "2026-09-03T14:10:09.250+02:00",
        "2026-09-03t14:10:09Z",
        "2026-09-03 14:10:09Z",
        "2026-09-03T14:10:09z",
        "2026-09-03T24:00:00Z",
        "2026-09-03T23:59:60Z",
        "2026-09-03T23:59:59Z",
        "2026-09-03T14:60:00Z",
        "2026-02-29T00:00:00Z",
        "2024-02-29T00:00:00Z",
        "2100-02-29T00:00:00Z",
        "2000-02-29T00:00:00Z",
        "2026-13-01T00:00:00Z",
        "2026-00-10T00:00:00Z",
        "2026-04-31T00:00:00Z",
        "2026-04-30T00:00:00Z",
        "0000-01-01T00:00:00Z",
        "0001-01-01T00:00:00Z",
        "9999-12-31T23:59:59Z",
        "1970-01-01T00:00:00Z",
        "1969-12-31T23:59:59Z",
        "1900-01-01T00:00:00Z",
        "1582-10-14T00:00:00Z",
        "1582-10-04T00:00:00Z",
        "2026-9-3T14:10:09Z",
        "26-09-03T14:10:09Z",
        "20260903T141009Z",
        "2026-09-03",
        "2026-09-03T",
        "2026-09-03T14",
        "2026-09-03T14:10",
        "",
        " ",
        "Z",
        " 2026-09-03T14:10:09Z",
        "2026-09-03T14:10:09Z ",
        "2026-09-03T14:10:09Z\n",
        "2026-09-03T14:10:09ZZ",
        "2026-09-03T14:10:09+02:00Z",
        "2026-09-03T14:10:09+24:00",
        "2026-09-03T14:10:09+23:59",
        "2026-09-03T14:10:09-14:00",
        "2026-09-03T14:10:09+00:60",
        "2026-09-03T14:10:09+99:99",
        "2026-09-03T14:10:09 +02:00",
        "2026-09-03T14:10:09 Z",
        "2026-09-03T14:10:09,5Z",
        "2026-09-03T14:10:09.5+02:00",
        "2026-09-03T14:10:09.0000000Z",
        "2026-09-03T14:10:09.9999999Z",
        "2026-09-03T14:10:09.9999999999Z",
        "2026-09-03T14:10:09.-5Z",
        "2026-09-03T14:10:09.5.5Z",
        "٢٠٢٦-٠٩-٠٣T١٤:١٠:٠٩Z",
        "２０２６-０９-０３T１４:１０:０９Z",
        "2026-09-03T14:10:09Z\u{200B}",
        "\u{FEFF}2026-09-03T14:10:09Z",
        "2026-09-03T14:10:09\u{FF1A}00Z",
        "2026‐09‐03T14:10:09Z",
        "2026-09-03T14.10.09Z",
        "2026/09/03T14:10:09Z",
        "-2026-09-03T14:10:09Z",
        "+2026-09-03T14:10:09Z",
        "12026-09-03T14:10:09Z",
        "2026-09-03T14:10:09.2201736+00:00",
        "2026-09-03T14:10:09.2201736-00:00",
        "2026-12-31T23:59:59.9999999Z",
        "2026-03-29T01:30:00Z",
        "2026-10-25T01:30:00Z",
        "2016-12-31T23:59:60Z",
        "2016-12-31T23:59:60.5Z",
        "2026-09-03T00:00:00.0000000Z",
        "2026-09-03T00:00:00.0Z",
        "Mon, 03 Sep 2026 14:10:09 GMT",
        "now",
        "null",
        "0",
        "1788444609",
    ];
    let mut out: Vec<Value> = fixed.iter().map(|t| json!({ "text": t })).collect();
    let mut rng = Rng::new(0x5453_544D);
    for _ in 0..3000 {
        let y = rng.range(1, 9999);
        let mo = rng.range(1, 12);
        let d = rng.range(1, 31);
        let h = rng.range(0, 23);
        let mi = rng.range(0, 59);
        let s = rng.range(0, 59);
        let frac_len = rng.range(0, 9);
        let frac: String = (0..frac_len)
            .map(|_| char::from(b'0' + rng.below(10) as u8))
            .collect();
        let frac = if frac_len == 0 {
            String::new()
        } else {
            format!(".{frac}")
        };
        let zone = match rng.below(8) {
            0..=3 => "Z".to_owned(),
            4 => format!("+{:02}:{:02}", rng.range(0, 14), rng.range(0, 59)),
            5 => format!("-{:02}:{:02}", rng.range(0, 14), rng.range(0, 59)),
            6 => format!("+{:02}{:02}", rng.range(0, 14), rng.range(0, 59)),
            _ => String::new(),
        };
        out.push(
            json!({ "text": format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}{frac}{zone}") }),
        );
    }
    out
}
