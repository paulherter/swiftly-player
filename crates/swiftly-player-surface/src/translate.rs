//! Pure translation of mpv's property values into the engine contract (host-testable, no libmpv needed).

use crate::{DisplayHints, DynamicRange};
use serde_json::Value;
use swiftly_playback::engine::{Cue, CueBody, EngineEvent, EngineTrack, SubtitleTextStyle};

/// Engine ids of external subtitle files start here, so they never clash with a server stream index.
pub const EXTERNAL_BASE: i64 = 1000;

/// The track lists plus the mapping from our ids to mpv's per-type ids (`aid`, `sid`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ParsedTracks {
    /// Audio tracks.
    pub audio: Vec<EngineTrack>,
    /// Subtitle tracks.
    pub subtitles: Vec<EngineTrack>,
    /// Active audio track (our id).
    pub active_audio: Option<i64>,
    /// Active subtitle track (our id).
    pub active_subtitle: Option<i64>,
    /// `(our id, mpv aid)` for every audio track.
    pub audio_ids: Vec<(i64, i64)>,
    /// `(our id, mpv sid)` for every subtitle track.
    pub subtitle_ids: Vec<(i64, i64)>,
}

impl ParsedTracks {
    /// The `EngineEvent::Tracks` for this list.
    pub fn event(&self) -> EngineEvent {
        EngineEvent::Tracks {
            audio: self.audio.clone(),
            subtitles: self.subtitles.clone(),
            active_audio: self.active_audio,
            active_subtitle: self.active_subtitle,
        }
    }
}

/// Parses mpv's `track-list` (JSON text). The id of a file's own track is its `ff-index` (the server's `Index`);
/// external files get `EXTERNAL_BASE + position among the external tracks of that kind`, the id the core expects
/// (`EngineRequest::external_track_id_base` + position in the file list it handed over at load).
pub fn parse_tracks(json: &str) -> ParsedTracks {
    let mut out = ParsedTracks::default();
    let Ok(Value::Array(list)) = serde_json::from_str::<Value>(json) else {
        return out;
    };
    let (mut ext_audio, mut ext_sub) = (0_i64, 0_i64);
    for t in &list {
        let kind = t.get("type").and_then(Value::as_str).unwrap_or("");
        if kind != "audio" && kind != "sub" {
            continue;
        }
        let mpv_id = t.get("id").and_then(Value::as_i64).unwrap_or(0);
        let external = t.get("external").and_then(Value::as_bool).unwrap_or(false);
        let id = match t.get("ff-index").and_then(Value::as_i64) {
            Some(ff) if !external => ff,
            _ => {
                let n = if kind == "audio" {
                    &mut ext_audio
                } else {
                    &mut ext_sub
                };
                *n += 1;
                EXTERNAL_BASE + *n - 1
            }
        };
        let flag = |k: &str| t.get(k).and_then(Value::as_bool).unwrap_or(false);
        let text = |k: &str| t.get(k).and_then(Value::as_str).map(str::to_owned);
        let track = EngineTrack {
            id,
            codec: text("codec").unwrap_or_default(),
            language: text("lang"),
            name: text("title").unwrap_or_default(),
            channels: t
                .get("demux-channel-count")
                .and_then(Value::as_i64)
                .unwrap_or(0),
            is_default: flag("default"),
            is_forced: flag("forced"),
        };
        let selected = flag("selected");
        if kind == "audio" {
            if selected {
                out.active_audio = Some(id);
            }
            out.audio_ids.push((id, mpv_id));
            out.audio.push(track);
        } else {
            if selected {
                out.active_subtitle = Some(id);
            }
            out.subtitle_ids.push((id, mpv_id));
            out.subtitles.push(track);
        }
    }
    out
}

/// Display hints from mpv's `video-params` (JSON text) and the container frame rate.
pub fn parse_hints(video_params: &str, fps: Option<f64>) -> DisplayHints {
    let v: Value = serde_json::from_str(video_params).unwrap_or(Value::Null);
    let gamma = v.get("gamma").and_then(Value::as_str).unwrap_or("");
    let range = match gamma {
        "pq" => DynamicRange::Hdr10,
        "hlg" => DynamicRange::Hlg,
        _ => DynamicRange::Sdr,
    };
    let dim = |k: &str| {
        v.get(k)
            .and_then(Value::as_u64)
            .and_then(|n| u32::try_from(n).ok())
    };
    let size = dim("dw").zip(dim("dh")).or_else(|| dim("w").zip(dim("h")));
    DisplayHints {
        range,
        frame_rate: fps.filter(|f| *f > 0.0),
        size,
    }
}

