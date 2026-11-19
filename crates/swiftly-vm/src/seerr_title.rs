//! The Seerr title page and the request sheet as one view model (Sans-I/O: the host runs the calls
//! of the `swiftly-seerr` client and feeds the answers in). One enum ([`TitleState`]) for the page,
//! one ([`SheetState`]) for the sheet; every transition is a method here. Also the shared words:
//! the status badge, the capsule on a tile, the text of a refused request, the quota line.

use std::collections::BTreeSet;
use std::time::{SystemTime, UNIX_EPOCH};

use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_seerr::models::{TmdbSize, tmdb_image};
use swiftly_seerr::requests::{RequestOutcome, RequestSpec, ServiceDetail};
use swiftly_seerr::types::{
    MediaInfo, PublicSettings, QuotaPart, RequestStatus, TitleCard, TitleEpisode, TitleInfo,
};
use swiftly_seerr::{AskError, Perms, SeerrStatus};

// ---------------------------------------------------------------- words

/// What a badge says, for colour and symbol.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BadgeKind {
    /// Nothing asked for yet.
    Requestable,
    /// A request waits for an admin.
    Waits,
    /// Approved, nothing downloading yet.
    Searching,
    /// Not released yet.
    Soon,
    /// A download runs.
    Fetching,
    /// Part of it is on the server.
    Partial,
    /// On the server.
    Available,
    /// Declined.
    Declined,
    /// The downloader could not take it.
    Failed,
    /// On the blocklist.
    Blocked,
}

/// The status of a title or season as the screens draw it.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrBadge {
    /// Which state.
    pub kind: BadgeKind,
    /// The short word of a capsule ("wartet", "62 %", "28. Nov.").
    pub word: String,
    /// The line of a page or row ("Wird geholt · 62 %").
    pub line: String,
    /// 0...1 while a download runs.
    pub progress: Option<f32>,
    /// SF Symbol name for the badge.
    pub symbol: String,
}

/// `28. Nov.` of `2026-11-28`; the day text itself when it does not read.
pub fn short_date(t: &Translator, date: &str) -> String {
    const MONTHS: [&str; 12] = [
        "Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sep.", "Okt.", "Nov.",
        "Dez.",
    ];
    let mut parts = date.split('-');
    let _year = parts.next();
    let month = parts.next().and_then(|m| m.parse::<usize>().ok());
    let day = parts
        .next()
        .and_then(|d| d.get(..2).unwrap_or(d).parse::<i64>().ok());
    match (month, day) {
        (Some(m @ 1..=12), Some(d)) => {
            t.t_args("%lld. %@", &[Arg::Int(d), Arg::Str(t.t(MONTHS[m - 1]))])
        }
        _ => date.to_string(),
    }
}

/// When something happened, as people say it: "gerade eben", "vor 5 Min.", "vor 3 Std.", "gestern",
/// "vor 3 Tagen" within the last week, then the day ("10. Nov.", with the year when it is not this
/// one). `iso` is the server's timestamp; text that does not read comes back as it is. Days are UTC
/// days. The one place every platform takes a comment or issue time from.
pub fn when_text(t: &Translator, iso: &str) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    when_text_at(t, iso, now)
}

/// [`when_text`] with the current time given (seconds since 1970).
pub fn when_text_at(t: &Translator, iso: &str, now: f64) -> String {
    let Some(then) = swiftly_model::parse_timestamp(iso) else {
        return iso.to_string();
    };
    let secs = (now - then).floor() as i64;
    let days = (now / 86_400.0).floor() as i64 - (then / 86_400.0).floor() as i64;
    if secs < 60 {
        // Also a slightly early clock on the server.
        return t.t("gerade eben");
    }
    if secs < 3_600 {
        return t.t_args("vor %lld Min.", &[Arg::Int(secs / 60)]);
    }
    if days == 0 {
        return t.t_args("vor %lld Std.", &[Arg::Int(secs / 3_600)]);
    }
    match days {
        1 => t.t("gestern"),
        2..=6 => t.t_args("vor %lld Tagen", &[Arg::Int(days)]),
        _ => {
            let day = short_date(t, iso);
            let this_year = date_utc(now);
            let year = iso.get(..4).unwrap_or_default();
            if this_year.get(..4) == Some(year) {
                day
            } else {
                format!("{day} {year}")
            }
        }
    }
}

/// The badge of a status.
pub fn badge_of(t: &Translator, status: &SeerrStatus) -> SeerrBadge {
    let make = |kind, word: String, line: String, progress, symbol: &str| SeerrBadge {
        kind,
        word,
        line,
        progress,
        symbol: symbol.to_string(),
    };
    match status {
        SeerrStatus::Requestable => make(
            BadgeKind::Requestable,
            "+".into(),
            t.t("Nicht auf deinem Server"),
            None,
            "plus",
        ),
        SeerrStatus::Waits => make(
            BadgeKind::Waits,
            t.t("wartet"),
            t.t("Wartet auf Freigabe"),
            None,
            "clock",
        ),
        SeerrStatus::Searching => make(
            BadgeKind::Searching,
            t.t("wird gesucht"),
            t.t("Wird gesucht"),
            None,
            "magnifyingglass",
        ),
        SeerrStatus::Soon { date, requested } => {
            let day = short_date(t, date);
            let line = if *requested {
                t.t_args("Angefragt · erscheint am %@", &[Arg::Str(day.clone())])
            } else {
                t.t_args("Erscheint am %@", &[Arg::Str(day.clone())])
            };
            make(BadgeKind::Soon, day, line, None, "calendar")
        }
        SeerrStatus::Fetching { percent, .. } => make(
            BadgeKind::Fetching,
            format!("{percent} %"),
            format!("{} · {percent} %", t.t("Wird geholt")),
            Some(f32::from(*percent) / 100.0),
            "arrow.down.circle",
        ),
        SeerrStatus::Partial => make(
            BadgeKind::Partial,
            t.t("teilweise"),
            t.t("Teilweise da"),
            None,
            "circle.lefthalf.filled",
        ),
        SeerrStatus::UpToDate { next } => {
            let (word, line) = match next {
                Some(date) => {
                    let day = short_date(t, date);
                    (
                        day.clone(),
                        t.t_args(
                            "Alle bisherigen Folgen da · nächste am %@",
                            &[Arg::Str(day)],
                        ),
                    )
                }
                None => (t.t("da"), t.t("Alle bisherigen Folgen da")),
            };
            make(
                BadgeKind::Partial,
                word,
                line,
                None,
                "circle.lefthalf.filled",
            )
        }
        SeerrStatus::Available => make(
            BadgeKind::Available,
            t.t("da"),
            t.t("Auf deinem Server"),
            None,
            "checkmark",
        ),
        SeerrStatus::Declined => make(
            BadgeKind::Declined,
            t.t("abgelehnt"),
            t.t("Abgelehnt"),
            None,
            "xmark",
        ),
        SeerrStatus::Failed => make(
            BadgeKind::Failed,
            t.t("fehlgeschlagen"),
            t.t("Holen fehlgeschlagen"),
            None,
            "exclamationmark.triangle",
        ),
        SeerrStatus::Blocked => make(
            BadgeKind::Blocked,
            t.t("gesperrt"),
            t.t("Gesperrt"),
            None,
            "nosign",
        ),
    }
}

/// The sentence of a refused or failed call, for the sheet or a row.
pub fn ask_text(t: &Translator, error: &AskError) -> String {
    match error {
        AskError::QuotaExceeded(text) => {
            // Seerr names the kind in its English text ("Movie Quota exceeded.", "Series Quota
            // exceeded.", "TV Request Quota exceeded."); the period is the account's default week.
            let lower = text.to_lowercase();
            if lower.contains("movie") {
                t.t("Dein Film-Limit für diese Woche ist erreicht.")
            } else if lower.contains("series") || lower.contains("tv") || lower.contains("season") {
                t.t("Dein Serien-Limit für diese Woche ist erreicht.")
            } else {
                t.t("Dein Limit ist aufgebraucht.")
            }
        }
        AskError::NoPermission => t.t("Dafür fehlt dir die Berechtigung."),
        AskError::Blocked => t.t("Dieser Titel ist gesperrt."),
        AskError::Exists => t.t("Das ist schon angefragt."),
        AskError::NoSeasons => t.t("Alle Staffeln sind schon angefragt oder da."),
        AskError::SessionLost => t.t("Seerr braucht eine neue Anmeldung."),
        AskError::NotFound => t.t("Das gibt es bei Seerr nicht mehr."),
        AskError::Conflict(_) => t.t("Das hat sich gerade geändert."),
        AskError::Failed { text, .. } => t.t_args("Seerr meldet: %@", &[Arg::Str(text.clone())]),
        AskError::Network(_) => t.t("Seerr antwortet gerade nicht."),
    }
}

