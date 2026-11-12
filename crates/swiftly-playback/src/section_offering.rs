//! Port of `Packages/JellyfinKit/Sources/JellyfinKit/SectionOffering.swift`: what the title menu
//! of "Movies" / "Series" offers (`SectionSelection`, `SectionOffering`).
//!
//! The rest of that Swift file already lives in `swiftly-library` and is reused, not
//! duplicated: `LibraryShare` and `LibraryGenre` (`library_genre`), `ShelfSource` and
//! `TitleFilter` (`shelf`), `CollectionDirectory` and `PlaylistDirectory`. The tests of those
//! types from `SectionOfferingTests.swift` are translated at the end of this module against
//! the `swiftly-library` types.

use std::collections::HashMap;

use swiftly_library::{CollectionDirectory, LibraryGenre, LibraryShare, PlaylistDirectory};
use swiftly_model::Item;

/// A choice in the menu on the title of "Movies" or "Series" (SectionOffering.swift:10-45).
/// Collections are not a library; they sit directly under "All".
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SectionSelection {
    /// Every title of this kind from every library. The default.
    All,
    /// The collections (Jellyfin: `BoxSet`) with titles of this kind.
    Collections,
    /// The video playlists with entries of this kind.
    Playlists,
    /// A single library, by its ID.
    Library(String),
}

impl SectionSelection {
    /// `id` (SectionOffering.swift:21).
    pub fn id(&self) -> String {
        self.remember_value()
    }

    /// How the choice is persisted (SectionOffering.swift:28-35): under the same name the
    /// library had before (its ID).
    pub fn remember_value(&self) -> String {
        match self {
            Self::All => "alle".into(),
            Self::Collections => "sammlungen".into(),
            Self::Playlists => "wiedergabelisten".into(),
            Self::Library(id) => id.clone(),
        }
    }

    /// `init(rememberValue:)` (SectionOffering.swift:37-44). `None` and the empty string are
    /// "All".
    pub fn from_remember_value(remember_value: Option<&str>) -> Self {
        match remember_value {
            None | Some("") | Some("alle") => Self::All,
            Some("sammlungen") => Self::Collections,
            Some("wiedergabelisten") => Self::Playlists,
            Some(id) => Self::Library(id.into()),
        }
    }
}

/// What the title of a section offers to choose, and whether it is a menu at all
/// (SectionOffering.swift:79-178). The title becomes a menu as soon as there is more than one
/// thing to choose. Order: "All", "Collections", "Playlists", then the single libraries in the
/// server's order.
#[derive(Debug, Clone, PartialEq)]
pub struct SectionOffering {
    /// `movies` or `tvshows`.
    pub art: String,
    /// Every library with titles of this kind, even a single one.
    pub libraries: Vec<Item>,
    /// How many collections, from the threshold up, are in this section.
    pub collections: usize,
    /// How many video playlists have entries of this kind.
    pub playlists: usize,
}

impl SectionOffering {
    /// `init(art:libraries:collections:playlists:)` (SectionOffering.swift:90).
    pub fn new(art: &str, libraries: Vec<Item>, collections: usize, playlists: usize) -> Self {
        Self {
            art: art.into(),
            libraries,
            collections,
            playlists,
        }
    }

    /// A single library is not a choice: it showed the same as "All" (SectionOffering.swift:99).
    pub fn shows_libraries(&self) -> bool {
        self.libraries.len() > 1
    }

    /// SectionOffering.swift:100.
    pub fn shows_collections(&self) -> bool {
        self.collections > 0
    }

    /// SectionOffering.swift:101.
    pub fn shows_playlists(&self) -> bool {
        self.playlists > 0
    }

    /// SectionOffering.swift:102.
    pub fn is_menu(&self) -> bool {
        self.shows_libraries() || self.shows_collections() || self.shows_playlists()
    }

    /// The menu entries in order (SectionOffering.swift:104-110).
    pub fn entries(&self) -> Vec<SectionSelection> {
        let mut list = vec![SectionSelection::All];
        if self.shows_collections() {
            list.push(SectionSelection::Collections);
        }
        if self.shows_playlists() {
            list.push(SectionSelection::Playlists);
        }
        if self.shows_libraries() {
            list.extend(
                self.libraries
                    .iter()
                    .map(|l| SectionSelection::Library(l.id.clone())),
            );
        }
        list
    }

