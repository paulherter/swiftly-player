//! The looks calls of the old Android facade (`Kern.looks*`, `Android/core/.../Looks.swift`) from the core, with the
//! same JSON answers. Stateless like the old ones: the try-on state travels as JSON between the calls. Each answer is
//! compared with the Swift one by the golden tests (`lk-*`).

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};
use swiftly_support::Calendar;
use swiftly_support::gift::{
    BatBlock, EffectContext, EffectPage, GiftContext, LookEffects, LookGift, LookProfileEntry,
};
use swiftly_support::look::{Look, LookAccent, LookColor, LookGlow, LookSelection};
use swiftly_support::try_on::{KeepResult, LookTryOn};

fn css(c: LookColor) -> Value {
    Value::String(c.css())
}

fn glow_word(g: LookGlow) -> Value {
    serde_json::to_value(g).unwrap_or(Value::Null)
}

fn accent_json(a: &LookAccent) -> Value {
    let mut o = Map::new();
    o.insert("id".into(), json!(a.id));
    o.insert("main".into(), css(a.main));
    o.insert("light".into(), css(a.light));
    o.insert("quiet".into(), css(a.quiet));
    o.insert("on".into(), css(a.on));
    if let Some(w) = a.warning {
        o.insert("warning".into(), css(w));
    }
    Value::Object(o)
}

fn look_json(l: &Look) -> Value {
    let mut o = Map::new();
    o.insert("id".into(), json!(l.id));
    o.insert("nameKey".into(), json!(l.name_key));
    o.insert("accent".into(), accent_json(&l.accent));
    o.insert("glowColor".into(), css(l.glow_color));
    o.insert("defaultGlow".into(), glow_word(l.default_glow));
    o.insert(
        "logoGradient".into(),
        Value::Array(l.logo_gradient.iter().map(|c| css(*c)).collect()),
    );
    if let Some(t) = l.glow_tint() {
        o.insert("glowTint".into(), css(t));
    }
    if let Some(i) = l.icon_name {
        o.insert("iconName".into(), json!(i));
    }
    o.insert("isGift".into(), json!(l.is_gift));
    if let Some(s) = l.availability {
        o.insert(
            "season".into(),
            json!({"id": s.id, "fromMonth": s.from.month, "fromDay": s.from.day, "toMonth": s.to.month, "toDay": s.to.day}),
        );
    }
    Value::Object(o)
}

fn palette_json(s: &LookSelection) -> Value {
    let p = s.palette();
    let mut o = Map::new();
    o.insert("look".into(), json!(p.look.id));
    o.insert("accent".into(), accent_json(&p.accent));
    o.insert("glow".into(), glow_word(p.glow));
    o.insert("glowOpacity".into(), json!(p.glow.opacity()));
    o.insert("glowColor".into(), css(p.glow_color()));
    if let Some(t) = p.glow_tint() {
        o.insert("glowTint".into(), css(t));
    }
    o.insert(
        "logoGradient".into(),
        Value::Array(p.look.logo_gradient.iter().map(|c| css(*c)).collect()),
    );
    o.insert("markColor".into(), css(p.mark_color()));
    if let Some(i) = p.icon_name {
        o.insert("iconName".into(), json!(i));
    }
    Value::Object(o)
}

fn selection_of(json: &str) -> LookSelection {
    LookSelection::decoded((!json.is_empty()).then_some(json.as_bytes()))
}

fn selection_text(s: &LookSelection) -> String {
    String::from_utf8(s.encoded()).unwrap_or_else(|_| "{}".into())
}

fn selection_value(s: &LookSelection) -> Value {
    serde_json::to_value(s).unwrap_or(Value::Null)
}

fn ids(json: &str) -> BTreeSet<String> {
    serde_json::from_str::<Vec<String>>(json)
        .map(|v| v.into_iter().collect())
        .unwrap_or_default()
}

/// The device clock in seconds, from epoch milliseconds.
fn secs(ms: i64) -> f64 {
    ms as f64 / 1000.0
}

/// Every look, the accent dots and the glow strengths (`Kern.looksCatalog`).
#[uniffi::export]
pub fn legacy_looks_catalog() -> String {
    let glows: Map<String, Value> = [LookGlow::Off, LookGlow::Soft, LookGlow::Bright]
        .into_iter()
        .map(|g| {
            (
                glow_word(g).as_str().unwrap_or_default().to_owned(),
                json!(g.opacity()),
            )
        })
        .collect();
    json!({
        "looks": Look::ALL.iter().map(look_json).collect::<Vec<_>>(),
        "accents": LookAccent::ALL.iter().map(accent_json).collect::<Vec<_>>(),
        "glows": glows,
    })
    .to_string()
}

