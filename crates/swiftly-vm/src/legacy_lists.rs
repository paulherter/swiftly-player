#![allow(missing_docs)]
//! The settings lists of the old Android facade (`Kern.bitrateLevels`, `span`, `languages`, `bufferLevels`) as the JSON the
//! Compose pickers read.

use serde_json::{Value, json};
use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::playback_selection::{BITRATE_LEVELS, SPAN_LEVELS, language_selection_all};

/// `Kern.bitrateLevels`: `[{"wert","text"}]`, 0 is "Unlimited".
pub fn bitrate_levels(locale: Locale) -> String {
    let t = Translator::new(locale);
    Value::Array(
        BITRATE_LEVELS
            .iter()
            .map(|&v| {
                let text = if v <= 0 {
                    t.t("Unbegrenzt")
                } else {
                    t.t_args("%lld Mbit/s", &[Arg::Int(v)])
                };
                json!({"wert": v.to_string(), "text": text})
            })
            .collect(),
    )
    .to_string()
}

/// `Kern.span`: the skip lengths in seconds.
pub fn span() -> String {
    json!(SPAN_LEVELS).to_string()
}

/// `Kern.languages`: with an empty label "Like the file", otherwise that label as the first entry.
pub fn languages(from: &str, locale: Locale) -> String {
    let label = if from.is_empty() {
        Translator::new(locale).t("Wie die Datei")
    } else {
        from.to_owned()
    };
    Value::Array(
        language_selection_all(&label)
            .into_iter()
            .map(|l| json!({"wert": l.value, "text": l.name}))
            .collect(),
    )
    .to_string()
}

/// `Kern.bufferLevels`: `[{"wert","text","netz"?}]`.
pub fn buffer_levels(locale: Locale) -> String {
    let t = Translator::new(locale);
    Value::Array(
        BufferLevel::ALL
            .iter()
            .map(|l| {
                let text = t.t(match l {
                    BufferLevel::Normal => "Normal",
                    BufferLevel::Bad => "Schlechte Verbindung",
                    BufferLevel::VeryBad => "Sehr schlechte Verbindung",
                });
                let mut o = serde_json::Map::new();
                o.insert("wert".into(), l.raw_value().into());
                o.insert("text".into(), text.into());
                if let Some(n) = l.network_lead_milliseconds() {
                    o.insert("netz".into(), n.into());
                }
                Value::Object(o)
            })
            .collect(),
    )
    .to_string()
}
