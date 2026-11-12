//! The AirPlay decision of the Swift core (`AirPlaySuitability`): whether a file can go to a TV through
//! real AirPlay and, if not, why. The host checks the source it already has *before* it asks the server
//! for an `airplay` plan (a refused plan would leave a session open on the server); when the check
//! passes, the plan is asked with the narrow `airplay` profile ([`crate::play_start::PlayFlavour::AvPlayer`]),
//! `audio_track` as the audio index and `-1` as the subtitle index (never let the server burn one in).
//! The texts are catalog keys: the host translates `key` and puts `codec_shown` in place of `%@`.

use swiftly_model::MediaSource;
use swiftly_playback::airplay_suitability::{AirPlaySuitability, Art, MIRRORING_KEY, Obstacle};

/// What kind of obstacle stands in the way of AirPlay.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AirPlayObstacleKind {
    /// The video codec does not go through (only H.264 and HEVC do).
    Video,
    /// No audio track goes through (DTS, TrueHD and friends).
    Audio,
    /// The server would have to remux the container but gives no address for it.
    Remux,
}

/// One obstacle with its sentence.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AirPlayObstacle {
    /// The kind.
    pub kind: AirPlayObstacleKind,
    /// The codec (or container) concerned, as the file names it.
    pub codec: String,
    /// The codec upper-cased, for the `%@` of the sentence.
    pub codec_shown: String,
    /// The catalog key (German source text) of the sentence with `%@`.
    pub key: String,
}

/// Whether and how a file goes over AirPlay.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AirPlayVerdict {
    /// Nothing stands in the way.
    pub fitting: bool,
    /// The server's `Index` of the audio track that gets through; `None` when none does or something else
    /// stands in the way.
    pub audio_track: Option<i64>,
    /// What stands in the way; empty when it fits.
    pub obstacles: Vec<AirPlayObstacle>,
    /// The catalog key of the sentence that closes the message: Screen Mirroring works for any format. The
    /// message is the obstacle sentences, a space, then this one; only shown when `fitting` is false.
    pub mirroring_key: String,
}

pub(crate) fn obstacle_of(o: &Obstacle) -> AirPlayObstacle {
    AirPlayObstacle {
        kind: match o.art {
            Art::Video => AirPlayObstacleKind::Video,
            Art::Audio => AirPlayObstacleKind::Audio,
            Art::Umpacken => AirPlayObstacleKind::Remux,
        },
        codec: o.codec.clone(),
        codec_shown: o.codec.to_uppercase(),
        key: o.key().to_owned(),
    }
}

pub(crate) fn verdict_of(s: &AirPlaySuitability) -> AirPlayVerdict {
    AirPlayVerdict {
        fitting: s.fitting(),
        audio_track: s.audio_track,
        obstacles: s.obstacles.iter().map(obstacle_of).collect(),
        mirroring_key: MIRRORING_KEY.to_owned(),
    }
}

/// The core's decision when the audio goes to an AirPlay device (`PlayerVm::airplay_start`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AirPlayStartDecision {
    /// Not now (the title is not live, or the picture is already in the small window or on the TV).
    Ignore,
    /// Ask the server for the narrow AirPlay plan with this audio `Index` and subtitle `-1`.
    Go { audio_track: Option<i64> },
    /// The file cannot go over AirPlay: show the verdict's sentences.
    Refused { verdict: AirPlayVerdict },
}

/// Checks a `MediaSource` (JSON, as the server names it) for AirPlay: all audio tracks count, the default
/// one wins if it works, else the one with the most channels. `None` for JSON that is not a source.
#[uniffi::export]
pub fn airplay_suitability(source_json: String) -> Option<AirPlayVerdict> {
    let source: MediaSource = serde_json::from_str(&source_json).ok()?;
    Some(verdict_of(&AirPlaySuitability::check(&source)))
}

