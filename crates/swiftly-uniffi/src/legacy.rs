//! Pure functions of the old Android facade (`Kern`), answered with the same JSON strings so the Compose code
//! does not change while the Swift core goes away. Each one is compared with the Swift answer by a Kotlin test
//! (`Android/golden`).

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use swiftly_library::refresh::due_return;
use swiftly_library::{StartRail, StartRailsEpisode};

/// The home rows in the current order, only those matching the new-additions setting: `[{"text","wert"}]`
/// (`Kern.startRails`; `text` is the German list name, the host translates it).
#[uniffi::export]
pub fn legacy_start_rails(stored: Vec<String>, disconnected: bool) -> String {
    let rows: Vec<Value> = StartRailsEpisode::applicable(&stored)
        .into_iter()
        .filter(|r| r.fits(disconnected))
        .map(|r| json!({"wert": r.raw_value(), "text": r.lists_name()}))
        .collect();
    Value::Array(rows).to_string()
}

/// A row moved by `step` positions among the visible ones: the new stored order (`Kern.startRailShifted`).
#[uniffi::export]
pub fn legacy_start_rail_shifted(
    was: String,
    step: i64,
    stored: Vec<String>,
    disconnected: bool,
) -> String {
    let order = match StartRail::from_raw(&was) {
        Some(rail) => StartRailsEpisode::shifted(rail, step, &stored, disconnected),
        None => stored,
    };
    json!(order).to_string()
}

/// Reload the home page after a pause: `last_ms` milliseconds since 1970, 0 means never loaded
/// (`Kern.refreshDue`).
#[uniffi::export]
pub fn legacy_refresh_due(last_ms: i64) -> bool {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    due_return((last_ms > 0).then(|| last_ms as f64 / 1000.0), now)
}

// ---- subtitle look ----------------------------------------------------------------------------

fn look_of(json: &str) -> swiftly_support::subtitle::SubtitleLook {
    swiftly_support::subtitle::SubtitleLook::read((!json.is_empty()).then_some(json.as_bytes()))
}

fn look_text(look: &swiftly_support::subtitle::SubtitleLook) -> String {
    String::from_utf8(look.encoded()).unwrap_or_else(|_| "{}".into())
}

/// The stored look in its stable form (`Kern.subtitleLookNormalise`).
#[uniffi::export]
pub fn legacy_subtitle_look_normalise(json: String) -> String {
    look_text(&look_of(&json))
}

/// The default look as text (`Kern.subtitleLookStandard`).
#[uniffi::export]
pub fn legacy_subtitle_look_standard() -> String {
    look_text(&swiftly_support::subtitle::SubtitleLook::STANDARD)
}

/// One field changed; an unknown field or word leaves the look as it was (`Kern.subtitleLookChange`).
#[uniffi::export]
pub fn legacy_subtitle_look_change(json: String, field: String, value: String) -> String {
    use serde_json::from_value;
    let mut look = look_of(&json);
    let word = || Value::String(value.clone());
    let on = value == "true";
    match field.as_str() {
        "size" => {
            if let Ok(v) = from_value(word()) {
                look.size = v
            }
        }
        "colour" => {
            if let Ok(v) = from_value(word()) {
                look.colour = v
            }
        }
        "outline" => {
            if let Ok(v) = from_value(word()) {
                look.outline = v
            }
        }
        "position" => {
            if let Ok(v) = from_value(word()) {
                look.position = v
            }
        }
        "shadow" => look.shadow = on,
        "background" => look.background = on,
        "keepFileStyle" => look.keep_file_style = on,
        _ => {}
    }
    look_text(&look)
}

/// Everything derived from a look as JSON for the preview and Media3 (`Kern.subtitleLookFacts`).
#[uniffi::export]
pub fn legacy_subtitle_look_facts(json: String, base_scale: f64) -> String {
    use swiftly_support::subtitle::{Outline, Position};
    let look = look_of(&json);
    let percent = look.text_scale_percent(base_scale);
    let word = |v: Value| v.as_str().unwrap_or_default().to_owned();
    json!({
        "size": word(json!(look.size)), "colour": word(json!(look.colour)),
        "outline": word(json!(look.outline)), "position": word(json!(look.position)),
        "shadow": look.shadow, "background": look.background, "keepFileStyle": look.keep_file_style,
        "raised": look.position == Position::Raised, "standard": look.is_standard(),
        "percent": percent, "rgb": look.colour.rgb(), "thickness": look.outline.thickness(),
        "edge": if look.outline != Outline::Off { "outline" } else if look.shadow { "shadow" } else { "none" },
        "fraction": 0.0625 * percent as f64 / 100.0,
        "bottomPadding": if look.position == Position::Raised { 0.15 } else { 0.08 },
    })
    .to_string()
}