/// A stored selection read the way the package reads it (`Kern.looksNormalize`).
#[uniffi::export]
pub fn legacy_looks_normalize(selection: String) -> String {
    selection_text(&selection_of(&selection))
}

/// The finished values for a selection (`Kern.looksPalette`).
#[uniffi::export]
pub fn legacy_looks_palette(selection: String) -> String {
    palette_json(&selection_of(&selection)).to_string()
}

/// A selection of another look, clean of the old overrides (`Kern.looksSwitch`).
#[uniffi::export]
pub fn legacy_looks_switch(look_id: String) -> String {
    selection_text(&LookSelection::original().switching(&Look::with_id(&look_id)))
}

fn tryon_state(
    state: &str,
) -> (
    LookSelection,
    Option<LookSelection>,
    Option<LookSelection>,
    bool,
    BTreeSet<String>,
) {
    let fresh = (
        LookSelection::original(),
        None,
        None,
        false,
        BTreeSet::new(),
    );
    let Ok(Value::Object(o)) = serde_json::from_str::<Value>(state) else {
        return fresh;
    };
    let sel = |k: &str| {
        o.get(k)
            .and_then(|v| serde_json::from_value::<LookSelection>(v.clone()).ok())
    };
    let (Some(saved), Some(supporter), Some(owned)) = (
        sel("saved"),
        o.get("supporter").and_then(Value::as_bool),
        o.get("owned")
            .and_then(|v| serde_json::from_value::<Vec<String>>(v.clone()).ok()),
    ) else {
        return fresh;
    };
    (
        saved,
        sel("preview"),
        sel("pending"),
        supporter,
        owned.into_iter().collect(),
    )
}

/// `LookTryOn` without a held object (`Kern.looksTryOn`): `op` is begin, tryOn, end, keep, sheetClosed, purchase,
/// supporter, choose, claim, reset or show.
#[uniffi::export]
pub fn legacy_looks_try_on(state: String, op: String, arg: String) -> String {
    let (saved, preview, pending, supporter, owned) = tryon_state(&state);
    let mut t = LookTryOn::new(saved, supporter, owned);
    if let Some(p) = &preview {
        t.begin();
        t.try_on(p.clone());
    }
    if let (Some(pend), Some(p), false) = (&pending, &preview, supporter) {
        t.try_on(pend.clone());
        let _ = t.keep();
        t.try_on(p.clone());
    }
    let mut result = String::new();
    let mut accepted = true;
    match op.as_str() {
        "begin" => t.begin(),
        "tryOn" => t.try_on(selection_of(&arg)),
        "end" => t.end(),
        "keep" => {
            result = match t.keep() {
                KeepResult::Kept => "kept",
                KeepResult::NeedsSupport => "needsSupport",
                KeepResult::Nothing => "nothing",
            }
            .into();
        }
        "sheetClosed" => t.support_sheet_closed(),
        "purchase" => {
            result = t
                .purchase_completed()
                .map(|s| s.look_id)
                .unwrap_or_default()
        }
        "supporter" => t.set_supporter(arg == "1"),
        "choose" => accepted = t.choose(selection_of(&arg)),
        "claim" => accepted = t.claim(&Look::with_id(&arg)).is_some(),
        "reset" => t.reset(),
        _ => {}
    }
    let shown = t.shown();
    let mut state = Map::new();
    state.insert("saved".into(), selection_value(t.saved()));
    if let Some(p) = t.preview() {
        state.insert("preview".into(), selection_value(p));
    }
    if let Some(p) = t.pending_keep() {
        state.insert("pending".into(), selection_value(p));
    }
    state.insert("supporter".into(), json!(t.is_supporter()));
    state.insert("owned".into(), json!(t.owned().iter().collect::<Vec<_>>()));
    json!({
        "state": state, "shown": selection_value(&shown), "palette": palette_json(&shown),
        "result": result, "accepted": accepted,
    })
    .to_string()
}

/// The id of the gift whose pop-up is due, or empty (`Kern.looksGiftDue`).
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn legacy_looks_gift_due(
    now_ms: i64,
    home_ready: bool,
    playing: bool,
    asked_this_session: bool,
    seconds_on_home: f64,
    owned: String,
    offered: String,
    utc_offset: i64,
) -> String {
    let context = GiftContext {
        now: secs(now_ms),
        home_ready,
        playing,
        asked_this_session,
        seconds_on_home,
        owned: ids(&owned),
        offered: ids(&offered),
    };
    LookGift::due(&context, &Look::ALL, Calendar::fixed(utc_offset))
        .map(|l| l.id.to_owned())
        .unwrap_or_default()
}

