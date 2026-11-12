//! Support rules: status, usage, prompt history, plan, the watch-time feed and the pure
//! "when to ask" decision (`SupportStatus.swift`, `SupportPrompt.swift`). The JSON shapes are
//! byte-compatible with Swift's sorted-key `JSONEncoder` with `.secondsSince1970` dates.

use serde::{Deserialize, Serialize};
use swiftly_settings::{KeyValueStore, StoreError, Value};

use crate::time::{Calendar, DAY, Timestamp, opt_secs, secs, secs_list};

/// Where the status came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// A tip bought through the App Store or Google Play.
    Store,
    /// A supporter key from the website, verified offline.
    Key,
}

impl Source {
    /// Every source.
    pub const ALL: [Source; 2] = [Source::Store, Source::Key];
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Kind {
    None,
    Supporter,
}

#[derive(Serialize, Deserialize)]
struct StatusWire {
    kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_secs")]
    since: Option<Timestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source: Option<Source>,
}

/// Whether this device belongs to a supporter, and how it became one. Stored locally only.
/// JSON: `{"kind":"none"}` or `{"kind":"supporter","since":<secs>,"source":"store"|"key"}`.
#[derive(Clone, Copy, Debug, PartialEq, Default, Serialize, Deserialize)]
#[serde(try_from = "StatusWire", into = "StatusWire")]
pub enum SupportStatus {
    /// Not a supporter.
    #[default]
    None,
    /// A supporter; `since` is when this device learned about it.
    Supporter {
        /// Where it came from.
        source: Source,
        /// Purchase date or key issue day; `None` when unknown.
        since: Option<Timestamp>,
    },
}

impl TryFrom<StatusWire> for SupportStatus {
    type Error = String;
    fn try_from(w: StatusWire) -> Result<Self, String> {
        match w.kind {
            Kind::None => Ok(Self::None),
            Kind::Supporter => match w.source {
                Some(source) => Ok(Self::Supporter {
                    source,
                    since: w.since,
                }),
                None => Err("supporter without a source".to_owned()),
            },
        }
    }
}

impl From<SupportStatus> for StatusWire {
    fn from(s: SupportStatus) -> Self {
        match s {
            SupportStatus::None => StatusWire {
                kind: Kind::None,
                since: None,
                source: None,
            },
            SupportStatus::Supporter { source, since } => StatusWire {
                kind: Kind::Supporter,
                since,
                source: Some(source),
            },
        }
    }
}

impl SupportStatus {
    /// Whether this is a supporter.
    pub fn is_supporter(&self) -> bool {
        matches!(self, Self::Supporter { .. })
    }
}

/// Local usage numbers the support prompt decides on. Never sent anywhere.
#[derive(Clone, Copy, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct SupportUsage {
    /// First start of the app on this device.
    #[serde(
        rename = "firstLaunch",
        default,
        skip_serializing_if = "Option::is_none",
        with = "opt_secs"
    )]
    pub first_launch: Option<Timestamp>,
    /// Seconds of actual playback.
    #[serde(rename = "watchedSeconds", with = "secs")]
    pub watched_seconds: f64,
}

/// What the person already answered to the card and the sheet.
#[derive(Clone, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct SupportPromptHistory {
    /// "Don't show again", or the second "Not now": the card never comes back.
    #[serde(rename = "cardDismissed", default)]
    pub card_dismissed: bool,
    /// "Not now" on the card: hidden until this moment.
    #[serde(
        rename = "cardSnoozedUntil",
        default,
        skip_serializing_if = "Option::is_none",
        with = "opt_secs"
    )]
    pub card_snoozed_until: Option<Timestamp>,
    /// How often "Not now" was pressed. Older histories have none.
    #[serde(rename = "cardSnoozes", default)]
    pub card_snoozes: i64,
    /// Every time the sheet appeared, newest last.
    #[serde(rename = "sheetShownAt", default, with = "secs_list")]
    pub sheet_shown_at: Vec<Timestamp>,
}

impl SupportPromptHistory {
    /// Older entries do not matter for any rule (the yearly limit looks at one year).
    pub const KEPT_SHEET_DATES: usize = 12;
    /// After this many "Not now" the card stays away for good.
    pub const SNOOZES_UNTIL_GONE: i64 = 2;

