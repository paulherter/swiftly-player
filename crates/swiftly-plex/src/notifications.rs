//! **Plex notifications over a WebSocket** (`/:/websockets/notifications`), sans-IO.
//!
//! The Swift app does not listen to them. They tell a host when the library changed (a scan
//! found or removed a title) so rails can refresh without polling. This module holds the
//! address, the frame reader and the throttle; the socket itself is the host's, like the
//! Jellyfin `/socket` (`swiftly-uniffi` `WebSocketLink`).
//!
//! Measured shape (research 13): one scan of a single new movie sends about 150 frames, mostly
//! `activity` and `progress`. Only `timeline` entries of the library identifier whose `state`
//! is 5 (settled) count; a deleted title arrives with `type` -1. The server replays nothing, so
//! after a reconnect the host re-reads what its screens show.

use std::time::{Duration, Instant};

use serde_json::Value;
use url::Url;

use crate::loose;

/// The identifier of library timeline entries.
pub const LIBRARY_IDENTIFIER: &str = "com.plexapp.plugins.library";

/// The `state` of a settled timeline entry (the title is complete in the library).
pub const SETTLED_STATE: i64 = 5;

/// One change of the library a frame announces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlexChange {
    /// A title was added or updated; the key is the `itemID` (the rating key).
    Changed(String),
    /// A title was removed.
    Removed(String),
}

impl PlexChange {
    /// The rating key the change is about.
    pub fn item_id(&self) -> &str {
        match self {
            Self::Changed(id) | Self::Removed(id) => id,
        }
    }
}

/// The socket address of a server address and token: `ws`/`wss`, the notifications path, the
/// token in the query (a socket cannot carry headers everywhere).
pub fn socket_url(base: &Url, token: &str) -> Option<Url> {
    let mut url = base.clone();
    url.set_scheme(if base.scheme() == "https" {
        "wss"
    } else {
        "ws"
    })
    .ok()?;
    url.set_path("/:/websockets/notifications");
    url.set_query(None);
    if !token.is_empty() {
        url.query_pairs_mut().append_pair("X-Plex-Token", token);
    }
    Some(url)
}

/// Reads one text frame. Frames that are not `timeline`, entries of other identifiers and
/// entries that are not settled give nothing; a frame that is not JSON gives nothing too.
pub fn parse_frame(text: &str) -> Vec<PlexChange> {
    let Ok(root) = serde_json::from_str::<Value>(text) else {
        return Vec::new();
    };
    let Some(container) = root.get("NotificationContainer") else {
        return Vec::new();
    };
    if loose::string(container, "type").as_deref() != Some("timeline") {
        return Vec::new();
    }
    let Some(entries) = container.get("TimelineEntry").and_then(Value::as_array) else {
        return Vec::new();
    };
    entries
        .iter()
        .filter(|e| {
            loose::string(e, "identifier").is_none_or(|identifier| identifier == LIBRARY_IDENTIFIER)
        })
        .filter_map(|e| {
            let id = loose::string(e, "itemID").filter(|id| !id.is_empty())?;
            if loose::int(e, "type") == Some(-1) {
                return Some(PlexChange::Removed(id));
            }
            (loose::int(e, "state") == Some(SETTLED_STATE)).then_some(PlexChange::Changed(id))
        })
        .collect()
}

/// What to do with a change that arrived.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThrottleAction {
    /// Refresh now.
    Emit,
    /// Refresh once at this time (the end of the window); call [`ChangeThrottle::fire`] then.
    Schedule(Instant),
    /// A refresh is already scheduled for this window.
    Absorbed,
}

/// Leading-edge throttle: the first change of a quiet period refreshes at once, the rest of
/// the window collapses into one trailing refresh.
#[derive(Debug, Clone)]
pub struct ChangeThrottle {
    window: Duration,
    last: Option<Instant>,
    pending: bool,
}

