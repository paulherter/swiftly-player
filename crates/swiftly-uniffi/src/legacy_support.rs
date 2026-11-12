//! The support and what's-new calls of the old Android facade (`Kern.support*`, `Kern.whatsNew*`,
//! `Android/core/.../Support.swift`) from the core, with the same JSON answers. Stateless: Kotlin keeps the three
//! records as strings and hands them in. Each answer is compared with the Swift one by the golden tests (`su-*`).
//! The supporter-key status only exists with feature `supporter-key` (direct build); the Play build has no symbol.

use serde_json::json;
use swiftly_l10n::whats_new::{WhatsNewDecision, WhatsNewEntry, decide};
use swiftly_settings::{KeyValueStore, MemoryStore, Value};
use swiftly_support::support::{
    PromptContext, Source, SupportPlatform, SupportPrompt, SupportStatus, SupportStore,
    WatchTimeCounter, storage_key,
};
use swiftly_support::{Calendar, SupportTip};

fn secs(ms: i64) -> f64 {
    ms as f64 / 1000.0
}

/// A store over the three record strings, an empty string meaning "not stored".
fn store(status: &str, usage: &str, history: &str) -> SupportStore<MemoryStore> {
    let m = MemoryStore::new();
    for (text, key) in [
        (status, storage_key::STATUS),
        (usage, storage_key::USAGE),
        (history, storage_key::PROMPT_HISTORY),
    ] {
        if !text.is_empty() {
            let _ = m.set(key, Value::Data(text.as_bytes().to_vec()));
        }
    }
    SupportStore::new(m)
}

fn text(s: &SupportStore<MemoryStore>, key: &str) -> String {
    match s.store().get(key) {
        Some(Value::Data(d)) => String::from_utf8_lossy(&d).into_owned(),
        Some(Value::Str(t)) => t,
        _ => String::new(),
    }
}

/// `Kern.supportRecordLaunch`: the first start, once. Returns the usage record.
#[uniffi::export]
pub fn legacy_support_record_launch(usage: String, now_ms: i64) -> String {
    let s = store("", &usage, "");
    let _ = s.record_launch(secs(now_ms));
    text(&s, storage_key::USAGE)
}

/// `Kern.supportDecide`: `{"showsHeart","showsCard","showsSheet","watchedHours","isSupporter"}`.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn legacy_support_decide(
    status: String,
    usage: String,
    history: String,
    is_playing: bool,
    seconds_since_launch: f64,
    tv: bool,
    now_ms: i64,
    utc_offset: i64,
) -> String {
    let s = store(&status, &usage, &history);
    let (st, us, hi) = (s.status(), s.usage(), s.prompt_history());
    let context = PromptContext {
        now: secs(now_ms),
        status: st,
        usage: us,
        history: &hi,
        is_playing,
        seconds_since_launch,
        platform: if tv {
            SupportPlatform::AndroidTv
        } else {
            SupportPlatform::Android
        },
    };
    let d = SupportPrompt::decide(&context, Calendar::fixed(utc_offset));
    json!({
        "showsHeart": d.shows_heart, "showsCard": d.shows_card, "showsSheet": d.shows_sheet,
        "watchedHours": WatchTimeCounter::new(us.watched_seconds).watched_hours(), "isSupporter": st.is_supporter(),
    })
    .to_string()
}

/// `Kern.supportHistoryAfter`: `snooze`, `dismiss`, `sheetShown`; anything else returns the stored record's form.
#[uniffi::export]
pub fn legacy_support_history_after(history: String, answer: String, now_ms: i64) -> String {
    let s = store("", "", &history);
    let mut h = s.prompt_history();
    match answer.as_str() {
        "snooze" => h.snooze_card(secs(now_ms)),
        "dismiss" => h.dismiss_card(),
        "sheetShown" => h.record_sheet_shown(secs(now_ms)),
        _ => {}
    }
    let _ = s.set_prompt_history(&h);
    text(&s, storage_key::PROMPT_HISTORY)
}

fn status_record(source: Source, since: Option<f64>) -> String {
    let s = store("", "", "");
    let _ = s.set_status(SupportStatus::Supporter { source, since });
    text(&s, storage_key::STATUS)
}

/// `Kern.supportStoreStatus`: the status record for a purchase from Google Play (`since_ms` 0 is unknown).
#[uniffi::export]
pub fn legacy_support_store_status(since_ms: i64) -> String {
    status_record(Source::Store, (since_ms > 0).then(|| secs(since_ms)))
}

/// `Kern.supportKeyStatus`: the status record for a verified supporter key. Direct build only.
#[cfg(feature = "supporter-key")]
#[uniffi::export]
pub fn legacy_support_key_status(issued_ms: i64) -> String {
    status_record(Source::Key, Some(secs(issued_ms)))
}

