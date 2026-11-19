//! The Seerr lists as view models (Sans-I/O, like [`crate::seerr_title`]): the hub (who am I, what
//! may I, the counts), discover rails, the search merge, the request list (mine and the admin
//! queue share it) and the home block. Each has one load enum and its transitions as methods.

use std::collections::{BTreeSet, HashMap};

use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_seerr::models::{TmdbSize, tmdb_image};
use swiftly_seerr::types::{
    DiscoverSlider, Me, Page, PublicSettings, Quota, RequestRow, RequestStatus, SearchResult,
    SliderKind, TitleCard, TitleInfo,
};
use swiftly_seerr::{
    AskError, Perms, SeasonDays, SeerrStatus, StatusInput, combine_seasons, season_request_status,
    status_of,
};

use crate::seerr_title::{
    BadgeKind, SeerrAccount, SeerrBadge, SeerrTileCard, ask_text, badge_of, is_offline, quota_line,
    tile_of,
};

// ---------------------------------------------------------------- titles of requests

/// The few facts of a title a request row needs (the request list carries only ids).
#[derive(Debug, Clone, PartialEq)]
pub struct TitleLite {
    /// Title.
    pub title: String,
    /// Release year.
    pub year: Option<i64>,
    /// The poster as a finished picture address (never a raw TMDB path).
    pub poster: Option<String>,
    /// `yyyy-mm-dd`.
    pub release_date: Option<String>,
    /// The days of every season (a series), for the status of a season request.
    pub seasons: Vec<SeasonDays>,
}

impl TitleLite {
    /// The seasons a request names; every season of the title when it names none. Empty for a film.
    fn wanted(&self, row: &RequestRow) -> Vec<&SeasonDays> {
        let named = row.season_numbers();
        self.seasons
            .iter()
            .filter(|s| named.is_empty() || named.contains(&s.number))
            .collect()
    }
}

/// "S2", "S1–2", "S1, S3", "S1–3, S5": the seasons of a request as a short tag (not translated, like an episode code).
pub fn season_tag(numbers: &[i64]) -> String {
    let mut sorted: Vec<i64> = numbers.iter().copied().filter(|n| *n > 0).collect();
    sorted.sort_unstable();
    sorted.dedup();
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < sorted.len() {
        let mut j = i;
        while j + 1 < sorted.len() && sorted[j + 1] == sorted[j] + 1 {
            j += 1;
        }
        parts.push(if j > i {
            format!("S{}\u{2013}{}", sorted[i], sorted[j])
        } else {
            format!("S{}", sorted[i])
        });
        i = j + 1;
    }
    parts.join(", ")
}

/// Titles by (art, TMDB id), filled by the host from `title()` answers.
#[derive(Debug, Clone, Default)]
pub struct TitleCache(HashMap<(String, i64), TitleLite>);

impl TitleCache {
    /// Remembers a title.
    pub fn put(&mut self, info: &TitleInfo) {
        let year = info
            .release_date
            .as_deref()
            .and_then(|d| d.get(..4))
            .and_then(|y| y.parse().ok());
        self.0.insert(
            (info.art.clone(), info.id),
            TitleLite {
                title: info.title.clone(),
                year,
                poster: tmdb_image(info.poster_path.as_deref(), TmdbSize::Poster),
                release_date: info.release_date.clone(),
                seasons: info
                    .seasons
                    .iter()
                    .filter(|s| s.season_number > 0)
                    .map(SeasonDays::of)
                    .collect(),
            },
        );
    }

    /// A known title.
    pub fn get(&self, art: &str, tmdb: i64) -> Option<&TitleLite> {
        self.0.get(&(art.to_string(), tmdb))
    }

    /// Which of these requests have no title yet.
    pub fn missing(&self, rows: &[RequestRow]) -> Vec<(String, i64)> {
        let mut out: Vec<(String, i64)> = rows
            .iter()
            .filter_map(key_of)
            .filter(|(art, id)| self.get(art, *id).is_none())
            .collect();
        out.sort();
        out.dedup();
        out
    }
}

fn key_of(r: &RequestRow) -> Option<(String, i64)> {
    let media = r.media.as_ref()?;
    let id = media.tmdb_id?;
    let art = r
        .media_type
        .clone()
        .or_else(|| media.media_type.clone())
        .unwrap_or_else(|| "movie".into());
    Some((art, id))
}

/// The status of one request row: the request's own verdict first, then what the server and the download say.
///
/// A series request is judged season by season (the seasons it names, or all): a season that has not started yet is
/// "erscheint am" with its first day, a season whose aired episodes are all there while later ones are to come is
/// "alle bisherigen Folgen da", and only a released season with nothing there is "wird gesucht".
pub fn request_status(row: &RequestRow, title: Option<&TitleLite>, today: &str) -> SeerrStatus {
    let release = title.and_then(|t| t.release_date.as_deref());
    let seasons = title.map(|t| t.wanted(row)).unwrap_or_default();
    match row.status {
        RequestStatus::Pending => SeerrStatus::Waits,
        RequestStatus::Declined => SeerrStatus::Declined,
        RequestStatus::Failed => SeerrStatus::Failed,
        RequestStatus::Completed => match seasons.iter().filter_map(|s| s.next_day(today)).min() {
            Some(day) => SeerrStatus::UpToDate {
                next: Some(day.to_string()),
            },
            None => SeerrStatus::Available,
        },
        RequestStatus::Approved if !seasons.is_empty() => combine_seasons(
            seasons
                .iter()
                .map(|s| season_request_status(row.media.as_deref(), row.is4k, s, today))
                .collect(),
        ),
        RequestStatus::Approved => {
            let s = status_of(&StatusInput {
                media: row.media.as_deref(),
                is4k: row.is4k,
                season: None,
                release_date: release,
                today,
            });
            match s {
                SeerrStatus::Fetching { .. }
                | SeerrStatus::Available
                | SeerrStatus::Partial
                | SeerrStatus::Searching
                | SeerrStatus::Soon { .. } => s,
                _ => match release.filter(|d| !d.is_empty() && *d > today) {
                    Some(d) => SeerrStatus::Soon {
                        date: d.to_string(),
                        requested: true,
                    },
                    None => SeerrStatus::Searching,
                },
            }
        }
    }
}

/// What a request row is called and which year it shows: a season request names its seasons ("Sweet P · S2") and
/// takes the year of its first season; a film or a whole series keeps its title and year.
fn request_heading(row: &RequestRow, lite: Option<&TitleLite>) -> (String, Option<i64>) {
    let title = lite.map(|l| l.title.clone()).unwrap_or_default();
    let year = lite.and_then(|l| l.year);
    let Some(lite) = lite else {
        return (title, year);
    };
    let seasons = lite.wanted(row);
    let named = row.season_numbers();
    if named.is_empty() || seasons.is_empty() {
        return (title, year);
    }
    let season_year = seasons
        .iter()
        .find_map(|s| s.first_day.as_deref())
        .and_then(|d| d.get(..4))
        .and_then(|y| y.parse().ok());
    let tag = season_tag(&named);
    (
        if tag.is_empty() {
            title
        } else {
            format!("{title} \u{b7} {tag}")
        },
        season_year.or(year),
    )
}

// ---------------------------------------------------------------- the hub

/// Where the connection stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubState {
    /// The first read runs.
    Loading,
    /// No Seerr, or no valid session: every entry point draws nothing.
    Unavailable,
    /// Seerr does not answer.
    Offline,
    /// Signed in.
    Ready,
}

/// A row of the Profile screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileRowKind {
    /// "Meine Anfragen".
    Requests,
    /// "Meine Meldungen".
    Issues,
    /// "Verwaltung".
    Admin,
}

/// A Profile row with its second line and count.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrProfileRow {
    /// Which.
    pub kind: ProfileRowKind,
    /// "Meine Anfragen".
    pub title: String,
    /// "3 laufen".
    pub detail: Option<String>,
    /// The number for the count mark.
    pub count: i64,
}

/// Counts the hub keeps (read by the host with the connection).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HubCounts {
    /// My requests that run (approved, not yet on the server).
    pub my_running: i64,
    /// My open problem reports.
    pub my_issues: i64,
    /// Requests that wait for approval (managers).
    pub pending: i64,
    /// Open problems of everyone (issue managers).
    pub issues_open: i64,
}

/// What the hub tells the host.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrHubInfo {
    /// Grows with every change.
    pub version: u64,
    /// State.
    pub state: HubState,
    /// Seerr's user id.
    pub user_id: i64,
    /// Name to show.
    pub user_name: String,
    /// Admin.
    pub is_admin: bool,
    /// May ask for films.
    pub can_request_movie: bool,
    /// May ask for series.
    pub can_request_tv: bool,
    /// Sees all requests.
    pub can_view_all_requests: bool,
    /// Approves, declines, deletes.
    pub can_manage_requests: bool,
    /// May report a problem.
    pub can_create_issues: bool,
    /// May open the issue list.
    pub can_view_issues: bool,
    /// May resolve issues.
    pub can_manage_issues: bool,
    /// The sheet may offer 4K for films.
    pub four_k_movie: bool,
    /// The sheet may offer 4K for series.
    pub four_k_tv: bool,
    /// Single seasons can be asked for.
    pub partial_requests: bool,
    /// "Noch frei diese Woche: 1 Film, 1 Staffel".
    pub quota_summary: Option<String>,
    /// The counts.
    pub counts: HubCounts,
    /// Rows for the Profile (only those the account may open).
    pub profile_rows: Vec<SeerrProfileRow>,
    /// "3 Anfragen · 1 Problem" for managers when something waits.
    pub admin_line: Option<String>,
}

/// The connection state: who, what may they do, how much is left.
pub struct SeerrHubVm {
    t: Translator,
    state: HubState,
    me: Option<Me>,
    quota: Quota,
    public: PublicSettings,
    counts: HubCounts,
    version: u64,
}

impl SeerrHubVm {
    /// A hub that has read nothing yet.
    pub fn new(locale: Locale) -> Self {
        Self {
            t: Translator::new(locale),
            state: HubState::Loading,
            me: None,
            quota: Quota::default(),
            public: PublicSettings::default(),
            counts: HubCounts::default(),
            version: 1,
        }
    }

    /// The version.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The account has no Seerr.
    pub fn unavailable(&mut self) {
        self.state = HubState::Unavailable;
        self.me = None;
        self.version += 1;
    }

    /// Whether every entry point may show something.
    pub fn available(&self) -> bool {
        self.state == HubState::Ready
    }

    /// `auth/me`, quota and public settings came back.
    pub fn loaded(
        &mut self,
        me: Result<Me, AskError>,
        quota: Option<Quota>,
        public: Option<PublicSettings>,
    ) {
        match me {
            Ok(me) => {
                self.me = Some(me);
                self.state = HubState::Ready;
                if let Some(q) = quota {
                    self.quota = q;
                }
                if let Some(p) = public {
                    self.public = p;
                }
            }
            Err(e) if is_offline(&e) => {
                // A hub that was ready stays ready: a blip must not hide the Seerr parts.
                if self.me.is_none() {
                    self.state = HubState::Offline;
                }
            }
            Err(_) => {
                self.state = HubState::Unavailable;
                self.me = None;
            }
        }
        self.version += 1;
    }