impl ChangeThrottle {
    /// A throttle with this window.
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            last: None,
            pending: false,
        }
    }

    /// A change arrived at `now`.
    pub fn offer(&mut self, now: Instant) -> ThrottleAction {
        match self.last {
            Some(last) if now.saturating_duration_since(last) < self.window => {
                if self.pending {
                    ThrottleAction::Absorbed
                } else {
                    self.pending = true;
                    ThrottleAction::Schedule(last + self.window)
                }
            }
            _ => {
                self.last = Some(now);
                self.pending = false;
                ThrottleAction::Emit
            }
        }
    }

    /// The scheduled time came: `true` when the trailing refresh is due now.
    pub fn fire(&mut self, now: Instant) -> bool {
        let due = self
            .last
            .is_some_and(|last| now.saturating_duration_since(last) >= self.window);
        if self.pending && due {
            self.pending = false;
            self.last = Some(now);
            return true;
        }
        false
    }

    /// The link broke: nothing was replayed, so the next change (or the reconnect itself) must
    /// refresh at once, and a scheduled trailing refresh is dropped.
    pub fn reset(&mut self) {
        self.last = None;
        self.pending = false;
    }
}

/// What a frame asks of the host, on a clock the host reads (milliseconds from any fixed start).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FeedAction {
    /// The frame announced nothing the library cares about.
    Nothing,
    /// Refresh now.
    Refresh,
    /// Refresh once at this time (ms); call [`ChangeFeed::fire`] then.
    RefreshAt(u64),
    /// A refresh is already scheduled for this window.
    Absorbed,
}

/// One text frame, read and throttled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedStep {
    /// Rating keys added or updated.
    pub changed: Vec<String>,
    /// Rating keys removed.
    pub removed: Vec<String>,
    /// What to do about it.
    pub action: FeedAction,
}

/// Frame reader plus [`ChangeThrottle`] on a millisecond clock owned by the host, so a host that
/// owns the socket needs no `Instant`.
#[derive(Debug, Clone)]
pub struct ChangeFeed {
    base: Instant,
    throttle: ChangeThrottle,
}

impl ChangeFeed {
    /// A feed with this throttle window.
    pub fn new(window: Duration) -> Self {
        Self {
            base: Instant::now(),
            throttle: ChangeThrottle::new(window),
        }
    }

    fn at(&self, ms: u64) -> Instant {
        self.base + Duration::from_millis(ms)
    }

    /// A text frame arrived at `now_ms`.
    pub fn frame(&mut self, text: &str, now_ms: u64) -> FeedStep {
        let changes = parse_frame(text);
        let (mut changed, mut removed) = (Vec::new(), Vec::new());
        for c in changes {
            match c {
                PlexChange::Changed(id) => changed.push(id),
                PlexChange::Removed(id) => removed.push(id),
            }
        }
        if changed.is_empty() && removed.is_empty() {
            return FeedStep {
                changed,
                removed,
                action: FeedAction::Nothing,
            };
        }
        let action = match self.throttle.offer(self.at(now_ms)) {
            ThrottleAction::Emit => FeedAction::Refresh,
            ThrottleAction::Schedule(t) => {
                FeedAction::RefreshAt(t.saturating_duration_since(self.base).as_millis() as u64)
            }
            ThrottleAction::Absorbed => FeedAction::Absorbed,
        };
        FeedStep {
            changed,
            removed,
            action,
        }
    }

    /// The scheduled time came: `true` when the trailing refresh is due.
    pub fn fire(&mut self, now_ms: u64) -> bool {
        self.throttle.fire(self.at(now_ms))
    }

