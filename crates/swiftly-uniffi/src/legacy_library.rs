//! The stateful half of the old Android library calls: the section state of one account (views, offering, natural list,
//! title filter across pages). One object per account; make a new one after an account switch.

use std::sync::Arc;

use crate::error::CoreError;
use crate::transport::CoreTransport;

/// The library section state of one account.
#[derive(uniffi::Object)]
pub struct LegacyLibrary {
    inner: swiftly_vm::LegacySection<CoreTransport>,
}

impl LegacyLibrary {
    pub(crate) fn new(inner: swiftly_vm::LegacySection<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}

#[uniffi::export]
impl LegacyLibrary {
    /// Fetches collections, shares and playlists (valid for one minute); the calls below do it themselves.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn offering_load(&self) -> Result<(), CoreError> {
        self.inner.offering_load().await;
        Ok(())
    }
    /// `Kern.startSelection`: libraries and collections still offered as own home rows.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn start_selection(&self, selected: String) -> Result<String, CoreError> {
        Ok(self.inner.start_selection(&selected).await?)
    }
    /// `Kern.sectionOffering`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn section_offering(
        &self,
        art: String,
        remembered: String,
    ) -> Result<String, CoreError> {
        Ok(self.inner.section_offering(&art, &remembered).await?)
    }
    /// `Kern.sectionPage`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn section_page(
        &self,
        art: String,
        choice: String,
        sorting: String,
        filter: String,
        since: i64,
        count: i64,
    ) -> Result<String, CoreError> {
        Ok(self
            .inner
            .section_page(&art, &choice, &sorting, &filter, since, count)
            .await?)
    }
    /// `Kern.collections`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn collections(&self, art: String) -> Result<String, CoreError> {
        Ok(self.inner.collections(&art).await?)
    }
    /// `Kern.playlists`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn playlists(&self, art: String) -> Result<String, CoreError> {
        Ok(self.inner.playlists(&art).await?)
    }
    /// `Kern.playlistPage`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn playlist_page(&self, id: String, art: String) -> Result<String, CoreError> {
        Ok(self.inner.playlist_page(&id, &art).await?)
    }
    /// `Kern.playlistStart`: the first entry's id, empty if there is none.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn playlist_start(&self, id: String, art: String) -> Result<String, CoreError> {
        Ok(self.inner.playlist_start(&id, &art).await)
    }
    /// The ids of the playlist started last, in order (the player's run).
    pub fn playlist_run(&self) -> Vec<String> {
        self.inner
            .playlist_run()
            .into_iter()
            .map(|i| i.id)
            .collect()
    }
    /// `Kern.collectionMosaic`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn collection_mosaic(
        &self,
        id: String,
        art: String,
        height: i64,
    ) -> Result<String, CoreError> {
        Ok(self.inner.collection_mosaic(&id, &art, height).await)
    }
    /// `Kern.collectionPage`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn collection_page(
        &self,
        id: String,
        art: String,
        sorting: String,
        filter: String,
        since: i64,
        count: i64,
    ) -> Result<String, CoreError> {
        Ok(self
            .inner
            .collection_page(&id, &art, &sorting, &filter, since, count)
            .await?)
    }
    /// `Kern.collectionsForTitle`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn collections_for_title(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.collections_for_title(&id).await)
    }
}

/// `Kern.collectionCountText`: "3 Filme" / "3 Serien" under a collection tile.
#[uniffi::export]
pub fn legacy_collection_count_text(art: String, count: i64, locale: String) -> String {
    swiftly_vm::legacy_count_text(swiftly_l10n::Locale::parse(&locale), &art, count)
}
