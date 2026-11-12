//! `ListRules` (Swift `RailsEpisode.swift:13-124`): rules for lists that go into a view.
//!
//! The `JellyfinClient` extension `lastAdded` that sits in the same Swift file is in
//! `client_ext`.

use std::collections::HashSet;

use swiftly_model::Item;
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// `ListRules` namespace.
pub struct ListRules;

/// `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)` followed by
/// `trimmingCharacters(in: .whitespaces)` (RailsEpisode.swift:71-74): decompose, drop combining
/// marks, lowercase, trim spaces and tabs.
fn folded(text: &str) -> String {
    let stripped: String = text
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_uppercase)
        .flat_map(char::to_lowercase)
        .collect();
    swiftly_rules::trim_whitespaces(&stripped).to_string()
}

/// Swift compares `String`s by canonical equivalence (`e` + U+0301 equals U+00E9); ids are compared
/// in their composed form so two spellings of one id count as one.
pub(crate) fn canon(id: &str) -> std::borrow::Cow<'_, str> {
    if id.is_ascii() {
        std::borrow::Cow::Borrowed(id)
    } else {
        std::borrow::Cow::Owned(id.nfc().collect())
    }
}

impl ListRules {
    /// Each id exactly once, in the order of first occurrence (:19-22).
    pub fn without_double(items: &[Item]) -> Vec<Item> {
        let mut watched = HashSet::new();
        items
            .iter()
            .filter(|i| watched.insert(canon(&i.id).into_owned()))
            .cloned()
            .collect()
    }

    /// One title, one row, even if it lives in two libraries (:40-50); at most `show_item`
    /// entries. Swift's name is `jeTitleInTimes`.
    pub fn je_title_in_times(items: &[Item], show_item: usize) -> Vec<Item> {
        let mut watched = HashSet::new();
        let mut result: Vec<Item> = Vec::new();
        for entry in items {
            if result.len() >= show_item {
                break;
            }
            if watched.insert(Self::title_key(entry)) {
                result.push(entry.clone());
            }
        }
        result
    }

    /// The first episode per series id; all movies stay, in list order (:53-59).
    pub fn je_series_in_times(items: &[Item]) -> Vec<Item> {
        let mut watched = HashSet::new();
        items
            .iter()
            .filter(|i| {
                if i.type_.as_deref() != Some("Episode") {
                    return true;
                }
                match &i.series_id {
                    Some(series) => watched.insert(series.clone()),
                    None => true,
                }
            })
            .cloned()
            .collect()
    }

    /// The full entries in the order of the slim ones; anything the server dropped is omitted
    /// (:64-67). Of two full entries with one id the first counts (`uniquingKeysWith: { a, _ in a }`).
    pub fn in_rails_episode(full: &[Item], pre_status: &[Item]) -> Vec<Item> {
        let mut by_id = std::collections::HashMap::new();
        for item in full {
            by_id.entry(canon(&item.id).into_owned()).or_insert(item);
        }
        pre_status
            .iter()
            .filter_map(|p| by_id.get(canon(&p.id).as_ref()).map(|i| (*i).clone()))
            .collect()
    }

    /// What makes up the title (:70-97).
    pub fn title_key(item: &Item) -> String {
        match item.type_.as_deref() {
            Some("Movie") => {
                if let Some(tmdb) = provider(item, "Tmdb") {
                    return format!("film:tmdb:{tmdb}");
                }
                if let Some(imdb) = provider(item, "Imdb") {
                    return format!("film:imdb:{imdb}");
                }
                let year = item
                    .production_year
                    .map(|y| y.to_string())
                    .unwrap_or_default();
                format!("film:{}:{year}", folded(&item.name))
            }
            Some("Series") => {
                for p in ["Tmdb", "Tvdb", "Imdb"] {
                    if let Some(nr) = provider(item, p) {
                        return format!("serie:{}:{nr}", p.to_lowercase());
                    }
                }
                format!("serie:{}", folded(&item.name))
            }
            Some("Episode") => {
                if let Some(series) = item.series_name.as_deref().filter(|s| !s.is_empty()) {
                    return format!("serie:{}", folded(series));
                }
                format!(
                    "serie:id:{}",
                    canon(item.series_id.as_deref().unwrap_or(&item.id))
                )
            }
            _ => format!("id:{}", canon(&item.id)),
        }
    }

