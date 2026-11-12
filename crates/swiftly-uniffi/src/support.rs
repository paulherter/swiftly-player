//! Pure helpers the host calls instead of its own copies: readable network errors, the
//! "What's new" decision and sheet, version comparison.

use std::time::Duration;

use swiftly_l10n::error_text::{readable_url_error, readable_url_error_system};
use swiftly_l10n::whats_new::{WhatsNewDecision, WhatsNewEntry, decide, is_newer};
use swiftly_l10n::{Locale, Translator};

/// A wait of `seconds` that never panics: `Duration::from_secs_f64` does for NaN, negative and
/// huge values, and a server-sent time can be any of them. NaN and negative give no wait, more
/// than a year is a year.
pub(crate) fn wait_duration(seconds: f64) -> Duration {
    const YEAR: f64 = 365.0 * 86_400.0;
    if seconds.is_nan() || seconds <= 0.0 {
        return Duration::ZERO;
    }
    Duration::from_secs_f64(seconds.min(YEAR))
}

/// The sentence for an `NSURLErrorDomain` code plus the system's English description (a
/// certificate cause wins over the code text).
#[uniffi::export]
pub fn readable_network_error(locale: String, code: i32, description: String) -> String {
    readable_url_error(&Translator::new(Locale::parse(&locale)), code, &description)
}

/// Like [`readable_network_error`] for Apple hosts: `description` is the system's own translated
/// `localizedDescription`, which the Swift app shows for a code without a sentence of its own.
#[uniffi::export]
pub fn readable_network_error_system(locale: String, code: i32, description: String) -> String {
    readable_url_error_system(&Translator::new(Locale::parse(&locale)), code, &description)
}

/// Whether `version` is newer than `than`, by number parts (1.0.10 is newer than 1.0.9).
#[uniffi::export]
pub fn version_is_newer(version: String, than: String) -> bool {
    is_newer(&version, &than)
}

/// What to do after a start.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WhatsNewAction {
    /// Store the version, show nothing.
    MarkSeen,
    /// Show the sheet.
    Show,
    /// Seen already.
    Nothing,
}

/// Whether the sheet is due. `entry_json` is the file for the current version, if the app has
/// one; a draft or a broken file counts as no file.
#[uniffi::export]
pub fn whats_new_decide(
    last_seen: Option<String>,
    used_before: bool,
    current: String,
    entry_json: Option<Vec<u8>>,
) -> WhatsNewAction {
    let has_entry = entry_json
        .as_deref()
        .and_then(WhatsNewEntry::decoded)
        .is_some();
    match decide(last_seen.as_deref(), used_before, &current, has_entry) {
        WhatsNewDecision::MarkSeen => WhatsNewAction::MarkSeen,
        WhatsNewDecision::Show => WhatsNewAction::Show,
        WhatsNewDecision::Nothing => WhatsNewAction::Nothing,
    }
}

/// One line of the sheet, in the device's language.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WhatsNewLine {
    /// An SF Symbol name.
    pub symbol: String,
    /// Headline.
    pub title: String,
    /// Optional second line.
    pub detail: Option<String>,
}

/// The sheet of one version, in the device's language.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WhatsNewSheet {
    /// App version.
    pub version: String,
    /// `standard`, `feature`, `gift` or `looks`.
    pub variant: String,
    /// Title.
    pub title: String,
    /// Three to five lines.
    pub lines: Vec<WhatsNewLine>,
    /// Label key of the main button (`continue`, `try`, `grab`, `tryLook`).
    pub primary_label: String,
    /// Action of the main button (`dismiss`, `open:<target>`, `applyLook:<id>`).
    pub primary_action: String,
    /// The look a gift offers.
    pub gift_look_id: Option<String>,
}