/// An external subtitle file waiting for the file to load, then added with `sub-add`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingSub {
    /// Address.
    pub url: String,
    /// Title, if known.
    pub title: Option<String>,
    /// Language, if known.
    pub language: Option<String>,
}

/// libass sizes a font by its line cell (ascent + descent), not by the em: Inter's cell, as measured against the Apple overlay, is this many ems tall.
/// Measured against the Apple overlay (`subtitles-desktop.md`), so `sub-font-size` gives the same letter height.
pub const INTER_CELL: f64 = 1.334;

/// How far the Apple text box reaches below the lowest ink, in ems (measured: 13.5 px at a 52.65 px text).
const BOX_BELOW_EM: f64 = 0.255;

/// mpv draws subtitles on a 720-line scale: sizes and margins below are in those units.
const SCALE_LINES: f64 = 720.0;

/// The `sub-*` options for a look at the size of the picture the subtitles are drawn on (`out_w` x `out_h` pixels).
/// Text size, outline and margins are shares of the picture, so the weight of the text is the same in every window
/// (the Apple overlay: text `height * 0.0625 * scale`, outline in percent of the text, bottom margin 16 pt).
pub fn text_options(
    style: &SubtitleTextStyle,
    out_w: u32,
    out_h: u32,
) -> Vec<(&'static str, String)> {
    let h = f64::from(out_h.max(2));
    let em = style.text_share * SCALE_LINES;
    let border = if style.background {
        em * 0.15
    } else {
        em * style.outline_em
    };
    // The Apple overlay measures its 16 points from the bottom of the text box, which reaches a quarter em below
    // the descenders; libass measures from the line's descent. The extra keeps the ink at the same place.
    // `margin_px` is in points: the frame is the picture, `picture_pt` points tall on screen.
    let px_per_pt = if style.picture_pt > 0.0 {
        h / style.picture_pt
    } else {
        1.0
    };
    let margin_y = (style.margin_px * px_per_pt + style.margin_share * h) * SCALE_LINES / h
        + em * BOX_BELOW_EM;
    let margin_x = f64::from(out_w) * 0.05 * SCALE_LINES / h;
    let mut o = vec![
        ("sub-font", style.font.clone()),
        ("sub-font-size", format!("{:.2}", em * INTER_CELL)),
        ("sub-scale", "1".to_owned()),
        ("sub-bold", "no".to_owned()),
        ("sub-italic", "no".to_owned()),
        ("sub-color", format!("#FF{:06X}", style.colour & 0xFF_FFFF)),
        (
            "sub-border-style",
            if style.background {
                "background-box"
            } else {
                "outline-and-shadow"
            }
            .to_owned(),
        ),
        ("sub-border-color", "#E6000000".to_owned()),
        ("sub-border-size", format!("{border:.2}")),
        (
            "sub-back-color",
            if style.background {
                "#A0000000"
            } else {
                "#00000000"
            }
            .to_owned(),
        ),
        ("sub-margin-y", format!("{margin_y:.0}")),
        ("sub-margin-x", format!("{margin_x:.0}")),
    ];
    if style.shadow && !style.background {
        o.push(("sub-shadow-color", "#A0000000".to_owned()));
        o.push(("sub-shadow-offset", format!("{:.2}", em * 0.04)));
    } else {
        o.push(("sub-shadow-offset", "0".to_owned()));
    }
    o
}

/// `sub-ass-override` for a text track: ASS and SSA keep their own style when the look says so, everything else
/// (SRT, VTT, a server-converted SRT) is plain text and takes the look.
pub fn ass_override(codec: &str, keep_file_style: bool) -> &'static str {
    if keep_file_style && matches!(codec, "ass" | "ssa") {
        "no"
    } else {
        "force"
    }
}

