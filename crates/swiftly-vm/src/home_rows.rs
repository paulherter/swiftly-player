//! The Home rows of the Appearance page, kept the way the Mac keeps them (`AppModel.startLibraries`, `startOrder`,
//! `startRails`, `startGenres`, `HomeRowOrder`): one combined order of fixed rows and library rows, the libraries
//! chosen per server, the genres chosen once.

use swiftly_library::start_libraries::{StartLibraries, StartLibrary};
use swiftly_library::start_order::library_row_id;
use swiftly_library::{HomeForm, SeerrSection, StartOrder, StartRail};
use swiftly_settings::{KeyValueStore, Settings, StoreError, keys};

/// What one row of the Home group is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HomeRowKind {
    /// A fixed row with a switch.
    Fixed {
        /// The row.
        rail: StartRail,
        /// Shown on the Home page.
        on: bool,
    },
    /// A Seerr section ("Anfrage ist da", "Meine Anfragen") with a switch; only while Seerr is connected.
    Seerr {
        /// The section.
        section: SeerrSection,
        /// Shown on the Start page.
        on: bool,
    },
    /// A chosen library or collection with a remove button.
    Library {
        /// The server's id.
        id: String,
        /// Its name.
        name: String,
        /// A collection, not a library.
        collection: bool,
    },
}

/// One row of the combined list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HomeRowEntry {
    /// The id in the combined order (`StartRail` raw value or `library:<id>`).
    pub id: String,
    /// What it is.
    pub kind: HomeRowKind,
}

/// Everything the Home group and the Genres group show.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HomeView {
    /// The rows in the stored order.
    pub rows: Vec<HomeRowEntry>,
    /// The chosen genres in order.
    pub genres: Vec<String>,
}

/// The chosen libraries of `server`.
pub fn libraries<S: KeyValueStore>(settings: &Settings<S>, server: &str) -> Vec<StartLibrary> {
    let data = settings.get_for_server_only(&keys::START_BIBLIOTHEKEN, server);
    StartLibraries::read(data.as_deref())
}

/// The combined order, healed against the rows that exist (`StartOrder.applicable`).
pub fn order<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    seerr: bool,
    form: HomeForm,
) -> Vec<String> {
    let stored = settings.get_for_server(&keys::START_REIHENFOLGE, server);
    // Empty: the old order of the fixed rows (`HomeRowOrder.effective`), see `migrate_order`.
    let stored =
        StartOrder::carried_over(&stored, &settings.get(&keys::START_REIHEN)).unwrap_or(stored);
    StartOrder::applicable_for(
        &stored,
        settings.get(&keys::NEU_GETRENNT),
        &libraries(settings, server),
        seerr,
        form,
    )
}

/// The one-time migration of the old per-kind order: a user whose combined order was never stored but who has an
/// old `startReihen` order gets that order stored under `startReihenfolge` (per server). Returns whether it stored.
/// Safe to call on every start: once an order is stored it does nothing.
pub fn migrate_order<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
) -> Result<bool, StoreError> {
    let stored = settings.get_for_server(&keys::START_REIHENFOLGE, server);
    let Some(carried) = StartOrder::carried_over(&stored, &settings.get(&keys::START_REIHEN))
    else {
        return Ok(false);
    };
    settings.set_for_server(&keys::START_REIHENFOLGE, server, carried)?;
    Ok(true)
}

/// Whether a Seerr section is switched on: its own setting, and the default when the user never touched it
/// (the arrival banner on, the rail of requests off).
pub fn seerr_on<S: KeyValueStore>(settings: &Settings<S>, section: SeerrSection) -> bool {
    match section {
        SeerrSection::Arrival => settings.get(&keys::SEERR_ARRIVAL_HINT),
        SeerrSection::Requests => settings.get(&keys::SEERR_REQUESTS_RAIL),
    }
}

/// The rows as the page lists them; `seerr`: Seerr is connected (only then its sections are rows).
pub fn view<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    seerr: bool,
    form: HomeForm,
) -> HomeView {
    let off = settings.get(&keys::START_AUS);
    let libs = libraries(settings, server);
    let rows = order(settings, server, seerr, form)
        .into_iter()
        .filter_map(|id| {
            let kind = if let Some(section) = SeerrSection::from_id(&id) {
                HomeRowKind::Seerr {
                    section,
                    on: seerr_on(settings, section),
                }
            } else if let Some(rail) = StartRail::from_raw(&id) {
                HomeRowKind::Fixed {
                    rail,
                    on: !off.iter().any(|o| o == rail.raw_value()),
                }
            } else {
                let lib = libs.iter().find(|l| library_row_id(l) == id)?;
                HomeRowKind::Library {
                    id: lib.id.clone(),
                    name: lib.name.clone(),
                    collection: lib.collection,
                }
            };
            Some(HomeRowEntry { id, kind })
        })
        .collect();
    HomeView {
        rows,
        genres: settings.get(&keys::START_GENRES),
    }
}

