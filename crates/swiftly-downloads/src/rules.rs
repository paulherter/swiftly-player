//! `DownloadRules` and `ProgressEstimator` (Downloads.swift:386-822): the decisions around
//! downloads, all verifiable without a device. Who loads next, whether space is enough, what is
//! expendable, how a list is grouped.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::future::Future;

use swiftly_model::{Item, UserItemData};
use swiftly_playback::sections::Segment;
use swiftly_rules::download_audio::AudioTrackRules;

use crate::group::DownloadGroup;
use crate::item::{Art, DownloadItem, follower_of};
use crate::size_text;
use crate::state::DownloadState;

/// How much space on the device stays untouched: one gigabyte (`padding`). A full disk stops
/// iOS from unpacking an update.
pub const PADDING: i64 = 1_073_741_824;

/// From this fraction a title counts as watched: Jellyfin's `MaxResumePct` (`watchedOff`).
pub const WATCHED_OFF: f64 = 0.9;

/// Below this no position is remembered: Jellyfin's `MinResumePct` (`pointOff`).
pub const POINT_OFF: f64 = 0.05;

/// What the tick does with the network.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetworkVerdict {
    /// Loading may begin or continue.
    Load,
    /// What is running goes back into the queue; it waits for Wi-Fi.
    PutBack,
    /// Do nothing yet: the network is not known.
    WaitFor,
}

/// What a download would cost and what options there are.
#[derive(Debug, Clone, PartialEq)]
pub struct SpaceInfo {
    /// Does it fit without clearing, with [`PADDING`] as reserve?
    pub suffices: bool,
    /// What would be free after the download. Can be negative.
    pub free_after: i64,
    /// Watched, finished downloads, largest first.
    pub dispensable: Vec<DownloadItem>,
    /// How much they take up together.
    pub dispensable_bytes: i64,
}

impl SpaceInfo {
    /// Is it enough once everything expendable is gone?
    pub fn suffices_to_clean_up(&self) -> bool {
        self.suffices || self.free_after + self.dispensable_bytes >= 0
    }
}

/// What the footer of a download picker says on the right, before pressing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FootSpace {
    /// This much stays free after loading.
    Free(i64),
    /// This much is missing for it to fit, reserve included.
    Few(i64),
}

/// `a` before `b` by `(season ?? 0, episode ?? 0, id)`.
fn by_number(a: &DownloadItem, b: &DownloadItem) -> Ordering {
    (a.season.unwrap_or(0), a.episode.unwrap_or(0), &a.id).cmp(&(
        b.season.unwrap_or(0),
        b.episode.unwrap_or(0),
        &b.id,
    ))
}

/// The decisions around downloads.
pub struct DownloadRules;

impl DownloadRules {
    /// Which item should run next, or `None`. `None` means one of three: one is already
    /// running, none is waiting, or Wi-Fi is missing and `only_over_wlan` applies. Oldest first;
    /// on equal times the id decides so the order does not depend on the caller's sorting.
    pub fn next_one(
        entries: &[DownloadItem],
        wlan: bool,
        only_over_wlan: bool,
    ) -> Option<&DownloadItem> {
        if entries.iter().any(|e| e.state == DownloadState::Loads) {
            return None;
        }
        if !Self::may_load(wlan, only_over_wlan) {
            return None;
        }
        entries
            .iter()
            .filter(|e| e.state == DownloadState::Waits)
            .min_by(|a, b| {
                a.created
                    .total_cmp(&b.created)
                    .then_with(|| a.id.cmp(&b.id))
            })
    }

    /// May anything be loaded at all? Asked on start, on network change and on launch, and
    /// answers the same each time.
    pub fn may_load(wlan: bool, only_over_wlan: bool) -> bool {
        wlan || !only_over_wlan
    }

    /// While the network is unknown, nothing starts. Without "Wi-Fi only" the network does not
    /// matter. `PutBack` is not a pause: the title waits so the next tick on Wi-Fi resumes it.
    pub fn network_verdict(wlan: Option<bool>, only_over_wlan: bool) -> NetworkVerdict {
        if !only_over_wlan {
            return NetworkVerdict::Load;
        }
        match wlan {
            None => NetworkVerdict::WaitFor,
            Some(true) => NetworkVerdict::Load,
            Some(false) => NetworkVerdict::PutBack,
        }
    }