/// A subtitle text from `sub-text` as the single current cue (empty text = no cue).
pub fn text_cue(text: &str, position: f64) -> Vec<Cue> {
    if text.trim().is_empty() {
        return Vec::new();
    }
    // mpv only tells us what is on screen now; the cue is valid until the next property change.
    vec![Cue {
        id: 1,
        start: position,
        end: position + 1.0e6,
        body: CueBody::Text(text.to_owned()),
    }]
}

/// Where a file is on its way to the end. With `keep-open=yes` libmpv sends no end-file at the end of the file: it
/// pauses on the last frame and flips `eof-reached` instead. This is the one place that turns that flag into
/// `EngineState::Ended`, exactly once per file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EofGate {
    /// The file has not reached its end (also: not loaded yet).
    #[default]
    Running,
    /// `Ended` was reported; the last frame stays up and the engine's own pause is not a user pause.
    Ended,
}

/// What happens to the gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EofInput {
    /// `eof-reached` changed (`true` at the end, `false` after a seek back or at a new file).
    Flag(bool),
    /// libmpv sent `end-file` with reason EOF (keep-open off, or a playlist).
    EndFile,
    /// A seek started or a new file starts.
    Reset,
}

impl EofGate {
    /// Returns the next gate and whether `Ended` is to be reported now. `loaded` is false until the file's own
    /// `file-loaded`: a flag that was queued by the previous file must not end the new one.
    #[must_use]
    pub fn step(self, input: EofInput, loaded: bool) -> (EofGate, bool) {
        match (self, input) {
            (EofGate::Running, EofInput::Flag(true)) if loaded => (EofGate::Ended, true),
            (EofGate::Running, EofInput::EndFile) => (EofGate::Ended, true),
            (EofGate::Ended, EofInput::Flag(false) | EofInput::Reset) => (EofGate::Running, false),
            (gate, _) => (gate, false),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TRACKS: &str = r#"[
      {"id":1,"type":"video","codec":"hevc"},
      {"id":1,"type":"audio","codec":"eac3","lang":"deu","title":"Deutsch","default":true,"selected":true,"ff-index":1,"demux-channel-count":6},
      {"id":2,"type":"audio","codec":"aac","lang":"eng","ff-index":2,"demux-channel-count":2},
      {"id":1,"type":"sub","codec":"subrip","lang":"eng","forced":true,"ff-index":3},
      {"id":2,"type":"sub","codec":"subrip","external":true,"selected":true}
    ]"#;

    #[test]
    fn tracks_use_ff_index_and_external_base() {
        let t = parse_tracks(TRACKS);
        assert_eq!(t.audio.len(), 2);
        assert_eq!(t.active_audio, Some(1));
        assert_eq!(t.audio_ids, vec![(1, 1), (2, 2)]);
        assert_eq!(t.audio[0].channels, 6);
        assert!(t.audio[0].is_default);
        assert_eq!(t.subtitles[0].id, 3);
        assert!(t.subtitles[0].is_forced);
        assert_eq!(t.subtitles[1].id, EXTERNAL_BASE);
        assert_eq!(t.active_subtitle, Some(EXTERNAL_BASE));
        assert_eq!(t.subtitle_ids, vec![(3, 1), (EXTERNAL_BASE, 2)]);
    }

    fn look(share: f64) -> SubtitleTextStyle {
        SubtitleTextStyle {
            font: "Inter 18pt SemiBold".into(),
            text_share: share,
            colour: 0xFFFFFF,
            outline_em: 0.03,
            shadow: false,
            background: false,
            margin_px: 16.0,
            picture_pt: 0.0,
            margin_share: 0.0,
            keep_file_style: true,
        }
    }

    #[test]
    fn the_look_maps_to_libass_options() {
        // Apple Mac/desktop default: text 0.0625 * 0.78 of the picture height.
        let o = text_options(&look(0.0625 * 0.78), 1920, 1080);
        let get = |k: &str| o.iter().find(|(n, _)| *n == k).map(|(_, v)| v.as_str());
        assert_eq!(get("sub-font"), Some("Inter 18pt SemiBold"));
        assert_eq!(get("sub-font-size"), Some("46.82"));
        assert_eq!(get("sub-color"), Some("#FFFFFFFF"));
        assert_eq!(get("sub-border-size"), Some("1.05"));
        assert_eq!(get("sub-border-style"), Some("outline-and-shadow"));
        assert_eq!(get("sub-shadow-offset"), Some("0"));
        assert_eq!(get("sub-back-color"), Some("#00000000"));
        // 16 px on 1080 lines = 10.67 of 720, plus the quarter em below the descenders (8.8).
        assert_eq!(get("sub-margin-y"), Some("20"));
        assert_eq!(get("sub-margin-x"), Some("64"));
        // Same look in a 720p window: the margin is 16 of 720 plus the box, the size share is unchanged.
        let small = text_options(&look(0.0625 * 0.78), 1280, 720);
        assert_eq!(
            small
                .iter()
                .find(|(n, _)| *n == "sub-margin-y")
                .map(|(_, v)| v.as_str()),
            Some("25")
        );
        assert_eq!(
            small
                .iter()
                .find(|(n, _)| *n == "sub-font-size")
                .map(|(_, v)| v.as_str()),
            Some("46.82")
        );
        // Raised: plus 7 % of the height; shadow and box.
        let mut raised = look(0.0625 * 0.78);
        (raised.margin_share, raised.shadow) = (0.07, true);
        let o = text_options(&raised, 1920, 1080);
        assert_eq!(
            o.iter()
                .find(|(n, _)| *n == "sub-margin-y")
                .map(|(_, v)| v.as_str()),
            Some("70")
        );
        assert_eq!(
            o.iter()
                .find(|(n, _)| *n == "sub-shadow-color")
                .map(|(_, v)| v.as_str()),
            Some("#A0000000")
        );
        let mut boxed = look(0.05);
        boxed.background = true;
        let o = text_options(&boxed, 1920, 1080);
        assert_eq!(
            o.iter()
                .find(|(n, _)| *n == "sub-border-style")
                .map(|(_, v)| v.as_str()),
            Some("background-box")
        );
        assert_eq!(
            o.iter()
                .find(|(n, _)| *n == "sub-back-color")
                .map(|(_, v)| v.as_str()),
            Some("#A0000000")
        );
    }

    #[test]
    fn only_a_native_ass_track_with_the_switch_keeps_its_style() {
        assert_eq!(ass_override("ass", true), "no");
        assert_eq!(ass_override("ssa", true), "no");
        assert_eq!(ass_override("ass", false), "force");
        assert_eq!(ass_override("subrip", true), "force");
        assert_eq!(ass_override("webvtt", true), "force");
    }

    #[test]
    fn bad_json_gives_empty_lists() {
        assert_eq!(parse_tracks("nonsense"), ParsedTracks::default());
    }

    #[test]
    fn hints_read_pq_hlg_and_size() {
        let h = parse_hints(
            r#"{"w":3840,"h":2160,"dw":3840,"dh":2160,"gamma":"pq"}"#,
            Some(23.976),
        );
        assert_eq!(h.range, DynamicRange::Hdr10);
        assert_eq!(h.size, Some((3840, 2160)));
        assert_eq!(h.frame_rate, Some(23.976));
        assert_eq!(
            parse_hints(r#"{"gamma":"hlg"}"#, None).range,
            DynamicRange::Hlg
        );
        assert_eq!(parse_hints("", Some(0.0)), DisplayHints::default());
    }

    #[test]
    fn empty_text_is_no_cue() {
        assert!(text_cue("  ", 1.0).is_empty());
        assert_eq!(text_cue("Hallo", 2.0).len(), 1);
    }
    #[test]
    fn eof_gate_reports_ended_once_per_file() {
        use EofGate::{Ended, Running};
        use EofInput::{EndFile, Flag, Reset};
        let table = [
            // (from, input, loaded, to, reports)
            (Running, Flag(true), true, Ended, true),
            (Ended, Flag(true), true, Ended, false),
            (Ended, EndFile, true, Ended, false),
            (Running, EndFile, true, Ended, true),
            (Ended, Flag(false), true, Running, false),
            (Ended, Reset, true, Running, false),
            (Running, Flag(false), true, Running, false),
            (Running, Reset, true, Running, false),
            // A flag of the previous file, before the new one is loaded: ignored.
            (Running, Flag(true), false, Running, false),
        ];
        for (from, input, loaded, to, reports) in table {
            assert_eq!(
                from.step(input, loaded),
                (to, reports),
                "{from:?} + {input:?}"
            );
        }
    }
}