    /// The quota came back.
    pub fn quota_loaded(&mut self, quota: Quota) {
        self.quota = quota;
        self.version += 1;
    }

    /// The counts came back.
    pub fn counts_loaded(&mut self, counts: HubCounts) {
        self.counts = counts;
        self.version += 1;
    }

    /// The user id (0 before sign-in).
    pub fn user_id(&self) -> i64 {
        self.me.as_ref().map_or(0, |m| m.id)
    }

    /// Permissions.
    pub fn perms(&self) -> Perms {
        self.me.as_ref().map_or(Perms::NONE, |m| m.perms())
    }

    /// The public settings.
    pub fn public(&self) -> &PublicSettings {
        &self.public
    }

    /// The account for a title page of `art`.
    pub fn account(&self, art: &str) -> SeerrAccount {
        SeerrAccount {
            user_id: self.user_id(),
            perms: self.perms(),
            quota: Some(self.quota.part(art)).filter(|q| q.has_limit()),
            public: self.public.clone(),
        }
    }

    /// The hub now.
    pub fn info(&self) -> SeerrHubInfo {
        let t = &self.t;
        let p = self.perms();
        let ready = self.state == HubState::Ready;
        let c = self.counts;
        let requests_n = |n: i64| {
            t.t_args(
                if n == 1 {
                    "%lld Anfrage"
                } else {
                    "%lld Anfragen"
                },
                &[Arg::Int(n)],
            )
        };
        let issues_n = |n: i64| {
            t.t_args(
                if n == 1 {
                    "%lld Problem"
                } else {
                    "%lld Probleme"
                },
                &[Arg::Int(n)],
            )
        };
        let mut admin_parts = Vec::new();
        if p.can_manage_requests() && c.pending > 0 {
            admin_parts.push(requests_n(c.pending));
        }
        if p.can_manage_issues() && c.issues_open > 0 {
            admin_parts.push(issues_n(c.issues_open));
        }
        let admin_line = (ready && !admin_parts.is_empty()).then(|| admin_parts.join(" · "));
        let mut rows = Vec::new();
        if ready && p.can_request_movie() | p.can_request_tv() | p.can_view_all_requests() {
            rows.push(SeerrProfileRow {
                kind: ProfileRowKind::Requests,
                title: t.t("Meine Anfragen"),
                detail: (c.my_running > 0)
                    .then(|| t.t_args("%lld laufen", &[Arg::Int(c.my_running)])),
                count: c.my_running,
            });
        }
        if ready && p.can_create_issues() | p.can_view_issues() {
            rows.push(SeerrProfileRow {
                kind: ProfileRowKind::Issues,
                title: t.t("Meine Meldungen"),
                detail: (c.my_issues > 0).then(|| t.t_args("%lld offen", &[Arg::Int(c.my_issues)])),
                count: c.my_issues,
            });
        }
        if ready && (p.can_manage_requests() || p.can_manage_issues()) {
            rows.push(SeerrProfileRow {
                kind: ProfileRowKind::Admin,
                title: t.t("Verwaltung"),
                detail: admin_line.clone(),
                count: c.pending + c.issues_open,
            });
        }
        let quota_summary = ready.then(|| self.summary()).flatten();
        SeerrHubInfo {
            version: self.version,
            state: self.state,
            user_id: self.user_id(),
            user_name: self.me.as_ref().map(|m| m.name()).unwrap_or_default(),
            is_admin: p.is_admin(),
            can_request_movie: p.can_request_movie(),
            can_request_tv: p.can_request_tv(),
            can_view_all_requests: p.can_view_all_requests(),
            can_manage_requests: p.can_manage_requests(),
            can_create_issues: p.can_create_issues(),
            can_view_issues: p.can_view_issues(),
            can_manage_issues: p.can_manage_issues(),
            four_k_movie: self.public.four_k_enabled("movie") && p.can_request_4k("movie"),
            four_k_tv: self.public.four_k_enabled("tv") && p.can_request_4k("tv"),
            partial_requests: self.public.partial_requests_enabled,
            quota_summary,
            counts: c,
            profile_rows: rows,
            admin_line,
        }
    }

    fn summary(&self) -> Option<String> {
        let t = &self.t;
        let mut parts = Vec::new();
        if let Some(n) = self
            .quota
            .movie
            .left()
            .filter(|_| self.quota.movie.has_limit())
        {
            parts.push(t.t_args(
                if n == 1 { "%lld Film" } else { "%lld Filme" },
                &[Arg::Int(n)],
            ));
        }
        if let Some(n) = self.quota.tv.left().filter(|_| self.quota.tv.has_limit()) {
            parts.push(t.t_args(
                if n == 1 {
                    "%lld Staffel"
                } else {
                    "%lld Staffeln"
                },
                &[Arg::Int(n)],
            ));
        }
        if parts.is_empty() {
            return None;
        }
        let days = self.quota.movie.days.or(self.quota.tv.days).unwrap_or(7);
        let period = match days {
            7 => t.t("diese Woche"),
            1 => t.t("heute"),
            30 => t.t("diesen Monat"),
            n => t.t_args("in %lld Tagen", &[Arg::Int(n)]),
        };
        Some(t.t_args(
            "Noch frei %@: %@",
            &[Arg::Str(period), Arg::Str(parts.join(", "))],
        ))
    }

    /// The one-line quota of `art` for a sheet (also the warning flag).
    pub fn quota_line(&self, art: &str) -> Option<(String, bool)> {
        quota_line(&self.t, art, &self.quota.part(art))
    }
}

// ---------------------------------------------------------------- discover

/// A rail of the discover page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RailId {
    /// "Im Trend".
    Trending,
    /// "Beliebte Filme".
    PopularMovies,
    /// "Beliebte Serien".
    PopularTv,
    /// "Bald im Kino".
    UpcomingMovies,
    /// "Bald im Stream".
    UpcomingTv,
    /// "Zuletzt angefragt".
    Recent,
}

impl RailId {
    /// The rails in the order of the server's Discover settings; unknown ones skipped; with no
    /// settings the default order.
    pub fn order(sliders: &[DiscoverSlider]) -> Vec<RailId> {
        let mut out: Vec<RailId> = Vec::new();
        for s in sliders.iter().filter(|s| s.enabled) {
            let id = match s.kind {
                SliderKind::Trending => Some(Self::Trending),
                SliderKind::PopularMovies => Some(Self::PopularMovies),
                SliderKind::PopularTv => Some(Self::PopularTv),
                SliderKind::UpcomingMovies => Some(Self::UpcomingMovies),
                SliderKind::UpcomingTv => Some(Self::UpcomingTv),
                SliderKind::RecentRequests => Some(Self::Recent),
                _ => None,
            };
            if let Some(id) = id
                && !out.contains(&id)
            {
                out.push(id);
            }
        }
        if out.is_empty() {
            out = vec![
                Self::Trending,
                Self::PopularMovies,
                Self::PopularTv,
                Self::UpcomingMovies,
                Self::UpcomingTv,
            ];
        }
        out
    }
}

/// One rail.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrRail {
    /// Which.
    pub id: RailId,
    /// "Im Trend".
    pub title: String,
    /// The tiles.
    pub tiles: Vec<SeerrTileCard>,
}

/// Where the discover page stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListLoad {
    /// Nothing asked yet.
    Idle,
    /// A read runs.
    Loading,
    /// Nothing to show (a clean empty state).
    Empty,
    /// Seerr does not answer.
    Offline,
    /// Seerr answered with an error.
    Failed,
    /// Entries are there.
    Content,
}

/// The discover page.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrDiscoverRails {
    /// Grows with every change.
    pub version: u64,
    /// State.
    pub load: ListLoad,
    /// The rails with at least one tile.
    pub rails: Vec<SeerrRail>,
    /// The line for `Offline` / `Failed`.
    pub error: Option<String>,
}

/// The discover rails.
pub struct SeerrDiscoverVm {
    t: Translator,
    today: String,
    order: Vec<RailId>,
    pending: usize,
    got: HashMap<RailId, Vec<TitleCard>>,
    offline: bool,
    failed: Option<AskError>,
    load: ListLoad,
    hide_available: bool,
    version: u64,
}

impl SeerrDiscoverVm {
    /// An empty page.
    pub fn new(locale: Locale, today: &str) -> Self {
        Self {
            t: Translator::new(locale),
            today: today.to_string(),
            order: Vec::new(),
            pending: 0,
            got: HashMap::new(),
            offline: false,
            failed: None,
            load: ListLoad::Idle,
            hide_available: false,
            version: 1,
        }
    }

    /// A load starts for these rails.
    pub fn begin(&mut self, order: Vec<RailId>, hide_available: bool) {
        self.pending = order.len();
        self.order = order;
        self.got.clear();
        self.offline = false;
        self.failed = None;
        self.hide_available = hide_available;
        self.load = ListLoad::Loading;
        self.version += 1;
    }

    /// One rail came back.
    pub fn rail_loaded(&mut self, id: RailId, page: Result<Page<TitleCard>, AskError>) {
        self.pending = self.pending.saturating_sub(1);
        match page {
            Ok(p) => {
                self.got.insert(id, p.results);
            }
            Err(e) if is_offline(&e) => self.offline = true,
            Err(e) => self.failed = Some(e),
        }
        if self.pending == 0 {
            let any = self.got.values().any(|v| !v.is_empty());
            self.load = if any {
                ListLoad::Content
            } else if self.offline {
                ListLoad::Offline
            } else if self.failed.is_some() {
                ListLoad::Failed
            } else {
                ListLoad::Empty
            };
        }
        self.version += 1;
    }

    /// The page now.
    pub fn info(&self) -> SeerrDiscoverRails {
        let t = &self.t;
        let rails = self
            .order
            .iter()
            .filter_map(|id| {
                let cards = self.got.get(id)?;
                let tiles: Vec<SeerrTileCard> = cards
                    .iter()
                    .map(|c| tile_of(t, c, &self.today))
                    .filter(|tile| !(self.hide_available && tile.on_server))
                    .filter(|tile| {
                        tile.badge
                            .as_ref()
                            .is_none_or(|b| b.kind != BadgeKind::Blocked)
                    })
                    .collect();
                (!tiles.is_empty()).then(|| SeerrRail {
                    id: *id,
                    title: t.t(match id {
                        RailId::Trending => "Im Trend",
                        RailId::PopularMovies => "Beliebte Filme",
                        RailId::PopularTv => "Beliebte Serien",
                        RailId::UpcomingMovies => "Bald im Kino",
                        RailId::UpcomingTv => "Bald im Stream",
                        RailId::Recent => "Zuletzt angefragt",
                    }),
                    tiles,
                })
            })
            .collect();
        let error = match self.load {
            ListLoad::Offline => Some(t.t("Seerr antwortet gerade nicht.")),
            ListLoad::Failed => self.failed.as_ref().map(|e| ask_text(t, e)),
            _ => None,
        };
        SeerrDiscoverRails {
            version: self.version,
            load: self.load,
            rails,
            error,
        }
    }
}

// ---------------------------------------------------------------- search