    /// "Not now" on the card: 30 days; the second time it does not come back.
    pub fn snooze_card(&mut self, now: Timestamp) {
        self.card_snoozed_until = Some(now + SupportPrompt::CARD_SNOOZE);
        self.card_snoozes += 1;
        if self.card_snoozes >= Self::SNOOZES_UNTIL_GONE {
            self.card_dismissed = true;
        }
    }

    /// "Don't show again" on the card.
    pub fn dismiss_card(&mut self) {
        self.card_dismissed = true;
    }

    /// Call when the sheet appears, before any answer. "Maybe later" counts as shown.
    pub fn record_sheet_shown(&mut self, now: Timestamp) {
        self.sheet_shown_at.push(now);
        if self.sheet_shown_at.len() > Self::KEPT_SHEET_DATES {
            let extra = self.sheet_shown_at.len() - Self::KEPT_SHEET_DATES;
            self.sheet_shown_at.drain(..extra);
        }
    }
}

/// What kind of support a supporter chose; stored as its raw word.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SupportPlan {
    /// Auto-renewable subscription.
    Monthly,
    /// Bought once.
    Lifetime,
    /// A tip.
    Tip,
}

impl SupportPlan {
    /// Every plan.
    pub const ALL: [SupportPlan; 3] = [Self::Monthly, Self::Lifetime, Self::Tip];

    /// The stored word.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Monthly => "monthly",
            Self::Lifetime => "lifetime",
            Self::Tip => "tip",
        }
    }

    /// From the stored word.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.raw() == raw)
    }
}

/// The fixed storage keys (`SupportStorageKey`). Changing one loses what devices have stored.
pub mod storage_key {
    /// The status record.
    pub const STATUS: &str = "support.status";
    /// The usage record.
    pub const USAGE: &str = "support.usage";
    /// The prompt history record.
    pub const PROMPT_HISTORY: &str = "support.promptHistory";
    /// The three records.
    pub const ALL: [&str; 3] = [STATUS, USAGE, PROMPT_HISTORY];
    /// What kind of support it was. Added later, hence not in `ALL`.
    pub const PLAN: &str = "support.plan";
}

/// Typed access to the records over a [`KeyValueStore`]. A record that is missing or
/// unreadable reads as its empty value; nothing here fails because of a damaged record.
pub struct SupportStore<S: KeyValueStore> {
    store: S,
}

impl<S: KeyValueStore> SupportStore<S> {
    /// Wraps a store.
    pub fn new(store: S) -> Self {
        Self { store }
    }

    /// The store underneath.
    pub fn store(&self) -> &S {
        &self.store
    }

    fn bytes(&self, key: &str) -> Option<Vec<u8>> {
        match self.store.get(key)? {
            Value::Data(d) => Some(d),
            Value::Str(s) => Some(s.into_bytes()),
            _ => None,
        }
    }

    fn read<T: serde::de::DeserializeOwned>(&self, key: &str) -> Option<T> {
        serde_json::from_slice(&self.bytes(key)?).ok()
    }

    fn write<T: Serialize>(&self, key: &str, value: &T) -> Result<(), StoreError> {
        match serde_json::to_vec(value) {
            Ok(bytes) => self.store.set(key, Value::Data(bytes)),
            Err(_) => self.store.remove(key),
        }
    }

    /// The status; `None` status when missing or damaged.
    pub fn status(&self) -> SupportStatus {
        self.read(storage_key::STATUS).unwrap_or_default()
    }
    /// Stores the status.
    pub fn set_status(&self, status: SupportStatus) -> Result<(), StoreError> {
        self.write(storage_key::STATUS, &status)
    }
    /// The usage.
    pub fn usage(&self) -> SupportUsage {
        self.read(storage_key::USAGE).unwrap_or_default()
    }
    /// Stores the usage.
    pub fn set_usage(&self, usage: SupportUsage) -> Result<(), StoreError> {
        self.write(storage_key::USAGE, &usage)
    }
    /// The prompt history.
    pub fn prompt_history(&self) -> SupportPromptHistory {
        self.read(storage_key::PROMPT_HISTORY).unwrap_or_default()
    }
    /// Stores the prompt history.
    pub fn set_prompt_history(&self, history: &SupportPromptHistory) -> Result<(), StoreError> {
        self.write(storage_key::PROMPT_HISTORY, history)
    }