// ---- own request headers ------------------------------------------------------------------------

fn headers_of(json: &str) -> Vec<swiftly_jellyfin::OwnHeader> {
    serde_json::from_str(json).unwrap_or_default()
}

/// Loads the table stored in the vault at start; empty or unreadable gives an empty table (`Kern.ownHeadersLoad`).
#[uniffi::export]
pub fn legacy_own_headers_load(panel: String) {
    swiftly_jellyfin::OwnHeaders::load((!panel.is_empty()).then_some(panel.as_str()));
}

/// The whole table for the vault, `"{}"` when nothing is set (`Kern.ownHeadersStore`).
#[uniffi::export]
pub fn legacy_own_headers_store() -> String {
    swiftly_jellyfin::OwnHeaders::store()
}

/// What is set for exactly this address: `[{"name","wert"}]` (`Kern.ownHeadersRegistered`).
#[uniffi::export]
pub fn legacy_own_headers_registered(address: String) -> String {
    let rows = swiftly_net::Url::parse(&address)
        .map(|u| swiftly_jellyfin::OwnHeaders::registered(&u))
        .unwrap_or_default();
    serde_json::to_string(&rows).unwrap_or_else(|_| "[]".into())
}

/// Sets (not stores) the headers of an address; an empty list removes it (`Kern.ownHeadersSet`).
#[uniffi::export]
pub fn legacy_own_headers_set(address: String, headers: String) {
    if let Ok(base) = swiftly_net::Url::parse(&address) {
        swiftly_jellyfin::OwnHeaders::set_down(&headers_of(&headers), &base);
    }
}

/// The headers for a request to this address as a JSON object, `{}` without an entry (`Kern.ownHeadersFields`).
#[uniffi::export]
pub fn legacy_own_headers_fields(address: String) -> String {
    let fields = swiftly_net::Url::parse(&address)
        .map(|u| swiftly_jellyfin::OwnHeaders::fields(&u))
        .unwrap_or_default();
    if fields.is_empty() {
        "{}".into()
    } else {
        serde_json::to_string(&fields).unwrap_or_else(|_| "{}".into())
    }
}

/// Through the same gate as when sending (`Kern.ownHeadersCleaned`).
#[uniffi::export]
pub fn legacy_own_headers_cleaned(headers: String) -> String {
    serde_json::to_string(&swiftly_jellyfin::OwnHeaders::cleaned(&headers_of(
        &headers,
    )))
    .unwrap_or_else(|_| "[]".into())
}

/// Names only, for the log; never the values (`Kern.ownHeadersNames`).
#[uniffi::export]
pub fn legacy_own_headers_names(address: String) -> String {
    match swiftly_net::Url::parse(&address) {
        Ok(u) => swiftly_jellyfin::OwnHeaders::names(&swiftly_jellyfin::OwnHeaders::registered(&u)),
        Err(_) => "keine".into(),
    }
}

/// Does Swiftly set this header itself (`Kern.headerLocked`)?
#[uniffi::export]
pub fn legacy_header_locked(name: String) -> bool {
    swiftly_jellyfin::OwnHeaders::is_locked(&name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rails_list_hides_rows_that_do_not_fit() {
        let all = legacy_start_rails(vec![], false);
        let split = legacy_start_rails(vec![], true);
        assert!(all.contains("weiterschauen") && split.contains("neueFilme"));
        assert_ne!(all, split);
    }

    #[test]
    fn shifting_an_unknown_row_keeps_the_order_and_never_loaded_is_due() {
        assert_eq!(
            legacy_start_rail_shifted("x".into(), 1, vec!["a".into()], false),
            r#"["a"]"#
        );
        assert!(legacy_refresh_due(0));
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        assert!(!legacy_refresh_due(now));
    }
}

/// `Kern.labels()`: `{"sortierung":[{"wert","text"}],"filter":[...]}` in the language of `locale`.
#[uniffi::export]
pub fn legacy_labels(locale: String) -> String {
    swiftly_vm::legacy_labels_json(swiftly_l10n::Locale::parse(&locale))
}

/// `Kern.savedGenres()`: the watchlist kinds `[{"wert","text"}]` in the language of `locale`.
#[uniffi::export]
pub fn legacy_saved_genres(locale: String) -> String {
    swiftly_vm::legacy_saved_genres_json(swiftly_l10n::Locale::parse(&locale))
}