/// The verdict for a plan the server answered without a `TranscodingUrl` although the container is not for
/// AVPlayer (Matroska): the original would be passed to AVPlayer, which cannot open it. `delivery_direct_play`
/// is whether the chosen source is delivered as Direct Play; `None` when the plan is fine.
#[uniffi::export]
pub fn airplay_remux_refusal(
    delivery_direct_play: bool,
    has_transcoding_url: bool,
    container: Option<String>,
) -> Option<AirPlayVerdict> {
    if delivery_direct_play || has_transcoding_url {
        return None;
    }
    let refused = AirPlaySuitability::new(
        None,
        vec![Obstacle::new(
            Art::Umpacken,
            container.unwrap_or_else(|| "?".into()),
        )],
    );
    Some(verdict_of(&refused))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(video: &str, audio: &[(&str, i64, i64, bool)]) -> String {
        let mut streams = vec![serde_json::json!({"Type": "Video", "Codec": video, "Index": 0})];
        for (codec, index, channels, standard) in audio {
            streams.push(serde_json::json!({
                "Type": "Audio", "Codec": codec, "Index": index, "Channels": channels, "IsDefault": standard
            }));
        }
        serde_json::json!({"Id": "q1", "Container": "mkv", "MediaStreams": streams}).to_string()
    }

    #[test]
    fn h264_and_aac_go_over_airplay() {
        let v = airplay_suitability(source("h264", &[("aac", 1, 2, true)])).expect("verdict");
        assert!(v.fitting && v.obstacles.is_empty());
        assert_eq!(v.audio_track, Some(1));
        let v = airplay_suitability(source("hevc", &[("eac3", 1, 6, true)])).expect("verdict");
        assert!(v.fitting);
        assert!(
            airplay_suitability(source("hvc1", &[("ac3", 1, 0, false)])).is_some_and(|v| v.fitting)
        );
    }

    #[test]
    fn dts_and_truehd_name_the_audio_obstacle() {
        let v = airplay_suitability(source("h264", &[("dts", 1, 6, true)])).expect("verdict");
        assert!(!v.fitting);
        assert_eq!(v.audio_track, None);
        assert_eq!(v.obstacles.len(), 1);
        assert_eq!(v.obstacles[0].kind, AirPlayObstacleKind::Audio);
        assert_eq!(v.obstacles[0].codec_shown, "DTS");
        assert!(v.obstacles[0].key.contains("%@"));
        let v = airplay_suitability(source("hevc", &[("truehd", 1, 8, true)])).expect("verdict");
        assert_eq!(v.obstacles[0].kind, AirPlayObstacleKind::Audio);
    }

    #[test]
    fn the_best_audio_track_wins_over_the_first() {
        let v = airplay_suitability(source(
            "h264",
            &[
                ("dts", 1, 6, false),
                ("aac", 2, 2, false),
                ("ac3", 3, 6, false),
            ],
        ))
        .expect("verdict");
        assert!(v.fitting);
        assert_eq!(
            v.audio_track,
            Some(3),
            "most channels among the usable ones, the server's index"
        );
        let v = airplay_suitability(source("h264", &[("ac3", 1, 6, false), ("aac", 2, 2, true)]))
            .expect("verdict");
        assert_eq!(v.audio_track, Some(2), "the default wins when it works");
    }

    #[test]
    fn a_foreign_video_codec_is_an_obstacle_and_bad_json_is_none() {
        let v = airplay_suitability(source("av1", &[("aac", 1, 2, true)])).expect("verdict");
        assert!(!v.fitting);
        assert_eq!(v.obstacles[0].kind, AirPlayObstacleKind::Video);
        assert_eq!(v.obstacles[0].codec_shown, "AV1");
        assert_eq!(v.audio_track, None);
        assert!(airplay_suitability("nope".into()).is_none());
    }

    #[test]
    fn a_plan_without_a_remux_address_is_refused() {
        assert!(airplay_remux_refusal(true, false, Some("mkv".into())).is_none());
        assert!(airplay_remux_refusal(false, true, Some("mkv".into())).is_none());
        let v = airplay_remux_refusal(false, false, Some("mkv".into())).expect("refused");
        assert!(!v.fitting);
        assert_eq!(v.obstacles[0].kind, AirPlayObstacleKind::Remux);
        assert_eq!(v.obstacles[0].codec_shown, "MKV");
        let v = airplay_remux_refusal(false, false, None).expect("refused");
        assert_eq!(v.obstacles[0].codec, "?");
    }
}