    /// `None` when unknown: a status from before plans existed, or from a supporter key.
    pub fn plan(&self) -> Option<SupportPlan> {
        let raw = String::from_utf8(self.bytes(storage_key::PLAN)?).ok()?;
        SupportPlan::from_raw(&raw)
    }
    /// Stores the plan as its raw word in a data record; `None` removes it.
    pub fn set_plan(&self, plan: Option<SupportPlan>) -> Result<(), StoreError> {
        match plan {
            Some(p) => self
                .store
                .set(storage_key::PLAN, Value::Data(p.raw().as_bytes().to_vec())),
            None => self.store.remove(storage_key::PLAN),
        }
    }

    /// Call once per app start. Records the first launch only the first time.
    pub fn record_launch(&self, now: Timestamp) -> Result<(), StoreError> {
        let mut usage = self.usage();
        if usage.first_launch.is_some() {
            return Ok(());
        }
        usage.first_launch = Some(now);
        self.set_usage(usage)
    }

    /// Stores the counter's total and marks it saved.
    pub fn save(&self, counter: &mut WatchTimeCounter) -> Result<(), StoreError> {
        let mut usage = self.usage();
        usage.watched_seconds = counter.total_seconds();
        self.set_usage(usage)?;
        counter.mark_saved();
        Ok(())
    }
}

/// Where the app runs, as far as the support prompt cares.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SupportPlatform {
    /// iPhone.
    #[serde(rename = "iPhone")]
    IPhone,
    /// iPad.
    #[serde(rename = "iPad")]
    IPad,
    /// Mac.
    #[serde(rename = "mac")]
    Mac,
    /// Apple TV.
    #[serde(rename = "appleTV")]
    AppleTv,
    /// Android.
    #[serde(rename = "android")]
    Android,
    /// Android TV.
    #[serde(rename = "androidTV")]
    AndroidTv,
    /// Linux.
    #[serde(rename = "linux")]
    Linux,
    /// Windows.
    #[serde(rename = "windows")]
    Windows,
}

impl SupportPlatform {
    /// Every platform.
    pub const ALL: [SupportPlatform; 8] = [
        Self::IPhone,
        Self::IPad,
        Self::Mac,
        Self::AppleTv,
        Self::Android,
        Self::AndroidTv,
        Self::Linux,
        Self::Windows,
    ];

    /// Apple TV gets the heart and the card, never the sheet.
    pub fn allows_sheet(self) -> bool {
        self != Self::AppleTv
    }
}

/// When to ask for support: one pure decision, the same on every platform.
pub struct SupportPrompt;

/// Everything the decision looks at. `now` is the injected clock.
#[derive(Clone, Copy, Debug)]
pub struct PromptContext<'a> {
    /// The clock.
    pub now: Timestamp,
    /// The status.
    pub status: SupportStatus,
    /// The usage.
    pub usage: SupportUsage,
    /// The history.
    pub history: &'a SupportPromptHistory,
    /// Playback is running.
    pub is_playing: bool,
    /// Seconds since the app started.
    pub seconds_since_launch: f64,
    /// The platform.
    pub platform: SupportPlatform,
}

/// The decision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Decision {
    /// The "Support Swiftly" entry in Settings and About. Always true.
    pub shows_heart: bool,
    /// The card at the end of the home page.
    pub shows_card: bool,
    /// The one-time thank-you sheet.
    pub shows_sheet: bool,
}

impl SupportPrompt {
    /// Two hours watched, in seconds.
    pub const MINIMUM_WATCHED_SECONDS: f64 = 2.0 * 3_600.0;
    /// No ask in the first minute after launch.
    pub const QUIET_AFTER_LAUNCH: f64 = 60.0;
    /// The card from 3 days after the first launch.
    pub const CARD_DELAY: f64 = 3.0 * DAY;
    /// "Not now" hides the card for 30 days.
    pub const CARD_SNOOZE: f64 = 30.0 * DAY;
    /// The sheet from 7 days after the first launch.
    pub const SHEET_DELAY: f64 = 7.0 * DAY;
    /// At most every 90 days.
    pub const SHEET_SPACING: f64 = 90.0 * DAY;
    /// At most this many times per calendar year.
    pub const SHEETS_PER_YEAR: usize = 3;

