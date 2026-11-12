//! Plex live helpers for hosts: the play check (state machine over the decision call) and the
//! library-change feed (frame reader + throttle). The socket itself stays with the host.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use swiftly_plex::notifications::{ChangeFeed, FeedAction};
use swiftly_plex::play_check::{PlayCheck, PlayCheckEffect, PlayCheckEvent, reduce};

use crate::error::CoreError;

/// Where the play check stands.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum PlexPlayCheckState {
    Idle,
    Asking,
    /// The server lets the file go out as it is: the refusal was not final, retry the file.
    Allowed,
    /// The server says no; its own words when it gave some.
    Refused {
        reason: Option<String>,
    },
    /// No usable answer.
    Unknown,
}

impl From<PlayCheck> for PlexPlayCheckState {
    fn from(s: PlayCheck) -> Self {
        match s {
            PlayCheck::Idle => Self::Idle,
            PlayCheck::Asking => Self::Asking,
            PlayCheck::Allowed => Self::Allowed,
            PlayCheck::Refused { reason } => Self::Refused { reason },
            PlayCheck::Unknown => Self::Unknown,
        }
    }
}

/// Asks the server; the account's client behind it.
#[async_trait::async_trait]
pub(crate) trait DecisionAsker: Send + Sync {
    async fn ask(&self, rating_key: &str) -> Result<swiftly_plex::PlexDecision, ()>;
}

pub(crate) struct ClientAsker<C>(pub Arc<C>);

#[async_trait::async_trait]
impl<T: swiftly_net::HttpTransport + 'static> DecisionAsker
    for ClientAsker<swiftly_plex::PlexClient<swiftly_vm::Shared<T>>>
{
    async fn ask(&self, rating_key: &str) -> Result<swiftly_plex::PlexDecision, ()> {
        self.0
            .direct_play_decision(rating_key, 0, 0)
            .await
            .map_err(|_| ())
    }
}

/// The Plex play check of one account: feed it the file's HTTP status, get the next state.
#[derive(uniffi::Object)]
pub struct PlexPlayCheckModel {
    asker: Arc<dyn DecisionAsker>,
    state: Mutex<PlayCheck>,
}

impl PlexPlayCheckModel {
    pub(crate) fn new(asker: Arc<dyn DecisionAsker>) -> Arc<Self> {
        Arc::new(Self {
            asker,
            state: Mutex::new(PlayCheck::Idle),
        })
    }

    fn step(&self, event: PlayCheckEvent) -> (PlayCheck, PlayCheckEffect) {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (next, effect) = reduce(guard.clone(), event);
        *guard = next.clone();
        (next, effect)
    }
}

#[uniffi::export]
impl PlexPlayCheckModel {
    /// The current state.
    pub fn state(&self) -> PlexPlayCheckState {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .into()
    }

    /// A new title or a new try.
    pub fn reset(&self) {
        self.step(PlayCheckEvent::Reset);
    }

    /// The file of `rating_key` answered with `status`. Only `500` asks the server (once); the
    /// returned state is the one after the answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn file_refused(
        &self,
        rating_key: String,
        status: u16,
    ) -> Result<PlexPlayCheckState, CoreError> {
        let (_, effect) = self.step(PlayCheckEvent::FileRefused { status });
        if effect == PlayCheckEffect::Ask {
            let event = match self.asker.ask(&rating_key).await {
                Ok(decision) => PlayCheckEvent::Verdict(decision),
                Err(()) => PlayCheckEvent::AskFailed,
            };
            self.step(event);
        }
        Ok(self.state())
    }
}

/// What the host does after a frame.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum PlexFeedAction {
    Nothing,
    Refresh,
    /// Refresh once at this host-clock time (ms); call `fire` then.
    RefreshAt {
        at_ms: u64,
    },
    Absorbed,
}

/// One frame, read.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PlexFeedStep {
    pub changed: Vec<String>,
    pub removed: Vec<String>,
    pub action: PlexFeedAction,
}

/// Library-change feed of a Plex server socket (frames in, refresh decisions out), on a
/// millisecond clock the host reads.
#[derive(uniffi::Object)]
pub struct PlexChangeFeed {
    feed: Mutex<ChangeFeed>,
}

