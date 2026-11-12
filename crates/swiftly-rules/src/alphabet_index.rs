//! Port of AlphabetIndex.swift.
//!
//! The letter strip beside an A-Z grid: which letters exist, and where each one starts.
//!
//! # Foundation behaviour
//!
//! * `Character.isLetter` / `isNumber` / `first(where:)` work on grapheme clusters and look at
//!   the first scalar: see [`crate::text`]. Implemented with `unicode-segmentation`.
//! * `uppercased()` is the locale-independent full mapping ("ß" gives "SS"), per scalar.
//! * `decomposedStringWithCanonicalMapping` is NFD (`unicode-normalization`).
//! * `upper == "Ё"` is Swift `String ==`, i.e. canonical equivalence: compared after NFC.
//! * `Calendar.current.shortMonthSymbols` is passed in by the caller (`month_names`).
//!
//! Differences: Unicode data versions of Rust's std / the crates vs. the OS can differ for
//! recently added scripts. Two *different* letters with the same first scalar (a decomposed
//! "E" + accent next to "E") are ordered by first appearance here; Swift's order for such a
//! tie depends on dictionary iteration and is random.

use crate::text::{characters, is_letter, is_number, nfc, nfd_first, uppercased};

/// The list orders of a library (`Sorting` in Library.swift), reduced to what the strip needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sorting {
    /// "By name" (raw value `name`).
    Name,
    /// "Recently added" (`neueste`).
    Latest,
    /// Community rating (`bewertung`).
    Rating,
    /// Premiere year (`erscheinung`).
    Erscheinung,
}

/// The fields of `Item` the strip reads (a plain input struct instead of `Models.swift`'s
/// `Item`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct IndexItem {
    /// Display name.
    pub name: String,
    /// The server's sort name.
    pub sort_name: Option<String>,
    /// ISO 8601 premiere date.
    pub premiere_date: Option<String>,
    /// Production year.
    pub production_year: Option<i64>,
    /// Community rating.
    pub community_rating: Option<f64>,
    /// ISO 8601 date the item was added.
    pub date_created: Option<String>,
}

/// One entry of the strip.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Entry {
    /// The key: what a title is matched against and what a jump asks for.
    pub letter: String,
    /// Position of the first title with this key in the server's list.
    pub first: usize,
    /// What the strip shows: the letter, or "26" for a year, "7" for a rating.
    pub label: String,
    /// A dot before this entry: the next step among years and ratings.
    pub gap: bool,
}

impl Entry {
    /// `Entry.init(letter:first:label:gap:)`; the label defaults to the letter.
    pub fn new(letter: &str, first: usize, label: Option<&str>, gap: bool) -> Self {
        Self {
            letter: letter.to_owned(),
            first,
            label: label.unwrap_or(letter).to_owned(),
            gap,
        }
    }
}

/// The letter strip.
#[derive(Debug, Clone, PartialEq)]
pub struct AlphabetIndex {
    /// In the strip's order. A key appears once, with its first title.
    pub entries: Vec<Entry>,
    /// How many titles the list holds.
    pub count: usize,
    /// The order the list is sorted in.
    pub sorting: Sorting,
    /// "Recently added" by month: every title was added in one year.
    pub monthly: bool,
}

const DASH: &str = "\u{2014}";

impl AlphabetIndex {
    /// How long a tapped entry is held at most (`AlphabetIndex.swift`, `holdSeconds`).
    pub const HOLD_SECONDS: i64 = 5;
    /// How much height a dot takes, as a share of an entry's row.
    pub const GAP_SHARE: f64 = 0.5;

    /// "By name" strip from (name, sort name) of every title in list order.
    /// (`AlphabetIndex.swift:55-65`)
    pub fn from_titles(titles: &[(&str, Option<&str>)]) -> Self {
        let mut first_at: Vec<(String, usize)> = Vec::new();
        for (i, (name, sort_name)) in titles.iter().enumerate() {
            let letter = Self::letter(name, *sort_name);
            if !first_at.iter().any(|(l, _)| *l == letter) {
                first_at.push((letter, i));
            }
        }
        // Stable: ties keep first appearance (Swift: dictionary order, i.e. random).
        first_at.sort_by_key(|(l, _)| Self::order(l));
        Self {
            entries: first_at
                .into_iter()
                .map(|(l, i)| Entry::new(&l, i, None, false))
                .collect(),
            count: titles.len(),
            sorting: Sorting::Name,
            monthly: false,
        }
    }

