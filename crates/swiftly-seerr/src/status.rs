//! One status vocabulary for every screen: what a title (or one season of it) is, for this viewer.
//! Pure: [`status_of`] reads the `mediaInfo` of Seerr, the release date and today's date.

use crate::models::SeerrState;
use crate::types::{MediaInfo, QueueItem, RequestRow, RequestStatus, TitleSeason};

/// What the UI shows for a title or season.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeerrStatus {
    /// "anfragbar": nothing asked for yet.
    Requestable,
    /// "wartet": a request waits for an admin.
    Waits,
    /// "wird gesucht": approved, the downloader has nothing yet.
    Searching,
    /// "erscheint am": not released yet. `requested` is true when a request is already in.
    Soon {
        /// Release day, `yyyy-mm-dd`.
        date: String,
        /// A request exists.
        requested: bool,
    },
    /// "wird geholt": a download runs.
    Fetching {
        /// 0...100 over all queue entries of the title or season.
        percent: u8,
        /// Seconds until the slowest entry is done, when the downloader knows.
        eta_seconds: Option<u32>,
    },
    /// "teilweise": part of it is on the server.
    Partial,
    /// "alle bisherigen Folgen da": everything that has aired is on the server, more is still to come.
    UpToDate {
        /// The next episode's day, `yyyy-mm-dd`, when TMDB lists one.
        next: Option<String>,
    },
    /// "verfügbar".
    Available,
    /// "abgelehnt".
    Declined,
    /// "fehlgeschlagen": the downloader could not take the request.
    Failed,
    /// "gesperrt": on the blocklist.
    Blocked,
}

impl SeerrStatus {
    /// The German word (also the translation key).
    pub fn word(&self) -> &'static str {
        match self {
            Self::Requestable => "anfragbar",
            Self::Waits => "wartet",
            Self::Searching => "wird gesucht",
            Self::Soon { .. } => "erscheint am",
            Self::Fetching { .. } => "wird geholt",
            Self::Partial => "teilweise",
            Self::UpToDate { .. } => "aktuell",
            Self::Available => "verfügbar",
            Self::Declined => "abgelehnt",
            Self::Failed => "fehlgeschlagen",
            Self::Blocked => "gesperrt",
        }
    }

    /// A new request can be made (a request button makes sense).
    pub fn can_request(&self) -> bool {
        matches!(
            self,
            Self::Requestable
                | Self::Partial
                | Self::Declined
                | Self::Soon {
                    requested: false,
                    ..
                }
        )
    }

    /// A request is on its way (not yet on the server).
    pub fn is_requested(&self) -> bool {
        matches!(
            self,
            Self::Waits
                | Self::Searching
                | Self::Fetching { .. }
                | Self::UpToDate { .. }
                | Self::Soon {
                    requested: true,
                    ..
                }
        )
    }

    /// Order of the "Angefragt" rail: downloading, then searching, waiting, soon, the rest.
    pub fn rail_rank(&self) -> u8 {
        match self {
            Self::Fetching { .. } => 0,
            Self::Searching => 1,
            Self::Waits => 2,
            Self::Soon { .. } | Self::UpToDate { .. } => 3,
            _ => 4,
        }
    }
}

/// Input of [`status_of`].
#[derive(Debug, Clone, Copy)]
pub struct StatusInput<'a> {
    /// Seerr's record, `None` when Seerr does not know the title.
    pub media: Option<&'a MediaInfo>,
    /// The 4K lane.
    pub is4k: bool,
    /// One season (series), `None` for the whole title.
    pub season: Option<i64>,
    /// Release day (`yyyy-mm-dd`) of the title or the season.
    pub release_date: Option<&'a str>,
    /// Today (`yyyy-mm-dd`).
    pub today: &'a str,
}

fn queue_for(media: &MediaInfo, is4k: bool, season: Option<i64>) -> Vec<&QueueItem> {
    media
        .queue(is4k)
        .iter()
        .filter(|q| match (season, q.episode) {
            (Some(n), Some(e)) => e.season_number == n,
            (Some(_), None) => false,
            (None, _) => true,
        })
        .collect()
}

