//! `HomeStore` (Swift `HomePageStore.swift`; app side `HomePageModel.swift:248-302`): the home
//! page from last time, so something is on screen at launch. Only a preview, never the truth.
//! One store belongs to exactly one account ([`HomeStore::file_name`]).

use serde::{Deserialize, Serialize};
use swiftly_model::Item;

use crate::store::Store;

/// The shape changes: an older store is discarded instead of misread (:20).
pub const CURRENT_VERSION: i64 = 1;

/// A genre row as stored.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Rail {
    /// Genre name.
    pub name: String,
    /// Its titles.
    pub items: Vec<Item>,
}

/// What is stored (:12-60). The JSON keys are the Swift ones.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HomeStore {
    /// `fassung`.
    #[serde(rename = "fassung")]
    pub version: i64,
    /// `bibliotheken`.
    #[serde(rename = "bibliotheken")]
    pub libraries: Vec<Item>,
    /// `weiterschauen`.
    #[serde(rename = "weiterschauen")]
    pub continue_watching: Vec<Item>,
    /// `naechsteFolge`.
    #[serde(rename = "naechsteFolge")]
    pub next_episode: Vec<Item>,
    /// `zuletzt`.
    #[serde(rename = "zuletzt")]
    pub recent: Vec<Item>,
    /// `neueFilme`.
    #[serde(rename = "neueFilme")]
    pub new_movies: Vec<Item>,
    /// `neueSerien`.
    #[serde(rename = "neueSerien")]
    pub new_series: Vec<Item>,
    /// `gattungsreihen`.
    #[serde(rename = "gattungsreihen")]
    pub genre_rails: Vec<Rail>,
}

impl HomeStore {
    /// A store of the current version.
    pub fn new(
        libraries: Vec<Item>,
        continue_watching: Vec<Item>,
        next_episode: Vec<Item>,
        recent: Vec<Item>,
        new_movies: Vec<Item>,
        new_series: Vec<Item>,
        genre_rails: Vec<Rail>,
    ) -> Self {
        Self {
            version: CURRENT_VERSION,
            libraries,
            continue_watching,
            next_episode,
            recent,
            new_movies,
            new_series,
            genre_rails,
        }
    }

    /// Nothing worth showing (:62-66).
    pub fn is_empty(&self) -> bool {
        self.continue_watching.is_empty()
            && self.next_episode.is_empty()
            && self.recent.is_empty()
            && self.new_movies.is_empty()
            && self.new_series.is_empty()
            && self.genre_rails.iter().all(|r| r.items.is_empty())
    }

    /// The JSON bytes (`data()`, :68).
    pub fn data(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(self)
    }

    /// `None` for anything that is not exactly this version, including a half-written file
    /// and an empty store (:72-76).
    pub fn read(data: &[u8]) -> Option<Self> {
        let store: Self = serde_json::from_slice(data).ok()?;
        (store.version == CURRENT_VERSION && !store.is_empty()).then_some(store)
    }

    /// A stable file name per account (FNV-1a, 64 bit, lower-case hex) (:80-87).
    pub fn file_name(account: &str) -> String {
        let mut value: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in account.bytes() {
            value ^= u64::from(byte);
            value = value.wrapping_mul(0x0100_0000_01b3);
        }
        format!("startseite-{value:x}.json")
    }

    /// Reads the preview of an account from the store (`storeRead`, `HomePageModel.swift:268`).
    pub fn load(store: &dyn Store, account: &str) -> Option<Self> {
        store
            .read(&Self::file_name(account))
            .and_then(|d| Self::read(&d))
    }

    /// Writes the store of an account; a failure is silent (`storeWrite`, :280-290).
    pub fn save(&self, store: &dyn Store, account: &str) {
        if let Ok(data) = self.data() {
            store.write(&Self::file_name(account), &data);
        }
    }

    /// On sign-out: the state of an account no longer on the device does not linger (:294).
    pub fn delete(store: &dyn Store, account: &str) {
        store.remove(&Self::file_name(account));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryStore;

    fn episode() -> Item {
        serde_json::from_str(
            r#"{"Id":"f1","Name":"Pilot","Type":"Episode","SeriesId":"s1","SeriesName":"Serie",
             "IndexNumber":1,"ParentIndexNumber":2,"Overview":"Worum es geht.",
             "ImageTags":{"Primary":"abc"},"BackdropImageTags":["b1"],
             "ProviderIds":{"Tvdb":"42"},"RunTimeTicks":27000000000,
             "UserData":{"PlaybackPositionTicks":6000000000,"Played":false,"IsFavorite":true}}"#,
        )
        .unwrap_or_default()
    }

    #[test]
    fn round_trip() {
        let f = episode();
        assert_eq!(f.id, "f1");
        let store = HomeStore::new(
            vec![Item::new("b", "Serien", None)],
            vec![f.clone()],
            vec![f.clone()],
            vec![],
            vec![],
            vec![f.clone()],
            vec![Rail {
                name: "Drama".into(),
                items: vec![f],
            }],
        );
        let back = HomeStore::read(&store.data().unwrap_or_default());
        assert_eq!(back.as_ref(), Some(&store));
        let back = back.unwrap_or_else(|| store.clone());
        assert_eq!(
            back.continue_watching[0]
                .user_data
                .as_ref()
                .and_then(|d| d.playback_position_ticks),
            Some(6_000_000_000)
        );
        assert_eq!(
            back.continue_watching[0]
                .image_tags
                .as_ref()
                .and_then(|t| t.get("Primary"))
                .map(String::as_str),
            Some("abc")
        );
    }

    #[test]
    fn other_version_broken_and_empty_are_not_shown() {
        let f = episode();
        let mut alt = HomeStore::new(vec![], vec![f], vec![], vec![], vec![], vec![], vec![]);
        alt.version = CURRENT_VERSION + 1;
        assert_eq!(HomeStore::read(&alt.data().unwrap_or_default()), None);
        assert_eq!(HomeStore::read(br#"{"fassung":1"#), None);
        let empty = HomeStore::new(
            vec![Item::new("b", "x", None)],
            vec![],
            vec![],
            vec![],
            vec![],
            vec![],
            vec![Rail {
                name: "Drama".into(),
                items: vec![],
            }],
        );
        assert_eq!(HomeStore::read(&empty.data().unwrap_or_default()), None);
    }

    #[test]
    fn file_name_per_account_stable_without_address() {
        let a = HomeStore::file_name("https://server.example|u1");
        assert_eq!(a, HomeStore::file_name("https://server.example|u1"));
        assert_ne!(a, HomeStore::file_name("https://server.example|u2"));
        assert!(!a.contains("server"));
        assert!(a.ends_with(".json"));
        // FNV-1a of the empty string is the offset basis.
        assert_eq!(HomeStore::file_name(""), "startseite-cbf29ce484222325.json");
    }

    #[test]
    fn persistence_behind_the_store_trait() {
        let mem = MemoryStore::new();
        let s = HomeStore::new(
            vec![],
            vec![episode()],
            vec![],
            vec![],
            vec![],
            vec![],
            vec![],
        );
        assert_eq!(HomeStore::load(&mem, "acc"), None);
        s.save(&mem, "acc");
        assert_eq!(HomeStore::load(&mem, "acc"), Some(s));
        assert_eq!(HomeStore::load(&mem, "other"), None);
        HomeStore::delete(&mem, "acc");
        assert_eq!(HomeStore::load(&mem, "acc"), None);
    }
}
