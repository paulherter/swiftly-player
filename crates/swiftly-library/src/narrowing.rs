//! What narrows a library list besides the status filter (`LibraryFilter`): a span of production
//! years and an audio language. Plus the one sheet model every platform renders (rows, selection,
//! group titles), so no UI decides what the filter sheet contains.
//!
//! Years go to the server (`Years=`). Jellyfin has no audio-language filter, so the language is
//! sifted here: [`LanguageIndex`] is built once from a scan of the audio tracks (`MediaSources`)
//! and says which titles have a language; a series has it when one of its episodes has it.

use std::collections::{BTreeSet, HashMap, HashSet};

use swiftly_model::Item;

use crate::library_filter::LibraryFilter;
use crate::store::KeyValue;

/// A span of production years, both ends included.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct YearSpan {
    /// First year.
    pub from: i32,
    /// Last year.
    pub to: i32,
}

impl YearSpan {
    /// The decade a year lies in: 2014 gives 2010 to 2019.
    pub fn decade(year: i32) -> Self {
        let from = year.div_euclid(10) * 10;
        Self { from, to: from + 9 }
    }
    /// Whether the year lies inside.
    pub fn contains(self, year: i64) -> bool {
        year >= i64::from(self.from) && year <= i64::from(self.to)
    }
    /// The stored form, `2010-2019`.
    pub fn raw_value(self) -> String {
        format!("{}-{}", self.from, self.to)
    }
    /// Reads the stored form; a span that runs backwards or is not numbers is nothing.
    pub fn from_raw(raw: &str) -> Option<Self> {
        let (a, b) = raw.split_once('-')?;
        let (from, to) = (a.parse::<i32>().ok()?, b.parse::<i32>().ok()?);
        (from <= to).then_some(Self { from, to })
    }
    /// Every year of the span, for the server's `Years=`.
    pub fn years(self) -> Vec<i32> {
        (self.from..=self.to).collect()
    }
    /// What a row shows: `2010–2019` (no words, so nothing to translate).
    pub fn label(self) -> String {
        format!("{}\u{2013}{}", self.from, self.to)
    }
}

/// The year span and language a list is narrowed to. `Default` narrows nothing.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct Narrowing {
    /// Only titles produced in these years.
    pub years: Option<YearSpan>,
    /// Only titles with an audio track in this language (three-letter code, see [`normalize_language`]).
    pub language: Option<String>,
}

impl Narrowing {
    /// Nothing narrowed.
    pub fn is_none(&self) -> bool {
        self.years.is_none() && self.language.is_none()
    }
    /// Part of the key a list is remembered under: empty when nothing is narrowed, so the keys of
    /// plain lists stay what they were.
    pub fn id(&self) -> String {
        let mut id = String::new();
        if let Some(y) = self.years {
            id.push_str(&format!("|j{}", y.raw_value()));
        }
        if let Some(l) = &self.language {
            id.push_str(&format!("|s{l}"));
        }
        id
    }
    /// The inverse of [`Narrowing::id`] (`"|j2010-2019|sdeu"`); anything unreadable narrows nothing.
    pub fn from_id(id: &str) -> Self {
        let mut narrowing = Self::default();
        for part in id.split('|') {
            if let Some(raw) = part.strip_prefix('j') {
                narrowing.years = YearSpan::from_raw(raw);
            } else if let Some(code) = part.strip_prefix('s') {
                narrowing.language = normalize_language(code);
            }
        }
        narrowing
    }
    /// Reads what a place remembered (`jahre.<name>`, `sprache.<name>`).
    pub fn read(name: &str, store: &dyn KeyValue) -> Self {
        Self {
            years: store
                .get(&format!("jahre.{name}"))
                .and_then(|r| YearSpan::from_raw(&r)),
            language: store
                .get(&format!("sprache.{name}"))
                .and_then(|r| normalize_language(&r)),
        }
    }
    /// Remembers it per place; nothing narrowed is stored as an empty text.
    pub fn write(&self, name: &str, store: &dyn KeyValue) {
        store.set(
            &format!("jahre.{name}"),
            &self.years.map(YearSpan::raw_value).unwrap_or_default(),
        );
        store.set(
            &format!("sprache.{name}"),
            self.language.as_deref().unwrap_or(""),
        );
    }
    /// Whether the title stays: its year inside the span (a title without a year does not), its
    /// id among those with the language.
    pub fn keeps(&self, item: &Item, languages: Option<&LanguageIndex>) -> bool {
        if let Some(span) = self.years
            && !item.production_year.is_some_and(|y| span.contains(y))
        {
            return false;
        }
        match (&self.language, languages) {
            (Some(code), Some(index)) => index.has(code, &item.id),
            (Some(_), None) => false,
            (None, _) => true,
        }
    }
}

