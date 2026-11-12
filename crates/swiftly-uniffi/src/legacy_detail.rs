//! The title, series and person calls of the old Android facade as one object per account (it keeps the playback
//! limit the settings set and the shuffled run). Make a new one after an account switch.

use std::sync::Arc;

use crate::error::CoreError;
use crate::transport::CoreTransport;

/// Title, series and person pages of one account.
#[derive(uniffi::Object)]
pub struct LegacyDetail {
    inner: swiftly_vm::LegacyDetail<CoreTransport>,
}

impl LegacyDetail {
    pub(crate) fn new(inner: swiftly_vm::LegacyDetail<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}

#[uniffi::export]
impl LegacyDetail {
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

    /// `Kern.fromContinueWatchingTake`: empty means done, otherwise the sentence for the failure.
    #[uniffi::method(async_runtime = "tokio")]
    #[allow(clippy::wrong_self_convention)] // name mirrors `Kern.fromContinueWatchingTake`
    pub async fn from_continue_watching_take(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.from_continue_watching_take(&id).await)
    }
    /// `Kern.plan`: `{"lossless","methode"}` or `{}`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn plan(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.plan_answer(&id).await)
    }
    /// `Kern.loadSelectionEpisodes`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_selection_episodes(
        &self,
        series: String,
        season: String,
    ) -> Result<String, CoreError> {
        Ok(self.inner.load_selection_episodes(&series, &season).await?)
    }

    // ---- downloads (the server calls; the queue itself is `DownloadsVm`) ---------------------------------------------

    /// `Kern.downloadItem`: `[{"posten","bild","serienbild"}]`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_item(&self, ids: Vec<String>) -> Result<String, CoreError> {
        Ok(self.inner.download_item(&ids).await)
    }
    /// `Kern.downloadAudioOptions`: `{"angeboten","optionen":[{"id","text"}],"vorgabe"}`.
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
    /// `Kern.downloadWithAudio` (after `download_item` or `download_audio_options` for the same ids).
    pub fn download_with_audio(&self, list: String, choice: String, locale: String) -> String {
        self.inner
            .download_with_audio(&crate::downloads::TrackNames::new(&locale), &list, &choice)
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
    /// `Kern.downloadHeaderImage`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_header_image(
        &self,
        series: String,
        width: i64,
    ) -> Result<String, CoreError> {
        Ok(self.inner.download_header_image(&series, width).await)
    }
    /// `Kern.downloadSections` as the segments in the old JSON; empty is no answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_sections(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.download_sections(&id).await)
    }
    /// The stored segments for `DownloadsIntent::SectionsFetched`; `None` is no answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_sections_typed(
        &self,
        id: String,
    ) -> Result<Option<Vec<crate::player::PlayerSection>>, CoreError> {
        Ok(self
            .inner
            .download_sections_typed(&id)
            .await
            .map(|v| v.into_iter().map(section_of).collect()))
    }
    /// What the server says about the downloaded titles, for `DownloadsIntent::ServerFollow`; `None` when it did not answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn download_follow_fetch(
        &self,
        ids: Vec<String>,
    ) -> Result<Option<crate::downloads::DownloadFollow>, CoreError> {
        Ok(self.inner.download_follow_fetch(&ids).await.map(follow_of))
    }
    /// For `DownloadsIntent::SuccessorFound`: the series' episodes as the server's `Items` JSON and the next episode's
    /// landscape image, for the watched download given as its list JSON object. `None`: no answer.
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
    /// `Kern.watchers`: `"absent"`, `""` or the list.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn watchers(&self, id: String) -> Result<String, CoreError> {
        Ok(self.inner.watchers(&id).await)
    }
    /// `Kern.pendingSubmit`: the settled report ids as JSON.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn pending_submit(&self, store: String) -> Result<String, CoreError> {
        Ok(self.inner.pending_submit(&store).await)
    }
}

/// `Kern.pendingReportRecord`.
#[uniffi::export]
pub fn legacy_pending_report_record(store: String, message: String) -> String {
    swiftly_vm::pending_report_record(&store, &message)
}
/// `Kern.pendingDone`.
#[uniffi::export]
pub fn legacy_pending_done(store: String, completed: String) -> String {
    swiftly_vm::pending_done(&store, &completed)
}