    /// Cost of a download of `bytes` with `free` bytes on the device (`slot(for:free:available:)`).
    pub fn slot(bytes: i64, free: i64, available: &[DownloadItem]) -> SpaceInfo {
        let leftover = free - bytes - PADDING;
        let distance = Self::dispensable(available);
        SpaceInfo {
            suffices: leftover >= 0,
            free_after: leftover,
            dispensable_bytes: distance.iter().map(|d| d.bytes).sum(),
            dispensable: distance,
        }
    }

    /// The footer says the same as the sheet after it: the reserve counts in the shortfall.
    /// Without a selection nothing is missing; it shows what is free now.
    pub fn foot_space(bytes: i64, free: i64) -> FootSpace {
        if bytes <= 0 {
            return FootSpace::Free(free.max(0));
        }
        let leftover = free - bytes - PADDING;
        if leftover >= 0 {
            FootSpace::Free(free - bytes)
        } else {
            FootSpace::Few(-leftover)
        }
    }

    /// What the app may suggest removing: fully downloaded and watched, largest first. Partial
    /// downloads are deliberately not included.
    pub fn dispensable(entries: &[DownloadItem]) -> Vec<DownloadItem> {
        let mut list: Vec<DownloadItem> = entries
            .iter()
            .filter(|e| e.state == DownloadState::Done && e.watched)
            .cloned()
            .collect();
        list.sort_by(|a, b| (b.bytes, &b.id).cmp(&(a.bytes, &a.id)));
        list
    }

    /// Movies stay single, episodes of the same series become a group. Newest first; within a
    /// series by season and episode. An episode without a series id stands alone.
    pub fn grouped(entries: &[DownloadItem]) -> Vec<DownloadGroup> {
        let mut groups: Vec<DownloadGroup> = Vec::new();
        let mut series_list: HashMap<&str, Vec<&DownloadItem>> = HashMap::new();
        let mut order: Vec<&str> = Vec::new();

        for p in entries {
            let Some(sid) = p
                .series_identifier
                .as_deref()
                .filter(|_| p.art == Art::Episode)
            else {
                groups.push(DownloadGroup::Single(p.clone()));
                continue;
            };
            if !series_list.contains_key(sid) {
                order.push(sid);
            }
            series_list.entry(sid).or_default().push(p);
        }

        for sid in order {
            let mut episodes: Vec<DownloadItem> = series_list
                .get(sid)
                .into_iter()
                .flatten()
                .map(|e| (*e).clone())
                .collect();
            episodes.sort_by(by_number);
            let title = episodes
                .first()
                .map(|e| e.series.clone().unwrap_or_else(|| e.title.clone()))
                .unwrap_or_default();
            groups.push(DownloadGroup::Series {
                id: sid.to_owned(),
                title,
                episodes,
            });
        }

        groups.sort_by(|a, b| {
            b.created()
                .total_cmp(&a.created())
                .then_with(|| b.id().cmp(&a.id()))
        });
        groups
    }

    /// "18,6 GB" (see [`size_text::size`]); `decimal_separator` comes from the (size) locale.
    pub fn size(bytes: i64, decimal_separator: &str) -> String {
        size_text::size(bytes, decimal_separator)
    }

    /// When progress is shown: at most once per second. Always let through: the first report,
    /// a restart (less than before) and the end.
    pub fn progress_show(
        loaded: i64,
        total: i64,
        before: Option<i64>,
        elapsed: Option<f64>,
    ) -> bool {
        let (Some(before), Some(elapsed)) = (before, elapsed) else {
            return true;
        };
        if loaded < before {
            return true;
        }
        if total > 0 && loaded >= total {
            return loaded != before;
        }
        let step = (total / 200).max(1);
        loaded - before >= step && elapsed >= 1.0
    }