/// The status filter and the narrowing as one value: what a fetch of the list is asked for.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ListFilter {
    /// All, started, watchlist, unwatched.
    pub status: LibraryFilter,
    /// Years and language.
    pub narrowing: Narrowing,
}

impl ListFilter {
    /// Both together.
    pub fn new(status: LibraryFilter, narrowing: Narrowing) -> Self {
        Self { status, narrowing }
    }
    /// The status filter alone.
    pub fn status_only(status: LibraryFilter) -> Self {
        Self::new(status, Narrowing::default())
    }
    /// Names the list for caches and keys; a plain status filter reads as its stored value.
    pub fn raw_value(&self) -> String {
        format!("{}{}", self.status.raw_value(), self.narrowing.id())
    }
    /// The inverse of [`ListFilter::raw_value`]; a plain status value (`"alle"`) is a filter without narrowing.
    pub fn from_raw(raw: &str) -> Self {
        let (status, rest) = raw.split_once('|').unwrap_or((raw, ""));
        let narrowing = if rest.is_empty() {
            Narrowing::default()
        } else {
            Narrowing::from_id(&format!("|{rest}"))
        };
        Self::new(
            LibraryFilter::from_raw(status).unwrap_or(LibraryFilter::All),
            narrowing,
        )
    }
    /// This filter after one row of the sheet was picked: the status row replaces the status, the years and
    /// language rows replace their part. For hosts that keep the filter as one value (the Android list page);
    /// the view model maps the same picks to its intents (`LibraryVm::pick`).
    pub fn picked(&self, choice: &FilterChoice) -> Self {
        let mut next = self.clone();
        match choice {
            FilterChoice::Status(status) => next.status = *status,
            FilterChoice::Years(years) => next.narrowing.years = *years,
            FilterChoice::Language(language) => next.narrowing.language.clone_from(language),
        }
        next
    }
    /// The `Filters` values (see [`LibraryFilter::jellyfin_filter`]).
    pub fn jellyfin_filter(&self) -> Vec<String> {
        self.status.jellyfin_filter()
    }
    /// See [`LibraryFilter::is_watched`].
    pub fn is_watched(&self) -> Option<bool> {
        self.status.is_watched()
    }
    /// The years for the server's `Years=`, empty when not narrowed.
    pub fn years(&self) -> Vec<i32> {
        self.narrowing
            .years
            .map(YearSpan::years)
            .unwrap_or_default()
    }
}

/// The three-letter code of a language as the server writes it, so `ger` and `deu` are one
/// language. Empty and undetermined codes are no language.
pub fn normalize_language(code: &str) -> Option<String> {
    let c = code.trim().to_ascii_lowercase();
    if c.len() < 2 || c == "und" || c == "mis" || c == "mul" || c == "zxx" {
        return None;
    }
    let t = match c.as_str() {
        "ger" => "deu",
        "fre" => "fra",
        "dut" => "nld",
        "chi" => "zho",
        "cze" => "ces",
        "gre" => "ell",
        "ice" => "isl",
        "per" => "fas",
        "rum" => "ron",
        "slo" => "slk",
        "may" => "msa",
        "baq" => "eus",
        "wel" => "cym",
        "alb" => "sqi",
        "arm" => "hye",
        "geo" => "kat",
        "mac" => "mkd",
        "bur" => "mya",
        other => other,
    };
    Some(t.to_owned())
}

/// Which titles of a library have which audio language, from one scan of the tracks.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LanguageIndex {
    by_code: HashMap<String, HashSet<String>>,
}

