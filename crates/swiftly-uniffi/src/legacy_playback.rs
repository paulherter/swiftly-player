//! The open title of the old Android facade as one object per account: the plan, the track rules, the chapter bar and
//! the trickplay sheets as the JSON the Compose player parses (`Kern.playbackOpen`, `tracksSelect`, `chapterBar`, ...).
//! Make a new one after an account switch.

use std::sync::Arc;

use crate::error::CoreError;
use crate::transport::CoreTransport;

/// A place for kept stops that keeps nothing: the app stores them from the answer of `playback_end`.
pub(crate) struct NoPending;

impl swiftly_vm::PendingSink for NoPending {
    fn record(&self, _report: swiftly_vm::PendingReport) {}
}

/// A stop of the playback, for the download's watch state (`StopRemember`).
#[derive(uniffi::Record, Clone, Debug)]
pub struct LegacyStopped {
    pub item_id: String,
    pub account: String,
    pub ticks: i64,
    /// Seconds since 1970.
    pub moment: f64,
    /// The server took the report.
    pub sent: bool,
}

/// The open title of one account.
#[derive(uniffi::Object)]
pub struct LegacyPlayback {
    inner: swiftly_vm::LegacyPlayback<CoreTransport>,
}

impl LegacyPlayback {
    /// See `swiftly_vm::LegacyPlayback::hand_over_order`.
    pub(crate) fn hand_over_order(&self) -> Option<(String, Option<String>, Option<i64>, i64)> {
        self.inner.hand_over_order()
    }