/// A group of the search block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchGroupKind {
    /// Films.
    Movies,
    /// Series.
    Series,
    /// People.
    People,
    /// Collections.
    Collections,
}

/// One group.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrSearchGroup {
    /// Which.
    pub kind: SearchGroupKind,
    /// "Filme".
    pub title: String,
    /// The tiles (people and collections have no badge).
    pub tiles: Vec<SeerrTileCard>,
}

/// The search merge: what Seerr adds below the library's own results.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrSearchInfo {
    /// Grows with every change.
    pub version: u64,
    /// State.
    pub load: ListLoad,
    /// The term these belong to.
    pub term: String,
    /// "Noch nicht auf deinem Server".
    pub block_title: String,
    /// The groups with at least one tile.
    pub groups: Vec<SeerrSearchGroup>,
    /// Tiles in all.
    pub count: i64,
    /// "Seerr antwortet gerade nicht" while `Offline`.
    pub error: Option<String>,
    /// "Auch nicht bei Seerr" when Seerr found nothing either.
    pub nothing_line: Option<String>,
}

/// The search merge.
pub struct SeerrSearchVm {
    t: Translator,
    today: String,
    term: String,
    load: ListLoad,
    results: Vec<SearchResult>,
    version: u64,
}

impl SeerrSearchVm {
    /// Nothing searched.
    pub fn new(locale: Locale, today: &str) -> Self {
        Self {
            t: Translator::new(locale),
            today: today.to_string(),
            term: String::new(),
            load: ListLoad::Idle,
            results: Vec::new(),
            version: 1,
        }
    }

    /// A term was entered. An empty term resets.
    pub fn begin(&mut self, term: &str) {
        self.term = term.trim().to_string();
        self.results.clear();
        self.load = if self.term.is_empty() {
            ListLoad::Idle
        } else {
            ListLoad::Loading
        };
        self.version += 1;
    }

    /// The answer for `term`; an answer for an older term is dropped.
    pub fn loaded(&mut self, term: &str, page: Result<Page<SearchResult>, AskError>) {
        if term.trim() != self.term {
            return;
        }
        match page {
            Ok(p) => {
                self.results = p.results;
                self.load = ListLoad::Content;
                if self.groups().is_empty() {
                    self.load = ListLoad::Empty;
                }
            }
            Err(e) if is_offline(&e) => self.load = ListLoad::Offline,
            Err(_) => self.load = ListLoad::Failed,
        }
        self.version += 1;
    }

    fn groups(&self) -> Vec<SeerrSearchGroup> {
        let t = &self.t;
        let mut movies = Vec::new();
        let mut series = Vec::new();
        let mut people = Vec::new();
        let mut collections = Vec::new();
        for r in &self.results {
            match r {
                SearchResult::Title(card) => {
                    let tile = tile_of(t, card, &self.today);
                    if tile.on_server {
                        continue;
                    }
                    if tile.art == "tv" {
                        series.push(tile);
                    } else {
                        movies.push(tile);
                    }
                }
                SearchResult::Person(p) => people.push(SeerrTileCard {
                    art: "person".into(),
                    tmdb: p.id,
                    title: p.name.clone(),
                    year: None,
                    poster: tmdb_image(p.profile_path.as_deref(), TmdbSize::Profile),
                    badge: None,
                    media_id: None,
                    on_server: false,
                    announcement: p.name.clone(),
                }),
                SearchResult::Collection(c) => collections.push(SeerrTileCard {
                    art: "collection".into(),
                    tmdb: c.id,
                    title: c.name.clone(),
                    year: None,
                    poster: tmdb_image(c.poster_path.as_deref(), TmdbSize::Poster),
                    badge: None,
                    media_id: None,
                    on_server: false,
                    announcement: c.name.clone(),
                }),
            }
        }
        [
            (SearchGroupKind::Movies, "Filme", movies),
            (SearchGroupKind::Series, "Serien", series),
            (SearchGroupKind::People, "Personen", people),
            (SearchGroupKind::Collections, "Sammlungen", collections),
        ]
        .into_iter()
        .filter(|(_, _, tiles)| !tiles.is_empty())
        .map(|(kind, title, tiles)| SeerrSearchGroup {
            kind,
            title: t.t(title),
            tiles,
        })
        .collect()
    }

    /// The merge now.
    pub fn info(&self) -> SeerrSearchInfo {
        let groups = self.groups();
        let count = groups
            .iter()
            .map(|g| i64::try_from(g.tiles.len()).unwrap_or(0))
            .sum();
        SeerrSearchInfo {
            version: self.version,
            load: self.load,
            term: self.term.clone(),
            block_title: self.t.t("Noch nicht auf deinem Server"),
            groups,
            count,
            error: (self.load == ListLoad::Offline)
                .then(|| self.t.t("Seerr antwortet gerade nicht.")),
            nothing_line: (self.load == ListLoad::Empty).then(|| self.t.t("Auch nicht bei Seerr.")),
        }
    }
}

// ---------------------------------------------------------------- requests

/// The filter pills of a request list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RequestPill {
    /// All.
    All,
    /// Wait for approval.
    Open,
    /// Approved, on their way.
    Running,
    /// On the server.
    Done,
    /// Declined.
    Declined,
    /// The downloader failed.
    Failed,
}

/// A pill with its count.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrPillInfo {
    /// Which.
    pub pill: RequestPill,
    /// "Läuft".
    pub title: String,
    /// How many rows.
    pub count: i64,
    /// Is the active one.
    pub selected: bool,
}

/// What a row is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowWork {
    /// Nothing.
    Idle,
    /// An action is on its way ("Wird freigegeben…").
    Working,
    /// The action failed ("Nochmal").
    Failed,
}

/// What a row can do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// Approve.
    Approve,
    /// Decline.
    Decline,
    /// Try a failed one again.
    Retry,
    /// Withdraw (delete) a waiting request.
    Withdraw,
}

/// One request row.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrRequestRow {
    /// Seerr's request id.
    pub id: i64,
    /// `movie` / `tv`.
    pub art: String,
    /// TMDB id.
    pub tmdb: i64,
    /// Seerr's media id.
    pub media_id: Option<i64>,
    /// Title.
    pub title: String,
    /// Year.
    pub year: Option<i64>,
    /// Poster path.
    pub poster: Option<String>,
    /// Status.
    pub badge: SeerrBadge,
    /// Who asked (admin queue).
    pub requested_by: Option<String>,
    /// "Staffel 2, 3" and "4K".
    pub detail: Option<String>,
    /// Own waiting request: "Zurückziehen".
    pub can_withdraw: bool,
    /// Approve (waiting, manager).
    pub can_approve: bool,
    /// Decline (waiting, manager).
    pub can_decline: bool,
    /// Retry (failed, manager).
    pub can_retry: bool,
    /// Action state.
    pub work: RowWork,
    /// "Wird freigegeben…" or the failure text.
    pub work_text: Option<String>,
}

/// The request list.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrRequestsInfo {
    /// Grows with every change.
    pub version: u64,
    /// State.
    pub load: ListLoad,
    /// The pills with counts.
    pub pills: Vec<SeerrPillInfo>,
    /// The rows of the active pill.
    pub rows: Vec<SeerrRequestRow>,
    /// "Noch frei diese Woche: 1 Film, 1 Staffel".
    pub quota_summary: Option<String>,
    /// Text of the empty or failed state.
    pub error: Option<String>,
}

/// Whose requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestScope {
    /// The account's own ("Meine Anfragen").
    Mine,
    /// Everyone's, with actions (admin queue).
    Queue,
}

struct Row {
    req: RequestRow,
    work: RowWork,
    work_text: Option<String>,
}

/// The request list (own or queue).
pub struct SeerrRequestsVm {
    t: Translator,
    today: String,
    scope: RequestScope,
    me: i64,
    perms: Perms,
    load: ListLoad,
    rows: Vec<Row>,
    pill: RequestPill,
    error: Option<String>,
    quota_summary: Option<String>,
    version: u64,
}

fn pill_of(status: &SeerrStatus) -> RequestPill {
    match status {
        SeerrStatus::Waits => RequestPill::Open,
        SeerrStatus::Declined => RequestPill::Declined,
        SeerrStatus::Failed => RequestPill::Failed,
        SeerrStatus::Available | SeerrStatus::Partial => RequestPill::Done,
        _ => RequestPill::Running,
    }
}

impl SeerrRequestsVm {
    /// An empty list for `me` (user id) with `perms`.
    pub fn new(locale: Locale, today: &str, scope: RequestScope, me: i64, perms: Perms) -> Self {
        Self {
            t: Translator::new(locale),
            today: today.to_string(),
            scope,
            me,
            perms,
            load: ListLoad::Idle,
            rows: Vec::new(),
            pill: RequestPill::All,
            error: None,
            quota_summary: None,
            version: 1,
        }
    }

    /// A load starts (a list that is there stays on screen).
    pub fn begin(&mut self) {
        if self.load != ListLoad::Content {
            self.load = ListLoad::Loading;
        }
        self.version += 1;
    }

    /// Who the list is for and what that account may. A list is made before the hub has read the rights, so a load
    /// hands them in once they are known; until then no row offers a verb.
    pub fn set_account(&mut self, me: i64, perms: Perms) {
        self.me = me;
        self.perms = perms;
        self.version += 1;
    }

    /// The summary line of the quota.
    pub fn set_quota_summary(&mut self, line: Option<String>) {
        self.quota_summary = line;
        self.version += 1;
    }

    /// The requests came back.
    pub fn loaded(&mut self, result: Result<Vec<RequestRow>, AskError>) {
        match result {
            Ok(rows) => {
                self.rows = rows
                    .into_iter()
                    .map(|req| Row {
                        req,
                        work: RowWork::Idle,
                        work_text: None,
                    })
                    .collect();
                self.load = if self.rows.is_empty() {
                    ListLoad::Empty
                } else {
                    ListLoad::Content
                };
                self.error = None;
            }
            Err(e) if is_offline(&e) => {
                self.load = ListLoad::Offline;
                self.error = Some(self.t.t("Seerr antwortet gerade nicht."));
            }
            Err(e) => {
                self.load = ListLoad::Failed;
                self.error = Some(ask_text(&self.t, &e));
            }
        }
        self.version += 1;
    }

    /// Picks a pill.
    pub fn select(&mut self, pill: RequestPill) {
        self.pill = pill;
        self.version += 1;
    }

    /// An action starts: the row shows it at once.
    pub fn begin_verdict(&mut self, id: i64, verdict: Verdict) {
        let text = self.t.t(match verdict {
            Verdict::Approve => "Wird freigegeben…",
            Verdict::Decline => "Wird abgelehnt…",
            Verdict::Retry => "Wird neu gestartet…",
            Verdict::Withdraw => "Wird zurückgezogen…",
        });
        if let Some(r) = self.rows.iter_mut().find(|r| r.req.id == id) {
            r.work = RowWork::Working;
            r.work_text = Some(text);
        }
        self.version += 1;
    }

