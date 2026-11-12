//! What the title menu of a library page lists and what the letter strip is made of (`SectionOffering` and
//! `AlphabetIndex` as `macOS/LibraryView.swift` and `Shared/LibraryModel.swift` use them). Pure functions; the
//! [`LibraryVm`](crate::LibraryVm) holds the state.

use swiftly_library::ShelfSource;
use swiftly_library::library_filter::Sorting;
use swiftly_model::Item;
use swiftly_playback::section_offering::{SectionOffering, SectionSelection};
use swiftly_rules::alphabet_index::{AlphabetIndex, IndexItem, Sorting as IndexSorting};

/// One row of the title menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListEntry {
    /// `SectionSelection.rememberValue` ("alle", "sammlungen", "wiedergabelisten" or a library id).
    pub key: String,
    /// "Alle Filme", "Sammlungen", "Wiedergabelisten" or the library's name.
    pub label: String,
    /// The current choice.
    pub selected: bool,
    /// A section header before the row ("Bibliotheken" before the first library).
    pub category: Option<String>,
}

/// The title menu of a page: the entries (only when there is more than "All") and the heading.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryList {
    /// Heading: "Filme"/"Serien" for "All", else the label of the choice.
    pub title: String,
    /// The rows; the title is only a menu when `is_menu`.
    pub entries: Vec<ListEntry>,
    /// Remember value of the choice.
    pub choice: String,
    /// More than one entry exists (`SectionOffering.isMenu`).
    pub is_menu: bool,
    /// The grid shows collection or playlist cards instead of titles.
    pub cards: bool,
}

/// The label of a selection (`label(_:)` in `LibraryView.swift`).
pub fn selection_label(offering: &SectionOffering, selection: &SectionSelection) -> String {
    let series = offering.art.eq_ignore_ascii_case("tvshows");
    match selection {
        SectionSelection::All => if series { "Alle Serien" } else { "Alle Filme" }.to_owned(),
        SectionSelection::Collections => "Sammlungen".to_owned(),
        SectionSelection::Playlists => "Wiedergabelisten".to_owned(),
        SectionSelection::Library(id) => offering
            .library(id)
            .map(|l| l.name.clone())
            .unwrap_or_default(),
    }
}

/// The menu for `choice`.
pub fn library_list(offering: &SectionOffering, choice: &SectionSelection) -> LibraryList {
    let series = offering.art.eq_ignore_ascii_case("tvshows");
    let first = offering.first_library();
    let entries = offering
        .entries()
        .into_iter()
        .map(|e| ListEntry {
            key: e.remember_value(),
            label: selection_label(offering, &e),
            selected: &e == choice,
            category: (Some(&e) == first.as_ref()).then(|| "Bibliotheken".to_owned()),
        })
        .collect();
    LibraryList {
        title: if *choice == SectionSelection::All {
            if series { "Serien" } else { "Filme" }.to_owned()
        } else {
            selection_label(offering, choice)
        },
        entries,
        choice: choice.remember_value(),
        is_menu: offering.is_menu(),
        cards: matches!(
            choice,
            SectionSelection::Collections | SectionSelection::Playlists
        ),
    }
}

/// What the grid reads from for a choice (`LibraryView.source`); `None` for the card lists and an empty area.
pub fn source_for(offering: &SectionOffering, choice: &SectionSelection) -> Option<ShelfSource> {
    let art = Some(offering.art.as_str());
    match choice {
        SectionSelection::All => offering.has_inventory().then(|| {
            let out = offering.all_out();
            let all = offering.all_sources();
            let only: Vec<&str> = if out.is_none() {
                all.iter().map(String::as_str).collect()
            } else {
                Vec::new()
            };
            ShelfSource::new(out.as_deref(), art, false, &only)
        }),
        SectionSelection::Library(id) => Some(ShelfSource::new(Some(id), art, false, &[])),
        SectionSelection::Collections | SectionSelection::Playlists => None,
    }
}