fn fetching(items: &[&QueueItem]) -> SeerrStatus {
    let size: f64 = items.iter().map(|q| q.size).sum();
    let left: f64 = items.iter().map(|q| q.size_left).sum();
    let percent = if size > 0.0 {
        ((1.0 - left / size) * 100.0).round().clamp(0.0, 100.0) as u8
    } else {
        0
    };
    SeerrStatus::Fetching {
        percent,
        eta_seconds: items.iter().filter_map(|q| q.seconds_left()).max(),
    }
}

fn relevant(media: &MediaInfo, is4k: bool, season: Option<i64>) -> Vec<&RequestRow> {
    media
        .requests
        .iter()
        .filter(|r| r.is4k == is4k)
        .filter(|r| match season {
            Some(n) => r.seasons.is_empty() || r.seasons.iter().any(|s| s.season_number == n),
            None => true,
        })
        .collect()
}

/// The request that decides the word: a live one (pending, approved) before a dead one (failed,
/// declined), the newest first; completed ones do not count.
fn deciding<'a>(requests: &[&'a RequestRow]) -> Option<&'a RequestRow> {
    let live =
        |r: &&&RequestRow| matches!(r.status, RequestStatus::Pending | RequestStatus::Approved);
    let dead =
        |r: &&&RequestRow| matches!(r.status, RequestStatus::Failed | RequestStatus::Declined);
    requests
        .iter()
        .filter(live)
        .max_by_key(|r| r.id)
        .or_else(|| requests.iter().filter(dead).max_by_key(|r| r.id))
        .copied()
}

/// The status of a title, or of one season, in one lane.
///
/// Order: blocklisted, available, partly available (title level), a running download, the deciding
/// request (waiting, approved, failed, declined), the number of the lane, release date, requestable.
pub fn status_of(input: &StatusInput<'_>) -> SeerrStatus {
    let unreleased = input
        .release_date
        .filter(|d| !d.is_empty())
        .filter(|d| *d > input.today);
    let soon = |requested: bool| match unreleased {
        Some(d) => SeerrStatus::Soon {
            date: d.to_string(),
            requested,
        },
        None if requested => SeerrStatus::Searching,
        None => SeerrStatus::Requestable,
    };
    let Some(media) = input.media else {
        return soon(false);
    };
    let title_state = media.lane(input.is4k);
    if title_state == SeerrState::Blocklisted {
        return SeerrStatus::Blocked;
    }
    let state = match input.season {
        Some(n) => media.season_state(n, input.is4k),
        None => title_state,
    };
    if state == SeerrState::Present {
        return SeerrStatus::Available;
    }
    if input.season.is_none() && state == SeerrState::PartWayPresent {
        return SeerrStatus::Partial;
    }
    let queue = queue_for(media, input.is4k, input.season);
    if !queue.is_empty() {
        return fetching(&queue);
    }
    let requests = relevant(media, input.is4k, input.season);
    if let Some(r) = deciding(&requests) {
        return match r.status {
            RequestStatus::Pending => SeerrStatus::Waits,
            RequestStatus::Approved => soon(true),
            RequestStatus::Failed => SeerrStatus::Failed,
            _ => SeerrStatus::Declined,
        };
    }
    match state {
        SeerrState::Loads => soon(true),
        SeerrState::WaitsSharing => SeerrStatus::Waits,
        SeerrState::PartWayPresent => SeerrStatus::Partial,
        _ => soon(false),
    }
}

// ---------------------------------------------------------------- seasons of a request

/// What the request rules need of one season: its first day and the days of its episodes (from TMDB, through
/// Seerr's `tv/{id}` and `tv/{id}/season/{n}`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SeasonDays {
    /// Season number.
    pub number: i64,
    /// First day, `yyyy-mm-dd`; `None` when TMDB has no day yet.
    pub first_day: Option<String>,
    /// The day of every episode that has one.
    pub episode_days: Vec<String>,
}

impl SeasonDays {
    /// The days of a season page.
    pub fn of(season: &TitleSeason) -> Self {
        let mut episode_days: Vec<String> = season
            .episodes
            .iter()
            .filter_map(|e| e.air_date.clone())
            .filter(|d| !d.is_empty())
            .collect();
        episode_days.sort();
        let first_day = season
            .air_date
            .clone()
            .filter(|d| !d.is_empty())
            .or_else(|| episode_days.first().cloned());
        Self {
            number: season.season_number,
            first_day,
            episode_days,
        }
    }

