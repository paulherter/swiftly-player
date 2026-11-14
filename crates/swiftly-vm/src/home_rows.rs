//! The Home rows of the Appearance page, kept the way the Mac keeps them (`AppModel.startLibraries`, `startOrder`,
//! `startRails`, `startGenres`, `HomeRowOrder`): one combined order of fixed rows and library rows, the libraries
//! chosen per server, the genres chosen once.

use swiftly_library::start_libraries::{StartLibraries, StartLibrary};
use swiftly_library::start_order::library_row_id;
use swiftly_library::{StartOrder, StartRail};
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
pub fn order<S: KeyValueStore>(settings: &Settings<S>, server: &str) -> Vec<String> {
    let stored = settings.get_for_server(&keys::START_REIHENFOLGE, server);
    let fixed = settings.get(&keys::START_REIHEN);
    // Empty: the old order of the fixed rows (`HomeRowOrder.effective`).
    let stored = if stored.is_empty() { fixed } else { stored };
    StartOrder::applicable(
        &stored,
        settings.get(&keys::NEU_GETRENNT),
        &libraries(settings, server),
    )
}

/// The rows as the page lists them.
pub fn view<S: KeyValueStore>(settings: &Settings<S>, server: &str) -> HomeView {
    let off = settings.get(&keys::START_AUS);
    let libs = libraries(settings, server);
    let rows = order(settings, server)
        .into_iter()
        .filter_map(|id| {
            let kind = if let Some(rail) = StartRail::from_raw(&id) {
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
    row: &str,
    target: &str,
) -> Result<bool, StoreError> {
    let list = order(settings, server);
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
    row: &str,
    delta: i32,
) -> Result<bool, StoreError> {
    let shown: Vec<String> = view(settings, server)
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
    drop_row(settings, server, row, neighbour)
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
    fn neu_getrennt_defaults_to_separate_rows_as_on_the_mac() {
        // `AppModel.swift:764`: `store.object(forKey: "neuGetrennt") as? Bool ?? true`.
        assert!(settings().get(&keys::NEU_GETRENNT));
    }

    #[test]
    fn libraries_join_the_order_and_move_with_the_fixed_rows() {
        let s = settings();
        add_library(&s, "srv", StartLibrary::new("L1", "Kino", false)).unwrap();
        add_library(&s, "srv", StartLibrary::new("C1", "Marvel", true)).unwrap();
        let ids: Vec<String> = view(&s, "srv").rows.into_iter().map(|r| r.id).collect();
        assert_eq!(&ids[ids.len() - 2..], ["library:L1", "library:C1"]);
        // Up: the collection swaps with the library above it.
        assert!(shift_row(&s, "srv", "library:C1", -1).unwrap());
        let ids: Vec<String> = view(&s, "srv").rows.into_iter().map(|r| r.id).collect();
        assert_eq!(&ids[ids.len() - 2..], ["library:C1", "library:L1"]);
        // The top row cannot go up.
        let first = ids[0].clone();
        assert!(!shift_row(&s, "srv", &first, -1).unwrap());
        // Another server keeps its own libraries.
        assert!(
            view(&s, "other")
                .rows
                .iter()
                .all(|r| !r.id.starts_with("library:"))
        );
        remove_library(&s, "srv", "L1").unwrap();
        assert!(view(&s, "srv").rows.iter().all(|r| r.id != "library:L1"));
    }

    #[test]
    fn a_fixed_row_dropped_below_a_library_updates_the_fixed_list() {
        let s = settings();
        add_library(&s, "srv", StartLibrary::new("L1", "Kino", false)).unwrap();
        let ids: Vec<String> = view(&s, "srv").rows.into_iter().map(|r| r.id).collect();
        let first = ids[0].clone();
        assert!(drop_row(&s, "srv", &first, "library:L1").unwrap());
        let after: Vec<String> = view(&s, "srv").rows.into_iter().map(|r| r.id).collect();
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
        assert_eq!(view(&s, "x").genres, ["Drama", "Komödie", "Horror"]);
        assert!(drop_genre(&s, "Horror", "Drama").unwrap());
        assert_eq!(view(&s, "x").genres, ["Horror", "Drama", "Komödie"]);
        remove_genre(&s, "Drama").unwrap();
        assert_eq!(view(&s, "x").genres, ["Horror", "Komödie"]);
    }
}