/// Reads the file of a version; `None` for broken JSON, a draft or not 3 to 5 lines.
#[uniffi::export]
pub fn whats_new_sheet(entry_json: Vec<u8>, language: String) -> Option<WhatsNewSheet> {
    let e = WhatsNewEntry::decoded(&entry_json)?;
    Some(WhatsNewSheet {
        gift_look_id: e.gift_look_id().map(str::to_owned),
        version: e.version.clone(),
        variant: format!("{:?}", e.variant).to_lowercase(),
        title: e.title.localized(&language).to_owned(),
        lines: e
            .items
            .iter()
            .map(|i| WhatsNewLine {
                symbol: i.symbol.clone(),
                title: i.title.localized(&language).to_owned(),
                detail: i.detail.as_ref().map(|d| d.localized(&language).to_owned()),
            })
            .collect(),
        primary_label: e.primary.label,
        primary_action: e.primary.action,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // F-cast-05: `Duration::from_secs_f64` panics on these.
    #[test]
    fn waits_never_panic_on_hostile_seconds() {
        for s in [f64::NAN, f64::NEG_INFINITY, -1.0, -0.0, 0.0] {
            assert_eq!(wait_duration(s), Duration::ZERO, "{s}");
        }
        for s in [f64::INFINITY, f64::MAX, 1e30, 1e19, u64::MAX as f64] {
            assert_eq!(wait_duration(s), Duration::from_secs(365 * 86_400), "{s}");
        }
        assert_eq!(wait_duration(1.5), Duration::from_millis(1500));
    }

    const FILE: &str = r#"{"version":"1.2.0","variant":"gift","title":{"en":"Hello","de":"Hallo"},
      "items":[{"symbol":"a","title":{"en":"One","de":"Eins"}},
               {"symbol":"b","title":{"en":"Two","de":"Zwei"},"detail":{"en":"d","de":"dd"}},
               {"symbol":"c","title":{"en":"Three","de":"Drei"}}],
      "module":{"type":"gift","lookId":"aurora"},
      "primary":{"label":"grab","action":"applyLook:aurora"}}"#;

    #[test]
    fn sheet_speaks_the_device_language() {
        let de = whats_new_sheet(FILE.as_bytes().to_vec(), "de-DE".into()).expect("sheet");
        assert_eq!(de.title, "Hallo");
        assert_eq!(de.lines[1].detail.as_deref(), Some("dd"));
        assert_eq!(de.gift_look_id.as_deref(), Some("aurora"));
        let ru = whats_new_sheet(FILE.as_bytes().to_vec(), "ru".into()).expect("sheet");
        assert_eq!(ru.title, "Hello");
        assert_eq!(ru.variant, "gift");
    }

    #[test]
    fn drafts_and_short_files_are_no_sheet() {
        let short = FILE.replacen(
            r#",
               {"symbol":"c","title":{"en":"Three","de":"Drei"}}"#,
            "",
            1,
        );
        assert!(whats_new_sheet(short.into_bytes(), "en".into()).is_none());
    }

    #[test]
    fn decision_follows_the_rules() {
        let file = Some(FILE.as_bytes().to_vec());
        assert_eq!(
            whats_new_decide(None, false, "1.2.0".into(), file.clone()),
            WhatsNewAction::MarkSeen
        );
        assert_eq!(
            whats_new_decide(None, true, "1.2.0".into(), file.clone()),
            WhatsNewAction::Show
        );
        assert_eq!(
            whats_new_decide(Some("1.2.0".into()), true, "1.2.0".into(), file.clone()),
            WhatsNewAction::Nothing
        );
        assert_eq!(
            whats_new_decide(Some("1.1.0".into()), true, "1.2.0".into(), None),
            WhatsNewAction::MarkSeen
        );
        assert!(version_is_newer("1.0.10".into(), "1.0.9".into()));
    }

    #[test]
    fn network_error_is_readable() {
        assert_eq!(
            readable_network_error("de".into(), -1001, String::new()),
            "Der Server hat nicht geantwortet."
        );
    }
}

/// What a checked supporter key says (feature `supporter-key`, direct builds only).
#[cfg(feature = "supporter-key")]
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SupporterLicense {
    pub app: u8,
    /// `"monthly"` or `"lifetime"`.
    pub plan: String,
    pub issued_at_ms: i64,
    pub expires_at_ms: Option<i64>,
    pub id: String,
    pub name: Option<String>,
    pub is_test: bool,
    pub is_legacy: bool,
}

/// Checks a pasted supporter key against the production key, expiry included. `Ok` is the licence,
/// `Err` the failure word (`badSignature`, `expired`, `wrongApp`, ...). Only in builds with the
/// `supporter-key` feature; the Play build does not export it.
#[cfg(feature = "supporter-key")]
#[uniffi::export]
pub fn supporter_key_verify(
    text: String,
    now_ms: i64,
) -> Result<SupporterLicense, crate::error::SupporterKeyError> {
    use swiftly_support::supporter_key::verify_now;
    match verify_now(&text, now_ms) {
        Ok(l) => Ok(SupporterLicense {
            app: l.app,
            plan: l.plan.to_owned(),
            issued_at_ms: l.issued_at_ms,
            expires_at_ms: l.expires_at_ms,
            id: l.id,
            name: l.name,
            is_test: l.is_test,
            is_legacy: l.is_legacy,
        }),
        Err(f) => Err(crate::error::SupporterKeyError::Refused {
            failure: f.as_str().to_owned(),
        }),
    }
}
