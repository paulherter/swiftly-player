//! Small pure rules of JellyfinKit: AgeRating, WholeNumber, ResumePoint, DownloadQuality,
//! DisplayRules, EpisodeEnd, ChapterBar. One generator function per domain.
use crate::Rng;
use serde_json::{Value, json};

fn opt_f(rng: &mut Rng, v: f64) -> Value {
    if rng.chance(15) {
        Value::Null
    } else {
        json!(v)
    }
}

pub fn age_rating() -> Vec<Value> {
    let fixed: &[Option<&str>] = &[
        None,
        Some(""),
        Some("   "),
        Some("age"),
        Some("Age"),
        Some("AGE 12"),
        Some("age 12"),
        Some("age-16"),
        Some("Age_18"),
        Some("age12"),
        Some("age  - 7"),
        Some("age 1x"),
        Some("age x1"),
        Some("age ٣"),
        Some("age ½"),
        Some("age Ⅳ"),
        Some("age ２１"),
        Some("\tage 6\t"),
        Some("age\n12"),
        Some(" PG-13 "),
        Some("FSK 16"),
        Some("DE-12"),
        Some("TV-MA"),
        Some("agency"),
        Some("age+"),
        Some("age 12+"),
        Some("age 007"),
        Some("age 123456789012345678901234567890"),
        Some("\u{00A0}age 9"),
        Some("\u{3000}age 9"),
        Some("ageÄ"),
        Some("age ٣٤"),
        Some("age ①"),
        Some("age 12\u{301}"),
        Some("age\u{00A0}12"),
        Some("age -\u{2003}5"),
        Some("ＡＧＥ 12"),
        Some("\u{200B}age 9"),
        Some("age 9\u{200B}"),
        Some("\u{FEFF}age 9"),
        Some("age 9\u{FEFF}"),
        Some("age\u{200B}9"),
    ];
    let mut rng = Rng::new(0x4147_4552);
    let mut out: Vec<Value> = fixed.iter().map(|s| json!({ "raw": s })).collect();
    let parts = [
        "age", "Age", "AGE", " ", "-", "_", "1", "12", "0", "x", "٣", "½", "+", "\t", "\u{00A0}",
        "PG", "é",
    ];
    for _ in 0..120 {
        let n = rng.range(1, 6);
        let s = rng.word(&parts, n as usize);
        out.push(json!({ "raw": s }));
    }
    out
}

pub fn whole_number() -> Vec<Value> {
    let fixed = [
        json!("nan"),
        json!("inf"),
        json!("-inf"),
        json!(0.0),
        json!(-0.0),
        json!(0.5),
        json!(-0.5),
        json!(1.9),
        json!(-1.9),
        json!(9.223372036854775e18),
        json!(9.223372036854776e18),
        json!(9.223372036854777e18),
        json!(-9.223372036854776e18),
        json!(-9.223372036854778e18),
        json!(1e19),
        json!(-1e19),
        json!(1e300),
        json!(-1e300),
        json!(5e-324),
        json!(4503599627370497.5),
        json!(9007199254740993.0),
        json!(2147483648.7),
        json!(-2147483649.2),
    ];
    let mut rng = Rng::new(0x5748_4F4C);
    let mut out: Vec<Value> = fixed.iter().map(|v| json!({ "value": v })).collect();
    for _ in 0..140 {
        let exp = rng.range(-3, 22);
        let v = (rng.unit() * 2.0 - 1.0) * 10f64.powi(exp as i32);
        out.push(json!({ "value": v }));
    }
    out
}

