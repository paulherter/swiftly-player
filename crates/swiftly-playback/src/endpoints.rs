//! The playback-side endpoints of the Jellyfin client: segments (intro skip), trickplay and
//! chapters (JellyfinClient.swift:1208-1300). They live here because their result types do
//! (`swiftly-playback`, `swiftly-rules`), and this crate depends on `swiftly-jellyfin`, not
//! the other way round.

use serde::Deserialize;
use swiftly_jellyfin::{DownloadConversion, JellyfinClient, ServerKind};
use swiftly_model::MediaSource;
use swiftly_net::{ErrorKind, HttpTransport, Url};
use swiftly_rules::chapter::{Chapter, ChapterBar};
use swiftly_rules::download_quality::DownloadQuality;

use crate::airplay_suitability::{AirPlaySuitability, Art, Obstacle};
use crate::device_profile::DeviceProfile;
use crate::offering_layer::AccountPreGift;
use crate::playback_plan::{PlanError, PlaybackPlan, best_source};
use crate::sections::{SectionResponse, Segment};
use crate::trickplay::{Trickplay, TrickplayResponse};

#[derive(Deserialize)]
struct RawChapter {
    #[serde(rename = "Name", default)]
    name: Option<String>,
    #[serde(rename = "StartPositionTicks")]
    ticks: i64,
}

/// `ChapterResponse` (Chapter.swift:46): broken entries are dropped, no list is empty.
#[derive(Deserialize)]
struct ChapterResponse {
    #[serde(rename = "Chapters", default)]
    chapters: Option<Vec<serde_json::Value>>,
}

impl ChapterResponse {
    fn chapters(self) -> Vec<Chapter> {
        self.chapters
            .unwrap_or_default()
            .into_iter()
            .filter_map(|v| serde_json::from_value::<RawChapter>(v).ok())
            .map(|c| Chapter::from_ticks(c.name.as_deref(), c.ticks))
            .collect()
    }
}

/// What AirPlay yields for a title (`AirPlayInfo`, AirPlaySuitability.swift:152).
#[derive(Debug, Clone, PartialEq)]
pub enum AirPlayInfo {
    /// Works, with this plan that `AVPlayer` can open.
    Goes(Box<PlaybackPlan>),
    /// Does not work, and here is why.
    GoesNot(AirPlaySuitability),
}

/// The calls, added to [`JellyfinClient`] as a trait.
#[allow(async_fn_in_trait)] // used with concrete transports, never boxed
pub trait PlaybackEndpoints {
    /// `GET MediaSegments/{id}`: intro, recap, outro. **A failure is not an error**: empty.
    async fn sections(&self, item_id: &str) -> Vec<Segment>;

    /// As [`Self::sections`], but `None` means "unreachable, ask again later"; an error answer
    /// from the server (no such endpoint) counts as none. Emby has no `MediaSegments`.
    async fn segments_to_store(&self, item_id: &str) -> Option<Vec<Segment>>;

    /// `GET Items/{id}?userId&Fields=Trickplay`: the best offer for the source; `None` if the
    /// server has none or on any failure. Emby makes `index.bif`, which is not read here.
    async fn trickplay(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        target: i64,
    ) -> Option<Trickplay>;

    /// `GET Items/{id}?userId&Fields=Chapters`, cleaned up by [`ChapterBar::usable`]. Asks for
    /// the source first when it differs from the title (each version has its own chapters),
    /// then for the title. Empty on any failure.
    async fn chapters(&self, item_id: &str, media_source_id: Option<&str>) -> Vec<Chapter>;

    /// `GET Users/{id}`: the account's settings and permissions; `None` on any failure.
    /// **Remembers the download permission in the client**, only on a response (:1195).
    async fn account_defaults(&self) -> Option<AccountPreGift>;

    /// What AirPlay offers for this title (:1314). The check comes before the request: a file
    /// that cannot go makes no server visit. `SubtitleStreamIndex: -1` is explicit, `None`
    /// would let the server burn in a subtitle and re-encode.
    async fn airplay_plan(
        &self,
        item_id: &str,
        source: &MediaSource,
    ) -> Result<AirPlayInfo, ErrorKind>;

