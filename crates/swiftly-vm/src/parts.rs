use crate::account::AccountRef;

/// Which picture of a title.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageKind {
    /// The poster (portrait).
    Poster,
    /// The backdrop (landscape).
    Backdrop,
}

/// A picture a view loads itself: the address (with everything the server needs) and the
/// size it wants it in. Contains the access token in the query, so never log it.
#[derive(Debug, Clone, PartialEq)]
pub struct ImageRef {
    /// Where to load it.
    pub address: String,
    /// Poster or backdrop.
    pub kind: ImageKind,
    /// Wanted width in points.
    pub wanted_width: u32,
    /// Wanted height in points.
    pub wanted_height: u32,
}

/// A small mark on a tile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Badge {
    /// Already seen.
    Watched,
    /// A favourite.
    Favorite,
    /// A series with this many unseen episodes.
    Unplayed {
        /// Number of unseen episodes.
        count: u32,
    },
    /// A series nobody started: how many seasons it has (`TileMark.seasons`).
    Seasons {
        /// Number of seasons.
        count: u32,
    },
}

/// One title in a rail, display-ready.
#[derive(Debug, Clone, PartialEq)]
pub struct Tile {
    /// Server id of the title.
    pub id: String,
    /// First line.
    pub title: String,
    /// Second line ("S1 · F3", "3 neue Folgen", the year).
    pub subtitle: Option<String>,
    /// How much was watched, 0 to 1.
    pub progress: Option<f32>,
    /// The picture.
    pub image: Option<ImageRef>,
    /// Marks.
    pub badges: Vec<Badge>,
    /// The line of a continue-watching tile with the time left ("S2 · F5 · noch 12 Min."); the usual `subtitle` stays
    /// when there is no resume state.
    pub remaining: Option<String>,
    /// What a host needs to open the title (type, series, season, numbers).
    pub facts: TileFacts,
}

/// The facts behind a tile that decide where a tap leads. Display text is in [`Tile`];
/// these are the server's own values, unchanged.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TileFacts {
    /// The server's `Type` (`Movie`, `Series`, `Episode`, ...).
    pub kind: Option<String>,
    /// The title's own name (an episode's name; [`Tile::title`] holds the series).
    pub name: String,
    /// Production year.
    pub year: Option<i32>,
    /// The series an episode belongs to.
    pub series_id: Option<String>,
    /// The season an episode belongs to.
    pub season_id: Option<String>,
    /// Season number of an episode.
    pub season_number: Option<i32>,
    /// Episode number.
    pub episode_number: Option<i32>,
    /// How many children the title has (a series: its seasons); the "3 seasons" mark of a tile.
    pub child_count: Option<i32>,
}

/// What a rail is. Layouts may style by it; they never decide what is inside.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailKind {
    /// Continue watching.
    ContinueWatching,
    /// Next episode.
    NextEpisode,
    /// New movies (split rail).
    NewMovies,
    /// New series (split rail).
    NewSeries,
    /// Recently added (shared rail).
    NewArrivals,
    /// A genre chosen by the user.
    Genre,
}

/// A horizontal row. `ids` lists all titles; `tiles` holds the display data of the first
/// `tiles.len()` of them (the window, grown by `HomeIntent::Visible`; the rest through
/// `HomeVm::tiles`).
#[derive(Debug, Clone, PartialEq)]
pub struct Rail {
    /// Stable id: the stored raw name of a fixed rail, `genre:<name>` for a genre.
    pub id: String,
    /// The German catalog key of the heading; empty when the name comes from the server.
    pub title_key: String,
    /// The heading, already in the user's language.
    pub title: String,
    /// What the rail is.
    pub kind: RailKind,
    /// How many titles it has.
    pub count: u32,
    /// All ids, in order.
    pub ids: Vec<String>,
    /// Display data of the window.
    pub tiles: Vec<Tile>,
}

impl Rail {
    /// A chosen library or collection (its own row, `library:<id>`); the kind is [`RailKind::Genre`] so the host
    /// API stays as it is.
    pub fn is_library(&self) -> bool {
        self.id.starts_with("library:")
    }

    /// A chosen genre row (`genre:<name>`).
    pub fn is_genre(&self) -> bool {
        self.id.starts_with("genre:")
    }
}

/// The rails of the page. `version` is the view model version at which this part was replaced.
#[derive(Debug, Clone, PartialEq)]
pub struct RailsPart {
    /// Version of the part.
    pub version: u64,
    /// The rails, in display order. Empty rails are left out.
    pub rails: Vec<Rail>,
}

/// Where the page stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// Nothing confirmed by the server yet; rails may show the stored preview.
    Loading,
    /// The server answered.
    Ready,
    /// The server could not be reached; rails show the last state.
    Offline,
    /// There is no account.
    SignedOut,
}

/// The status of the page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusPart {
    /// Version of the part.
    pub version: u64,
    /// The state.
    pub status: Status,
    /// The rails come from the stored preview, not from the server.
    pub preview: bool,
    /// A reload runs while rails are shown.
    pub refreshing: bool,
}

/// What the view asks for. Never blocks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HomeIntent {
    /// Load now (first appearance, pull to refresh): preview from the store, then the server.
    Load,
    /// Back in the foreground: loads only when the last load is 30 s or more old.
    Refresh,
    /// Another account (or none: signed out). Clears the page at once.
    AccountSwitched {
        /// The new account, `None` for signed out.
        account: Option<AccountRef>,
    },
    /// A rail came into view: its tile data is prepared in full.
    Visible {
        /// The rail id.
        rail: String,
    },
}