pub fn resume_point() -> Vec<Value> {
    let positions = [
        -5.0, 0.0, 30.0, 59.999, 60.0, 60.0000001, 60.5, 61.0, 120.0, 3599.0, 3600.0, 5400.0, 1e9,
    ];
    let runtimes = [
        -10.0, 0.0, 0.5, 60.0, 119.0, 120.0, 121.0, 180.0, 3600.0, 3660.0, 5400.0, 1e7,
    ];
    let mut rng = Rng::new(0x5245_5355);
    let mut out = vec![];
    for p in positions {
        for r in runtimes {
            out.push(json!({ "position": p, "runtime": r }));
        }
        out.push(json!({ "position": p, "runtime": null }));
    }
    out.push(json!({ "position": null, "runtime": 100.0 }));
    out.push(json!({ "position": null, "runtime": null }));
    for _ in 0..120 {
        let r = rng.unit() * 8000.0;
        let p = if rng.chance(50) {
            r - 60.0 + (rng.unit() - 0.5) * 2.0
        } else {
            rng.unit() * 8000.0
        };
        out.push(json!({ "position": opt_f(&mut rng, p), "runtime": opt_f(&mut rng, r) }));
    }
    out
}

pub fn download_quality() -> Vec<Value> {
    let raws = ["original", "hd1080", "hd720", "sd480"];
    let tri = [Value::Null, json!(true), json!(false)];
    let ticks = [
        Value::Null,
        json!(0),
        json!(-5),
        json!(1),
        json!(10_000_000),
        json!(36_000_000_000i64),
        json!(54_000_000_000i64),
        json!(i64::MAX),
        json!(7_200_000_000_000i64),
    ];
    let bytes = [
        0i64,
        1,
        -3,
        1_000_000,
        4_000_000_000,
        80_000_000_000,
        i64::MAX,
    ];
    let mut rng = Rng::new(0x4451_5541);
    let mut out = vec![];
    for round in 0..300 {
        let files: Vec<Value> = (0..rng.range(0, 4))
            .map(|_| json!([*rng.pick(&bytes), rng.pick(&ticks).clone()]))
            .collect();
        out.push(json!({
            "quality": raws[round % 4],
            "video": rng.pick(&tri).clone(),
            "audio": rng.pick(&tri).clone(),
            "bytes": *rng.pick(&bytes),
            "ticks": rng.pick(&ticks).clone(),
            "files": files,
            "original": *rng.pick(&bytes),
            "source": if rng.chance(30) { Value::Null } else { json!(rng.range(-5, 20_000_000)) },
        }));
    }
    out
}

const TERMS: &[&str] = &[
    "",
    " ",
    "a",
    "ab",
    " a ",
    "a b",
    "\n\n",
    "\r\n",
    "a\r\n",
    "\u{0085}a\u{0085}",
    "\u{2028}ab",
    "\u{200B}a",
    "\u{00A0}a\u{00A0}",
    "\u{3000}ab\u{3000}",
    "e\u{301}",
    "e\u{301}e\u{301}",
    "🇩🇪",
    "🇩🇪🇫🇷",
    "👨‍👩‍👧",
    "👨‍👩‍👧x",
    "ab\u{FEFF}",
    "\u{FEFF}a",
    "한국",
    "\u{1100}\u{1161}",
    "\u{1100}\u{1161}\u{11A8}",
    "ﬁ",
    "\t\ta\t\t",
    "a\u{200D}",
    "\u{0301}",
    "\u{0301}\u{0301}",
    "x\u{0301}",
    "\u{180E}ab",
    "\u{2060}ab",
    "ab ",
    "\u{1680}ab",
    "\u{0009}\u{000B}\u{000C}ab",
];

pub fn display_rules() -> Vec<Value> {
    let arts = [
        Value::Null,
        json!("Series"),
        json!("Movie"),
        json!("series"),
        json!(""),
    ];
    let ints = [Value::Null, json!(0), json!(1), json!(5), json!(-3)];
    let bools = [Value::Null, json!(true), json!(false)];
    let secs = [
        Value::Null,
        json!(0.0),
        json!(-1.0),
        json!(0.001),
        json!(5400.0),
        json!(1e12),
    ];
    let mut rng = Rng::new(0x4453_504C);
    let mut out = vec![];
    for i in 0..200 {
        out.push(json!({
            "seconds": rng.pick(&secs).clone(),
            "term": TERMS[i % TERMS.len()],
            "art": rng.pick(&arts).clone(),
            "seasons": rng.pick(&ints).clone(),
            "watched": rng.pick(&bools).clone(),
            "open": rng.pick(&ints).clone(),
            "type": rng.pick(&arts).clone(),
            "series_id": if rng.chance(50) { Value::Null } else { json!("s1") },
        }));
    }
    out
}

