//! Localizable.xcstrings sweep: every key, every language (de, en, ru), against the texts in the core.
//!
//! The Apple catalogue is the truth the apps show. This test parses `Sources/Shared/Localizable.xcstrings` on its own
//! (plain `serde_json`, not the core's loader) and checks, for all keys and languages:
//! * the core holds the same text (plain string or every plural variation) as the catalogue,
//! * the placeholders of en and ru equal those of the German key (position and kind),
//! * plural keys have the forms the language needs, and the core picks the form the CLDR rule of de/en/ru asks for
//!   for a list of counts (0, 1, 2, 3, 4, 5, 11, 12, 14, 21, 22, 25, 100, 101, 102, 111, 1000000, 1000001, i64::MAX),
//! * every plain string renders with generated arguments without leftovers and without a panic.
//!
//! The Swift side (`String(localized:)` against the bundle) cannot run headless; the catalogue file is what it reads.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::Value;
use swiftly_l10n::catalog::{Catalog, Text};
use swiftly_l10n::format::{self, ArgClass};
use swiftly_l10n::{Arg, Locale, Translator};

const LANGS: [&str; 3] = ["de", "en", "ru"];
const COUNTS: [i64; 19] = [
    0,
    1,
    2,
    3,
    4,
    5,
    11,
    12,
    14,
    21,
    22,
    25,
    100,
    101,
    102,
    111,
    1_000_000,
    1_000_001,
    i64::MAX,
];

fn catalogue() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Sources/Shared/Localizable.xcstrings");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).expect("xcstrings json")
}

/// Known differences between the app catalogue and the core (finding F-l10n-01, `swiftly-l10n/NOTES.md`): the app file holds
/// a plain "%lld Filme" for de/en where the package `.stringsdict` has one/other (the core keeps the plural, "1 Film"
/// instead of "1 Filme"; better for users; the tvOS library shows `String(localized: "\(n) Filme")` from the app catalogue,
/// so the Apple app prints "1 Filme" today). "%lld Staffeln" is plural in both files, no difference. "Normal" in ru exists
/// twice with two genders: the core keeps the app wording and offers the package wording through `Translator::t_package`.
const KNOWN: [(&str, &str); 4] = [
    ("%lld Filme", "de"),
    ("%lld Filme", "en"),
    ("%lld Serien", "de"),
    ("%lld Serien", "en"),
];

/// The catalogue's text of one language: a plain value or the plural variations.
enum Raw {
    Plain(String),
    Plural(BTreeMap<String, String>),
}

fn raw_of(loc: &Value) -> Option<Raw> {
    if let Some(v) = loc["stringUnit"]["value"].as_str() {
        return Some(Raw::Plain(v.to_owned()));
    }
    let plural = loc["variations"]["plural"].as_object()?;
    let forms = plural
        .iter()
        .filter_map(|(k, v)| Some((k.clone(), v["stringUnit"]["value"].as_str()?.to_owned())))
        .collect();
    Some(Raw::Plural(forms))
}

/// Independent CLDR rule for de, en, ru (integers).
fn expected_category(lang: &str, n: i64) -> &'static str {
    let n = n.unsigned_abs();
    match lang {
        "ru" => {
            let (m10, m100) = (n % 10, n % 100);
            if m10 == 1 && m100 != 11 {
                "one"
            } else if (2..=4).contains(&m10) && !(12..=14).contains(&m100) {
                "few"
            } else {
                "many"
            }
        }
        _ => {
            if n == 1 {
                "one"
            } else {
                "other"
            }
        }
    }
}

fn first_text<'a>(forms: &'a BTreeMap<String, String>, want: &str) -> &'a str {
    forms
        .get(want)
        .or_else(|| forms.get("other"))
        .or_else(|| forms.get("one"))
        .or_else(|| forms.values().next())
        .map_or("", String::as_str)
}

#[test]
fn every_key_and_language_equals_the_catalogue() {
    let doc = catalogue();
    let strings = doc["strings"].as_object().expect("strings");
    let core = Catalog::builtin();
    let (mut checked, mut plural_keys, mut known, mut missing) =
        (0_usize, 0_usize, 0_usize, Vec::new());
    for (key, entry) in strings {
        let Some(core_entry) = core.get(key) else {
            missing.push(key.clone());
            continue;
        };
        for lang in LANGS {
            let Some(raw) = raw_of(&entry["localizations"][lang]) else {
                continue;
            };
            let Some(text) = core_entry.text(lang) else {
                panic!("{key:?} [{lang}]: in the catalogue, missing in the core");
            };
            // Where both the app and the package define a key the app value wins (catalog.rs Origin::Both),
            // so the app catalogue is the reference here in every case.
            match (&raw, text) {
                (Raw::Plain(_), Text::Plural(_)) if KNOWN.contains(&(key.as_str(), lang)) => {
                    known += 1
                }
                (Raw::Plain(want), Text::Simple(got)) => assert_eq!(want, got, "{key:?} [{lang}]"),
                (Raw::Plural(want), Text::Plural(got)) => {
                    plural_keys += 1;
                    assert_eq!(
                        want.len(),
                        got.len(),
                        "{key:?} [{lang}] number of plural forms"
                    );
                    for (cat, form) in got.iter() {
                        let name = format!("{cat:?}").to_lowercase();
                        assert_eq!(
                            want.get(&name),
                            Some(&(*form).to_owned()),
                            "{key:?} [{lang}] form {name}"
                        );
                    }
                }
                _ => panic!("{key:?} [{lang}]: plain/plural shape differs from the catalogue"),
            }
            checked += 1;
        }
    }
    assert!(
        missing.is_empty(),
        "keys of the catalogue missing in the core: {missing:?}"
    );
    assert!(checked > 2900, "only {checked} texts compared");
    assert!(plural_keys > 0);
    assert_eq!(
        known,
        KNOWN.len(),
        "the list of known differences must match exactly (no silent growth, no stale entry)"
    );
    println!("l10n sweep: {checked} texts compared, {plural_keys} of them plural");
}

