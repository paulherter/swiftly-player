//! CLDR plural categories and the rules of the languages Swiftly ships or may ship.
//!
//! Only whole numbers are needed for counts in the UI, so the rules are the integer
//! forms of the CLDR 44 plural rules (`v = 0`). A language without a rule here gets
//! the single category `other`, which is also correct for ja, zh, ko, vi, th and id.

/// One of the six CLDR plural categories.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PluralCategory {
    /// Zero (Arabic, Latvian).
    Zero,
    /// One (singular).
    One,
    /// Two (dual: Arabic, Hebrew, Slovenian).
    Two,
    /// Few (Slavic 2-4, Arabic 3-10).
    Few,
    /// Many (Russian 5-20, Polish, Arabic 11-99, millions in romance languages).
    Many,
    /// Everything else; every language has it.
    Other,
}

impl PluralCategory {
    /// The CLDR name, as used in `.xcstrings` and `.stringsdict`.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Zero => "zero",
            Self::One => "one",
            Self::Two => "two",
            Self::Few => "few",
            Self::Many => "many",
            Self::Other => "other",
        }
    }

    /// Parses a CLDR name; `None` for anything else.
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "zero" => Self::Zero,
            "one" => Self::One,
            "two" => Self::Two,
            "few" => Self::Few,
            "many" => Self::Many,
            "other" => Self::Other,
            _ => return None,
        })
    }
}

/// The plural rule family of a language.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Rule {
    /// Only `other` (ja, zh, ko, vi, th, id, ms).
    Single,
    /// `one` for 1 (en, de, nl, sv, tr ...).
    OneIsOne,
    /// `one` for 0 and 1 (fr, pt, hi).
    ZeroOneIsOne,
    /// `one` for 1, `many` for whole millions (es, it, ca).
    RomanceMillions,
    /// Like `ZeroOneIsOne` plus `many` for whole millions (fr, pt).
    FrenchMillions,
    /// ru, uk, be.
    EastSlavic,
    /// pl.
    Polish,
    /// cs, sk.
    CzechSlovak,
    /// hr, sr, bs.
    SouthSlavic,
    /// sl.
    Slovenian,
    /// lt.
    Lithuanian,
    /// lv.
    Latvian,
    /// ro.
    Romanian,
    /// ar.
    Arabic,
    /// he.
    Hebrew,
}

fn rule_for(tag: &str) -> Rule {
    let lower = tag.to_ascii_lowercase().replace('_', "-");
    if lower == "pt-pt" {
        return Rule::RomanceMillions; // European Portuguese: one is only 1.
    }
    let lang = lower.split('-').next().unwrap_or("");
    match lang {
        "ja" | "zh" | "ko" | "vi" | "th" | "id" | "ms" | "lo" | "my" | "km" | "yue" => Rule::Single,
        "fr" | "pt" => Rule::FrenchMillions,
        "hi" | "bn" | "fa" | "am" | "gu" | "kn" | "zu" => Rule::ZeroOneIsOne,
        "es" | "it" | "ca" => Rule::RomanceMillions,
        // Swift reads the first two letters, so the three-letter codes of the same languages count too.
        "ru" | "uk" | "be" | "rus" | "ukr" | "bel" => Rule::EastSlavic,
        "pl" => Rule::Polish,
        "cs" | "sk" => Rule::CzechSlovak,
        "hr" | "sr" | "bs" => Rule::SouthSlavic,
        "sl" => Rule::Slovenian,
        "lt" => Rule::Lithuanian,
        "lv" => Rule::Latvian,
        "ro" | "mo" => Rule::Romanian,
        "ar" => Rule::Arabic,
        "he" | "iw" => Rule::Hebrew,
        "" => Rule::Single,
        // en, de, nl, sv, da, nb, nn, no, fi, et, el, hu, bg, tr, az, eu, gl, sq, ur, ta, te, sw, af ...
        _ => Rule::OneIsOne,
    }
}