    /// The first day lies ahead: the season cannot be searched yet.
    pub fn first_day_ahead(&self, today: &str) -> Option<&str> {
        self.first_day
            .as_deref()
            .filter(|d| !d.is_empty() && *d > today)
    }

    /// The next episode that has not aired yet.
    pub fn next_day(&self, today: &str) -> Option<&str> {
        self.episode_days
            .iter()
            .map(String::as_str)
            .find(|d| *d > today)
    }
}

/// Wants one season of a request in one status: what Seerr says it has, what is downloading, and for a season that
/// has not started its first day.
///
/// * the first day lies ahead: "erscheint am" (the request waits for it);
/// * Seerr has the whole season: "da", or "alle bisherigen Folgen da" while later episodes are still to air;
/// * part of it is on the server: "teilweise";
/// * a download runs: "wird geholt";
/// * released, nothing there: "wird gesucht".
pub fn season_request_status(
    media: Option<&MediaInfo>,
    is4k: bool,
    season: &SeasonDays,
    today: &str,
) -> SeerrStatus {
    let state = media.map_or(SeerrState::Opened, |m| m.season_state(season.number, is4k));
    let first = status_of(&StatusInput {
        media,
        is4k,
        season: Some(season.number),
        release_date: season.first_day.as_deref(),
        today,
    });
    match first {
        SeerrStatus::Available => match season.next_day(today) {
            Some(day) => SeerrStatus::UpToDate {
                next: Some(day.to_string()),
            },
            None => SeerrStatus::Available,
        },
        SeerrStatus::Fetching { .. }
        | SeerrStatus::Failed
        | SeerrStatus::Declined
        | SeerrStatus::Blocked => first,
        _ => {
            if let Some(day) = season.first_day_ahead(today) {
                SeerrStatus::Soon {
                    date: day.to_string(),
                    requested: true,
                }
            } else if state == SeerrState::PartWayPresent {
                SeerrStatus::Partial
            } else {
                SeerrStatus::Searching
            }
        }
    }
}

/// One word for a request of several seasons: what is missing now beats what is only waiting, a day beats "all
/// there so far", and only when every season is there the request is "da".
pub fn combine_seasons(parts: Vec<SeerrStatus>) -> SeerrStatus {
    let first_of = |pick: &dyn Fn(&SeerrStatus) -> bool| parts.iter().find(|s| pick(s)).cloned();
    if let Some(s) = first_of(&|s| matches!(s, SeerrStatus::Fetching { .. })) {
        return s;
    }
    if let Some(s) = first_of(&|s| matches!(s, SeerrStatus::Searching)) {
        return s;
    }
    if let Some(s) = first_of(&|s| matches!(s, SeerrStatus::Partial)) {
        return s;
    }
    let days: Vec<&str> = parts
        .iter()
        .filter_map(|s| match s {
            SeerrStatus::Soon { date, .. } => Some(date.as_str()),
            SeerrStatus::UpToDate { next } => next.as_deref(),
            _ => None,
        })
        .collect();
    let earliest = days.iter().min().map(|d| (*d).to_string());
    if parts.iter().any(|s| matches!(s, SeerrStatus::Soon { .. }))
        && let Some(date) = earliest
    {
        return SeerrStatus::Soon {
            date,
            requested: true,
        };
    }
    if parts
        .iter()
        .any(|s| matches!(s, SeerrStatus::UpToDate { .. }))
    {
        return SeerrStatus::UpToDate { next: earliest };
    }
    SeerrStatus::Available
}

#[cfg(test)]
mod season_tests {
    use super::*;

    const TODAY: &str = "2026-11-17";