#[uniffi::export]
impl PlexChangeFeed {
    /// A feed whose throttle window is `window_ms` (leading edge plus one trailing refresh).
    #[uniffi::constructor]
    pub fn new(window_ms: u64) -> Arc<Self> {
        Arc::new(Self {
            feed: Mutex::new(ChangeFeed::new(Duration::from_millis(window_ms))),
        })
    }

    /// A text frame arrived at `now_ms`.
    pub fn frame(&self, text: String, now_ms: u64) -> PlexFeedStep {
        let step = self
            .feed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .frame(&text, now_ms);
        PlexFeedStep {
            changed: step.changed,
            removed: step.removed,
            action: match step.action {
                FeedAction::Nothing => PlexFeedAction::Nothing,
                FeedAction::Refresh => PlexFeedAction::Refresh,
                FeedAction::RefreshAt(at_ms) => PlexFeedAction::RefreshAt { at_ms },
                FeedAction::Absorbed => PlexFeedAction::Absorbed,
            },
        }
    }

    /// The scheduled time came: `true` when the trailing refresh is due.
    pub fn fire(&self, now_ms: u64) -> bool {
        self.feed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .fire(now_ms)
    }

    /// The socket broke: the next change refreshes at once.
    pub fn reset(&self) {
        self.feed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Fake(Option<swiftly_plex::PlexDecision>, AtomicUsize);

    #[async_trait::async_trait]
    impl DecisionAsker for Fake {
        async fn ask(&self, _: &str) -> Result<swiftly_plex::PlexDecision, ()> {
            self.1.fetch_add(1, Ordering::SeqCst);
            self.0.clone().ok_or(())
        }
    }

    fn decision(code: i64) -> swiftly_plex::PlexDecision {
        swiftly_plex::PlexDecision {
            general_code: None,
            direct_play_code: Some(code),
            general_text: None,
            direct_play_text: Some("no".into()),
        }
    }

    #[tokio::test]
    async fn only_a_500_asks_and_only_once() {
        let fake = Arc::new(Fake(Some(decision(1000)), AtomicUsize::new(0)));
        let asker: Arc<dyn DecisionAsker> = Arc::<Fake>::clone(&fake);
        let m = PlexPlayCheckModel::new(asker);
        assert_eq!(
            m.file_refused("1".into(), 404).await.unwrap(),
            PlexPlayCheckState::Idle
        );
        assert_eq!(fake.1.load(Ordering::SeqCst), 0);
        assert_eq!(
            m.file_refused("1".into(), 500).await.unwrap(),
            PlexPlayCheckState::Allowed
        );
        assert_eq!(
            m.file_refused("1".into(), 500).await.unwrap(),
            PlexPlayCheckState::Allowed
        );
        assert_eq!(fake.1.load(Ordering::SeqCst), 1);
        m.reset();
        assert_eq!(m.state(), PlexPlayCheckState::Idle);
    }

    #[tokio::test]
    async fn refusal_and_failure_end_in_their_states() {
        let m = PlexPlayCheckModel::new(Arc::new(Fake(Some(decision(2000)), AtomicUsize::new(0))));
        assert_eq!(
            m.file_refused("1".into(), 500).await.unwrap(),
            PlexPlayCheckState::Refused {
                reason: Some("no".into())
            }
        );
        let m = PlexPlayCheckModel::new(Arc::new(Fake(None, AtomicUsize::new(0))));
        assert_eq!(
            m.file_refused("1".into(), 500).await.unwrap(),
            PlexPlayCheckState::Unknown
        );
    }

    #[test]
    fn the_feed_export_follows_the_throttle() {
        let f = PlexChangeFeed::new(1000);
        let frame = r#"{"NotificationContainer":{"type":"timeline","TimelineEntry":[{"identifier":"com.plexapp.plugins.library","itemID":"7","state":5,"type":1}]}}"#;
        assert_eq!(f.frame(frame.into(), 0).action, PlexFeedAction::Refresh);
        assert_eq!(
            f.frame(frame.into(), 10).action,
            PlexFeedAction::RefreshAt { at_ms: 1000 }
        );
        assert!(f.fire(1000));
    }
}
