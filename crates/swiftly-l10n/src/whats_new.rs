//! **"What's new": one sheet after an update, filled from one JSON per version**
//! (`WhatsNew.swift`). Shape and rules: `Notizen/Supporter/WHATS-NEW-SYSTEM.md`.

use serde::Deserialize;

/// A text in both languages of the app.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct WhatsNewText {
    /// English.
    pub en: String,
    /// German.
    pub de: String,
}

impl WhatsNewText {
    /// German for a German device, English for everyone else (the app's fallback; the files
    /// carry no Russian).
    pub fn localized(&self, language: &str) -> &str {
        if language.starts_with("de") {
            &self.de
        } else {
            &self.en
        }
    }
}

/// One line of the sheet.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct WhatsNewItem {
    /// An SF Symbol name.
    pub symbol: String,
    /// Headline.
    pub title: WhatsNewText,
    /// Optional second line.
    pub detail: Option<WhatsNewText>,
}

/// The look of the sheet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WhatsNewVariant {
    /// Plain list.
    Standard,
    /// One feature in the lead.
    Feature,
    /// With a gift module.
    Gift,
    /// Looks.
    Looks,
}

/// An extra block (`gift` today).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct WhatsNewModule {
    /// Module type.
    #[serde(rename = "type")]
    pub kind: String,
    /// The look a gift offers.
    #[serde(rename = "lookId")]
    pub look_id: Option<String>,
}

/// The main button: label is `continue`, `try`, `grab` or `tryLook`; action is `dismiss`,
/// `open:<target>` or `applyLook:<id>`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct WhatsNewPrimary {
    /// Label key.
    pub label: String,
    /// Action.
    pub action: String,
}

/// The file shipped for one version.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct WhatsNewEntry {
    /// App version.
    pub version: String,
    /// Look of the sheet.
    pub variant: WhatsNewVariant,
    /// Title.
    pub title: WhatsNewText,
    /// Three to five lines.
    pub items: Vec<WhatsNewItem>,
    /// Extra block.
    pub module: Option<WhatsNewModule>,
    /// Main button.
    pub primary: WhatsNewPrimary,
    /// A draft is never shown.
    pub draft: Option<bool>,
}

impl WhatsNewEntry {
    /// Decodes a file; `None` for broken JSON, a draft, or not 3 to 5 items.
    pub fn decoded(data: &[u8]) -> Option<Self> {
        let e: Self = serde_json::from_slice(data).ok()?;
        (e.draft != Some(true) && (3..=5).contains(&e.items.len())).then_some(e)
    }

    /// The look id of the gift this sheet offers, if it has a gift module.
    pub fn gift_look_id(&self) -> Option<&str> {
        let m = self.module.as_ref()?;
        (m.kind == "gift").then_some(())?;
        m.look_id.as_deref()
    }
}

/// Whether the sheet is due.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WhatsNewDecision {
    /// Fresh install or nothing new: store the version, show nothing.
    MarkSeen,
    /// After an update with a file for this version.
    Show,
    /// Seen already.
    Nothing,
}

/// Where the last seen version is stored.
pub const LAST_SEEN_KEY: &str = "whatsnew.lastSeen";

/// `lastSeen` is `None` on a fresh install and on the first update that brings this sheet;
/// `used_before` tells those two apart (the app ran before with older records).
pub fn decide(
    last_seen: Option<&str>,
    used_before: bool,
    current: &str,
    has_entry: bool,
) -> WhatsNewDecision {
    match last_seen {
        Some(seen) if !is_newer(current, seen) => return WhatsNewDecision::Nothing,
        None if !used_before => return WhatsNewDecision::MarkSeen,
        _ => {}
    }
    if has_entry {
        WhatsNewDecision::Show
    } else {
        WhatsNewDecision::MarkSeen
    }
}

/// Compares by number parts: 1.0.10 is newer than 1.0.9 (`VersionComparison.newer`).
pub fn is_newer(version: &str, than: &str) -> bool {
    crate::version_number::newer(version, than, None, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    // The real file of 1.0.8 (Resources/whatsnew/1.0.8.json).
    const REAL: &str = r#"{
      "version": "1.0.8", "variant": "gift",
      "title": { "en": "A Halloween look, on the house", "de": "Ein Halloween-Look, geschenkt" },
      "items": [
        { "symbol": "paintpalette", "title": { "en": "Orange instead of turquoise", "de": "Orange statt Türkis" },
          "detail": { "en": "Accent", "de": "Akzent" } },
        { "symbol": "app", "title": { "en": "An app icon to match", "de": "Ein App-Icon dazu" } },
        { "symbol": "arrow.uturn.backward", "title": { "en": "Back", "de": "Zurück" } } ],
      "module": { "type": "gift", "lookId": "halloween" },
      "primary": { "label": "grab", "action": "applyLook:halloween" } }"#;

    #[test]
    fn real_file_decodes() {
        let e = WhatsNewEntry::decoded(REAL.as_bytes()).expect("entry");
        assert_eq!(e.variant, WhatsNewVariant::Gift);
        assert_eq!(e.items.len(), 3);
        assert_eq!(e.gift_look_id(), Some("halloween"));
        assert_eq!(e.primary.action, "applyLook:halloween");
        assert_eq!(e.title.localized("de-DE"), "Ein Halloween-Look, geschenkt");
        assert_eq!(e.title.localized("ru"), "A Halloween look, on the house");
        assert!(e.items[1].detail.is_none());
    }

    #[test]
    fn drafts_broken_and_wrong_counts_are_never_shown() {
        assert!(
            WhatsNewEntry::decoded(
                REAL.replace("\"version\"", "\"draft\": true, \"version\"")
                    .as_bytes()
            )
            .is_none()
        );
        assert!(WhatsNewEntry::decoded(b"kein JSON").is_none());
        let two = r#"{"version":"1","variant":"standard","title":{"en":"a","de":"a"},"items":[
          {"symbol":"s","title":{"en":"a","de":"a"}},{"symbol":"s","title":{"en":"a","de":"a"}}],
          "primary":{"label":"continue","action":"dismiss"}}"#;
        assert!(WhatsNewEntry::decoded(two.as_bytes()).is_none());
    }

    #[test]
    fn version_compare_by_number_parts() {
        assert!(is_newer("1.0.10", "1.0.9"));
        assert!(!is_newer("1.0.9", "1.0.10"));
        assert!(!is_newer("1.1", "1.1.0"));
        assert!(is_newer("1.1.1", "1.1"));
        assert!(is_newer("2", "1.9.9"));
    }

    #[test]
    fn decide_rules() {
        use WhatsNewDecision::*;
        assert_eq!(decide(None, false, "1.2", true), MarkSeen); // fresh install
        assert_eq!(decide(None, true, "1.2", true), Show); // first update with the sheet
        assert_eq!(decide(None, true, "1.2", false), MarkSeen);
        assert_eq!(decide(Some("1.1"), true, "1.2", true), Show);
        assert_eq!(decide(Some("1.1"), true, "1.2", false), MarkSeen);
        assert_eq!(decide(Some("1.2"), true, "1.2", true), Nothing);
        assert_eq!(decide(Some("1.3"), true, "1.2", true), Nothing);
        assert_eq!(LAST_SEEN_KEY, "whatsnew.lastSeen");
    }
}
