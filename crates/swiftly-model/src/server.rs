use serde::{Deserialize, Deserializer, Serialize};

use crate::item::Item;
use crate::lenient::Lenient;

/// `/System/Info/Public` (JellyfinKit/Models.swift:5).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct PublicSystemInfo {
    /// Display name of the server.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_name: Option<String>,
    /// Server version, `10.x` on Jellyfin, `4.x` on Emby.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Server id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// "Jellyfin Server" on Jellyfin; Emby does not send it (Models.swift:9).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub product_name: Option<String>,
}

impl PublicSystemInfo {
    /// Is this answer a Jellyfin's? (Models.swift:29)
    ///
    /// Jellyfin names itself; where it does not, its version starts at 10,
    /// while Emby's is 4.x. Like Swift's `split(separator:)` empty pieces are
    /// skipped before the first one is read.
    pub fn looks_like_jellyfin(&self) -> bool {
        if let Some(product) = &self.product_name {
            return product.to_lowercase().contains("jellyfin");
        }
        let major = self
            .version
            .as_deref()
            .and_then(|v| v.split('.').find(|p| !p.is_empty()))
            .and_then(|p| p.parse::<i64>().ok());
        major.is_some_and(|m| m >= 10)
    }
}

/// Sign-in answer (Models.swift:38).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AuthenticationResult {
    /// Session token.
    pub access_token: String,
    /// Server id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_id: Option<String>,
    /// The signed-in user.
    pub user: User,
}

/// A server user (Models.swift:50).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct User {
    /// User id.
    pub id: String,
    /// User name.
    pub name: String,
}

/// A page of items (Models.swift:62).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ItemsResponse {
    /// The readable items.
    pub items: Vec<Item>,
    /// Server total; the item count where the server omits it.
    pub total_record_count: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawItemsResponse {
    items: Option<Box<serde_json::value::RawValue>>,
    #[serde(default, deserialize_with = "crate::lenient::whole_number")]
    total_record_count: Option<i64>,
}

/// The entries of `Items`. Fast path: the whole array reads as `Item`s straight from the text
/// (no intermediate DOM, about 2.4x faster); only when one entry cannot be read the lenient path
/// runs, which skips exactly the unreadable entries. Both give the same list when every entry
/// is readable.
fn read_items<E: serde::de::Error>(raw: &serde_json::value::RawValue) -> Result<Vec<Item>, E> {
    match serde_json::from_str::<Vec<Item>>(raw.get()) {
        Ok(items) => Ok(items),
        Err(_) => serde_json::from_str::<Lenient<Item>>(raw.get())
            .map(|l| l.0)
            .map_err(E::custom),
    }
}

/// Decodes leniently (Models.swift:76-88): entries that cannot be read are
/// skipped, a missing `Items` is an empty list, a missing `TotalRecordCount`
/// is the number of items.
impl<'de> Deserialize<'de> for ItemsResponse {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = RawItemsResponse::deserialize(deserializer)?;
        let mut items = match &raw.items {
            Some(r) => read_items::<D::Error>(r)?,
            None => Vec::new(),
        };
        // The total stays the server's: paging offsets count its entries, not ours.
        let total = raw.total_record_count.unwrap_or(items.len() as i64);
        // A show whose files were deleted stays on the server with no seasons; it is not shown anywhere.
        items.retain(|i| !i.is_hollow_series());
        Ok(Self {
            items,
            total_record_count: total,
        })
    }
}

impl ItemsResponse {
    /// Memberwise initializer (Models.swift:71).
    pub fn new(items: Vec<Item>, total_record_count: i64) -> Self {
        Self {
            items,
            total_record_count,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(product: Option<&str>, version: Option<&str>) -> PublicSystemInfo {
        PublicSystemInfo {
            product_name: product.map(Into::into),
            version: version.map(Into::into),
            ..Default::default()
        }
    }

    #[test]
    fn items_fast_path_equals_the_lenient_path() {
        let good = r#"{"Items":[{"Id":"a","Name":"A","Type":"Movie"},{"Id":"b","Name":"B"}],"TotalRecordCount":9}"#;
        let r: ItemsResponse = serde_json::from_str(good).unwrap();
        assert_eq!((r.items.len(), r.total_record_count), (2, 9));
        // One entry cannot be read: only that one is skipped, as before.
        let bad = r#"{"Items":[{"Id":"a","Name":"A"},{"Id":5,"Name":[]},{"Id":"c","Name":"C"}]}"#;
        let r: ItemsResponse = serde_json::from_str(bad).unwrap();
        assert_eq!(
            r.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["a", "c"]
        );
        assert_eq!(r.total_record_count, 2);
        let none: ItemsResponse = serde_json::from_str(r#"{"Items":null}"#).unwrap();
        assert_eq!((none.items.len(), none.total_record_count), (0, 0));
        assert!(serde_json::from_str::<ItemsResponse>(r#"{"Items":5}"#).is_err());
    }

    #[test]
    fn series_without_seasons_are_dropped_everywhere() {
        let page = r#"{"Items":[
            {"Id":"gone","Name":"Gone","Type":"Series","ChildCount":0},
            {"Id":"live","Name":"Live","Type":"Series","ChildCount":2},
            {"Id":"unknown","Name":"Unknown","Type":"Series"},
            {"Id":"movie","Name":"Movie","Type":"Movie","ChildCount":0}],"TotalRecordCount":4}"#;
        let r: ItemsResponse = serde_json::from_str(page).unwrap();
        assert_eq!(
            r.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["live", "unknown", "movie"]
        );
        assert_eq!(r.total_record_count, 4);
    }

    #[test]
    fn jellyfin_or_emby() {
        assert!(info(Some("Jellyfin Server"), None).looks_like_jellyfin());
        assert!(!info(Some("Emby Server"), Some("12.0")).looks_like_jellyfin());
        assert!(info(None, Some("10.11.0")).looks_like_jellyfin());
        assert!(!info(None, Some("4.10.0.2")).looks_like_jellyfin());
        assert!(!info(None, None).looks_like_jellyfin());
        assert!(!info(None, Some("abc")).looks_like_jellyfin());
    }

    #[test]
    fn missing_fields_default() {
        let r: ItemsResponse = serde_json::from_str("{}").unwrap();
        assert!(r.items.is_empty());
        assert_eq!(r.total_record_count, 0);
        let r: ItemsResponse =
            serde_json::from_str(r#"{"Items":[{"Id":"a","Name":"b"},{"Name":"x"}]}"#).unwrap();
        assert_eq!((r.items.len(), r.total_record_count), (1, 1));
        assert!(serde_json::from_str::<ItemsResponse>(r#"{"TotalRecordCount":"7"}"#).is_err());
    }
}
