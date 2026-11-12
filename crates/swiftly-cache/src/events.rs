//! Server events that invalidate the cache, read from the WebSocket message.

use serde_json::Value;

/// A change the server announced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Invalidation {
    /// `LibraryChanged`: items were added, updated or removed.
    LibraryChanged {
        /// Ids added.
        added: Vec<String>,
        /// Ids updated.
        updated: Vec<String>,
        /// Ids removed.
        removed: Vec<String>,
    },
    /// `UserDataChanged`: played, favourite or progress changed for these items.
    UserDataChanged {
        /// The items.
        item_ids: Vec<String>,
    },
}

fn ids(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Reads a Jellyfin/Emby WebSocket text message (`{"MessageType":…,"Data":…}`); `None` for
/// anything that does not touch cached data (keep-alives, sessions, tasks).
pub fn parse_ws(message: &str) -> Option<Invalidation> {
    let v: Value = serde_json::from_str(message).ok()?;
    let data = v.get("Data")?;
    match v.get("MessageType")?.as_str()? {
        "LibraryChanged" => Some(Invalidation::LibraryChanged {
            added: ids(data.get("ItemsAdded")),
            updated: ids(data.get("ItemsUpdated")),
            removed: ids(data.get("ItemsRemoved")),
        }),
        "UserDataChanged" => Some(Invalidation::UserDataChanged {
            item_ids: data
                .get("UserDataList")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.get("ItemId")?.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default(),
        }),
        _ => None,
    }
}