    /// The same rule for appending: what is already there is not added again (:100-103).
    pub fn append(new_one: &[Item], existing: &[Item]) -> Vec<Item> {
        let mut watched: HashSet<String> =
            existing.iter().map(|i| canon(&i.id).into_owned()).collect();
        let mut out = existing.to_vec();
        out.extend(
            new_one
                .iter()
                .filter(|i| watched.insert(canon(&i.id).into_owned()))
                .cloned(),
        );
        out
    }

    /// Whether there is more beyond what is already there (:108-110).
    pub fn still_more_present(loaded: i64, total: i64) -> bool {
        loaded < total
    }

    /// Whether this tile is in the last three rows, so it triggers loading more (:128-130).
    pub fn post_load_section(id: &str, items: &[Item], columns: i64) -> bool {
        let take = usize::try_from((3 * columns).max(1)).unwrap_or(1);
        let start = items.len().saturating_sub(take);
        let id = canon(id);
        items[start..].iter().any(|i| canon(&i.id) == id)
    }

    /// The first page is reloaded; further pages stay (:141-146). If the total changed,
    /// everything is replaced.
    pub fn refresh(
        first: &[Item],
        existing: &[Item],
        total_before: i64,
        total_now: i64,
    ) -> Vec<Item> {
        if total_before != total_now || existing.len() <= first.len() {
            return Self::without_double(first);
        }
        Self::append(&existing[first.len()..], &Self::without_double(first))
    }
}

