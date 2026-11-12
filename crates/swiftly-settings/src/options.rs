//! Option lists and the raw values stored for them (`apple-settings.md` section 2).

/// Skip lengths in seconds (`Span.levels`, `JK/PlaybackSelection.swift:26-27`).
pub const SKIP_SECONDS_LEVELS: [i64; 5] = [5, 10, 15, 30, 60];
/// Bitrate limits in Mbit/s; 0 = unlimited (`Bitrate.levels`, `JK/PlaybackSelection.swift:16`).
pub const BITRATE_LEVELS: [i64; 6] = [0, 4, 8, 20, 40, 80];
/// Sleep timer minutes (`SleepTimes.values`, `JK/PlaybackLevels.swift:25`).
pub const SLEEP_TIMER_MINUTES: [i64; 5] = [15, 30, 45, 60, 90];
/// Playback speeds (`SpeedLevels.values`, `JK/PlaybackLevels.swift:9`).
pub const SPEED_LEVELS: [f32; 5] = [0.75, 1.0, 1.25, 1.5, 2.0];

macro_rules! raw_enum {
    ($(#[$m:meta])* $name:ident { $( $(#[$vm:meta])* $var:ident = $raw:literal ),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum $name { $( $(#[$vm])* $var ),+ }
        impl $name {
            /// Every case.
            pub const ALL: &'static [Self] = &[ $( Self::$var ),+ ];
            /// The persisted raw value.
            pub const fn raw(self) -> &'static str { match self { $( Self::$var => $raw ),+ } }
            /// Parses a raw value; `None` for unknown text.
            pub fn from_raw(raw: &str) -> Option<Self> { match raw { $( $raw => Some(Self::$var), )+ _ => None } }
        }
    };
}

raw_enum! {
    /// `BufferLevel` (`JK/BufferLevel.swift:19-33`), stored under `pufferstufe`.
    BufferLevel {
        /// Fast seeks; the default.
        Normal = "normal",
        /// Poor connection: drops quality.
        Bad = "schlecht",
    }
}

raw_enum! {
    /// Library sort order, `Sorting` (`JK/Library.swift:4-33`); keys `sortierung.<library>`.
    Sorting {
        /// Sort by name (`SortName`).
        Name = "name",
        /// Recently added (`DateCreated`); the default.
        Latest = "neueste",
        /// Rating (`CommunityRating`).
        Rating = "bewertung",
        /// Release year (`PremiereDate`).
        Erscheinung = "erscheinung",
    }
}

raw_enum! {
    /// `LibraryFilter` (`JK/Library.swift:35-62`); keys `filter.<library>`.
    LibraryFilter {
        /// All.
        All = "alle",
        /// Begun (`IsResumable`).
        Begun = "angefangen",
        /// Watchlist (`IsFavorite`).
        Watchlist = "merkliste",
        /// Unwatched.
        Unwatched = "ungesehen",
    }
}

raw_enum! {
    /// `RememberGenre` (`JK/Library.swift:80-118`).
    RememberGenre {
        /// All.
        All = "alle",
        /// Movies.
        Movies = "filme",
        /// Series.
        SeriesList = "serien",
    }
}

raw_enum! {
    /// `StartRail` (`JK/StartRails.swift:9-20`); the values of `startReihen` and `startAus`.
    StartRail {
        /// Continue watching.
        ContinueWatching = "weiterschauen",
        /// Next episode.
        NextEpisode = "naechsteFolge",
        /// New movies.
        NewMovies = "neueFilme",
        /// New series.
        NewSeries = "neueSerien",
        /// New arrivals (combined row).
        NewArrivals = "neuzugaenge",
    }
}