    /// The action came back.
    pub fn verdict_done(&mut self, id: i64, verdict: Verdict, result: Result<(), AskError>) {
        match result {
            Ok(()) => {
                if verdict == Verdict::Withdraw {
                    self.rows.retain(|r| r.req.id != id);
                } else if let Some(r) = self.rows.iter_mut().find(|r| r.req.id == id) {
                    r.req.status = match verdict {
                        Verdict::Decline => RequestStatus::Declined,
                        _ => RequestStatus::Approved,
                    };
                    r.work = RowWork::Idle;
                    r.work_text = None;
                }
                if self.rows.is_empty() {
                    self.load = ListLoad::Empty;
                }
            }
            Err(e) => {
                let text = ask_text(&self.t, &e);
                if let Some(r) = self.rows.iter_mut().find(|r| r.req.id == id) {
                    r.work = RowWork::Failed;
                    r.work_text = Some(text);
                }
            }
        }
        self.version += 1;
    }

    /// The requests as loaded (for the home block and counts).
    pub fn requests(&self) -> Vec<&RequestRow> {
        self.rows.iter().map(|r| &r.req).collect()
    }

    fn status_of_row(&self, r: &Row, cache: &TitleCache) -> SeerrStatus {
        let lite = key_of(&r.req).and_then(|(art, id)| cache.get(&art, id));
        request_status(&r.req, lite, &self.today)
    }

    fn row_info(&self, r: &Row, cache: &TitleCache) -> SeerrRequestRow {
        let t = &self.t;
        let (art, tmdb) = key_of(&r.req).unwrap_or_else(|| ("movie".into(), 0));
        let lite = cache.get(&art, tmdb);
        let status = self.status_of_row(r, cache);
        let own = r.req.requested_by.as_ref().is_some_and(|u| u.id == self.me);
        let manage = self.perms.can_manage_requests();
        let waiting = r.req.status == RequestStatus::Pending;
        let mut detail = Vec::new();
        let (title, year) = request_heading(&r.req, lite);
        if r.req.is4k {
            detail.push(t.t("4K"));
        }
        SeerrRequestRow {
            id: r.req.id,
            art,
            tmdb,
            media_id: r.req.media.as_ref().map(|m| m.id).filter(|i| *i > 0),
            title,
            year,
            poster: lite.and_then(|l| l.poster.clone()),
            badge: badge_of(t, &status),
            requested_by: (self.scope == RequestScope::Queue)
                .then(|| r.req.requested_by.as_ref().map(|u| u.name()))
                .flatten()
                .filter(|n| !n.is_empty()),
            detail: (!detail.is_empty()).then(|| detail.join(" · ")),
            can_withdraw: waiting && (own || manage) && self.scope == RequestScope::Mine,
            can_approve: waiting && manage,
            can_decline: waiting && manage,
            can_retry: r.req.status == RequestStatus::Failed && manage,
            work: r.work,
            work_text: r.work_text.clone(),
        }
    }

    /// The list now.
    pub fn info(&self, cache: &TitleCache) -> SeerrRequestsInfo {
        let t = &self.t;
        let cats: Vec<RequestPill> = self
            .rows
            .iter()
            .map(|r| pill_of(&self.status_of_row(r, cache)))
            .collect();
        let count = |p: RequestPill| {
            i64::try_from(
                cats.iter()
                    .filter(|c| p == RequestPill::All || **c == p)
                    .count(),
            )
            .unwrap_or(0)
        };
        let pills = [
            (RequestPill::All, "Alle"),
            (RequestPill::Open, "Offen"),
            (RequestPill::Running, "Läuft"),
            (RequestPill::Done, "Fertig"),
            (RequestPill::Declined, "Abgelehnt"),
            (RequestPill::Failed, "Fehlgeschlagen"),
        ]
        .into_iter()
        .map(|(pill, title)| SeerrPillInfo {
            pill,
            title: t.t(title),
            count: count(pill),
            selected: pill == self.pill,
        })
        .collect();
        let rows = self
            .rows
            .iter()
            .zip(&cats)
            .filter(|(_, c)| self.pill == RequestPill::All || **c == self.pill)
            .map(|(r, _)| self.row_info(r, cache))
            .collect();
        SeerrRequestsInfo {
            version: self.version,
            load: self.load,
            pills,
            rows,
            quota_summary: self.quota_summary.clone(),
            error: self.error.clone(),
        }
    }

    /// Requests that run (for the Profile row), counted the same way as the pills.
    pub fn running(&self, cache: &TitleCache) -> i64 {
        i64::try_from(
            self.rows
                .iter()
                .filter(|r| pill_of(&self.status_of_row(r, cache)) == RequestPill::Running)
                .count(),
        )
        .unwrap_or(0)
    }
}

// ---------------------------------------------------------------- home block

/// "<Titel> ist da" with a way to play it.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrArrival {
    /// The request (dismiss stores this id).
    pub request_id: i64,
    /// `movie` / `tv`.
    pub art: String,
    /// TMDB id.
    pub tmdb: i64,
    /// Title, with the season of a season request ("Sweet P · S2").
    pub title: String,
    /// The poster as a finished picture address.
    pub poster: Option<String>,
    /// The library item to play.
    pub library_id: String,
    /// "Dune ist da".
    pub line: String,
}

/// The line for managers: "Wartet auf dich" and what waits.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrAttention {
    /// "Wartet auf dich".
    pub title: String,
    /// "3 Anfragen · 1 Problem".
    pub detail: String,
    /// Sum of both numbers.
    pub count: i64,
}

/// What the block takes of the page, part by part. A host reserves exactly this room while the answer is out, so
/// the rails below do not move when the block arrives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SeerrHomeShape {
    /// The arrival banner "<Titel> ist da".
    pub arrival: bool,
    /// More than one arrival lies behind the banner (the stack peeks out below it).
    pub stacked: bool,
    /// Three or more arrivals: the stack peeks out with two cards below the banner (the most it shows), so the reserve
    /// is as tall as the real stack.
    pub deep: bool,
    /// The manager's line.
    pub attention: bool,
    /// The "Angefragt" rail.
    pub rail: bool,
}

impl SeerrHomeShape {
    /// The shape as the short text a host stores per profile ("" = nothing): `a` banner, `s` stack, `d` deep stack (3+), `l` line, `r` rail.
    pub fn code(self) -> String {
        let mut out = String::new();
        for (on, letter) in [
            (self.arrival, 'a'),
            (self.stacked, 's'),
            (self.deep, 'd'),
            (self.attention, 'l'),
            (self.rail, 'r'),
        ] {
            if on {
                out.push(letter);
            }
        }
        out
    }

    /// The shape of a stored code (anything unknown counts as nothing).
    pub fn parse(code: &str) -> Self {
        Self {
            arrival: code.contains('a'),
            stacked: code.contains('s'),
            deep: code.contains('d'),
            attention: code.contains('l'),
            rail: code.contains('r'),
        }
    }

    /// Nothing to reserve.
    pub fn is_empty(self) -> bool {
        self == Self::default()
    }

    /// What is reserved when the page waited its budget for the first answer of a profile and Seerr was still out: the
    /// "Angefragt" rail, the part most profiles with Seerr have. If Seerr says otherwise the room closes in one motion.
    pub const FIRST_GUESS: Self = Self {
        arrival: false,
        stacked: false,
        deep: false,
        attention: false,
        rail: true,
    };
}

/// How long the Start page waits for the first Seerr answer of a profile that has no remembered shape, in seconds.
/// After it the page shows with the reserve of [`SeerrHomeShape::FIRST_GUESS`].
pub const HOME_BUDGET_SECONDS: f64 = 1.5;

/// The stored code of "the block had nothing": a profile that knows this does not wait next time.
const NOTHING_CODE: &str = "-";

/// The key a host stores the block's last shape under, one per profile (`account`: the account key, `None`: none).
pub fn seerr_home_memory_key(account: Option<&str>) -> String {
    match account {
        Some(a) if !a.is_empty() => format!("seerrHomeShape.{a}"),
        _ => "seerrHomeShape".to_string(),
    }
}

/// Where the home block stands. One state, so a host never draws a half-built block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeerrHomeState {
    /// Seerr is connected and has not answered yet: draw an empty block of `shape` (no text, no spinner), so the
    /// rails below stand where they will stay.
    Pending,
    /// Nothing to draw and nothing to reserve (not connected, answered with nothing, or Seerr not usable).
    Hidden,
    /// Draw the block with its content.
    Shown,
}

/// The block above the home rails.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrHomeInfo {
    /// Grows with every change.
    pub version: u64,
    /// Where the block stands.
    pub state: SeerrHomeState,
    /// What the block takes of the page: the remembered shape while `Pending`, the real one when `Shown`.
    pub shape: SeerrHomeShape,
    /// The shape's code for the host to store (per profile, see [`seerr_home_memory_key`]) once `state` is no
    /// longer `Pending`; the next start reserves it in its first frame.
    pub memory: String,
    /// The Start page waits for this answer before it shows (first start of a profile: nothing is remembered, so there
    /// is no room to reserve). Ends with the answer or after [`HOME_BUDGET_SECONDS`]; the host shows its page as a whole
    /// when this is false.
    pub holds_page: bool,
    /// Draw the block's content (`state` is `Shown`; false: nothing, not even a heading).
    pub show: bool,
    /// The arrival on top of the stack (the first of `arrivals`); `None`: no arrival.
    pub arrival: Option<SeerrArrival>,
    /// Every arrival in stack order, the top one first. One entry: a plain banner; several: a notification stack
    /// (collapsed: the top card with the others peeking out below it; expanded: all cards as a list).
    pub arrivals: Vec<SeerrArrival>,
    /// The stack is open (a list of all cards). Only ever true with two or more arrivals: one card is a plain banner.
    pub arrivals_expanded: bool,
    /// The manager's line.
    pub attention: Option<SeerrAttention>,
    /// "Meine Anfragen".
    pub rail_title: String,
    /// The tiles, downloading first, then waiting, then soon.
    pub rail: Vec<SeerrTileCard>,
}

impl SeerrHomeInfo {
    /// The block of the first frame: Seerr is connected, nothing came back yet, the host reserves what the last start
    /// had (`memory`: the stored code, "" when there is none).
    pub fn pending(memory: &str) -> Self {
        if memory.is_empty() {
            Self::reserve(SeerrHomeShape::FIRST_GUESS, true)
        } else {
            Self::reserve(SeerrHomeShape::parse(memory), false)
        }
    }

    /// The reserve: blank content (no words, no pictures) in every part of `shape`, laid out by the host like the real
    /// block and drawn invisible and untouchable, so it takes exactly the room the answer will take. `holds_page`: the
    /// shape is only a guess and the page waits for the answer instead.
    fn reserve(shape: SeerrHomeShape, holds_page: bool) -> Self {
        let rail_title = String::from(BLANK);
        Self {
            version: 0,
            state: SeerrHomeState::Pending,
            shape,
            memory: if holds_page {
                String::new()
            } else {
                shape.code()
            },
            holds_page,
            show: false,
            arrival: shape.arrival.then(blank_arrival),
            arrivals: if shape.arrival {
                (0..match (shape.stacked, shape.deep) {
                    (_, true) => 3,
                    (true, false) => 2,
                    _ => 1,
                })
                    .map(|i| SeerrArrival {
                        request_id: i,
                        ..blank_arrival()
                    })
                    .collect()
            } else {
                Vec::new()
            },
            arrivals_expanded: false,
            attention: shape.attention.then(|| SeerrAttention {
                title: BLANK.into(),
                detail: BLANK.into(),
                count: 0,
            }),
            rail_title,
            rail: if shape.rail {
                vec![SeerrTileCard {
                    art: "movie".into(),
                    tmdb: 0,
                    title: BLANK.into(),
                    year: None,
                    poster: None,
                    badge: None,
                    media_id: None,
                    on_server: false,
                    announcement: String::new(),
                }]
            } else {
                Vec::new()
            },
        }
    }
}

