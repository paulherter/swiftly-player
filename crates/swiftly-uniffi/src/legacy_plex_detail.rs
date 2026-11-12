//! The title, series and person calls for a Plex account (same answers as `LegacyDetail`, over the Plex client).

use std::sync::Arc;

use crate::error::CoreError;
use crate::transport::CoreTransport;

/// Title, series and person pages of one Plex account.
#[derive(uniffi::Object)]
pub struct LegacyPlexDetail {
    inner: swiftly_vm::LegacyPlexDetail<CoreTransport>,
}

impl LegacyPlexDetail {
    pub(crate) fn new(inner: swiftly_vm::LegacyPlexDetail<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}

#[uniffi::export]
impl LegacyPlexDetail {
    /// `Kern.playbackSelection`: the settings that decide the bitrate limit, at start and on every change.
    pub fn playback_selection(&self, always_direct_play: bool, megabit: i64) {
        self.inner.playback_selection(always_direct_play, megabit);
    }
    /// `Kern.title`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn title(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.title(&id).await?)
    }
    /// `Kern.series`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn series(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.series(&id).await?)
    }
    /// `Kern.episodes`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn episodes(&self, series: String, season: String) -> Result<String, CoreError> {
        Ok(self.inner.episodes(&series, &season).await?)
    }
    /// `Kern.titleField`: similar titles and extras.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn title_field(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.title_field(&id).await?)
    }
    /// `Kern.trailers`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn trailers(&self, id: String, can_open_web: bool) -> Result<String, CoreError> {
        Ok(self.inner.trailers(&id, can_open_web).await)
    }
    /// `Kern.person`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn person(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.person(&id).await?)
    }
    /// `Kern.episodeAfter`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn episode_after(
        &self,
        episode: String,
        series: String,
    ) -> Result<String, CoreError> {
        Ok(self.inner.episode_after(&episode, &series).await)
    }
    /// `Kern.shuffleStart`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn shuffle_start(&self, series: String) -> Result<String, CoreError> {
        Ok(self.inner.shuffle_start(&series).await)
    }
    /// The ids of the shuffled run, in order (the player's run).
    pub fn run_ids(&self) -> Vec<String> {
        self.inner.run_ids()
    }
    /// `Kern.remember`: empty means done, otherwise the sentence for the failure.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn remember(&self, id: String, on: bool) -> Result<String, CoreError> {
        Ok(self.inner.remember(&id, on).await)
    }
    /// `Kern.watched`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn watched(&self, id: String, on: bool) -> Result<String, CoreError> {
        Ok(self.inner.watched(&id, on).await)
    }
    /// `Kern.metadataRefresh`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn metadata_refresh(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.metadata_refresh(&id).await)
    }

    // ---- downloads (Plex: the original file, the markers, the follower episode) ---------------------------------------

    /// `Kern.downloadAddress`: the file address of a download (a request for the part's key).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_address(
        &self,
        id: String,
        source: Option<String>,
        quality: String,
        audio_index: Option<i64>,
    ) -> Result<String, CoreError> {
        Ok(self
            .inner
            .download_address(&id, source.as_deref(), &quality, audio_index)
            .await?)
    }
    /// The external subtitle files that go with a finished download: `[{"index","adresse","endung"}]`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_subtitle_files(
        &self,
        id: String,
        source: Option<String>,
        converted: bool,
    ) -> Result<String, CoreError> {
        Ok(self
            .inner
            .download_subtitle_files(&id, source.as_deref(), converted)
            .await)
    }
    /// The stored segments for `DownloadsIntent::SectionsFetched`; `None` is no answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_sections_typed(
        &self,
        id: String,
    ) -> Result<Option<Vec<crate::player::PlayerSection>>, CoreError> {
        Ok(self.inner.download_sections_typed(&id).await.map(|v| {
            v.into_iter()
                .map(crate::legacy_detail::section_of)
                .collect()
        }))
    }
    /// What the server says about the downloaded titles; `None` when it did not answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_follow_fetch(
        &self,
        ids: Vec<String>,
    ) -> Result<Option<crate::downloads::DownloadFollow>, CoreError> {
        Ok(self
            .inner
            .download_follow_fetch(&ids)
            .await
            .map(crate::legacy_detail::follow_of))
    }
    /// The series' episodes and the next episode's image for a watched download; `None`: no answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_successor(
        &self,
        watched: String,
    ) -> Result<Option<crate::downloads::DownloadSuccessor>, CoreError> {
        let Some((episodes_json, image)) = self.inner.download_successor(&watched).await else {
            return Ok(None);
        };
        Ok(Some(crate::downloads::DownloadSuccessor {
            episodes_json: episodes_json.into_bytes(),
            image,
        }))
    }
    /// `Kern.fromContinueWatchingTake` for Plex: empty means done, otherwise the sentence for the failure.
    #[uniffi::method(async_runtime = "tokio")]
    #[allow(clippy::wrong_self_convention)] // name mirrors `Kern.fromContinueWatchingTake`
    pub async fn from_continue_watching_take(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.from_continue_watching_take(&id).await)
    }
    /// `Kern.plan` for Plex: `{"lossless","methode"}` or `{}`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn plan(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.plan_answer(&id).await)
    }
    /// `Kern.loadSelectionEpisodes` for Plex.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_selection_episodes(
        &self,
        series: String,
        season: String,
    ) -> Result<String, CoreError> {
        Ok(self.inner.load_selection_episodes(&series, &season).await?)
    }
    /// `Kern.downloadItem` for Plex: `[{"posten","bild","serienbild"}]`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_item(&self, ids: Vec<String>) -> Result<String, CoreError> {
        Ok(self.inner.download_item(&ids).await)
    }
    /// `Kern.downloadAudioOptions` for Plex.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_audio_options(
        &self,
        ids: Vec<String>,
        preferred: String,
        locale: String,
    ) -> Result<String, CoreError> {
        let streams = self.inner.download_audio_streams(&ids).await;
        Ok(self.inner.download_audio_options(
            &crate::downloads::TrackNames::new(&locale),
            &streams,
            &preferred,
        ))
    }
    /// `Kern.downloadWithAudio` for Plex.
    pub fn download_with_audio(&self, list: String, choice: String, locale: String) -> String {
        self.inner
            .download_with_audio(&crate::downloads::TrackNames::new(&locale), &list, &choice)
    }
    /// `Kern.downloadHeaderImage` for Plex.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_header_image(
        &self,
        series: String,
        width: i64,
    ) -> Result<String, CoreError> {
        Ok(self.inner.download_header_image(&series, width).await)
    }
}
