//! The skip button's countdown fill of a REAL title (the live player screen: the engine behind the view model is not the
//! made-up one) follows what the core counts: it stands while the film is paused and asks for no frames then.
//! The unit tests of `skip_fill` cover the maths; this one covers where `running` comes from.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::arc_with_non_send_sync
)]

use std::sync::{Arc, Mutex};
use swiftly_desktop::player_screen::{LiveEngine, PlayerScreen, SKIP_X_PAD};
use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_layout::Size;
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, PipCmd, PlaybackEngine, SubtitleRoute,
};
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::sections::{Art, Segment};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{OfferView, PlayerIntent, PlayerSpec, Reporter};

const STEP: f64 = 1000.0 / 60.0;

/// An engine that does nothing; it only remembers whether it was told to pause.
#[derive(Default)]
struct Still {
    pauses: Mutex<u32>,
}

impl PlaybackEngine for Still {
    fn load(&self, _request: EngineLoad) {}
    fn play(&self) {}
    fn pause(&self) {
        *self.pauses.lock().unwrap() += 1;
    }
    fn seek(&self, _seconds: f64) {}
    fn set_rate(&self, _tempo: f32) {}
    fn set_volume(&self, _percent: u8) {}
    fn set_audio_delay(&self, _milliseconds: i32) {}
    fn select_audio(&self, _server_index: i32) -> bool {
        true
    }
    fn select_subtitle(&self, _server_index: i32) -> SubtitleRoute {
        SubtitleRoute::Cues
    }
    fn set_fill(&self, _on: bool) {}
    fn place(&self, _rect: swiftly_playback::engine::Rect) {}
    fn stop(&self, _reset_display: bool) {}
    fn pip(&self, _command: PipCmd) {}
}

/// The host side of the engine: no events of its own, and it wakes the host (so playing alone asks for no frames).
struct Feed;
impl LiveEngine for Feed {
    fn events(&self) -> Vec<EngineEvent> {
        Vec::new()
    }
    fn frame(&self, _w: u32, _h: u32, _sink: &mut dyn FnMut(u32, u32, &[u8])) {}
    fn wake_driven(&self) -> bool {
        true
    }
}

struct Quiet;
impl Reporter for Quiet {
    fn report(&self, _message: swiftly_vm::ReportMessage) {}
}

