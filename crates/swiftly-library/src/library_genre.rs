//! `LibraryGenre` (Swift `LibraryGenre.swift`) and the pieces of `SectionOffering.swift` that
//! extend it (:48-60, :180-206): which item kind a library of a type holds.

/// `LibraryGenre` namespace.
pub struct LibraryGenre;

impl LibraryGenre {
    /// The values for `IncludeItemTypes`, or empty if there is no useful restriction
    /// (`types(toward:)`, LibraryGenre.swift:21-33). Unknown means: do not restrict.
    pub fn types_toward(art: Option<&str>) -> Vec<&'static str> {
        match art.map(str::to_lowercase).as_deref() {
            Some("movies") => vec!["Movie"],
            Some("tvshows") => vec!["Series"],
            Some("music") => vec!["MusicAlbum"],
            Some("homevideos") => vec!["Video", "Photo"],
            Some("books") => vec!["Book"],
            _ => Vec::new(),
        }
    }

    /// Whether this type must be queried recursively: only when the kind is fixed (:41-43).
    pub fn recursive_toward(art: Option<&str>) -> bool {
        !Self::types_toward(art).is_empty()
    }

    /// Which section belongs to a title kind: `Movie` to `movies` (SectionOffering.swift:196-202).
    pub fn art_to_type(type_: Option<&str>) -> Option<&'static str> {
        match type_ {
            Some("Movie") => Some("movies"),
            Some("Series") => Some("tvshows"),
            _ => None,
        }
    }

    /// Whether a library of this kind can hold movies and series (SectionOffering.swift:188-195).
    pub fn can_be_mixed(art: Option<&str>) -> bool {
        const UNAMBIGUOUS: [&str; 10] = [
            "movies",
            "tvshows",
            "music",
            "musicvideos",
            "books",
            "photos",
            "livetv",
            "playlists",
            "boxsets",
            "trailers",
        ];
        match art.map(str::to_lowercase) {
            None => true,
            Some(a) => !UNAMBIGUOUS.contains(&a.as_str()),
        }
    }
}

/// How many movies and series a library holds that can contain both (SectionOffering.swift:48).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LibraryShare {
    /// Movies.
    pub movies: i64,
    /// Series.
    pub series_list: i64,
}

impl LibraryShare {
    /// `count(art:)`: `movies` or `tvshows`, else 0.
    pub fn count(&self, art: &str) -> i64 {
        match art.to_lowercase().as_str() {
            "movies" => self.movies,
            "tvshows" => self.series_list,
            _ => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known() {
        assert_eq!(LibraryGenre::types_toward(Some("movies")), ["Movie"]);
        assert_eq!(LibraryGenre::types_toward(Some("tvshows")), ["Series"]);
    }
    #[test]
    fn recursive() {
        assert!(LibraryGenre::recursive_toward(Some("movies")));
        assert!(LibraryGenre::recursive_toward(Some("tvshows")));
    }
    #[test]
    fn unknown_is_not_restricted() {
        assert!(LibraryGenre::types_toward(Some("boxsets")).is_empty());
        assert!(LibraryGenre::types_toward(None).is_empty());
        assert!(!LibraryGenre::recursive_toward(None));
    }
    #[test]
    fn case_is_irrelevant() {
        assert_eq!(LibraryGenre::types_toward(Some("TVShows")), ["Series"]);
        assert_eq!(LibraryGenre::types_toward(Some("Movies")), ["Movie"]);
    }
    #[test]
    fn mixed_and_sections() {
        assert!(LibraryGenre::can_be_mixed(None));
        assert!(LibraryGenre::can_be_mixed(Some("mixed")));
        assert!(!LibraryGenre::can_be_mixed(Some("Movies")));
        assert_eq!(LibraryGenre::art_to_type(Some("Series")), Some("tvshows"));
        assert_eq!(LibraryGenre::art_to_type(Some("Episode")), None);
        assert_eq!(
            LibraryShare {
                movies: 3,
                series_list: 1
            }
            .count("TVShows"),
            1
        );
    }
}