    /// "0,84 von 2,31 GB": both numbers in the same unit, with fixed decimals. The total sets
    /// the unit: GB with two decimals, MB with none, KB with none. Returns `(loaded, total)`;
    /// the total carries the unit.
    pub fn progress(loaded: i64, total: i64, decimal_separator: &str) -> (String, String) {
        let (divider, unit, set): (f64, &str, usize) = if total >= 1_000_000_000 {
            (1e9, "GB", 2)
        } else if total >= 1_000_000 {
            (1e6, "MB", 0)
        } else {
            (1e3, "KB", 0)
        };
        let figure = |b: i64| size_text::fixed(b.max(0) as f64 / divider, set, decimal_separator);
        // Swift: `min(loaded, max(total, loaded))`, which is `loaded`.
        let shown = loaded.min(total.max(loaded));
        (figure(shown), format!("{} {}", figure(total), unit))
    }

    /// Which downloaded episode the play button takes: the first finished one not yet watched,
    /// by season and episode; if all are watched, the first. Running and waiting ones do not
    /// count.
    pub fn next_episode(entries: &[DownloadItem]) -> Option<&DownloadItem> {
        let mut done: Vec<&DownloadItem> = entries
            .iter()
            .filter(|e| e.state == DownloadState::Done)
            .collect();
        done.sort_by(|a, b| by_number(a, b));
        done.iter()
            .find(|e| !e.watched)
            .or_else(|| done.first())
            .copied()
    }

