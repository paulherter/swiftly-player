//! Port of the engine-neutral part of `FirstFrame.swift` (JellyfinKit): the clock runs, the
//! audio plays, and no picture ever came. The rescue ladder (output rebuild, software decoder,
//! give up) as pure data and functions. Time is `f64` seconds of movie time.

use swiftly_model::DeliveryMethod;
use swiftly_model::Localizer;

/// This much movie time without a single shown picture before intervening, in seconds
/// (FirstFrame.swift:30).
pub const DEADLINE: f64 = 4.0;

/// Largest clock step that counts as playing time; a larger step is a seek
/// (FirstFrame.swift:34).
pub const LARGEST_STEP: f64 = 2.0;

/// What has already been tried. Applies to a title, not to a rebuild (FirstFrame.swift:37).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    /// Nothing yet.
    No = 0,
    /// Stream and output reopened at the same position.
    OutputNew = 1,
    /// Reopened with the software decoder.
    Software = 2,
    /// That stayed black too. From here on, leave it alone.
    GivenUp = 3,
}

/// What the rule advises (FirstFrame.swift:49, `Rat`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rat {
    /// No case: picture present, no video track, excluded, or already given up.
    Nothing,
    /// Not yet [`DEADLINE`] of movie time without a picture.
    Wait,
    /// First rescue: rebuild stream and output at the same position.
    OutputNew,
    /// Second rescue: reopen with the software decoder.
    SoftwareDecoder,
    /// Both stayed black: log it, show a notice, do nothing more.
    GiveUp,
}

/// The advice for the current state (FirstFrame.swift:70).
///
/// `has_video_track`: whether the server names a video track (pure audio files have none).
/// `excluded`: picture-in-picture, AirPlay, pause. `shown`: pictures shown since the last
/// rebuild. `runtime`: movie time since the last rebuild during which the clock ran.
/// `until_from`: what has already been tried for this title.
pub fn rat(
    has_video_track: bool,
    excluded: bool,
    shown: u64,
    runtime: f64,
    until_from: Level,
) -> Rat {
    if !has_video_track || excluded || shown != 0 {
        return Rat::Nothing;
    }
    if until_from == Level::GivenUp {
        return Rat::Nothing;
    }
    if runtime < DEADLINE {
        return Rat::Wait;
    }
    match until_from {
        Level::No => Rat::OutputNew,
        Level::OutputNew => Rat::SoftwareDecoder,
        Level::Software => Rat::GiveUp,
        Level::GivenUp => Rat::Nothing,
    }
}

/// The stage that applies after an advice (FirstFrame.swift:85).
pub fn next(to: Rat, until_from: Level) -> Level {
    match to {
        Rat::OutputNew => Level::OutputNew,
        Rat::SoftwareDecoder => Level::Software,
        Rat::GiveUp => Level::GivenUp,
        Rat::Nothing | Rat::Wait => until_from,
    }
}

/// How much movie time really passed between two looks (FirstFrame.swift:99).
///
/// Zero if there is no previous value, the clock stood or went backwards, and for a step above
/// [`LARGEST_STEP`], which was a seek.
pub fn growth(before: Option<f64>, now: f64) -> f64 {
    let Some(before) = before else {
        return 0.0;
    };
    let step = now - before;
    if step > 0.0 && step <= LARGEST_STEP {
        step
    } else {
        0.0
    }
}

/// The option that makes VLC decode in software (FirstFrame.swift:113).
pub const SOFTWARE_OPTION: &str = ":codec=avcodec,any";

/// The same for libVLC 3 on Linux and Windows, where hardware sits inside avcodec itself
/// (FirstFrame.swift:121).
pub const SOFTWARE_OPTIONS_DESKTOP: [&str; 2] = [SOFTWARE_OPTION, ":avcodec-hw=none"];

/// MPEG-4 Part 2 (XviD, DivX) in software from the start, only when the stream arrives
/// unchanged (FirstFrame.swift:140).
pub fn software_from_start(video_codec: Option<&str>, method: DeliveryMethod) -> bool {
    if method == DeliveryMethod::Transcode {
        return false;
    }
    video_codec.is_some_and(|c| c.to_lowercase() == "mpeg4")
}

/// Catalog key of the technical-badge notice for a level, or `None` while there is nothing to
/// say (FirstFrame.swift:146-151, German source text as key).
pub fn hint_key(rung: Level) -> Option<&'static str> {
    match rung {
        Level::No => None,
        Level::OutputNew => Some("Kein Bild vom Dekoder – Wiedergabe neu aufgebaut"),
        Level::Software => Some("Kein Bild vom Dekoder – Software-Dekoder aktiv"),
        Level::GivenUp => Some("Kein Bild vom Dekoder – auch Software-Dekoder ohne Bild"),
    }
}

