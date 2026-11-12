//! The JSON-lines wire between the Rust UI and a native engine that lives in another language (Media3 in Kotlin).
//!
//! No Rust-to-Java calls are needed: the Rust side queues commands, the Kotlin shell drains them once per frame
//! (`Native.engineCommands()`), and Kotlin pushes events with `Native.engineEvent(json)`. [`QueueEngine`] is the
//! Rust half; it is a [`SurfaceEngine`] with [`FrameDelivery::NativeOverlay`] (the video is a `SurfaceView` below the UI).

use crate::translate::text_cue;
use crate::{
    AudioDevice, Capabilities, DisplayHints, DynamicRange, FrameBuffer, FrameDelivery, FrameStatus,
    SurfaceEngine, VideoStats, VideoSurface,
};
use serde_json::{Value, json};
use std::sync::{Mutex, MutexGuard, PoisonError};
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, EngineTrack, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
};

#[derive(Default)]
struct Inner {
    commands: Vec<String>,
    events: Vec<EngineEvent>,
    hints: DisplayHints,
    stats: VideoStats,
    audio_ids: Vec<i64>,
    subtitle_ids: Vec<i64>,
    position: f64,
}

/// The Rust half of a native engine: queues commands out, parses events in.
#[derive(Default)]
pub struct QueueEngine {
    inner: Mutex<Inner>,
}

fn lock(m: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn tracks(v: Option<&Value>) -> Vec<EngineTrack> {
    let Some(Value::Array(list)) = v else {
        return Vec::new();
    };
    list.iter()
        .map(|t| EngineTrack {
            id: t["id"].as_i64().unwrap_or(-1),
            codec: t["codec"].as_str().unwrap_or("").to_owned(),
            language: t["lang"].as_str().map(str::to_owned),
            name: t["name"].as_str().unwrap_or("").to_owned(),
            channels: t["ch"].as_i64().unwrap_or(0),
            is_default: t["def"].as_bool().unwrap_or(false),
            is_forced: t["forced"].as_bool().unwrap_or(false),
        })
        .collect()
}

impl QueueEngine {
    /// A new, empty engine.
    pub fn new() -> QueueEngine {
        QueueEngine::default()
    }

    fn push(&self, v: Value) {
        lock(&self.inner).commands.push(v.to_string());
    }

    /// Takes the queued commands as JSON lines (one per line).
    pub fn take_commands(&self) -> String {
        std::mem::take(&mut lock(&self.inner).commands).join("\n")
    }

    /// Feeds one event line from the native side. Returns `false` when the line is not understood.
    pub fn feed(&self, line: &str) -> bool {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            return false;
        };
        let mut s = lock(&self.inner);
        let event = match v["e"].as_str().unwrap_or("") {
            "state" => EngineEvent::State(match v["s"].as_str().unwrap_or("") {
                "idle" => EngineState::Idle,
                "loading" => EngineState::Loading,
                "playing" => EngineState::Playing,
                "paused" => EngineState::Paused,
                "seeking" => EngineState::Seeking,
                "ended" => EngineState::Ended,
                "error" => EngineState::Error {
                    message: v["msg"].as_str().unwrap_or("").to_owned(),
                    kind: v["kind"].as_str().map(str::to_owned),
                },
                _ => return false,
            }),
            "first" => EngineEvent::FirstFrame,
            "clock" => {
                let p = v["p"].as_f64().unwrap_or(0.0);
                s.position = p;
                EngineEvent::Clock {
                    position: p,
                    source_time: p,
                }
            }
            "duration" => EngineEvent::Duration(v["d"].as_f64().unwrap_or(0.0)),
            "size" => {
                let (w, h) = (
                    v["w"].as_f64().unwrap_or(0.0),
                    v["h"].as_f64().unwrap_or(0.0),
                );
                s.hints.size = Some((w as u32, h as u32));
                EngineEvent::VideoSize {
                    width: w,
                    height: h,
                }
            }
            "tracks" => {
                let (audio, subtitles) = (tracks(v.get("audio")), tracks(v.get("sub")));
                s.audio_ids = audio.iter().map(|t| t.id).collect();
                s.subtitle_ids = subtitles.iter().map(|t| t.id).collect();
                EngineEvent::Tracks {
                    audio,
                    subtitles,
                    active_audio: v["aa"].as_i64(),
                    active_subtitle: v["as"].as_i64(),
                }
            }
            "cue" => EngineEvent::Cues(text_cue(v["text"].as_str().unwrap_or(""), s.position)),
            "hints" => {
                s.hints.range = match v["hdr"].as_str().unwrap_or("") {
                    "hdr10" => DynamicRange::Hdr10,
                    "hlg" => DynamicRange::Hlg,
                    "dv" => DynamicRange::DolbyVision,
                    _ => DynamicRange::Sdr,
                };
                s.hints.frame_rate = v["fps"].as_f64().filter(|f| *f > 0.0);
                return true;
            }
            "stats" => {
                s.stats.frames_rendered = v["rendered"].as_u64().unwrap_or(0);
                s.stats.decoder_drops = v["dropped"].as_u64().unwrap_or(0);
                s.stats.hwdec = v["codec"].as_str().unwrap_or("").to_owned();
                return true;
            }
            _ => return false,
        };
        s.events.push(event);
        true
    }
}