/// The stored id of the offer for a look today, or empty outside its window (`Kern.looksGiftOfferID`).
#[uniffi::export]
pub fn legacy_looks_gift_offer_id(look_id: String, now_ms: i64, utc_offset: i64) -> String {
    LookGift::offer_id(
        &Look::with_id(&look_id),
        secs(now_ms),
        Calendar::fixed(utc_offset),
    )
    .unwrap_or_default()
}

/// Whether the gift can be picked up now (`Kern.looksGiftAvailable`).
#[uniffi::export]
pub fn legacy_looks_gift_available(
    look_id: String,
    owned: String,
    now_ms: i64,
    utc_offset: i64,
) -> bool {
    LookGift::is_available(
        &Look::with_id(&look_id),
        &ids(&owned),
        secs(now_ms),
        Calendar::fixed(utc_offset),
    )
}

/// Whether any gift can be picked up now (`Kern.looksAnyGiftAvailable`).
#[uniffi::export]
pub fn legacy_looks_any_gift_available(owned: String, now_ms: i64, utc_offset: i64) -> bool {
    let owned = ids(&owned);
    Look::ALL.iter().any(|l| {
        l.is_gift && LookGift::is_available(l, &owned, secs(now_ms), Calendar::fixed(utc_offset))
    })
}

/// `{"home","profile","batBlock"}` for the look shown (`Kern.looksEffects`).
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn legacy_looks_effects(
    look_id: String,
    now_ms: i64,
    switch_on: bool,
    playing: bool,
    reduce_motion: bool,
    low_power: bool,
    foreground: bool,
    utc_offset: i64,
) -> String {
    let context = EffectContext {
        look: Look::with_id(&look_id),
        now: secs(now_ms),
        switch_on,
        playing,
        reduce_motion,
        low_power,
        foreground,
    };
    let calendar = Calendar::fixed(utc_offset);
    let block = match LookEffects::bat_block(EffectPage::Home, &context, calendar) {
        None => "",
        Some(BatBlock::WrongPage) => "wrongPage",
        Some(BatBlock::SwitchOff) => "switchOff",
        Some(BatBlock::Playing) => "playing",
        Some(BatBlock::OutsideWindow) => "outsideWindow",
        Some(BatBlock::ReduceMotion) => "reduceMotion",
        Some(BatBlock::LowPower) => "lowPower",
        Some(BatBlock::Background) => "background",
    };
    json!({
        "home": LookEffects::details(EffectPage::Home, &context, calendar),
        "profile": LookEffects::details(EffectPage::Profile, &context, calendar),
        "batBlock": block,
    })
    .to_string()
}