impl LanguageIndex {
    /// Adds what the scanned items say: a film for itself, an episode for its series.
    pub fn add(&mut self, items: &[Item]) {
        for item in items {
            let id = if item.type_.as_deref() == Some("Episode") {
                match &item.series_id {
                    Some(s) => s,
                    None => continue,
                }
            } else {
                &item.id
            };
            let streams = item
                .media_sources
                .iter()
                .flatten()
                .flat_map(|s| s.media_streams.iter().flatten());
            for stream in streams {
                if stream.type_.as_deref() != Some("Audio") {
                    continue;
                }
                if let Some(code) = stream.language.as_deref().and_then(normalize_language) {
                    self.by_code.entry(code).or_default().insert(id.clone());
                }
            }
        }
    }
    /// The index of one scan.
    pub fn from_scan(items: &[Item]) -> Self {
        let mut index = Self::default();
        index.add(items);
        index
    }
    /// Whether the title has an audio track in the language.
    pub fn has(&self, code: &str, id: &str) -> bool {
        self.by_code.get(code).is_some_and(|ids| ids.contains(id))
    }
    /// The languages found with how many titles have each, most titles first.
    pub fn languages(&self) -> Vec<(String, u64)> {
        let mut all: Vec<(String, u64)> = self
            .by_code
            .iter()
            .map(|(c, ids)| (c.clone(), u64::try_from(ids.len()).unwrap_or(u64::MAX)))
            .collect();
        all.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        all
    }
}

/// What the server can offer to pick from: one part of the sheet. Explicit states, so the sheet
/// never shows a group that is neither loading nor ready.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Facet<T> {
    /// This server or list cannot filter by it (Plex, a collection): no group.
    #[default]
    Off,
    /// Not asked yet or on its way: the group shows that it is loading.
    Loading,
    /// The server could not say: no group (the list stays usable without it).
    Failed,
    /// What there is to pick from; empty means no group.
    Ready(Vec<T>),
}

/// The choices behind the year and language groups.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FilterFacets {
    /// The production years that exist in the list.
    pub years: Facet<i32>,
    /// The audio languages that exist in the list, with their title counts.
    pub languages: Facet<(String, u64)>,
}

/// Which group of the sheet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FilterGroupKind {
    /// Everything, started, watchlist, unwatched.
    Status,
    /// Decades of production years.
    Years,
    /// Audio languages.
    Language,
}

/// What picking a row does.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FilterChoice {
    /// Sets the status filter.
    Status(LibraryFilter),
    /// Sets the year span, `None` is "all years".
    Years(Option<YearSpan>),
    /// Sets the language, `None` is "all languages".
    Language(Option<String>),
}

/// One row of the sheet, ready to draw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilterRow {
    /// What picking it does.
    pub choice: FilterChoice,
    /// The text, in the interface language.
    pub label: String,
    /// It is the current pick of its group.
    pub selected: bool,
    /// How many titles it covers, where the server said.
    pub count: Option<u64>,
}

/// A group of rows with its heading.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilterGroup {
    /// Which group.
    pub kind: FilterGroupKind,
    /// The heading (empty for the first group: the sheet's own title is enough).
    pub title: String,
    /// The rows; empty while `loading`.
    pub rows: Vec<FilterRow>,
    /// The choices are on their way.
    pub loading: bool,
}

/// The whole filter sheet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilterSheet {
    /// The sheet's title.
    pub title: String,
    /// The groups in order: status, years, language.
    pub groups: Vec<FilterGroup>,
    /// What the filter pill shows for the current picks ([`pill_text`]).
    pub pill: String,
}

/// One line of the sheet drawn as a single list: the rows of every group in order, the group's
/// heading on its first line. A group that is still loading is one line without a choice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SheetLine {
    /// What picking it does; `None` for the "loading" line.
    pub choice: Option<FilterChoice>,
    /// The text, in the interface language.
    pub label: String,
    /// It is the current pick of its group.
    pub selected: bool,
    /// How many titles it covers, where the server said.
    pub count: Option<u64>,
    /// The heading of the group this line opens (never on the first group).
    pub heading: Option<String>,
}

/// The text of the "choices are on their way" line.
pub const LOADING_LABEL: &str = "\u{2026}";

/// The catalog keys of the sheet (German wording, the platform's catalog translates them).
pub mod words {
    /// Title of the sheet.
    pub const TITLE: &str = "Filtern";
    /// Heading of the year group.
    pub const YEARS: &str = "Erscheinungsjahr";
    /// Heading of the language group.
    pub const LANGUAGE: &str = "Sprache";
    /// The year row that narrows nothing.
    pub const ALL_YEARS: &str = "Alle Jahre";
    /// The language row that narrows nothing.
    pub const ALL_LANGUAGES: &str = "Alle Sprachen";
}