pub fn episode_end() -> Vec<Value> {
    let durations: [f64; 11] = [
        -1.0, 0.0, 59.0, 60.0, 60.001, 300.0, 300.001, 1200.0, 2700.0, 7200.0, 1e6,
    ];
    let mut rng = Rng::new(0x4550_454E);
    let mut out = vec![];
    for d in durations {
        for k in 0..12 {
            let p = match k {
                0 => 0.0,
                1 => -3.0,
                2 => d - 150.0,
                3 => d - 150.0001,
                4 => d * 0.96,
                5 => d * 0.9599,
                6 => d - 1.0,
                7 => d - 0.9999,
                8 => d,
                9 => d + 5.0,
                _ => rng.unit() * d.max(1.0),
            };
            let since = [0.0, 4.99, 5.0, 5.01, 60.0][rng.below(5) as usize];
            let card = rng.chance(30);
            out.push(json!({ "position": p, "duration": d, "since": since, "card": card }));
        }
    }
    out
}

pub fn chapter_bar() -> Vec<Value> {
    let mut rng = Rng::new(0x4348_4150);
    let mut out = vec![];
    for round in 0..260 {
        let duration = [0.0, -4.0, 100.0, 1500.0, 5400.0, 7261.5][rng.below(6) as usize];
        let n = rng.range(0, 14);
        let mut chapters = vec![];
        match round % 4 {
            // a uniform grid like the server's placeholder chapters
            0 => {
                let step = [60.0, 300.0, 600.0][rng.below(3) as usize];
                for i in 0..n {
                    chapters.push(json!({ "name": format!("Chapter {}", i + 1), "from": i as f64 * step + (rng.unit() - 0.5) * 0.6 }));
                }
            }
            _ => {
                for i in 0..n {
                    let from = match rng.below(8) {
                        0 => -(rng.unit() * 20.0),
                        1 => duration + rng.unit() * 20.0,
                        2 => 0.0,
                        3 => (rng.range(0, 6) * 100) as f64,
                        _ => rng.unit() * duration.max(100.0),
                    };
                    let name =
                        [" Intro ", "Kapitel 1", "", "\nEnd\t", "Ünïcode"][rng.below(5) as usize];
                    chapters.push(json!({ "name": format!("{name}{i}"), "from": from }));
                }
            }
        }
        let width = [0.0, -5.0, 200.0, 360.0, 1000.0][rng.below(5) as usize];
        let min_width = [0.0, 10.0, 24.0, 60.0][rng.below(4) as usize];
        let gap = [0.0, 2.0, 6.0][rng.below(3) as usize];
        out.push(json!({
            "chapters": chapters,
            "duration": duration,
            "width": width,
            "min_width": min_width,
            "gap": gap,
            "shares": [-0.1, 0.0, 0.25, 0.5, 0.999, 1.0, 1.5],
            "spots": [-1.0, 0.0, 30.0, 150.0, 2000.0, 99999.0],
        }));
    }
    out
}

/// Which code points the search-term trim removes (and how clusters of one count): `<c>a`.
pub fn term_trim() -> Vec<Value> {
    let mut out = vec![];
    let ranges: &[(u32, u32)] = &[
        (0, 0x2FF),
        (0x1680, 0x1680),
        (0x1800, 0x1810),
        (0x2000, 0x2070),
        (0x3000, 0x3000),
        (0xFE00, 0xFEFF),
        (0xFFF0, 0xFFFF),
        (0xE0000, 0xE0080),
        (0x1D173, 0x1D17A),
    ];
    for (lo, hi) in ranges {
        for cp in *lo..=*hi {
            if let Some(c) = char::from_u32(cp) {
                out.push(json!({ "term": format!("{c}a"), "cp": cp }));
            }
        }
    }
    out
}
