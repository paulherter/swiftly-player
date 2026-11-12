//! Port of NaturalOrder.swift (the pure part; the `JellyfinClient` paging extension is
//! networking and not ported).
//!
//! "By name" in natural order: digits first, then Latin titles, then titles in other
//! scripts, each group in the order a reader expects.
//!
//! # Foundation behaviour and how this port matches it
//!
//! Swift compares the keys with
//! `String.compare(_:options: [.numeric, .caseInsensitive, .widthInsensitive], range: nil, locale:)`
//! (`NaturalOrder.swift:46-49`). That is **not** `localizedStandardCompare`; it is CoreFoundation's
//! locale-aware collation (ICU based) with three options:
//! numeric (digit runs compare as numbers), case-insensitive, width-insensitive. Diacritics
//! stay significant (no `.diacriticInsensitive`).
//!
//! Here that is [`icu_collator`] (ICU4X, CLDR data) with `Strength::Secondary` (case and width
//! variants equal, accents still differ) and numeric ordering on, tailored to the given
//! locale. It reproduces the examples in the Swift tests (`ru`: "Ё" with "Е" before "Ж";
//! `de`: umlauts at their base letter), but it is a different implementation than Apple's:
//!
//! * punctuation / whitespace weighting (ICU default "non-ignorable") and the order of
//!   symbols can differ in rare titles;
//! * leading zeros in numbers ("007" vs "7") are equal in ICU numeric ordering; Apple's
//!   behaviour for exactly-equal numbers is not documented, ties fall back to the server
//!   order (stable sort) here;
//! * the CLDR version differs from the one shipped in the OS.

use std::cmp::Ordering;

use icu_collator::CollatorPreferences;
use icu_collator::options::{CollatorOptions, Strength};
use icu_collator::preferences::CollationNumericOrdering;
use icu_collator::{Collator, CollatorBorrowed};
use icu_locale_core::Locale;

use crate::alphabet_index::AlphabetIndex;
use crate::text::{characters, is_letter, is_number};

/// A title as the rules see it: display name and the server's sort name.
pub type Title<'a> = (&'a str, Option<&'a str>);

/// Collator equal to Swift's `[.numeric, .caseInsensitive, .widthInsensitive]` for a locale.
pub struct NaturalCollator {
    inner: CollatorBorrowed<'static>,
}

/// The collation data for the locale could not be loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollatorError(pub String);

impl std::fmt::Display for CollatorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "collator unavailable: {}", self.0)
    }
}

impl std::error::Error for CollatorError {}

impl NaturalCollator {
    /// `locale` is a BCP 47 or POSIX-style identifier ("ru", "de_DE", "en-US"); an empty or
    /// unparsable identifier gives the root collation. (Swift took `Locale`, default
    /// `.current`; the caller passes the interface language.)
    pub fn new(locale: &str) -> Result<Self, CollatorError> {
        let id = locale.replace('_', "-");
        let parsed: Locale = id.parse().unwrap_or(Locale::UNKNOWN);
        let mut prefs = CollatorPreferences::from(&parsed);
        prefs.numeric_ordering = Some(CollationNumericOrdering::True);
        let mut options = CollatorOptions::default();
        options.strength = Some(Strength::Secondary);
        let inner =
            Collator::try_new(prefs, options).map_err(|e| CollatorError(format!("{e:?}")))?;
        Ok(Self { inner })
    }

    /// Compare two keys.
    pub fn compare(&self, a: &str, b: &str) -> Ordering {
        self.inner.compare(a, b)
    }
}