    /// The next downloaded episode after `id`, for "Next episode" when no server answers. Only
    /// finished downloads of the same account and series. Specials (season 0) come first; a gap
    /// is skipped. Without an episode number there is none.
    pub fn episode_post<'a>(id: &str, entries: &'a [DownloadItem]) -> Option<&'a DownloadItem> {
        let now = entries.iter().find(|e| e.id == id)?;
        if now.art != Art::Episode {
            return None;
        }
        let series = now.series_identifier.as_deref()?;
        let number = now.episode?;
        let here = (now.season.unwrap_or(0), number);
        entries
            .iter()
            .filter(|e| {
                e.state == DownloadState::Done
                    && e.account == now.account
                    && e.series_identifier.as_deref() == Some(series)
                    && e.id != id
                    && e.episode.is_some()
                    && (e.season.unwrap_or(0), e.episode.unwrap_or(0)) > here
            })
            .min_by(|a, b| by_number(a, b))
    }

    /// Has this playback reached the end? From 90 % a title counts as watched.
    pub fn reached_end(ticks: i64, runtime_ticks: Option<i64>) -> bool {
        let Some(runtime) = runtime_ticks.filter(|r| *r > 0) else {
            return false;
        };
        ticks as f64 / runtime as f64 >= WATCHED_OFF
    }

    /// Does this entry have a successor to look for: a finished episode with a series and a
    /// number?
    pub fn has_successor(item: &DownloadItem) -> bool {
        item.state == DownloadState::Done
            && item.art == Art::Episode
            && item.series_identifier.is_some()
            && item.episode.is_some()
    }

    /// The episode after `item` in the series, from the server's list: by season and number,
    /// specials (season 0) before everything. `None` after the last episode.
    pub fn following_episode<'a>(item: &DownloadItem, episodes: &'a [Item]) -> Option<&'a Item> {
        let number = item.episode?;
        let here = (item.season.unwrap_or(0), number);
        let key = |e: &Item| {
            (
                e.parent_index_number.unwrap_or(0),
                e.index_number.unwrap_or(0),
            )
        };
        episodes
            .iter()
            .filter(|e| e.id != item.id && e.index_number.is_some() && key(e) > here)
            .min_by(|a, b| key(a).cmp(&key(b)).then_with(|| a.id.cmp(&b.id)))
    }

    /// The download that follows a watched one: same series and account, same quality and same
    /// audio language, and the link back that removes the watched one once this is on the
    /// device. If the next episode lacks the language it loads with every track; the language is
    /// carried along anyway. `now` is the creation time.
    pub fn follow_up(
        rules: &dyn AudioTrackRules,
        watched: &DownloadItem,
        next: &Item,
        now: f64,
    ) -> DownloadItem {
        follower_of(rules, watched, next, now)
    }

    /// Which watched episode to remove now that `item` is finished, if any: the one it was
    /// loaded to follow, as long as it is still on the device, finished and watched.
    pub fn replaced_one(item: &DownloadItem, entries: &[DownloadItem]) -> Option<String> {
        if item.state != DownloadState::Done {
            return None;
        }
        let old = item.replaces.as_deref()?;
        let entry = entries
            .iter()
            .find(|e| e.id == old && e.account == item.account)?;
        (entry.state == DownloadState::Done && entry.watched).then(|| old.to_owned())
    }

    /// The segments of a title, stored ones first: if some were stored at download they apply
    /// without a request. Otherwise `server` is asked; empty there means "none" or
    /// "unreachable", and both mean no button.
    pub async fn sections<F, Fut>(stored: Option<Vec<Segment>>, server: F) -> Vec<Segment>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Vec<Segment>>,
    {
        match stored {
            Some(s) if !s.is_empty() => s,
            _ => server().await,
        }
    }

    /// "Next episode": online as before, without a server the next downloaded one. Without
    /// network it is not even asked. If the request fails the downloaded one applies; if the
    /// server answers "none", that stands.
    pub async fn episode_post_item<F, Fut, E>(
        item: &Item,
        entries: &[DownloadItem],
        without_network: bool,
        server: F,
    ) -> Option<Item>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Option<Item>, E>>,
    {
        let loaded = Self::episode_post(&item.id, entries).map(DownloadItem::as_item);
        if without_network {
            return loaded;
        }
        server().await.unwrap_or(loaded)
    }

    /// What the server says about a downloaded title, into the entry. Watched, position and time
    /// come from the server, unless the entry carries a newer state from here that is not yet
    /// reported (one second of slack).
    pub fn follow(p: &DownloadItem, watch_state: Option<&UserItemData>) -> DownloadItem {
        let Some(watch_state) = watch_state else {
            return p.clone();
        };
        let server_play = watch_state.last_play();
        if let Some(here) = p.recent
            && here - server_play.unwrap_or(f64::NEG_INFINITY) > 1.0
        {
            return p.clone();
        }
        let mut q = p.clone();
        q.watched = watch_state.played.unwrap_or(false);
        q.point_ticks = watch_state.playback_position_ticks.filter(|t| *t > 0);
        q.recent = server_play.or(p.recent);
        q
    }

    /// The progress-sync state of one download after `event` ([`ProgressSync::transition`]).
    pub fn sync_state(
        p: &DownloadItem,
        now: ProgressSync,
        event: SyncEvent<'_>,
    ) -> Result<ProgressSync, SyncRefused> {
        now.transition(p, event)
    }

    /// The position a download holds that the server has not seen yet, as `(ticks, moment)`
    /// (the `LocalAhead` state against `server`).
    pub fn unreported_progress(
        p: &DownloadItem,
        server: Option<&UserItemData>,
    ) -> Option<(i64, f64)> {
        match ProgressSync::judge(p, server) {
            ProgressSync::LocalAhead { ticks, moment } => Some((ticks, moment)),
            _ => None,
        }
    }

    /// "12 titles - 42.8 GB": count and bytes of what is finished.
    pub fn allocation(entries: &[DownloadItem]) -> (usize, i64) {
        let done: Vec<&DownloadItem> = entries
            .iter()
            .filter(|e| e.state == DownloadState::Done)
            .collect();
        (done.len(), done.iter().map(|e| e.bytes).sum())
    }
}

/// Keep counting between two reports, never backwards (Downloads.swift:776). Reports come at
/// most once per second; this computes the in-between at the pace of the last seconds.
///
/// Four rules: the pace is smoothed; at most one and a half seconds past the last report; never
/// less than last shown (only a restart resets); paused means standing.
#[derive(Debug, Clone, Default)]
pub struct ProgressEstimator {
    reported: Option<i64>,
    report_time: Option<f64>,
    total: i64,
    running: bool,
    /// Bytes per second, smoothed.
    pub tempo: f64,
    shown: i64,
}

impl ProgressEstimator {
    /// A fresh estimator.
    pub fn new() -> Self {
        Self::default()
    }

