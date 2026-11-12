//! Translation of SupportStatusTests, SupportPromptTests and the copy tests (JellyfinKit).

use swiftly_settings::{KeyValueStore, MemoryStore, Value};
use swiftly_support::support::{PromptContext, storage_key};
use swiftly_support::{
    Calendar, Decision, Source, SupportCopy, SupportPlan, SupportPlatform, SupportProductId,
    SupportPrompt, SupportPromptHistory, SupportStatus, SupportStore, SupportTip, SupportUsage,
    WatchTimeCounter, WatchTimeFeed,
};

const SINCE: f64 = 1_792_281_600.0;

fn json<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap_or_default()
}

#[test]
fn stored_json_shape_is_fixed() {
    assert_eq!(json(&SupportStatus::None), r#"{"kind":"none"}"#);
    assert_eq!(
        json(&SupportStatus::Supporter {
            source: Source::Store,
            since: Some(SINCE)
        }),
        r#"{"kind":"supporter","since":1792281600,"source":"store"}"#
    );
    assert_eq!(
        json(&SupportStatus::Supporter {
            source: Source::Key,
            since: None
        }),
        r#"{"kind":"supporter","source":"key"}"#
    );
    assert_eq!(
        json(&SupportUsage {
            first_launch: Some(SINCE),
            watched_seconds: 7_200.0
        }),
        r#"{"firstLaunch":1792281600,"watchedSeconds":7200}"#
    );
    let history = SupportPromptHistory {
        card_snoozed_until: Some(SINCE),
        card_dismissed: true,
        card_snoozes: 0,
        sheet_shown_at: vec![SINCE],
    };
    assert_eq!(
        json(&history),
        r#"{"cardDismissed":true,"cardSnoozedUntil":1792281600,"cardSnoozes":0,"sheetShownAt":[1792281600]}"#
    );
}

#[test]
fn stored_json_reads_back() {
    for status in [
        SupportStatus::None,
        SupportStatus::Supporter {
            source: Source::Store,
            since: Some(SINCE),
        },
        SupportStatus::Supporter {
            source: Source::Key,
            since: None,
        },
    ] {
        let back: SupportStatus = serde_json::from_str(&json(&status)).unwrap();
        assert_eq!(back, status);
    }
    assert!(serde_json::from_str::<SupportStatus>(r#"{"kind":"gold"}"#).is_err());
    // Fractions survive.
    let usage = SupportUsage {
        first_launch: None,
        watched_seconds: 7_200.5,
    };
    assert_eq!(
        serde_json::from_str::<SupportUsage>(&json(&usage)).unwrap(),
        usage
    );
}

#[test]
fn store_reads_empty_and_writes_fixed_keys() {
    let store = SupportStore::new(MemoryStore::new());
    assert_eq!(store.status(), SupportStatus::None);
    assert_eq!(store.usage(), SupportUsage::default());
    assert_eq!(store.prompt_history(), SupportPromptHistory::default());
    store
        .set_status(SupportStatus::Supporter {
            source: Source::Key,
            since: Some(SINCE),
        })
        .unwrap();
    store.record_launch(SINCE).unwrap();
    store.record_launch(SINCE + 1_000.0).unwrap();
    let mut history = store.prompt_history();
    history.dismiss_card();
    store.set_prompt_history(&history).unwrap();
    let mut keys = store.store().keys();
    keys.sort();
    let mut expected: Vec<String> = storage_key::ALL.iter().map(|s| (*s).to_owned()).collect();
    expected.sort();
    assert_eq!(keys, expected);
    assert_eq!(
        store.status(),
        SupportStatus::Supporter {
            source: Source::Key,
            since: Some(SINCE)
        }
    );
    assert_eq!(store.usage().first_launch, Some(SINCE));
    assert!(store.prompt_history().card_dismissed);
    assert_eq!(
        storage_key::ALL,
        ["support.status", "support.usage", "support.promptHistory"]
    );
}

#[test]
fn damaged_record_reads_as_empty_and_strings_read_as_bytes() {
    let mem = MemoryStore::new();
    mem.set(storage_key::STATUS, Value::Data(b"{".to_vec()))
        .unwrap();
    assert_eq!(SupportStore::new(mem).status(), SupportStatus::None);
    let mem = MemoryStore::new();
    mem.set(
        storage_key::STATUS,
        Value::Str(r#"{"kind":"supporter","source":"store"}"#.into()),
    )
    .unwrap();
    assert!(SupportStore::new(mem).status().is_supporter());
}

#[test]
fn plan_is_stored_under_its_own_key() {
    let store = SupportStore::new(MemoryStore::new());
    assert_eq!(store.plan(), None);
    store.set_plan(Some(SupportPlan::Lifetime)).unwrap();
    assert_eq!(store.plan(), Some(SupportPlan::Lifetime));
    assert_eq!(store.store().get_data("support.plan").unwrap(), b"lifetime");
    store.set_plan(None).unwrap();
    assert_eq!(store.plan(), None);
    assert!(!storage_key::ALL.contains(&storage_key::PLAN));
    assert_eq!(
        SupportPlan::ALL.map(SupportPlan::raw),
        ["monthly", "lifetime", "tip"]
    );
}

// ---- Prompt ----

const DAYS: f64 = 86_400.0;
const HOUR: f64 = 3_600.0;
const START: f64 = 1_799_582_400.0;

struct C {
    days: f64,
    watched_hours: f64,
    status: SupportStatus,
    history: SupportPromptHistory,
    playing: bool,
    since_launch: f64,
    platform: SupportPlatform,
    first_launch: Option<f64>,
    now: Option<f64>,
}

fn c(days: f64) -> C {
    C {
        days,
        watched_hours: 2.0,
        status: SupportStatus::None,
        history: SupportPromptHistory::default(),
        playing: false,
        since_launch: 120.0,
        platform: SupportPlatform::IPhone,
        first_launch: Some(START),
        now: None,
    }
}

fn decide(c: &C) -> Decision {
    let ctx = PromptContext {
        now: c.now.unwrap_or(START + c.days * DAYS),
        status: c.status,
        usage: SupportUsage {
            first_launch: c.first_launch,
            watched_seconds: c.watched_hours * HOUR,
        },
        history: &c.history,
        is_playing: c.playing,
        seconds_since_launch: c.since_launch,
        platform: c.platform,
    };
    SupportPrompt::decide(&ctx, Calendar::UTC)
}

#[test]
fn heart_is_always_there() {
    assert!(
        decide(&C {
            watched_hours: 0.0,
            ..c(0.0)
        })
        .shows_heart
    );
    assert!(
        decide(&C {
            status: SupportStatus::Supporter {
                source: Source::Store,
                since: None
            },
            playing: true,
            ..c(100.0)
        })
        .shows_heart
    );
}

#[test]
fn card_rules() {
    assert!(!decide(&c(2.99)).shows_card);
    assert!(decide(&c(3.0)).shows_card);
    assert!(
        !decide(&C {
            watched_hours: 1.99,
            ..c(5.0)
        })
        .shows_card
    );
    assert!(
        decide(&C {
            watched_hours: 2.0,
            ..c(5.0)
        })
        .shows_card
    );
    assert!(
        !decide(&C {
            first_launch: None,
            ..c(10.0)
        })
        .shows_card
    );
    assert!(
        decide(&C {
            platform: SupportPlatform::AppleTv,
            ..c(3.0)
        })
        .shows_card
    );
}

#[test]
fn card_snooze_is_thirty_days_and_second_ends_it() {
    let mut history = SupportPromptHistory::default();
    history.record_sheet_shown(START + 7.0 * DAYS);
    let now = START + 4.0 * DAYS;
    history.snooze_card(now);
    assert_eq!(history.card_snoozed_until, Some(now + 30.0 * DAYS));
    assert!(
        !decide(&C {
            history: history.clone(),
            ..c(4.0)
        })
        .shows_card
    );
    assert!(
        !decide(&C {
            history: history.clone(),
            ..c(33.99)
        })
        .shows_card
    );
    assert!(decide(&C { history, ..c(34.0) }).shows_card);

    let mut history = SupportPromptHistory::default();
    history.snooze_card(START + 4.0 * DAYS);
    assert!(!history.card_dismissed);
    history.snooze_card(START + 40.0 * DAYS);
    assert!(history.card_dismissed);
    assert_eq!(SupportPromptHistory::SNOOZES_UNTIL_GONE, 2);
    assert!(
        !decide(&C {
            watched_hours: 900.0,
            history,
            ..c(4_000.0)
        })
        .shows_card
    );
    let old: SupportPromptHistory =
        serde_json::from_str(r#"{"cardDismissed":false,"sheetShownAt":[]}"#).unwrap();
    assert_eq!(old.card_snoozes, 0);

    let mut history = SupportPromptHistory::default();
    history.dismiss_card();
    assert!(!decide(&C { history, ..c(4.0) }).shows_card);
}

#[test]
fn sheet_rules() {
    assert!(!decide(&c(6.99)).shows_sheet);
    assert!(decide(&c(7.0)).shows_sheet);
    assert!(
        !decide(&C {
            watched_hours: 1.5,
            ..c(8.0)
        })
        .shows_sheet
    );
    assert!(
        decide(&C {
            watched_hours: 2.0,
            ..c(8.0)
        })
        .shows_sheet
    );

    let mut history = SupportPromptHistory::default();
    history.record_sheet_shown(START + 7.0 * DAYS);
    assert!(
        !decide(&C {
            history: history.clone(),
            ..c(7.0)
        })
        .shows_sheet
    );
    assert!(
        !decide(&C {
            history: history.clone(),
            ..c(96.99)
        })
        .shows_sheet
    );
    assert!(decide(&C { history, ..c(97.0) }).shows_sheet);
}

#[test]
fn sheet_yearly_limit() {
    let new_year = 1_798_761_600.0; // 2027-01-01 00:00 UTC
    let mut history = SupportPromptHistory::default();
    for i in 0..3 {
        history.record_sheet_shown(new_year + f64::from(i) * 90.0 * DAYS);
    }
    let base = C {
        first_launch: Some(new_year - 30.0 * DAYS),
        history,
        now: Some(new_year + 300.0 * DAYS),
        ..c(0.0)
    };
    assert!(!decide(&base).shows_sheet);
    let next_year = C {
        now: Some(1_830_297_600.0),
        ..base
    };
    assert!(decide(&next_year).shows_sheet);
}

#[test]
fn apple_tv_card_and_one_ask_at_a_time() {
    let d = decide(&C {
        platform: SupportPlatform::AppleTv,
        ..c(10.0)
    });
    assert!(!d.shows_sheet);
    assert!(d.shows_card);
    assert!(!SupportPlatform::AppleTv.allows_sheet());
    let no_sheet: Vec<_> = SupportPlatform::ALL
        .into_iter()
        .filter(|p| !p.allows_sheet())
        .collect();
    assert_eq!(no_sheet, [SupportPlatform::AppleTv]);
    let d = decide(&c(10.0));
    assert!(d.shows_sheet);
    assert!(!d.shows_card);
    assert_eq!(
        serde_json::to_string(&SupportPlatform::AndroidTv).unwrap(),
        "\"androidTV\""
    );
}

#[test]
fn never_for_supporters_or_during_playback_or_right_after_launch() {
    for source in Source::ALL {
        let d = decide(&C {
            watched_hours: 50.0,
            status: SupportStatus::Supporter {
                source,
                since: None,
            },
            ..c(100.0)
        });
        assert!(!d.shows_card && !d.shows_sheet);
    }
    let d = decide(&C {
        playing: true,
        ..c(100.0)
    });
    assert!(!d.shows_card && !d.shows_sheet);
    let early = decide(&C {
        since_launch: 59.9,
        ..c(100.0)
    });
    assert!(!early.shows_card && !early.shows_sheet);
    assert!(
        decide(&C {
            since_launch: 60.0,
            ..c(100.0)
        })
        .shows_sheet
    );
    assert!(
        !decide(&C {
            since_launch: 10.0,
            ..c(5.0)
        })
        .shows_card
    );
}

#[test]
fn history_keeps_the_last_twelve_sheet_dates() {
    let mut history = SupportPromptHistory::default();
    for i in 0..20 {
        history.record_sheet_shown(START + f64::from(i));
    }
    assert_eq!(
        history.sheet_shown_at.len(),
        SupportPromptHistory::KEPT_SHEET_DATES
    );
    assert_eq!(SupportPromptHistory::KEPT_SHEET_DATES, 12);
    assert_eq!(history.sheet_shown_at.last().copied(), Some(START + 19.0));
}

// ---- Watch time ----

const T0: f64 = 1_800_000_000.0;

#[test]
fn counter_counts_playing_time_only() {
    let mut counter = WatchTimeCounter::default();
    for s in (0..=100).step_by(10) {
        counter.playback_progress(true, T0 + f64::from(s));
    }
    assert_eq!(counter.total_seconds(), 100.0);
    counter.playback_stopped(T0 + 105.0);
    assert_eq!(counter.total_seconds(), 105.0);

    let mut counter = WatchTimeCounter::default();
    counter.playback_progress(true, T0);
    counter.playback_progress(false, T0 + 10.0);
    counter.playback_progress(false, T0 + 20.0);
    counter.playback_progress(true, T0 + 25.0);
    counter.playback_progress(true, T0 + 30.0);
    assert_eq!(counter.total_seconds(), 15.0);
}

#[test]
fn counter_ignores_gaps_and_backwards_clocks() {
    let mut counter = WatchTimeCounter::default();
    counter.playback_progress(true, T0);
    counter.playback_progress(true, T0 + 31.0);
    counter.playback_progress(true, T0 + 41.0);
    counter.playback_progress(true, T0 + 35.0);
    counter.playback_progress(true, T0 + 65.0);
    assert_eq!(counter.total_seconds(), 40.0);

    let mut counter = WatchTimeCounter::new(100.0);
    counter.playback_progress(true, T0);
    counter.playback_stopped(T0 + 5.0);
    counter.playback_stopped(T0 + 10.0);
    counter.playback_progress(true, T0 + 12.0);
    assert_eq!(counter.total_seconds(), 105.0);
}

#[test]
fn counter_hours_and_saving() {
    let mut counter = WatchTimeCounter::new(2.0 * 3_600.0 - 1.0);
    assert_eq!(counter.watched_hours(), 1);
    assert!(!counter.needs_save());
    for s in (0..=60).step_by(10) {
        counter.playback_progress(true, T0 + f64::from(s));
    }
    assert_eq!(counter.watched_hours(), 2);
    assert!(counter.needs_save());
    let store = SupportStore::new(MemoryStore::new());
    store.save(&mut counter).unwrap();
    assert!(!counter.needs_save());
    assert_eq!(store.usage().watched_seconds, counter.total_seconds());
    assert_eq!(WatchTimeCounter::new(-5.0).total_seconds(), 0.0);

    fn feed(sink: &mut impl WatchTimeFeed) {
        sink.playback_progress(true, T0);
        sink.playback_stopped(T0 + 20.0);
    }
    let mut counter = WatchTimeCounter::default();
    feed(&mut counter);
    assert_eq!(counter.total_seconds(), 20.0);
}

// ---- Copy ----

#[test]
fn copy_keys_unique_and_complete() {
    let keys: std::collections::BTreeSet<_> = SupportCopy::ALL.iter().map(|t| t.key()).collect();
    assert_eq!(keys.len(), SupportCopy::ALL.len());
    for t in SupportCopy::ALL {
        assert!(!t.de.is_empty() && !t.en.is_empty());
        assert!(t.de != t.en || t.de == "Swiftly");
    }
}

#[test]
fn copy_placeholders_and_wording() {
    fn tokens(s: &str) -> (usize, usize) {
        (s.matches("%lld").count(), s.matches("%@").count())
    }
    for t in SupportCopy::ALL {
        assert_eq!(tokens(t.de), tokens(t.en), "{}", t.key());
        assert!(!t.de.contains('!') && !t.en.contains('!'), "{}", t.key());
        for word in [
            "seamless",
            "nahtlos",
            "effortless",
            "mühelos",
            "powerful",
            "beautiful",
            "intuitive",
            "ultimate",
            "ultimativ",
            "genieße",
            "experience",
            "unleash",
            "journey",
            "Sie ",
        ] {
            assert!(
                !t.de.contains(word) && !t.en.to_lowercase().contains(&word.to_lowercase()),
                "{}: {word}",
                t.key()
            );
        }
    }
    assert_eq!(
        SupportCopy::CARD_WATCHED_HOURS.en.replace("%lld", "25"),
        "You have watched 25 hours with Swiftly."
    );
    assert_eq!(SupportCopy::CARD_MINIMUM_HOURS, 2);
}

#[test]
fn copy_language_choice() {
    assert_eq!(
        SupportCopy::NOT_NOW.text_for_language("de-AT"),
        "Nicht jetzt"
    );
    assert_eq!(SupportCopy::NOT_NOW.text_for_language("DE"), "Nicht jetzt");
    assert_eq!(SupportCopy::NOT_NOW.text_for_language("fr"), "Not now");
}

#[test]
fn tips_and_product_ids() {
    let ids: Vec<_> = SupportTip::ORDERED.iter().map(|t| t.product_id()).collect();
    assert_eq!(
        ids,
        [
            "de.paulherter.swiftly.tip.coffee",
            "de.paulherter.swiftly.tip.cake",
            "de.paulherter.swiftly.tip.movie"
        ]
    );
    assert_eq!(
        SupportTip::from_product_id("de.paulherter.swiftly.tip.cake"),
        Some(SupportTip::Cake)
    );
    assert_eq!(
        SupportTip::from_product_id("de.paulherter.swiftly.tip.1"),
        None
    );
    assert_eq!(SupportTip::Coffee.title(), SupportCopy::TIP_COFFEE);
    assert_eq!(
        SupportTip::ORDERED.map(SupportTip::emoji),
        ["☕", "🍰", "🎬"]
    );
    assert_eq!(SupportProductId::all().len(), 5);
    assert_eq!(
        SupportProductId::plan(SupportProductId::MONTHLY),
        Some(SupportPlan::Monthly)
    );
    assert_eq!(
        SupportProductId::plan(SupportProductId::LIFETIME),
        Some(SupportPlan::Lifetime)
    );
    assert_eq!(
        SupportProductId::plan("de.paulherter.swiftly.tip.movie"),
        Some(SupportPlan::Tip)
    );
    assert_eq!(SupportProductId::plan("other"), None);
}