/// A stored segment as the host-facing section (the reverse of `From<PlayerSection> for Segment`).
pub(crate) fn section_of(s: swiftly_playback::sections::Segment) -> crate::player::PlayerSection {
    use crate::player::PlayerSectionKind as K;
    use swiftly_playback::sections::Art;
    crate::player::PlayerSection {
        kind: match s.art {
            Art::Unknown => K::Unknown,
            Art::Ads => K::Ads,
            Art::Preview => K::Preview,
            Art::LookBack => K::LookBack,
            Art::Credits => K::Credits,
            Art::IntroSegment => K::Intro,
        },
        from: s.from,
        until: s.until,
    }
}

/// What the server said about the downloaded titles, as the host-facing record.
pub(crate) fn follow_of(f: swiftly_vm::FollowFetch) -> crate::downloads::DownloadFollow {
    crate::downloads::DownloadFollow {
        available: f.available,
        states: f
            .states
            .into_iter()
            .map(|(id, u)| crate::downloads::DownloadWatchState {
                id,
                played: u.played,
                position_ticks: u.playback_position_ticks,
                played_percentage: u.played_percentage,
                last_played_date: u.last_played_date,
            })
            .collect(),
    }
}

/// `Kern.stoppsProcess`: the stops (as the playback reported them) for the downloads list and the catch-up store.
#[uniffi::export]
pub fn legacy_stops_process(
    store: String,
    list: String,
    next_auto: bool,
    stops: Vec<crate::legacy_playback::LegacyStopped>,
) -> String {
    let stops: Vec<swiftly_vm::LegacyStop> = stops
        .into_iter()
        .map(|s| swiftly_vm::LegacyStop {
            item_id: s.item_id,
            account: s.account,
            ticks: s.ticks,
            moment: s.moment,
            sent: s.sent,
        })
        .collect();
    swiftly_vm::stops_process(&store, &list, next_auto, &stops)
}

/// `Kern.episodeCard`: sizes, springs and times of the next-episode card, as the old JSON (`breite`, `ecke`, ...).
#[uniffi::export]
pub fn legacy_episode_card(tv: bool) -> String {
    use swiftly_rules::episodes_card as c;
    let m = if tv { c::TV } else { c::IPHONE };
    serde_json::json!({
        "breite": m.width, "ecke": m.corner, "ring": m.ring, "abstand": m.spacing, "klein": m.small, "titel": m.title,
        "erscheinenOmega": c::APPEAR_OMEGA, "erscheinenVerzug": c::APPEAR_LAG, "wegOmega": c::DISTANCE_OMEGA, "zoomOmega": c::ZOOM_OMEGA,
        "angabenAus": c::DETAILS_OUT, "tausch": c::SWAP, "bildBlende": c::IMAGE_FADE, "versatz": c::OFFSET,
        "startmass": c::START_METRIC, "fokusmass": c::FOCUS_METRIC, "klickDruck": c::CLICK_PRESS, "klickDauer": c::CLICK_DURATION,
        "untenAbstand": c::BOTTOM_SPACING,
    })
    .to_string()
}

/// `Kern.episodeCardWidth`: the card width for a safe width (dp).
#[uniffi::export]
pub fn legacy_episode_card_width(safe_width: f64, large: bool, tv: bool) -> f64 {
    use swiftly_rules::episodes_card as c;
    c::width(&if tv { c::TV } else { c::IPHONE }, safe_width, large)
}

/// `Kern.episodeCardDragged`: the offset while dragging, one axis.
#[uniffi::export]
pub fn legacy_episode_card_dragged(distance: f64) -> f64 {
    swiftly_rules::episodes_card::dragged(distance, 0.0).0
}

/// `Kern.episodeCardSwipedAway`.
#[uniffi::export]
pub fn legacy_episode_card_swiped_away(x: f64, y: f64, momentum_x: f64, momentum_y: f64) -> bool {
    swiftly_rules::episodes_card::swiped_away(x, y, momentum_x, momentum_y)
}

/// `Kern.episodeCardFadeFrom`.
#[uniffi::export]
pub fn legacy_episode_card_fade_from(image_since: f64) -> f64 {
    swiftly_rules::episodes_card::fade_off(image_since)
}
