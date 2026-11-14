//! The smaller rules around the player: the failure screen (`startScrim` in `PlayerScreen.swift`),
//! the track memory seam (`TrackMemory`), the quality choice (`qualitySelection`), the rating
//! and Discord prompts after a finished title (`Community.kickoff`, `RatingQuestion`,
//! `AppModel.doneWatch`) and the replacing of a running player by a remote play order
//! (`PlayRequest.received`, `closeRunning`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use swiftly_library::KeyValue;

/// What the start-failed screen says (`EmptyState` in `startScrim`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    /// Header line.
    pub header: &'static str,
    /// Body text.
    pub text: &'static str,
    /// The main button; sends `PlayerIntent::Retry`.
    pub primary: &'static str,
    /// The quiet button; closes the player.
    pub quiet: &'static str,
}

impl Failure {
    /// The one wording the Swift app uses for every failed start.
    pub const START: Self = Self {
        header: "Das startet nicht",
        text: "Die Datei oder der Server liefert kein Bild. Prüf die Verbindung und versuch es noch einmal.",
        primary: "Erneut versuchen",
        quiet: "Schließen",
    };
}

/// Hint after a quality switch that plays the original anyway.
pub const ORIGINAL_QUALITY_HINT: &str = "Läuft in Originalqualität. Der Server wandelt nichts um.";

/// The quality choice as the layer shows it (`QualitySelection`): Direct Play or a cap in Mbit/s.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Quality {
    /// Always Direct Play.
    pub direct_play: bool,
    /// The cap in Mbit/s while `direct_play` is off.
    pub limit: i64,
}

/// Where the hand-chosen tracks are remembered per series or film (`TrackMemory`, which is
/// `UserDefaults` dictionaries `utJeTitel` and `tonJeTitel` in Swift).
pub trait TrackMemoryStore: Send + Sync {
    /// The whole dictionary under `key` (`SUBTITLE_KEY` or `AUDIO_KEY`).
    fn load(&self, key: &str) -> HashMap<String, String>;
    /// Stores it again.
    fn save(&self, key: &str, all: &HashMap<String, String>);
}

/// What comes up after a finished title (`Community.Trigger`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Nudge {
    /// The store's rating field.
    Rating,
    /// The hint about the Discord.
    Discord,
}

/// From this many finished titles on the rating question is due (`RatingQuestion.threshold`).
pub const RATING_THRESHOLD: i64 = 3;
/// From this share on a title counts as finished (`RatingQuestion.readyShare`).
pub const READY_SHARE: f64 = 0.9;
/// A trailer or short clip is no watched title (`RatingQuestion.minDuration`).
pub const MIN_DURATION: f64 = 60.0;
/// From this many finished titles on the Discord hint is due (`Community.discordThreshold`).
pub const DISCORD_THRESHOLD: i64 = 5;

/// `RatingQuestion.countsAsReady`.
pub fn counts_as_ready(position: f64, duration: f64) -> bool {
    duration >= MIN_DURATION && position / duration >= READY_SHARE
}

/// `Community.kickoff`: at most one thing, the rating first.
pub fn kickoff(
    done: i64,
    rating_last: Option<&str>,
    version: &str,
    discord_shown: bool,
    rating_possible: bool,
) -> Option<Nudge> {
    if rating_possible && done >= RATING_THRESHOLD && rating_last != Some(version) {
        return Some(Nudge::Rating);
    }
    (done >= DISCORD_THRESHOLD && !discord_shown).then_some(Nudge::Discord)
}

const DONE_KEY: &str = "bewertungFertig";
const RATED_KEY: &str = "bewertungFassung";
const DISCORD_KEY: &str = "discordHinweisGezeigt";

/// Counts finished titles on the device and says what is due next (`AppModel.doneWatch`).
pub struct AfterPlay {
    store: Arc<dyn KeyValue>,
    version: String,
    rating_possible: bool,
    /// The host marks a nudge as shown only when it really put it on screen ([`AfterPlay::mark_shown`]), where the
    /// Apple apps mark at once (a crash before the sheet would rather lose the hint than repeat it).
    mark_when_shown: bool,
}

