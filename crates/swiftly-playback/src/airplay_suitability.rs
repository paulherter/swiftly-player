//! Port of `AirPlaySuitability.swift` (JellyfinKit): whether a file can go to a TV via real
//! AirPlay, and if not, why. Looks at all audio tracks, not just the first. Texts are catalog
//! keys resolved through a [`Localizer`]; `AirPlayInfo` (needs `PlaybackPlan`) is not ported.

use swiftly_model::Localizer;
use swiftly_model::{MediaSource, MediaStream};

/// What kind of obstacle (AirPlaySuitability.swift:40, `Obstacle.Art`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Art {
    /// The video codec does not go through.
    Video,
    /// No audio track goes through (Swift raw value `"ton"`).
    Audio,
    /// The server would have to remux but cannot or will not (Swift `umpacken`).
    Umpacken,
}

impl Art {
    /// The Swift raw value: `video`, `ton`, `umpacken`.
    pub fn raw_value(self) -> &'static str {
        match self {
            Art::Video => "video",
            Art::Audio => "ton",
            Art::Umpacken => "umpacken",
        }
    }
}

/// What stands in the way of AirPlay (AirPlaySuitability.swift:39).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Obstacle {
    /// The kind of obstacle.
    pub art: Art,
    /// The codec (or container) concerned, as given.
    pub codec: String,
}

impl Obstacle {
    /// Creates an obstacle (AirPlaySuitability.swift:50).
    pub fn new(art: Art, codec: impl Into<String>) -> Self {
        Self {
            art,
            codec: codec.into(),
        }
    }

    /// The catalog key (German source text) with `%@` for the upper-cased codec
    /// (AirPlaySuitability.swift:55-63).
    pub fn key(&self) -> &'static str {
        match self.art {
            Art::Video => "Das Bild liegt als %@ vor. AirPlay überträgt nur H.264 und HEVC.",
            Art::Audio => {
                "Der Ton liegt als %@ vor. Apple-Geräte nehmen das über AirPlay nicht an."
            }
            Art::Umpacken => {
                "Die Datei liegt als %@ vor. Für AirPlay müsste der Server sie umpacken — er bietet das nicht an. In den Servereinstellungen unter „Wiedergabe“ muss Transkodierung erlaubt sein."
            }
        }
    }

    /// The sentence for this obstacle, translated through `l` (AirPlaySuitability.swift:55).
    pub fn text(&self, l: &dyn Localizer) -> String {
        l.text(self.key(), &[])
            .replace("%@", &self.codec.to_uppercase())
    }
}

/// Catalog key of the second sentence of the message (AirPlaySuitability.swift:76).
pub const MIRRORING_KEY: &str =
    "Über Bildschirmsynchronisierung im Kontrollzentrum läuft der Film trotzdem auf dem Fernseher.";

/// Whether and how a file goes over AirPlay (AirPlaySuitability.swift:20).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AirPlaySuitability {
    /// Index of the audio track that gets through via AirPlay, `None` if none. This is the
    /// server's `Index`, not the position in the list (AirPlaySuitability.swift:27).
    pub audio_track: Option<i64>,
    /// What stands in the way.
    pub obstacles: Vec<Obstacle>,
}

/// Video codecs that AirPlay transmits (AirPlaySuitability.swift:86).
pub const VIDEO_CODECS: [&str; 9] = [
    "h264", "avc1", "avc", "hevc", "h265", "hvc1", "hev1", "dvh1", "dvhe",
];

/// Audio codecs that AirPlay transmits. DTS, TrueHD and MLP are deliberately missing
/// (AirPlaySuitability.swift:97).
pub const AUDIO_CODECS: [&str; 9] = [
    "aac", "aac_latm", "he-aac", "ac3", "eac3", "ec-3", "alac", "flac", "mp3",
];

impl AirPlaySuitability {
    /// Creates a result (AirPlaySuitability.swift:33).
    pub fn new(audio_track: Option<i64>, obstacles: Vec<Obstacle>) -> Self {
        Self {
            audio_track,
            obstacles,
        }
    }

