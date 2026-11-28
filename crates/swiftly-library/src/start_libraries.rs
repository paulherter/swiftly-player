//! Libraries and collections pulled onto the home page as their own rows
//! (Swift `StartLibraries.swift`).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use swiftly_model::Item;

use crate::list_rules::ListRules;

/// The comparison form of a Jellyfin id, insensitive to dash formatting and casing.
pub fn normalized_id(id: &str) -> String {
    crate::list_rules::canon(id)
        .chars()
        .filter(|c| *c != '-')
        .flat_map(char::to_lowercase)
        .collect()
}

/// A library or collection the user pulled onto the home page (:7-34). Only the stable selection
/// is persisted; the name is resolved from the server for each Home load.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartLibrary {
    /// Library or collection id.
    pub id: String,
    /// Current runtime name, empty until the server resolves it.
    pub name: String,
    /// A collection (`BoxSet`) instead of a library.
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

#[derive(Serialize, Deserialize)]
struct Record {
    id: Option<String>,
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
    /// entry without an id is skipped; a wrongly typed `id` or `sammlung` fails the whole list.
    /// Legacy `name` fields are ignored.
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
                        name: String::new(),
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
        let records: Vec<Record> = Self::clean(choice)
            .into_iter()
            .map(|library| Record {
                id: Some(library.id),
                sammlung: Some(library.collection),
            })
            .collect();
        let text = serde_json::to_string(&records).ok()?;
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
    fn legacy_names_load_but_are_not_authoritative() {
        let d = br#"[{"id":"a"},{"name":"ohne Kennung"},{"id":"b","name":"B"},{"id":"a","name":"doppelt"}]"#;
        let libraries = StartLibraries::read(Some(d));
        assert_eq!(
            libraries,
            [
                StartLibrary::new("a", "", false),
                StartLibrary::new("b", "", false),
            ]
        );
        assert_eq!(
            String::from_utf8(StartLibraries::data(&libraries).unwrap_or_default())
                .unwrap_or_default(),
            r#"[{"id":"a","sammlung":false},{"id":"b","sammlung":false}]"#
        );
    }
    #[test]
    fn write_and_read_round_trip() {
        let w = [
            StartLibrary::new("x", "Filme", false),
            StartLibrary::new("y", "Marvel", true),
        ];
        let data = StartLibraries::data(&w);
        assert_eq!(
            StartLibraries::read(data.as_deref()),
            [
                StartLibrary::new("x", "", false),
                StartLibrary::new("y", "", true),
            ]
        );
    }
    #[test]
    fn keys_are_sorted_and_stable() {
        let w = [StartLibrary::new("x", "Filme", true)];
        let text =
            String::from_utf8(StartLibraries::data(&w).unwrap_or_default()).unwrap_or_default();
        assert_eq!(text, r#"[{"id":"x","sammlung":true}]"#);
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