/// Stores a new combined order and keeps the fixed rows' own list in step (`AppModel.storeOrder`).
fn store_order<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    moved: Vec<String>,
) -> Result<(), StoreError> {
    let fixed: Vec<String> = moved
        .iter()
        .filter(|o| StartRail::from_raw(o).is_some())
        .cloned()
        .collect();
    let mut rails = fixed.clone();
    rails.extend(
        settings
            .get(&keys::START_REIHEN)
            .into_iter()
            .filter(|r| !fixed.contains(r)),
    );
    settings.set_for_server(&keys::START_REIHENFOLGE, server, moved)?;
    settings.set(&keys::START_REIHEN, rails)
}

/// A drop on a row: `row` takes the place of `target` (`HomeRowOrder.moved(row:onto:)`). Returns whether anything moved.
pub fn drop_row<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    seerr: bool,
    form: HomeForm,
    row: &str,
    target: &str,
) -> Result<bool, StoreError> {
    let list = order(settings, server, seerr, form);
    let (Some(from), Some(to)) = (
        list.iter().position(|r| r == row),
        list.iter().position(|r| r == target),
    ) else {
        return Ok(false);
    };
    if from == to {
        return Ok(false);
    }
    // SwiftUI's `onMove` destination is the insertion index before the move; the row lands on the target's place.
    store_order(settings, server, StartOrder::moved(&list, from, to))?;
    Ok(true)
}

/// Move Up / Move Down among the rows that are shown (`HomeRowOrder.moved(row:by:among:)`): swaps with the visible
/// neighbour, nothing at the ends.
pub fn shift_row<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    seerr: bool,
    form: HomeForm,
    row: &str,
    delta: i32,
) -> Result<bool, StoreError> {
    let shown: Vec<String> = view(settings, server, seerr, form)
        .rows
        .into_iter()
        .map(|r| r.id)
        .collect();
    let Some(at) = shown.iter().position(|r| r == row) else {
        return Ok(false);
    };
    let Some(neighbour) = i64::try_from(at)
        .ok()
        .and_then(|a| usize::try_from(a + i64::from(delta)).ok())
        .and_then(|i| shown.get(i))
    else {
        return Ok(false);
    };
    drop_row(settings, server, seerr, form, row, neighbour)
}

/// Adds a library or collection at the end (`LibrarySelectionView`).
pub fn add_library<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    library: StartLibrary,
) -> Result<(), StoreError> {
    let mut chosen = libraries(settings, server);
    chosen.push(library);
    write_libraries(settings, server, &chosen)
}

/// Removes a chosen library (the x on its row).
pub fn remove_library<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    id: &str,
) -> Result<(), StoreError> {
    let mut chosen = libraries(settings, server);
    chosen.retain(|l| l.id != id);
    write_libraries(settings, server, &chosen)
}

fn write_libraries<S: KeyValueStore>(
    settings: &Settings<S>,
    server: &str,
    chosen: &[StartLibrary],
) -> Result<(), StoreError> {
    settings.set_for_server(
        &keys::START_BIBLIOTHEKEN,
        server,
        Some(StartLibraries::data(chosen).unwrap_or_default()),
    )
}

/// Adds a genre at the end (`GenreSelectionView`); a chosen one is not added twice.
pub fn add_genre<S: KeyValueStore>(settings: &Settings<S>, name: &str) -> Result<(), StoreError> {
    let mut genres = settings.get(&keys::START_GENRES);
    if !genres.iter().any(|g| g == name) {
        genres.push(name.to_owned());
        settings.set(&keys::START_GENRES, genres)?;
    }
    Ok(())
}

/// Removes a genre (the x on its row).
pub fn remove_genre<S: KeyValueStore>(
    settings: &Settings<S>,
    name: &str,
) -> Result<(), StoreError> {
    let mut genres = settings.get(&keys::START_GENRES);
    genres.retain(|g| g != name);
    settings.set(&keys::START_GENRES, genres)
}

