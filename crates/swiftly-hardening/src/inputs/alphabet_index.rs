//! AlphabetIndex (JellyfinKit/AlphabetIndex.swift): letters, keys, entries, condensing.
use crate::Rng;
use serde_json::{Value, json};

const NAMES: &[&str] = &[
    "The Matrix",
    "A Man",
    "Éclair",
    "ñandú",
    "Ça va",
    "Über",
    "Öl",
    "Ärger",
    "Straße",
    "ßtraße",
    "ǅ",
    "ǆ",
    "Ǆ",
    "ǈ",
    "«Старый» Новый год",
    "(500) Days of Summer",
    "1984",
    "007",
    "",
    " ",
    "…",
    "...!",
    "\"Quoted\"",
    "[REC]",
    "#hashtag",
    "Ёлки",
    "ёлка",
    "Елка",
    "Жизнь",
    "и мир",
    "Й",
    "Αθήνα",
    "ωραία",
    "ΐ",
    "ς",
    "العربية",
    "أحمد",
    "إبراهيم",
    "آمال",
    "ٱلله",
    "שלום",
    "東京",
    "ドラえもん",
    "한국어",
    "ＡＢＣ",
    "ａｂｃ",
    "Ⅳ",
    "½",
    "x",
    "z",
    "Ŝtelisto",
    "İstanbul",
    "ıslak",
    "ǰ",
    "ﬁsh",
    "ﬀ",
    "e\u{301}clair",
    "a\u{30a}ngstrom",
    "😀 smile",
    "\u{200B}hidden",
    "٣ Kinder",
    "1st",
    "Zorro",
    "Adam",
    "Åsa",
    "Ø",
    "Æon",
    "Œuvre",
    "ŉ",
    "ǆa",
    "ᾳ",
    "Ꭰ",
    "ᏸ",
];
const DATES: &[&str] = &[
    "2021-03-04T10:00:00Z",
    "2021-12-31",
    "2020-01-01T00:00:00.0000000Z",
    "2021",
    "20",
    "",
    "abcd-ef-gh",
    "0000-01-01",
    "2021-13-01",
    "2021-00-10",
    "2021-1",
    "2021-09",
    "1999-1x",
    "99999-01-01",
    "-123-01-01",
    "2024-02-29T12:00:00+02:00",
    "٢٠٢١-٠٣-٠٤",
    "2021/03/04",
    "２０２１-０３",
    "1850-06-01",
    "2026-11-08T08:00:00Z",
    "2026-10-31",
    "2026-11-01",
];
const RATINGS: &[f64] = &[
    0.0, 0.1, 5.5, 6.99, 7.0, 7.5, 9.99, 10.0, 10.5, 11.0, 100.0, -0.5, -1.0, -20.0, 1e9, 3.0,
];

fn item(rng: &mut Rng) -> Value {
    let name = rng.pick(NAMES).to_string();
    let sort = if rng.chance(30) {
        json!(rng.pick(NAMES))
    } else {
        Value::Null
    };
    let premiere = if rng.chance(30) {
        Value::Null
    } else {
        json!(rng.pick(DATES))
    };
    let year = if rng.chance(40) {
        Value::Null
    } else {
        json!(rng.range(-5, 2100))
    };
    let rating = if rng.chance(30) {
        Value::Null
    } else {
        json!(rng.pick(RATINGS))
    };
    let created = if rng.chance(25) {
        Value::Null
    } else {
        json!(rng.pick(DATES))
    };
    json!({ "name": name, "sort": sort, "premiere": premiere, "year": year, "rating": rating, "created": created })
}

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x414C_5048);
    let sortings = ["name", "neueste", "bewertung", "erscheinung"];
    let mut cases = vec![];
    for round in 0..240 {
        let sorting = sortings[round % 4];
        let n = if round < 8 {
            round as i64
        } else {
            rng.range(1, 60)
        };
        let mut items: Vec<Value> = (0..n).map(|_| item(&mut rng)).collect();
        if sorting == "neueste" && round % 3 == 0 && !items.is_empty() {
            // One shared year: Swift switches to months.
            for it in &mut items {
                it["created"] = json!(format!("2024-{:02}-15", rng.range(0, 14)));
            }
        }
        let height = [0.0, 120.0, 333.3, 640.0][rng.below(4) as usize];
        cases.push(json!({
            "sorting": sorting,
            "items": items,
            "slots": rng.range(0, 30),
            "height": height,
            "ys": [0.0, 1.0, 17.5, 100.0, 333.0, 640.0, 1000.0],
        }));
    }
    cases
}