/// `Kern.supportSource`: `store`, `key` or empty for none.
#[uniffi::export]
pub fn legacy_support_source(status: String) -> String {
    match store(&status, "", "").status() {
        SupportStatus::Supporter { source, .. } => serde_json::to_value(source)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default(),
        SupportStatus::None => String::new(),
    }
}

/// `Kern.supportTips`: `[{"id","de","en","emoji"}]` in display order.
#[uniffi::export]
pub fn legacy_support_tips() -> String {
    let tips: Vec<_> = SupportTip::ORDERED
        .iter()
        .map(|t| json!({"id": t.product_id(), "de": t.title().de, "en": t.title().en, "emoji": t.emoji()}))
        .collect();
    serde_json::Value::Array(tips).to_string()
}

/// `Kern.whatsNewDecide`: `markSeen`, `show` or `nothing`.
#[uniffi::export]
pub fn legacy_whats_new_decide(
    last_seen: String,
    used_before: bool,
    current: String,
    has_entry: bool,
) -> String {
    let seen = (!last_seen.is_empty()).then_some(last_seen.as_str());
    match decide(seen, used_before, &current, has_entry) {
        WhatsNewDecision::MarkSeen => "markSeen",
        WhatsNewDecision::Show => "show",
        WhatsNewDecision::Nothing => "nothing",
    }
    .to_owned()
}

/// `Kern.whatsNewCheck`: `{"valid":Bool,"giftLook":""}`.
#[uniffi::export]
pub fn legacy_whats_new_check(json: String) -> String {
    match WhatsNewEntry::decoded(json.as_bytes()) {
        Some(e) => json!({"valid": true, "giftLook": e.gift_look_id().unwrap_or("")}),
        None => json!({"valid": false, "giftLook": ""}),
    }
    .to_string()
}

/// **The watch-time counter of the support screen** (`Kern.supportWatchBegin/Take`, `watchProgress/Stopped`). One per app;
/// Kotlin feeds it from the playback tick and stores what `take` returns.
#[derive(uniffi::Object)]
pub struct LegacySupportWatch {
    counter: std::sync::Mutex<WatchTimeCounter>,
}

#[uniffi::export]
impl LegacySupportWatch {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            counter: std::sync::Mutex::new(WatchTimeCounter::default()),
        })
    }

    /// Start from the stored usage record, once per app start.
    pub fn begin(&self, usage: String) {
        let seconds = store("", &usage, "").usage().watched_seconds;
        *self
            .counter
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = WatchTimeCounter::new(seconds);
    }

    /// One observation of the playback tick.
    pub fn progress(&self, is_playing: bool, now_ms: i64) {
        use swiftly_support::support::WatchTimeFeed;
        self.counter
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .playback_progress(is_playing, secs(now_ms));
    }

    /// Playback ended or the app went to the background.
    pub fn stopped(&self, now_ms: i64) {
        use swiftly_support::support::WatchTimeFeed;
        self.counter
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .playback_stopped(secs(now_ms));
    }

    /// The usage record with the counted seconds when enough piled up (or `force` and anything is unsaved); "" otherwise.
    pub fn take(&self, usage: String, force: bool) -> String {
        let mut c = self
            .counter
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !(if force {
            c.unsaved_seconds() > 0.0
        } else {
            c.needs_save()
        }) {
            return String::new();
        }
        let s = store("", &usage, "");
        let _ = s.save(&mut c);
        text(&s, storage_key::USAGE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watch_counter_counts_and_stores() {
        let w = LegacySupportWatch::new();
        let usage = legacy_support_record_launch(String::new(), 1_700_000_000_000);
        w.begin(usage.clone());
        for i in 0..=70 {
            w.progress(true, 1_000_000 + i * 1000);
        }
        assert!(
            w.take(usage.clone(), false)
                .contains("\"watchedSeconds\":70")
        );
        assert_eq!(w.take(usage.clone(), true), "");
        w.progress(true, 2_000_000);
        w.stopped(2_005_000);
        assert!(w.take(usage, true).contains("\"watchedSeconds\":75"));
    }

    #[test]
    fn records_round_trip() {
        let u = legacy_support_record_launch(String::new(), 1_700_000_000_000);
        assert_eq!(
            legacy_support_record_launch(u.clone(), 1_800_000_000_000),
            u
        );
        let st = legacy_support_store_status(0);
        assert_eq!(legacy_support_source(st), "store");
        assert_eq!(legacy_support_source(String::new()), "");
        assert_eq!(
            legacy_whats_new_decide(String::new(), false, "1.0".into(), true),
            "markSeen"
        );
        assert_eq!(
            legacy_whats_new_check("garbage".into()),
            r#"{"giftLook":"","valid":false}"#
        );
    }
}