    /// The strip for any order, from the whole list in the server's order.
    /// `short_month_symbols` is `Calendar.current.shortMonthSymbols` ("Jan", "Feb", ...).
    /// (`AlphabetIndex.swift:79-107`)
    pub fn from_items(items: &[IndexItem], sorting: Sorting, short_month_symbols: &[&str]) -> Self {
        if sorting == Sorting::Name {
            let titles: Vec<(&str, Option<&str>)> = items
                .iter()
                .map(|i| (i.name.as_str(), i.sort_name.as_deref()))
                .collect();
            return Self::from_titles(&titles);
        }
        // "Zuletzt": months instead of years when the years alone are no scale.
        let monthly = sorting == Sorting::Latest && {
            let mut years: Vec<i64> = items
                .iter()
                .filter_map(|i| year_of(i.date_created.as_deref()))
                .collect();
            years.sort_unstable();
            years.dedup();
            years.len() <= 1
        };
        let mut keys: Vec<String> = Vec::new();
        let mut first_at: Vec<(String, usize)> = Vec::new();
        for (i, item) in items.iter().enumerate() {
            let key = Self::key_of(item, sorting, monthly);
            if !first_at.iter().any(|(k, _)| *k == key) {
                first_at.push((key.clone(), i));
                keys.push(key);
            }
        }
        let mut built: Vec<Entry> = Vec::new();
        for key in keys {
            let first = first_at
                .iter()
                .find(|(k, _)| *k == key)
                .map_or(0, |(_, i)| *i);
            let label = label_for(&key, sorting, monthly, short_month_symbols);
            // Years and ratings are a scale: a dot between every two steps.
            let gap = !built.is_empty();
            built.push(Entry {
                letter: key,
                first,
                label,
                gap,
            });
        }
        Self {
            entries: built,
            count: items.len(),
            sorting,
            monthly,
        }
    }

    /// What a title is matched by in this index.
    pub fn key(&self, item: &IndexItem) -> String {
        Self::key_of(item, self.sorting, self.monthly)
    }

    /// The key of a title for an order: the letter, the year ("2025"), the rating ("r7") or
    /// the year added ("2025"); "—" when the title lacks the value.
    /// (`AlphabetIndex.swift:118-136`)
    pub fn key_of(item: &IndexItem, sorting: Sorting, monthly: bool) -> String {
        match sorting {
            Sorting::Name => Self::letter(&item.name, item.sort_name.as_deref()),
            Sorting::Erscheinung => {
                match year_of(item.premiere_date.as_deref()).or(item.production_year) {
                    Some(year) => year.to_string(),
                    None => DASH.to_owned(),
                }
            }
            Sorting::Rating => match item.community_rating {
                // Swift `Int(rating)` truncates toward zero (and would trap for huge
                // values; `as` saturates, and the clamp to 0...10 makes both the same).
                Some(r) if r.is_finite() => format!("r{}", (r as i64).clamp(0, 10)),
                _ => DASH.to_owned(),
            },
            Sorting::Latest => {
                let Some(year) = year_of(item.date_created.as_deref()) else {
                    return DASH.to_owned();
                };
                if monthly && let Some(month) = month_of(item.date_created.as_deref()) {
                    return format!(
                        "{year}{}",
                        if month < 10 {
                            format!("-0{month}")
                        } else {
                            format!("-{month}")
                        }
                    );
                }
                year.to_string()
            }
        }
    }

    /// Fewer than two letters is no index: nothing to jump between.
    pub fn is_useful(&self) -> bool {
        self.entries.len() > 1
    }

    /// The letter of a title. From the sort name while the title is Latin, so "The Adam
    /// Project" stands under "A"; from the title itself when it is written in another script.
    /// (`AlphabetIndex.swift:177-181`)
    pub fn letter(name: &str, sort_name: Option<&str>) -> String {
        let shown = Self::letter_for(name);
        if shown == "#" || is_latin(&shown) {
            return Self::letter_for(sort_name.unwrap_or(name));
        }
        shown
    }

    /// The letter of one string. Digits share "#", and so does a name without letters or
    /// digits; punctuation in front is skipped. Latin letters lose their accents, other
    /// scripts keep theirs, only "Ё" joins "Е". (`AlphabetIndex.swift:192-213`)
    pub fn letter_for(name: &str) -> String {
        let chars = characters(name);
        let Some(first) = chars.iter().find(|c| is_letter(c) || is_number(c)) else {
            return "#".to_owned();
        };
        if !is_letter(first) {
            return "#".to_owned();
        }
        let upper = uppercased(first);
        // Latin accents and Arabic hamza or vowel marks belong to the letter. Note that a
        // *decomposed* "e" + accent uppercases to "E" + accent, which is outside the range
        // and so is returned whole below - the same quirk as in Swift.
        if let Some(scalar) = upper.chars().next() {
            let v = scalar as u32;
            if ((0x00C0..=0x024F).contains(&v) || (0x0600..=0x06FF).contains(&v))
                && let Some(base) = nfd_first(&upper)
            {
                return base.to_string();
            }
        }
        if nfc(&upper) == nfc("\u{0401}") {
            return "\u{0415}".to_owned();
        }
        // "ß" becomes "SS"; the strip wants one character.
        characters(&upper)
            .first()
            .map(|s| (*s).to_owned())
            .unwrap_or_default()
    }