/// Collator equal to Swift's `String.localizedStandardCompare` (the order of Finder and of the
/// server list) for a locale.
///
/// That is **not** the [`NaturalCollator`] (diacritics are significant there): the first pass
/// ignores case, diacritics and width and reads digit runs as numbers ("Server 2" before
/// "Server 10", "e" = "é" = "E"); names that are equal then are told apart by the full
/// comparison (accent before case, lower case before upper case), and last by the raw UTF-16
/// code units. Verified against Foundation in the oracle domains `server_discovery` and
/// `standard_compare_de|en|ru` (the latter on thousands of pairs with real Swift).
///
/// Leading zeros (measured, not documented): ICU treats "7", "07" and "007" as equal, Apple puts
/// the run with fewer digits first. The order of the tie-breaks is: (1) accents ("e" before
/// "é", wherever they stand in the name); (2) case and the length of ASCII digit runs together,
/// decided at the first name part (letter or digit run) where they differ ("x07" before "X7"
/// because the case differs in front of the zero, but "07x" after "7X" because the zero comes
/// first); (3) everything else (width, other digit scripts, which do not count zeros) by the
/// full comparison and last the raw UTF-16 code units.
pub struct StandardCollator {
    loose: CollatorBorrowed<'static>,
    accents: CollatorBorrowed<'static>,
    full: CollatorBorrowed<'static>,
}

/// The parts of a name for the tie-break: every character, but an ASCII digit run is one part.
fn name_parts(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = s;
    while !rest.is_empty() {
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        if digits > 0 {
            out.push(&rest[..digits]);
            rest = &rest[digits..];
            continue;
        }
        let text = rest.bytes().take_while(|b| !b.is_ascii_digit()).count();
        out.extend(characters(&rest[..text]));
        rest = &rest[text..];
    }
    out
}

fn is_digit_run(part: &str) -> bool {
    !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit())
}

impl StandardCollator {
    /// `locale` as for [`NaturalCollator::new`]; an unparsable identifier gives the root collation.
    pub fn new(locale: &str) -> Result<Self, CollatorError> {
        let id = locale.replace('_', "-");
        let parsed: Locale = id.parse().unwrap_or(Locale::UNKNOWN);
        let build = |strength: Strength| {
            let mut prefs = CollatorPreferences::from(&parsed);
            prefs.numeric_ordering = Some(CollationNumericOrdering::True);
            let mut options = CollatorOptions::default();
            options.strength = Some(strength);
            Collator::try_new(prefs, options).map_err(|e| CollatorError(format!("{e:?}")))
        };
        Ok(Self {
            loose: build(Strength::Primary)?,
            accents: build(Strength::Secondary)?,
            full: build(Strength::Tertiary)?,
        })
    }

    /// Compare two names. `Equal` only for identical strings.
    pub fn compare(&self, a: &str, b: &str) -> Ordering {
        self.loose
            .compare(a, b)
            .then_with(|| self.accents.compare(a, b))
            .then_with(|| self.zeros_and_case(a, b))
            .then_with(|| self.full.compare(a, b))
            .then_with(|| a.encode_utf16().cmp(b.encode_utf16()))
    }

    /// Names equal so far: the first part where case or the length of an ASCII digit run differs
    /// decides (the shorter run first, lower case before upper case).
    fn zeros_and_case(&self, a: &str, b: &str) -> Ordering {
        let (parts_a, parts_b) = (name_parts(a), name_parts(b));
        if parts_a.len() != parts_b.len() {
            return Ordering::Equal;
        }
        for (x, y) in parts_a.into_iter().zip(parts_b) {
            if x == y {
                continue;
            }
            let order = if is_digit_run(x) && is_digit_run(y) {
                x.len().cmp(&y.len())
            } else {
                // Canonically equal but written differently ("e" + U+0301 against "é"): raw order.
                self.full
                    .compare(x, y)
                    .then_with(|| x.encode_utf16().cmp(y.encode_utf16()))
            };
            if order != Ordering::Equal {
                return order;
            }
        }
        Ordering::Equal
    }
}

/// `NaturalOrder` namespace.
pub struct NaturalOrder;

impl NaturalOrder {
    /// Which block a title belongs to: 0 digits and symbols, 1 Latin, 2 other scripts.
    /// (`NaturalOrder.swift:20-25`)
    pub fn group(name: &str, sort_name: Option<&str>) -> i32 {
        let letter = AlphabetIndex::letter(name, sort_name);
        if letter == "#" {
            return 0;
        }
        match letter.chars().next() {
            None => 0,
            Some(c) if c.is_ascii_uppercase() => 1,
            Some(_) => 2,
        }
    }

