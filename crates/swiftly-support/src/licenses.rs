//! Open-source licence data: the typed list read from `LICENSES/components.json`, the one file
//! the licence pages and `THIRD-PARTY-NOTICES.md` come from
//! (`Sources/Shared/Licenses.swift`, `Werkzeuge/licenses-generate.py`). Bytes in, typed list
//! out; the host reads the file from its bundle.

use serde::Deserialize;

/// One component (`LicenseComponent`).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct LicenseComponent {
    /// Stable id.
    pub id: String,
    /// Display name.
    pub name: String,
    /// Version text.
    pub version: String,
    /// SPDX identifier.
    pub spdx: String,
    /// Copyright holder.
    #[serde(rename = "urheber")]
    pub author: String,
    /// Source URL.
    #[serde(rename = "quelle")]
    pub source: String,
    /// Platforms the component ships on (`ios`, `windows`, ...).
    #[serde(rename = "plattformen")]
    pub platforms: Vec<String>,
    /// File names of the licence texts under `LICENSES/`.
    #[serde(rename = "texte")]
    pub texts: Vec<String>,
    /// Group the list shows it under.
    #[serde(rename = "gruppe")]
    pub group: String,
    /// An optional note.
    #[serde(rename = "notiz", default)]
    pub note: Option<String>,
}

/// A titled section of the written offer.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct LicenseSection {
    /// Title.
    #[serde(rename = "titel")]
    pub title: String,
    /// Paragraphs.
    #[serde(rename = "absaetze")]
    pub paragraphs: Vec<String>,
}

/// Sources and written offer under LGPL-2.1 section 6.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct LicenseOffering {
    /// Title.
    #[serde(rename = "titel")]
    pub title: String,
    /// One-line summary.
    #[serde(rename = "kurz")]
    pub short: String,
    /// Contact address.
    #[serde(rename = "kontakt")]
    pub contact: String,
    /// The sections.
    #[serde(rename = "abschnitte")]
    pub sections: Vec<LicenseSection>,
}

/// The whole file.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct LicenseData {
    /// Schema number.
    pub schema: i64,
    /// The written offer.
    #[serde(rename = "angebot")]
    pub offering: LicenseOffering,
    /// The components, in file order.
    #[serde(rename = "bausteine")]
    pub components: Vec<LicenseComponent>,
}

impl LicenseData {
    /// Reads `components.json`; `None` if it does not parse.
    pub fn parse(json: &[u8]) -> Option<Self> {
        serde_json::from_slice(json).ok()
    }

    /// The components that ship on a platform (`ios`, `ipados`, `macos`, `tvos`, `android`,
    /// `linux`, `windows`).
    pub fn for_platform<'a>(
        &'a self,
        platform: &'a str,
    ) -> impl Iterator<Item = &'a LicenseComponent> {
        self.components
            .iter()
            .filter(move |c| c.platforms.iter().any(|p| p == platform))
    }
}