impl AfterPlay {
    /// `rating_possible` is false where the platform has no review prompt (Apple TV, Linux).
    pub fn new(store: Arc<dyn KeyValue>, version: &str, rating_possible: bool) -> Self {
        Self {
            store,
            version: version.to_owned(),
            rating_possible,
            mark_when_shown: false,
        }
    }

    /// Like [`AfterPlay::new`], but a nudge counts as shown only after [`AfterPlay::mark_shown`]: a card that was not put on
    /// screen (another window in front, the app closed) comes again after the next finished title.
    pub fn marking_when_shown(
        store: Arc<dyn KeyValue>,
        version: &str,
        rating_possible: bool,
    ) -> Self {
        Self {
            mark_when_shown: true,
            ..Self::new(store, version, rating_possible)
        }
    }

    /// Records that `nudge` was shown (what `done_watch` does at once when the host marks on its own).
    pub fn mark_shown(&self, nudge: Nudge) {
        match nudge {
            Nudge::Rating => self.store.set(RATED_KEY, &self.version),
            Nudge::Discord => self.store.set(DISCORD_KEY, "true"),
        }
    }

    /// A title ended at `position` of `duration`; the nudge that is due, if any.
    pub fn done_watch(&self, position: f64, duration: f64) -> Option<Nudge> {
        if !counts_as_ready(position, duration) {
            return None;
        }
        let done = self
            .store
            .get(DONE_KEY)
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0)
            + 1;
        self.store.set(DONE_KEY, &done.to_string());
        let last = self.store.get(RATED_KEY);
        let shown = self.store.get(DISCORD_KEY).as_deref() == Some("true");
        let nudge = kickoff(
            done,
            last.as_deref(),
            &self.version,
            shown,
            self.rating_possible,
        );
        // Marked at once: a crash before the sheet would rather lose the hint than repeat it.
        if let Some(n) = nudge.filter(|_| !self.mark_when_shown) {
            self.mark_shown(n);
        }
        nudge
    }
}

/// Which remote play order is the newest (`receivedCount`): an older one that is still waiting
/// drops out when a newer one arrives.
#[derive(Debug, Default)]
pub struct RemoteOrders {
    count: AtomicU64,
}

impl RemoteOrders {
    /// A new order arrived; its ticket.
    pub fn receive(&self) -> u64 {
        self.count.fetch_add(1, Ordering::SeqCst) + 1
    }

    /// No newer order has overtaken this one.
    pub fn is_current(&self, ticket: u64) -> bool {
        self.count.load(Ordering::SeqCst) == ticket
    }
}

/// How long a running player may take to go (`closeRunning`: 50 polls of 100 ms).
pub const CLOSE_WAIT: f64 = 5.0;

/// What `closeRunning` does next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseStep {
    /// Ask again in 100 ms.
    Wait,
    /// The old player is gone; open the new one.
    Gone,
    /// It did not go: drop the order, two players on top of each other are worse.
    GaveUp,
}

/// Replacing a running player: `PlayerIntent::Close` first (its stop is reported like any other),
/// then [`Self::step`] every 100 ms until the old one has unregistered and the presentation is
/// quiet.
#[derive(Debug, Clone, Copy)]
pub struct ReplaceRunning {
    since: f64,
}

impl ReplaceRunning {
    /// Starts waiting at `now`.
    pub fn new(now: f64) -> Self {
        Self { since: now }
    }

    /// `registered`: the old player still listens for remote commands; `quiet`: no screen is
    /// being dismissed or presented.
    pub fn step(&self, now: f64, registered: bool, quiet: bool) -> CloseStep {
        if !registered && quiet {
            CloseStep::Gone
        } else if now - self.since >= CLOSE_WAIT {
            CloseStep::GaveUp
        } else {
            CloseStep::Wait
        }
    }
}

/// An in-memory [`TrackMemoryStore`], for tests and hosts without persistence.
#[derive(Default)]
pub struct MemoryTrackStore(Mutex<HashMap<String, HashMap<String, String>>>);

impl TrackMemoryStore for MemoryTrackStore {
    fn load(&self, key: &str) -> HashMap<String, String> {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(key)
            .cloned()
            .unwrap_or_default()
    }
    fn save(&self, key: &str, all: &HashMap<String, String>) {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.to_owned(), all.clone());
    }
}
