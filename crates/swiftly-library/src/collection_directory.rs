//! `ItemCollection` and `CollectionDirectory` (Swift `CollectionDirectory.swift:1-110`):
//! all collections of an account with their members. The fetch (`collectionDirectory`,
//! `libraryShares`) is in `client_ext`.

use std::collections::HashSet;

use swiftly_model::{Item, Localizer};

use crate::library_genre::LibraryGenre;

/// A Jellyfin collection (`BoxSet`) with the ids of its movies and series (:4-39).
#[derive(Debug, Clone, PartialEq)]
pub struct ItemCollection {
    /// The collection itself.
    pub item: Item,
    /// Ids of its movies.
    pub movies: HashSet<String>,
    /// Ids of its series.
    pub series_list: HashSet<String>,
}

impl ItemCollection {
    /// `init(item:members:)`.
    pub fn new(item: Item, members: &[Item]) -> Self {
        let ids = |kind: &str| {
            members
                .iter()
                .filter(|m| m.type_.as_deref() == Some(kind))
                .map(|m| m.id.clone())
                .collect()
        };
        Self {
            item,
            movies: ids("Movie"),
            series_list: ids("Series"),
        }
    }
    /// The collection's id.
    pub fn id(&self) -> &str {
        &self.item.id
    }
    /// How many titles of the section (`movies` or `tvshows`) it holds.
    pub fn count(&self, art: &str) -> usize {
        match art.to_lowercase().as_str() {
            "movies" => self.movies.len(),
            "tvshows" => self.series_list.len(),
            _ => 0,
        }
    }
    /// Whether the title is a member.
    pub fn contains(&self, id: &str) -> bool {
        self.movies.contains(id) || self.series_list.contains(id)
    }
    /// "3 movies" or "3 series" under a collection tile (:34-38). The catalog keys are the
    /// German source strings `%lld Serien` / `%lld Filme`.
    pub fn count_text(art: &str, count: i64, l: &dyn Localizer) -> String {
        let key = if art.to_lowercase() == "tvshows" {
            "%lld Serien"
        } else {
            "%lld Filme"
        };
        l.text(key, &[count])
    }
}

/// All collections of an account, including membership (:54-109).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CollectionDirectory {
    /// The collections, in server order.
    pub all: Vec<ItemCollection>,
}

impl CollectionDirectory {
    /// A collection only counts from two titles in the section (:56).
    pub const THRESHOLD: usize = 2;

    /// The collections in the section, in server order (:66-68).
    pub fn collections(&self, art: &str) -> Vec<&ItemCollection> {
        self.all
            .iter()
            .filter(|c| c.count(art) >= Self::THRESHOLD)
            .collect()
    }
    /// The collections this title belongs to, only those that exist in the title's section
    /// (`collections(with:)`, :72-75).
    pub fn collections_with(&self, title: &Item) -> Vec<&ItemCollection> {
        let Some(art) = LibraryGenre::art_to_type(title.type_.as_deref()) else {
            return Vec::new();
        };
        self.collections(art)
            .into_iter()
            .filter(|c| c.contains(&title.id))
            .collect()
    }
    /// Has the user hidden collections in Jellyfin? The `boxsets` folder is in the list with
    /// hidden views but not in the visible one (:90-95).
    pub fn hidden(visible: &[Item], with_hidden: &[Item]) -> bool {
        let folder = |list: &[Item]| {
            list.iter().any(|i| {
                i.collection_type
                    .as_deref()
                    .map(str::to_lowercase)
                    .as_deref()
                    == Some("boxsets")
            })
        };
        folder(with_hidden) && !folder(visible)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_model::Source;

    fn text(art: &str, n: i64) -> String {
        ItemCollection::count_text(art, n, &Source)
    }
    fn member(id: &str, kind: &str) -> Item {
        Item::new(id, id, Some(kind))
    }

    #[test]
    fn series_in_tvshows_movies_else() {
        assert!(text("tvshows", 3).contains('3'));
        assert!(text("movies", 3).contains('3'));
        assert_ne!(text("movies", 3), text("tvshows", 3));
    }
    #[test]
    fn art_case_is_irrelevant() {
        assert_eq!(text("TVShows", 1), text("tvshows", 1));
    }
    #[test]
    fn singular_and_plural_differ() {
        assert_ne!(text("movies", 1), text("movies", 2));
        assert_ne!(text("tvshows", 1), text("tvshows", 2));
    }
    #[test]
    fn threshold_and_membership() {
        let big = ItemCollection::new(
            Item::new("c1", "Trilogie", Some("BoxSet")),
            &[
                member("m1", "Movie"),
                member("m2", "Movie"),
                member("s1", "Series"),
            ],
        );
        let small = ItemCollection::new(
            Item::new("c2", "Eins", Some("BoxSet")),
            &[member("m9", "Movie")],
        );
        let dir = CollectionDirectory {
            all: vec![big, small],
        };
        assert_eq!(
            dir.collections("movies")
                .iter()
                .map(|c| c.id())
                .collect::<Vec<_>>(),
            ["c1"]
        );
        assert!(dir.collections("tvshows").is_empty());
        assert_eq!(dir.collections_with(&member("m1", "Movie")).len(), 1);
        assert!(dir.collections_with(&member("s1", "Series")).is_empty());
        assert!(dir.collections_with(&member("m9", "Movie")).is_empty());
        assert!(dir.collections_with(&member("e", "Episode")).is_empty());
    }
    #[test]
    fn hidden_collections_folder() {
        let folder = Item {
            collection_type: Some("boxsets".into()),
            ..Item::new("b", "Sammlungen", None)
        };
        assert!(CollectionDirectory::hidden(
            &[],
            std::slice::from_ref(&folder)
        ));
        assert!(!CollectionDirectory::hidden(
            std::slice::from_ref(&folder),
            std::slice::from_ref(&folder)
        ));
        assert!(!CollectionDirectory::hidden(&[], &[]));
    }
}