/// The plural category of the whole number `n` (sign ignored) in the language `tag`
/// (`"ru"`, `"pt-PT"`, `"de_DE"` all work).
pub fn category(tag: &str, n: i64) -> PluralCategory {
    use PluralCategory::{Few, Many, One, Other, Two, Zero};
    let n = n.unsigned_abs();
    let (m10, m100, m1m) = (n % 10, n % 100, n % 1_000_000);
    match rule_for(tag) {
        Rule::Single => Other,
        Rule::OneIsOne => {
            if n == 1 {
                One
            } else {
                Other
            }
        }
        Rule::ZeroOneIsOne => {
            if n <= 1 {
                One
            } else {
                Other
            }
        }
        Rule::RomanceMillions => {
            if n == 1 {
                One
            } else if n != 0 && m1m == 0 {
                Many
            } else {
                Other
            }
        }
        Rule::FrenchMillions => {
            if n <= 1 {
                One
            } else if n != 0 && m1m == 0 {
                Many
            } else {
                Other
            }
        }
        Rule::EastSlavic => {
            if m10 == 1 && m100 != 11 {
                One
            } else if (2..=4).contains(&m10) && !(12..=14).contains(&m100) {
                Few
            } else {
                Many
            }
        }
        Rule::Polish => {
            if n == 1 {
                One
            } else if (2..=4).contains(&m10) && !(12..=14).contains(&m100) {
                Few
            } else {
                Many
            }
        }
        Rule::CzechSlovak => match n {
            1 => One,
            2..=4 => Few,
            _ => Other,
        },
        Rule::SouthSlavic => {
            if m10 == 1 && m100 != 11 {
                One
            } else if (2..=4).contains(&m10) && !(12..=14).contains(&m100) {
                Few
            } else {
                Other
            }
        }
        Rule::Slovenian => match m100 {
            1 => One,
            2 => Two,
            3 | 4 => Few,
            _ => Other,
        },
        Rule::Lithuanian => {
            if m10 == 1 && !(11..=19).contains(&m100) {
                One
            } else if (2..=9).contains(&m10) && !(11..=19).contains(&m100) {
                Few
            } else {
                Other
            }
        }
        Rule::Latvian => {
            if m10 == 0 || (11..=19).contains(&m100) {
                Zero
            } else if m10 == 1 && m100 != 11 {
                One
            } else {
                Other
            }
        }
        Rule::Romanian => {
            if n == 1 {
                One
            } else if n == 0 || (2..=19).contains(&m100) {
                Few
            } else {
                Other
            }
        }
        Rule::Arabic => {
            if n == 0 {
                Zero
            } else if n == 1 {
                One
            } else if n == 2 {
                Two
            } else if (3..=10).contains(&m100) {
                Few
            } else if (11..=99).contains(&m100) {
                Many
            } else {
                Other
            }
        }
        Rule::Hebrew => match n {
            1 => One,
            2 => Two,
            _ => Other,
        },
    }
}

/// The categories a translator has to provide for whole numbers in the language `tag`,
/// in CLDR order. Used by the catalogue check.
pub fn categories(tag: &str) -> &'static [PluralCategory] {
    use PluralCategory::{Few, Many, One, Other, Two, Zero};
    match rule_for(tag) {
        Rule::Single => &[Other],
        Rule::OneIsOne | Rule::ZeroOneIsOne => &[One, Other],
        Rule::RomanceMillions | Rule::FrenchMillions => &[One, Many, Other],
        Rule::EastSlavic | Rule::Polish => &[One, Few, Many, Other],
        Rule::CzechSlovak | Rule::SouthSlavic | Rule::Lithuanian | Rule::Romanian => {
            &[One, Few, Other]
        }
        Rule::Slovenian => &[One, Two, Few, Other],
        Rule::Latvian => &[Zero, One, Other],
        Rule::Arabic => &[Zero, One, Two, Few, Many, Other],
        Rule::Hebrew => &[One, Two, Other],
    }
}