    pub(crate) fn new(inner: swiftly_vm::LegacyPlayback<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}

#[uniffi::export]
impl LegacyPlayback {
    /// `Kern.playbackSelection`.
    pub fn playback_selection(&self, always_direct_play: bool, megabit: i64) {
        self.inner.playback_selection(always_direct_play, megabit);
    }
    /// The downloads list and the network state: where "next episode" comes from.
    pub fn set_downloads(&self, list: String, without_network: bool) {
        self.inner.set_downloads(&list, without_network);
    }
    /// `Kern.subtitleLookReport`: whether the server hands ASS out as SRT.
    pub fn set_server_extracts_text(&self, on: bool) {
        self.inner.set_server_extracts_text(on);
    }
    /// The device has no Dolby Vision decoder: Dolby Vision profile 5 is planned as a server transcode.
    pub fn set_no_dolby_vision_decoder(&self, on: bool) {
        self.inner.set_no_dolby_vision_decoder(on);
    }
    /// Tracks sent with the title from another client.
    pub fn set_ordered(&self, item_id: String, audio: Option<i64>, subtitle: Option<i64>) {
        self.inner.set_ordered(&item_id, audio, subtitle);
    }
    /// `Kern.playbackOpen`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn open(&self, id: String, source_id: String) -> Result<String, CoreError> {
        Ok(self.inner.open(&id, &source_id).await?)
    }
    /// `Kern.subtitleFiles`.
    pub fn subtitle_files(&self) -> String {
        self.inner.subtitle_files()
    }
    /// `Kern.subtitleAttributeSet`.
    pub fn subtitle_attribute_set(&self, index: i64, attribute: String) {
        self.inner.subtitle_attribute_set(index, &attribute);
    }
    /// `Kern.tracksSelect`.
    #[allow(clippy::too_many_arguments)]
    pub fn tracks_select(
        &self,
        audio: String,
        subtitle: String,
        audio_now: i64,
        audio_wish: String,
        subtitle_preference: String,
        automatic: bool,
        audio_memory: String,
        subtitle_memory: String,
    ) -> String {
        self.inner.tracks_select(
            &audio,
            &subtitle,
            audio_now,
            &audio_wish,
            &subtitle_preference,
            automatic,
            &audio_memory,
            &subtitle_memory,
        )
    }
    /// `Kern.openSubtitle`.
    pub fn open_subtitle(&self, subtitle: String) -> i64 {
        self.inner.open_subtitle(&subtitle)
    }
    /// `Kern.audioFromHand`.
    pub fn audio_from_hand(&self, audio: String, id: i64, memory: String) -> String {
        self.inner.audio_from_hand(&audio, id, &memory)
    }
    /// `Kern.subtitleFromHand`.
    pub fn subtitle_from_hand(&self, subtitle: String, id: i64, memory: String) -> String {
        self.inner.subtitle_from_hand(&subtitle, id, &memory)
    }
    /// `Kern.trackNames`.
    pub fn track_names(&self, audio: String, subtitle: String) -> String {
        self.inner.track_names(&audio, &subtitle)
    }
    /// `Kern.chapterLoad`.
    pub fn chapter_load(&self) -> i64 {
        self.inner.chapter_load()
    }
    /// `Kern.chapterBar`.
    pub fn chapter_bar(&self, duration: f64, width: f64, min_width: f64, gap: f64) -> String {
        self.inner.chapter_bar(duration, width, min_width, gap)
    }
    /// `Kern.chapterName`.
    pub fn chapter_name(&self, at: f64) -> String {
        self.inner.chapter_name(at)
    }
    /// `Kern.chapterPiece`.
    pub fn chapter_piece(&self, share: f64, duration: f64, width: f64, min_width: f64) -> i64 {
        self.inner.chapter_piece(share, duration, width, min_width)
    }
    /// `Kern.trickplayDetail`.
    pub fn trickplay_detail(&self) -> String {
        self.inner.trickplay_detail()
    }
    /// `Kern.trickplayAddress`.
    pub fn trickplay_address(&self, width: i64, sheet: i64) -> String {
        self.inner.trickplay_address(width, sheet)
    }
    /// `Kern.firstFrameVideoCodec`.
    pub fn first_frame_video_codec(&self) -> String {
        self.inner.first_frame_video_codec()
    }
    /// `Kern.playbackPoint`.
    pub fn playback_point(&self, since: f64) {
        self.inner.playback_point(since);
    }
    /// `Kern.displayTime`.
    pub fn display_time(&self, position: f64, at_push: bool) -> f64 {
        self.inner.display_time(position, at_push)
    }
    /// `Kern.controlsChanged`.
    pub fn controls_changed(&self, opened: bool) -> String {
        self.inner.controls_changed(opened)
    }
    /// `Kern.offeringClose`.
    pub fn offering_close(&self) -> bool {
        self.inner.offering_close()
    }
    /// `Kern.offeringPressed`.
    pub fn offering_pressed(&self) {
        self.inner.offering_pressed();
    }
    /// `Kern.nextAutomaticSet`.
    pub fn next_automatic_set(&self, on: bool) {
        self.inner.next_automatic_set(on);
    }
    /// `Kern.resumeTarget`.
    pub fn resume_target(&self, position: f64, in_group: bool) -> f64 {
        self.inner.resume_target(position, in_group)
    }
    /// `Kern.prebufferDue`.
    pub fn prebuffer_due(&self, position: f64, duration: f64, network_favorable: bool) -> bool {
        self.inner
            .prebuffer_due(position, duration, network_favorable)
    }
    /// `Kern.episodePrepare`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn episode_prepare(&self) -> Result<(), CoreError> {
        self.inner.episode_prepare().await;
        Ok(())
    }
    /// `Kern.playbackTick`.
    #[allow(clippy::too_many_arguments)]
    pub fn playback_tick(
        &self,
        duration: f64,
        position: f64,
        shows_image: bool,
        running: bool,
        has_audio_tracks: bool,
        at_push: bool,
        auto_skip: bool,
    ) -> String {
        self.inner.playback_tick(
            duration,
            position,
            shows_image,
            running,
            has_audio_tracks,
            at_push,
            auto_skip,
        )
    }
    /// `Kern.runStateReported`.
    pub fn run_state_reported(&self, running: bool, position: f64) {
        self.inner.run_state_reported(running, position);
    }
    /// `Kern.jumpReported`.
    pub fn jump_reported(&self, target: f64) -> String {
        self.inner.jump_reported(target)
    }
    /// `Kern.backgroundReport`.
    pub fn background_report(&self, position: f64, paused: bool) {
        self.inner.background_report(position, paused);
    }
    /// `Kern.playbackEnd`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn playback_end(&self, position: f64) -> Result<String, CoreError> {
        Ok(self.inner.playback_end(position).await)
    }
    /// `Kern.playbackFromTheSlab`: a stored file plays before any server.
    pub fn open_slab(
        &self,
        entries: String,
        path: String,
        image: String,
    ) -> Result<String, CoreError> {
        self.inner
            .open_slab(&entries, &path, &image)
            .map_err(CoreError::from)
    }
    /// `Kern.playbackLookUp`: next episode and sections of a stored file from the server; empty when nothing changed.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn look_up(&self) -> Result<String, CoreError> {
        Ok(self.inner.look_up().await)
    }
    /// `Kern.qualitySwitch`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quality_switch(&self, position: f64) -> Result<String, CoreError> {
        Ok(self.inner.quality_switch(position).await)
    }
    /// `Kern.episodeSwitch`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn episode_switch(&self, id: String, position: f64) -> Result<String, CoreError> {
        Ok(self.inner.episode_switch(&id, position).await)
    }
    /// The stops since the last pickup (for the download's watch state).
    pub fn stops_take(&self) -> Vec<LegacyStopped> {
        self.inner
            .stops_take()
            .into_iter()
            .map(|s| LegacyStopped {
                item_id: s.item_id,
                account: s.account,
                ticks: s.ticks,
                moment: s.moment,
                sent: s.sent,
            })
            .collect()
    }
    /// The report lines since the last pickup (`Kern.logFetch`).
    pub fn log_fetch(&self) -> String {
        self.inner.log_fetch()
    }
    /// A group plays without a next episode.
    pub fn set_without_next(&self, on: bool) {
        self.inner.set_without_next(on);
    }
    /// `Kern.techFixed`.
    pub fn tech_fixed(&self, measure: bool) -> String {
        self.inner.tech_fixed(measure)
    }
    /// `Kern.techTick` (the eleven VLC counters in the old order, then position and whether it runs).
    #[allow(clippy::too_many_arguments)]
    pub fn tech_tick(
        &self,
        has_read: i64,
        unpacked: i64,
        shown: i64,
        discarded: i64,
        video_blocks: i64,
        audio_blocks: i64,
        audio_play: i64,
        audio_lost: i64,
        damaged: i64,
        jumps: i64,
        spot: f64,
        running: bool,
    ) -> String {
        self.inner.tech_tick(
            [
                has_read,
                unpacked,
                shown,
                discarded,
                video_blocks,
                audio_blocks,
                audio_play,
                audio_lost,
                damaged,
                jumps,
            ],
            spot,
            running,
        )
    }
    /// The frame rate (-1: none) and the average bytes per second (-1: none) of the open file, for the tech badge's measurement.
    pub fn tech_source(&self) -> Vec<f64> {
        let (a, b) = self.inner.tech_source();
        vec![a, b]
    }
}