/// What the filter pill shows: the status, plus the year span and the language when the list is
/// narrowed ("Ungesehen · 2010–2019 · Deutsch"). Needs no facets, so it is right before the sheet
/// has ever been opened.
pub fn pill_text(
    status: LibraryFilter,
    narrowing: &Narrowing,
    say: &dyn Fn(&str) -> String,
    language_name: &dyn Fn(&str) -> Option<String>,
) -> String {
    let mut parts = vec![say(status_key(status))];
    if let Some(span) = narrowing.years {
        parts.push(span.label());
    }
    if let Some(code) = &narrowing.language {
        parts.push(language_label(code, language_name));
    }
    parts.join(" \u{b7} ")
}

fn language_label(code: &str, language_name: &dyn Fn(&str) -> Option<String>) -> String {
    language_name(code).unwrap_or_else(|| code.to_ascii_uppercase())
}

impl FilterSheet {
    /// The rows of all groups as one list, ready for a platform's list or sheet: no logic is left
    /// to the UI, it draws the lines and hands `choice` back on a tap.
    pub fn flat_rows(&self) -> Vec<SheetLine> {
        let mut lines = Vec::new();
        for group in &self.groups {
            let mut heading = (!group.title.is_empty()).then(|| group.title.clone());
            for row in &group.rows {
                lines.push(SheetLine {
                    choice: Some(row.choice.clone()),
                    label: row.label.clone(),
                    selected: row.selected,
                    count: row.count,
                    heading: heading.take(),
                });
            }
            if group.loading {
                lines.push(SheetLine {
                    choice: None,
                    label: LOADING_LABEL.to_owned(),
                    selected: false,
                    count: None,
                    heading: Some(group.title.clone()),
                });
            }
        }
        lines
    }

    /// Builds the sheet. `offered` are the status filters the page offers, `say` translates a
    /// catalog key, `language_name` names a language code in the interface language.
    pub fn build(
        offered: &[LibraryFilter],
        status: LibraryFilter,
        narrowing: &Narrowing,
        facets: &FilterFacets,
        say: &dyn Fn(&str) -> String,
        language_name: &dyn Fn(&str) -> Option<String>,
    ) -> Self {
        let mut groups = vec![FilterGroup {
            kind: FilterGroupKind::Status,
            title: String::new(),
            rows: offered
                .iter()
                .map(|f| FilterRow {
                    choice: FilterChoice::Status(*f),
                    label: say(status_key(*f)),
                    selected: *f == status,
                    count: None,
                })
                .collect(),
            loading: false,
        }];
        match &facets.years {
            Facet::Loading => groups.push(loading_group(FilterGroupKind::Years, say(words::YEARS))),
            Facet::Ready(years) if !years.is_empty() => {
                let decades: BTreeSet<i32> =
                    years.iter().map(|y| YearSpan::decade(*y).from).collect();
                let mut rows = vec![FilterRow {
                    choice: FilterChoice::Years(None),
                    label: say(words::ALL_YEARS),
                    selected: narrowing.years.is_none(),
                    count: None,
                }];
                rows.extend(decades.iter().rev().map(|d| {
                    let span = YearSpan::decade(*d);
                    FilterRow {
                        choice: FilterChoice::Years(Some(span)),
                        label: span.label(),
                        selected: narrowing.years == Some(span),
                        count: None,
                    }
                }));
                groups.push(FilterGroup {
                    kind: FilterGroupKind::Years,
                    title: say(words::YEARS),
                    rows,
                    loading: false,
                });
            }
            _ => {}
        }
        match &facets.languages {
            Facet::Loading => groups.push(loading_group(
                FilterGroupKind::Language,
                say(words::LANGUAGE),
            )),
            Facet::Ready(languages) if !languages.is_empty() => {
                let mut rows = vec![FilterRow {
                    choice: FilterChoice::Language(None),
                    label: say(words::ALL_LANGUAGES),
                    selected: narrowing.language.is_none(),
                    count: None,
                }];
                rows.extend(languages.iter().map(|(code, n)| FilterRow {
                    choice: FilterChoice::Language(Some(code.clone())),
                    label: language_label(code, language_name),
                    selected: narrowing.language.as_deref() == Some(code.as_str()),
                    count: Some(*n),
                }));
                groups.push(FilterGroup {
                    kind: FilterGroupKind::Language,
                    title: say(words::LANGUAGE),
                    rows,
                    loading: false,
                });
            }
            _ => {}
        }
        Self {
            title: say(words::TITLE),
            groups,
            pill: pill_text(status, narrowing, say, language_name),
        }
    }
}