/// A no-break space: a line of text of the right height that shows nothing.
const BLANK: &str = "\u{a0}";

fn blank_arrival() -> SeerrArrival {
    SeerrArrival {
        request_id: 0,
        art: "movie".into(),
        tmdb: 0,
        title: BLANK.into(),
        poster: None,
        library_id: String::new(),
        line: BLANK.into(),
    }
}

/// The arrivals of the Start page as one state: none, one banner, or a stack (top card first). Every change goes
/// through here, so the order, the loop and the closing of the last card cannot disagree.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum ArrivalDeck {
    /// No arrival: the block draws no banner.
    #[default]
    Empty,
    /// One arrival, a plain banner without the stack look.
    One(i64, String),
    /// Two or more: `top` is in front, `behind` follow in the order they come to the front.
    Stack {
        /// The request in front (and its library item).
        top: (i64, String),
        /// The cards behind, nearest first (at least one).
        behind: Vec<(i64, String)>,
    },
}

impl ArrivalDeck {
    /// The deck of these cards, the first one in front. A single card is `One`, none is `Empty`.
    pub fn of(mut cards: Vec<(i64, String)>) -> Self {
        match cards.len() {
            0 => Self::Empty,
            1 => {
                let (id, lib) = cards.remove(0);
                Self::One(id, lib)
            }
            _ => {
                let top = cards.remove(0);
                Self::Stack { top, behind: cards }
            }
        }
    }

    /// The cards, the front one first.
    pub fn cards(&self) -> Vec<(i64, String)> {
        match self {
            Self::Empty => Vec::new(),
            Self::One(id, lib) => vec![(*id, lib.clone())],
            Self::Stack { top, behind } => {
                let mut all = vec![top.clone()];
                all.extend(behind.iter().cloned());
                all
            }
        }
    }

    /// The request in front.
    pub fn top_id(&self) -> Option<i64> {
        match self {
            Self::Empty => None,
            Self::One(id, _) => Some(*id),
            Self::Stack { top, .. } => Some(top.0),
        }
    }

    /// How many cards there are.
    pub fn len(&self) -> usize {
        match self {
            Self::Empty => 0,
            Self::One(..) => 1,
            Self::Stack { behind, .. } => 1 + behind.len(),
        }
    }

    /// No card.
    pub fn is_empty(&self) -> bool {
        matches!(self, Self::Empty)
    }

    /// Takes one card out (the X or a swipe on any card, a stored dismissal): the stack shrinks, one card left is a plain
    /// banner, the last one closes the block's banner.
    pub fn remove(&mut self, request_id: i64) {
        let mut cards = self.cards();
        cards.retain(|(id, _)| *id != request_id);
        *self = Self::of(cards);
    }

    /// A new read found these arrivals (newest first). The card that was in front stays in front while it is still
    /// there; the others follow in the order of the new read.
    pub fn reload(&mut self, found: Vec<(i64, String)>) {
        let front = self.top_id();
        let mut cards = found;
        if let Some(at) = front.and_then(|f| cards.iter().position(|(id, _)| *id == f)) {
            cards.rotate_left(at);
        }
        *self = Self::of(cards);
    }
}

/// How the stack of arrivals is laid out. One card or none is always `Collapsed` (there is nothing to open).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ArrivalLayout {
    /// The top card, the others peek out below it.
    #[default]
    Collapsed,
    /// All cards as a list.
    Expanded,
}

/// An arrival to look up in the library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArrivalCandidate {
    /// The request.
    pub request_id: i64,
    /// `movie` / `tv`.
    pub art: String,
    /// TMDB id.
    pub tmdb: i64,
}

/// The home block.
pub struct SeerrHomeVm {
    t: Translator,
    today: String,
    requests: Vec<RequestRow>,
    dismissed: BTreeSet<i64>,
    arrival_on: bool,
    requests_on: bool,
    deck: ArrivalDeck,
    layout: ArrivalLayout,
    attention: Option<SeerrAttention>,
    available: bool,
    phase: HomePhase,
    version: u64,
}

/// Whether the first answer is in. Moves forward only: `Idle` to `Awaiting` or `Pending` to `Answered`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HomePhase {
    /// Not asked yet.
    Idle,
    /// Asked, no answer, and this profile remembers nothing: the page waits for it (up to [`HOME_BUDGET_SECONDS`]).
    Awaiting,
    /// Asked, no answer: the remembered shape (or, after the wait, the first guess) is reserved.
    Pending(SeerrHomeShape),
    /// The first answer is in (later reloads keep what is shown until the new answer is there).
    Answered,
}

impl SeerrHomeVm {
    /// An empty block.
    pub fn new(locale: Locale, today: &str) -> Self {
        Self {
            t: Translator::new(locale),
            today: today.to_string(),
            requests: Vec::new(),
            dismissed: BTreeSet::new(),
            arrival_on: true,
            requests_on: false,
            deck: ArrivalDeck::Empty,
            layout: ArrivalLayout::Collapsed,
            attention: None,
            available: false,
            phase: HomePhase::Idle,
            version: 1,
        }
    }

    /// Seerr is connected and the first read starts: reserve the remembered shape (`memory`: the stored code) until
    /// [`Self::answered`]. Does nothing once asked, so a reload never brings the reserve back.
    pub fn begin(&mut self, memory: &str) {
        if self.phase == HomePhase::Idle {
            self.phase = if memory.is_empty() {
                HomePhase::Awaiting
            } else {
                HomePhase::Pending(SeerrHomeShape::parse(memory))
            };
            self.version += 1;
        }
    }

    /// The budget of a first start ran out with Seerr still out: the page shows now, with the first guess reserved.
    /// Does nothing in any other phase.
    pub fn budget_over(&mut self) {
        if self.phase == HomePhase::Awaiting {
            self.phase = HomePhase::Pending(SeerrHomeShape::FIRST_GUESS);
            self.version += 1;
        }
    }

    /// The first read is over (whatever it found, also nothing): the block is `Shown` or `Hidden` from now on.
    pub fn answered(&mut self) {
        if self.phase != HomePhase::Answered {
            self.phase = HomePhase::Answered;
            self.version += 1;
        }
    }

    /// The dismissed arrivals (request ids) the host stored.
    pub fn set_dismissed(&mut self, ids: &[i64]) {
        self.dismissed = ids.iter().copied().collect();
        for id in ids {
            self.deck.remove(*id);
        }
        self.version += 1;
    }

    /// The setting "Ankunft-Hinweise anzeigen" (key `seerrArrivalHint`).
    pub fn set_arrival_enabled(&mut self, on: bool) {
        self.arrival_on = on;
        if !on {
            self.deck = ArrivalDeck::Empty;
        }
        self.version += 1;
    }

    /// The setting "Meine Anfragen" on the Start page (key `seerrRequestsRail`, off until switched on): without it the
    /// "Angefragt" rail is not part of the block, so a host that draws the block draws no rail.
    pub fn set_requests_enabled(&mut self, on: bool) {
        self.requests_on = on;
        self.version += 1;
    }

    /// Hides one arrival for good (the X or a swipe on any card, open or closed); returns every dismissed id for the
    /// host to store. The stack closes by itself when fewer than two cards are left.
    pub fn dismiss(&mut self, request_id: i64) -> Vec<i64> {
        self.dismissed.insert(request_id);
        self.deck.remove(request_id);
        self.settle_layout();
        self.version += 1;
        self.dismissed.iter().copied().collect()
    }

    /// Opens (`true`) or closes the stack (the tap on it, "Weniger anzeigen"). The host also calls this with the stored
    /// state before the first read; the stack shows open only with two or more cards (`SeerrHomeInfo::arrivals_expanded`),
    /// and the host stores that value after every change.
    pub fn set_arrivals_expanded(&mut self, on: bool) {
        self.layout = if on {
            ArrivalLayout::Expanded
        } else {
            ArrivalLayout::Collapsed
        };
        self.version += 1;
    }

    /// Once the cards are known (a read, a dismissal): a stack of fewer than two cards is closed for good, so a card that
    /// arrives later does not come in open.
    fn settle_layout(&mut self) {
        if self.deck.len() < 2 && self.layout == ArrivalLayout::Expanded {
            self.layout = ArrivalLayout::Collapsed;
        }
    }

    /// The hub is (not) available; without it nothing shows.
    pub fn set_available(&mut self, on: bool) {
        self.available = on;
        if !on {
            self.requests.clear();
            self.deck = ArrivalDeck::Empty;
            self.attention = None;
        }
        self.version += 1;
    }

    /// The account's own requests came back.
    pub fn requests_loaded(&mut self, requests: Vec<RequestRow>) {
        self.requests = requests;
        self.version += 1;
    }

    /// The manager's line, from the hub's counts.
    pub fn set_attention(&mut self, line: Option<(String, i64)>) {
        self.attention = line.map(|(detail, count)| SeerrAttention {
            title: self.t.t("Wartet auf dich"),
            detail,
            count,
        });
        self.version += 1;
    }