    fn media(seasons: &[(i64, i64)]) -> MediaInfo {
        let known: Vec<String> = seasons
            .iter()
            .map(|(n, st)| format!(r#"{{"seasonNumber":{n},"status":{st}}}"#))
            .collect();
        serde_json::from_str(&format!(
            r#"{{"tmdbId":50,"status":3,"mediaType":"tv","seasons":[{}]}}"#,
            known.join(",")
        ))
        .unwrap()
    }

    fn days(number: i64, first: &str, episodes: &[&str]) -> SeasonDays {
        SeasonDays {
            number,
            first_day: (!first.is_empty()).then(|| first.to_string()),
            episode_days: episodes.iter().map(|d| (*d).to_string()).collect(),
        }
    }

    fn soon(date: &str) -> SeerrStatus {
        SeerrStatus::Soon {
            date: date.into(),
            requested: true,
        }
    }

    #[test]
    fn a_season_that_has_not_started_says_its_day_not_searching() {
        let m = media(&[]);
        let s = days(2, "2026-11-26", &["2026-11-26", "2026-12-03"]);
        assert_eq!(
            season_request_status(Some(&m), false, &s, TODAY),
            soon("2026-11-26")
        );
        // The day itself counts as released: then it is searched.
        assert_eq!(
            season_request_status(Some(&m), false, &s, "2026-11-26"),
            SeerrStatus::Searching
        );
        assert_eq!(
            season_request_status(None, false, &s, "2026-11-27"),
            SeerrStatus::Searching
        );
    }

    #[test]
    fn aired_episodes_all_there_is_up_to_date_not_searching() {
        let s = days(
            22,
            "2026-09-01",
            &["2026-09-01", "2026-11-10", "2026-11-24"],
        );
        assert_eq!(
            season_request_status(Some(&media(&[(22, 5)])), false, &s, TODAY),
            SeerrStatus::UpToDate {
                next: Some("2026-11-24".into())
            }
        );
        let done = days(22, "2026-09-01", &["2026-09-01"]);
        assert_eq!(
            season_request_status(Some(&media(&[(22, 5)])), false, &done, TODAY),
            SeerrStatus::Available
        );
    }

    #[test]
    fn part_there_nothing_there_and_a_run() {
        let s = days(22, "2026-09-01", &["2026-09-01", "2026-11-10"]);
        assert_eq!(
            season_request_status(Some(&media(&[(22, 4)])), false, &s, TODAY),
            SeerrStatus::Partial
        );
        assert_eq!(
            season_request_status(Some(&media(&[])), false, &s, TODAY),
            SeerrStatus::Searching
        );
    }

    #[test]
    fn several_seasons_take_what_is_missing_first() {
        let up = SeerrStatus::UpToDate {
            next: Some("2026-11-24".into()),
        };
        let fetching = SeerrStatus::Fetching {
            percent: 40,
            eta_seconds: None,
        };
        assert_eq!(
            combine_seasons(vec![
                SeerrStatus::Available,
                SeerrStatus::Searching,
                soon("2026-12-24")
            ]),
            SeerrStatus::Searching
        );
        assert_eq!(
            combine_seasons(vec![fetching.clone(), SeerrStatus::Searching]),
            fetching
        );
        assert_eq!(
            combine_seasons(vec![
                SeerrStatus::Available,
                SeerrStatus::Partial,
                soon("2026-12-24")
            ]),
            SeerrStatus::Partial
        );
        assert_eq!(
            combine_seasons(vec![up.clone(), soon("2026-12-24"), soon("2026-12-01")]),
            soon("2026-11-24")
        );
        assert_eq!(
            combine_seasons(vec![SeerrStatus::Available, up.clone()]),
            up
        );
        assert_eq!(
            combine_seasons(vec![SeerrStatus::Available, SeerrStatus::Available]),
            SeerrStatus::Available
        );
    }

    #[test]
    fn season_days_read_a_season_page() {
        let page = TitleSeason {
            season_number: 3,
            air_date: None,
            episodes: vec![
                crate::types::TitleEpisode {
                    air_date: Some("2026-12-03".into()),
                    ..Default::default()
                },
                crate::types::TitleEpisode {
                    air_date: Some("2026-11-26".into()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let d = SeasonDays::of(&page);
        assert_eq!(d.first_day.as_deref(), Some("2026-11-26"));
        assert_eq!(d.first_day_ahead(TODAY), Some("2026-11-26"));
        assert_eq!(d.next_day("2026-11-26"), Some("2026-12-03"));
        assert_eq!(d.next_day("2026-12-03"), None);
    }
}