/// A genre dropped on another takes its place (`genreStore`).
pub fn drop_genre<S: KeyValueStore>(
    settings: &Settings<S>,
    moved: &str,
    target: &str,
) -> Result<bool, StoreError> {
    let mut genres = settings.get(&keys::START_GENRES);
    let (Some(from), Some(to)) = (
        genres.iter().position(|g| g == moved),
        genres.iter().position(|g| g == target),
    ) else {
        return Ok(false);
    };
    if from == to {
        return Ok(false);
    }
    let name = genres.remove(from);
    genres.insert(to, name);
    settings.set(&keys::START_GENRES, genres)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_settings::MemoryStore;

    fn settings() -> Settings<MemoryStore> {
        Settings::new(MemoryStore::default())
    }

    #[test]
    fn old_fixed_order_moves_into_the_combined_order_once() {
        let s = settings();
        s.set(
            &keys::START_REIHEN,
            vec!["neueSerien".to_owned(), "weiterschauen".to_owned()],
        )
        .unwrap();
        assert!(s.get_for_server(&keys::START_REIHENFOLGE, "srv").is_empty());
        assert!(migrate_order(&s, "srv").unwrap());
        assert_eq!(
            s.get_for_server(&keys::START_REIHENFOLGE, "srv"),
            ["neueSerien", "weiterschauen"]
        );
        // Second call: stored already, nothing happens; a later change of the old list does not win.
        s.set(&keys::START_REIHEN, vec!["naechsteFolge".to_owned()])
            .unwrap();
        assert!(!migrate_order(&s, "srv").unwrap());
        assert_eq!(ids(&s, false)[..2], ["neueSerien", "weiterschauen"]);
        // Another server migrates on its own.
        assert!(migrate_order(&s, "other").unwrap());
    }

    #[test]
    fn neu_getrennt_defaults_to_separate_rows_as_on_the_mac() {
        // `AppModel.swift:764`: `store.object(forKey: "neuGetrennt") as? Bool ?? true`.
        assert!(settings().get(&keys::NEU_GETRENNT));
    }

    #[test]
    fn libraries_join_the_order_and_move_with_the_fixed_rows() {
        let s = settings();
        add_library(&s, "srv", StartLibrary::new("L1", "Kino", false)).unwrap();
        add_library(&s, "srv", StartLibrary::new("C1", "Marvel", true)).unwrap();
        let ids: Vec<String> = view(&s, "srv", false, HomeForm::Handheld)
            .rows
            .into_iter()
            .map(|r| r.id)
            .collect();
        assert_eq!(&ids[ids.len() - 2..], ["library:L1", "library:C1"]);
        // Up: the collection swaps with the library above it.
        assert!(shift_row(&s, "srv", false, HomeForm::Handheld, "library:C1", -1).unwrap());
        let ids: Vec<String> = view(&s, "srv", false, HomeForm::Handheld)
            .rows
            .into_iter()
            .map(|r| r.id)
            .collect();
        assert_eq!(&ids[ids.len() - 2..], ["library:C1", "library:L1"]);
        // The top row cannot go up.
        let first = ids[0].clone();
        assert!(!shift_row(&s, "srv", false, HomeForm::Handheld, &first, -1).unwrap());
        // Another server keeps its own libraries.
        assert!(
            view(&s, "other", false, HomeForm::Handheld)
                .rows
                .iter()
                .all(|r| !r.id.starts_with("library:"))
        );
        remove_library(&s, "srv", "L1").unwrap();
        assert!(
            view(&s, "srv", false, HomeForm::Handheld)
                .rows
                .iter()
                .all(|r| r.id != "library:L1")
        );
    }

    #[test]
    fn a_fixed_row_dropped_below_a_library_updates_the_fixed_list() {
        let s = settings();
        add_library(&s, "srv", StartLibrary::new("L1", "Kino", false)).unwrap();
        let ids: Vec<String> = view(&s, "srv", false, HomeForm::Handheld)
            .rows
            .into_iter()
            .map(|r| r.id)
            .collect();
        let first = ids[0].clone();
        assert!(drop_row(&s, "srv", false, HomeForm::Handheld, &first, "library:L1").unwrap());
        let after: Vec<String> = view(&s, "srv", false, HomeForm::Handheld)
            .rows
            .into_iter()
            .map(|r| r.id)
            .collect();
        assert_eq!(after.last().map(String::as_str), Some(first.as_str()));
        let rails = s.get(&keys::START_REIHEN);
        assert_eq!(rails.last(), Some(&first));
    }

    #[test]
    fn genres_are_added_once_dropped_and_removed() {
        let s = settings();
        for g in ["Drama", "Komödie", "Horror", "Drama"] {
            add_genre(&s, g).unwrap();
        }
        assert_eq!(
            view(&s, "x", false, HomeForm::Handheld).genres,
            ["Drama", "Komödie", "Horror"]
        );
        assert!(drop_genre(&s, "Horror", "Drama").unwrap());
        assert_eq!(
            view(&s, "x", false, HomeForm::Handheld).genres,
            ["Horror", "Drama", "Komödie"]
        );
        remove_genre(&s, "Drama").unwrap();
        assert_eq!(
            view(&s, "x", false, HomeForm::Handheld).genres,
            ["Horror", "Komödie"]
        );
    }

    fn ids(s: &Settings<MemoryStore>, seerr: bool) -> Vec<String> {
        view(s, "srv", seerr, HomeForm::Handheld)
            .rows
            .into_iter()
            .map(|r| r.id)
            .collect()
    }

    fn seerr_row(s: &Settings<MemoryStore>, section: SeerrSection) -> Option<bool> {
        view(s, "srv", true, HomeForm::Handheld)
            .rows
            .into_iter()
            .find_map(|r| match r.kind {
                HomeRowKind::Seerr { section: x, on } if x == section => Some(on),
                _ => None,
            })
    }

    #[test]
    fn seerr_sections_default_to_arrival_on_and_requests_off() {
        let s = settings();
        assert_eq!(seerr_row(&s, SeerrSection::Arrival), Some(true));
        assert_eq!(seerr_row(&s, SeerrSection::Requests), Some(false));
        // Both lead the list until the user places them.
        assert_eq!(&ids(&s, true)[..2], ["seerr:arrival", "seerr:requests"]);
        s.set(&keys::SEERR_REQUESTS_RAIL, true).unwrap();
        assert_eq!(seerr_row(&s, SeerrSection::Requests), Some(true));
    }

    #[test]
    fn seerr_sections_are_hidden_without_seerr() {
        let s = settings();
        assert!(ids(&s, false).iter().all(|i| !i.starts_with("seerr:")));
        assert!(ids(&s, true).iter().any(|i| i == "seerr:requests"));
    }

    #[test]
    fn the_view_lists_only_the_seerr_sections_of_the_form() {
        let s = settings();
        let seerr_ids = |form| {
            view(&s, "srv", true, form)
                .rows
                .into_iter()
                .map(|r| r.id)
                .filter(|i| i.starts_with("seerr:"))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            seerr_ids(HomeForm::Handheld),
            ["seerr:arrival", "seerr:requests"]
        );
        assert_eq!(seerr_ids(HomeForm::Desktop), ["seerr:requests"]);
        assert!(seerr_ids(HomeForm::Tv).is_empty());
    }

    #[test]
    fn seerr_sections_move_with_the_other_rows_and_keep_their_place() {
        let s = settings();
        add_library(&s, "srv", StartLibrary::new("L1", "Kino", false)).unwrap();
        // Drag "Meine Anfragen" below the library row.
        assert!(
            drop_row(
                &s,
                "srv",
                true,
                HomeForm::Handheld,
                "seerr:requests",
                "library:L1"
            )
            .unwrap()
        );
        let after = ids(&s, true);
        assert_eq!(after.last().map(String::as_str), Some("seerr:requests"));
        // The order is stored per server and survives a read through a new view.
        assert_eq!(ids(&s, true), after);
        // Move Up swaps with the visible neighbour.
        assert!(shift_row(&s, "srv", true, HomeForm::Handheld, "seerr:requests", -1).unwrap());
        let up = ids(&s, true);
        assert_eq!(up[up.len() - 2], "seerr:requests");
        // The fixed rows' own list holds no Seerr id.
        assert!(
            s.get(&keys::START_REIHEN)
                .iter()
                .all(|r| !r.starts_with("seerr:"))
        );
        // Without Seerr the stored place is dropped from the view but the other rows keep their order.
        assert!(ids(&s, false).iter().all(|i| !i.starts_with("seerr:")));
        // Another server has its own order.
        assert_eq!(
            &view(&s, "other", true, HomeForm::Handheld).rows[0].id,
            "seerr:arrival"
        );
    }
}