#[test]
fn placeholders_and_plural_forms_agree_between_languages() {
    let doc = catalogue();
    let mut problems = Vec::new();
    for (key, entry) in doc["strings"].as_object().expect("strings") {
        let de = raw_of(&entry["localizations"]["de"]);
        for lang in ["en", "ru"] {
            let (Some(de), Some(other)) = (&de, raw_of(&entry["localizations"][lang])) else {
                continue;
            };
            let signature = |r: &Raw| -> Vec<(usize, ArgClass)> {
                match r {
                    Raw::Plain(t) => format::signature(t),
                    Raw::Plural(f) => format::signature(first_text(f, "other")),
                }
            };
            // Plural variations may repeat the count in the same position; compare the set of classes per position.
            let (a, b) = (signature(de), signature(&other));
            if a != b {
                problems.push(format!("{key:?} [{lang}] placeholders {a:?} against {b:?}"));
            }
            if let Raw::Plural(forms) = &other {
                let needed: &[&str] = if lang == "ru" {
                    &["one", "few", "many", "other"]
                } else {
                    &["one", "other"]
                };
                for n in needed {
                    if !forms.contains_key(*n) {
                        problems.push(format!("{key:?} [{lang}] lacks the plural form {n}"));
                    }
                }
            }
        }
    }
    // The file is the truth the apps show: differences are findings, not test failures to hide. None are expected.
    assert!(
        problems.is_empty(),
        "{} problems, first: {:#?}",
        problems.len(),
        &problems[..problems.len().min(8)]
    );
}

#[test]
fn plural_keys_pick_the_form_the_language_asks_for() {
    let doc = catalogue();
    let mut compared = 0_usize;
    for (key, entry) in doc["strings"].as_object().expect("strings") {
        for lang in LANGS {
            let Some(Raw::Plural(forms)) = raw_of(&entry["localizations"][lang]) else {
                continue;
            };
            let translator = Translator::new(Locale::parse(lang));
            for n in COUNTS {
                let want_form = first_text(&forms, expected_category(lang, n));
                // The count is argument 1; other placeholders get a fixed text.
                let extra: Vec<Arg> = (0..4).map(|i| Arg::Str(format!("x{i}"))).collect();
                let want = format::render(want_form, &[&[Arg::Int(n)][..], &extra[..]].concat());
                let got = translator.plural(key, n, &extra);
                assert_eq!(got, want, "{key:?} [{lang}] n={n}");
                compared += 1;
            }
        }
    }
    assert!(compared > 100, "only {compared} plural lookups compared");
    println!("l10n sweep: {compared} plural lookups");
}

#[test]
fn every_plain_text_renders_with_generated_arguments() {
    let doc = catalogue();
    let core = Catalog::builtin();
    let mut rendered = 0_usize;
    for (key, entry) in doc["strings"].as_object().expect("strings") {
        for lang in LANGS {
            let Some(Raw::Plain(text)) = raw_of(&entry["localizations"][lang]) else {
                continue;
            };
            let signature = format::signature(&text);
            let slots = signature.iter().map(|(p, _)| *p).max().unwrap_or(0);
            let mut args = vec![Arg::Str(String::new()); slots];
            for (position, class) in &signature {
                args[position - 1] = match class {
                    ArgClass::Integer => Arg::Int(-7),
                    ArgClass::Float => Arg::Float(2.5),
                    _ => Arg::Str("Ä ё".into()),
                };
            }
            let out = core.t_args(&Locale::parse(lang), key, &args);
            // No placeholder may survive (a `%%` becomes `%`, so look for a conversion after a percent sign).
            assert!(
                format::placeholders(&out)
                    .iter()
                    .all(|p| p.conversion == '%'),
                "{key:?} [{lang}] left a placeholder: {out:?}"
            );
            // And rendering with too few arguments must not panic.
            let _ = core.t_args(&Locale::parse(lang), key, &[]);
            rendered += 1;
        }
    }
    assert!(rendered > 2500, "only {rendered} texts rendered");
}