    /// The string a title is compared by within its block, without the quotes or brackets in
    /// front («Старый» Новый год compares as "Старый» Новый год"). Latin titles use the
    /// sort name, the others the name. (`NaturalOrder.swift:29-33`)
    pub fn key(name: &str, sort_name: Option<&str>) -> String {
        let key = if Self::group(name, sort_name) == 1 {
            sort_name.unwrap_or(name)
        } else {
            name
        };
        let chars = characters(key);
        match chars.iter().position(|c| is_letter(c) || is_number(c)) {
            None => key.to_owned(),
            Some(start) => chars[start..].concat(),
        }
    }

    /// `true` when `a` comes before `b`. Equal names are neither before nor after (a remake:
    /// the server's order decides, kept by a stable sort). (`NaturalOrder.swift:36-52`)
    pub fn before(a: Title<'_>, b: Title<'_>, collator: &NaturalCollator) -> bool {
        let ga = Self::group(a.0, a.1);
        let gb = Self::group(b.0, b.1);
        if ga != gb {
            return ga < gb;
        }
        if ga == 2 {
            let la = AlphabetIndex::order(&AlphabetIndex::letter(a.0, a.1));
            let lb = AlphabetIndex::order(&AlphabetIndex::letter(b.0, b.1));
            if la != lb {
                return la < lb;
            }
        }
        collator.compare(&Self::key(a.0, a.1), &Self::key(b.0, b.1)) == Ordering::Less
    }

