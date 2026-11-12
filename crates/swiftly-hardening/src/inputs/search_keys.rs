//! Domain `search_keys` (SearchKeys.swift): the TV keyboard rows, what a key press and hardware text do to
//! the term (characters = grapheme clusters, special-case upper/lower mappings), `SearchGroups.showsTitles`
//! and `SearchScreen.state`. Read by `Domain_Description.swift` and `tests/oracle_search_keys.rs`.
use crate::Rng;
use serde_json::{Value, json};

const KEYS: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÜß1234567890-";

const PIECES: &[&str] = &[
    "Tatort",
    "tatort",
    " ",
    "  ",
    "-",
    "--",
    "a",
    "A",
    "é",
    "e\u{301}",
    "ß",
    "ǰ",
    "ŉ",
    "İ",
    "ı",
    "ﬁ",
    "ǆ",
    "ǅ",
    "ᾳ",
    "ς",
    "Σ",
    "ΐ",
    "1",
    "²",
    "½",
    "一",
    "٣",
    "①",
    "🙂",
    "👨‍👩‍👧",
    "🇩🇪",
    "\u{301}",
    "\u{200D}",
    "\r\n",
    "\n",
    "\t",
    "\u{00A0}",
    "(",
    "!",
    "日本",
    "ñ",
    "Ñ",
    "ǰ\u{301}",
    "-\u{301}",
    " \u{301}",
];

fn word(rng: &mut Rng, max: i64) -> String {
    (0..rng.range(0, max)).map(|_| *rng.pick(PIECES)).collect()
}

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x5345_4B59);
    let mut out = vec![
        json!({"op": "rows", "speech": true}),
        json!({"op": "rows", "speech": false}),
    ];
    for _ in 0..1500 {
        let c = if rng.chance(70) {
            let keys: Vec<char> = KEYS.chars().collect();
            keys[rng.below(keys.len() as u64) as usize].to_string()
        } else {
            let mut s = rng.pick(PIECES).to_string();
            if rng.chance(20) {
                s.push_str(rng.pick(PIECES));
            }
            s
        };
        out.push(json!({"op": "typed", "c": c, "term": word(&mut rng, 5)}));
    }
    for op in ["space_fits", "with_space", "delete"] {
        for _ in 0..500 {
            out.push(json!({"op": op, "term": word(&mut rng, 6)}));
        }
    }
    for _ in 0..1800 {
        out.push(json!({"op": "hardware", "text": word(&mut rng, 8), "term": word(&mut rng, 4)}));
    }
    for s in 0..3 {
        for f in 0..3 {
            for r in [0, 1, 2, -1] {
                out.push(json!({"op": "titles", "s": s, "f": f, "r": r}));
            }
        }
    }
    for _ in 0..800 {
        out.push(json!({"op": "state", "term": word(&mut rng, 4), "history": rng.range(-1, 3), "hits": rng.chance(50),
            "answered": rng.chance(50), "disrupted": rng.chance(30), "waited": rng.chance(50)}));
    }
    out
}
