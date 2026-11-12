use serde::Serialize;
use swiftly_net::{ErrorKind, HttpTransport, Method};

use crate::client::{JellyfinClient, Query};

pub use swiftly_model::{seconds_from_ticks, ticks_from_seconds};

/// How the server delivers the title (`wireName` of the delivery method, Models.swift:603).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayMethod {
    /// `DirectPlay`
    DirectPlay,
    /// `DirectStream`
    DirectStream,
    /// `Transcode`
    Transcode,
}

impl PlayMethod {
    /// The spelling Jellyfin expects in playback reports.
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::DirectPlay => "DirectPlay",
            Self::DirectStream => "DirectStream",
            Self::Transcode => "Transcode",
        }
    }
}

/// The part of a playback plan that reports carry (ids and method). `PlaybackPlan` itself lives
/// in the playback crate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportPlan {
    /// `PlaySessionId` from `PlaybackInfo`.
    pub play_session_id: Option<String>,
    /// `MediaSourceId`.
    pub media_source_id: Option<String>,
    /// How the title is delivered.
    pub method: PlayMethod,
}

impl ReportPlan {
    /// The plan of a file from disk: no ids, direct play (`PlaybackPlan.fromSlab`,
    /// PlaybackPlan.swift:68-75); used for late reports where there was no session offline.
    pub fn from_file() -> Self {
        Self {
            play_session_id: None,
            media_source_id: None,
            method: PlayMethod::DirectPlay,
        }
    }
}

/// The running tracks as Jellyfin indices; missing ones are left out of the report, otherwise
/// the server remembers "none" (`TrackIndices`, TrackRule.swift:247).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TrackIndices {
    /// Audio stream index.
    pub audio: Option<i64>,
    /// Subtitle stream index.
    pub subtitle: Option<i64>,
}

/// Body of the three reports (`ProgressBody`, PlaybackReporting.swift:25-39). Keys in the
/// order the Swift struct declares them; nil optionals are omitted.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct ProgressBody {
    item_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    play_session_id: Option<String>,
    position_ticks: i64,
    is_paused: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    media_source_id: Option<String>,
    play_method: &'static str,
    /// Without it Jellyfin does not remember the position (PlaybackReporting.swift:33).
    can_seek: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    audio_stream_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    subtitle_stream_index: Option<i64>,
}

pub(crate) fn report_body(
    item_id: &str,
    plan: &ReportPlan,
    position_ticks: i64,
    paused: bool,
    tracks: TrackIndices,
) -> ProgressBody {
    ProgressBody {
        item_id: item_id.into(),
        play_session_id: plan.play_session_id.clone(),
        position_ticks,
        is_paused: paused,
        media_source_id: plan.media_source_id.clone(),
        play_method: plan.method.wire_name(),
        can_seek: true,
        audio_stream_index: tracks.audio,
        subtitle_stream_index: tracks.subtitle,
    }
}

impl<T: HttpTransport> JellyfinClient<T> {
    /// `POST Sessions/Playing`: playback has started (PlaybackReporting.swift:46).
    pub async fn report_start(
        &self,
        item_id: &str,
        plan: &ReportPlan,
        ticks: i64,
        tracks: TrackIndices,
    ) -> Result<(), ErrorKind> {
        self.post_session("Sessions/Playing", item_id, plan, ticks, false, tracks)
            .await
    }

    /// `POST Sessions/Playing/Progress`: about every ten seconds and on every state change
    /// (PlaybackReporting.swift:55).
    pub async fn report_progress(
        &self,
        item_id: &str,
        plan: &ReportPlan,
        position_ticks: i64,
        paused: bool,
        tracks: TrackIndices,
    ) -> Result<(), ErrorKind> {
        self.post_session(
            "Sessions/Playing/Progress",
            item_id,
            plan,
            position_ticks,
            paused,
            tracks,
        )
        .await
    }

    /// `POST Sessions/Playing/Stopped`: must also be sent when leaving the view, otherwise the
    /// session stays stuck in the dashboard (PlaybackReporting.swift:62).
    pub async fn report_stopped(
        &self,
        item_id: &str,
        plan: &ReportPlan,
        position_ticks: i64,
    ) -> Result<(), ErrorKind> {
        self.post_session(
            "Sessions/Playing/Stopped",
            item_id,
            plan,
            position_ticks,
            false,
            TrackIndices::default(),
        )
        .await
    }

    /// `DELETE Videos/ActiveEncodings?deviceId&playSessionId`: ends the conversion job of a
    /// play session (PlaybackReporting.swift:72). Silent: needs a session and a non-empty
    /// session id, and any failure is ignored.
    pub async fn stop_encoding(&self, play_session_id: &str) {
        if play_session_id.is_empty() || self.require_session().is_err() {
            return;
        }
        let q = Query::new()
            .add("deviceId", &self.config.device_id)
            .add("playSessionId", play_session_id);
        if let Ok(req) = self.request("Videos/ActiveEncodings", Method::Delete, &q, None) {
            let _ = self.send_ignoring_body(req).await;
        }
    }

    async fn post_session(
        &self,
        path: &str,
        item_id: &str,
        plan: &ReportPlan,
        position_ticks: i64,
        paused: bool,
        tracks: TrackIndices,
    ) -> Result<(), ErrorKind> {
        self.require_session()?;
        let body = Self::json_body(&report_body(item_id, plan, position_ticks, paused, tracks))?;
        let req = self.request(path, Method::Post, &Query::new(), Some(body))?;
        self.send_ignoring_body(req).await
    }
}