    /// True if nothing stands in the way (AirPlaySuitability.swift:31).
    pub fn fitting(&self) -> bool {
        self.obstacles.is_empty()
    }

    /// The message for the app, or `None` if it fits (AirPlaySuitability.swift:72). The second
    /// sentence ([`MIRRORING_KEY`]) matters more: there is a way that works for any format.
    pub fn message(&self, l: &dyn Localizer) -> Option<String> {
        if self.fitting() {
            return None;
        }
        let grounds = self
            .obstacles
            .iter()
            .map(|o| o.text(l))
            .collect::<Vec<_>>()
            .join(" ");
        Some(format!("{grounds} {}", l.text(MIRRORING_KEY, &[])))
    }

    /// Checks a source (AirPlaySuitability.swift:105).
    pub fn check(source: &MediaSource) -> AirPlaySuitability {
        let streams: &[MediaStream] = source.media_streams.as_deref().unwrap_or(&[]);
        let mut obstacles: Vec<Obstacle> = Vec::new();

        // Video. Without a video track it is an audio file; nothing stands in the way.
        if let Some(video) = streams.iter().find(|s| s.type_.as_deref() == Some("Video")) {
            let codec = video.codec.as_deref().unwrap_or("").to_lowercase();
            if !VIDEO_CODECS.contains(&codec.as_str()) {
                let shown = if codec.is_empty() {
                    "?".to_string()
                } else {
                    codec
                };
                obstacles.push(Obstacle::new(Art::Video, shown));
            }
        }

        // Audio. Of all usable tracks the best one, not the first.
        let audio_streams: Vec<&MediaStream> = streams
            .iter()
            .filter(|s| s.type_.as_deref() == Some("Audio"))
            .collect();
        let suitable: Vec<&MediaStream> = audio_streams
            .iter()
            .copied()
            .filter(|s| {
                AUDIO_CODECS.contains(&s.codec.as_deref().unwrap_or("").to_lowercase().as_str())
            })
            .collect();
        let selected = best_audio_track(&suitable);

        if selected.is_none()
            && let Some(first) = audio_streams.first()
        {
            // What the viewer would have heard otherwise: the default track, else the first.
            let named = audio_streams
                .iter()
                .find(|s| s.is_default == Some(true))
                .unwrap_or(first);
            let codec = named
                .codec
                .as_deref()
                .map_or_else(|| "?".to_string(), str::to_lowercase);
            obstacles.push(Obstacle::new(Art::Audio, codec));
        }

        AirPlaySuitability {
            audio_track: if obstacles.is_empty() {
                selected.and_then(|s| s.index)
            } else {
                None
            },
            obstacles,
        }
    }
}

