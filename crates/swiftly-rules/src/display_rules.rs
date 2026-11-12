//! Port of DisplayRules.swift.
//!
//! Decisions that look like UI but are not: **whether** something is shown. The wording stays
//! in the views.

use crate::text::{characters, is_cf_newline, is_cf_whitespace};

/// What is on a tile's badge. The view sets the wording; here only which information it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TileMark {
    /// Watched (checkmark).
    Watched,
    /// This many episodes are open.
    Opened(i64),
    /// This many seasons.
    Seasons(i64),
}

/// Whether a runtime may be shown at all: `0`, negative values, NaN and `None` are not a
/// runtime. (`DisplayRules.swift:19-22`)
pub fn runtime_show(seconds: Option<f64>) -> bool {
    seconds.is_some_and(|s| s > 0.0)
}

/// When a search input goes to the server: more than one character after trimming
/// whitespace and newlines. `count` is in Characters (grapheme clusters), as in Swift.
/// (`DisplayRules.swift:30-32`)
///
/// Foundation note: `CharacterSet.whitespacesAndNewlines` is Zs/Zl/Zp plus U+0009..U+000D and
/// U+0085, which is exactly Rust's `White_Space` set.
pub fn search_term_fits(term: &str) -> bool {
    let trimmed = term.trim_matches(|c| is_cf_whitespace(c) || is_cf_newline(c));
    characters(trimmed).len() > 1
}

/// What is shown at the top right of a tile. Precedence: watched, then open episodes (series
/// only), then the season count (series only). (`DisplayRules.swift:51-58`)
pub fn tile_mark(
    art: Option<&str>,
    seasons: Option<i64>,
    watched: Option<bool>,
    open_episodes: Option<i64>,
) -> Option<TileMark> {
    if watched == Some(true) {
        return Some(TileMark::Watched);
    }
    if art != Some("Series") {
        return None;
    }
    if let Some(opened) = open_episodes
        && opened > 0
    {
        return Some(TileMark::Opened(opened));
    }
    if let Some(n) = seasons
        && n > 0
    {
        return Some(TileMark::Seasons(n));
    }
    None
}

/// `Item.tileCharacter` (`DisplayRules.swift:76-78`) on the two fields it reads: a TV for
/// series and their episodes, a film strip otherwise.
pub fn tile_character(item_type: Option<&str>, series_id: Option<&str>) -> &'static str {
    if item_type == Some("Series") || series_id.is_some() {
        "tv"
    } else {
        "film"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: nullIsNot()
    #[test]
    fn null_is_not() {
        assert!(!runtime_show(Some(0.0)));
        assert!(!runtime_show(None));
        assert!(!runtime_show(Some(-5.0)));
    }

    // Swift: realRuntime()
    #[test]
    fn real_runtime() {
        assert!(runtime_show(Some(1.0)));
        assert!(runtime_show(Some(3600.0)));
    }

    // Swift: inLetter()
    #[test]
    fn in_letter() {
        assert!(!search_term_fits(""));
        assert!(!search_term_fits("a"));
        assert!(!search_term_fits("   "));
    }

    // Swift: emptyCharacterCountNot()
    #[test]
    fn empty_character_count_not() {
        assert!(!search_term_fits("a "));
        assert!(!search_term_fits(" a"));
        assert!(search_term_fits(" ab "));
    }

    // Swift: offTwo()
    #[test]
    fn off_two() {
        assert!(search_term_fits("ab"));
        assert!(search_term_fits("Lighthouse"));
    }

    // Swift: watchedWins()
    #[test]
    fn watched_wins() {
        assert_eq!(
            tile_mark(Some("Series"), Some(7), Some(true), Some(3)),
            Some(TileMark::Watched)
        );
    }

    // Swift: openPreSeasons()
    #[test]
    fn open_pre_seasons() {
        assert_eq!(
            tile_mark(Some("Series"), Some(7), Some(false), Some(12)),
            Some(TileMark::Opened(12))
        );
    }

    // Swift: seasonCount()
    #[test]
    fn season_count() {
        assert_eq!(
            tile_mark(Some("Series"), Some(7), Some(false), Some(0)),
            Some(TileMark::Seasons(7))
        );
        assert_eq!(
            tile_mark(Some("Series"), Some(7), None, None),
            Some(TileMark::Seasons(7))
        );
    }

    // Swift: filmWithoutMark()
    #[test]
    fn film_without_mark() {
        assert_eq!(tile_mark(Some("Movie"), None, Some(false), None), None);
        assert_eq!(
            tile_mark(Some("Movie"), Some(1), Some(false), Some(4)),
            None
        );
    }

    // Swift: filmWatched()
    #[test]
    fn film_watched() {
        assert_eq!(
            tile_mark(Some("Movie"), None, Some(true), None),
            Some(TileMark::Watched)
        );
    }

    // Swift: zerosDropOut()
    #[test]
    fn zeros_drop_out() {
        assert_eq!(
            tile_mark(Some("Series"), Some(0), Some(false), Some(0)),
            None
        );
        assert_eq!(tile_mark(None, None, None, None), None);
    }

    // Swift: tileCharacter() (inputs are the two Item fields it reads)
    #[test]
    fn tile_character_rule() {
        assert_eq!(tile_character(Some("Series"), None), "tv");
        assert_eq!(tile_character(Some("Episode"), Some("s")), "tv");
        assert_eq!(tile_character(Some("Movie"), None), "film");
        assert_eq!(tile_character(None, None), "film");
    }
}