    /// The download address for a quality (:1413, :1438). The conversion needs all five
    /// values of the level; the original with every track is the plain file.
    fn download_url_for(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        quality: DownloadQuality,
        audio_stream_index: Option<i64>,
    ) -> Result<Url, ErrorKind>;

    /// A trickplay tile sheet as raw JPEG; `None` on any error (only the time is shown).
    async fn trickplay_sheet(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        width: i64,
        sheet: i64,
    ) -> Option<Vec<u8>>;
}

async fn chapter_query<T: HttpTransport>(c: &JellyfinClient<T>, id: &str) -> Option<Vec<Chapter>> {
    let user = c.current_session()?.user_id;
    let r: ChapterResponse = c
        .get_json(
            &format!("Items/{id}"),
            &[("userId", &user), ("Fields", "Chapters")],
        )
        .await
        .ok()?;
    Some(r.chapters())
}

impl<T: HttpTransport> PlaybackEndpoints for JellyfinClient<T> {
    async fn sections(&self, item_id: &str) -> Vec<Segment> {
        self.segments_to_store(item_id).await.unwrap_or_default()
    }

    async fn segments_to_store(&self, item_id: &str) -> Option<Vec<Segment>> {
        if self.server_kind() == ServerKind::Emby {
            return Some(Vec::new());
        }
        match self
            .get_json::<SectionResponse>(&format!("MediaSegments/{item_id}"), &[])
            .await
        {
            Ok(r) => Some(r.items),
            Err(ErrorKind::Http { .. }) => Some(Vec::new()),
            Err(_) => None,
        }
    }

    async fn trickplay(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        target: i64,
    ) -> Option<Trickplay> {
        if self.server_kind() == ServerKind::Emby {
            return None;
        }
        let user = self.current_session()?.user_id;
        let r: TrickplayResponse = self
            .get_json(
                &format!("Items/{item_id}"),
                &[("userId", &user), ("Fields", "Trickplay")],
            )
            .await
            .ok()?;
        r.of_target(media_source_id, target)
    }

    async fn chapters(&self, item_id: &str, media_source_id: Option<&str>) -> Vec<Chapter> {
        if let Some(source) = media_source_id
            && source.to_lowercase() != item_id.to_lowercase()
            && let Some(found) = chapter_query(self, source).await
        {
            return ChapterBar::usable(&found);
        }
        ChapterBar::usable(&chapter_query(self, item_id).await.unwrap_or_default())
    }

    async fn account_defaults(&self) -> Option<AccountPreGift> {
        let user = self.current_session()?.user_id;
        let guidelines: AccountPreGift = self.get_json(&format!("Users/{user}"), &[]).await.ok()?;
        self.remember_download_allowed(guidelines.downloads_allowed);
        Some(guidelines)
    }

    async fn airplay_plan(
        &self,
        item_id: &str,
        source: &MediaSource,
    ) -> Result<AirPlayInfo, ErrorKind> {
        let suitability = AirPlaySuitability::check(source);
        if !suitability.fitting() {
            return Ok(AirPlayInfo::GoesNot(suitability));
        }
        let profile = DeviceProfile::airplay(1_000_000_000, false);
        let info = self
            .playback_info(
                item_id,
                &profile,
                profile.max_streaming_bitrate,
                suitability.audio_track,
                Some(-1),
                None,
            )
            .await?;
        let Some(best) = best_source(&info.media_sources) else {
            return Err(match info.error_code.as_deref() {
                Some(reason) if !reason.is_empty() => ErrorKind::PlaybackRejected(reason.into()),
                _ => ErrorKind::NoPlayableSource,
            });
        };
        // Without an address from the server AVPlayer cannot open a Matroska original.
        if best.delivery_method() != swiftly_model::DeliveryMethod::DirectPlay
            && best.transcoding_url.is_none()
        {
            return Ok(AirPlayInfo::GoesNot(AirPlaySuitability::new(
                None,
                vec![Obstacle::new(
                    Art::Umpacken,
                    best.container.clone().unwrap_or_else(|| "?".into()),
                )],
            )));
        }
        let plan = PlaybackPlan::make(
            &info,
            item_id,
            &profile,
            |id, source_id, session_id| {
                self.stream_url(id, source_id, session_id)
                    .map(|u| u.to_string())
                    .map_err(|_| PlanError::InvalidServerUrl)
            },
            self.base_url().as_str(),
            None,
        )
        .map_err(|e| match e {
            PlanError::PlaybackRejected(r) => ErrorKind::PlaybackRejected(r),
            PlanError::InvalidServerUrl => ErrorKind::InvalidServerUrl,
        })?;
        plan.map(|p| AirPlayInfo::Goes(Box::new(p)))
            .ok_or(ErrorKind::NoPlayableSource)
    }