/// The default track if it works, otherwise the one with the most channels; on a tie the
/// server's order is kept (AirPlaySuitability.swift:139).
fn best_audio_track<'a>(tracks: &[&'a MediaStream]) -> Option<&'a MediaStream> {
    if let Some(standard) = tracks.iter().find(|t| t.is_default == Some(true)) {
        return Some(standard);
    }
    let mut best: Option<&MediaStream> = None;
    for track in tracks {
        if track.channels.unwrap_or(0) > best.map_or(-1, |b| b.channels.unwrap_or(0)) {
            best = Some(track);
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_model::Source;

    fn feed(
        type_: &str,
        codec: &str,
        index: i64,
        channels: Option<i64>,
        standard: Option<bool>,
    ) -> MediaStream {
        MediaStream {
            codec: Some(codec.to_string()),
            type_: Some(type_.to_string()),
            channels,
            is_default: standard,
            index: Some(index),
            ..Default::default()
        }
    }

    fn source(streams: Vec<MediaStream>) -> MediaSource {
        MediaSource {
            id: Some("q1".into()),
            container: Some("mkv".into()),
            media_streams: Some(streams),
            ..Default::default()
        }
    }

    #[test]
    fn h264aac() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "h264", 0, None, None),
            feed("Audio", "aac", 1, Some(2), Some(true)),
        ]));
        assert!(e.fitting());
        assert_eq!(e.audio_track, Some(1));
        assert_eq!(e.message(&Source), None);
    }

    #[test]
    fn hevc_eac3() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "hevc", 0, None, None),
            feed("Audio", "eac3", 1, Some(6), Some(true)),
        ]));
        assert!(e.fitting());
    }

    #[test]
    fn hvc1() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "hvc1", 0, None, None),
            feed("Audio", "ac3", 1, None, None),
        ]));
        assert!(e.fitting());
    }

    #[test]
    fn dts_all() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "h264", 0, None, None),
            feed("Audio", "dts", 1, Some(6), Some(true)),
        ]));
        assert!(!e.fitting());
        assert_eq!(e.audio_track, None);
        assert_eq!(e.obstacles.len(), 1);
        assert_eq!(e.obstacles.first().map(|o| o.art), Some(Art::Audio));
        assert_eq!(e.obstacles.first().map(|o| o.codec.as_str()), Some("dts"));
        assert!(e.message(&Source).is_some());
    }

    #[test]
    fn truehd() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "hevc", 0, None, None),
            feed("Audio", "truehd", 1, None, Some(true)),
        ]));
        assert!(!e.fitting());
        assert_eq!(e.obstacles.first().map(|o| o.art), Some(Art::Audio));
    }

    #[test]
    fn av1() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "av1", 0, None, None),
            feed("Audio", "aac", 1, None, Some(true)),
        ]));
        assert!(!e.fitting());
        assert_eq!(e.obstacles.len(), 1);
        assert_eq!(e.obstacles.first().map(|o| o.art), Some(Art::Video));
        assert_eq!(e.obstacles.first().map(|o| o.codec.as_str()), Some("av1"));
    }

    #[test]
    fn beides() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "vc1", 0, None, None),
            feed("Audio", "dts", 1, None, Some(true)),
        ]));
        assert_eq!(e.obstacles.len(), 2);
        assert!(e.obstacles.iter().any(|o| o.art == Art::Video));
        assert!(e.obstacles.iter().any(|o| o.art == Art::Audio));
    }

    /// The untauglich default track must not win.
    #[test]
    fn dts_beside_ac3() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "h264", 0, None, None),
            feed("Audio", "dts", 1, Some(6), Some(true)),
            feed("Audio", "ac3", 2, Some(6), None),
        ]));
        assert!(e.fitting());
        assert_eq!(e.audio_track, Some(2));
    }

    #[test]
    fn standard_wins() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "h264", 0, None, None),
            feed("Audio", "aac", 1, Some(2), Some(true)),
            feed("Audio", "eac3", 2, Some(6), None),
        ]));
        assert_eq!(e.audio_track, Some(1));
    }

    /// On a tie the server's order is kept.
    #[test]
    fn most_channels() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "h264", 0, None, None),
            feed("Audio", "aac", 1, Some(2), None),
            feed("Audio", "eac3", 2, Some(6), None),
            feed("Audio", "ac3", 3, Some(6), None),
        ]));
        assert_eq!(e.audio_track, Some(2));
    }

    #[test]
    fn subtitle_irrelevant() {
        let e = AirPlaySuitability::check(&source(vec![
            feed("Video", "h264", 0, None, None),
            feed("Audio", "aac", 1, None, Some(true)),
            feed("Subtitle", "pgssub", 2, None, None),
        ]));
        assert!(e.fitting());
    }

    #[test]
    fn umpacken() {
        let e = AirPlaySuitability::new(None, vec![Obstacle::new(Art::Umpacken, "mkv")]);
        assert!(!e.fitting());
        assert_eq!(e.audio_track, None);
        assert!(e.message(&Source).is_some());
        // The container must appear in the message.
        assert!(
            e.message(&Source)
                .is_some_and(|m| m.to_lowercase().contains("mkv"))
        );
    }

    #[test]
    fn without_streams() {
        let e = AirPlaySuitability::check(&source(vec![]));
        assert!(e.fitting());
        assert_eq!(e.audio_track, None);
    }
}