/// The notice for the technical badge through a localizer, or `None` (FirstFrame.swift:146).
pub fn hint(rung: Level, l: &dyn Localizer) -> Option<String> {
    hint_key(rung).map(|key| l.text(key, &[]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_model::MediaSource;
    use swiftly_model::Source;

    fn rat(video: bool, from: bool, shown: u64, run: f64, until_from: Level) -> Rat {
        super::rat(video, from, shown, run, until_from)
    }

    /// Swift helper defaults: video true, excluded false, shown 0, run 5, level .no.
    fn rat_at(until_from: Level) -> Rat {
        rat(true, false, 0, 5.0, until_from)
    }

    fn rat_run(run: f64) -> Rat {
        rat(true, false, 0, run, Level::No)
    }

    #[test]
    fn levels() {
        assert_eq!(rat_at(Level::No), Rat::OutputNew);
        assert_eq!(rat_at(Level::OutputNew), Rat::SoftwareDecoder);
        assert_eq!(rat_at(Level::Software), Rat::GiveUp);
        assert_eq!(rat_at(Level::GivenUp), Rat::Nothing);
        let mut rung = Level::No;
        let mut episode: Vec<Rat> = Vec::new();
        for _ in 0..5 {
            let r = rat_at(rung);
            episode.push(r);
            rung = next(r, rung);
        }
        assert_eq!(
            episode,
            [
                Rat::OutputNew,
                Rat::SoftwareDecoder,
                Rat::GiveUp,
                Rat::Nothing,
                Rat::Nothing
            ]
        );
    }

    #[test]
    fn deadline() {
        assert_eq!(rat_run(0.0), Rat::Wait);
        assert_eq!(rat_run(DEADLINE - 0.5), Rat::Wait);
        assert_eq!(rat_run(DEADLINE), Rat::OutputNew);
    }

    #[test]
    fn exceptions() {
        assert_eq!(rat(true, false, 1, 60.0, Level::No), Rat::Nothing);
        assert_eq!(rat(false, false, 0, 60.0, Level::No), Rat::Nothing);
        assert_eq!(rat(true, true, 0, 60.0, Level::No), Rat::Nothing);
        assert_eq!(rat(true, false, 1, 5.0, Level::Software), Rat::Nothing);
    }

    #[test]
    fn growth() {
        assert_eq!(super::growth(None, 10.0), 0.0);
        assert_eq!(super::growth(Some(10.0), 10.0), 0.0); // buffering, pause
        assert_eq!(super::growth(Some(10.0), 9.0), 0.0); // backwards
        assert_eq!(super::growth(Some(10.0), 11.0), 1.0);
        assert_eq!(super::growth(Some(10.0), 610.0), 0.0); // jump
        // Ten ticks of buffering, then four seconds of film: only then due.
        let mut run = 0.0;
        let mut before: Option<f64> = None;
        for t in [
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0,
        ] {
            run += super::growth(before, t);
            before = Some(t);
        }
        assert_eq!(rat_run(run), Rat::Wait);
        run += super::growth(before, 4.0);
        assert_eq!(rat_run(run), Rat::OutputNew);
    }

    #[test]
    fn hint() {
        assert!(super::hint(Level::No, &Source).is_none());
        assert!(super::hint(Level::Software, &Source).is_some());
        assert!(super::hint(Level::GivenUp, &Source).is_some());
    }

    // FirstFrameSoftwareTests

    #[test]
    fn mpeg4() {
        assert!(software_from_start(
            Some("mpeg4"),
            DeliveryMethod::DirectPlay
        ));
        assert!(software_from_start(
            Some("MPEG4"),
            DeliveryMethod::DirectStream
        ));
        assert!(!software_from_start(
            Some("mpeg4"),
            DeliveryMethod::Transcode
        ));
        assert!(!software_from_start(
            Some("h264"),
            DeliveryMethod::DirectPlay
        ));
        assert!(!software_from_start(
            Some("hevc"),
            DeliveryMethod::DirectPlay
        ));
        assert!(!software_from_start(None, DeliveryMethod::DirectPlay));
    }

    // FirstFrameSlabTests (only `desktop`; `slab`, `entries`, `list` need PlaybackPlan.fromSlab
    // and DownloadItem, which do not exist in Rust yet)

    #[test]
    fn desktop() {
        assert_eq!(
            SOFTWARE_OPTIONS_DESKTOP,
            [SOFTWARE_OPTION, ":avcodec-hw=none"]
        );
    }

    // MediaSourceImageCodecTests

    #[test]
    fn codec() {
        let q: Result<MediaSource, _> = serde_json::from_str(
            r#"{"MediaStreams":[{"Type":"Audio","Codec":"mp3"},{"Type":"Video","Codec":"mpeg4"}]}"#,
        );
        assert_eq!(q.as_ref().ok().and_then(|q| q.video_codec()), Some("mpeg4"));
        let empty: Result<MediaSource, _> = serde_json::from_str(r#"{"MediaStreams":[]}"#);
        assert!(empty.is_ok());
        assert_eq!(empty.as_ref().ok().and_then(|q| q.video_codec()), None);
    }
}