fn spec() -> PlayerSpec {
    PlayerSpec {
        item_id: "ep".into(),
        title: "Folge".into(),
        plan: ReportPlan {
            play_session_id: None,
            media_source_id: None,
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: "ep".into(),
            streams: Vec::new(),
            runtime: 2700.0,
            subtitle_files: Vec::new(),
            url: "demo://ep".into(),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: 0.0,
        audio_index: None,
        subtitle_index: -1,
        next: None,
        series_id: Some("serie".into()),
        track_title: None,
        downloaded: false,
    }
}

struct Rig {
    screen: PlayerScreen,
    engine: Arc<Still>,
    now: f64,
    position: f64,
    paused: bool,
}

impl Rig {
    /// A live screen with "skip automatically" on and an intro from 20 s to 80 s, playing at 25 s.
    fn new() -> Rig {
        static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "skip-fill-wiring-{}-{}",
            std::process::id(),
            N.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(JsonFileStore::open(dir.join("settings.json")).unwrap());
        store.set("introAbspannAuto", Value::Bool(true)).unwrap();
        let engine = Arc::new(Still::default());
        let mut screen = PlayerScreen::live(
            Env::new(Size::new(1280.0, 720.0), 1.0, Idiom::Desktop),
            Cx::deterministic(),
            0.0,
            spec(),
            ("Serie".into(), "S1 · F1".into()),
            Arc::clone(&engine) as Arc<dyn PlaybackEngine>,
            Arc::new(Feed),
            Arc::new(Quiet),
            |vm| vm.set_sections(vec![Segment::new(Art::IntroSegment, 20.0, 80.0)]),
        );
        screen.set_store(store, 0.0);
        for e in [
            EngineEvent::LoadFinished { attempt: 1 },
            EngineEvent::Duration(2700.0),
            EngineEvent::State(EngineState::Playing),
            EngineEvent::FirstFrame,
        ] {
            screen.engine_event(e, 0.0);
        }
        let mut rig = Rig {
            screen,
            engine,
            now: 0.0,
            position: 25.0,
            paused: false,
        };
        rig.run(1000.0);
        rig
    }

    /// Frames for `ms`; a playing engine reports its clock every frame, a paused one reports nothing.
    fn run(&mut self, ms: f64) {
        let end = self.now + ms;
        while self.now < end {
            self.now += STEP;
            if !self.paused {
                self.position += STEP / 1000.0;
                self.screen.engine_event(
                    EngineEvent::Clock {
                        position: self.position,
                        source_time: self.position,
                    },
                    self.now,
                );
            }
            let _ = self.screen.frame(self.now);
        }
    }

    fn fill(&self) -> Option<f64> {
        self.screen.skip_fill_share()
    }
}

#[test]
fn the_fill_runs_while_the_film_plays_and_stands_while_it_is_paused() {
    let mut r = Rig::new();
    r.run(1500.0);
    assert!(
        matches!(r.screen.vm().offer().view, OfferView::Button { .. }),
        "the skip button shows: {:?}",
        r.screen.vm().offer()
    );
    let before = r.fill().expect("a countdown shows");
    assert!(before > 0.05, "the fill has started: {before}");
    r.run(1000.0);
    let running = r.fill().expect("still counting down");
    assert!(
        running > before + 0.1,
        "it runs while playing: {before} -> {running}"
    );
    // Space: the core pauses the engine, the engine reports Paused.
    r.screen.send_intent(PlayerIntent::TogglePlay, r.now);
    r.screen
        .engine_event(EngineEvent::State(EngineState::Paused), r.now);
    r.paused = true;
    assert_eq!(*r.engine.pauses.lock().unwrap(), 1, "the engine was paused");
    // A moment for the controls to settle, then the fill must stand and no frame may be wanted for it.
    r.run(1200.0);
    let held = r.fill().expect("the countdown is still on screen");
    r.run(3000.0);
    let later = r.fill().expect("the countdown is still on screen");
    assert!(
        (later - held).abs() < 1e-9,
        "the fill ran on while paused: {held} -> {later} (running share {running})"
    );
    assert!(
        later < 0.9,
        "the fill stands near where the core holds it, not full: {later}"
    );
    assert!(
        !r.screen.wants_frame(),
        "a paused countdown asks for no frames"
    );
    // Resume: it runs on from where it stood, without a jump.
    r.screen.send_intent(PlayerIntent::TogglePlay, r.now);
    r.screen
        .engine_event(EngineEvent::State(EngineState::Playing), r.now);
    r.paused = false;
    r.run(500.0);
    let resumed = r.fill().expect("counting down again");
    assert!(
        resumed >= later - 1e-9 && resumed < later + 0.25,
        "resumed without a jump: {later} -> {resumed}"
    );
}

#[test]
fn the_x_of_the_auto_skip_button_has_a_target_of_at_least_32_pt() {
    let mut r = Rig::new();
    r.run(1500.0);
    let f = r
        .screen
        .frame_of("offer-x")
        .expect("the X shows on the auto-skip button");
    assert!(
        f[2] >= 32.0 && f[3] >= 32.0,
        "the X target is {} x {} pt",
        f[2],
        f[3]
    );
}

/// At a full countdown the fill must cover the pill to its right edge, X column included: the fill's width over its share
/// is the width the pill is laid out with (a 2 pt strip stayed uncovered when the fill counted the X column too short).
#[test]
fn the_fill_of_a_full_countdown_reaches_the_pills_right_edge() {
    let mut r = Rig::new();
    r.run(1500.0);
    let share = r.fill().expect("a countdown shows") as f32;
    assert!(share > 0.05, "the fill has started: {share}");
    let label_side = r.screen.frame_of("offer").expect("the pill's label side");
    let x = r.screen.frame_of("offer-x").expect("the X target");
    let fill = r.screen.frame_of("offer-fill").expect("the fill");
    let pill_w = x[0] + x[2] + SKIP_X_PAD - label_side[0];
    let full_fill = fill[2] / share;
    assert!(
        (full_fill - pill_w).abs() < 0.5,
        "a full fill is {full_fill} pt wide, the pill {pill_w} pt"
    );
}
