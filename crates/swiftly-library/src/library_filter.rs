//! Sort order, filter and watchlist kind of a library page (Swift `Library.swift:4-118`).
//!
//! `Sorting` itself is `swiftly_rules::alphabet_index::Sorting` (the strip needs it too);
//! [`SortingExt`] adds what `Library.swift` defines on it. Labels are catalog wording and not
//! ported.

pub use swiftly_rules::alphabet_index::Sorting;

/// `Sorting` members from Library.swift:4-31.
pub trait SortingExt: Sized {
    /// All orders, in declaration order (`CaseIterable`).
    const ALL: [Self; 4];
    /// The stored raw value: `name`, `neueste`, `bewertung`, `erscheinung` (:5).
    fn raw_value(self) -> &'static str;
    /// `Sorting(rawValue:)`.
    fn from_raw(raw: &str) -> Option<Self>;
    /// Jellyfin's field name (`inputField`, :18-25).
    fn input_field(self) -> &'static str;
    /// Names ascending, everything else descending (`bearing`, :30).
    fn bearing(self) -> &'static str;
}

impl SortingExt for Sorting {
    const ALL: [Self; 4] = [Self::Name, Self::Latest, Self::Rating, Self::Erscheinung];

    fn raw_value(self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::Latest => "neueste",
            Self::Rating => "bewertung",
            Self::Erscheinung => "erscheinung",
        }
    }
    fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.raw_value() == raw)
    }
    fn input_field(self) -> &'static str {
        match self {
            Self::Name => "SortName",
            Self::Latest => "DateCreated",
            Self::Rating => "CommunityRating",
            Self::Erscheinung => "PremiereDate",
        }
    }
    fn bearing(self) -> &'static str {
        if self == Self::Name {
            "Ascending"
        } else {
            "Descending"
        }
    }
}

/// Narrows the list (Library.swift:35-58).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LibraryFilter {
    /// `alle`.
    All,
    /// `angefangen`: started titles.
    Begun,
    /// `merkliste`: favourites.
    Watchlist,
    /// `ungesehen`: unwatched.
    Unwatched,
}

impl LibraryFilter {
    /// All filters, in declaration order.
    pub const ALL: [Self; 4] = [Self::All, Self::Begun, Self::Watchlist, Self::Unwatched];

    /// The stored raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::All => "alle",
            Self::Begun => "angefangen",
            Self::Watchlist => "merkliste",
            Self::Unwatched => "ungesehen",
        }
    }
    /// `LibraryFilter(rawValue:)`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|f| f.raw_value() == raw)
    }
    /// The `Filters` values (`jellyfinFilter`, :46-51).
    pub fn jellyfin_filter(self) -> Vec<String> {
        match self {
            Self::Begun => vec!["IsResumable".into()],
            Self::Watchlist => vec!["IsFavorite".into()],
            _ => Vec::new(),
        }
    }
    /// Only "Unwatched" needs its own switch (`isWatched`, :54).
    pub fn is_watched(self) -> Option<bool> {
        (self == Self::Unwatched).then_some(false)
    }
    /// The filters a page offers: without the watchlist when it is switched off (:57-59).
    pub fn offered(filters: &[Self], watchlist: bool) -> Vec<Self> {
        filters
            .iter()
            .copied()
            .filter(|f| watchlist || *f != Self::Watchlist)
            .collect()
    }
    /// A stored filter the page no longer offers falls back to "All" (:63-65).
    pub fn kept(self, offered: &[Self]) -> Self {
        if offered.contains(&self) {
            self
        } else {
            Self::All
        }
    }
}

/// What the watchlist shows: movies, series or both (Library.swift:80-118).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RememberGenre {
    /// `alle`.
    All,
    /// `filme`.
    Movies,
    /// `serien`.
    SeriesList,
}

impl RememberGenre {
    /// All kinds, in declaration order.
    pub const ALL: [Self; 3] = [Self::All, Self::Movies, Self::SeriesList];

