//! **The Plex play decision** (`/video/:/transcode/universal/decision`), used only to ask
//! "may this file be played as it is?".
//!
//! The Swift app never calls it: the plan is always the file at `Part.key`. Plex servers that
//! limit the remote bitrate answer that download with `500` (Plezy #2909); a host that meets
//! such an answer asks the server once here, with direct play and direct stream allowed and
//! no bitrate cap, and reads the verdict. Nothing is transcoded: no session is started and the
//! caller still plays the original file. This is additive; no existing behaviour reads it.
//!
//! One more use: a title the device cannot show as it is (AV1 Dolby Vision 10.0, a green picture
//! on the iPhone) is asked for with direct play and direct stream **off**
//! ([`PlexDecision::transcode_query`]); a yes ([`PlexDecision::allows_transcode`]) makes the plan a
//! universal-transcoder HLS address ([`crate::PlexPlayback::transcode_url`]).

use serde_json::Value;
use swiftly_net::ErrorKind;

use crate::loose;

/// The code of "direct play is possible" in `directPlayDecisionCode` / `generalDecisionCode`.
pub const DECISION_OK: i64 = 1000;

/// What the server said about playing a title as it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexDecision {
    /// `generalDecisionCode` (1000 is fine).
    pub general_code: Option<i64>,
    /// `directPlayDecisionCode` (1000 is fine; 2000 means "not as it is").
    pub direct_play_code: Option<i64>,
    /// `generalDecisionText`.
    pub general_text: Option<String>,
    /// `directPlayDecisionText`.
    pub direct_play_text: Option<String>,
}

impl PlexDecision {
    /// The path of the call.
    pub const PATH: &'static str = "/video/:/transcode/universal/decision";