fn provider<'a>(item: &'a Item, key: &str) -> Option<&'a str> {
    item.provider_ids
        .as_ref()?
        .get(key)
        .map(String::as_str)
        .filter(|v| !v.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, name: &str) -> Item {
        Item::new(id, name, None)
    }
    fn ids(v: &[Item]) -> Vec<&str> {
        v.iter().map(|i| i.id.as_str()).collect()
    }
    fn film(id: &str, name: &str, year: Option<i64>, tmdb: Option<&str>) -> Item {
        Item {
            production_year: year,
            provider_ids: tmdb.map(|t| [("Tmdb".to_string(), t.to_string())].into()),
            ..Item::new(id, name, Some("Movie"))
        }
    }
    fn episode(id: &str, series: &str, series_id: &str) -> Item {
        Item {
            series_name: Some(series.into()),
            series_id: Some(series_id.into()),
            ..Item::new(id, "Folge", Some("Episode"))
        }
    }

    #[test]
    fn duplicates_drop_out() {
        let list = [
            item("a", "erste"),
            item("b", "x"),
            item("a", "zweite"),
            item("c", "x"),
        ];
        let clean = ListRules::without_double(&list);
        assert_eq!(ids(&clean), ["a", "b", "c"]);
        assert_eq!(clean[0].name, "erste");
    }
    #[test]
    fn nothing_to_drop() {
        let list = [item("a", "x"), item("b", "x"), item("c", "x")];
        assert_eq!(ids(&ListRules::without_double(&list)), ["a", "b", "c"]);
    }
    #[test]
    fn empty_stays_empty() {
        assert!(ListRules::without_double(&[]).is_empty());
    }
    #[test]
    fn append_only_new() {
        let present = [item("a", "x"), item("b", "x")];
        let new = [item("b", "x"), item("c", "x"), item("c", "x")];
        assert_eq!(ids(&ListRules::append(&new, &present)), ["a", "b", "c"]);
    }
    #[test]
    fn full_in_order_of_slim() {
        let slim = [item("c", "x"), item("a", "x"), item("b", "x")];
        let full = [
            item("a", "voll a"),
            item("b", "voll b"),
            item("c", "voll c"),
            item("z", "x"),
        ];
        let result = ListRules::in_rails_episode(&full, &slim);
        assert_eq!(ids(&result), ["c", "a", "b"]);
        assert_eq!(result[0].name, "voll c");
        assert_eq!(
            ids(&ListRules::in_rails_episode(&[item("a", "x")], &slim)),
            ["a"]
        );
    }
    #[test]
    fn trigger_third_last_rail() {
        let list: Vec<Item> = (0..30).map(|i| item(&format!("i{i}"), "x")).collect();
        assert!(!ListRules::post_load_section("i14", &list, 5));
        assert!(ListRules::post_load_section("i15", &list, 5));
        assert!(ListRules::post_load_section("i29", &list, 5));
    }
    #[test]
    fn shorter_than_three_rails() {
        let list: Vec<Item> = (0..7).map(|i| item(&format!("i{i}"), "x")).collect();
        assert!(ListRules::post_load_section("i0", &list, 5));
    }
    #[test]
    fn empty_list_has_no_trigger() {
        assert!(!ListRules::post_load_section("i0", &[], 5));
    }
    #[test]
    fn large_library_post_back() {
        let server: Vec<Item> = (0..2000).map(|i| item(&format!("i{i}"), "x")).collect();
        let page = |since: usize| server[since..(since + 60).min(server.len())].to_vec();
        let mut list: Vec<Item> = Vec::new();
        while list.len() < 180 {
            list = ListRules::append(&page(list.len()), &list);
        }
        assert_eq!(list.len(), 180);
        list = ListRules::refresh(&page(0), &list, 2000, 2000);
        assert_eq!(ids(&list), ids(&server[..180]));
        assert!(ListRules::post_load_section("i170", &list, 7));
        while list.len() < server.len() {
            list = ListRules::append(&page(list.len()), &list);
        }
        assert_eq!(ids(&list), ids(&server));
    }
    #[test]
    fn refresh_with_new_title_replaces() {
        let old: Vec<Item> = (0..120).map(|i| item(&format!("i{i}"), "x")).collect();
        let mut new = vec![item("neu", "x")];
        new.extend((0..59).map(|i| item(&format!("i{i}"), "x")));
        let result = ListRules::refresh(&new, &old, 120, 121);
        assert_eq!(ids(&result), ids(&new));
    }
    #[test]
    fn still_more_present() {
        assert!(ListRules::still_more_present(40, 120));
        assert!(!ListRules::still_more_present(120, 120));
        assert!(!ListRules::still_more_present(121, 120));
    }
    #[test]
    fn film_two_libraries() {
        let raw = [
            film("359b", "Toy Story 5", Some(2026), Some("1084244")),
            film("fa4a", "Toy Story 5", Some(2026), Some("1084244")),
        ];
        assert_eq!(ids(&ListRules::je_title_in_times(&raw, 24)), ["359b"]);
    }
    #[test]
    fn film_without_number_uses_name_and_year() {
        let raw = [
            film("a", "Obsession", Some(2026), None),
            film("b", "obsession", Some(2026), None),
            film("c", "Obsession", Some(1976), None),
        ];
        assert_eq!(ids(&ListRules::je_title_in_times(&raw, 24)), ["a", "c"]);
    }
    #[test]
    fn series_two_libraries() {
        let raw = [
            episode("67e2", "Adults", "7870"),
            episode("b6fe", "Beauty & The Nerd", "0f0c"),
            episode("fdcf", "Beauty & The Nerd", "a323"),
            episode("d419", "Adults", "f131"),
            episode("480c", "Adults", "7870"),
        ];
        assert_eq!(
            ids(&ListRules::je_title_in_times(&raw, 24)),
            ["67e2", "b6fe"]
        );
    }
    #[test]
    fn film_and_series_of_one_name_stay() {
        let raw = [
            film("f", "FROM", Some(2026), None),
            episode("e", "FROM", "s"),
        ];
        assert_eq!(ListRules::je_title_in_times(&raw, 24).len(), 2);
    }
    #[test]
    fn at_most_the_wanted_number() {
        let raw: Vec<Item> = (0..10)
            .map(|i| film(&i.to_string(), &format!("Film {i}"), Some(2026), None))
            .collect();
        assert_eq!(ids(&ListRules::je_title_in_times(&raw, 3)), ["0", "1", "2"]);
    }
    #[test]
    fn series_in_times_keeps_first_episode_per_series_and_all_movies() {
        let raw = [
            episode("e1", "S", "s1"),
            film("m", "M", None, None),
            episode("e2", "S", "s1"),
            episode("e3", "T", "s2"),
        ];
        assert_eq!(ids(&ListRules::je_series_in_times(&raw)), ["e1", "m", "e3"]);
    }
    #[test]
    fn folding_ignores_case_and_diacritics() {
        assert_eq!(folded("  Séance\t"), "seance");
    }
}