    /// Requests that are available now, not dismissed, newest first: look each up in the library
    /// (stop at the first hit). Empty while the setting is off.
    pub fn arrival_candidates(&self) -> Vec<ArrivalCandidate> {
        if !self.arrival_on || !self.available {
            return Vec::new();
        }
        let mut rows: Vec<&RequestRow> = self
            .requests
            .iter()
            .filter(|r| !self.dismissed.contains(&r.id))
            .filter(|r| {
                r.status == RequestStatus::Completed
                    || r.media.as_ref().is_some_and(|m| {
                        r.status == RequestStatus::Approved
                            && m.lane(r.is4k) == swiftly_seerr::SeerrState::Present
                    })
            })
            .collect();
        rows.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| b.id.cmp(&a.id))
        });
        rows.into_iter()
            .filter_map(|r| {
                key_of(r).map(|(art, tmdb)| ArrivalCandidate {
                    request_id: r.id,
                    art,
                    tmdb,
                })
            })
            .take(5)
            .collect()
    }

    /// The library has these requests' titles (candidate order, newest first): they are the stack. Dismissed ones and
    /// everything while the setting is off do not count.
    pub fn arrivals_found(&mut self, found: Vec<(i64, String)>) {
        let found = if self.arrival_on {
            found
                .into_iter()
                .filter(|(id, _)| !self.dismissed.contains(id))
                .collect()
        } else {
            Vec::new()
        };
        self.deck.reload(found);
        self.settle_layout();
        self.version += 1;
    }

    /// The block now.
    pub fn info(&self, cache: &TitleCache) -> SeerrHomeInfo {
        let t = &self.t;
        let mut asked: Vec<(SeerrStatus, &RequestRow)> = self
            .requests
            .iter()
            .map(|r| {
                let lite = key_of(r).and_then(|(a, i)| cache.get(&a, i));
                (request_status(r, lite, &self.today), r)
            })
            .filter(|(s, _)| s.is_requested())
            .collect();
        asked.sort_by(|(a, ra), (b, rb)| {
            a.rail_rank()
                .cmp(&b.rail_rank())
                .then_with(|| rb.id.cmp(&ra.id))
        });
        let rail: Vec<SeerrTileCard> = if self.available && self.requests_on {
            asked
                .iter()
                .filter_map(|(s, r)| {
                    let (art, tmdb) = key_of(r)?;
                    let lite = cache.get(&art, tmdb)?;
                    let badge = badge_of(t, s);
                    let (title, year) = request_heading(r, Some(lite));
                    Some(SeerrTileCard {
                        announcement: format!("{title}, {}", badge.line),
                        art,
                        tmdb,
                        title,
                        year,
                        poster: lite.poster.clone(),
                        badge: Some(badge),
                        media_id: r.media.as_ref().map(|m| m.id).filter(|i| *i > 0),
                        on_server: false,
                    })
                })
                .collect()
        } else {
            Vec::new()
        };
        let arrivals: Vec<SeerrArrival> = if self.arrival_on {
            self.deck
                .cards()
                .iter()
                .filter_map(|(id, library_id)| {
                    let r = self.requests.iter().find(|r| r.id == *id)?;
                    let (art, tmdb) = key_of(r)?;
                    let lite = cache.get(&art, tmdb)?;
                    let (title, _) = request_heading(r, Some(lite));
                    Some(SeerrArrival {
                        request_id: *id,
                        poster: lite.poster.clone(),
                        library_id: library_id.clone(),
                        line: t.t_args("%@ ist da", &[Arg::Str(title.clone())]),
                        title,
                        art,
                        tmdb,
                    })
                })
                .collect()
        } else {
            Vec::new()
        };
        let attention = self.attention.clone().filter(|_| self.available);
        let content =
            self.available && (!arrivals.is_empty() || attention.is_some() || !rail.is_empty());
        let (state, shape) = match self.phase {
            // Half an answer is not drawn: the block comes as a whole.
            HomePhase::Pending(shape) => (SeerrHomeState::Pending, shape),
            HomePhase::Awaiting => (SeerrHomeState::Pending, SeerrHomeShape::FIRST_GUESS),
            HomePhase::Idle | HomePhase::Answered if !content => {
                (SeerrHomeState::Hidden, SeerrHomeShape::default())
            }
            HomePhase::Idle | HomePhase::Answered => (
                SeerrHomeState::Shown,
                SeerrHomeShape {
                    arrival: !arrivals.is_empty(),
                    stacked: arrivals.len() > 1,
                    deep: arrivals.len() > 2,
                    attention: attention.is_some(),
                    rail: !rail.is_empty(),
                },
            ),
        };
        if state == SeerrHomeState::Pending {
            return SeerrHomeInfo {
                version: self.version,
                ..SeerrHomeInfo::reserve(shape, self.phase == HomePhase::Awaiting)
            };
        }
        let shown = state == SeerrHomeState::Shown;
        SeerrHomeInfo {
            version: self.version,
            state,
            shape,
            memory: if shown {
                shape.code()
            } else {
                NOTHING_CODE.to_string()
            },
            holds_page: false,
            show: shown,
            arrival: arrivals.first().cloned().filter(|_| shown),
            arrivals_expanded: shown
                && self.layout == ArrivalLayout::Expanded
                && arrivals.len() > 1,
            arrivals: if shown { arrivals } else { Vec::new() },
            attention: attention.filter(|_| shown),
            rail_title: t.t("Meine Anfragen"),
            rail: if shown { rail } else { Vec::new() },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_seerr::types::{CollectionCard, Me, PersonCard, TitleSeason};

    const DE: &str = "de";

    fn me(perms: i64) -> Me {
        serde_json::from_str(&format!(
            r#"{{"id":2,"displayName":"Paul","permissions":{perms}}}"#
        ))
        .expect("me")
    }

    fn row(json: &str) -> RequestRow {
        serde_json::from_str(json).expect("request")
    }

    #[test]
    fn the_arrival_stack_closes_any_card_one_at_a_time_and_keeps_dismissals() {
        let card = |id: i64| (id, format!("lib-{id}"));
        let ids = |d: &ArrivalDeck| d.cards().iter().map(|c| c.0).collect::<Vec<_>>();
        // One card is a plain banner, none is nothing.
        assert_eq!(ArrivalDeck::of(vec![]), ArrivalDeck::Empty);
        let mut deck = ArrivalDeck::of(vec![card(3), card(2), card(1)]);
        assert_eq!(deck.top_id(), Some(3));
        // The X closes the front card only; the stack shrinks, one left is a plain banner, the last one closes it.
        deck.remove(3);
        assert_eq!(ids(&deck), [2, 1]);
        assert!(matches!(deck, ArrivalDeck::Stack { .. }));
        deck.remove(2);
        assert_eq!(deck, ArrivalDeck::One(1, "lib-1".into()));
        deck.remove(1);
        assert!(deck.is_empty());
        // Any card can go, not only the one in front.
        let mut deck = ArrivalDeck::of(vec![card(3), card(2), card(1)]);
        deck.remove(2);
        assert_eq!(ids(&deck), [3, 1]);
        // A reload keeps the card in front in front.
        deck.reload(vec![card(4), card(3), card(2), card(1)]);
        assert_eq!(deck.top_id(), Some(3));
        assert_eq!(deck.len(), 4);
    }

    #[test]
    fn the_home_block_stacks_arrivals_and_a_dismissed_one_stays_dismissed_after_a_restart() {
        let today = "2026-11-17";
        let mut cache = TitleCache::default();
        let mk = |id: i64, tmdb: i64| {
            row(&format!(
                r#"{{"id":{id},"status":5,"mediaType":"movie","updatedAt":"2026-11-1{id}","media":{{"tmdbId":{tmdb},"status":5}}}}"#
            ))
        };
        let rows = vec![mk(1, 10), mk(2, 11), mk(3, 12)];
        for (tmdb, name) in [(10, "Dune"), (11, "Heat"), (12, "Alien")] {
            cache.put(&title_info("movie", tmdb, name, Vec::new()));
        }
        let mut home = SeerrHomeVm::new(Locale::parse(DE), today);
        home.set_available(true);
        home.requests_loaded(rows.clone());
        let found: Vec<(i64, String)> = home
            .arrival_candidates()
            .into_iter()
            .map(|c| (c.request_id, format!("lib-{}", c.request_id)))
            .collect();
        assert_eq!(
            found.iter().map(|f| f.0).collect::<Vec<_>>(),
            [3, 2, 1],
            "newest first"
        );
        home.arrivals_found(found.clone());
        let info = home.info(&cache);
        assert_eq!(info.arrivals.len(), 3);
        assert!(
            info.shape.stacked
                && info.shape.deep
                && info.memory.contains('s')
                && info.memory.contains('d')
        );
        // The next start reserves as many cards as the stack had, so the rows below do not move when it answers.
        assert_eq!(SeerrHomeInfo::pending(&info.memory).arrivals.len(), 3);
        assert_eq!(SeerrHomeInfo::pending("as").arrivals.len(), 2);
        assert_eq!(SeerrHomeInfo::pending("a").arrivals.len(), 1);
        assert_eq!(info.arrival.as_ref().map(|a| a.request_id), Some(3));
        assert!(!info.arrivals_expanded, "a stack starts closed");
        // Tap: the list of all cards. A restart with the stored state brings it back open.
        home.set_arrivals_expanded(true);
        assert!(home.info(&cache).arrivals_expanded);
        // A swipe on a card in the middle takes only that one; the others stay in order and the stack stays open.
        let stored = home.dismiss(2);
        assert_eq!(stored, [2]);
        let info = home.info(&cache);
        assert_eq!(
            info.arrivals
                .iter()
                .map(|a| a.request_id)
                .collect::<Vec<_>>(),
            [3, 1]
        );
        assert!(
            info.arrivals_expanded,
            "two cards left: still a stack, still open"
        );
        // A restart: a new block with the stored ids does not bring the dismissed one back.
        let mut again = SeerrHomeVm::new(Locale::parse(DE), today);
        again.set_available(true);
        again.set_dismissed(&stored);
        again.set_arrivals_expanded(true);
        again.requests_loaded(rows);
        assert_eq!(
            again
                .arrival_candidates()
                .iter()
                .map(|c| c.request_id)
                .collect::<Vec<_>>(),
            [3, 1]
        );
        again.arrivals_found(found.clone());
        let info = again.info(&cache);
        assert_eq!(
            info.arrivals
                .iter()
                .map(|a| a.request_id)
                .collect::<Vec<_>>(),
            [3, 1]
        );
        assert!(
            info.arrivals_expanded,
            "the stored open state comes back with the stack"
        );
        // The second to last card goes: the stack is one plain banner and closed; a new card does not come in open.
        again.dismiss(3);
        let info = again.info(&cache);
        assert_eq!(info.arrivals.len(), 1);
        assert!(!info.arrivals_expanded);
        again.arrivals_found(found);
        assert!(
            !again.info(&cache).arrivals_expanded,
            "a card that arrives later does not open the stack"
        );
        // The last X closes the banner and the block with it (no manager line, no rail).
        again.dismiss(1);
        let info = again.info(&cache);
        assert!(info.arrivals.is_empty() && info.arrival.is_none());
        assert_eq!(info.state, SeerrHomeState::Hidden);
    }

    #[test]
    fn the_hub_shows_profile_rows_only_for_what_the_account_may_open() {
        let mut hub = SeerrHubVm::new(Locale::parse(DE));
        assert!(!hub.available());
        hub.loaded(Ok(me(32 | 4_194_304)), None, None);
        let rows = hub.info().profile_rows;
        assert_eq!(rows.len(), 2, "requests and own reports, no admin");
        assert!(rows.iter().all(|r| r.kind != ProfileRowKind::Admin));
        hub.loaded(Ok(me(2)), None, None);
        hub.counts_loaded(HubCounts {
            pending: 3,
            issues_open: 1,
            my_running: 3,
            ..HubCounts::default()
        });
        let info = hub.info();
        assert_eq!(info.admin_line.as_deref(), Some("3 Anfragen · 1 Problem"));
        let admin = info
            .profile_rows
            .iter()
            .find(|r| r.kind == ProfileRowKind::Admin);
        assert_eq!(admin.map(|r| r.count), Some(4));
        assert_eq!(info.profile_rows[0].detail.as_deref(), Some("3 laufen"));
        // A dead session hides everything; a blip does not.
        hub.loaded(
            Err(AskError::Network(swiftly_net::ErrorKind::Cancelled)),
            None,
            None,
        );
        assert!(hub.available());
        hub.loaded(Err(AskError::SessionLost), None, None);
        assert!(!hub.available());
        assert!(hub.info().profile_rows.is_empty());
    }

    #[test]
    fn rails_follow_the_servers_slider_order_and_skip_unknown_ones() {
        let slider = |kind, enabled| DiscoverSlider {
            id: 1,
            kind,
            title: None,
            enabled,
            data: None,
        };
        let order = RailId::order(&[
            slider(SliderKind::PopularTv, true),
            slider(SliderKind::Studios, true),
            slider(SliderKind::Trending, false),
            slider(SliderKind::UpcomingMovies, true),
            slider(SliderKind::Other(99), true),
        ]);
        assert_eq!(order, [RailId::PopularTv, RailId::UpcomingMovies]);
        assert_eq!(
            RailId::order(&[]).len(),
            5,
            "default order without settings"
        );
    }

    #[test]
    fn a_stale_search_answer_is_dropped() {
        let mut vm = SeerrSearchVm::new(Locale::parse(DE), "2026-11-14");
        vm.begin("nord");
        vm.begin("nordsee");
        vm.loaded(
            "nord",
            Ok(Page {
                page: 1,
                total_pages: 1,
                total_results: 0,
                results: Vec::new(),
            }),
        );
        assert_eq!(vm.info().load, ListLoad::Loading);
        vm.loaded(
            "nordsee",
            Ok(Page {
                page: 1,
                total_pages: 1,
                total_results: 0,
                results: Vec::new(),
            }),
        );
        let info = vm.info();
        assert_eq!(info.load, ListLoad::Empty);
        assert_eq!(info.nothing_line.as_deref(), Some("Auch nicht bei Seerr."));
        vm.begin("");
        assert_eq!(vm.info().load, ListLoad::Idle);
    }

    #[test]
    fn a_request_reads_by_its_own_verdict_first() {
        let r = |status: i64, media: &str| {
            row(&format!(r#"{{"id":1,"status":{status},"media":{media}}}"#))
        };
        let today = "2026-11-14";
        assert_eq!(
            request_status(&r(1, r#"{"status":2}"#), None, today),
            SeerrStatus::Waits
        );
        assert_eq!(
            request_status(&r(3, r#"{"status":1}"#), None, today),
            SeerrStatus::Declined
        );
        assert_eq!(
            request_status(&r(4, r#"{"status":3}"#), None, today),
            SeerrStatus::Failed
        );
        assert_eq!(
            request_status(&r(5, r#"{"status":5}"#), None, today),
            SeerrStatus::Available
        );
        assert_eq!(
            request_status(&r(2, r#"{"status":3}"#), None, today),
            SeerrStatus::Searching
        );
        assert_eq!(
            request_status(
                &r(2, r#"{"status":3}"#),
                Some(&lite("Nordlandreise", &[], Some("2026-11-28"))),
                today
            ),
            SeerrStatus::Soon {
                date: "2026-11-28".into(),
                requested: true
            }
        );
    }

    #[test]
    fn the_queue_acts_at_once_and_a_failure_offers_another_try() {
        let admin = Perms(16);
        let mut vm = SeerrRequestsVm::new(
            Locale::parse(DE),
            "2026-11-14",
            RequestScope::Queue,
            1,
            admin,
        );
        vm.loaded(Ok(vec![row(
            r#"{"id":7,"status":1,"mediaType":"movie","requestedBy":{"id":5,"displayName":"Lena"},"media":{"tmdbId":9,"status":2}}"#,
        )]));
        let cache = TitleCache::default();
        let first = vm.info(&cache).rows.remove(0);
        assert!(first.can_approve && first.can_decline);
        assert_eq!(first.requested_by.as_deref(), Some("Lena"));
        vm.begin_verdict(7, Verdict::Approve);
        let working = vm.info(&cache).rows.remove(0);
        assert_eq!(
            (working.work, working.work_text.as_deref()),
            (RowWork::Working, Some("Wird freigegeben…"))
        );
        vm.verdict_done(7, Verdict::Approve, Err(AskError::NoPermission));
        let failed = vm.info(&cache).rows.remove(0);
        assert_eq!(failed.work, RowWork::Failed);
        assert!(failed.can_approve, "Nochmal");
        vm.verdict_done(7, Verdict::Approve, Ok(()));
        // Approved: the row left the waiting filter.
        vm.select(RequestPill::Open);
        assert!(vm.info(&cache).rows.is_empty());
        vm.select(RequestPill::Running);
        assert_eq!(vm.info(&cache).rows.len(), 1);
    }

    #[test]
    fn arrivals_need_the_setting_a_finished_request_and_no_earlier_x() {
        let mut vm = SeerrHomeVm::new(Locale::parse(DE), "2026-11-14");
        vm.set_available(true);
        vm.requests_loaded(vec![
            row(r#"{"id":1,"status":5,"mediaType":"movie","updatedAt":"2026-11-10","media":{"tmdbId":10,"status":5}}"#),
            row(r#"{"id":2,"status":5,"mediaType":"tv","updatedAt":"2026-11-12","media":{"tmdbId":11,"status":5}}"#),
            row(r#"{"id":3,"status":2,"mediaType":"movie","media":{"tmdbId":12,"status":3}}"#),
        ]);
        let ids = |vm: &SeerrHomeVm| {
            vm.arrival_candidates()
                .iter()
                .map(|c| c.request_id)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            ids(&vm),
            [2, 1],
            "newest first, the running one is not an arrival"
        );
        vm.set_dismissed(&[2]);
        assert_eq!(ids(&vm), [1]);
        assert_eq!(vm.dismiss(1), [1, 2]);
        assert!(ids(&vm).is_empty());
        vm.set_dismissed(&[]);
        vm.set_arrival_enabled(false);
        assert!(ids(&vm).is_empty(), "off stops the arrival search");
        vm.set_available(false);
        assert!(!vm.info(&TitleCache::default()).show);
    }

    #[test]
    fn the_home_block_reserves_its_last_shape_until_the_first_answer_and_comes_as_a_whole() {
        let mut cache = TitleCache::default();
        cache.0.insert(
            ("movie".into(), 12),
            TitleLite {
                title: "Nordstern".into(),
                year: Some(2026),
                poster: None,
                release_date: None,
                seasons: Vec::new(),
            },
        );
        let mut vm = SeerrHomeVm::new(Locale::parse(DE), "2026-11-14");
        vm.set_requests_enabled(true);
        // Not asked (no connection): nothing to draw and nothing to reserve.
        let idle = vm.info(&cache);
        assert_eq!(idle.state, SeerrHomeState::Hidden);
        assert!(idle.shape.is_empty() && !idle.show);
        // The first read starts: the stored shape ("lr": line and rail) is reserved, without content.
        vm.begin("lr");
        let first = vm.info(&cache);
        assert_eq!(first.state, SeerrHomeState::Pending);
        assert_eq!(
            first.shape,
            SeerrHomeShape {
                arrival: false,
                stacked: false,
                deep: false,
                attention: true,
                rail: true
            }
        );
        // Blank content of the right parts (nothing readable), so the host can lay out the room.
        assert!(!first.show && first.arrival.is_none());
        assert_eq!(first.rail.len(), 1);
        assert!(first.rail[0].title.trim().is_empty());
        assert!(
            first
                .attention
                .as_ref()
                .is_some_and(|a| a.title.trim().is_empty())
        );
        assert_eq!(first.memory, "lr");
        // Parts of the answer arrive: still reserved, never half drawn.
        vm.set_available(true);
        vm.set_attention(Some(("3 Anfragen".into(), 3)));
        vm.requests_loaded(vec![row(
            r#"{"id":3,"status":2,"mediaType":"movie","media":{"tmdbId":12,"status":3}}"#,
        )]);
        let partial = vm.info(&cache);
        assert_eq!(partial.state, SeerrHomeState::Pending);
        assert!(!partial.show && partial.rail[0].title.trim().is_empty());
        // The first answer: the real block, the same shape as reserved, ready to be remembered.
        vm.answered();
        let shown = vm.info(&cache);
        assert_eq!(shown.state, SeerrHomeState::Shown);
        assert!(shown.show && shown.attention.is_some() && shown.rail.len() == 1);
        assert_eq!(shown.shape, first.shape, "the rails below do not move");
        assert_eq!(shown.memory, "lr");
        // A reload keeps the block; the reserve never comes back.
        vm.begin("");
        assert_eq!(vm.info(&cache).state, SeerrHomeState::Shown);
        // Seerr has nothing to say now: the block closes and the next start reserves nothing.
        vm.set_attention(None);
        vm.requests_loaded(Vec::new());
        let none = vm.info(&cache);
        assert_eq!(none.state, SeerrHomeState::Hidden);
        assert_eq!(
            none.memory, "-",
            "stored as 'had nothing', so the next start does not wait"
        );
        assert!(!none.holds_page);
    }

    #[test]
    fn a_first_start_holds_the_page_for_the_answer_and_after_the_budget_reserves_the_first_guess() {
        let mut cache = TitleCache::default();
        cache.0.insert(
            ("movie".into(), 12),
            TitleLite {
                title: "Nordstern".into(),
                year: Some(2026),
                poster: None,
                release_date: None,
                seasons: Vec::new(),
            },
        );
        let rows = || {
            vec![row(
                r#"{"id":3,"status":2,"mediaType":"movie","media":{"tmdbId":12,"status":3}}"#,
            )]
        };
        // Path 1: nothing remembered, the answer is in time: the page waited, then shows the block as a whole.
        let mut vm = SeerrHomeVm::new(Locale::parse(DE), "2026-11-14");
        vm.set_requests_enabled(true);
        vm.begin("");
        let waiting = vm.info(&cache);
        assert!((waiting.state, waiting.holds_page) == (SeerrHomeState::Pending, true));
        assert_eq!(waiting.memory, "", "nothing to remember before an answer");
        vm.set_available(true);
        vm.requests_loaded(rows());
        assert!(
            vm.info(&cache).holds_page,
            "half an answer does not release the page"
        );
        vm.answered();
        let shown = vm.info(&cache);
        assert!((shown.state, shown.holds_page) == (SeerrHomeState::Shown, false));
        assert_eq!(shown.memory, "r");
        vm.budget_over();
        assert_eq!(
            vm.info(&cache).state,
            SeerrHomeState::Shown,
            "a late budget does nothing"
        );

        // Path 2: the budget runs out first: the page shows with the first guess (the rail), then Seerr has nothing.
        let mut vm = SeerrHomeVm::new(Locale::parse(DE), "2026-11-14");
        vm.begin("");
        vm.budget_over();
        let guess = vm.info(&cache);
        assert!((guess.state, guess.holds_page) == (SeerrHomeState::Pending, false));
        assert_eq!(guess.shape, SeerrHomeShape::FIRST_GUESS);
        assert_eq!(
            guess.rail.len(),
            1,
            "the reserve of the guess is laid out blank"
        );
        vm.set_available(true);
        vm.answered();
        let closed = vm.info(&cache);
        assert_eq!(
            (closed.state, closed.memory.as_str()),
            (SeerrHomeState::Hidden, "-")
        );

        // A remembered profile never holds the page, also with an empty memory of "-" (it had nothing).
        for code in ["r", "-"] {
            let mut vm = SeerrHomeVm::new(Locale::parse(DE), "2026-11-14");
            vm.begin(code);
            assert!(!vm.info(&cache).holds_page, "{code}");
        }
        assert!(SeerrHomeInfo::pending("").holds_page && !SeerrHomeInfo::pending("lr").holds_page);
    }

    #[test]
    fn a_pending_block_unusable_seerr_and_the_stored_code_round_trip() {
        let mut vm = SeerrHomeVm::new(Locale::parse(DE), "2026-11-14");
        vm.begin("arl");
        // Seerr answered that it cannot be used: the reserve goes, nothing is drawn.
        vm.set_available(false);
        vm.answered();
        let info = vm.info(&TitleCache::default());
        assert_eq!(
            (info.state, info.shape.is_empty()),
            (SeerrHomeState::Hidden, true)
        );
        let pending = SeerrHomeInfo::pending("ar");
        assert_eq!(pending.state, SeerrHomeState::Pending);
        assert_eq!(pending.memory, "ar");
        assert_eq!(SeerrHomeShape::parse("junk"), SeerrHomeShape::default());
        assert_eq!(seerr_home_memory_key(Some("u1")), "seerrHomeShape.u1");
        assert_eq!(seerr_home_memory_key(None), "seerrHomeShape");
    }

    fn lite(title: &str, seasons: &[SeasonDays], release: Option<&str>) -> TitleLite {
        TitleLite {
            title: title.into(),
            year: release
                .and_then(|d| d.get(..4))
                .and_then(|y| y.parse().ok()),
            poster: None,
            release_date: release.map(str::to_string),
            seasons: seasons.to_vec(),
        }
    }

    fn season(number: i64, first: &str, episodes: &[&str]) -> SeasonDays {
        SeasonDays {
            number,
            first_day: (!first.is_empty()).then(|| first.to_string()),
            episode_days: episodes.iter().map(|d| (*d).to_string()).collect(),
        }
    }

    /// A series request of the given seasons; `media_seasons` is Seerr's per-season state (status number).
    fn tv_request(status: i64, seasons: &[i64], media_seasons: &[(i64, i64)]) -> RequestRow {
        let asked: Vec<String> = seasons
            .iter()
            .map(|n| format!(r#"{{"seasonNumber":{n},"status":{status}}}"#))
            .collect();
        let known: Vec<String> = media_seasons
            .iter()
            .map(|(n, st)| format!(r#"{{"seasonNumber":{n},"status":{st}}}"#))
            .collect();
        row(&format!(
            r#"{{"id":9,"status":{status},"mediaType":"tv","seasons":[{}],"media":{{"tmdbId":50,"status":3,"mediaType":"tv","seasons":[{}]}}}}"#,
            asked.join(","),
            known.join(",")
        ))
    }

    #[test]
    fn a_season_that_has_not_aired_yet_says_when_it_comes() {
        // "Sweet P" season 2 airs on 26 Nov, season 1 is on the server: asked and approved, not searchable yet.
        let today = "2026-11-17";
        let seasons = [
            season(1, "2024-05-01", &["2024-05-01"]),
            season(2, "2026-11-26", &["2026-11-26", "2026-12-03"]),
        ];
        let title = lite("Sweet P", &seasons, Some("2024-05-01"));
        let req = tv_request(2, &[2], &[(1, 5)]);
        let status = request_status(&req, Some(&title), today);
        assert_eq!(
            status,
            SeerrStatus::Soon {
                date: "2026-11-26".into(),
                requested: true
            }
        );
        let t = Translator::new(Locale::parse(DE));
        assert_eq!(
            badge_of(&t, &status).line,
            "Angefragt · erscheint am 26. Nov."
        );
        assert_eq!(
            request_heading(&req, Some(&title)),
            ("Sweet P \u{b7} S2".into(), Some(2026))
        );
        // Once it has started and nothing is there, it is searched.
        assert_eq!(
            request_status(&req, Some(&title), "2026-11-27"),
            SeerrStatus::Searching
        );
    }

    #[test]
    fn a_running_season_with_all_aired_episodes_there_says_so() {
        // "TV Total" season 22: Seerr has the season, later episodes are still to air.
        let today = "2026-11-17";
        let title = lite(
            "TV Total",
            &[season(
                22,
                "2026-09-01",
                &["2026-09-01", "2026-11-10", "2026-11-24"],
            )],
            Some("1999-03-08"),
        );
        let req = tv_request(2, &[22], &[(22, 5)]);
        let status = request_status(&req, Some(&title), today);
        assert_eq!(
            status,
            SeerrStatus::UpToDate {
                next: Some("2026-11-24".into())
            }
        );
        let t = Translator::new(Locale::parse(DE));
        let badge = badge_of(&t, &status);
        assert_eq!(
            badge.line,
            "Alle bisherigen Folgen da \u{b7} nächste am 24. Nov."
        );
        assert!(status.is_requested(), "stays in the Angefragt rail");
        // Without a later date the season is simply there; part of it there reads "teilweise".
        let done = lite(
            "TV Total",
            &[season(22, "2026-09-01", &["2026-09-01"])],
            None,
        );
        assert_eq!(
            request_status(&req, Some(&done), today),
            SeerrStatus::Available
        );
        let part = tv_request(2, &[22], &[(22, 4)]);
        assert_eq!(
            request_status(&part, Some(&title), today),
            SeerrStatus::Partial
        );
        // Nothing of a released season there: searched. A finished request with more to come stays on the rail.
        let none = tv_request(2, &[22], &[]);
        assert_eq!(
            request_status(&none, Some(&title), today),
            SeerrStatus::Searching
        );
        let finished = tv_request(5, &[22], &[(22, 5)]);
        assert_eq!(
            request_status(&finished, Some(&title), today),
            SeerrStatus::UpToDate {
                next: Some("2026-11-24".into())
            }
        );
    }

    #[test]
    fn several_seasons_take_the_worst_word_and_the_tag_names_them() {
        let today = "2026-11-17";
        let seasons = [
            season(1, "2024-01-01", &["2024-01-01"]),
            season(2, "2025-01-01", &["2025-01-01"]),
            season(3, "2026-12-24", &["2026-12-24"]),
        ];
        let title = lite("Nordmeer", &seasons, Some("2024-01-01"));
        let req = tv_request(2, &[1, 2, 3], &[(1, 5), (2, 5)]);
        assert_eq!(
            request_status(&req, Some(&title), today),
            SeerrStatus::Soon {
                date: "2026-12-24".into(),
                requested: true
            }
        );
        let missing = tv_request(2, &[1, 2, 3], &[(1, 5)]);
        assert_eq!(
            request_status(&missing, Some(&title), today),
            SeerrStatus::Searching
        );
        assert_eq!(season_tag(&[2]), "S2");
        assert_eq!(season_tag(&[2, 1]), "S1\u{2013}2");
        assert_eq!(season_tag(&[1, 3]), "S1, S3");
        assert_eq!(season_tag(&[1, 2, 3, 5]), "S1\u{2013}3, S5");
        assert_eq!(
            request_heading(&req, Some(&title)).0,
            "Nordmeer \u{b7} S1\u{2013}3"
        );
        // A film keeps title and year; a series asked as a whole keeps its plain title.
        let film =
            row(r#"{"id":1,"status":2,"mediaType":"movie","media":{"tmdbId":5,"status":3}}"#);
        assert_eq!(
            request_heading(&film, Some(&lite("Dune", &[], Some("2021-10-22")))),
            ("Dune".into(), Some(2021))
        );
        let whole = tv_request(2, &[], &[]);
        assert_eq!(
            request_heading(&whole, Some(&title)),
            ("Nordmeer".into(), Some(2024))
        );
    }

    /// Every address a Seerr record hands to a screen is a finished one: a raw TMDB path (`/abc.jpg`) is relative
    /// and draws nothing (the cause of the blank "Meine Anfragen" and the cover-less arrival banner).
    fn raw_paths(debug: &str) -> Vec<String> {
        debug
            .split('"')
            .skip(1)
            .step_by(2)
            .filter(|s| {
                s.starts_with('/')
                    && [".jpg", ".jpeg", ".png", ".webp", ".svg"]
                        .iter()
                        .any(|e| s.ends_with(e))
            })
            .map(str::to_string)
            .collect()
    }

    fn title_info(art: &str, id: i64, name: &str, seasons: Vec<TitleSeason>) -> TitleInfo {
        TitleInfo {
            id,
            art: art.into(),
            title: name.into(),
            tagline: None,
            overview: None,
            release_date: Some("2024-05-01".into()),
            genres: Vec::new(),
            runtime: None,
            rating: None,
            poster_path: Some(format!("/p{id}.jpg")),
            backdrop_path: Some(format!("/b{id}.jpg")),
            tmdb_status: None,
            seasons,
            cast: Vec::new(),
            collection: None,
            media: None,
        }
    }

    #[test]
    fn no_seerr_record_hands_out_a_raw_picture_path() {
        let today = "2026-11-17";
        let mut cache = TitleCache::default();
        cache.put(&title_info("movie", 10, "Dune", Vec::new()));
        cache.put(&title_info(
            "tv",
            50,
            "Sweet P",
            vec![TitleSeason {
                season_number: 2,
                episode_count: 2,
                air_date: Some("2026-11-26".into()),
                ..TitleSeason::default()
            }],
        ));
        let rows = vec![
            row(
                r#"{"id":1,"status":5,"mediaType":"movie","updatedAt":"2026-11-10","media":{"tmdbId":10,"status":5}}"#,
            ),
            tv_request(2, &[2], &[]),
        ];
        let mut list =
            SeerrRequestsVm::new(Locale::parse(DE), today, RequestScope::Mine, 2, Perms(0));
        list.loaded(Ok(rows.clone()));
        let info = list.info(&cache);
        assert!(info.rows.iter().all(|r| {
            r.poster
                .as_deref()
                .is_some_and(|p| p.starts_with("https://"))
        }));
        let mut home = SeerrHomeVm::new(Locale::parse(DE), today);
        home.set_available(true);
        home.set_requests_enabled(true);
        home.requests_loaded(rows);
        home.arrivals_found(vec![(1, "lib-1".into())]);
        let block = home.info(&cache);
        assert!(block.arrival.as_ref().is_some_and(|a| {
            a.poster
                .as_deref()
                .is_some_and(|p| p.starts_with("https://"))
        }));
        assert!(!block.rail.is_empty());
        let mut search = SeerrSearchVm::new(Locale::parse(DE), today);
        search.begin("nord");
        search.loaded(
            "nord",
            Ok(Page {
                page: 1,
                total_pages: 1,
                total_results: 2,
                results: vec![
                    SearchResult::Person(PersonCard {
                        id: 7,
                        name: "Mara Brandt".into(),
                        profile_path: Some("/c7.jpg".into()),
                        known_for: None,
                    }),
                    SearchResult::Collection(CollectionCard {
                        id: 8,
                        name: "Nord Collection".into(),
                        poster_path: Some("/p8.jpg".into()),
                        backdrop_path: None,
                    }),
                ],
            }),
        );
        let walked = [
            format!("{info:#?}"),
            format!("{block:#?}"),
            format!("{:#?}", search.info()),
        ];
        for text in walked {
            assert!(
                raw_paths(&text).is_empty(),
                "raw picture paths: {:?}",
                raw_paths(&text)
            );
        }
        assert!(
            raw_paths(r#"poster: Some("/a.jpg")"#).len() == 1,
            "the guard sees a raw path"
        );
    }
}