    /// The query for one title: ask for the original file, directly, without a bitrate cap.
    pub fn query(rating_key: &str, media_index: usize, part_index: usize) -> Vec<(String, String)> {
        [
            ("path", format!("/library/metadata/{rating_key}")),
            ("mediaIndex", media_index.to_string()),
            ("partIndex", part_index.to_string()),
            ("protocol", "http".into()),
            ("directPlay", "1".into()),
            ("directStream", "1".into()),
            ("hasMDE", "1".into()),
            ("maxVideoBitrate", "2000000".into()),
            ("videoBitrate", "2000000".into()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect()
    }

    /// The query that asks for a transcode of one title: direct play and direct stream off, so the
    /// server may neither send the file nor copy its video. `session` ties it to the start address.
    pub fn transcode_query(
        rating_key: &str,
        media_index: usize,
        part_index: usize,
        session: &str,
    ) -> Vec<(String, String)> {
        Self::transcode_query_with_subtitle(rating_key, media_index, part_index, session, None)
    }

    /// The same query with a chosen subtitle (`MediaStream.id`): a transcoded stream carries no
    /// subtitle unless the request asks for it, so the server burns the stream into the picture
    /// (`subtitles=burn`, the only way a bitmap track reaches a player). `None` or an id of 0
    /// or less sends none.
    pub fn transcode_query_with_subtitle(
        rating_key: &str,
        media_index: usize,
        part_index: usize,
        session: &str,
        subtitle_stream_id: Option<i64>,
    ) -> Vec<(String, String)> {
        let subtitle = subtitle_stream_id.filter(|id| *id > 0);
        let mut query: Vec<(String, String)> = [
            ("path", format!("/library/metadata/{rating_key}")),
            ("mediaIndex", media_index.to_string()),
            ("partIndex", part_index.to_string()),
            ("protocol", "hls".into()),
            ("directPlay", "0".into()),
            ("directStream", "0".into()),
            ("directStreamAudio", "1".into()),
            ("hasMDE", "1".into()),
            ("fastSeek", "1".into()),
            ("copyts", "1".into()),
            (
                "subtitles",
                if subtitle.is_some() { "burn" } else { "none" }.into(),
            ),
            ("videoQuality", "100".into()),
            ("session", session.to_string()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        if let Some(id) = subtitle {
            query.push(("subtitleStreamID".to_string(), id.to_string()));
        }
        query
    }

    /// Reads the answer (`{"MediaContainer": {...}}`); numbers may arrive as text.
    ///
    /// # Errors
    /// A decoding error when the body is not JSON or has no container.
    pub fn from_body(body: &[u8]) -> Result<Self, ErrorKind> {
        let root: Value =
            serde_json::from_slice(body).map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        let c = root
            .get("MediaContainer")
            .ok_or_else(|| ErrorKind::Decoding("keyNotFound MediaContainer".into()))?;
        Ok(Self {
            general_code: loose::int(c, "generalDecisionCode"),
            direct_play_code: loose::int(c, "directPlayDecisionCode"),
            general_text: loose::string(c, "generalDecisionText"),
            direct_play_text: loose::string(c, "directPlayDecisionText"),
        })
    }

    /// Whether the server will transcode the title when asked with [`Self::transcode_query`]: the
    /// general code is in the 1xxx range (1000 direct play, 1001 conversion), not a 2xxx/3xxx
    /// refusal (transcoding off for the user, no transcoder, no licence). Not seen on a real
    /// server in this tree: the answers are recorded shapes.
    pub fn allows_transcode(&self) -> bool {
        self.general_code.is_some_and(|c| (1000..2000).contains(&c))
    }

    /// Whether the server lets the file go out as it is. Without a direct-play code the general
    /// one decides; an answer with neither is not a yes.
    pub fn allows_direct_play(&self) -> bool {
        self.direct_play_code
            .or(self.general_code)
            .is_some_and(|c| c == DECISION_OK)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_play_ok() {
        let d = PlexDecision::from_body(
            br#"{"MediaContainer":{"generalDecisionCode":1000,"directPlayDecisionCode":1000,
            "generalDecisionText":"Direct play OK."}}"#,
        )
        .expect("decision");
        assert!(d.allows_direct_play());
        assert_eq!(d.general_text.as_deref(), Some("Direct play OK."));
    }

    #[test]
    fn numbers_as_text_and_refusal() {
        let d = PlexDecision::from_body(
            br#"{"MediaContainer":{"generalDecisionCode":"1000","directPlayDecisionCode":"2000"}}"#,
        )
        .expect("decision");
        assert_eq!(d.direct_play_code, Some(2000));
        assert!(!d.allows_direct_play());
    }

    #[test]
    fn general_code_decides_without_direct_play_code_and_empty_is_no() {
        let ok = PlexDecision::from_body(br#"{"MediaContainer":{"generalDecisionCode":1000}}"#)
            .expect("decision");
        assert!(ok.allows_direct_play());
        let none = PlexDecision::from_body(br#"{"MediaContainer":{}}"#).expect("decision");
        assert!(!none.allows_direct_play());
        assert!(PlexDecision::from_body(b"nope").is_err());
        assert!(PlexDecision::from_body(b"{}").is_err());
    }

    #[test]
    fn query_asks_for_the_original() {
        let q = PlexDecision::query("42", 0, 0);
        let get = |k: &str| q.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str());
        assert_eq!(get("path"), Some("/library/metadata/42"));
        assert_eq!(get("directPlay"), Some("1"));
        assert_eq!(get("protocol"), Some("http"));
    }

    #[test]
    fn transcode_asks_without_direct_and_reads_the_code() {
        let q = PlexDecision::transcode_query("42", 1, 0, "sess");
        let get = |k: &str| q.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str());
        assert_eq!(get("directPlay"), Some("0"));
        assert_eq!(get("directStream"), Some("0"));
        assert_eq!(get("protocol"), Some("hls"));
        assert_eq!(get("mediaIndex"), Some("1"));
        assert_eq!(get("session"), Some("sess"));
        let yes = PlexDecision::from_body(
            br#"{"MediaContainer":{"generalDecisionCode":1001,"directPlayDecisionCode":2000}}"#,
        )
        .expect("decision");
        assert!(yes.allows_transcode());
        let no = PlexDecision::from_body(
            br#"{"MediaContainer":{"generalDecisionCode":2000,"generalDecisionText":"Neither"}}"#,
        )
        .expect("decision");
        assert!(!no.allows_transcode());
        assert!(
            !PlexDecision::from_body(br#"{"MediaContainer":{}}"#)
                .expect("decision")
                .allows_transcode()
        );
    }

    #[test]
    fn a_transcode_asks_for_the_chosen_subtitle_burned_in() {
        let get = |q: &[(String, String)], k: &str| {
            q.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone())
        };
        let none = PlexDecision::transcode_query("42", 0, 0, "sess");
        assert_eq!(get(&none, "subtitles").as_deref(), Some("none"));
        assert_eq!(get(&none, "subtitleStreamID"), None);
        let burn = PlexDecision::transcode_query_with_subtitle("42", 0, 0, "sess", Some(411_748));
        assert_eq!(get(&burn, "subtitles").as_deref(), Some("burn"));
        assert_eq!(get(&burn, "subtitleStreamID").as_deref(), Some("411748"));
        let off = PlexDecision::transcode_query_with_subtitle("42", 0, 0, "sess", Some(-1));
        assert_eq!(get(&off, "subtitles").as_deref(), Some("none"));
    }
}