    /// The titles in natural order. **Stable**: equal names keep the server's order.
    /// (`NaturalOrder.swift:55-64`; Swift sorts with an offset tie-break, `sort_by` here is
    /// stable and the comparator is the same strict-weak order.)
    ///
    /// Group, letter and key of every title are worked out once (they used to be recomputed
    /// on both sides of every comparison), and one collator call decides a pair.
    pub fn sorted<T, F>(titles: Vec<T>, collator: &NaturalCollator, title: F) -> Vec<T>
    where
        F: for<'a> Fn(&'a T) -> Title<'a>,
    {
        struct Prepared {
            /// Block, then (for other scripts) the first letter's order; see [`NaturalOrder::before`].
            block: (i32, u32),
            key: String,
        }
        let prepared: Vec<Prepared> = titles
            .iter()
            .map(|t| {
                let (name, sort_name) = title(t);
                let group = Self::group(name, sort_name);
                let order = if group == 2 {
                    AlphabetIndex::order(&AlphabetIndex::letter(name, sort_name))
                } else {
                    0
                };
                Prepared {
                    block: (group, order),
                    key: Self::key(name, sort_name),
                }
            })
            .collect();
        let mut order: Vec<usize> = (0..titles.len()).collect();
        order.sort_by(|&i, &j| {
            let (a, b) = (&prepared[i], &prepared[j]);
            a.block
                .cmp(&b.block)
                .then_with(|| collator.compare(&a.key, &b.key))
                .then_with(|| i.cmp(&j))
        });
        let mut slots: Vec<Option<T>> = titles.into_iter().map(Some).collect();
        order.into_iter().filter_map(|i| slots[i].take()).collect()
    }

    /// The straightforward version [`NaturalOrder::sorted`] replaced; the tests hold the fast
    /// one to it.
    #[cfg(test)]
    fn sorted_reference<T, F>(titles: Vec<T>, collator: &NaturalCollator, title: F) -> Vec<T>
    where
        F: for<'a> Fn(&'a T) -> Title<'a>,
    {
        let mut indexed: Vec<(usize, T)> = titles.into_iter().enumerate().collect();
        indexed.sort_by(|(i, l), (j, r)| {
            let a = title(l);
            let b = title(r);
            if Self::before(a, b, collator) {
                Ordering::Less
            } else if Self::before(b, a, collator) {
                Ordering::Greater
            } else {
                i.cmp(j)
            }
        });
        indexed.into_iter().map(|(_, t)| t).collect()
    }

    /// IDs per request when a page is fetched by ID (`JellyfinClient.naturalBatch`,
    /// `NaturalOrder.swift:115`): some 3.3 KB of address.
    pub const NATURAL_BATCH: usize = 100;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn order(titles: &[(&str, Option<&str>)], locale: &str) -> Vec<String> {
        let c = NaturalCollator::new(locale).expect("collator");
        NaturalOrder::sorted(titles.to_vec(), &c, |t| (t.0, t.1))
            .into_iter()
            .map(|t| t.0.to_owned())
            .collect()
    }

    // Swift `localizedStandardCompare`: numbers as numbers, then case and accents only as a tie-break.
    #[test]
    fn standard_compare_reads_numbers_and_ignores_case_and_accents_first() {
        use std::cmp::Ordering::{Equal, Greater, Less};
        for locale in ["de", "en", "ru", ""] {
            let c = StandardCollator::new(locale).expect("collator");
            assert_eq!(c.compare("Server 2", "Server 10"), Less, "{locale}");
            assert_eq!(c.compare("a10", "a2"), Greater, "{locale}");
            assert_eq!(c.compare("é", "f"), Less, "{locale}");
            assert_eq!(c.compare("E", "é"), Less, "{locale}");
            assert_eq!(c.compare("e", "E"), Less, "{locale}");
            assert_eq!(c.compare("é", "E"), Greater, "{locale}");
            assert_eq!(c.compare("same", "same"), Equal, "{locale}");
            assert_eq!(c.compare("e\u{0301}", "\u{e9}"), Less, "{locale}");
        }
    }

    // Measured with real Swift (oracle domains `standard_compare_*`): fewer leading zeros first;
    // an accent beats everything; case and zeros decide at the first part where they differ.
    #[test]
    fn standard_compare_orders_leading_zeros_like_apple() {
        use std::cmp::Ordering::{Greater, Less};
        for locale in ["de", "en", "ru", ""] {
            let c = StandardCollator::new(locale).expect("collator");
            for (a, b) in [
                ("7", "07"),
                ("07", "007"),
                ("7", "007"),
                ("a7", "a07"),
                ("a7b", "a07b"),
                ("a07b", "a7c"),
                ("7 07", "07 7"),
                ("1.7", "1.07"),
                ("0", "00"),
                ("a0b", "a00b"),
                ("1 02", "01 2"),
                ("x07", "X7"),
                ("7X", "07x"),
                ("e7", "é07"),
                ("a07", "ä7"),
                ("a7", "a07 "),
                ("a99", "a099"),
                ("a07a07", "a007a7"),
            ] {
                assert_eq!(c.compare(a, b), Less, "{locale}: {a:?} before {b:?}");
                assert_eq!(c.compare(b, a), Greater, "{locale}: {b:?} after {a:?}");
            }
            // Numbers still win over zeros; names without a tie are not touched.
            assert_eq!(c.compare("a007", "a8"), Less, "{locale}");
            assert_eq!(c.compare("a09", "a10"), Less, "{locale}");
            assert_eq!(
                c.compare("same 007", "same 007"),
                std::cmp::Ordering::Equal,
                "{locale}"
            );
            // Very long runs do not overflow (compared as text, not as numbers).
            let long = "9".repeat(5000);
            assert_eq!(c.compare(&long, &format!("0{long}")), Less, "{locale}");
        }
    }

    // Swift: groups()
    #[test]
    fn groups() {
        let server = [
            ("Выживший", Some("vyzhivshii")),
            ("12 стульев", Some("12 stulev")),
            ("Venom", Some("venom")),
            ("2+1", Some("2+1")),
            ("007: Спектр", Some("007 spektr")),
            ("Adam", Some("adam")),
            ("За бортом", Some("za bortom")),
            ("Zootopia", Some("zootopia")),
            ("8 подруг", Some("8 podrug")),
        ];
        assert_eq!(
            order(&server, "ru_RU"),
            [
                "2+1",
                "007: Спектр",
                "8 подруг",
                "12 стульев",
                "Adam",
                "Venom",
                "Zootopia",
                "Выживший",
                "За бортом"
            ]
        );
    }

    // Swift: quotes()
    #[test]
    fn quotes() {
        assert_eq!(
            order(
                &[
                    ("«Старый» Новый год", Some("staryi novyi god")),
                    ("1+1", Some("1+1")),
                    ("Сказка", Some("skazka")),
                    ("Сталкер", Some("stalker")),
                ],
                "ru_RU"
            ),
            ["1+1", "Сказка", "Сталкер", "«Старый» Новый год"]
        );
    }

    // Swift: article()
    #[test]
    fn article() {
        assert_eq!(
            order(
                &[
                    ("The Batman", Some("batman")),
                    ("The Adam Project", Some("adam project")),
                    ("Alvin", Some("alvin"))
                ],
                "ru_RU"
            ),
            ["The Adam Project", "Alvin", "The Batman"]
        );
    }

    // Swift: cyrillic()
    #[test]
    fn cyrillic() {
        assert_eq!(
            order(
                &[
                    ("Жанна", None),
                    ("Ёлки", None),
                    ("Ешь", None),
                    ("Елена", None)
                ],
                "ru_RU"
            ),
            ["Елена", "Ёлки", "Ешь", "Жанна"]
        );
    }

    // Swift: scripts()
    #[test]
    fn scripts() {
        let titles = [
            ("Ёлки", Some("iolki")),
            ("Über den Wolken", Some("uber den wolken")),
            ("Alien", Some("alien")),
            ("Ärger im Paradies", Some("arger im paradies")),
            ("Батман", Some("batman")),
            ("Up", Some("up")),
        ];
        assert_eq!(
            order(&titles, "de_DE"),
            [
                "Alien",
                "Ärger im Paradies",
                "Über den Wolken",
                "Up",
                "Батман",
                "Ёлки"
            ]
        );
        // The strip has the same order and the same letters.
        let index = AlphabetIndex::from_titles(&titles);
        let letters: Vec<&str> = index.entries.iter().map(|e| e.letter.as_str()).collect();
        assert_eq!(letters, ["A", "U", "Б", "Е"]);
    }

    // Swift: stable()
    #[test]
    fn stable() {
        let titles = [
            ("Dune", Some("dune"), 1),
            ("Dune", Some("dune"), 2),
            ("Alien", Some("alien"), 3),
        ];
        let c = NaturalCollator::new("").expect("collator");
        let sorted = NaturalOrder::sorted(titles.to_vec(), &c, |t| (t.0, t.1));
        assert_eq!(sorted.iter().map(|t| t.2).collect::<Vec<_>>(), [3, 1, 2]);
    }

    // Extra (not in Swift): case and width are ignored, accents are not.
    #[test]
    fn options_match_foundation_flags() {
        let c = NaturalCollator::new("en").expect("collator");
        assert_eq!(c.compare("abc", "ABC"), Ordering::Equal);
        assert_eq!(c.compare("ａbc", "abc"), Ordering::Equal);
        assert_eq!(c.compare("e", "é"), Ordering::Less);
        assert_eq!(c.compare("a2", "a10"), Ordering::Less);
    }

    // The decorated sort gives exactly what the plain comparator sort gave, on many random
    // mixes of digits, accents, other scripts, symbols and duplicates.
    #[test]
    fn sorted_equals_reference_on_random_titles() {
        let words = [
            "the",
            "Alpha",
            "élan",
            "Zoë",
            "10",
            "2",
            "007",
            "Старый",
            "Ёлки",
            "йети",
            "«Новый»",
            "(500)",
            "...",
            "ＡＢＣ",
            "abc",
            "Ärger",
            "ß",
            "日本",
            "한국",
            "Film",
            " ",
            "x",
        ];
        let mut seed = 0x9E37_79B9_7F4A_7C15_u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for locale in ["de", "ru", "en", ""] {
            let c = NaturalCollator::new(locale).expect("collator");
            for round in 0..40 {
                let n = 1 + (round * 7) % 120;
                let titles: Vec<(String, Option<String>)> = (0..n)
                    .map(|_| {
                        let parts = 1 + next() % 4;
                        let name: Vec<&str> = (0..parts)
                            .map(|_| words[(next() % words.len() as u64) as usize])
                            .collect();
                        let name = name.join(" ");
                        let sort = (next() % 3 == 0).then(|| name.to_lowercase());
                        (name, sort)
                    })
                    .collect();
                let fast = NaturalOrder::sorted(titles.clone(), &c, as_title);
                let slow = NaturalOrder::sorted_reference(titles, &c, as_title);
                assert_eq!(fast, slow, "locale {locale:?} round {round}");
            }
        }
    }

    fn as_title(t: &(String, Option<String>)) -> Title<'_> {
        (t.0.as_str(), t.1.as_deref())
    }
}