    /// Alphabetical, across scripts: "#", then by code point of the first scalar.
    /// (`AlphabetIndex.swift:222-225`)
    pub fn order(letter: &str) -> u32 {
        if letter == "#" {
            return 0;
        }
        letter.chars().next().map_or(0, |c| c as u32)
    }

    /// Where to scroll for a letter, among the titles loaded so far: the first loaded title
    /// with exactly this letter. `None` means it is not loaded yet.
    pub fn target_for_letter(
        &self,
        letter: &str,
        loaded: &[(&str, Option<&str>)],
    ) -> Option<usize> {
        loaded
            .iter()
            .position(|(n, s)| Self::letter(n, *s) == letter)
    }

    /// The same for any order, by the loaded titles' keys.
    pub fn target_for_key(&self, key: &str, loaded: &[IndexItem]) -> Option<usize> {
        loaded.iter().position(|i| self.key(i) == key)
    }

    /// What the strip shows for a key ("25" for "2025"), for VoiceOver and the like.
    pub fn label_of(&self, key: Option<&str>) -> Option<String> {
        let key = key?;
        Some(
            self.entries
                .iter()
                .find(|e| e.letter == key)
                .map_or_else(|| key.to_owned(), |e| e.label.clone()),
        )
    }

    /// The strip's height in rows: one per entry, half a row per dot.
    pub fn rows(shown: &[Entry]) -> f64 {
        shown.len() as f64 + shown.iter().filter(|e| e.gap).count() as f64 * Self::GAP_SHARE
    }

    /// The entry under a point of the strip, `y` from 0 to `height`. A dot belongs to the
    /// entry after it, the group it opens. (`AlphabetIndex.swift:259-268`)
    pub fn entry_at(y: f64, height: f64, shown: &[Entry]) -> Option<&Entry> {
        if shown.is_empty() || height <= 0.0 {
            return None;
        }
        let row = height / Self::rows(shown);
        let mut bottom = 0.0;
        for entry in shown {
            bottom += (if entry.gap {
                Self::GAP_SHARE * row
            } else {
                0.0
            }) + row;
            if y < bottom {
                return Some(entry);
            }
        }
        shown.last()
    }

    /// The strip when it does not fit: keeps the first and the last letter and spreads the
    /// rest evenly. (`AlphabetIndex.swift:273-286`)
    pub fn condensed(&self, fitting: i64) -> Vec<Entry> {
        if fitting < 2 || Self::rows(&self.entries) <= fitting as f64 {
            return self.entries.clone();
        }
        if self.sorting != Sorting::Name {
            return self.thinned(fitting);
        }
        let last = self.entries.len() - 1;
        let mut picked: Vec<Entry> = Vec::new();
        let mut taken: Vec<usize> = Vec::new();
        for k in 0..fitting {
            // `rounded()` is half away from zero, as `f64::round`.
            let i =
                ((k as f64 * last as f64 / (fitting - 1) as f64).round() as i64).max(0) as usize;
            if !taken.contains(&i) {
                taken.push(i);
                picked.push(self.entries[i].clone());
            }
        }
        picked
    }

    /// A scale thinned from the top down. (`AlphabetIndex.swift:294-308`)
    fn thinned(&self, slots: i64) -> Vec<Entry> {
        let fits = 2.max(((slots as f64 + Self::GAP_SHARE) / (1.0 + Self::GAP_SHARE)) as i64);
        if self.entries.len() as i64 <= fits {
            return self.entries.clone();
        }
        let last = (self.entries.len() - 1) as i64;
        let mut picked: Vec<i64> = Vec::new();
        for k in 0..fits {
            // Squared, so the steps grow towards the end of the list.
            let share = k as f64 / (fits - 1) as f64;
            let mut i = (share * share * last as f64).round() as i64;
            if let Some(before) = picked.last() {
                i = i.max(before + 1);
            }
            // Leave room for the ones still to come, the last entry above all.
            i = i.min(last - (fits - 1 - k));
            picked.push(i);
        }
        picked
            .into_iter()
            .enumerate()
            .map(|(k, i)| {
                let e = self.entries[i.max(0) as usize].clone();
                // The first shown entry stands at the top: no dot above it.
                if k == 0 { Entry { gap: false, ..e } } else { e }
            })
            .collect()
    }
}