    /// The link broke.
    pub fn reset(&mut self) {
        self.throttle.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_address() {
        let base = Url::parse("https://192-168-1-2.abc.plex.direct:32400/").expect("url");
        let url = socket_url(&base, "tok en").expect("socket");
        assert_eq!(url.scheme(), "wss");
        assert_eq!(url.path(), "/:/websockets/notifications");
        assert_eq!(url.query(), Some("X-Plex-Token=tok+en"));
        let plain = socket_url(&Url::parse("http://nas:32400").expect("url"), "").expect("socket");
        assert_eq!(plain.as_str(), "ws://nas:32400/:/websockets/notifications");
    }

    #[test]
    fn only_settled_library_entries_count() {
        let frame = r#"{"NotificationContainer":{"type":"timeline","size":3,"TimelineEntry":[
            {"identifier":"com.plexapp.plugins.library","itemID":"10","type":1,"state":5},
            {"identifier":"com.plexapp.plugins.library","itemID":"11","type":1,"state":0},
            {"identifier":"com.plexapp.plugins.library","itemID":"12","type":-1,"state":9},
            {"identifier":"tv.plex.provider.discover","itemID":"13","type":1,"state":5}]}}"#;
        assert_eq!(
            parse_frame(frame),
            vec![
                PlexChange::Changed("10".into()),
                PlexChange::Removed("12".into())
            ]
        );
    }

    #[test]
    fn other_frames_and_noise_give_nothing() {
        assert!(parse_frame(r#"{"NotificationContainer":{"type":"activity"}}"#).is_empty());
        assert!(
            parse_frame(r#"{"NotificationContainer":{"type":"progress","size":1}}"#).is_empty()
        );
        assert!(parse_frame("not json").is_empty());
        assert!(parse_frame("{}").is_empty());
    }

    #[test]
    fn numeric_item_id_is_read() {
        let frame = r#"{"NotificationContainer":{"type":"timeline","TimelineEntry":[
            {"itemID":77,"type":1,"state":5}]}}"#;
        assert_eq!(parse_frame(frame)[0].item_id(), "77");
    }

    #[test]
    fn throttle_leads_then_coalesces() {
        let t0 = Instant::now();
        let w = Duration::from_secs(2);
        let mut th = ChangeThrottle::new(w);
        assert_eq!(th.offer(t0), ThrottleAction::Emit);
        assert_eq!(
            th.offer(t0 + Duration::from_millis(100)),
            ThrottleAction::Schedule(t0 + w)
        );
        assert_eq!(
            th.offer(t0 + Duration::from_millis(900)),
            ThrottleAction::Absorbed
        );
        assert!(!th.fire(t0 + Duration::from_secs(1)));
        assert!(th.fire(t0 + w));
        // The trailing refresh opened a new window.
        assert_eq!(
            th.offer(t0 + w + Duration::from_millis(10)),
            ThrottleAction::Schedule(t0 + w + w)
        );
        assert_eq!(th.offer(t0 + Duration::from_secs(10)), ThrottleAction::Emit);
        assert!(!th.fire(t0 + Duration::from_secs(20)));
    }

    #[test]
    fn reset_makes_the_next_change_immediate() {
        let t0 = Instant::now();
        let mut th = ChangeThrottle::new(Duration::from_secs(2));
        assert_eq!(th.offer(t0), ThrottleAction::Emit);
        th.reset();
        assert_eq!(
            th.offer(t0 + Duration::from_millis(1)),
            ThrottleAction::Emit
        );
    }

    #[test]
    fn feed_reads_and_throttles_on_a_millisecond_clock() {
        let frame = r#"{"NotificationContainer":{"type":"timeline","TimelineEntry":[{"identifier":"com.plexapp.plugins.library","itemID":"42","state":5,"type":1}]}}"#;
        let mut feed = ChangeFeed::new(Duration::from_millis(1000));
        let a = feed.frame(frame, 0);
        assert_eq!(
            (a.changed.as_slice(), a.action),
            (&["42".to_string()][..], FeedAction::Refresh)
        );
        assert_eq!(feed.frame(frame, 300).action, FeedAction::RefreshAt(1000));
        assert_eq!(feed.frame(frame, 400).action, FeedAction::Absorbed);
        assert!(!feed.fire(900));
        assert!(feed.fire(1000));
        assert_eq!(feed.frame("{}", 1100).action, FeedAction::Nothing);
        feed.reset();
        assert_eq!(feed.frame(frame, 1200).action, FeedAction::Refresh);
    }
}