    /// Before which entry the divider and the "Libraries" heading go: before the first library,
    /// if the menu has any (SectionOffering.swift:114-116).
    pub fn first_library(&self) -> Option<SectionSelection> {
        if self.shows_libraries() {
            self.libraries
                .first()
                .map(|l| SectionSelection::Library(l.id.clone()))
        } else {
            None
        }
    }

    /// The library with this id (SectionOffering.swift:118-120).
    pub fn library(&self, id: &str) -> Option<&Item> {
        self.libraries.iter().find(|l| l.id == id)
    }

    /// The remembered choice if it still exists, otherwise "All" (SectionOffering.swift:126-129).
    pub fn choice(&self, remembered: Option<&str>) -> SectionSelection {
        let wish = SectionSelection::from_remember_value(remembered);
        if self.entries().contains(&wish) {
            wish
        } else {
            SectionSelection::All
        }
    }

    /// What "All" reads from: the libraries of this kind, not the mixed ones. A mixed library
    /// counts toward "All" only if the section has no library of its own
    /// (SectionOffering.swift:138-141).
    pub fn all_sources(&self) -> Vec<String> {
        let art = self.art.to_lowercase();
        let own_ones: Vec<&Item> = self
            .libraries
            .iter()
            .filter(|l| {
                l.collection_type
                    .as_deref()
                    .map(str::to_lowercase)
                    .as_deref()
                    == Some(art.as_str())
            })
            .collect();
        let chosen: Vec<&Item> = if own_ones.is_empty() {
            self.libraries.iter().collect()
        } else {
            own_ones
        };
        chosen.into_iter().map(|l| l.id.clone()).collect()
    }

    /// The one library, if "All" reads from only one; otherwise `None`
    /// (SectionOffering.swift:145-147).
    pub fn all_out(&self) -> Option<String> {
        let sources = self.all_sources();
        if sources.len() == 1 {
            sources.into_iter().next()
        } else {
            None
        }
    }

    /// Whether there is anything to show in this section at all (SectionOffering.swift:150).
    pub fn has_inventory(&self) -> bool {
        !self.libraries.is_empty()
    }

    /// `compose` (SectionOffering.swift:158-166). `views` are the account's libraries
    /// (`UserViews`), `shares` the movies and series per mixed library (a missing one appears
    /// nowhere), `directory` the collections (`None` while unknown).
    pub fn compose(
        art: &str,
        views: &[Item],
        shares: &HashMap<String, LibraryShare>,
        directory: Option<&CollectionDirectory>,
        playlists: Option<&PlaylistDirectory>,
    ) -> Self {
        let matching: Vec<Item> = views
            .iter()
            .filter(|v| Self::belongs(v, art, shares))
            .cloned()
            .collect();
        Self {
            art: art.into(),
            libraries: matching,
            collections: directory.map_or(0, |d| d.collections(art).len()),
            playlists: playlists.map_or(0, |p| p.playlists(art).len()),
        }
    }