/// True when the answer means "Seerr is not reachable" (the offline state), not a refusal.
pub fn is_offline(error: &AskError) -> bool {
    matches!(error, AskError::Network(_))
        || matches!(error, AskError::Failed { status, .. } if *status >= 500)
}

/// The quota of `art` as a line, and whether it is the warning (nothing left). `None` when the
/// account has no limit.
pub fn quota_line(t: &Translator, art: &str, part: &QuotaPart) -> Option<(String, bool)> {
    if !part.has_limit() {
        return None;
    }
    let left = part.left().unwrap_or(0).max(0);
    let limit = part.limit.unwrap_or(0);
    let days = part.days.unwrap_or(7);
    let period = match days {
        7 => t.t("diese Woche"),
        1 => t.t("heute"),
        30 => t.t("diesen Monat"),
        n => t.t_args("in %lld Tagen", &[Arg::Int(n)]),
    };
    if left == 0 {
        return Some((t.t_args("Nichts mehr frei %@", &[Arg::Str(period)]), true));
    }
    let unit = match (art == "tv", limit == 1) {
        (true, true) => "Staffel",
        (true, false) => "Staffeln",
        (false, true) => "Film",
        (false, false) => "Filme",
    };
    Some((
        t.t_args(
            "Noch %lld von %lld %@ frei %@",
            &[
                Arg::Int(left),
                Arg::Int(limit),
                Arg::Str(t.t(unit)),
                Arg::Str(period),
            ],
        ),
        false,
    ))
}

/// Today as `yyyy-mm-dd` (UTC).
pub fn today_utc() -> String {
    date_utc(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64()),
    )
}

/// `yyyy-mm-dd` (UTC) of seconds since 1970.
fn date_utc(secs: f64) -> String {
    let days = (secs / 86_400.0).floor() as i64;
    // Civil date from days since 1970-01-01 (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

// ---------------------------------------------------------------- tiles

/// One poster tile of a rail, a search or a similar list.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrTileCard {
    /// `movie`, `tv`, `person` or `collection`.
    pub art: String,
    /// TMDB id.
    pub tmdb: i64,
    /// Title or name.
    pub title: String,
    /// Year, when known.
    pub year: Option<i64>,
    /// Poster or portrait path (TMDB).
    pub poster: Option<String>,
    /// Status capsule; `None` for people and collections.
    pub badge: Option<SeerrBadge>,
    /// Seerr's media id, when it knows the title.
    pub media_id: Option<i64>,
    /// The title is on the server: the host opens its own page.
    pub on_server: bool,
    /// What VoiceOver reads.
    pub announcement: String,
}

/// The tile of a card.
pub fn tile_of(t: &Translator, card: &TitleCard, today: &str) -> SeerrTileCard {
    let status = card.status(today, false);
    let badge = badge_of(t, &status);
    let announcement = format!("{}, {}", card.hit.title, badge.line);
    SeerrTileCard {
        art: card.hit.art.clone(),
        tmdb: card.hit.id,
        title: card.hit.title.clone(),
        year: card.hit.year,
        poster: tmdb_image(card.hit.poster_path.as_deref(), TmdbSize::Poster),
        media_id: card.media.as_ref().map(|m| m.id).filter(|id| *id > 0),
        on_server: status == SeerrStatus::Available,
        badge: Some(badge),
        announcement,
    }
}

// ---------------------------------------------------------------- the page

/// A cast member of the page.
pub use crate::seerr::SeerrCast;

/// What the primary button of the page is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrimaryKind {
    /// "Anfragen".
    Request,
    /// "Angefragt", nothing to press.
    Requested,
    /// A request is on its way.
    Busy,
    /// The limit is used up.
    Locked,
    /// No button (on the server, blocked, no permission).
    Hidden,
}

/// The primary button of the page or the sheet.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrPrimary {
    /// State.
    pub kind: PrimaryKind,
    /// Label.
    pub text: String,
    /// Can be pressed.
    pub enabled: bool,
}

/// One season row (page list, season picker and request sheet).
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrSeasonRowInfo {
    /// Season number (0 = specials).
    pub number: i64,
    /// "Staffel 3".
    pub title: String,
    /// "10 Folgen".
    pub episodes: Option<String>,
    /// Status capsule.
    pub badge: SeerrBadge,
    /// The season is in the library: the host switches to it.
    pub on_server: bool,
    /// Not on the server and not on its way: draw it grey, a tap asks for it.
    pub missing: bool,
    /// Can be ticked in the sheet.
    pub selectable: bool,
    /// Is ticked in the sheet.
    pub selected: bool,
    /// The request that waits for approval for this season (the admin pills act on it).
    pub waiting_request: Option<i64>,
    /// The episodes TMDB lists for the season (empty when it lists none); the page shows them like a library page.
    pub episode_list: Vec<SeerrEpisodeInfo>,
}

/// One episode row of a season on the page: still of final size (the host holds the place), name, line, story.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrEpisodeInfo {
    /// Number in the season.
    pub number: i64,
    /// Name; "Folge 4" when TMDB has none.
    pub title: String,
    /// "45 Min. · 14. Nov." (parts that are unknown are left out).
    pub meta: String,
    /// Story.
    pub overview: Option<String>,
    /// Finished URL of the still; `None` when TMDB has none (the host draws the placeholder).
    pub still: Option<String>,
}

/// An on/off row of the sheet ("In 4K").
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrToggleRow {
    /// Label.
    pub label: String,
    /// State.
    pub on: bool,
}

/// One choice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeerrChoiceOption {
    /// Value to hand back.
    pub id: String,
    /// Label.
    pub name: String,
}

/// A pick row of the sheet ("Qualität", "Ordner").
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrChoiceRow {
    /// Label.
    pub label: String,
    /// The shown value.
    pub value: String,
    /// The options.
    pub options: Vec<SeerrChoiceOption>,
    /// The picked option's id.
    pub selected: String,
}

/// Where the sheet is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SheetPhase {
    /// Not shown.
    Closed,
    /// Shown, the user edits.
    Editing,
    /// The request is on its way.
    Sending,
    /// The server refused; `error` says why.
    Failed,
}

/// The request sheet as the host draws it.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrSheetInfo {
    /// Where it is.
    pub phase: SheetPhase,
    /// "Welche Staffeln?" or the film title.
    pub title: String,
    /// Season rows (series only).
    pub rows: Vec<SeerrSeasonRowInfo>,
    /// "Noch 1 von 3 Staffeln frei diese Woche"; `None` while loading or without limit.
    pub quota_line: Option<String>,
    /// The quota is still being read.
    pub quota_loading: bool,
    /// The line is the warning (nothing left).
    pub quota_warning: bool,
    /// The button under the rows.
    pub primary: SeerrPrimary,
    /// "In 4K" (only with the permission and when Seerr has a 4K lane).
    pub four_k: Option<SeerrToggleRow>,
    /// "Qualität" (admin).
    pub quality: Option<SeerrChoiceRow>,
    /// "Ordner" (admin).
    pub folder: Option<SeerrChoiceRow>,
    /// Why the last request failed.
    pub error: Option<String>,
}

/// Where the page stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TitleLoad {
    /// First load runs.
    Loading,
    /// No Seerr for this account: draw nothing.
    Unavailable,
    /// Seerr does not answer.
    Offline,
    /// Seerr answered with an error (see `error`).
    Failed,
    /// The page is there.
    Content,
}