    /// A report from the transfer, `time` in seconds on any consistent clock.
    pub fn report(&mut self, loaded: i64, total: i64, time: f64) {
        self.total = total;
        match (self.reported, self.report_time) {
            (Some(g), _) if loaded < g => {
                // Restart: what stood before no longer applies.
                self.tempo = 0.0;
                self.shown = loaded;
            }
            (Some(g), Some(mz)) if self.running => {
                let dt = time - mz;
                if dt > 0.05 {
                    let new = loaded.saturating_sub(g) as f64 / dt;
                    self.tempo = if self.tempo == 0.0 {
                        new
                    } else {
                        self.tempo * 0.7 + new * 0.3
                    };
                }
            }
            _ => {}
        }
        self.reported = Some(loaded);
        self.report_time = Some(time);
        self.running = true;
    }

    /// No bytes come anymore: the number stays where it is.
    pub fn halt(&mut self) {
        self.running = false;
        self.tempo = 0.0;
    }

    /// The number to show at `time`.
    pub fn value(&mut self, time: f64) -> i64 {
        let (Some(g), Some(mz)) = (self.reported, self.report_time) else {
            return self.shown;
        };
        let mut estimate = g;
        if self.running {
            let dt = (time - mz).clamp(0.0, 1.5);
            estimate = estimate.saturating_add((self.tempo * dt) as i64);
        }
        if self.total > 0 {
            estimate = estimate.min(self.total);
        }
        self.shown = self.shown.max(estimate);
        self.shown
    }
}

/// Where one download's playback progress stands against the server: ONE enum, every move in
/// [`ProgressSync::transition`]. UI: `Unknown` = nothing shown, `Offline` = "will sync" hint,
/// `Synced` = plain, `LocalAhead` = "syncing" (report is due), `ServerAhead` = resume position was
/// updated from the server.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProgressSync {
    /// The server was not asked yet.
    Unknown,
    /// No answer from the server (offline); the local state stays.
    Offline,
    /// Local and server agree (within one second).
    Synced,
    /// Played here after the server's state: this position is to be reported.
    LocalAhead {
        /// Position in ticks (the full length for a watched title).
        ticks: i64,
        /// When it happened, Unix seconds.
        moment: f64,
    },
    /// The server is newer: the download takes its position (see [`DownloadRules::follow`]).
    ServerAhead,
}

/// What can happen to a [`ProgressSync`].
#[derive(Debug, Clone, Copy)]
pub enum SyncEvent<'a> {
    /// The server answered with its watch state (`None`: it never saw the title).
    Answer(Option<&'a UserItemData>),
    /// The server could not be reached.
    NoNetwork,
    /// The pending report of `LocalAhead` got through (or was settled as obsolete).
    Reported,
}

/// An event that does not fit the state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyncRefused;

impl ProgressSync {
    /// Compares a download with the server's state: newer wins, one second of slack, and a title
    /// without a position that is not watched never reports (0 must not wipe a server position).
    pub fn judge(p: &DownloadItem, server: Option<&UserItemData>) -> Self {
        let server_last = server.and_then(UserItemData::last_play);
        let here = p.recent;
        if let Some(here) = here
            && here - server_last.unwrap_or(f64::NEG_INFINITY) > 1.0
        {
            let ticks = if p.watched {
                p.runtime_ticks.filter(|r| *r > 0).or(p.point_ticks)
            } else {
                p.point_ticks.filter(|t| *t > 0)
            };
            return ticks.map_or(Self::Synced, |ticks| Self::LocalAhead {
                ticks,
                moment: here,
            });
        }
        match (server_last, here) {
            (Some(s), h) if s - h.unwrap_or(f64::NEG_INFINITY) > 1.0 => Self::ServerAhead,
            _ => Self::Synced,
        }
    }

    /// The only place a state changes.
    ///
    /// # Errors
    /// [`SyncRefused`] for `Reported` in any state but `LocalAhead`; the state stays.
    pub fn transition(self, p: &DownloadItem, event: SyncEvent<'_>) -> Result<Self, SyncRefused> {
        match (self, event) {
            (_, SyncEvent::NoNetwork) => Ok(match self {
                Self::LocalAhead { .. } => self, // the report stays due
                _ => Self::Offline,
            }),
            (_, SyncEvent::Answer(server)) => Ok(Self::judge(p, server)),
            (Self::LocalAhead { .. }, SyncEvent::Reported) => Ok(Self::Synced),
            (_, SyncEvent::Reported) => Err(SyncRefused),
        }
    }
}