fn is_latin(letter: &str) -> bool {
    letter
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_uppercase())
}

/// The year of an ISO 8601 date ("2009-12-31T00:00:00.0000000Z"). `count` and `prefix` are
/// in Characters (grapheme clusters), as in Swift. (`AlphabetIndex.swift:139-142`)
fn year_of(date: Option<&str>) -> Option<i64> {
    let chars = characters(date?);
    if chars.len() < 4 {
        return None;
    }
    let year: i64 = chars[..4].concat().parse().ok()?;
    (year > 0).then_some(year)
}

/// The month (1 to 12) of an ISO 8601 date. (`AlphabetIndex.swift:145-150`)
fn month_of(date: Option<&str>) -> Option<i64> {
    let chars = characters(date?);
    if chars.len() < 7 {
        return None;
    }
    let month: i64 = chars[5..7].concat().parse().ok()?;
    (1..=12).contains(&month).then_some(month)
}

fn two_digits(year: i64) -> String {
    let rest = year % 100;
    if rest < 10 {
        format!("0{rest}")
    } else {
        rest.to_string()
    }
}

fn label_for(key: &str, sorting: Sorting, monthly: bool, month_names: &[&str]) -> String {
    if key == DASH {
        return key.to_owned();
    }
    if monthly && sorting == Sorting::Latest && key.chars().count() == 7 {
        let chars: Vec<char> = key.chars().collect();
        let year = chars[..4].iter().collect::<String>().parse::<i64>().ok();
        let month = chars[5..].iter().collect::<String>().parse::<i64>().ok();
        if let (Some(year), Some(month)) = (year, month) {
            let name = usize::try_from(month - 1)
                .ok()
                .and_then(|i| month_names.get(i))
                .copied()
                .unwrap_or("");
            return format!("{} {}", name.trim_matches('.'), two_digits(year));
        }
    }
    match sorting {
        Sorting::Name => key.to_owned(),
        Sorting::Erscheinung | Sorting::Latest => key
            .parse::<i64>()
            .map_or_else(|_| key.to_owned(), two_digits),
        Sorting::Rating => key.chars().skip(1).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: letters()
    #[test]
    fn letters() {
        let l = AlphabetIndex::letter_for;
        assert_eq!(l("47 ronin"), "#");
        assert_eq!(l("(500) days"), "#");
        assert_eq!(l("adam project"), "A");
        assert_eq!(l("élan"), "E");
        assert_eq!(l("ßtraße"), "S");
        assert_eq!(l("ёлки"), "Е");
        assert_eq!(l("йети"), "Й");
        assert_eq!(l("Ärger"), "A");
        assert_eq!(l("  "), "#");
        // Quotes and brackets in front are skipped.
        assert_eq!(l("«Старый» Новый год"), "С");
        assert_eq!(l("\"Weird\" Al"), "W");
        assert_eq!(l("..."), "#");
    }

    // Swift: titleLetter()
    #[test]
    fn title_letter() {
        let l = AlphabetIndex::letter;
        assert_eq!(l("The Adam Project", Some("adam project")), "A");
        assert_eq!(l("Выживший", Some("vyzhivshii")), "В");
        assert_eq!(l("47 Ронинов", Some("47 roninov")), "#");
        assert_eq!(l("Alvin", None), "A");
    }

    // Swift: entries()
    #[test]
    fn entries() {
        let index = AlphabetIndex::from_titles(&[
            ("2 Guns", Some("2 guns")),
            ("Adam", Some("adam")),
            ("Вышибала", Some("vyshibala")),
            ("Venom", Some("venom")),
            ("Ёлки", Some("iolki")),
            ("Ешь, молись", Some("esh molis")),
            ("За бортом", Some("za bortom")),
            ("Über den Wolken", Some("uber den wolken")),
        ]);
        let letters: Vec<&str> = index.entries.iter().map(|e| e.letter.as_str()).collect();
        assert_eq!(letters, ["#", "A", "U", "V", "В", "Е", "З"]);
        let first = |l: &str| {
            index
                .entries
                .iter()
                .find(|e| e.letter == l)
                .map(|e| e.first)
        };
        assert_eq!(first("В"), Some(2));
        assert_eq!(first("V"), Some(3));
        assert_eq!(first("Е"), Some(4));
        assert_eq!(index.count, 8);
        assert!(index.is_useful());
        assert!(!AlphabetIndex::from_titles(&[("Alpha", None), ("Avatar", None)]).is_useful());
    }

    // Swift: target()
    #[test]
    fn target() {
        let titles: Vec<(&str, Option<&str>)> = vec![
            ("47 Ronin", Some("47 ronin")),
            ("Adam", Some("adam")),
            ("Вышибала", Some("vyshibala")),
            ("Venom", Some("venom")),
            ("Высшая лига", Some("vysshaia liga")),
        ];
        let index = AlphabetIndex::from_titles(&titles);
        assert_eq!(index.target_for_letter("A", &titles), Some(1));
        assert_eq!(index.target_for_letter("В", &titles), Some(2));
        assert_eq!(index.target_for_letter("V", &titles), Some(3));
        assert_eq!(index.target_for_letter("Z", &titles), None);
        // Not loaded yet: load more.
        assert_eq!(index.target_for_letter("V", &titles[..3]), None);
    }

    // Swift: condensed()
    #[test]
    fn condensed() {
        let names: Vec<String> = (0..26u8)
            .map(|i| format!("{}x", (b'a' + i) as char))
            .collect();
        let titles: Vec<(&str, Option<&str>)> = names.iter().map(|n| (n.as_str(), None)).collect();
        let index = AlphabetIndex::from_titles(&titles);
        let five = index.condensed(5);
        assert_eq!(five.len(), 5);
        assert_eq!(five.first().map(|e| e.letter.as_str()), Some("A"));
        assert_eq!(five.last().map(|e| e.letter.as_str()), Some("Z"));
        assert_eq!(index.condensed(40).len(), 26);
    }

    // Extra (not in Swift): the other orders, which Swift has no test for.
    fn item(date: Option<&str>, rating: Option<f64>) -> IndexItem {
        IndexItem {
            name: "X".into(),
            date_created: date.map(str::to_owned),
            community_rating: rating,
            ..Default::default()
        }
    }

    #[test]
    fn year_scale_and_months() {
        let months = [
            "Jan.", "Feb.", "Mär.", "Apr.", "Mai", "Jun.", "Jul.", "Aug.", "Sep.", "Okt.", "Nov.",
            "Dez.",
        ];
        let years = [
            item(Some("2026-03-01T00:00:00Z"), None),
            item(Some("2025-01-01"), None),
            item(None, None),
        ];
        let index = AlphabetIndex::from_items(&years, Sorting::Latest, &months);
        let labels: Vec<&str> = index.entries.iter().map(|e| e.label.as_str()).collect();
        assert_eq!(labels, ["26", "25", "\u{2014}"]);
        assert_eq!(
            index.entries.iter().map(|e| e.gap).collect::<Vec<_>>(),
            [false, true, true]
        );
        assert!(!index.monthly);
        let one_year = [
            item(Some("2026-10-05"), None),
            item(Some("2026-03-05"), None),
        ];
        let monthly = AlphabetIndex::from_items(&one_year, Sorting::Latest, &months);
        assert!(monthly.monthly);
        let keys: Vec<&str> = monthly.entries.iter().map(|e| e.letter.as_str()).collect();
        assert_eq!(keys, ["2026-10", "2026-03"]);
        assert_eq!(monthly.entries[0].label, "Okt 26");
        let rated = [
            item(None, Some(7.9)),
            item(None, Some(12.0)),
            item(None, Some(f64::NAN)),
        ];
        let r = AlphabetIndex::from_items(&rated, Sorting::Rating, &months);
        assert_eq!(
            r.entries
                .iter()
                .map(|e| e.letter.as_str())
                .collect::<Vec<_>>(),
            ["r7", "r10", "\u{2014}"]
        );
        assert_eq!(r.entries[0].label, "7");
    }

    #[test]
    fn strip_geometry() {
        let e = |l: &str, gap| Entry::new(l, 0, None, gap);
        let shown = [e("a", false), e("b", true), e("c", true)];
        assert_eq!(AlphabetIndex::rows(&shown), 4.0);
        assert_eq!(
            AlphabetIndex::entry_at(0.0, 40.0, &shown).map(|x| x.letter.as_str()),
            Some("a")
        );
        assert_eq!(
            AlphabetIndex::entry_at(1000.0, 40.0, &shown).map(|x| x.letter.as_str()),
            Some("c")
        );
        assert!(AlphabetIndex::entry_at(1.0, 0.0, &shown).is_none());
    }
}
