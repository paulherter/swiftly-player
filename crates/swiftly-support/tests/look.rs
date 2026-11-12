//! Translation of LookTests, LookTryOnTests and LookGiftTests (JellyfinKit).

use std::collections::BTreeSet;
use swiftly_settings::{KeyValueStore, MemoryStore, Value};
use swiftly_support::gift::{
    BatBlock, EffectContext, EffectPage, GiftContext, LookEffects, LookGift, LookProfileEntry,
};
use swiftly_support::look::{
    LookAccent, LookColor, LookGlow, LookPalette, LookSelection, storage_key,
};
use swiftly_support::look_store::{IconStep, LookStore, dock_icon_name, look_icon_step};
use swiftly_support::season::LookSeason;
use swiftly_support::time::{Calendar, MonthDay};
use swiftly_support::try_on::{KeepResult, LookTryOn};
use swiftly_support::{Look, SupporterIcon};

fn cal() -> Calendar {
    Calendar::fixed(3600)
}
fn day(y: i32, m: u32, d: u32, h: u32, min: u32) -> f64 {
    cal().timestamp(y, m, d, h, min)
}
fn noon(y: i32, m: u32, d: u32) -> f64 {
    day(y, m, d, 12, 0)
}
fn set(ids: &[&str]) -> BTreeSet<String> {
    ids.iter().map(|s| (*s).to_owned()).collect()
}
fn luminance(c: LookColor) -> f64 {
    let ch = |v: f64| {
        if v <= 0.03928 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * ch(c.red()) + 0.7152 * ch(c.green()) + 0.0722 * ch(c.blue())
}
fn ratio(a: LookColor, b: LookColor) -> f64 {
    (luminance(a) + 0.05) / (luminance(b) + 0.05)
}

#[test]
fn original_is_unchanged() {
    let p = LookPalette::original();
    assert_eq!(p.look.id, "original");
    assert_eq!(p.accent.main.css(), "#50D5DA");
    assert_eq!(p.accent.light.css(), "#7AE6EA");
    assert_eq!(p.accent.quiet.css(), "#113435");
    assert_eq!(p.accent.on.css(), "#061212");
    assert_eq!(p.glow, LookGlow::Off);
    assert_eq!(p.glow.opacity(), 0.0);
    assert_eq!(p.icon_name, None);
    assert_eq!(p.look.logo_gradient, &[LookColor::new(0x50D5DA)]);
    assert_eq!(p.look.background.css(), "#101010");
}

#[test]
fn neon_night_and_overrides() {
    let p = LookSelection::of("neonNight").palette();
    assert_eq!(p.accent, LookAccent::VIOLET);
    assert_eq!(p.glow, LookGlow::Soft);
    assert_eq!(p.glow.opacity(), 0.20);
    assert_eq!(p.icon_name, Some("AppIcon-NeonNight"));
    assert_eq!(p.look.logo_gradient.len(), 2);

    let sel = LookSelection {
        accent_id: Some("coral".into()),
        glow: Some(LookGlow::Bright),
        uses_look_icon: Some(false),
        look_id: "neonNight".into(),
    };
    let p = sel.palette();
    assert_eq!(p.look, Look::NEON_NIGHT);
    assert_eq!(p.accent, LookAccent::CORAL);
    assert_eq!(p.glow, LookGlow::Bright);
    assert_eq!(p.icon_name, None);
}

#[test]
fn switching_drops_overrides_and_unknown_ids_fall_back() {
    let sel = LookSelection {
        accent_id: Some("gold".into()),
        glow: Some(LookGlow::Bright),
        uses_look_icon: None,
        look_id: "original".into(),
    };
    assert_eq!(
        sel.switching(&Look::NEON_NIGHT),
        LookSelection::of("neonNight")
    );
    assert_eq!(LookSelection::of("removed").palette().look, Look::ORIGINAL);
    let odd = LookSelection {
        accent_id: Some("removed".into()),
        ..LookSelection::of("neonNight")
    };
    assert_eq!(odd.palette().accent, LookAccent::VIOLET);
    assert_eq!(
        LookSelection::decoded(Some(b"garbage")),
        LookSelection::original()
    );
    assert_eq!(LookSelection::decoded(None), LookSelection::original());
}

#[test]
fn stored_json_shape_is_fixed() {
    let sel = LookSelection {
        accent_id: Some("coral".into()),
        glow: Some(LookGlow::Bright),
        uses_look_icon: Some(false),
        look_id: "neonNight".into(),
    };
    let data = sel.encoded();
    assert_eq!(
        String::from_utf8(data.clone()).unwrap(),
        r#"{"accent":"coral","glow":"bright","icon":false,"look":"neonNight"}"#
    );
    assert_eq!(
        String::from_utf8(LookSelection::original().encoded()).unwrap(),
        r#"{"look":"original"}"#
    );
    assert_eq!(
        LookSelection::decoded(Some(&data)).glow,
        Some(LookGlow::Bright)
    );
    assert_eq!(storage_key::SELECTION, "look.selection");
    assert_eq!(storage_key::OWNED, "look.owned");
    assert_eq!(storage_key::GIFT_OFFERED, "look.gift.offered");
    assert_eq!(storage_key::EFFECTS, "look.effects");
}

#[test]
fn accents_are_readable_and_ordered() {
    for a in LookAccent::ALL {
        assert!(ratio(a.main, a.on) >= 4.5, "{}", a.id);
    }
    assert_eq!(
        LookAccent::ALL.map(|a| a.id),
        ["violet", "teal", "coral", "gold", "emerald"]
    );
    assert_eq!(LookAccent::TEAL.name_key(), "Türkis");
    assert_eq!(LookAccent::PUMPKIN.name_key(), "Türkis");
    assert_eq!(LookAccent::VIOLET.name_key(), "Violett");
}

#[test]
fn look_order_ids_and_names() {
    let ids: Vec<_> = Look::ALL.iter().map(|l| l.id).collect();
    assert_eq!(
        ids,
        [
            "original",
            "halloween",
            "neonNight",
            "sunset",
            "aurora",
            "ice",
            "ember",
            "gold",
            "emerald"
        ]
    );
    let names: Vec<_> = Look::ALL.iter().map(|l| l.name_key).collect();
    assert_eq!(
        names,
        [
            "Original",
            "Halloween",
            "Neon-Nacht",
            "Sunset",
            "Aurora",
            "Eis",
            "Glut",
            "Gold",
            "Smaragd"
        ]
    );
    assert_eq!(Look::free(), vec![Look::ORIGINAL, Look::HALLOWEEN]);
    let icons: BTreeSet<_> = Look::ALL.iter().filter_map(|l| l.icon_name).collect();
    assert_eq!(icons.len(), Look::ALL.len() - 1);
    for l in Look::ALL {
        assert_eq!(Look::with_id(l.id), l);
        assert_eq!(LookSelection::of(l.id).palette().look, l);
    }
    assert_eq!(Look::with_id("removed"), Look::ORIGINAL);
}

#[test]
fn supporter_looks() {
    let ground = LookColor::new(0x101010);
    for l in [
        Look::SUNSET,
        Look::AURORA,
        Look::ICE,
        Look::EMBER,
        Look::GOLD,
        Look::EMERALD,
    ] {
        assert!(!l.is_gift && l.availability.is_none());
        assert_eq!(l.default_glow, LookGlow::Soft);
        assert_eq!(l.background.css(), "#101010");
        assert!(l.icon_name.unwrap().starts_with("AppIcon-Look"));
        assert!(l.logo_gradient.len() >= 2);
        assert!(ratio(l.accent.main, ground) >= 4.5, "{}", l.id);
        assert!(ratio(l.accent.main, l.accent.on) >= 4.5, "{}", l.id);
        assert_eq!(LookAccent::with_id(l.accent.id), Some(l.accent));
    }
    let sunset: Vec<_> = Look::SUNSET.logo_gradient.iter().map(|c| c.css()).collect();
    assert_eq!(sunset, ["#FFCB57", "#FF6E7F", "#B83FD0"]);
    assert_eq!(Look::GOLD.glow_color.css(), "#E0B050");
    assert!(LookAccent::EMBER.warning.is_some());
}

// ---- LookTryOn ----

fn neon() -> LookSelection {
    LookSelection::of("neonNight")
}

#[test]
fn try_on_matrix() {
    let state = LookTryOn::new(neon(), false, BTreeSet::new());
    assert_eq!(state.shown(), LookSelection::original());
    assert!(!state.is_previewing());

    let mut state = LookTryOn::default();
    state.begin();
    assert_eq!(state.shown(), LookSelection::original());
    state.try_on(neon());
    assert_eq!(state.shown(), neon());
    assert_eq!(*state.saved(), LookSelection::original());

    assert_eq!(
        LookTryOn::new(neon(), true, BTreeSet::new()).shown(),
        neon()
    );
    let mut state = LookTryOn::new(neon(), true, BTreeSet::new());
    state.begin();
    state.try_on(LookSelection::original());
    assert_eq!(state.shown(), LookSelection::original());
    assert_eq!(*state.saved(), neon());
}

#[test]
fn preview_opens_on_the_active_look() {
    for supporter in [false, true] {
        let tuned = LookSelection {
            accent_id: Some("gold".into()),
            glow: Some(LookGlow::Bright),
            uses_look_icon: None,
            look_id: "neonNight".into(),
        };
        let mut state = LookTryOn::new(tuned.clone(), supporter, BTreeSet::new());
        let before = state.shown();
        state.begin();
        assert_eq!(state.shown(), before);
        state.try_on(LookSelection::original());
        state.try_on(state.saved().clone());
        state.end();
        assert_eq!(state.shown(), before);
        assert_eq!(*state.saved(), tuned);
    }
}

#[test]
fn closing_keeps_nothing() {
    for supporter in [false, true] {
        let mut state = LookTryOn::new(LookSelection::original(), supporter, BTreeSet::new());
        state.begin();
        state.try_on(LookSelection {
            accent_id: Some("coral".into()),
            ..neon()
        });
        state.end();
        assert_eq!(state.shown(), LookSelection::original());
        assert_eq!(*state.saved(), LookSelection::original());
        assert!(state.pending_keep().is_none());
    }
}

#[test]
fn keep_flows() {
    let mut state = LookTryOn::default();
    state.begin();
    state.try_on(neon());
    assert_eq!(state.keep(), KeepResult::NeedsSupport);
    assert_eq!(*state.saved(), LookSelection::original());
    assert!(!state.is_supporter());
    assert!(state.is_previewing());
    state.support_sheet_closed();
    state.end();
    assert_eq!(state.shown(), LookSelection::original());

    // Wish forgotten, later a tip: not switched.
    let mut state = LookTryOn::default();
    state.begin();
    state.try_on(neon());
    state.keep();
    state.support_sheet_closed();
    state.end();
    assert_eq!(state.purchase_completed(), None);
    assert!(state.is_supporter());
    assert_eq!(state.shown(), LookSelection::original());

    // Keep, then the purchase.
    let mut state = LookTryOn::default();
    state.begin();
    state.try_on(neon());
    state.keep();
    let kept = state.purchase_completed();
    assert_eq!(kept.map(|k| k.look_id), Some("neonNight".to_owned()));
    assert_eq!(state.saved().look_id, "neonNight");
    assert_eq!(state.shown().look_id, "neonNight");
    assert!(!state.is_previewing());

    // As a supporter right away.
    let mut state = LookTryOn::new(LookSelection::original(), true, BTreeSet::new());
    state.begin();
    state.try_on(neon());
    assert_eq!(state.keep(), KeepResult::Kept);
    assert_eq!(state.saved().look_id, "neonNight");
    assert!(!state.is_previewing());

    // Without a preview.
    let mut state = LookTryOn::new(LookSelection::original(), true, BTreeSet::new());
    assert_eq!(state.keep(), KeepResult::Nothing);
    let mut state = LookTryOn::default();
    state.try_on(neon());
    assert_eq!(state.shown(), LookSelection::original());
}

#[test]
fn support_changing_choose_reset() {
    let mut state = LookTryOn::new(neon(), true, BTreeSet::new());
    state.set_supporter(false);
    assert_eq!(state.shown(), LookSelection::original());
    assert_eq!(*state.saved(), neon());
    state.set_supporter(true);
    assert_eq!(state.shown(), neon());

    let mut state = LookTryOn::default();
    assert!(!state.choose(neon()));
    assert_eq!(state.shown(), LookSelection::original());
    state.set_supporter(true);
    assert!(state.choose(neon()));
    assert_eq!(state.shown(), neon());

    let mut state = LookTryOn::new(neon(), true, BTreeSet::new());
    state.begin();
    state.reset();
    assert_eq!(state, LookTryOn::default());
}

// ---- LookGift, seasons, effects ----

fn ctx(now: f64) -> GiftContext {
    GiftContext {
        now,
        home_ready: true,
        playing: false,
        asked_this_session: false,
        seconds_on_home: 10.0,
        owned: set(&[]),
        offered: set(&[]),
    }
}

#[test]
fn halloween_window() {
    let s = LookSeason::HALLOWEEN;
    assert_eq!(
        (s.from, s.to),
        (MonthDay::new(10, 24), MonthDay::new(11, 2))
    );
    assert!(!s.is_active(day(2026, 10, 23, 23, 59), cal()));
    assert!(s.is_active(day(2026, 10, 24, 0, 0), cal()));
    assert!(s.is_active(noon(2026, 10, 31), cal()));
    assert!(s.is_active(day(2026, 11, 2, 23, 59), cal()));
    assert!(!s.is_active(day(2026, 11, 3, 0, 0), cal()));
    assert!(!s.is_active(noon(2027, 3, 1), cal()));
}

#[test]
fn window_over_new_year_and_next_start() {
    let winter = LookSeason {
        id: "winter",
        from: MonthDay::new(12, 1),
        to: MonthDay::new(1, 2),
    };
    assert!(winter.crosses_new_year());
    assert!(winter.is_active(noon(2026, 12, 24), cal()));
    assert!(winter.is_active(noon(2027, 1, 2), cal()));
    assert!(!winter.is_active(noon(2027, 1, 3), cal()));
    assert_eq!(winter.season_year(noon(2027, 1, 1), cal()), Some(2026));
    assert_eq!(winter.season_year(noon(2026, 12, 1), cal()), Some(2026));
    let s = LookSeason::HALLOWEEN;
    assert_eq!(
        s.next_start(noon(2026, 10, 1), cal()),
        day(2026, 10, 24, 0, 0)
    );
    assert_eq!(
        s.next_start(noon(2026, 10, 30), cal()),
        day(2027, 10, 24, 0, 0)
    );
}

#[test]
fn gift_due_rules() {
    let now = noon(2026, 10, 26);
    let looks = Look::ALL;
    assert_eq!(
        LookGift::due(&ctx(now), &looks, cal()),
        Some(Look::HALLOWEEN)
    );
    assert_eq!(LookGift::due(&ctx(noon(2026, 10, 20)), &looks, cal()), None);
    assert_eq!(LookGift::due(&ctx(noon(2026, 11, 3)), &looks, cal()), None);
    assert_eq!(
        LookGift::due(
            &GiftContext {
                home_ready: false,
                ..ctx(now)
            },
            &looks,
            cal()
        ),
        None
    );
    assert_eq!(
        LookGift::due(
            &GiftContext {
                playing: true,
                ..ctx(now)
            },
            &looks,
            cal()
        ),
        None
    );
    assert_eq!(
        LookGift::due(
            &GiftContext {
                asked_this_session: true,
                ..ctx(now)
            },
            &looks,
            cal()
        ),
        None
    );
    assert_eq!(
        LookGift::due(
            &GiftContext {
                seconds_on_home: 1.0,
                ..ctx(now)
            },
            &looks,
            cal()
        ),
        None
    );
}

#[test]
fn gift_shown_once_and_availability() {
    let now = noon(2026, 10, 26);
    let looks = Look::ALL;
    assert_eq!(
        LookGift::offer_id(&Look::HALLOWEEN, now, cal()).as_deref(),
        Some("halloween-2026")
    );
    assert_eq!(
        LookGift::due(
            &GiftContext {
                offered: set(&["halloween-2026"]),
                ..ctx(now)
            },
            &looks,
            cal()
        ),
        None
    );
    assert_eq!(
        LookGift::due(
            &GiftContext {
                owned: set(&["halloween"]),
                ..ctx(now)
            },
            &looks,
            cal()
        ),
        None
    );
    let next = GiftContext {
        offered: set(&["halloween-2026"]),
        ..ctx(noon(2027, 10, 26))
    };
    assert_eq!(LookGift::due(&next, &looks, cal()), Some(Look::HALLOWEEN));

    assert!(LookGift::is_available(
        &Look::HALLOWEEN,
        &set(&[]),
        noon(2026, 10, 30),
        cal()
    ));
    assert!(!LookGift::is_available(
        &Look::HALLOWEEN,
        &set(&[]),
        noon(2026, 11, 5),
        cal()
    ));
    assert!(LookGift::is_available(
        &Look::HALLOWEEN,
        &set(&["halloween"]),
        noon(2027, 3, 1),
        cal()
    ));
    assert!(LookGift::is_available(
        &Look::ORIGINAL,
        &set(&[]),
        noon(2027, 3, 1),
        cal()
    ));
}

#[test]
fn claim_and_choose_free() {
    let mut state = LookTryOn::default();
    assert_eq!(state.shown(), LookSelection::original());
    assert_eq!(
        state.claim(&Look::HALLOWEEN),
        Some(LookSelection::of("halloween"))
    );
    assert_eq!(*state.owned(), set(&["halloween"]));
    assert_eq!(state.shown().look(), Look::HALLOWEEN);
    assert!(state.owns_look());
    let later = LookTryOn::new(state.saved().clone(), false, state.owned().clone());
    assert_eq!(later.shown().look(), Look::HALLOWEEN);

    let mut state = LookTryOn::default();
    assert_eq!(state.claim(&Look::NEON_NIGHT), None);
    assert!(state.owned().is_empty());

    let mut state = LookTryOn::new(LookSelection::original(), false, set(&["halloween"]));
    assert!(state.choose(LookSelection::of("halloween")));
    assert_eq!(state.shown().look(), Look::HALLOWEEN);
    assert!(state.choose(LookSelection::original()));
    assert!(!state.choose(LookSelection::of("neonNight")));
    assert!(!state.choose(LookSelection {
        accent_id: Some("gold".into()),
        ..LookSelection::of("halloween")
    }));
    assert_eq!(state.shown(), LookSelection::original());
    assert!(state.choose(LookSelection {
        glow: Some(LookGlow::Soft),
        ..LookSelection::original()
    }));
    assert!(state.choose(LookSelection {
        glow: Some(LookGlow::Bright),
        uses_look_icon: Some(false),
        ..LookSelection::of("halloween")
    }));
    let mut stranger = LookTryOn::default();
    assert!(!stranger.choose(LookSelection::of("halloween")));

    let state = LookTryOn::new(LookSelection::of("halloween"), false, set(&[]));
    assert_eq!(state.shown(), LookSelection::original());

    let mut state = LookTryOn::new(LookSelection::original(), false, set(&["halloween"]));
    state.begin();
    state.try_on(LookSelection::of("halloween"));
    assert_eq!(state.keep(), KeepResult::Kept);
    assert_eq!(state.saved().look(), Look::HALLOWEEN);
    state.begin();
    state.try_on(LookSelection::of("neonNight"));
    assert_eq!(state.keep(), KeepResult::NeedsSupport);
}

#[test]
fn profile_entry_states() {
    use LookProfileEntry as E;
    assert_eq!(E::at(true, true, false), E::Current);
    assert_eq!(E::at(true, true, true), E::Current);
    assert_eq!(E::at(true, false, true), E::Current);
    assert_eq!(E::at(true, false, false), E::Teaser);
    assert_eq!(E::at(false, true, false), E::Current);
    assert_eq!(E::at(false, false, true), E::Current);
    assert_eq!(E::at(false, false, false), E::None);
    assert!(E::shows_looks_row(E::None, true));
    assert!(!E::shows_looks_row(E::None, false));
    assert!(!E::shows_looks_row(E::Current, true));
    assert!(!E::shows_looks_row(E::Teaser, true));
}

fn fx(now: f64) -> EffectContext {
    EffectContext {
        look: Look::HALLOWEEN,
        now,
        switch_on: true,
        playing: false,
        reduce_motion: false,
        low_power: false,
        foreground: true,
    }
}

#[test]
fn bats_and_details() {
    let now = noon(2026, 10, 30);
    let c = cal();
    assert!(LookEffects::bats(EffectPage::Home, &fx(now), c));
    assert!(!LookEffects::bats(EffectPage::Detail, &fx(now), c));
    assert!(!LookEffects::bats(EffectPage::Profile, &fx(now), c));
    assert!(!LookEffects::bats(
        EffectPage::Home,
        &EffectContext {
            playing: true,
            ..fx(now)
        },
        c
    ));
    assert!(!LookEffects::bats(
        EffectPage::Home,
        &EffectContext {
            reduce_motion: true,
            ..fx(now)
        },
        c
    ));
    assert!(!LookEffects::bats(
        EffectPage::Home,
        &EffectContext {
            low_power: true,
            ..fx(now)
        },
        c
    ));
    assert!(!LookEffects::bats(
        EffectPage::Home,
        &EffectContext {
            foreground: false,
            ..fx(now)
        },
        c
    ));
    assert!(!LookEffects::bats(
        EffectPage::Home,
        &EffectContext {
            switch_on: false,
            ..fx(now)
        },
        c
    ));
    assert!(!LookEffects::bats(
        EffectPage::Home,
        &fx(noon(2026, 11, 3)),
        c
    ));
    assert!(!LookEffects::bats(
        EffectPage::Home,
        &EffectContext {
            look: Look::ORIGINAL,
            ..fx(now)
        },
        c
    ));

    assert_eq!(LookEffects::bat_block(EffectPage::Home, &fx(now), c), None);
    assert_eq!(
        LookEffects::bat_block(
            EffectPage::Home,
            &EffectContext {
                reduce_motion: true,
                ..fx(now)
            },
            c
        ),
        Some(BatBlock::ReduceMotion)
    );
    assert_eq!(
        LookEffects::bat_block(
            EffectPage::Home,
            &EffectContext {
                low_power: true,
                ..fx(now)
            },
            c
        ),
        Some(BatBlock::LowPower)
    );
    assert_eq!(
        LookEffects::bat_block(
            EffectPage::Home,
            &EffectContext {
                playing: true,
                ..fx(now)
            },
            c
        ),
        Some(BatBlock::Playing)
    );
    assert_eq!(
        LookEffects::bat_block(EffectPage::Home, &fx(noon(2026, 11, 3)), c),
        Some(BatBlock::OutsideWindow)
    );
    assert_eq!(
        LookEffects::bat_block(
            EffectPage::Home,
            &EffectContext {
                foreground: false,
                ..fx(now)
            },
            c
        ),
        Some(BatBlock::Background)
    );

    assert!(LookEffects::details(
        EffectPage::Home,
        &EffectContext {
            reduce_motion: true,
            ..fx(now)
        },
        c
    ));
    assert!(LookEffects::details(EffectPage::Profile, &fx(now), c));
    assert!(!LookEffects::details(EffectPage::Detail, &fx(now), c));
    assert!(!LookEffects::details(
        EffectPage::Home,
        &fx(noon(2026, 11, 3)),
        c
    ));
}

#[test]
fn bat_rhythm() {
    assert_eq!(LookEffects::wait(true, 0.3), 6.0);
    assert_eq!(LookEffects::wait(false, 0.0), 45.0);
    assert_eq!(LookEffects::wait(false, 1.0), 90.0);
    assert_eq!(LookEffects::PAUSE, (45.0, 90.0));
    assert_eq!(LookEffects::FLIGHT, (2.5, 3.5));
}

#[test]
fn logo_colour_and_halloween_look() {
    assert_eq!(LookPalette::original().mark_color().css(), "#50D5DA");
    assert_eq!(
        LookSelection::of("halloween").palette().mark_color().css(),
        "#FF8A2B"
    );
    assert_eq!(
        LookSelection::of("neonNight").palette().mark_color().css(),
        "#8E63FF"
    );
    let mut state = LookTryOn::default();
    state.claim(&Look::HALLOWEEN);
    assert_eq!(state.shown().palette().mark_color().css(), "#FF8A2B");

    let p = LookSelection::of("halloween").palette();
    assert_eq!(p.accent.main.css(), "#FF8A2B");
    assert_eq!(p.icon_name, Some("AppIcon-Halloween"));
    assert_eq!(p.glow, LookGlow::Soft);
    assert!(LookAccent::PUMPKIN.warning.is_some());
    assert!(LookAccent::TEAL.warning.is_none());
    let pumpkin = LookAccent::PUMPKIN;
    let ground = LookColor::new(0x101010);
    assert!(ratio(pumpkin.main, pumpkin.on) >= 4.5);
    assert!(ratio(pumpkin.main, ground) >= 4.5);
    assert!(ratio(pumpkin.warning.unwrap(), ground) >= 4.5);
}

// ---- LookStore over a key-value store ----

#[test]
fn look_store_load_save_funnel() {
    let mut store = LookStore::load(MemoryStore::new());
    assert!(store.effects_on());
    assert_eq!(store.selection(), LookSelection::original());
    // Nothing is written by loading.
    assert!(store.store().keys().is_empty());

    // Claim: the selection and the owned list are written, sorted.
    store.claim(&Look::HALLOWEEN).unwrap();
    assert_eq!(
        store.store().get_data("look.selection").unwrap(),
        br#"{"look":"halloween"}"#
    );
    assert_eq!(
        store.store().get("look.owned"),
        Some(Value::StrList(vec!["halloween".into()]))
    );

    // A preview writes nothing.
    let before = store.store().keys();
    store.begin_preview().unwrap();
    store.try_on(LookSelection::of("original")).unwrap();
    assert_eq!(store.store().keys(), before);
    assert_eq!(
        store.store().get_data("look.selection").unwrap(),
        br#"{"look":"halloween"}"#
    );
    store.end_preview().unwrap();

    // Loading again reads the same state; not a supporter, so a stored supporter look shows the original.
    let reread = LookStore::load(MemoryStore::new());
    assert!(reread.state().owned().is_empty());
    store.set_effects_on(false).unwrap();
    assert_eq!(store.store().get_bool("look.effects"), Some(false));

    // Reset: fresh install, offers forgotten, effects on.
    store
        .mark_offered(&Look::HALLOWEEN, noon(2026, 10, 26), cal())
        .unwrap();
    assert_eq!(store.offered(), set(&["halloween-2026"]));
    store.reset().unwrap();
    assert_eq!(store.selection(), LookSelection::original());
    assert!(store.offered().is_empty());
    assert!(store.effects_on());
    assert_eq!(
        store.store().get("look.owned"),
        Some(Value::StrList(vec![]))
    );
}

#[test]
fn look_store_reads_what_swift_stored() {
    let mem = MemoryStore::new();
    mem.set(
        "look.selection",
        Value::Data(br#"{"accent":"gold","look":"neonNight"}"#.to_vec()),
    )
    .unwrap();
    mem.set("look.owned", Value::StrList(vec!["halloween".into()]))
        .unwrap();
    mem.set("look.effects", Value::Bool(false)).unwrap();
    let mut store = LookStore::load(mem);
    assert!(!store.effects_on());
    assert!(store.state().owned().contains("halloween"));
    assert_eq!(
        store.selection(),
        LookSelection::original(),
        "not a supporter yet"
    );
    store.set_supporter(true).unwrap();
    assert_eq!(store.selection().accent_id.as_deref(), Some("gold"));
    let now = noon(2026, 5, 1);
    assert_eq!(store.picker_looks(now, cal()).len(), Look::ALL.len());
    assert_eq!(
        store.free_looks(now, cal()),
        vec![Look::ORIGINAL, Look::HALLOWEEN]
    );
    let outside = LookStore::load(MemoryStore::new());
    assert_eq!(outside.picker_looks(now, cal()).len(), Look::ALL.len() - 1);
    assert_eq!(outside.free_looks(now, cal()), vec![Look::ORIGINAL]);
}

#[test]
fn icons_follow_the_look() {
    assert_eq!(look_icon_step(None, None), IconStep::Keep);
    // A supporter icon stays when a look without an icon is chosen.
    assert_eq!(look_icon_step(Some("AppIcon-Heart"), None), IconStep::Keep);
    assert_eq!(
        look_icon_step(Some("AppIcon-Halloween"), None),
        IconStep::Set(None)
    );
    assert_eq!(
        look_icon_step(None, Some("AppIcon-NeonNight")),
        IconStep::Set(Some("AppIcon-NeonNight"))
    );
    assert_eq!(
        look_icon_step(Some("AppIcon-NeonNight"), Some("AppIcon-NeonNight")),
        IconStep::Keep
    );
    assert_eq!(dock_icon_name("AppIcon-LookGold"), "DockIcon-LookGold");

    assert_eq!(
        SupporterIcon::ALL.map(SupporterIcon::raw),
        [
            "AppIcon-Heart",
            "AppIcon-Aurora",
            "AppIcon-Gold",
            "AppIcon-Light",
            "AppIcon-Night",
            "AppIcon-Coffee"
        ]
    );
    assert_eq!(
        SupporterIcon::ALL.map(SupporterIcon::name_key),
        ["Herz", "Aurora", "Gold", "Hell", "Nacht", "Kaffee"]
    );
    assert_eq!(
        SupporterIcon::from_raw("AppIcon-Night"),
        Some(SupporterIcon::Night)
    );
    assert_eq!(SupporterIcon::from_raw("AppIcon-Halloween"), None);
}
