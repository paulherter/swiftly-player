//! Library and home logic of Swiftly, ported 1:1 from Swift (`Packages/JellyfinKit`,
//! `Sources/Shared/HomePageModel.swift`, `LibraryModel.swift`).
//!
//! Three layers:
//! - plain rules (`list_rules`, `start_rails`, `refresh`, `search_history`, ...), no I/O;
//! - the home loader (`home`) behind the [`HomePageSource`] trait, with an implementation for
//!   [`swiftly_jellyfin::JellyfinClient`] in `client_ext`, and persistence behind the [`Store`]
//!   and [`KeyValue`] traits (`store`);
//! - the view-model logic as pure state machines (`home_state`, `library_state`): intents and
//!   answers go in, state and effect commands come out, no I/O inside.
//!
//! Every module header and most items name the Swift `file:line` they mirror. Wording stays
//! in the localisation crate; the few German source strings that Swift tests pin down
//! (`StartRail::lists_name`) are the catalog keys.
#![deny(missing_docs)]

pub mod client_ext;
pub mod collection_directory;
pub mod home;
pub mod home_state;
pub mod home_store;
pub mod jump_target;
pub mod library_filter;
pub mod library_genre;
pub mod library_state;
pub mod list_rules;
pub mod pages_ratio;
pub mod playlist_directory;
pub mod refresh;
pub mod search_history;
pub mod series_state;
pub mod shelf;
pub mod shuffle_run;
pub mod start_libraries;
pub mod start_order;
pub mod start_rails;
pub mod store;

pub use collection_directory::{CollectionDirectory, ItemCollection};
pub use home::{Home, HomeLoader, HomePageSource, LoadRequest};
pub use home_state::{HomeCommand, HomeState};
pub use home_store::HomeStore;
pub use library_filter::{LibraryFilter, RememberGenre, SortingExt};
pub use library_genre::{LibraryGenre, LibraryShare};
pub use library_state::{LibraryCommand, LibraryState};
pub use list_rules::ListRules;
pub use playlist_directory::{PlaylistDirectory, VideoPlaylist};
pub use series_state::SeasonSelectionRule;
pub use shelf::{ShelfSource, TitleFilter};
pub use start_libraries::{StartLibraries, StartLibrary};
pub use start_order::{OrderEditor, OrderEvent, OrderRefused, StartOrder, library_row_id};
pub use start_rails::{LibraryJump, StartRail, StartRailsEpisode};
pub use store::{KeyValue, MemoryKeyValue, MemoryStore, Store};