/// The whole page.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrTitleInfo {
    /// Grows with every change.
    pub version: u64,
    /// State.
    pub load: TitleLoad,
    /// `movie` or `tv`.
    pub art: String,
    /// TMDB id.
    pub tmdb: i64,
    /// Seerr's media id (for problems and deleting), when it knows the title.
    pub media_id: Option<i64>,
    /// Title.
    pub title: String,
    /// "2008 · 7 Staffeln · Drama".
    pub secondary_line: String,
    /// Story.
    pub overview: Option<String>,
    /// TMDB rating above zero.
    pub rating: Option<f64>,
    /// Poster path.
    pub poster: Option<String>,
    /// Backdrop path.
    pub backdrop: Option<String>,
    /// Status of the title.
    pub badge: Option<SeerrBadge>,
    /// The title is on the server (the host shows its own page).
    pub on_server: bool,
    /// The button.
    pub primary: SeerrPrimary,
    /// Season list (series).
    pub seasons: Vec<SeerrSeasonRowInfo>,
    /// The first twelve people.
    pub cast: Vec<SeerrCast>,
    /// Similar titles not on the server.
    pub similar: Vec<SeerrTileCard>,
    /// The request sheet.
    pub sheet: SeerrSheetInfo,
    /// Why `load` is `Failed`.
    pub error: Option<String>,
}

impl SeerrTitleInfo {
    /// The season whose episodes the page lists: the one the person picked, else the first season that has episodes
    /// (`None` when TMDB lists none). One rule for every Rust host; the choice itself is the host's view state.
    pub fn episode_season(&self, picked: Option<i64>) -> Option<&SeerrSeasonRowInfo> {
        let listed = |s: &&SeerrSeasonRowInfo| !s.episode_list.is_empty();
        self.seasons
            .iter()
            .filter(listed)
            .find(|s| Some(s.number) == picked)
            .or_else(|| self.seasons.iter().find(listed))
    }
}

/// The account behind the page, from the hub.
#[derive(Debug, Clone, Default)]
pub struct SeerrAccount {
    /// Seerr's user id.
    pub user_id: i64,
    /// Permissions.
    pub perms: Perms,
    /// The quota of `art`, when known.
    pub quota: Option<QuotaPart>,
    /// What the server allows.
    pub public: PublicSettings,
}

/// What the request sheet still needs from the host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SheetNeeds {
    /// Read the quota again.
    pub quota: bool,
    /// Read the Radarr/Sonarr choices (admin).
    pub services: bool,
}

/// How a request ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestEnd {
    /// It is in. `auto_approved`: no admin needed.
    Requested {
        /// Approved on the spot.
        auto_approved: bool,
    },
    /// Somebody asked before: the page re-reads and shows "Angefragt".
    Exists,
    /// The sheet stays open with this text.
    Failed(String),
}

#[derive(Debug, Clone)]
enum QuotaState {
    Loading,
    Known(QuotaPart),
    Unlimited,
}

#[derive(Debug, Clone, Default)]
struct Choices {
    server: Option<i64>,
    profiles: Vec<(i64, String)>,
    folders: Vec<String>,
    profile: Option<i64>,
    folder: Option<String>,
}

/// The Radarr / Sonarr choices of the open sheet (administrators only).
///
/// **The rows stand from the sheet's first frame.** `Pending` draws "Qualität" and "Ordner" at their
/// final size with an empty value, so the rows ride up with the card and only their value fills in.
/// They used to be absent until the network answered and were inserted while the card was still sliding
/// up: everything else moved with the card, these two rows popped in at their end place.
#[derive(Debug, Clone)]
enum ChoicesState {
    /// The account may not choose (no rows).
    Absent,
    /// Asked for; the rows stand with empty values.
    Pending,
    /// The default server's choices.
    Ready(Choices),
}