    /// A mixed library appears in both sections, but only where it has something
    /// (SectionOffering.swift:171-177).
    pub fn belongs(view: &Item, toward: &str, shares: &HashMap<String, LibraryShare>) -> bool {
        let kind = view.collection_type.as_deref().map(str::to_lowercase);
        if kind.as_deref() == Some(toward.to_lowercase().as_str()) {
            return true;
        }
        if !LibraryGenre::can_be_mixed(kind.as_deref()) {
            return false;
        }
        shares.get(&view.id).map_or(0, |s| s.count(toward)) > 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_library::library_filter::{Sorting, SortingExt};
    use swiftly_library::{ItemCollection, ShelfSource, TitleFilter};

    fn view(id: &str, name: &str, collection_type: Option<&str>) -> Item {
        Item {
            collection_type: collection_type.map(Into::into),
            ..Item::new(id, name, None)
        }
    }
    fn movies() -> Item {
        view("f", "Filme", Some("movies"))
    }
    fn series_list() -> Item {
        view("s", "Serien", Some("tvshows"))
    }
    fn docs() -> Item {
        view("d", "Dokus", None)
    }
    fn second_movies() -> Item {
        view("f2", "Filmabend", Some("movies"))
    }
    fn music() -> Item {
        view("m", "Musik", Some("music"))
    }
    fn home_base() -> Item {
        view("h", "Heimvideos", Some("homevideos"))
    }
    fn folder() -> Item {
        view("b", "Sammlungen", Some("boxsets"))
    }

    fn container(id: &str, movie_count: usize, series_count: usize) -> ItemCollection {
        let f = (0..movie_count).map(|i| Item::new(format!("{id}-f{i}"), "", Some("Movie")));
        let s = (0..series_count).map(|i| Item::new(format!("{id}-s{i}"), "", Some("Series")));
        let members: Vec<Item> = f.chain(s).collect();
        ItemCollection::new(Item::new(id, id, Some("BoxSet")), &members)
    }

    fn compose(
        art: &str,
        views: &[Item],
        shares: &[(&str, LibraryShare)],
        directory: Option<&CollectionDirectory>,
    ) -> SectionOffering {
        let shares: HashMap<String, LibraryShare> =
            shares.iter().map(|(k, v)| ((*k).to_string(), *v)).collect();
        SectionOffering::compose(art, views, &shares, directory, None)
    }

    fn share(movies: i64, series_list: i64) -> LibraryShare {
        LibraryShare {
            movies,
            series_list,
        }
    }

    fn lib(id: &str) -> SectionSelection {
        SectionSelection::Library(id.into())
    }

    // MARK: SectionOfferingTests (8)

    #[test]
    fn not_select() {
        let views = [movies(), series_list(), music()];
        let empty = CollectionDirectory { all: vec![] };
        for art in ["movies", "tvshows"] {
            let a = compose(art, &views, &[], Some(&empty));
            assert!(!a.is_menu());
            assert_eq!(a.entries(), [SectionSelection::All]);
            assert_eq!(a.libraries.len(), 1);
        }
        // "All" then reads from exactly that one library, the same query as before the rework.
        let a = compose("movies", &views, &[], None);
        assert_eq!(a.all_out().as_deref(), Some("f"));
    }

    #[test]
    fn two_libraries() {
        let a = compose(
            "movies",
            &[movies(), series_list(), second_movies()],
            &[],
            None,
        );
        assert!(a.is_menu());
        assert_eq!(a.entries(), [SectionSelection::All, lib("f"), lib("f2")]);
        assert_eq!(a.first_library(), Some(lib("f")));
        assert_eq!(a.all_out(), None);
    }

    #[test]
    fn collections_pre_libraries() {
        let directory = CollectionDirectory {
            all: vec![container("hp", 8, 0)],
        };
        let a = compose(
            "movies",
            &[movies(), second_movies(), folder()],
            &[],
            Some(&directory),
        );
        assert_eq!(
            a.entries(),
            [
                SectionSelection::All,
                SectionSelection::Collections,
                lib("f"),
                lib("f2")
            ]
        );
    }

    #[test]
    fn only_collections() {
        let directory = CollectionDirectory {
            all: vec![container("hp", 8, 0)],
        };
        let views = [movies(), series_list(), folder()];
        let a = compose("movies", &views, &[], Some(&directory));
        assert_eq!(
            a.entries(),
            [SectionSelection::All, SectionSelection::Collections]
        );
        assert_eq!(a.first_library(), None);
        // Under series there is no collection with series, so no menu.
        let s = compose("tvshows", &views, &[], Some(&directory));
        assert!(!s.is_menu());
    }

    #[test]
    fn mixed() {
        let views = [movies(), series_list(), docs()];
        let both = [("d", share(38, 6))];
        let f = compose("movies", &views, &both, None);
        let s = compose("tvshows", &views, &both, None);
        assert_eq!(f.entries(), [SectionSelection::All, lib("f"), lib("d")]);
        assert_eq!(s.entries(), [SectionSelection::All, lib("s"), lib("d")]);

        // Without series it appears only under movies.
        let only_movies = [("d", share(38, 0))];
        let s2 = compose("tvshows", &views, &only_movies, None);
        assert!(!s2.is_menu());

        // Not counted yet: it appears nowhere (yet).
        let f3 = compose("movies", &views, &[], None);
        assert!(!f3.is_menu());
    }

    #[test]
    fn no_special_types() {
        assert!(LibraryGenre::can_be_mixed(None));
        assert!(LibraryGenre::can_be_mixed(Some("mixed")));
        assert!(LibraryGenre::can_be_mixed(Some("homevideos")));
        assert!(!LibraryGenre::can_be_mixed(Some("movies")));
        assert!(!LibraryGenre::can_be_mixed(Some("music")));
        assert!(!LibraryGenre::can_be_mixed(Some("BoxSets")));
        // Home videos without movies appear nowhere, without anyone having to forbid it.
        let a = compose(
            "movies",
            &[movies(), home_base()],
            &[("h", share(0, 0))],
            None,
        );
        assert!(!a.is_menu());
    }

    #[test]
    fn remembered() {
        let directory = CollectionDirectory {
            all: vec![container("hp", 8, 0)],
        };
        let a = compose(
            "movies",
            &[movies(), second_movies()],
            &[],
            Some(&directory),
        );
        assert_eq!(a.choice(None), SectionSelection::All);
        assert_eq!(a.choice(Some("f2")), lib("f2"));
        assert_eq!(a.choice(Some("sammlungen")), SectionSelection::Collections);
        assert_eq!(a.choice(Some("weg")), SectionSelection::All);
        // A single library is no longer a choice.
        let b = compose("movies", &[movies()], &[], None);
        assert_eq!(b.choice(Some("f")), SectionSelection::All);
        assert_eq!(b.choice(Some("sammlungen")), SectionSelection::All);
    }

    #[test]
    fn remember_value() {
        for w in [
            SectionSelection::All,
            SectionSelection::Collections,
            lib("abc"),
        ] {
            assert_eq!(
                SectionSelection::from_remember_value(Some(&w.remember_value())),
                w
            );
        }
    }

    // MARK: CollectionDirectoryTests (3), reusing swiftly_library::CollectionDirectory

    fn container_with(id: &str, movies: &[&str], series_list: &[&str]) -> ItemCollection {
        let mut members: Vec<Item> = movies
            .iter()
            .map(|m| Item::new(*m, *m, Some("Movie")))
            .collect();
        members.extend(
            series_list
                .iter()
                .map(|s| Item::new(*s, *s, Some("Series"))),
        );
        members.push(Item::new("folge", "", Some("Episode")));
        ItemCollection::new(Item::new(id, id, Some("BoxSet")), &members)
    }

    fn ids(list: Vec<&ItemCollection>) -> Vec<String> {
        list.iter().map(|c| c.id().to_string()).collect()
    }

    #[test]
    fn threshold() {
        let v = CollectionDirectory {
            all: vec![
                container_with("eins", &["a"], &[]),
                container_with("zwei", &["a", "b"], &[]),
                container_with("gemischt", &["c"], &["x", "y"]),
            ],
        };
        assert_eq!(ids(v.collections("movies")), ["zwei"]);
        assert_eq!(ids(v.collections("tvshows")), ["gemischt"]);
        assert!(v.collections("music").is_empty());
    }

    #[test]
    fn membership() {
        let v = CollectionDirectory {
            all: vec![
                container_with("hp", &["hp1", "hp2", "hp3"], &[]),
                container_with("allein", &["hp1"], &[]),
                container_with("gemischt", &["hp1"], &["x", "y"]),
            ],
        };
        assert_eq!(
            ids(v.collections_with(&Item::new("hp1", "", Some("Movie")))),
            ["hp"]
        );
        assert_eq!(
            ids(v.collections_with(&Item::new("x", "", Some("Series")))),
            ["gemischt"]
        );
        assert!(
            v.collections_with(&Item::new("zz", "", Some("Movie")))
                .is_empty()
        );
        // Episodes belong to no section.
        assert!(
            v.collections_with(&Item::new("folge", "", Some("Episode")))
                .is_empty()
        );
    }

    #[test]
    fn hidden() {
        let film = view("f", "", Some("movies"));
        let box_folder = view("b", "", Some("boxsets"));
        assert!(CollectionDirectory::hidden(
            std::slice::from_ref(&film),
            &[film.clone(), box_folder.clone()]
        ));
        assert!(!CollectionDirectory::hidden(
            &[film.clone(), box_folder.clone()],
            &[film.clone(), box_folder]
        ));
        // Jellyfin 12 on the test server: the folder appears in neither of the two.
        assert!(!CollectionDirectory::hidden(
            std::slice::from_ref(&film),
            std::slice::from_ref(&film)
        ));
    }

    // MARK: ShelfSourceTests (3), reusing swiftly_library::ShelfSource

    #[test]
    fn library() {
        let q = ShelfSource::new(Some("f"), Some("movies"), false, &[]);
        assert_eq!(q.types(), ["Movie"]);
        assert!(q.recursive());
        assert_eq!(q.bearing(Sorting::Erscheinung), "Descending");
    }

    #[test]
    fn all() {
        let q = ShelfSource::new(None, Some("tvshows"), false, &[]);
        assert_eq!(q.types(), ["Series"]);
        assert!(q.recursive());
    }

    #[test]
    fn collection() {
        let q = ShelfSource::new(Some("hp"), Some("movies"), true, &[]);
        assert_eq!(q.types(), ["Movie"]);
        assert!(!q.recursive());
        assert_eq!(q.bearing(Sorting::Erscheinung), "Ascending");
        assert_eq!(q.bearing(Sorting::Name), "Ascending");
        assert_eq!(q.bearing(Sorting::Latest), "Descending");
        assert_ne!(
            q.key(),
            ShelfSource::new(Some("hp"), Some("movies"), false, &[]).key()
        );
        // `Sorting` raw values are untouched by this module (SortingExt keeps them).
        assert_eq!(Sorting::Name.raw_value(), "name");
    }

    // MARK: AllOutMultipleTests (4), reusing TitleFilter/ShelfSource

    fn film(id: &str, name: &str, tmdb: Option<&str>) -> Item {
        Item {
            production_year: Some(2026),
            provider_ids: tmdb.map(|t| [("Tmdb".to_string(), t.to_string())].into()),
            ..Item::new(id, name, Some("Movie"))
        }
    }

    #[test]
    fn without_mixed() {
        let views = [
            view("f", "Filme", Some("movies")),
            view("k", "Kinoabend", Some("movies")),
            view("m", "Mixed", None),
        ];
        let a = compose("movies", &views, &[("m", share(13, 0))], None);
        // The menu lists the mixed one, "All" does not.
        assert!(a.entries().contains(&lib("m")));
        assert_eq!(a.all_sources(), ["f", "k"]);
        assert_eq!(a.all_out(), None);
        // If only the mixed one exists, "All" reads from it.
        let b = compose(
            "movies",
            std::slice::from_ref(&views[2]),
            &[("m", share(13, 0))],
            None,
        );
        assert_eq!(b.all_out().as_deref(), Some("m"));
    }

    #[test]
    fn filter_ref() {
        // As on the test server: the same movie from three libraries.
        let allowed = [
            film("f1", "Toy Story 5", Some("1")),
            film("k1", "Toy Story 5", Some("1")),
            film("f2", "Exit 8", Some("2")),
        ];
        let mut filter_ref = TitleFilter::from_identifiers(&allowed);
        assert_eq!(filter_ref.total, 2);
        let page1 = [
            film("f1", "Toy Story 5", Some("1")),
            film("got", "Game.of.Thrones.S01E01", None),
        ];
        let page2 = [
            film("k1", "Toy Story 5", Some("1")),
            film("f2", "Exit 8", Some("2")),
        ];
        let seven = |f: &mut TitleFilter, page: &[Item]| -> Vec<String> {
            f.sift(page).into_iter().map(|i| i.id).collect()
        };
        assert_eq!(seven(&mut filter_ref, &page1), ["f1"]);
        assert_eq!(seven(&mut filter_ref, &page2), ["f2"]);
        // Which copy stays is decided beforehand, not by which comes first.
        filter_ref.from_front();
        assert_eq!(seven(&mut filter_ref, &page2), ["f2"]);
        assert_eq!(seven(&mut filter_ref, &page1), ["f1"]);
    }

    #[test]
    fn series_list_counts_once() {
        let with_tvdb = |id: &str, name: &str, tvdb: Option<&str>| Item {
            provider_ids: tvdb.map(|t| [("Tvdb".to_string(), t.to_string())].into()),
            ..Item::new(id, name, Some("Series"))
        };
        let a = with_tvdb("a", "FROM", Some("9"));
        let b = with_tvdb("b", "FROM", Some("9"));
        let c = with_tvdb("c", "Dark", None);
        assert_eq!(TitleFilter::from_identifiers(&[a, b, c]).total, 2);
    }

    #[test]
    fn source() {
        assert!(ShelfSource::new(None, Some("movies"), false, &["f", "k"]).is_filtering());
        assert!(!ShelfSource::new(Some("f"), Some("movies"), false, &[]).is_filtering());
    }
}