impl PlaybackEngine for QueueEngine {
    fn load(&self, r: EngineLoad) {
        self.push(json!({"c":"load","url":r.url,"headers":r.headers,"start":r.start,"audio":r.audio_server_index,
            "sub":r.subtitle_server_index,"software":r.software_decode,"fps_match":r.frame_rate_match,
            "external":r.external_subtitles.iter().map(|e| json!({"url":e.url,"name":e.name,"lang":e.language,"forced":e.is_forced})).collect::<Vec<_>>()}));
    }
    fn play(&self) {
        self.push(json!({"c":"play"}));
    }
    fn pause(&self) {
        self.push(json!({"c":"pause"}));
    }
    fn seek(&self, seconds: f64) {
        self.push(json!({"c":"seek","s":seconds}));
    }
    fn set_rate(&self, tempo: f32) {
        self.push(json!({"c":"rate","v":tempo}));
    }
    fn set_volume(&self, percent: u8) {
        self.push(json!({"c":"volume","v":percent}));
    }
    fn set_audio_delay(&self, milliseconds: i32) {
        self.push(json!({"c":"delay","ms":milliseconds}));
    }
    fn select_audio(&self, server_index: i32) -> bool {
        let known = lock(&self.inner)
            .audio_ids
            .contains(&i64::from(server_index));
        if known {
            self.push(json!({"c":"audio","i":server_index}));
        }
        known
    }
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute {
        if server_index >= 0
            && !lock(&self.inner)
                .subtitle_ids
                .contains(&i64::from(server_index))
        {
            return SubtitleRoute::Unsupported;
        }
        self.push(json!({"c":"sub","i":server_index}));
        SubtitleRoute::Cues
    }
    fn set_fill(&self, on: bool) {
        self.push(json!({"c":"fill","on":on}));
    }
    fn place(&self, rect: Rect) {
        self.push(json!({"c":"place","x":rect.x,"y":rect.y,"w":rect.width,"h":rect.height}));
    }
    fn stop(&self, reset_display: bool) {
        self.push(json!({"c":"stop","reset":reset_display}));
    }
    fn pip(&self, command: PipCmd) {
        self.push(json!({"c":"pip","v":format!("{command:?}")}));
    }
}

impl VideoSurface for QueueEngine {
    fn delivery(&self) -> FrameDelivery {
        FrameDelivery::NativeOverlay
    }
    fn place(&self, rect: Rect) {
        PlaybackEngine::place(self, rect);
    }
    fn acquire_frame(&self, _w: u32, _h: u32, _out: &mut FrameBuffer) -> FrameStatus {
        FrameStatus::NotReady
    }
    fn display_hints(&self) -> DisplayHints {
        lock(&self.inner).hints
    }
}

impl SurfaceEngine for QueueEngine {
    fn poll_events(&self) -> Vec<EngineEvent> {
        std::mem::take(&mut lock(&self.inner).events)
    }
    fn stats(&self) -> VideoStats {
        lock(&self.inner).stats.clone()
    }
    fn audio_devices(&self) -> Vec<AudioDevice> {
        Vec::new()
    }
    fn set_audio_device(&self, _id: &str) -> bool {
        false
    }
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            hdr_passthrough: true,
            frame_rate_match: true,
            pip: true,
            audio_devices: false,
            draws_bitmap_subtitles: false,
            audio_passthrough: false,
            exclusive_audio: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_queue_as_json_lines_and_drain() {
        let e = QueueEngine::new();
        e.play();
        e.seek(12.5);
        e.set_volume(40);
        let lines = e.take_commands();
        assert_eq!(lines.lines().count(), 3);
        assert!(lines.contains(r#""c":"seek""#) && lines.contains("12.5"));
        assert_eq!(e.take_commands(), "");
    }

    #[test]
    fn events_parse_in_order() {
        let e = QueueEngine::new();
        assert!(e.feed(r#"{"e":"state","s":"loading"}"#));
        assert!(e.feed(r#"{"e":"duration","d":60.0}"#));
        assert!(e.feed(r#"{"e":"first"}"#));
        assert!(
            e.feed(r#"{"e":"tracks","audio":[{"id":1,"codec":"eac3","ch":6}],"sub":[],"aa":1}"#)
        );
        assert!(e.feed(r#"{"e":"state","s":"error","msg":"boom"}"#));
        assert!(!e.feed("garbage"));
        let ev = e.poll_events();
        assert_eq!(ev.len(), 5);
        assert_eq!(ev[0], EngineEvent::State(EngineState::Loading));
        assert!(
            matches!(&ev[3], EngineEvent::Tracks { audio, active_audio: Some(1), .. } if audio[0].channels == 6)
        );
        assert!(e.poll_events().is_empty());
    }

    #[test]
    fn track_selection_checks_the_known_lists() {
        let e = QueueEngine::new();
        assert!(!e.select_audio(3));
        assert_eq!(e.select_subtitle(7), SubtitleRoute::Unsupported);
        assert_eq!(e.select_subtitle(-1), SubtitleRoute::Cues);
        e.feed(r#"{"e":"tracks","audio":[{"id":3}],"sub":[{"id":7}]}"#);
        assert!(e.select_audio(3));
        assert_eq!(e.select_subtitle(7), SubtitleRoute::Cues);
    }

    #[test]
    fn hints_and_stats_do_not_make_events() {
        let e = QueueEngine::new();
        e.feed(r#"{"e":"hints","hdr":"dv","fps":23.976}"#);
        e.feed(r#"{"e":"stats","rendered":100,"dropped":2}"#);
        assert!(e.poll_events().is_empty());
        assert_eq!(e.display_hints().range, DynamicRange::DolbyVision);
        assert_eq!(e.stats().frames_rendered, 100);
        assert_eq!(e.delivery(), FrameDelivery::NativeOverlay);
    }
}