impl ChoicesState {
    fn ready(&self) -> Option<&Choices> {
        match self {
            Self::Ready(c) => Some(c),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
enum Submit {
    Idle,
    Running,
    Failed(String),
}

#[derive(Debug, Clone)]
struct OpenSheet {
    selected: BTreeSet<i64>,
    four_k: bool,
    quota: QuotaState,
    choices: ChoicesState,
    submit: Submit,
}

#[derive(Debug, Clone)]
enum SheetState {
    Closed,
    Open(Box<OpenSheet>),
}

struct Loaded {
    info: TitleInfo,
    account: SeerrAccount,
    related: Vec<TitleCard>,
    sheet: SheetState,
    running: bool,
}

enum TitleState {
    Loading,
    Unavailable,
    Offline,
    Failed(String),
    Content(Box<Loaded>),
}

/// The view model of one title page and its request sheet.
pub struct SeerrTitleVm {
    t: Translator,
    art: String,
    tmdb: i64,
    today: String,
    library: BTreeSet<i64>,
    state: TitleState,
    version: u64,
}

impl SeerrTitleVm {
    /// A page for `art` (`movie` / `tv`) and the TMDB id.
    pub fn new(locale: Locale, art: &str, tmdb: i64, today: &str) -> Self {
        Self {
            t: Translator::new(locale),
            art: art.to_string(),
            tmdb,
            today: today.to_string(),
            library: BTreeSet::new(),
            state: TitleState::Loading,
            version: 1,
        }
    }

    fn bump(&mut self) {
        self.version += 1;
    }

    /// The version, moves with every change.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The seasons of the library (present on the server, switchable).
    pub fn set_library_seasons(&mut self, numbers: &[i64]) {
        self.library = numbers.iter().copied().collect();
        self.bump();
    }

    /// Seerr does not answer.
    pub fn offline(&mut self) {
        self.state = TitleState::Offline;
        self.bump();
    }

    /// The account has no Seerr: the page draws nothing.
    pub fn unavailable(&mut self) {
        self.state = TitleState::Unavailable;
        self.bump();
    }

    /// A (re)load starts; a page that is there stays.
    pub fn begin_load(&mut self) {
        if !matches!(self.state, TitleState::Content(_)) {
            self.state = TitleState::Loading;
            self.bump();
        }
    }

    /// The title came back.
    pub fn loaded(
        &mut self,
        title: Result<TitleInfo, AskError>,
        related: Vec<TitleCard>,
        account: SeerrAccount,
    ) {
        match title {
            Ok(info) => {
                let keep = match std::mem::replace(&mut self.state, TitleState::Loading) {
                    TitleState::Content(old) => old.sheet,
                    _ => SheetState::Closed,
                };
                self.state = TitleState::Content(Box::new(Loaded {
                    info,
                    account,
                    related,
                    sheet: keep,
                    running: false,
                }));
            }
            Err(e) if is_offline(&e) => self.state = TitleState::Offline,
            Err(AskError::SessionLost) => self.state = TitleState::Unavailable,
            Err(e) => self.state = TitleState::Failed(ask_text(&self.t, &e)),
        }
        self.bump();
    }

    fn content(&mut self) -> Option<&mut Loaded> {
        match &mut self.state {
            TitleState::Content(c) => Some(c),
            _ => None,
        }
    }

    // ---- the sheet

    /// Opens the sheet at once. `season`: the tapped (grey) season is ticked; `None` ticks only the first
    /// season that can be asked for (see [`first_requestable`]), none when no season can. Returns what the
    /// host should fetch for it.
    pub fn open_sheet(&mut self, season: Option<i64>) -> SheetNeeds {
        let art = self.art.clone();
        let today = self.today.clone();
        let library = self.library.clone();
        let t = Translator::new(self.t.locale().clone());
        let Some(c) = self.content() else {
            return SheetNeeds {
                quota: false,
                services: false,
            };
        };
        let rows = season_rows(c, &library, &today, &t);
        let selected: BTreeSet<i64> = if art == "tv" {
            match season {
                Some(n) => BTreeSet::from([n]),
                None => first_requestable(&rows).into_iter().collect(),
            }
        } else {
            BTreeSet::new()
        };
        let advanced = c.account.perms.can_choose_advanced();
        let quota = match c.account.quota {
            Some(q) if q.has_limit() => QuotaState::Known(q),
            Some(_) => QuotaState::Unlimited,
            None => QuotaState::Loading,
        };
        c.sheet = SheetState::Open(Box::new(OpenSheet {
            selected,
            four_k: false,
            quota,
            choices: if advanced {
                ChoicesState::Pending
            } else {
                ChoicesState::Absent
            },
            submit: Submit::Idle,
        }));
        self.bump();
        SheetNeeds {
            quota: true,
            services: advanced,
        }
    }

    /// The quota came back (`None`: it did not).
    pub fn quota_loaded(&mut self, quota: Option<QuotaPart>) {
        if let Some(c) = self.content() {
            c.account.quota = quota;
            if let SheetState::Open(s) = &mut c.sheet {
                s.quota = match quota {
                    Some(q) if q.has_limit() => QuotaState::Known(q),
                    _ => QuotaState::Unlimited,
                };
            }
        }
        self.bump();
    }

    /// The Radarr / Sonarr choices of the default server came back.
    pub fn services_loaded(&mut self, server: Option<i64>, detail: &ServiceDetail) {
        if let Some(c) = self.content()
            && let SheetState::Open(s) = &mut c.sheet
        {
            let active_profile = detail
                .server
                .as_ref()
                .and_then(|x| x.active_profile_id)
                .filter(|p| *p > 0);
            let active_dir = detail
                .server
                .as_ref()
                .and_then(|x| x.active_directory.clone());
            s.choices = ChoicesState::Ready(Choices {
                server,
                profiles: detail
                    .profiles
                    .iter()
                    .map(|p| (p.id, p.name.clone().unwrap_or_default()))
                    .collect(),
                folders: detail
                    .root_folders
                    .iter()
                    .filter_map(|f| f.path.clone())
                    .collect(),
                profile: active_profile,
                folder: active_dir,
            });
        }
        self.bump();
    }

    /// The choices could not be read: the reserved rows go (the request goes to Seerr's defaults).
    pub fn services_failed(&mut self) {
        if let Some(c) = self.content()
            && let SheetState::Open(s) = &mut c.sheet
            && matches!(s.choices, ChoicesState::Pending)
        {
            s.choices = ChoicesState::Absent;
        }
        self.bump();
    }

    /// A season row was tapped.
    pub fn toggle(&mut self, number: i64) {
        let (library, today) = (self.library.clone(), self.today.clone());
        let t = Translator::new(self.t.locale().clone());
        if let Some(c) = self.content() {
            let fixed = !c.account.public.partial_requests_enabled;
            let ok = season_rows(c, &library, &today, &t)
                .iter()
                .any(|r| r.number == number && r.selectable);
            if let SheetState::Open(s) = &mut c.sheet
                && ok
                && !fixed
                && !matches!(s.submit, Submit::Running)
            {
                if !s.selected.remove(&number) {
                    s.selected.insert(number);
                }
                s.submit = Submit::Idle;
            }
        }
        self.bump();
    }

    /// "In 4K".
    pub fn set_four_k(&mut self, on: bool) {
        if let Some(c) = self.content()
            && let SheetState::Open(s) = &mut c.sheet
        {
            s.four_k = on;
        }
        self.bump();
    }

    /// "Qualität" picked.
    pub fn choose_quality(&mut self, id: i64) {
        if let Some(c) = self.content()
            && let SheetState::Open(s) = &mut c.sheet
            && let ChoicesState::Ready(ch) = &mut s.choices
        {
            ch.profile = Some(id);
        }
        self.bump();
    }

    /// "Ordner" picked.
    pub fn choose_folder(&mut self, path: &str) {
        if let Some(c) = self.content()
            && let SheetState::Open(s) = &mut c.sheet
            && let ChoicesState::Ready(ch) = &mut s.choices
        {
            ch.folder = Some(path.to_string());
        }
        self.bump();
    }

    /// The sheet was closed.
    pub fn close_sheet(&mut self) {
        if let Some(c) = self.content() {
            c.sheet = SheetState::Closed;
        }
        self.bump();
    }

    /// The sheet's button. `Some(spec)`: send it; `None`: nothing to send (not pressable).
    pub fn confirm(&mut self) -> Option<(RequestSpec, Perms)> {
        let t = Translator::new(self.t.locale().clone());
        let (art, tmdb, library, today) = (
            self.art.clone(),
            self.tmdb,
            self.library.clone(),
            self.today.clone(),
        );
        let c = self.content()?;
        let perms = c.account.perms;
        let primary = sheet_primary(c, &library, &today, &t);
        let rows = season_rows(c, &library, &today, &t);
        let fixed = !c.account.public.partial_requests_enabled;
        let SheetState::Open(s) = &mut c.sheet else {
            return None;
        };
        if !primary.enabled || matches!(s.submit, Submit::Running) {
            return None;
        }
        let mut spec = RequestSpec::new(&art, tmdb);
        if art == "tv" {
            let seasons: Vec<i64> = if fixed {
                rows.iter()
                    .filter(|r| r.selected)
                    .map(|r| r.number)
                    .collect()
            } else {
                s.selected.iter().copied().collect()
            };
            spec = spec.with_seasons(&seasons);
        }
        spec.is4k = s.four_k;
        if let Some(ch) = s.choices.ready() {
            spec.server_id = ch.server;
            spec.profile_id = ch.profile;
            spec.root_folder = ch.folder.clone();
        }
        s.submit = Submit::Running;
        c.running = true;
        self.bump();
        Some((spec, perms))
    }

    /// The request came back.
    pub fn asked(&mut self, result: Result<RequestOutcome, AskError>) -> RequestEnd {
        let t = Translator::new(self.t.locale().clone());
        let art = self.art.clone();
        let mut end = RequestEnd::Exists;
        if let Some(c) = self.content() {
            c.running = false;
            match result {
                Ok(out) => {
                    // The quota counts the asked seasons (series) or the film.
                    if let SheetState::Open(s) = &c.sheet {
                        let n = if art == "tv" {
                            i64::try_from(s.selected.len().max(1)).unwrap_or(1)
                        } else {
                            1
                        };
                        if let Some(q) = &mut c.account.quota
                            && q.has_limit()
                        {
                            q.used += n;
                            q.remaining = q.remaining.map(|r| (r - n).max(0));
                        }
                    }
                    c.sheet = SheetState::Closed;
                    end = RequestEnd::Requested {
                        auto_approved: out.auto_approved,
                    };
                }
                Err(AskError::Exists) => {
                    c.sheet = SheetState::Closed;
                }
                Err(e) => {
                    let text = ask_text(&t, &e);
                    if let SheetState::Open(s) = &mut c.sheet {
                        s.submit = Submit::Failed(text.clone());
                    }
                    end = RequestEnd::Failed(text);
                }
            }
        }
        self.bump();
        end
    }

    // ---- what the host draws

    /// The page now.
    pub fn info(&self) -> SeerrTitleInfo {
        let t = &self.t;
        let mut info = SeerrTitleInfo {
            version: self.version,
            load: TitleLoad::Loading,
            art: self.art.clone(),
            tmdb: self.tmdb,
            media_id: None,
            title: String::new(),
            secondary_line: String::new(),
            overview: None,
            rating: None,
            poster: None,
            backdrop: None,
            badge: None,
            on_server: false,
            primary: SeerrPrimary {
                kind: PrimaryKind::Hidden,
                text: String::new(),
                enabled: false,
            },
            seasons: Vec::new(),
            cast: Vec::new(),
            similar: Vec::new(),
            sheet: closed_sheet(),
            error: None,
        };
        let c = match &self.state {
            TitleState::Loading => return info,
            TitleState::Unavailable => {
                info.load = TitleLoad::Unavailable;
                return info;
            }
            TitleState::Offline => {
                info.load = TitleLoad::Offline;
                info.error = Some(t.t("Seerr antwortet gerade nicht."));
                return info;
            }
            TitleState::Failed(text) => {
                info.load = TitleLoad::Failed;
                info.error = Some(text.clone());
                return info;
            }
            TitleState::Content(c) => c,
        };
        let status = c.info.status(&self.today, false, None);
        info.load = TitleLoad::Content;
        info.media_id = c.info.media.as_ref().map(|m| m.id).filter(|id| *id > 0);
        info.title = c.info.title.clone();
        info.secondary_line = secondary_line(t, &c.info);
        info.overview = c.info.overview.clone().filter(|s| !s.is_empty());
        info.rating = c.info.rating.filter(|r| *r > 0.0);
        info.poster = tmdb_image(c.info.poster_path.as_deref(), TmdbSize::Poster);
        // The poster stands in when the title has no wide picture, so the head is never empty.
        info.backdrop = tmdb_image(c.info.backdrop_path.as_deref(), TmdbSize::Backdrop)
            .or_else(|| tmdb_image(c.info.poster_path.as_deref(), TmdbSize::Backdrop));
        info.badge = Some(badge_of(t, &status));
        info.on_server = status == SeerrStatus::Available;
        info.primary = page_primary(t, c, &status, &self.art);
        info.seasons = season_rows(c, &self.library, &self.today, t);
        info.cast = c
            .info
            .cast
            .iter()
            .take(12)
            .map(|p| SeerrCast {
                person: p.id,
                name: p.name.clone(),
                role: p.role.clone(),
                image: tmdb_image(p.image_path.as_deref(), TmdbSize::Profile),
            })
            .collect();
        info.similar = c
            .related
            .iter()
            .map(|card| tile_of(t, card, &self.today))
            .filter(|tile| !tile.on_server)
            .take(20)
            .collect();
        info.sheet = sheet_info(t, c, &self.library, &self.today, &self.art);
        info
    }

    /// The seasons for the season picker of a library series: the library's and Seerr's merged.
    pub fn season_picker(&self) -> Vec<SeerrSeasonRowInfo> {
        match &self.state {
            TitleState::Content(c) => season_rows(c, &self.library, &self.today, &self.t),
            _ => Vec::new(),
        }
    }
}

fn closed_sheet() -> SeerrSheetInfo {
    SeerrSheetInfo {
        phase: SheetPhase::Closed,
        title: String::new(),
        rows: Vec::new(),
        quota_line: None,
        quota_loading: false,
        quota_warning: false,
        primary: SeerrPrimary {
            kind: PrimaryKind::Hidden,
            text: String::new(),
            enabled: false,
        },
        four_k: None,
        quality: None,
        folder: None,
        error: None,
    }
}

fn secondary_line(t: &Translator, info: &TitleInfo) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(y) = info.release_date.as_deref().and_then(|d| d.get(..4)) {
        parts.push(y.to_string());
    }
    if info.art == "tv" && !info.seasons.is_empty() {
        let n = i64::try_from(info.seasons.len()).unwrap_or(0);
        parts.push(t.t_args(
            if n == 1 {
                "%lld Staffel"
            } else {
                "%lld Staffeln"
            },
            &[Arg::Int(n)],
        ));
    } else if let Some(r) = info.runtime.filter(|r| *r > 0) {
        parts.push(t.t_args("%lld Min.", &[Arg::Int(r)]));
    }
    if !info.genres.is_empty() {
        parts.push(
            info.genres
                .iter()
                .take(3)
                .cloned()
                .collect::<Vec<_>>()
                .join(", "),
        );
    }
    parts.join(" · ")
}

fn quota_of(c: &Loaded) -> Option<QuotaPart> {
    c.account.quota.filter(|q| q.has_limit())
}

fn page_primary(t: &Translator, c: &Loaded, status: &SeerrStatus, art: &str) -> SeerrPrimary {
    let make = |kind, text: &str, enabled| SeerrPrimary {
        kind,
        text: t.t(text),
        enabled,
    };
    if c.running {
        return make(PrimaryKind::Busy, "Wird angefragt…", false);
    }
    if !c.account.perms.can_request(art) {
        return make(PrimaryKind::Hidden, "", false);
    }
    match status {
        SeerrStatus::Blocked | SeerrStatus::Available | SeerrStatus::Failed => {
            make(PrimaryKind::Hidden, "", false)
        }
        s if s.is_requested() => make(PrimaryKind::Requested, "Angefragt", false),
        _ => {
            if quota_of(c).is_some_and(|q| q.used_up()) {
                make(PrimaryKind::Locked, "Limit erreicht", false)
            } else {
                make(PrimaryKind::Request, "Anfragen", true)
            }
        }
    }
}

fn four_k_offered(c: &Loaded, art: &str) -> bool {
    c.account.public.four_k_enabled(art) && c.account.perms.can_request_4k(art)
}

/// The one season the sheet ticks on its own: the first that is neither on the server nor available nor
/// requested (`selectable`). Specials (season 0) only when no numbered season can be asked for.
fn first_requestable(rows: &[SeerrSeasonRowInfo]) -> Option<i64> {
    let mut open = rows.iter().filter(|r| r.selectable);
    let first = open.next()?;
    if first.number > 0 {
        return Some(first.number);
    }
    Some(open.next().map_or(first.number, |r| r.number))
}

/// Season rows of the page, picker and sheet. `selected` is taken from the open sheet.
fn season_rows(
    c: &Loaded,
    library: &BTreeSet<i64>,
    today: &str,
    t: &Translator,
) -> Vec<SeerrSeasonRowInfo> {
    if c.info.art != "tv" {
        return Vec::new();
    }
    let selected = match &c.sheet {
        SheetState::Open(s) => s.selected.clone(),
        SheetState::Closed => BTreeSet::new(),
    };
    let fixed = !c.account.public.partial_requests_enabled;
    let can = c.account.perms.can_request_tv();
    let mut numbers: BTreeSet<i64> = c
        .info
        .seasons
        .iter()
        .map(|s| s.season_number)
        .filter(|n| *n > 0 || c.account.public.enable_special_episodes)
        .collect();
    numbers.extend(library.iter().copied());
    numbers
        .into_iter()
        .map(|n| {
            let status = c.info.status(today, false, Some(n));
            let on_server = library.contains(&n);
            let selectable = can
                && !on_server
                && status.can_request()
                && !matches!(status, SeerrStatus::Blocked);
            let episodes = c
                .info
                .seasons
                .iter()
                .find(|s| s.season_number == n)
                .map(|s| s.episode_count)
                .filter(|e| *e > 0)
                .map(|e| t.t_args("%lld Folgen", &[Arg::Int(e)]));
            let episode_list = c
                .info
                .seasons
                .iter()
                .find(|s| s.season_number == n)
                .map(|s| episode_rows(t, &s.episodes))
                .unwrap_or_default();
            SeerrSeasonRowInfo {
                number: n,
                title: if n == 0 {
                    t.t("Specials")
                } else {
                    t.t_args("Staffel %lld", &[Arg::Int(n)])
                },
                episodes,
                badge: badge_of(
                    t,
                    &if on_server {
                        SeerrStatus::Available
                    } else {
                        status.clone()
                    },
                ),
                on_server,
                missing: !on_server && !matches!(status, SeerrStatus::Available),
                selectable: selectable && !fixed,
                selected: selectable && (fixed || selected.contains(&n)),
                waiting_request: waiting_request(c.info.media.as_ref(), n),
                episode_list,
            }
        })
        .collect()
}

/// The rows of a season's episodes, in order of their number.
fn episode_rows(t: &Translator, episodes: &[TitleEpisode]) -> Vec<SeerrEpisodeInfo> {
    let mut rows: Vec<&TitleEpisode> = episodes.iter().filter(|e| e.episode_number > 0).collect();
    rows.sort_by_key(|e| e.episode_number);
    rows.into_iter()
        .map(|e| {
            let mut meta = Vec::new();
            if let Some(min) = e.runtime.filter(|m| *m > 0) {
                meta.push(t.t_args("%lld Min.", &[Arg::Int(min)]));
            }
            if let Some(day) = e.air_date.as_deref().filter(|d| !d.is_empty()) {
                meta.push(short_date(t, day));
            }
            SeerrEpisodeInfo {
                number: e.episode_number,
                title: e
                    .name
                    .clone()
                    .filter(|n| !n.trim().is_empty())
                    .unwrap_or_else(|| t.t_args("Folge %lld", &[Arg::Int(e.episode_number)])),
                meta: meta.join(" · "),
                overview: e
                    .overview
                    .as_deref()
                    .map(str::trim)
                    .filter(|o| !o.is_empty())
                    .map(str::to_string),
                still: tmdb_image(e.still_path.as_deref(), TmdbSize::Still),
            }
        })
        .collect()
}

fn waiting_request(media: Option<&MediaInfo>, season: i64) -> Option<i64> {
    media?
        .requests
        .iter()
        .filter(|r| r.status == RequestStatus::Pending && !r.is4k)
        .filter(|r| r.seasons.is_empty() || r.seasons.iter().any(|s| s.season_number == season))
        .map(|r| r.id)
        .max()
}

fn sheet_primary(c: &Loaded, library: &BTreeSet<i64>, today: &str, t: &Translator) -> SeerrPrimary {
    let SheetState::Open(s) = &c.sheet else {
        return SeerrPrimary {
            kind: PrimaryKind::Hidden,
            text: String::new(),
            enabled: false,
        };
    };
    let tv = c.info.art == "tv";
    let rows = season_rows(c, library, today, t);
    let fixed = !c.account.public.partial_requests_enabled;
    let count = if tv {
        i64::try_from(if fixed {
            rows.iter().filter(|r| r.selected).count()
        } else {
            s.selected.len()
        })
        .unwrap_or(0)
    } else {
        1
    };
    let text = if !tv {
        t.t("Anfragen")
    } else if fixed {
        t.t("Alle Staffeln anfragen")
    } else if count == 1 {
        let n = s.selected.iter().next().copied().unwrap_or(0);
        t.t_args("Staffel %lld anfragen", &[Arg::Int(n)])
    } else if count > 1 {
        t.t_args("%lld Staffeln anfragen", &[Arg::Int(count)])
    } else {
        t.t("Anfragen")
    };
    let quota = match &s.quota {
        QuotaState::Known(q) => Some(*q),
        _ => None,
    };
    let (kind, enabled) = if matches!(s.submit, Submit::Running) {
        (PrimaryKind::Busy, false)
    } else if quota.is_some_and(|q| q.used_up() || q.left().is_some_and(|left| count > left)) {
        (PrimaryKind::Locked, false)
    } else {
        (PrimaryKind::Request, count > 0)
    };
    SeerrPrimary {
        kind,
        text,
        enabled,
    }
}

fn sheet_info(
    t: &Translator,
    c: &Loaded,
    library: &BTreeSet<i64>,
    today: &str,
    art: &str,
) -> SeerrSheetInfo {
    let SheetState::Open(s) = &c.sheet else {
        return closed_sheet();
    };
    let primary = sheet_primary(c, library, today, t);
    let (quota_line, quota_warning) = match &s.quota {
        QuotaState::Known(q) => {
            let count = i64::try_from(s.selected.len()).unwrap_or(0);
            match quota_line(t, art, q) {
                Some((_, false)) if art == "tv" && q.left().is_some_and(|l| count > l) => (
                    Some(t.t_args("Nur noch %lld frei", &[Arg::Int(q.left().unwrap_or(0))])),
                    true,
                ),
                Some((text, warn)) => (Some(text), warn),
                None => (None, false),
            }
        }
        _ => (None, false),
    };
    let choice = |label: &str, options: Vec<SeerrChoiceOption>, selected: String| {
        let value = options
            .iter()
            .find(|o| o.id == selected)
            .map(|o| o.name.clone())
            .unwrap_or_default();
        SeerrChoiceRow {
            label: t.t(label),
            value,
            options,
            selected,
        }
    };
    // Pending: the row at its final size with an empty value (see `ChoicesState`).
    let (quality, folder) = match &s.choices {
        ChoicesState::Absent => (None, None),
        ChoicesState::Pending => (
            Some(choice("Qualität", Vec::new(), String::new())),
            Some(choice("Ordner", Vec::new(), String::new())),
        ),
        ChoicesState::Ready(ch) => (
            (!ch.profiles.is_empty()).then(|| {
                choice(
                    "Qualität",
                    ch.profiles
                        .iter()
                        .map(|(id, name)| SeerrChoiceOption {
                            id: id.to_string(),
                            name: name.clone(),
                        })
                        .collect(),
                    ch.profile.map(|p| p.to_string()).unwrap_or_default(),
                )
            }),
            (!ch.folders.is_empty()).then(|| {
                choice(
                    "Ordner",
                    ch.folders
                        .iter()
                        .map(|f| SeerrChoiceOption {
                            id: f.clone(),
                            name: f.clone(),
                        })
                        .collect(),
                    ch.folder.clone().unwrap_or_default(),
                )
            }),
        ),
    };
    let (phase, error) = match &s.submit {
        Submit::Idle => (SheetPhase::Editing, None),
        Submit::Running => (SheetPhase::Sending, None),
        Submit::Failed(text) => (SheetPhase::Failed, Some(text.clone())),
    };
    SeerrSheetInfo {
        phase,
        title: if art == "tv" {
            t.t("Welche Staffeln?")
        } else {
            c.info.title.clone()
        },
        rows: season_rows(c, library, today, t),
        quota_line,
        quota_loading: matches!(s.quota, QuotaState::Loading),
        quota_warning,
        primary,
        four_k: four_k_offered(c, art).then(|| SeerrToggleRow {
            label: t.t("In 4K"),
            on: s.four_k,
        }),
        quality,
        folder,
        error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn de() -> Translator {
        Translator::new(Locale::parse("de"))
    }

    #[test]
    fn one_word_table_for_every_state() {
        let t = de();
        let fetching = SeerrStatus::Fetching {
            percent: 62,
            eta_seconds: None,
        };
        let soon = SeerrStatus::Soon {
            date: "2026-11-28".into(),
            requested: false,
        };
        let rows: [(SeerrStatus, &str, &str); 9] = [
            (SeerrStatus::Requestable, "+", "Nicht auf deinem Server"),
            (SeerrStatus::Waits, "wartet", "Wartet auf Freigabe"),
            (fetching, "62 %", "Wird geholt · 62 %"),
            (soon, "28. Nov.", "Erscheint am 28. Nov."),
            (SeerrStatus::Declined, "abgelehnt", "Abgelehnt"),
            (
                SeerrStatus::Failed,
                "fehlgeschlagen",
                "Holen fehlgeschlagen",
            ),
            (SeerrStatus::Blocked, "gesperrt", "Gesperrt"),
            (SeerrStatus::Partial, "teilweise", "Teilweise da"),
            (SeerrStatus::Searching, "wird gesucht", "Wird gesucht"),
        ];
        for (status, word, line) in rows {
            let b = badge_of(&t, &status);
            assert_eq!((b.word.as_str(), b.line.as_str()), (word, line));
        }
        let b = badge_of(
            &t,
            &SeerrStatus::Fetching {
                percent: 62,
                eta_seconds: None,
            },
        );
        assert_eq!(b.progress, Some(0.62));
    }

    #[test]
    fn quota_words_follow_the_window_and_stay_away_without_a_limit() {
        let t = de();
        let part = |days, limit, used, remaining| QuotaPart {
            days,
            limit,
            used,
            remaining,
            restricted: remaining == Some(0),
        };
        let line = |art, p: QuotaPart| quota_line(&t, art, &p);
        assert_eq!(
            line("tv", part(Some(7), Some(3), 2, Some(1))),
            Some(("Noch 1 von 3 Staffeln frei diese Woche".into(), false))
        );
        assert_eq!(
            line("movie", part(Some(1), Some(1), 0, Some(0))),
            Some(("Nichts mehr frei heute".into(), true))
        );
        assert_eq!(
            line("movie", part(Some(14), Some(5), 1, Some(4))).map(|l| l.0),
            Some("Noch 4 von 5 Filmen frei in 14 Tagen".replace("Filmen", "Filme"))
        );
        assert_eq!(
            line("tv", part(None, None, 4, None)),
            None,
            "admins and unlimited accounts"
        );
    }

    #[test]
    fn every_refusal_has_a_sentence_and_only_a_dead_server_is_offline() {
        let t = de();
        assert_eq!(
            ask_text(&t, &AskError::QuotaExceeded("Movie Quota exceeded.".into())),
            "Dein Film-Limit für diese Woche ist erreicht."
        );
        assert_eq!(
            ask_text(
                &t,
                &AskError::QuotaExceeded("Series Quota exceeded.".into())
            ),
            "Dein Serien-Limit für diese Woche ist erreicht."
        );
        assert_eq!(
            ask_text(
                &t,
                &AskError::QuotaExceeded("TV Request Quota exceeded.".into())
            ),
            "Dein Serien-Limit für diese Woche ist erreicht."
        );
        assert_eq!(
            ask_text(&t, &AskError::QuotaExceeded("Quota exceeded.".into())),
            "Dein Limit ist aufgebraucht."
        );
        assert_eq!(
            ask_text(&t, &AskError::NoPermission),
            "Dafür fehlt dir die Berechtigung."
        );
        assert_eq!(ask_text(&t, &AskError::Exists), "Das ist schon angefragt.");
        assert_eq!(
            ask_text(&t, &AskError::Blocked),
            "Dieser Titel ist gesperrt."
        );
        assert_eq!(
            ask_text(&t, &AskError::SessionLost),
            "Seerr braucht eine neue Anmeldung."
        );
        assert!(!is_offline(&AskError::NoPermission));
        assert!(is_offline(&AskError::Failed {
            status: 503,
            text: String::new()
        }));
    }

    #[test]
    fn dates_read_as_day_and_month() {
        let t = de();
        assert_eq!(short_date(&t, "2026-03-05"), "5. März");
        assert_eq!(short_date(&t, "2026-12-24T10:00:00Z"), "24. Dez.");
        assert_eq!(short_date(&t, "unklar"), "unklar");
        let today = today_utc();
        assert_eq!(today.len(), 10);
        assert!(today.as_str() > "2026-01-01");
    }

    #[test]
    fn times_read_relative_then_as_a_day() {
        let t = de();
        // 2026-11-18 12:00:00 UTC
        let now = swiftly_model::parse_timestamp("2026-11-18T12:00:00.000Z").unwrap();
        let at = |iso: &str| when_text_at(&t, iso, now);
        assert_eq!(at("2026-11-18T11:59:40.000Z"), "gerade eben");
        assert_eq!(at("2026-11-18T11:55:00.000Z"), "vor 5 Min.");
        assert_eq!(at("2026-11-18T09:00:00.000Z"), "vor 3 Std.");
        assert_eq!(at("2026-11-17T20:00:00.000Z"), "gestern");
        assert_eq!(at("2026-11-15T10:00:00.000Z"), "vor 3 Tagen");
        assert_eq!(at("2026-11-10T10:00:00.000Z"), "10. Nov.");
        assert_eq!(at("2025-12-24T10:00:00.000Z"), "24. Dez. 2025");
        assert_eq!(at("unklar"), "unklar");
        // The raw timestamp never comes through for an ISO input.
        assert!(!at("2026-11-10T10:00:00.000Z").contains('T'));
        let en = Translator::new(Locale::parse("en"));
        assert_eq!(
            when_text_at(&en, "2026-11-15T10:00:00.000Z", now),
            "3 days ago"
        );
        assert_eq!(
            when_text_at(&en, "2026-11-18T09:00:00.000Z", now),
            "3 h ago"
        );
        let ru = Translator::new(Locale::parse("ru"));
        assert_eq!(when_text_at(&ru, "2026-11-17T20:00:00.000Z", now), "вчера");
    }

    fn series(media: &str) -> TitleInfo {
        TitleInfo {
            id: 7,
            art: "tv".into(),
            title: "Serie".into(),
            tagline: None,
            overview: None,
            release_date: Some("2010-01-01".into()),
            genres: vec!["Krimi".into()],
            runtime: None,
            rating: Some(7.5),
            poster_path: None,
            backdrop_path: None,
            tmdb_status: None,
            seasons: (1..=3)
                .map(|n| swiftly_seerr::types::TitleSeason {
                    season_number: n,
                    episode_count: 8,
                    name: None,
                    air_date: Some("2011-01-01".into()),
                    ..Default::default()
                })
                .collect(),
            cast: Vec::new(),
            collection: None,
            media: serde_json::from_str(media).ok(),
        }
    }

    fn loaded(vm: &mut SeerrTitleVm, perms: i64, public: PublicSettings, media: &str) {
        vm.loaded(
            Ok(series(media)),
            Vec::new(),
            SeerrAccount {
                user_id: 2,
                perms: Perms(perms),
                quota: None,
                public,
            },
        );
    }

    #[test]
    fn without_partial_requests_the_sheet_asks_for_all_open_seasons() {
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-14");
        let public = PublicSettings {
            partial_requests_enabled: false,
            ..PublicSettings::default()
        };
        loaded(&mut vm, 32, public, r#"{"id":1,"status":1}"#);
        let sheet = {
            vm.open_sheet(None);
            vm.info().sheet
        };
        assert!(sheet.rows.iter().all(|r| !r.selectable && r.selected));
        assert_eq!(sheet.primary.text, "Alle Staffeln anfragen");
        let (spec, _) = vm.confirm().expect("spec");
        assert_eq!(spec.seasons, Some(vec![1, 2, 3]));
        // A running request blocks a second press.
        assert!(vm.confirm().is_none());
        assert_eq!(vm.info().sheet.phase, SheetPhase::Sending);
    }

    fn ticked(vm: &SeerrTitleVm) -> Vec<i64> {
        vm.info()
            .sheet
            .rows
            .iter()
            .filter(|r| r.selected)
            .map(|r| r.number)
            .collect()
    }

    #[test]
    fn the_sheet_ticks_only_the_first_season_that_can_be_requested() {
        let public = PublicSettings {
            partial_requests_enabled: true,
            ..PublicSettings::default()
        };
        let sheet_after = |media: &str| {
            let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-14");
            loaded(&mut vm, 32, public.clone(), media);
            vm.open_sheet(None);
            vm
        };
        // Nothing asked yet: season 1 only, not all three.
        let vm = sheet_after("");
        assert_eq!(ticked(&vm), [1]);
        assert_eq!(vm.info().sheet.primary.text, "Staffel 1 anfragen");
        assert!(vm.info().sheet.primary.enabled);
        // Season 1 is available and season 2 already requested: the first one left is season 3.
        let vm = sheet_after(
            r#"{"id":1,"status":4,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":2}]}"#,
        );
        assert_eq!(ticked(&vm), [3]);
        // Every season is available or requested: nothing is ticked and there is nothing to send.
        let mut vm = sheet_after(
            r#"{"id":1,"status":4,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":2},{"seasonNumber":3,"status":3}]}"#,
        );
        assert!(ticked(&vm).is_empty());
        assert!(!vm.info().sheet.primary.enabled);
        assert!(vm.confirm().is_none());
        // A tapped grey season still opens the sheet with exactly that one.
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-14");
        loaded(&mut vm, 32, public, "");
        vm.open_sheet(Some(3));
        assert_eq!(ticked(&vm), [3]);
    }

    #[test]
    fn specials_are_ticked_only_when_no_numbered_season_can_be_requested() {
        let t = Translator::new(Locale::parse("de"));
        let row = |number: i64, selectable: bool| SeerrSeasonRowInfo {
            number,
            title: String::new(),
            episodes: None,
            badge: badge_of(&t, &SeerrStatus::Available),
            on_server: false,
            missing: selectable,
            selectable,
            selected: false,
            waiting_request: None,
            episode_list: Vec::new(),
        };
        assert_eq!(first_requestable(&[row(0, true), row(1, true)]), Some(1));
        assert_eq!(first_requestable(&[row(0, true), row(1, false)]), Some(0));
        assert_eq!(first_requestable(&[row(0, false), row(1, false)]), None);
        assert_eq!(first_requestable(&[]), None);
    }

    #[test]
    fn a_film_sheet_has_no_rows_and_four_k_needs_the_permission_and_the_lane() {
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-14");
        let public = PublicSettings {
            series4k_enabled: true,
            partial_requests_enabled: true,
            ..PublicSettings::default()
        };
        loaded(&mut vm, 32, public.clone(), "");
        vm.open_sheet(Some(2));
        assert!(vm.info().sheet.four_k.is_none(), "no REQUEST_4K");
        loaded(&mut vm, 32 | 1024, public, "");
        vm.open_sheet(Some(2));
        let four_k = vm.info().sheet.four_k.expect("4K row");
        assert!(!four_k.on);
        vm.set_four_k(true);
        let (spec, _) = vm.confirm().expect("spec");
        assert!(spec.is4k);
    }

    /// **A sheet opens complete**: an administrator's "Qualität" and "Ordner" rows stand from the
    /// first record on (empty values while the choices are read), so they never get inserted while the
    /// card slides up. Only the values change when the choices arrive.
    #[test]
    fn the_admin_rows_stand_from_the_first_frame_and_only_their_values_fill_in() {
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-14");
        let public = PublicSettings {
            partial_requests_enabled: true,
            ..PublicSettings::default()
        };
        loaded(&mut vm, 32 | 8192, public.clone(), "");
        let needs = vm.open_sheet(None);
        assert!(needs.services);
        let first = vm.info().sheet;
        let (q, f) = (
            first.quality.expect("quality row"),
            first.folder.expect("folder row"),
        );
        assert_eq!((q.label.as_str(), q.value.as_str()), ("Qualität", ""));
        assert_eq!((f.label.as_str(), f.value.as_str()), ("Ordner", ""));
        let detail: ServiceDetail = serde_json::from_str(
            r#"{"server":{"id":1,"activeProfileId":4,"activeDirectory":"/tv"},
                "profiles":[{"id":4,"name":"HD-1080p"}],"rootFolders":[{"id":1,"path":"/tv"}]}"#,
        )
        .expect("detail");
        vm.services_loaded(Some(1), &detail);
        let after = vm.info().sheet;
        assert_eq!(after.quality.expect("quality").value, "HD-1080p");
        assert_eq!(after.folder.expect("folder").value, "/tv");
        assert_eq!(after.rows.len(), first.rows.len());
        // A failed read takes the reserved rows away; a user without the permission never has them.
        vm.open_sheet(None);
        vm.services_failed();
        assert!(vm.info().sheet.quality.is_none());
        loaded(&mut vm, 32, public, "");
        assert!(!vm.open_sheet(None).services);
        assert!(vm.info().sheet.quality.is_none() && vm.info().sheet.folder.is_none());
    }

    #[test]
    fn a_blocked_title_and_a_missing_permission_offer_no_button() {
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-14");
        loaded(
            &mut vm,
            32,
            PublicSettings::default(),
            r#"{"id":1,"status":6}"#,
        );
        let info = vm.info();
        assert_eq!(
            info.badge.as_ref().map(|b| b.word.as_str()),
            Some("gesperrt")
        );
        assert_eq!(info.primary.kind, PrimaryKind::Hidden);
        loaded(
            &mut vm,
            0,
            PublicSettings::default(),
            r#"{"id":1,"status":1}"#,
        );
        assert_eq!(
            vm.info().primary.kind,
            PrimaryKind::Hidden,
            "no REQUEST bit"
        );
        loaded(
            &mut vm,
            32,
            PublicSettings::default(),
            r#"{"id":1,"status":7}"#,
        );
        assert_eq!(
            vm.info().primary.kind,
            PrimaryKind::Request,
            "a deleted title can be asked for again"
        );
    }

    #[test]
    fn page_states_are_one_enum() {
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "movie", 1, "2026-11-14");
        assert_eq!(vm.info().load, TitleLoad::Loading);
        vm.offline();
        assert_eq!(vm.info().load, TitleLoad::Offline);
        assert!(vm.info().error.is_some());
        vm.loaded(Err(AskError::NotFound), Vec::new(), SeerrAccount::default());
        assert_eq!(vm.info().load, TitleLoad::Failed);
        vm.loaded(
            Err(AskError::SessionLost),
            Vec::new(),
            SeerrAccount::default(),
        );
        assert_eq!(vm.info().load, TitleLoad::Unavailable);
    }
    #[test]
    fn the_page_gives_finished_picture_urls_and_the_episode_rows_of_every_season() {
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-17");
        let mut info = series("");
        info.poster_path = Some("/p.jpg".into());
        info.backdrop_path = None;
        info.cast = vec![swiftly_seerr::SeerrPerson {
            id: 1234,
            name: "Anna".into(),
            role: None,
            image_path: Some("/anna.jpg".into()),
        }];
        info.seasons[0].episodes = vec![
            TitleEpisode {
                episode_number: 2,
                name: None,
                overview: Some("  ".into()),
                air_date: Some("2025-03-02".into()),
                runtime: None,
                still_path: None,
            },
            TitleEpisode {
                episode_number: 1,
                name: Some("Auftakt".into()),
                overview: Some("Es beginnt.".into()),
                air_date: None,
                runtime: Some(45),
                still_path: Some("/s1.jpg".into()),
            },
        ];
        vm.loaded(Ok(info), Vec::new(), SeerrAccount::default());
        let page = vm.info();
        assert_eq!(
            page.poster.as_deref(),
            Some("https://image.tmdb.org/t/p/w342/p.jpg")
        );
        // No backdrop: the poster stands in at the wide size, so the head is never empty.
        assert_eq!(
            page.backdrop.as_deref(),
            Some("https://image.tmdb.org/t/p/w1280/p.jpg")
        );
        assert_eq!(
            page.cast[0].image.as_deref(),
            Some("https://image.tmdb.org/t/p/w185/anna.jpg")
        );
        // The TMDB person id of Seerr's credits reaches the tile: it is what the person page opens with.
        assert_eq!(page.cast[0].person, 1234);
        assert_eq!(page.cast[0].person_ref().tmdb, 1234);
        let rows = &page.seasons[0].episode_list;
        assert_eq!(
            rows.iter().map(|e| e.number).collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(rows[0].title, "Auftakt");
        assert_eq!(rows[0].meta, "45 Min.");
        assert_eq!(
            rows[0].still.as_deref(),
            Some("https://image.tmdb.org/t/p/w300/s1.jpg")
        );
        assert_eq!(rows[1].title, "Folge 2");
        assert_eq!(rows[1].meta, "2. März");
        assert_eq!(
            (rows[1].overview.clone(), rows[1].still.clone()),
            (None, None)
        );
        assert!(page.seasons[1].episode_list.is_empty());
    }

    #[test]
    fn the_episode_season_is_the_picked_one_else_the_first_with_episodes() {
        let mut vm = SeerrTitleVm::new(Locale::parse("de"), "tv", 7, "2026-11-17");
        let mut info = series("");
        let episode = |n| TitleEpisode {
            episode_number: n,
            name: Some(format!("Folge {n}")),
            overview: None,
            air_date: None,
            runtime: None,
            still_path: None,
        };
        let last = info.seasons.len() - 1;
        info.seasons[last].episodes = vec![episode(1)];
        vm.loaded(Ok(info), Vec::new(), SeerrAccount::default());
        let page = vm.info();
        let last_number = page.seasons[last].number;
        // Only the last season lists episodes: nothing picked, or a pick without episodes, falls to it.
        assert_eq!(
            page.episode_season(None).map(|s| s.number),
            Some(last_number)
        );
        assert_eq!(
            page.episode_season(Some(page.seasons[0].number))
                .map(|s| s.number),
            Some(last_number)
        );
        assert_eq!(
            page.episode_season(Some(last_number)).map(|s| s.number),
            Some(last_number)
        );
        let mut bare = page.clone();
        bare.seasons.iter_mut().for_each(|s| s.episode_list.clear());
        assert!(bare.episode_season(Some(last_number)).is_none());
    }
}