/// The strip of a list in the server's order (`LibraryModel.alphabet`).
pub fn alphabet(items: &[Item], sorting: Sorting) -> AlphabetIndex {
    let rows: Vec<IndexItem> = items.iter().map(index_item).collect();
    let sorting = match sorting {
        Sorting::Name => IndexSorting::Name,
        Sorting::Latest => IndexSorting::Latest,
        Sorting::Rating => IndexSorting::Rating,
        Sorting::Erscheinung => IndexSorting::Erscheinung,
    };
    AlphabetIndex::from_items(&rows, sorting, &SHORT_MONTHS)
}

/// `Calendar.shortMonthSymbols` of the German locale.
pub const SHORT_MONTHS: [&str; 12] = [
    "Jan.",
    "Feb.",
    "M\u{E4}rz",
    "Apr.",
    "Mai",
    "Juni",
    "Juli",
    "Aug.",
    "Sept.",
    "Okt.",
    "Nov.",
    "Dez.",
];

/// The fields of an item the strip reads.
pub fn index_item(i: &Item) -> IndexItem {
    IndexItem {
        name: i.name.clone(),
        sort_name: i.sort_name.clone(),
        premiere_date: i.premiere_date.clone(),
        production_year: i.production_year,
        community_rating: i.community_rating,
        date_created: i.date_created.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lib(id: &str, name: &str, kind: Option<&str>) -> Item {
        Item {
            id: id.into(),
            name: name.into(),
            collection_type: kind.map(Into::into),
            ..Item::default()
        }
    }

    fn two_movie_libraries() -> SectionOffering {
        SectionOffering::new(
            "movies",
            vec![
                lib("a", "Kino", Some("movies")),
                lib("b", "Archiv", Some("movies")),
            ],
            0,
            0,
        )
    }

    #[test]
    fn labels_follow_the_kind_of_the_section() {
        let movies = two_movie_libraries();
        let series = SectionOffering::new("TVShows", vec![], 0, 0);
        assert_eq!(
            selection_label(&movies, &SectionSelection::All),
            "Alle Filme"
        );
        // The art is compared without regard to case.
        assert_eq!(
            selection_label(&series, &SectionSelection::All),
            "Alle Serien"
        );
        assert_eq!(
            selection_label(&movies, &SectionSelection::Collections),
            "Sammlungen"
        );
        assert_eq!(
            selection_label(&movies, &SectionSelection::Playlists),
            "Wiedergabelisten"
        );
        assert_eq!(
            selection_label(&movies, &SectionSelection::Library("b".into())),
            "Archiv"
        );
        // A library that vanished has no name rather than a wrong one.
        assert_eq!(
            selection_label(&movies, &SectionSelection::Library("gone".into())),
            ""
        );
    }

    #[test]
    fn a_single_library_is_no_menu_and_shows_only_all() {
        let one = SectionOffering::new("movies", vec![lib("a", "Kino", Some("movies"))], 0, 0);
        let list = library_list(&one, &SectionSelection::All);
        assert!(!list.is_menu);
        assert_eq!(list.title, "Filme");
        assert_eq!(list.choice, "alle");
        assert!(!list.cards);
        assert_eq!(list.entries.len(), 1);
        assert_eq!(
            list.entries[0],
            ListEntry {
                key: "alle".into(),
                label: "Alle Filme".into(),
                selected: true,
                category: None
            }
        );
    }

    #[test]
    fn the_menu_lists_all_cards_and_libraries_with_one_heading() {
        let offering = SectionOffering::new(
            "tvshows",
            vec![
                lib("a", "Serien 1", Some("tvshows")),
                lib("b", "Serien 2", Some("tvshows")),
            ],
            2,
            1,
        );
        let list = library_list(&offering, &SectionSelection::Library("b".into()));
        assert!(list.is_menu);
        assert_eq!(list.title, "Serien 2");
        assert_eq!(list.choice, "b");
        assert!(!list.cards);
        let keys: Vec<&str> = list.entries.iter().map(|e| e.key.as_str()).collect();
        assert_eq!(keys, ["alle", "sammlungen", "wiedergabelisten", "a", "b"]);
        let labels: Vec<&str> = list.entries.iter().map(|e| e.label.as_str()).collect();
        assert_eq!(
            labels,
            [
                "Alle Serien",
                "Sammlungen",
                "Wiedergabelisten",
                "Serien 1",
                "Serien 2"
            ]
        );
        // Exactly one row is selected, and only the first library carries the heading.
        assert_eq!(list.entries.iter().filter(|e| e.selected).count(), 1);
        assert!(list.entries[4].selected);
        let headed: Vec<&str> = list
            .entries
            .iter()
            .filter(|e| e.category.is_some())
            .map(|e| e.key.as_str())
            .collect();
        assert_eq!(headed, ["a"]);
        assert_eq!(list.entries[3].category.as_deref(), Some("Bibliotheken"));
    }

    #[test]
    fn collection_and_playlist_choices_show_cards_and_use_their_label_as_title() {
        let offering = SectionOffering::new("movies", vec![lib("a", "Kino", Some("movies"))], 3, 2);
        let collections = library_list(&offering, &SectionSelection::Collections);
        assert!(collections.cards && collections.is_menu);
        assert_eq!(collections.title, "Sammlungen");
        assert_eq!(collections.choice, "sammlungen");
        let playlists = library_list(&offering, &SectionSelection::Playlists);
        assert!(playlists.cards);
        assert_eq!(playlists.title, "Wiedergabelisten");
        // A single library never shows a heading: it is not offered as a choice.
        assert!(playlists.entries.iter().all(|e| e.category.is_none()));
    }

    #[test]
    fn a_choice_that_is_not_offered_selects_nothing() {
        let list = library_list(&two_movie_libraries(), &SectionSelection::Collections);
        assert!(list.entries.iter().all(|e| !e.selected));
    }

    #[test]
    fn the_source_of_all_reads_one_library_directly() {
        let one = SectionOffering::new("movies", vec![lib("a", "Kino", Some("movies"))], 0, 0);
        assert_eq!(
            source_for(&one, &SectionSelection::All),
            Some(ShelfSource::new(Some("a"), Some("movies"), false, &[]))
        );
    }

    #[test]
    fn the_source_of_all_filters_across_several_libraries() {
        let source = source_for(&two_movie_libraries(), &SectionSelection::All).expect("source");
        assert_eq!(
            source,
            ShelfSource::new(None, Some("movies"), false, &["a", "b"])
        );
        assert!(source.is_filtering());
    }

    #[test]
    fn a_mixed_library_counts_for_all_only_without_a_library_of_its_own() {
        let mixed = lib("m", "Gemischt", Some("mixed"));
        let own = lib("o", "Filme", Some("movies"));
        let with_own = SectionOffering::new("movies", vec![mixed.clone(), own], 0, 0);
        assert_eq!(
            source_for(&with_own, &SectionSelection::All),
            Some(ShelfSource::new(Some("o"), Some("movies"), false, &[]))
        );
        let only_mixed = SectionOffering::new("movies", vec![mixed], 0, 0);
        assert_eq!(
            source_for(&only_mixed, &SectionSelection::All),
            Some(ShelfSource::new(Some("m"), Some("movies"), false, &[]))
        );
    }

    #[test]
    fn an_empty_section_has_no_source_for_all() {
        let none = SectionOffering::new("movies", vec![], 0, 0);
        assert_eq!(source_for(&none, &SectionSelection::All), None);
        // A named library is read as asked, even when the offering does not list it.
        assert_eq!(
            source_for(&none, &SectionSelection::Library("x".into())),
            Some(ShelfSource::new(Some("x"), Some("movies"), false, &[]))
        );
    }

    #[test]
    fn card_lists_have_no_source() {
        let offering = two_movie_libraries();
        assert_eq!(source_for(&offering, &SectionSelection::Collections), None);
        assert_eq!(source_for(&offering, &SectionSelection::Playlists), None);
    }

    fn titled(name: &str) -> Item {
        Item {
            name: name.into(),
            ..Item::default()
        }
    }

    #[test]
    fn the_name_strip_has_one_entry_per_first_letter_in_list_order() {
        let items = [
            titled("Alpha"),
            titled("Anna"),
            titled("Berta"),
            titled("Zed"),
        ];
        let index = alphabet(&items, Sorting::Name);
        assert_eq!(index.count, 4);
        let letters: Vec<(&str, usize)> = index
            .entries
            .iter()
            .map(|e| (e.letter.as_str(), e.first))
            .collect();
        assert_eq!(letters, [("A", 0), ("B", 2), ("Z", 3)]);
        assert!(index.is_useful());
        assert!(!alphabet(&[titled("Alpha"), titled("Anna")], Sorting::Name).is_useful());
        assert_eq!(alphabet(&[], Sorting::Name).count, 0);
    }

    #[test]
    fn the_name_strip_prefers_the_sort_name() {
        let item = Item {
            name: "The Adam Project".into(),
            sort_name: Some("Adam Project".into()),
            ..Item::default()
        };
        assert_eq!(alphabet(&[item], Sorting::Name).entries[0].letter, "A");
    }

    #[test]
    fn the_rating_strip_truncates_and_marks_unrated_titles() {
        let rated = |r: Option<f64>| Item {
            name: "x".into(),
            community_rating: r,
            ..Item::default()
        };
        let index = alphabet(
            &[
                rated(Some(8.7)),
                rated(Some(8.1)),
                rated(Some(6.0)),
                rated(None),
            ],
            Sorting::Rating,
        );
        let keys: Vec<&str> = index.entries.iter().map(|e| e.letter.as_str()).collect();
        assert_eq!(keys, ["r8", "r6", "\u{2014}"]);
        assert_eq!(index.entries[0].label, "8");
        assert_eq!(index.entries[1].first, 2);
        assert!(index.entries[1].gap && !index.entries[0].gap);
    }

    #[test]
    fn the_release_strip_uses_the_premiere_date_before_the_production_year() {
        let film = |premiere: Option<&str>, year: Option<i64>| Item {
            name: "x".into(),
            premiere_date: premiere.map(Into::into),
            production_year: year,
            ..Item::default()
        };
        let index = alphabet(
            &[
                film(Some("2024-05-01T00:00:00Z"), Some(1999)),
                film(None, Some(2020)),
                film(None, None),
            ],
            Sorting::Erscheinung,
        );
        let keys: Vec<&str> = index.entries.iter().map(|e| e.letter.as_str()).collect();
        assert_eq!(keys, ["2024", "2020", "\u{2014}"]);
        assert_eq!(index.entries[0].label, "24");
    }

    #[test]
    fn the_latest_strip_switches_to_german_months_within_a_single_year() {
        let added = |d: &str| Item {
            name: "x".into(),
            date_created: Some(d.into()),
            ..Item::default()
        };
        let one_year = alphabet(
            &[added("2025-03-02T10:00:00Z"), added("2025-01-15T10:00:00Z")],
            Sorting::Latest,
        );
        assert!(one_year.monthly);
        let keys: Vec<&str> = one_year.entries.iter().map(|e| e.letter.as_str()).collect();
        assert_eq!(keys, ["2025-03", "2025-01"]);
        assert_eq!(one_year.entries[0].label, "M\u{E4}rz 25");
        assert_eq!(one_year.entries[1].label, "Jan 25");
        let two_years = alphabet(
            &[added("2025-03-02T10:00:00Z"), added("2024-01-15T10:00:00Z")],
            Sorting::Latest,
        );
        assert!(!two_years.monthly);
        let keys: Vec<&str> = two_years
            .entries
            .iter()
            .map(|e| e.letter.as_str())
            .collect();
        assert_eq!(keys, ["2025", "2024"]);
    }

    #[test]
    fn index_item_copies_exactly_the_fields_the_strip_reads() {
        let item = Item {
            id: "ignored".into(),
            name: "N".into(),
            sort_name: Some("S".into()),
            premiere_date: Some("2020-01-01".into()),
            production_year: Some(2019),
            community_rating: Some(7.5),
            date_created: Some("2021-02-02".into()),
            ..Item::default()
        };
        let row = index_item(&item);
        assert_eq!(row.name, "N");
        assert_eq!(row.sort_name.as_deref(), Some("S"));
        assert_eq!(row.premiere_date.as_deref(), Some("2020-01-01"));
        assert_eq!(row.production_year, Some(2019));
        assert_eq!(row.community_rating, Some(7.5));
        assert_eq!(row.date_created.as_deref(), Some("2021-02-02"));
        assert_eq!(SHORT_MONTHS.len(), 12);
        assert_eq!(SHORT_MONTHS[2], "M\u{E4}rz");
    }
}