    fn download_url_for(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        quality: DownloadQuality,
        audio_stream_index: Option<i64>,
    ) -> Result<Url, ErrorKind> {
        let conversion = if quality.is_original() {
            None
        } else {
            match (
                quality.image_bitrate(),
                quality.audio_bitrate(),
                quality.height(),
                quality.width(),
                quality.audio_channels(),
            ) {
                (
                    Some(video_bitrate),
                    Some(audio_bitrate),
                    Some(height),
                    Some(width),
                    Some(channels),
                ) => Some(DownloadConversion {
                    video_bitrate,
                    audio_bitrate,
                    height,
                    width,
                    channels,
                }),
                _ => None,
            }
        };
        self.download_url(item_id, media_source_id, conversion, audio_stream_index)
    }

    async fn trickplay_sheet(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        width: i64,
        sheet: i64,
    ) -> Option<Vec<u8>> {
        let url = self.trickplay_url(item_id, media_source_id, width, sheet)?;
        self.get_bytes(url).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sections::Art;
    use futures_executor::block_on;
    use swiftly_jellyfin::{ClientConfig, Session};
    use swiftly_net::MockTransport;

    fn client(mock: MockTransport, kind: ServerKind) -> JellyfinClient<MockTransport> {
        let c = JellyfinClient::new(
            mock,
            "https://tv.example.de",
            ClientConfig::new("dev", "Test", "1.0").kind(kind),
        )
        .expect("client");
        c.set_session(Some(Session {
            access_token: "TOKEN".into(),
            user_id: "u1".into(),
            user_name: "n".into(),
            server_url: "https://tv.example.de".into(),
            kind,
        }));
        c
    }
    fn jf(mock: MockTransport) -> JellyfinClient<MockTransport> {
        client(mock, ServerKind::Jellyfin)
    }
    fn path_of(c: &JellyfinClient<MockTransport>) -> String {
        c.transport().last_request().expect("req").url.to_string()
    }

    // JellyfinClient.swift:1208-1228
    #[test]
    fn segments_read_skip_unknown_types_and_failures_are_quiet() {
        let body = r#"{"Items":[{"Type":"Intro","StartTicks":100000000,"EndTicks":900000000},
            {"Type":"Zukunft","StartTicks":0,"EndTicks":1}]}"#;
        let c = jf(MockTransport::new().route("/MediaSegments/e1", 200, body));
        let list = block_on(c.sections("e1"));
        assert_eq!(path_of(&c), "https://tv.example.de/MediaSegments/e1");
        assert_eq!(list.len(), 2);
        assert_eq!(
            (list[0].art, list[0].from, list[0].until),
            (Art::IntroSegment, 10.0, 90.0)
        );
        assert_eq!(list[1].art, Art::Unknown);
        // old server: error answer = none; no answer = ask again
        let c = jf(MockTransport::new().route("/MediaSegments/e1", 404, ""));
        assert_eq!(block_on(c.segments_to_store("e1")), Some(vec![]));
        let c = jf(MockTransport::new()
            .route_error("/MediaSegments/e1", ErrorKind::Network { code: -1009 }));
        assert_eq!(block_on(c.segments_to_store("e1")), None);
        assert!(block_on(c.sections("e1")).is_empty());
    }

    #[test]
    fn emby_has_no_segments_and_no_trickplay() {
        let c = client(MockTransport::new(), ServerKind::Emby);
        assert_eq!(block_on(c.segments_to_store("e1")), Some(vec![]));
        assert!(block_on(c.trickplay("e1", None, 320)).is_none());
        assert!(c.transport().last_request().is_none());
    }

    // :1231
    #[test]
    fn trickplay_asks_for_the_field_and_picks_the_width() {
        let body = r#"{"Trickplay":{"src1":{
            "160":{"Width":160,"Height":90,"TileWidth":10,"TileHeight":10,"ThumbnailCount":50,"Interval":10000},
            "320":{"Width":320,"Height":180,"TileWidth":5,"TileHeight":5,"ThumbnailCount":50,"Interval":10000}}}}"#;
        let c = jf(MockTransport::new().route("/Items/m1", 200, body));
        let t = block_on(c.trickplay("m1", Some("src1"), 320)).expect("trickplay");
        assert_eq!(
            path_of(&c),
            "https://tv.example.de/Items/m1?userId=u1&Fields=Trickplay"
        );
        assert_eq!((t.width, t.tiles_wide), (320, 5));
        let c = jf(MockTransport::new().route("/Items/m1", 200, r#"{"Id":"m1"}"#));
        assert!(block_on(c.trickplay("m1", None, 320)).is_none());
        let c = jf(MockTransport::new().route("/Items/m1", 500, ""));
        assert!(block_on(c.trickplay("m1", None, 320)).is_none());
    }

    // :1256
    #[test]
    fn chapters_ask_the_source_first_then_the_title() {
        let real = r#"{"Chapters":[{"Name":" Anfang \n","StartPositionTicks":0},
            {"Name":"Mitte","StartPositionTicks":6000000000},{"Broken":1}]}"#;
        let c = jf(MockTransport::new().route("/Items/src9", 200, real));
        let list = block_on(c.chapters("m1", Some("src9")));
        assert_eq!(
            path_of(&c),
            "https://tv.example.de/Items/src9?userId=u1&Fields=Chapters"
        );
        assert_eq!(
            list,
            vec![Chapter::new("Anfang", 0.0), Chapter::new("Mitte", 600.0)]
        );
        // source unknown to the server: the title applies
        let c =
            jf(MockTransport::new()
                .route("/Items/src9", 404, "")
                .route("/Items/m1", 200, real));
        assert_eq!(block_on(c.chapters("m1", Some("src9"))).len(), 2);
        // same id (any case): asks only once
        let c = jf(MockTransport::new().route("/Items/m1", 200, real));
        assert_eq!(block_on(c.chapters("m1", Some("M1"))).len(), 2);
        assert_eq!(c.transport().requests().len(), 1);
        // a placeholder grid or a single chapter is no bar
        let grid = r#"{"Chapters":[{"Name":"1","StartPositionTicks":0},{"Name":"2","StartPositionTicks":3000000000},{"Name":"3","StartPositionTicks":6000000000}]}"#;
        let c = jf(MockTransport::new().route("/Items/m1", 200, grid));
        assert!(block_on(c.chapters("m1", None)).is_empty());
        let c = jf(MockTransport::new().route("/Items/m1", 500, ""));
        assert!(block_on(c.chapters("m1", None)).is_empty());
    }

    // :1296
    #[test]
    fn trickplay_sheet_bytes_or_none() {
        let c = jf(MockTransport::new().route("/Trickplay/320/0.jpg", 200, "JPEG"));
        assert_eq!(
            block_on(c.trickplay_sheet("m1", Some("s1"), 320, 0)),
            Some(b"JPEG".to_vec())
        );
        assert_eq!(
            path_of(&c),
            "https://tv.example.de/Videos/m1/Trickplay/320/0.jpg?MediaSourceId=s1&ApiKey=TOKEN"
        );
        let c = jf(MockTransport::new().route("/Trickplay/320/0.jpg", 404, ""));
        assert!(block_on(c.trickplay_sheet("m1", None, 320, 0)).is_none());
    }

    fn source(json: &str) -> MediaSource {
        serde_json::from_str(json).expect("source")
    }
    const FITTING: &str = r#"{"Id":"s1","Container":"mp4","MediaStreams":[
        {"Type":"Video","Codec":"h264","Index":0},{"Type":"Audio","Codec":"aac","Index":1}]}"#;

    // JellyfinClient.swift:1314: a file that cannot go makes no request.
    #[test]
    fn airplay_refuses_before_asking_the_server() {
        let c = jf(MockTransport::new());
        let src = source(
            r#"{"Id":"s1","Container":"mkv","MediaStreams":[
            {"Type":"Video","Codec":"vc1","Index":0},{"Type":"Audio","Codec":"aac","Index":1}]}"#,
        );
        let r = block_on(c.airplay_plan("i1", &src)).unwrap();
        assert!(matches!(r, AirPlayInfo::GoesNot(s) if !s.fitting()));
        assert!(c.transport().requests().is_empty());
    }

    #[test]
    fn airplay_asks_once_with_the_narrow_profile_and_no_subtitle() {
        let info = r#"{"PlaySessionId":"ps","MediaSources":[{"Id":"s1","Container":"mp4",
            "SupportsDirectPlay":true,"MediaStreams":[]}]}"#;
        let c = jf(MockTransport::new().route("/Items/i1/PlaybackInfo", 200, info));
        let r = block_on(c.airplay_plan("i1", &source(FITTING))).unwrap();
        let reqs = c.transport().requests();
        assert_eq!(reqs.len(), 1);
        let body = String::from_utf8(reqs[0].body.clone().unwrap()).unwrap();
        assert!(body.contains("\"SubtitleStreamIndex\":-1"), "{body}");
        assert!(body.contains("\"AudioStreamIndex\":1"), "{body}");
        assert!(body.contains("Swiftly (AirPlay)"), "{body}");
        let AirPlayInfo::Goes(plan) = r else {
            panic!("goes")
        };
        assert_eq!(plan.play_session_id.as_deref(), Some("ps"));
        assert!(plan.url.contains("/Videos/i1/stream?static=true"));
    }

    #[test]
    fn airplay_without_transcoding_address_is_a_remux_obstacle() {
        let info = r#"{"MediaSources":[{"Id":"s1","Container":"mkv",
            "SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":true}]}"#;
        let c = jf(MockTransport::new().route("/Items/i1/PlaybackInfo", 200, info));
        let r = block_on(c.airplay_plan("i1", &source(FITTING))).unwrap();
        let AirPlayInfo::GoesNot(s) = r else {
            panic!("goes not")
        };
        assert_eq!(
            s.obstacles[0].art,
            crate::airplay_suitability::Art::Umpacken
        );
        assert_eq!(s.obstacles[0].codec, "mkv");
    }

    #[test]
    fn airplay_reports_rejection_and_missing_source() {
        let c = jf(MockTransport::new().route(
            "/Items/i1/PlaybackInfo",
            200,
            r#"{"ErrorCode":"NotAllowed","MediaSources":[]}"#,
        ));
        assert_eq!(
            block_on(c.airplay_plan("i1", &source(FITTING))).unwrap_err(),
            ErrorKind::PlaybackRejected("NotAllowed".into())
        );
        let c =
            jf(MockTransport::new().route("/Items/i1/PlaybackInfo", 200, r#"{"MediaSources":[]}"#));
        assert_eq!(
            block_on(c.airplay_plan("i1", &source(FITTING))).unwrap_err(),
            ErrorKind::NoPlayableSource
        );
    }

    // JellyfinClient.swift:1195: the permission is remembered on a response only.
    #[test]
    fn account_defaults_remember_the_download_permission() {
        let body = r#"{"Configuration":{"EnableNextEpisodeAutoPlay":true},
            "Policy":{"EnableContentDownloading":false}}"#;
        let c = jf(MockTransport::new().route("/Users/u1", 200, body));
        let g = block_on(c.account_defaults()).unwrap();
        assert_eq!(g.next_episode_automatic, Some(true));
        assert_eq!(c.download_allowed(), Some(false));
        assert!(
            c.download_url_for("i1", None, DownloadQuality::Original, None)
                .is_err()
        );
        // a failure changes nothing
        let c2 = jf(MockTransport::new().route("/Users/u1", 500, ""));
        c2.remember_download_allowed(Some(false));
        assert!(block_on(c2.account_defaults()).is_none());
        assert_eq!(c2.download_allowed(), Some(false));
    }

    #[test]
    fn download_url_for_quality_uses_the_level_values() {
        let c = jf(MockTransport::new());
        let plain = c
            .download_url_for("i1", Some("s1"), DownloadQuality::Original, None)
            .unwrap();
        assert!(plain.as_str().contains("/Videos/i1/stream?static=true"));
        let hd = c
            .download_url_for("i1", Some("s1"), DownloadQuality::Hd720, None)
            .unwrap();
        let s = hd.as_str();
        assert!(s.contains("stream.mkv?static=false&container=mkv&videoCodec=h264&audioCodec=aac&videoBitRate=4000000"), "{s}");
        assert!(s.contains("maxHeight=720&maxWidth=1280"));
    }
}