fn loading_group(kind: FilterGroupKind, title: String) -> FilterGroup {
    FilterGroup {
        kind,
        title,
        rows: Vec::new(),
        loading: true,
    }
}

/// The catalog key of a status filter's label (the same wording as `LibraryFilter.label`).
pub fn status_key(filter: LibraryFilter) -> &'static str {
    match filter {
        LibraryFilter::All => "Alle",
        LibraryFilter::Begun => "Angefangen",
        LibraryFilter::Watchlist => "Merkliste",
        LibraryFilter::Unwatched => "Ungesehen",
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use swiftly_model::{Item, MediaSource, MediaStream};

    use super::*;

    #[derive(Default)]
    struct Mem(Mutex<HashMap<String, String>>);
    impl KeyValue for Mem {
        fn get(&self, key: &str) -> Option<String> {
            self.0.lock().unwrap().get(key).cloned()
        }
        fn set(&self, key: &str, value: &str) {
            self.0.lock().unwrap().insert(key.into(), value.into());
        }
    }

    fn titled(id: &str, kind: &str, year: Option<i64>, langs: &[&str]) -> Item {
        let streams = langs
            .iter()
            .map(|l| MediaStream {
                type_: Some("Audio".into()),
                language: Some((*l).into()),
                ..MediaStream::default()
            })
            .collect();
        Item {
            production_year: year,
            media_sources: Some(vec![MediaSource {
                media_streams: Some(streams),
                ..MediaSource::default()
            }]),
            ..Item::new(id, id, Some(kind))
        }
    }

    #[test]
    fn year_span_round_trips_and_covers_a_decade() {
        let d = YearSpan::decade(2014);
        assert_eq!((d.from, d.to), (2010, 2019));
        assert_eq!(YearSpan::from_raw(&d.raw_value()), Some(d));
        assert_eq!(YearSpan::from_raw("2019-2010"), None);
        assert_eq!(YearSpan::from_raw("x"), None);
        assert_eq!(d.years().len(), 10);
        assert!(d.contains(2010) && d.contains(2019) && !d.contains(2020));
        assert_eq!(d.label(), "2010\u{2013}2019");
        assert_eq!(YearSpan::decade(1999).from, 1990);
    }

    #[test]
    fn narrowing_is_remembered_per_place_and_plain_keeps_its_key() {
        let kv = Mem::default();
        assert!(Narrowing::read("movies", &kv).is_none());
        let n = Narrowing {
            years: Some(YearSpan::decade(2015)),
            language: Some("deu".into()),
        };
        n.write("movies", &kv);
        assert_eq!(kv.get("jahre.movies").as_deref(), Some("2010-2019"));
        assert_eq!(kv.get("sprache.movies").as_deref(), Some("deu"));
        assert_eq!(Narrowing::read("movies", &kv), n);
        // Another place is untouched.
        assert!(Narrowing::read("series", &kv).is_none());
        // Clearing stores empty texts, which read back as nothing.
        Narrowing::default().write("movies", &kv);
        assert!(Narrowing::read("movies", &kv).is_none());
        assert_eq!(Narrowing::default().id(), "");
        assert_eq!(n.id(), "|j2010-2019|sdeu");
    }

    #[test]
    fn german_and_ger_are_one_language() {
        assert_eq!(normalize_language("ger").as_deref(), Some("deu"));
        assert_eq!(normalize_language("DEU").as_deref(), Some("deu"));
        assert_eq!(normalize_language("und"), None);
        assert_eq!(normalize_language(""), None);
    }

    #[test]
    fn index_counts_films_and_folds_episodes_into_their_series() {
        let mut episode = titled("e1", "Episode", Some(2021), &["deu"]);
        episode.series_id = Some("s1".into());
        let items = [
            titled("m1", "Movie", Some(2012), &["ger", "eng"]),
            titled("m2", "Movie", Some(2005), &["eng"]),
            episode,
            titled("m3", "Movie", None, &["und"]),
        ];
        let index = LanguageIndex::from_scan(&items);
        assert!(index.has("deu", "m1") && index.has("eng", "m1"));
        assert!(!index.has("deu", "m2"));
        assert!(index.has("deu", "s1") && !index.has("deu", "e1"));
        assert_eq!(
            index.languages(),
            [("deu".to_string(), 2), ("eng".to_string(), 2)]
        );
    }

    #[test]
    fn keeps_combines_years_and_language() {
        let index = LanguageIndex::from_scan(&[
            titled("a", "Movie", Some(2012), &["deu"]),
            titled("b", "Movie", Some(2012), &["eng"]),
            titled("c", "Movie", Some(2001), &["deu"]),
        ]);
        let years = Narrowing {
            years: Some(YearSpan::decade(2010)),
            language: None,
        };
        let both = Narrowing {
            years: Some(YearSpan::decade(2010)),
            language: Some("deu".into()),
        };
        let a = titled("a", "Movie", Some(2012), &[]);
        let b = titled("b", "Movie", Some(2012), &[]);
        let c = titled("c", "Movie", Some(2001), &[]);
        let no_year = titled("a", "Movie", None, &[]);
        assert!(years.keeps(&a, None) && years.keeps(&b, None) && !years.keeps(&c, None));
        assert!(both.keeps(&a, Some(&index)));
        assert!(!both.keeps(&b, Some(&index)), "right year, wrong language");
        assert!(!both.keeps(&c, Some(&index)), "right language, wrong year");
        assert!(!years.keeps(&no_year, None), "no year, no decade");
        assert!(
            !both.keeps(&a, None),
            "a language without an index keeps nothing"
        );
        assert!(Narrowing::default().keeps(&no_year, None));
    }

    fn say(key: &str) -> String {
        key.to_owned()
    }
    fn name(code: &str) -> Option<String> {
        (code == "deu").then(|| "Deutsch".to_owned())
    }

    #[test]
    fn sheet_lists_decades_newest_first_and_marks_the_picks() {
        let facets = FilterFacets {
            years: Facet::Ready(vec![1998, 2011, 2014, 2023]),
            languages: Facet::Ready(vec![("deu".into(), 5), ("eng".into(), 3)]),
        };
        let narrowing = Narrowing {
            years: Some(YearSpan::decade(2010)),
            language: Some("deu".into()),
        };
        let sheet = FilterSheet::build(
            &LibraryFilter::ALL,
            LibraryFilter::Begun,
            &narrowing,
            &facets,
            &say,
            &name,
        );
        assert_eq!(sheet.title, "Filtern");
        let kinds: Vec<_> = sheet.groups.iter().map(|g| g.kind).collect();
        assert_eq!(
            kinds,
            [
                FilterGroupKind::Status,
                FilterGroupKind::Years,
                FilterGroupKind::Language
            ]
        );
        let labels = |g: &FilterGroup| g.rows.iter().map(|r| r.label.clone()).collect::<Vec<_>>();
        assert_eq!(
            labels(&sheet.groups[0]),
            ["Alle", "Angefangen", "Merkliste", "Ungesehen"]
        );
        assert_eq!(
            labels(&sheet.groups[1]),
            [
                "Alle Jahre",
                "2020\u{2013}2029",
                "2010\u{2013}2019",
                "1990\u{2013}1999"
            ]
        );
        assert_eq!(
            labels(&sheet.groups[2]),
            ["Alle Sprachen", "Deutsch", "ENG"]
        );
        let picked = |g: &FilterGroup| {
            g.rows
                .iter()
                .filter(|r| r.selected)
                .map(|r| r.label.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(picked(&sheet.groups[0]), ["Angefangen"]);
        assert_eq!(picked(&sheet.groups[1]), ["2010\u{2013}2019"]);
        assert_eq!(picked(&sheet.groups[2]), ["Deutsch"]);
        assert_eq!(sheet.groups[2].rows[1].count, Some(5));
    }

    #[test]
    fn sheet_hides_what_the_server_cannot_do_and_shows_loading() {
        let off = FilterSheet::build(
            &LibraryFilter::ALL,
            LibraryFilter::All,
            &Narrowing::default(),
            &FilterFacets::default(),
            &say,
            &name,
        );
        assert_eq!(off.groups.len(), 1, "Plex: only the status group");
        let waiting = FilterSheet::build(
            &LibraryFilter::ALL,
            LibraryFilter::All,
            &Narrowing::default(),
            &FilterFacets {
                years: Facet::Failed,
                languages: Facet::Loading,
            },
            &say,
            &name,
        );
        assert_eq!(waiting.groups.len(), 2);
        assert!(waiting.groups[1].loading && waiting.groups[1].rows.is_empty());
        assert_eq!(waiting.groups[1].kind, FilterGroupKind::Language);
        let empty = FilterSheet::build(
            &LibraryFilter::ALL,
            LibraryFilter::All,
            &Narrowing::default(),
            &FilterFacets {
                years: Facet::Ready(Vec::new()),
                languages: Facet::Ready(Vec::new()),
            },
            &say,
            &name,
        );
        assert_eq!(empty.groups.len(), 1, "nothing to pick from, no group");
    }
    #[test]
    fn flat_rows_put_each_heading_on_the_first_line_of_its_group() {
        let facets = FilterFacets {
            years: Facet::Ready(vec![2011, 2014]),
            languages: Facet::Loading,
        };
        let sheet = FilterSheet::build(
            &LibraryFilter::ALL,
            LibraryFilter::Unwatched,
            &Narrowing {
                years: Some(YearSpan::decade(2010)),
                language: None,
            },
            &facets,
            &say,
            &name,
        );
        let lines = sheet.flat_rows();
        let text: Vec<_> = lines
            .iter()
            .map(|l| (l.heading.as_deref(), l.label.as_str(), l.selected))
            .collect();
        assert_eq!(
            text,
            [
                (None, "Alle", false),
                (None, "Angefangen", false),
                (None, "Merkliste", false),
                (None, "Ungesehen", true),
                (Some("Erscheinungsjahr"), "Alle Jahre", false),
                (None, "2010\u{2013}2019", true),
                (Some("Sprache"), LOADING_LABEL, false),
            ]
        );
        assert_eq!(
            lines[3].choice,
            Some(FilterChoice::Status(LibraryFilter::Unwatched))
        );
        assert_eq!(lines[4].choice, Some(FilterChoice::Years(None)));
        assert_eq!(lines[6].choice, None, "the loading line cannot be picked");
        assert_eq!(sheet.pill, "Ungesehen \u{b7} 2010\u{2013}2019");
    }

    #[test]
    fn the_pill_names_status_years_and_language_without_any_facets() {
        let none = Narrowing::default();
        assert_eq!(pill_text(LibraryFilter::All, &none, &say, &name), "Alle");
        let both = Narrowing {
            years: Some(YearSpan::decade(1990)),
            language: Some("deu".into()),
        };
        assert_eq!(
            pill_text(LibraryFilter::Unwatched, &both, &say, &name),
            "Ungesehen \u{b7} 1990\u{2013}1999 \u{b7} Deutsch"
        );
        let unknown = Narrowing {
            years: None,
            language: Some("jpn".into()),
        };
        assert_eq!(
            pill_text(LibraryFilter::Begun, &unknown, &say, &name),
            "Angefangen \u{b7} JPN"
        );
    }

    #[test]
    fn a_list_filter_reads_back_from_its_raw_value_and_takes_picks() {
        let plain = ListFilter::from_raw("ungesehen");
        assert_eq!(plain.status, LibraryFilter::Unwatched);
        assert!(plain.narrowing.is_none());
        assert_eq!(plain.raw_value(), "ungesehen");
        let narrowed = plain
            .picked(&FilterChoice::Years(Some(YearSpan::decade(2014))))
            .picked(&FilterChoice::Language(Some("deu".into())));
        assert_eq!(ListFilter::from_raw(&narrowed.raw_value()), narrowed);
        assert_eq!(
            narrowed.narrowing.years,
            Some(YearSpan {
                from: 2010,
                to: 2019
            })
        );
        assert_eq!(narrowed.narrowing.language.as_deref(), Some("deu"));
        let lifted = narrowed
            .picked(&FilterChoice::Years(None))
            .picked(&FilterChoice::Status(LibraryFilter::All));
        assert_eq!(lifted.raw_value(), "alle|sdeu");
        assert_eq!(
            ListFilter::from_raw("garbage|jx|s"),
            ListFilter::status_only(LibraryFilter::All)
        );
    }
}
