//! Pure rule files of the Swiftly Jellyfin client, ported 1:1 from Swift (`JellyfinKit`).
//!
//! One module per Swift file; every module header names its Swift source. No networking, no
//! UI strings, no persistence: wording stays in the localisation crate, models in
//! `swiftly-model`. Where a Swift rule needs a model type, the module defines a small plain
//! input struct instead (see `NOTES.md`).
//!
//! Time is passed in as plain `f64` seconds on any consistent clock (Swift used `Date`).

pub mod age_rating;
pub mod alphabet_index;
pub mod buffer_level;
pub mod chapter;
pub mod counter;
pub mod delay;
pub mod description;
pub mod display_rules;
pub mod download_audio;
pub mod download_quality;
pub mod download_right;
pub mod episodes_card;
pub mod episodes_end;
pub mod episodes_switch;
pub mod language;
pub mod natural_order;
pub mod notches_snap;
pub mod playback_levels;
pub mod playback_selection;
pub mod playback_tick;
pub mod search_keys;
pub mod time_assumption;
pub mod title_marks;
pub mod whole_number;

mod text;
pub use text::{
    case_insensitive_equal, trim_name, trim_whitespaces, trim_whitespaces_and_newlines,
};
