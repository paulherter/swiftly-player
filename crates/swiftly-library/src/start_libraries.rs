//! Libraries and collections pulled onto the home page as their own rows
//! (Swift `StartLibraries.swift`).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use swiftly_model::Item;

use crate::list_rules::ListRules;

/// A library or collection the user pulled onto the home page (:7-34). Both id and name are
/// remembered. Serialised keys are `id`, `name`, `sammlung` (already in sorted order).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StartLibrary {
    /// Library or collection id.
    pub id: String,
    /// Name, kept so the settings can name the row while the server is silent.
    pub name: String,
    /// A collection (`BoxSet`) instead of a library.
    #[serde(rename = "sammlung")]
    pub collection: bool,
}

impl StartLibrary {
    /// `init(id:name:collection:)`.
    pub fn new(id: &str, name: &str, collection: bool) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            collection,
        }
    }
    /// From what the picker shows (`init(_ item:)`).
    pub fn from_item(item: &Item) -> Self {
        Self::new(
            &item.id,
            &item.name,
            item.type_.as_deref() == Some("BoxSet"),
        )
    }
    /// The entry as an item, for the page the row header opens (`item`).
    pub fn item(&self) -> Item {
        Item::new(
            self.id.clone(),
            self.name.clone(),
            Some(if self.collection {
                "BoxSet"
            } else {
                "CollectionFolder"
            }),
        )
    }
}

#[derive(Deserialize)]
struct Record {
    id: Option<String>,
    name: Option<String>,
    sammlung: Option<bool>,
}

/// How the chosen library rows are read, supplemented and saved (:44-101).
pub struct StartLibraries;

impl StartLibraries {
    /// Each id once, in order of first appearance; an empty id is dropped (:52-55).
    pub fn clean(choice: &[StartLibrary]) -> Vec<StartLibrary> {
        let mut watched = HashSet::new();
        choice
            .iter()
            .filter(|l| {
                !l.id.is_empty() && watched.insert(crate::list_rules::canon(&l.id).into_owned())
            })
            .cloned()
            .collect()
    }

    /// Reads a stored choice. Never fails: missing or damaged storage means "no rows". An
    /// entry without an id is skipped; a wrongly typed field fails the whole list, as in
    /// Swift (:60-68).
    pub fn read(data: Option<&[u8]>) -> Vec<StartLibrary> {
        let Some(data) = data else { return Vec::new() };
        let Ok(raw) = serde_json::from_slice::<Vec<Record>>(data) else {
            return Vec::new();
        };
        Self::clean(
            &raw.into_iter()
                .filter_map(|e| {
                    let id = e.id?;
                    Some(StartLibrary {
                        id,
                        name: e.name.unwrap_or_default(),
                        collection: e.sammlung.unwrap_or(false),
                    })
                })
                .collect::<Vec<_>>(),
        )
    }

    /// The cleaned choice as JSON; struct fields are declared in sorted-key order so equal
    /// choices give equal text (:73-77).
    pub fn data(choice: &[StartLibrary]) -> Option<Vec<u8>> {
        // Foundation's JSONEncoder writes `/` as `\/`; equal text across platforms keeps the sync quiet.
        let text = serde_json::to_string(&Self::clean(choice)).ok()?;
        Some(text.replace('/', "\\/").into_bytes())
    }

    /// Whether a library has titles to show; music, playlists, live TV and books carry no
    /// poster row (:92-97).
    pub fn selectable(library: &Item) -> bool {
        !matches!(
            library
                .collection_type
                .as_deref()
                .map(str::to_lowercase)
                .as_deref(),
            Some("music" | "playlists" | "livetv" | "books")
        )
    }

    /// What is available to pick: libraries and collections without what is already chosen
    /// (:99-104).
    pub fn pick(libraries: &[Item], collections: &[Item], selected: &[StartLibrary]) -> Vec<Item> {
        let already: HashSet<String> = selected
            .iter()
            .map(|s| crate::list_rules::canon(&s.id).into_owned())
            .collect();
        let all: Vec<Item> = libraries.iter().chain(collections).cloned().collect();
        ListRules::without_double(&all)
            .into_iter()
            .filter(|i| !already.contains(crate::list_rules::canon(&i.id).as_ref()))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(id: &str) -> Item {
        Item::new(id, id, None)
    }

    #[test]
    fn old_store_gives_no_rows() {
        assert!(StartLibraries::read(None).is_empty());
        assert!(StartLibraries::read(Some(b"kaputt")).is_empty());
    }
    #[test]
    fn entry_without_name_keeps_the_choice() {
        let d = br#"[{"id":"a"},{"name":"ohne Kennung"},{"id":"b","name":"B"},{"id":"a","name":"doppelt"}]"#;
        let ids: Vec<String> = StartLibraries::read(Some(d))
            .into_iter()
            .map(|l| l.id)
            .collect();
        assert_eq!(ids, ["a", "b"]);
    }
    #[test]
    fn write_and_read_round_trip() {
        let w = [
            StartLibrary::new("x", "Filme", false),
            StartLibrary::new("y", "Marvel", false),
        ];
        let data = StartLibraries::data(&w);
        assert_eq!(StartLibraries::read(data.as_deref()), w);
    }
    #[test]
    fn keys_are_sorted_and_stable() {
        let w = [StartLibrary::new("x", "Filme", true)];
        let text =
            String::from_utf8(StartLibraries::data(&w).unwrap_or_default()).unwrap_or_default();
        assert_eq!(text, r#"[{"id":"x","name":"Filme","sammlung":true}]"#);
    }
    #[test]
    fn pick_leaves_out_the_chosen() {
        let a = StartLibraries::pick(
            &[t("a"), t("b")],
            &[t("c"), t("a")],
            &[StartLibrary::new("b", "B", false)],
        );
        assert_eq!(
            a.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["a", "c"]
        );
    }
    #[test]
    fn selectable_skips_music_and_playlists() {
        let list = Item {
            collection_type: Some("playlists".into()),
            ..t("pl")
        };
        assert!(!StartLibraries::selectable(&list));
        let movies = Item {
            collection_type: Some("Movies".into()),
            ..t("m")
        };
        assert!(StartLibraries::selectable(&movies));
    }
    #[test]
    fn collection_item_type() {
        assert_eq!(
            StartLibrary::new("c", "C", true).item().type_.as_deref(),
            Some("BoxSet")
        );
        assert_eq!(
            StartLibrary::new("c", "C", false).item().type_.as_deref(),
            Some("CollectionFolder")
        );
        let b = Item::new("c", "C", Some("BoxSet"));
        assert!(StartLibrary::from_item(&b).collection);
    }
}
