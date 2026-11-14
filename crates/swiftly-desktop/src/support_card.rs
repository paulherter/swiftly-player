//! The support card at the end of Start (`MacSupportCard`, shown when `SupportModel.cardVisible`): the rules, the stored
//! records and the copy are the core's (`swiftly-support`); this holds the desktop's state around them.
//!
//! Launch time and watched seconds live in the settings file under the core's keys, so they survive a restart.
//! "Unterstützen" opens the supporter web page (no in-app purchase on Windows and Linux), "Nicht jetzt" hides the card
//! for 30 days (`SupportPromptHistory.snooze_card`).

use std::sync::Arc;
use swiftly_settings::{JsonFileStore, KeyValueStore, StoreError, Value};
use swiftly_support::support::{
    PromptContext, SupportPlatform, SupportPrompt, SupportStore, WatchTimeCounter, WatchTimeFeed,
};
use swiftly_support::time::{Calendar, Timestamp};

/// The page "Unterstützen" opens.
pub const SUPPORTER_PAGE: &str = "https://swiftlyplayer.com/supporter";

/// The settings file as the core's store.
#[derive(Clone)]
pub struct Shared(pub Arc<JsonFileStore>);

impl KeyValueStore for Shared {
    fn get(&self, key: &str) -> Option<Value> {
        self.0.get(key)
    }
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
        self.0.set(key, value)
    }
    fn remove(&self, key: &str) -> Result<(), StoreError> {
        self.0.remove(key)
    }
    fn keys(&self) -> Vec<String> {
        self.0.keys()
    }
}

/// Where the card stands: the stored records and the playback counter.
pub struct SupportCard {
    store: SupportStore<Shared>,
    counter: WatchTimeCounter,
    /// The clock reading (seconds) the app started at.
    launched: Timestamp,
}

impl SupportCard {
    /// Opens the records and notes this start (the first one is remembered as the first launch).
    pub fn new(settings: Arc<JsonFileStore>, now: Timestamp) -> SupportCard {
        let store = SupportStore::new(Shared(settings));
        let _ = store.record_launch(now);
        let counter = WatchTimeCounter::new(store.usage().watched_seconds);
        SupportCard {
            store,
            counter,
            launched: now,
        }
    }

    /// The platform the rules know this build as. The desktop has no support sheet (there is no in-app purchase here,
    /// the card and the settings row open the supporter web page), so it asks like Apple TV: the card, never the sheet.
    /// Rules for a sheet that does not exist would only hide the card after the seventh day.
    fn platform() -> SupportPlatform {
        SupportPlatform::AppleTv
    }

    /// The watched hours when the card is due now (`None`: no card). Never while a video plays, never in the first
    /// minute, only after two hours watched and three days of use, never for supporters.
    pub fn due(&self, playing: bool, now: Timestamp) -> Option<i64> {
        let history = self.store.prompt_history();
        let usage = self.store.usage();
        let context = PromptContext {
            now,
            status: self.store.status(),
            usage,
            history: &history,
            is_playing: playing,
            seconds_since_launch: now - self.launched,
            platform: Self::platform(),
        };
        SupportPrompt::decide(&context, Calendar::UTC)
            .shows_card
            .then(|| self.counter.watched_hours())
    }

    /// "Nicht jetzt": hides the card for 30 days.
    pub fn snooze(&self, now: Timestamp) {
        let mut history = self.store.prompt_history();
        history.snooze_card(now);
        let _ = self.store.set_prompt_history(&history);
    }

    /// One observation of the player (call while it is open).
    pub fn feed(&mut self, playing: bool, now: Timestamp) {
        self.counter.playback_progress(playing, now);
        if self.counter.needs_save() {
            let _ = self.store.save(&mut self.counter);
        }
    }

    /// The player closed: the time counted so far is stored.
    pub fn stopped(&mut self, now: Timestamp) {
        self.counter.playback_stopped(now);
        let _ = self.store.save(&mut self.counter);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_support::time::DAY;

    fn card(dir: &std::path::Path, now: f64) -> SupportCard {
        SupportCard::new(
            Arc::new(JsonFileStore::open(dir.join("s.json")).expect("store")),
            now,
        )
    }

    fn watch(c: &mut SupportCard, seconds: f64, from: f64) {
        let mut t = from;
        while t < from + seconds {
            c.feed(true, t);
            t += 5.0;
        }
        c.stopped(t);
    }

    #[test]
    fn the_card_waits_for_two_hours_three_days_and_a_quiet_minute() {
        let dir = std::env::temp_dir().join(format!("support-card-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let t0 = 1_800_000_000.0;
        let mut c = card(&dir, t0);
        // Day 4, but nothing watched: no card.
        assert_eq!(c.due(false, t0 + 4.0 * DAY), None);
        watch(&mut c, 2.0 * 3_600.0 + 60.0, t0 + 100.0);
        // Watched enough, three days not over yet.
        assert_eq!(c.due(false, t0 + 2.0 * DAY), None);
        // Day 4, quiet: the card, naming 2 hours; not while a video plays.
        assert_eq!(c.due(false, t0 + 4.0 * DAY), Some(2));
        assert_eq!(c.due(true, t0 + 4.0 * DAY), None);
        // "Nicht jetzt": gone for 30 days.
        c.snooze(t0 + 4.0 * DAY);
        assert_eq!(c.due(false, t0 + 5.0 * DAY), None);
        assert_eq!(c.due(false, t0 + 40.0 * DAY), Some(2));
        // Hours survive a restart; the first launch stays the first.
        let again = card(&dir, t0 + 50.0 * DAY);
        assert_eq!(again.due(false, t0 + 50.0 * DAY + 120.0), Some(2));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
