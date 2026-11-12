//! `ShelfSource` and `TitleFilter` (Swift `SectionOffering.swift:213-310`): where a library or
//! collection page reads its titles from, and the filter for "All" across libraries.

use std::collections::{HashMap, HashSet};

use swiftly_model::{Item, Items};

use crate::library_filter::{Sorting, SortingExt};
use crate::library_genre::LibraryGenre;

/// Where a library or collection page gets its titles (:213-258).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShelfSource {
    /// Library or collection. `None` means: from several libraries.
    pub parent: Option<String>,
    /// Without `parent`: from exactly these libraries (`onlyOut`).
    pub only_out: Vec<String>,
    /// The section, `movies` or `tvshows`.
    pub art: Option<String>,
    /// A collection (`BoxSet`) instead of a library.
    pub collection: bool,
}

impl ShelfSource {
    /// `init(parent:art:collection:onlyOut:)`.
    pub fn new(
        parent: Option<&str>,
        art: Option<&str>,
        collection: bool,
        only_out: &[&str],
    ) -> Self {
        Self {
            parent: parent.map(Into::into),
            only_out: only_out.iter().map(|s| (*s).into()).collect(),
            art: art.map(Into::into),
            collection,
        }
    }
    /// From several libraries, so filtered (:232).
    pub fn is_filtering(&self) -> bool {
        self.parent.is_none() && !self.only_out.is_empty()
    }
    /// `IncludeItemTypes` of the section (:234).
    pub fn types(&self) -> Vec<&'static str> {
        LibraryGenre::types_toward(self.art.as_deref())
    }
    /// A collection is not queried recursively; "All" is (:243-247).
    pub fn recursive(&self) -> bool {
        if self.collection {
            return false;
        }
        if self.parent.is_none() {
            return true;
        }
        LibraryGenre::recursive_toward(self.art.as_deref())
    }
    /// In a collection the year ascends, everywhere else the sort direction applies (:251-253).
    pub fn bearing(&self, sorting: Sorting) -> &'static str {
        if self.collection && sorting == Sorting::Erscheinung {
            "Ascending"
        } else {
            sorting.bearing()
        }
    }
    /// What it was loaded for; if that changes, it is replaced instead of refreshed (:256-258).
    pub fn key(&self) -> String {
        let head = self
            .parent
            .clone()
            .unwrap_or_else(|| self.only_out.join("+"));
        format!(
            "{head}|{}|{}",
            self.art.as_deref().unwrap_or(""),
            if self.collection { "s" } else { "b" }
        )
    }
}

/// "All movies" looks like a library, not like their sum (:280-310): each work once, and only
/// what comes from the chosen libraries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TitleFilter {
    allowed: HashSet<String>,
    /// How many distinct titles there are.
    pub total: i64,
    watched: HashSet<String>,
}

impl TitleFilter {
    /// `init(je:)`: per chosen library, in the account's order, everything from it (:287-295).
    pub fn new(libraries: &[(String, Vec<Item>)]) -> Self {
        let mut origin = HashMap::new();
        for (from, list) in libraries {
            for i in list {
                origin.insert(i.id.clone(), from.clone());
            }
        }
        let views: Vec<Item> = libraries
            .iter()
            .map(|(id, _)| Item::new(id.clone(), "", None))
            .collect();
        // One library needs no joined copy of its list (Swift shares the array; a clone of 10 000 items costs here).
        if let [(_, only)] = libraries {
            return Self::build(only, &origin, &views);
        }
        let all: Vec<Item> = libraries
            .iter()
            .flat_map(|(_, l)| l.iter().cloned())
            .collect();
        Self::build(&all, &origin, &views)
    }
    fn build(all: &[Item], origin: &HashMap<String, String>, views: &[Item]) -> Self {
        let media_works = Items::merge(all, origin, views, &HashMap::new(), false);
        Self {
            allowed: media_works
                .iter()
                .map(|i| crate::list_rules::canon(&i.id).into_owned())
                .collect(),
            total: i64::try_from(media_works.len()).unwrap_or(i64::MAX),
            watched: HashSet::new(),
        }
    }
    /// `init(identifiers:)`: everything from one list; of duplicates the first stays (:298).
    pub fn from_identifiers(identifiers: &[Item]) -> Self {
        let origin: HashMap<String, String> = identifiers
            .iter()
            .map(|i| (i.id.clone(), String::new()))
            .collect();
        Self::build(identifiers, &origin, &[Item::new(String::new(), "", None)])
    }
    /// What remains of a page, in its order (Swift `seven`, :301-303).
    pub fn sift(&mut self, page: &[Item]) -> Vec<Item> {
        page.iter()
            .filter(|i| {
                self.allowed
                    .contains(crate::list_rules::canon(&i.id).as_ref())
                    && self
                        .watched
                        .insert(crate::list_rules::canon(&i.id).into_owned())
            })
            .cloned()
            .collect()
    }
    /// From the start, when reloading the first page (`fromFront`).
    pub fn from_front(&mut self) {
        self.watched.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn film(id: &str, tmdb: &str) -> Item {
        Item {
            provider_ids: Some([("Tmdb".to_string(), tmdb.to_string())].into()),
            ..Item::new(id, id, Some("Movie"))
        }
    }

    #[test]
    fn source_queries() {
        let lib = ShelfSource::new(Some("l1"), Some("movies"), false, &[]);
        assert!(lib.recursive());
        assert!(!lib.is_filtering());
        assert_eq!(lib.types(), ["Movie"]);
        assert_eq!(lib.key(), "l1|movies|b");
        let col = ShelfSource::new(Some("c"), Some("movies"), true, &[]);
        assert!(!col.recursive());
        assert_eq!(col.bearing(Sorting::Erscheinung), "Ascending");
        assert_eq!(col.bearing(Sorting::Latest), "Descending");
        let all = ShelfSource::new(None, None, false, &["a", "b"]);
        assert!(all.is_filtering());
        assert!(all.recursive());
        assert_eq!(all.key(), "a+b||b");
        let plain = ShelfSource::new(Some("x"), None, false, &[]);
        assert!(!plain.recursive());
    }

    #[test]
    fn filter_keeps_one_copy_from_the_first_library() {
        // The same work (same TMDb id) in two libraries: the one of the first library stays.
        let mut f = TitleFilter::new(&[
            ("lib1".into(), vec![film("a1", "7"), film("a2", "8")]),
            ("lib2".into(), vec![film("b1", "7")]),
        ]);
        assert_eq!(f.total, 2);
        let page = f.sift(&[
            film("b1", "7"),
            film("a1", "7"),
            film("a2", "8"),
            film("a2", "8"),
        ]);
        assert_eq!(
            page.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["a1", "a2"]
        );
        f.from_front();
        assert_eq!(f.sift(&[film("a1", "7")]).len(), 1);
    }
}