    /// The decision; `calendar` decides what "calendar year" means.
    pub fn decide(context: &PromptContext<'_>, calendar: Calendar) -> Decision {
        let sheet = Self::sheet_is_due(context, calendar);
        Decision {
            shows_heart: true,
            shows_card: !sheet && Self::card_is_due(context),
            shows_sheet: sheet,
        }
    }

    fn may_ask(context: &PromptContext<'_>, delay: f64) -> bool {
        if context.status.is_supporter()
            || context.is_playing
            || context.seconds_since_launch < Self::QUIET_AFTER_LAUNCH
            || context.usage.watched_seconds < Self::MINIMUM_WATCHED_SECONDS
        {
            return false;
        }
        match context.usage.first_launch {
            Some(first) => context.now - first >= delay,
            None => false,
        }
    }

    fn card_is_due(context: &PromptContext<'_>) -> bool {
        if !Self::may_ask(context, Self::CARD_DELAY) || context.history.card_dismissed {
            return false;
        }
        !matches!(context.history.card_snoozed_until, Some(until) if context.now < until)
    }

    fn sheet_is_due(context: &PromptContext<'_>, calendar: Calendar) -> bool {
        if !context.platform.allows_sheet() || !Self::may_ask(context, Self::SHEET_DELAY) {
            return false;
        }
        let shown = &context.history.sheet_shown_at;
        if let Some(last) = shown.iter().copied().reduce(f64::max)
            && context.now - last < Self::SHEET_SPACING
        {
            return false;
        }
        let year = calendar.year(context.now);
        shown.iter().filter(|t| calendar.year(**t) == year).count() < Self::SHEETS_PER_YEAR
    }
}

/// Sums the seconds that were actually played. Local only, never sent. A gap longer than
/// [`WatchTimeCounter::MAXIMUM_GAP`] or a clock that went backwards counts nothing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WatchTimeCounter {
    total_seconds: f64,
    unsaved_seconds: f64,
    playing_since: Option<Timestamp>,
}

/// What the apps feed with playback progress.
pub trait WatchTimeFeed {
    /// One observation: is the video playing right now?
    fn playback_progress(&mut self, is_playing: bool, at: Timestamp);
    /// Playback ended, the player closed, or the app went to the background.
    fn playback_stopped(&mut self, at: Timestamp);
}

impl WatchTimeCounter {
    /// Progress arrives every 0.5 to 10 seconds; anything much longer is not watching.
    pub const MAXIMUM_GAP: f64 = 30.0;
    /// How much unsaved time is worth one write to storage.
    pub const SAVE_EVERY: f64 = 60.0;

    /// A counter that continues from a stored total.
    pub fn new(total_seconds: f64) -> Self {
        Self {
            total_seconds: total_seconds.max(0.0),
            unsaved_seconds: 0.0,
            playing_since: None,
        }
    }

    /// Seconds played so far.
    pub fn total_seconds(&self) -> f64 {
        self.total_seconds
    }

    /// Whole hours, for "You have watched 25 hours with Swiftly."
    pub fn watched_hours(&self) -> i64 {
        (self.total_seconds / 3_600.0).min(f64::from(i32::MAX)) as i64
    }

    /// Seconds counted since the last store.
    pub fn unsaved_seconds(&self) -> f64 {
        self.unsaved_seconds
    }

    /// True once enough time has piled up to store it.
    pub fn needs_save(&self) -> bool {
        self.unsaved_seconds >= Self::SAVE_EVERY
    }

    /// Marks the total as stored.
    pub fn mark_saved(&mut self) {
        self.unsaved_seconds = 0.0;
    }

    fn count_until(&mut self, now: Timestamp) {
        let Some(since) = self.playing_since else {
            return;
        };
        let gap = now - since;
        if gap > 0.0 && gap <= Self::MAXIMUM_GAP {
            self.total_seconds += gap;
            self.unsaved_seconds += gap;
        }
    }
}

impl Default for WatchTimeCounter {
    fn default() -> Self {
        Self::new(0.0)
    }
}

impl WatchTimeFeed for WatchTimeCounter {
    fn playback_progress(&mut self, is_playing: bool, at: Timestamp) {
        self.count_until(at);
        self.playing_since = if is_playing { Some(at) } else { None };
    }

    fn playback_stopped(&mut self, at: Timestamp) {
        self.count_until(at);
        self.playing_since = None;
    }
}
