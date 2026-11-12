//! The player view model never calls the host engine under its lock, also for the two commands
//! that answer (`select_audio`, `select_subtitle`), and the subtitle delay is an engine command.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_model::MediaStream;
use swiftly_playback::decoder_choice::AudioOutputMode;
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineTrack, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
};
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::track_label::LabelText;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::delay::Delay;
use swiftly_vm::{PlayerIntent, PlayerPrefs, PlayerSpec, PlayerVm, ReportMessage, Reporter};

/// A host engine that records calls; `select_audio` / `select_subtitle` can block until released,
/// like a Swift callback that hops to the main thread while the main thread waits on the view
/// model.
#[derive(Default)]
struct Host {
    calls: Mutex<Vec<String>>,
    block: AtomicBool,
    entered: AtomicBool,
    release: AtomicBool,
}

impl Host {
    fn log(&self, s: String) {
        self.calls.lock().unwrap().push(s);
    }
    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
    fn hold(&self) {
        if !self.block.load(Ordering::SeqCst) {
            return;
        }
        self.entered.store(true, Ordering::SeqCst);
        let until = Instant::now() + Duration::from_secs(10);
        while !self.release.load(Ordering::SeqCst) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

impl PlaybackEngine for Host {
    fn load(&self, request: EngineLoad) {
        self.log(format!("load {:?}", request.start));
    }
    fn play(&self) {
        self.log("play".into());
    }
    fn pause(&self) {
        self.log("pause".into());
    }
    fn seek(&self, seconds: f64) {
        self.log(format!("seek {seconds}"));
    }
    fn set_rate(&self, tempo: f32) {
        self.log(format!("rate {tempo}"));
    }
    fn set_volume(&self, percent: u8) {
        self.log(format!("volume {percent}"));
    }
    fn set_audio_delay(&self, milliseconds: i32) {
        self.log(format!("audio-delay {milliseconds}"));
    }
    fn set_subtitle_delay(&self, milliseconds: i32) {
        self.log(format!("subtitle-delay {milliseconds}"));
    }
    fn select_audio(&self, server_index: i32) -> bool {
        self.hold();
        self.log(format!("audio {server_index}"));
        true
    }
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute {
        self.hold();
        self.log(format!("subtitle {server_index}"));
        SubtitleRoute::Cues
    }
    fn set_fill(&self, on: bool) {
        self.log(format!("fill {on}"));
    }
    fn place(&self, _rect: Rect) {}
    fn stop(&self, reset_display: bool) {
        self.log(format!("stop {reset_display}"));
    }
    fn pip(&self, command: PipCmd) {
        self.log(format!("pip {command:?}"));
    }
    fn set_audio_output(&self, _mode: &AudioOutputMode) {}
}

#[derive(Default)]
struct Silent;

impl Reporter for Silent {
    fn report(&self, _message: ReportMessage) {}
}

struct Words;
impl LabelText for Words {
    fn language_name(&self, code: &str) -> Option<String> {
        matches!(code, "eng" | "deu").then(|| code.to_owned())
    }
    fn knows_code(&self, code: &str) -> bool {
        matches!(code, "eng" | "deu")
    }
    fn unknown(&self) -> String {
        "unbekannt".into()
    }
    fn forced(&self) -> String {
        "Erzwungen".into()
    }
    fn hearing_impaired(&self) -> String {
        "Hörgeschädigt".into()
    }
    fn file(&self) -> String {
        "Datei".into()
    }
}

fn stream(index: i64, kind: &str, language: &str, codec: &str) -> MediaStream {
    MediaStream {
        index: Some(index),
        type_: Some(kind.into()),
        language: Some(language.into()),
        codec: Some(codec.into()),
        channels: (kind == "Audio").then_some(6),
        ..MediaStream::default()
    }
}

fn spec() -> PlayerSpec {
    PlayerSpec {
        item_id: "ep1".into(),
        title: "Pilot".into(),
        plan: ReportPlan {
            play_session_id: Some("s1".into()),
            media_source_id: Some("m1".into()),
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: "ep1".into(),
            streams: vec![
                stream(1, "Audio", "eng", "ac3"),
                stream(2, "Audio", "deu", "eac3"),
                stream(3, "Subtitle", "eng", "subrip"),
            ],
            runtime: 3600.0,
            subtitle_files: Vec::new(),
            url: "https://tv.example.test/v".into(),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: 0.0,
        audio_index: Some(2),
        subtitle_index: -1,
        next: None,
        series_id: Some("show".into()),
        track_title: Some("acct|show".into()),
        downloaded: false,
    }
}

fn player(host: &Arc<Host>) -> Arc<PlayerVm<Host, Silent>> {
    let vm = Arc::new(PlayerVm::new(
        host.clone(),
        Arc::new(Silent),
        Arc::new(Words),
        PlayerPrefs::default(),
        spec(),
        100.0,
    ));
    vm.start(100.0);
    vm
}

fn track(id: i64, language: &str) -> EngineTrack {
    EngineTrack {
        id,
        codec: "ac3".into(),
        language: Some(language.into()),
        name: String::new(),
        channels: 6,
        is_default: false,
        is_forced: false,
    }
}

fn tracks_event() -> EngineEvent {
    EngineEvent::Tracks {
        audio: vec![track(1, "eng"), track(2, "deu")],
        subtitles: Vec::new(),
        active_audio: Some(2),
        active_subtitle: None,
    }
}

#[test]
fn the_subtitle_delay_is_an_engine_command_once_per_change() {
    let host = Arc::new(Host::default());
    let vm = player(&host);
    vm.send(
        PlayerIntent::SubtitleDelay(Delay::from_milliseconds(500)),
        101.0,
    );
    vm.send(
        PlayerIntent::SubtitleDelay(Delay::from_milliseconds(500)),
        102.0,
    );
    vm.send(
        PlayerIntent::SubtitleDelay(Delay::from_milliseconds(-250)),
        103.0,
    );
    let calls = host.calls();
    assert_eq!(
        calls.iter().filter(|c| *c == "subtitle-delay 500").count(),
        1,
        "{calls:?}"
    );
    assert_eq!(
        calls.iter().filter(|c| *c == "subtitle-delay -250").count(),
        1,
        "{calls:?}"
    );
    assert_eq!(vm.tracks().subtitle_delay_ms, -250);
}

/// F4 for the two commands that answer: while the host blocks inside `select_audio`, the readers
/// (what the main thread polls) must still be answered.
#[test]
fn a_blocked_select_audio_does_not_block_the_readers() {
    let host = Arc::new(Host::default());
    let vm = player(&host);
    vm.engine_event(EngineEvent::LoadFinished { attempt: 1 }, 101.0);
    // The engine lists both audio tracks and plays the one that went in with the load (2).
    vm.engine_event(tracks_event(), 101.5);
    host.block.store(true, Ordering::SeqCst);
    // The user picks the other one: the engine is asked, and the host blocks in the answer.
    let driver = vm.clone();
    let events = std::thread::spawn(move || driver.send(PlayerIntent::SelectAudio(1), 102.0));
    let start = Instant::now();
    while !host.entered.load(Ordering::SeqCst) {
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "select_audio was never asked"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    // The host sits inside the callback now: the readers answer from another thread.
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = vm.clone();
    std::thread::spawn(move || {
        let _ = reader.transport();
        let _ = reader.controls();
        let _ = reader.tracks();
        let _ = reader.version();
        tx.send(()).unwrap();
    });
    let answered = rx.recv_timeout(Duration::from_secs(2)).is_ok();
    host.release.store(true, Ordering::SeqCst);
    events.join().unwrap();
    assert!(
        answered,
        "the readers were blocked while the host answered select_audio"
    );
    assert!(
        host.calls().iter().any(|c| c == "audio 1"),
        "{:?}",
        host.calls()
    );
}