    /// The stored raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::All => "alle",
            Self::Movies => "filme",
            Self::SeriesList => "serien",
        }
    }
    /// `RememberGenre(rawValue:)`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|g| g.raw_value() == raw)
    }
    /// Jellyfin's `CollectionType` (`art`).
    pub fn art(self) -> Option<&'static str> {
        match self {
            Self::All => None,
            Self::Movies => Some("movies"),
            Self::SeriesList => Some("tvshows"),
        }
    }
    /// Which `IncludeItemTypes` follow from it (`types`).
    pub fn types(self) -> Vec<&'static str> {
        match self {
            Self::All => vec!["Movie", "Series"],
            Self::Movies => vec!["Movie"],
            Self::SeriesList => vec!["Series"],
        }
    }
    /// `toward(art:)`: the first kind whose `art` matches, else `All`.
    pub fn toward(art: Option<&str>) -> Self {
        Self::ALL
            .into_iter()
            .find(|g| g.art() == art)
            .unwrap_or(Self::All)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offered_without_watchlist() {
        assert_eq!(
            LibraryFilter::offered(&LibraryFilter::ALL, true),
            LibraryFilter::ALL
        );
        assert_eq!(
            LibraryFilter::offered(
                &[
                    LibraryFilter::All,
                    LibraryFilter::Begun,
                    LibraryFilter::Watchlist
                ],
                false
            ),
            [LibraryFilter::All, LibraryFilter::Begun]
        );
        assert_eq!(
            LibraryFilter::offered(&LibraryFilter::ALL, false),
            [
                LibraryFilter::All,
                LibraryFilter::Begun,
                LibraryFilter::Unwatched
            ]
        );
    }
    #[test]
    fn kept_falls_back_to_all() {
        let two = [LibraryFilter::All, LibraryFilter::Begun];
        assert_eq!(LibraryFilter::Watchlist.kept(&two), LibraryFilter::All);
        assert_eq!(LibraryFilter::Begun.kept(&two), LibraryFilter::Begun);
        assert_eq!(
            LibraryFilter::Watchlist.kept(&LibraryFilter::ALL),
            LibraryFilter::Watchlist
        );
    }
    #[test]
    fn query_parameters() {
        assert_eq!(Sorting::Name.input_field(), "SortName");
        assert_eq!(Sorting::Latest.input_field(), "DateCreated");
        assert_eq!(Sorting::Rating.input_field(), "CommunityRating");
        assert_eq!(Sorting::Erscheinung.input_field(), "PremiereDate");
        assert_eq!(Sorting::Name.bearing(), "Ascending");
        assert_eq!(Sorting::Latest.bearing(), "Descending");
        assert_eq!(LibraryFilter::Begun.jellyfin_filter(), ["IsResumable"]);
        assert_eq!(LibraryFilter::Watchlist.jellyfin_filter(), ["IsFavorite"]);
        assert!(LibraryFilter::Unwatched.jellyfin_filter().is_empty());
        assert_eq!(LibraryFilter::Unwatched.is_watched(), Some(false));
        assert_eq!(LibraryFilter::All.is_watched(), None);
    }
    #[test]
    fn raw_values_round_trip() {
        for s in Sorting::ALL {
            assert_eq!(Sorting::from_raw(s.raw_value()), Some(s));
        }
        for f in LibraryFilter::ALL {
            assert_eq!(LibraryFilter::from_raw(f.raw_value()), Some(f));
        }
        assert_eq!(Sorting::from_raw("bewertung"), Some(Sorting::Rating));
        assert_eq!(Sorting::from_raw("x"), None);
    }
    #[test]
    fn remember_genre() {
        assert_eq!(
            RememberGenre::toward(Some("tvshows")),
            RememberGenre::SeriesList
        );
        assert_eq!(RememberGenre::toward(Some("music")), RememberGenre::All);
        assert_eq!(RememberGenre::toward(None), RememberGenre::All);
        assert_eq!(RememberGenre::All.types(), ["Movie", "Series"]);
        assert_eq!(RememberGenre::Movies.art(), Some("movies"));
    }
}