/// `{"entry":"none|teaser|current","showsRow"}` (`Kern.looksProfileEntry`).
#[uniffi::export]
pub fn legacy_looks_profile_entry(
    supporter_features: bool,
    is_supporter: bool,
    owns_look: bool,
    gift_available: bool,
) -> String {
    let entry = LookProfileEntry::at(supporter_features, is_supporter, owns_look);
    let name = match entry {
        LookProfileEntry::None => "none",
        LookProfileEntry::Teaser => "teaser",
        LookProfileEntry::Current => "current",
    };
    json!({"entry": name, "showsRow": LookProfileEntry::shows_looks_row(entry, gift_available)})
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Value {
        serde_json::from_str(s).expect("valid JSON")
    }

    #[test]
    fn catalog_lists_looks_accents_and_glows() {
        let c = parse(&legacy_looks_catalog());
        assert_eq!(c["looks"].as_array().unwrap().len(), Look::ALL.len());
        assert!(!c["accents"].as_array().unwrap().is_empty());
        assert_eq!(c["glows"].as_object().unwrap().len(), 3);
    }

    #[test]
    fn broken_selections_fall_back_to_the_original() {
        let original = legacy_looks_normalize(String::new());
        assert_eq!(legacy_looks_normalize("not json".into()), original);
        assert_eq!(
            legacy_looks_normalize(original.clone()),
            original,
            "normalising is stable"
        );
        assert!(parse(&legacy_looks_palette("{".into())).is_object());
        // An unknown look id switches to something valid, never a panic.
        assert!(!legacy_looks_switch("no-such-look".into()).is_empty());
        for l in Look::ALL.iter() {
            assert!(!legacy_looks_switch(l.id.to_owned()).is_empty());
        }
    }

    #[test]
    fn try_on_walks_the_support_flow() {
        let gift_free = Look::ALL
            .iter()
            .find(|l| !l.is_gift && l.id != "original")
            .map(|l| l.id.to_owned());
        let fresh = "{}".to_string();
        // Every op runs on a fresh and a broken state without a panic and answers a state.
        for op in [
            "begin",
            "tryOn",
            "end",
            "keep",
            "sheetClosed",
            "purchase",
            "supporter",
            "choose",
            "claim",
            "reset",
            "show",
            "bogus",
        ] {
            for state in [&fresh, "garbage"] {
                let r = parse(&legacy_looks_try_on(
                    state.to_string(),
                    op.into(),
                    "1".into(),
                ));
                assert!(
                    r["state"].is_object()
                        && r["palette"].is_object()
                        && r["accepted"].is_boolean(),
                    "{op}"
                );
            }
        }
        let Some(id) = gift_free else { return };
        let arg = legacy_looks_switch(id.clone());
        let begun = parse(&legacy_looks_try_on(
            fresh.clone(),
            "begin".into(),
            String::new(),
        ));
        let r = parse(&legacy_looks_try_on(
            begun["state"].to_string(),
            "tryOn".into(),
            arg.clone(),
        ));
        let state = r["state"].to_string();
        let kept = parse(&legacy_looks_try_on(
            state.clone(),
            "keep".into(),
            String::new(),
        ));
        assert!(["kept", "needsSupport", "nothing"].contains(&kept["result"].as_str().unwrap()));
        // The preview survives a round trip through the stored state and ends cleanly.
        let ended = parse(&legacy_looks_try_on(state, "end".into(), String::new()));
        assert!(
            ended["state"].get("preview").is_none(),
            "ending a try-on drops the preview"
        );
    }

    #[test]
    fn gifts_follow_the_calendar() {
        let now = 1_767_225_600_000_i64; // 2026-01-01 00:00 UTC
        for off in [0, 3600, -18000] {
            let any = legacy_looks_any_gift_available(String::new(), now, off);
            let due = legacy_looks_gift_due(
                now,
                true,
                false,
                false,
                60.0,
                String::new(),
                String::new(),
                off,
            );
            if !due.is_empty() {
                assert!(any, "a gift that is due is also available");
            }
            // Never while playing, before home is ready or when already asked.
            assert_eq!(
                legacy_looks_gift_due(
                    now,
                    true,
                    true,
                    false,
                    60.0,
                    String::new(),
                    String::new(),
                    off
                ),
                ""
            );
            assert_eq!(
                legacy_looks_gift_due(
                    now,
                    false,
                    false,
                    false,
                    60.0,
                    String::new(),
                    String::new(),
                    off
                ),
                ""
            );
            assert_eq!(
                legacy_looks_gift_due(
                    now,
                    true,
                    false,
                    true,
                    60.0,
                    String::new(),
                    String::new(),
                    off
                ),
                ""
            );
        }
        for l in Look::ALL.iter() {
            let offer = legacy_looks_gift_offer_id(l.id.to_owned(), now, 0);
            let avail = legacy_looks_gift_available(l.id.to_owned(), "[]".into(), now, 0);
            // An offer id is a stable text for the day; asking twice gives the same answer.
            assert_eq!(offer, legacy_looks_gift_offer_id(l.id.to_owned(), now, 0));
            let _ = avail;
        }
        // A broken owned list reads as "owns nothing".
        assert_eq!(
            legacy_looks_any_gift_available("oops".into(), now, 0),
            legacy_looks_any_gift_available("[]".into(), now, 0)
        );
    }

    #[test]
    fn effects_report_why_the_bats_stay_away() {
        let now = 1_767_225_600_000_i64;
        let look = Look::ALL
            .iter()
            .find(|l| l.is_gift)
            .map_or("original", |l| l.id)
            .to_owned();
        let block = |switch_on, playing, reduce, low, fg| {
            parse(&legacy_looks_effects(
                look.clone(),
                now,
                switch_on,
                playing,
                reduce,
                low,
                fg,
                0,
            ))["batBlock"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        assert!(
            ["switchOff", "outsideWindow", "wrongPage", ""]
                .contains(&block(false, false, false, false, true).as_str())
        );
        assert_ne!(
            block(true, true, false, false, true),
            "",
            "never while playing"
        );
        assert_ne!(block(true, false, true, false, true), "");
        assert_ne!(block(true, false, false, true, true), "");
        assert_ne!(block(true, false, false, false, false), "");
        let r = parse(&legacy_looks_effects(
            "nope".into(),
            now,
            true,
            false,
            false,
            false,
            true,
            0,
        ));
        assert!(r.get("home").is_some() && r.get("profile").is_some());
    }

    #[test]
    fn profile_entry_rows() {
        for (feat, sup, own, gift) in [
            (false, false, false, false),
            (true, false, false, true),
            (true, true, true, false),
            (true, true, false, true),
        ] {
            let r = parse(&legacy_looks_profile_entry(feat, sup, own, gift));
            assert!(["none", "teaser", "current"].contains(&r["entry"].as_str().unwrap()));
            assert!(r["showsRow"].is_boolean());
        }
    }
}
