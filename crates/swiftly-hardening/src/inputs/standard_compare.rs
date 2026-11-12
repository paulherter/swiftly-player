//! Inputs of the oracle domains `standard_compare_de|en|ru`: pairs of names for
//! `String.localizedStandardCompare` (leading zeros, mixed digits and letters, accents, case,
//! several digit runs, wide and foreign digits). The three domains share one list; each is run by
//! Swift in a process that has the matching language (`-AppleLanguages (ru)`).

use crate::Rng;
use serde_json::{Value, json};

const FIXED: &[(&str, &str)] = &[
    ("7", "07"),
    ("07", "007"),
    ("7", "007"),
    ("a7", "a07"),
    ("a07", "a7"),
    ("a7b", "a07b"),
    ("a07b", "a7c"),
    ("7 7", "07 07"),
    ("07 7", "7 07"),
    ("1.07", "1.7"),
    ("00", "0"),
    ("000", "00"),
    ("a00b", "a0b"),
    ("x07", "X7"),
    ("07x", "7X"),
    ("e07", "E7"),
    ("é7", "e07"),
    ("ä7", "a07"),
    ("1 02", "01 2"),
    ("1,0", "1,00"),
    (
        "1000000000000000000000000000000001",
        "01000000000000000000000000000000001",
    ),
    ("0000000000000000000000000000000000007", "7"),
    ("a\u{200B}07", "a7"),
    ("e\u{0301}07", "é7"),
    ("Folge 07", "Folge 7"),
    ("Staffel 1", "Staffel 01"),
    ("S01E02", "S1E2"),
    ("Track 007", "track 7"),
];

const LETTERS: &[&str] = &["a", "e", "x", "o", "u", "s", "i", "z", "k"];
const SEPARATORS: &[&str] = &[" ", "-", ".", ",", "_", "(", ")"];
const NUMBERS: &[&str] = &["7", "12", "1", "5", "30", "9", "10", "2", "100", "0", "99"];

fn base(rng: &mut Rng) -> Vec<String> {
    let n = 1 + rng.below(5) as usize;
    (0..n)
        .map(|_| match rng.below(4) {
            0 | 1 => (*rng.pick(LETTERS)).to_string(),
            2 => (*rng.pick(NUMBERS)).to_string(),
            _ => (*rng.pick(SEPARATORS)).to_string(),
        })
        .collect()
}

fn accent(letter: &str) -> &str {
    match letter {
        "a" => "ä",
        "e" => "é",
        "o" => "ö",
        "u" => "ü",
        "i" => "í",
        "s" => "š",
        other => other,
    }
}

fn vary(rng: &mut Rng, token: &str, harsh: bool) -> String {
    let first = token.chars().next().unwrap_or(' ');
    if first.is_ascii_digit() {
        let zeros = if rng.chance(35) {
            0
        } else {
            rng.below(3) as usize
        };
        // Wide and foreign digits (U+FF10.., U+0660..) and "ß" against "SS" order differently in
        // Apple's code (F-collate-02) and stay out of the generator.
        return format!("{}{token}", "0".repeat(zeros));
    }
    if first.is_alphabetic() {
        let mut out = token.to_string();
        if rng.chance(30) {
            out = accent(token).to_string();
            if harsh && rng.chance(20) && out == "é" {
                out = "e\u{0301}".to_string();
            }
        }
        if rng.chance(30) {
            out = out.to_uppercase();
        }
        return out;
    }
    token.to_string()
}

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x57A4_DA2D);
    let mut cases: Vec<Value> = FIXED
        .iter()
        .flat_map(|(a, b)| [json!({ "a": a, "b": b }), json!({ "a": b, "b": a })])
        .collect();
    // Pairs that differ only in case, accent and leading zeros: the interesting ties.
    while cases.len() < 3600 {
        let tokens = base(&mut rng);
        let harsh = cases.len().is_multiple_of(4);
        let a: String = tokens.iter().map(|t| vary(&mut rng, t, harsh)).collect();
        let b: String = tokens.iter().map(|t| vary(&mut rng, t, harsh)).collect();
        cases.push(json!({ "a": a, "b": b }));
    }
    // Unrelated pairs from the same pieces.
    while cases.len() < 4400 {
        let a: String = base(&mut rng)
            .iter()
            .map(|t| vary(&mut rng, t, true))
            .collect();
        let b: String = base(&mut rng)
            .iter()
            .map(|t| vary(&mut rng, t, true))
            .collect();
        cases.push(json!({ "a": a, "b": b }));
    }
    cases
}
