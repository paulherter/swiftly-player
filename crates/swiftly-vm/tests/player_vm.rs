//! The player view model against a fake engine and a recording reporter: start/progress/stop
//! cadence, pause/resume and seek reports, controls, skip prompts, the next-episode card, the
//! group hook, the start watchdog, and the client reporter over a mock transport.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

use std::sync::{Arc, Mutex};

use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_model::MediaStream;
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
};
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::sections::{Art, Segment};
use swiftly_playback::track_label::LabelText;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::delay::Delay;
use swiftly_vm::{
    AfterPlay, CloseStep, Failure, GroupHook, MemoryTrackStore, NextEpisode, Nudge,
    ORIGINAL_QUALITY_HINT, OfferView, Phase, PlayerEffect, PlayerIntent, PlayerLayer, PlayerPrefs,
    PlayerSpec, PlayerVm, Quality, RemoteOrders, ReplaceRunning, ReportKind, ReportMessage,
    Reporter, SMALL_WINDOW_TEXT, SWITCH_FAILED_HINT, StreamReading, TrackMemoryStore,
};

#[derive(Default)]
struct Fake {
    calls: Mutex<Vec<String>>,
}

impl Fake {
    fn log(&self, s: String) {
        self.calls.lock().unwrap().push(s);
    }
    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
    fn has(&self, s: &str) -> bool {
        self.calls().iter().any(|c| c == s)
    }
}

impl PlaybackEngine for Fake {
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
        self.log(format!("audio {server_index}"));
        true
    }
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute {
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
    fn set_audio_output(&self, mode: &swiftly_playback::decoder_choice::AudioOutputMode) {
        self.log(format!(
            "audio-output {:?} {}",
            mode.spdif_codecs, mode.exclusive
        ));
    }
}

#[derive(Default)]
struct Reports(Mutex<Vec<ReportMessage>>);

impl Reporter for Reports {
    fn report(&self, message: ReportMessage) {
        self.0.lock().unwrap().push(message);
    }
}

impl Reports {
    fn kinds(&self) -> Vec<ReportKind> {
        self.0.lock().unwrap().iter().map(|m| m.kind).collect()
    }
    fn last(&self) -> ReportMessage {
        self.0.lock().unwrap().last().unwrap().clone()
    }
}

struct Words;
impl LabelText for Words {
    fn language_name(&self, code: &str) -> Option<String> {
        match code {
            "eng" => Some("English".into()),
            "deu" => Some("German".into()),
            _ => None,
        }
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

fn spec(start_at: f64, next: bool) -> PlayerSpec {
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
        start_at,
        audio_index: Some(1),
        subtitle_index: -1,
        next: next.then(|| NextEpisode {
            id: "ep2".into(),
            title: "Second".into(),
        }),
        series_id: Some("show".into()),
        track_title: Some("acct|show".into()),
        downloaded: false,
    }
}

struct Rig {
    vm: PlayerVm<Fake, Reports>,
    engine: Arc<Fake>,
    reports: Arc<Reports>,
}

/// A started player at `t = 100` whose first picture is up and whose clock sits at `position`.
fn rig_with(start_at: f64, next: bool, prefs: PlayerPrefs) -> Rig {
    let engine = Arc::new(Fake::default());
    let reports = Arc::new(Reports::default());
    let vm = PlayerVm::new(
        engine.clone(),
        reports.clone(),
        Arc::new(Words),
        prefs,
        spec(start_at, next),
        100.0,
    );
    vm.start(100.0);
    Rig {
        vm,
        engine,
        reports,
    }
}

fn rig() -> Rig {
    rig_with(0.0, false, PlayerPrefs::default())
}

impl Rig {
    fn picture(&self, now: f64, position: f64, duration: f64) {
        let e = |ev| self.vm.engine_event(ev, now);
        e(EngineEvent::LoadFinished { attempt: 1 });
        e(EngineEvent::Duration(duration));
        e(EngineEvent::State(EngineState::Playing));
        e(EngineEvent::FirstFrame);
        e(EngineEvent::Clock {
            position,
            source_time: position,
        });
    }
    /// Runs 500 ms ticks from `from` to `to` with the clock following in real time.
    fn run(&self, from: f64, to: f64, position_at_from: f64) -> f64 {
        let mut t = from;
        while t < to - 1e-9 {
            t += 0.5;
            let p = position_at_from + (t - from);
            self.vm.engine_event(
                EngineEvent::Clock {
                    position: p,
                    source_time: p,
                },
                t,
            );
            self.vm.display_tick(t - 0.25);
            self.vm.tick(t);
        }
        t
    }
}

#[test]
fn start_loads_and_reports_once_the_picture_is_up() {
    let r = rig();
    assert!(r.engine.calls()[0].starts_with("load"));
    assert_eq!(r.vm.transport().phase, Phase::Loading);
    assert!(r.vm.transport().buffering);
    r.vm.tick(100.5);
    assert!(
        r.reports.kinds().is_empty(),
        "no report before a picture: {:?}",
        r.reports.0.lock().unwrap()
    );

    r.picture(101.0, 0.0, 3600.0);
    r.vm.tick(101.5);
    assert_eq!(r.reports.kinds(), vec![ReportKind::Start]);
    assert_eq!(r.vm.transport().phase, Phase::Playing);
    assert!(!r.vm.transport().buffering);
    assert_eq!(r.vm.transport().duration, 3600.0);
    assert!(r.engine.has("play"));
    // 10 s spacing of progress: nothing in between, one at the end.
    r.run(101.5, 109.5, 0.0);
    assert_eq!(r.reports.kinds(), vec![ReportKind::Start]);
    r.run(109.5, 112.0, 8.0);
    assert_eq!(
        r.reports.kinds(),
        vec![ReportKind::Start, ReportKind::Progress { paused: false }]
    );
}

#[test]
fn pause_and_resume_report_at_once_and_a_long_pause_jumps_back() {
    let r = rig();
    r.picture(101.0, 1000.0, 3600.0);
    r.vm.tick(101.5);
    r.vm.send(PlayerIntent::TogglePlay, 102.0);
    assert!(r.engine.has("pause"));
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 102.0);
    assert_eq!(r.reports.last().kind, ReportKind::Progress { paused: true });
    assert!(r.vm.controls().visible);

    // Resume after 11 minutes: a few seconds back (pause_jump_back).
    r.vm.send(PlayerIntent::TogglePlay, 102.0 + 700.0);
    assert!(r.engine.has("play"));
    let seek = r
        .engine
        .calls()
        .into_iter()
        .find(|c| c.starts_with("seek"))
        .expect("jumped back");
    let to: f64 = seek["seek ".len()..].parse().unwrap();
    assert!((990.0..1000.0).contains(&to), "{to}");
    r.vm.engine_event(EngineEvent::State(EngineState::Playing), 802.0);
    assert_eq!(
        r.reports.last().kind,
        ReportKind::Progress { paused: false }
    );
}

/// The Mac's button follows the engine's own report (`runsDisplay`), not the next 500 ms tick: the click reaches the
/// engine at once, and the report flips the shown state in the same call, so the glyph changes in the next frame.
#[test]
fn the_shown_state_flips_on_the_engines_report_without_waiting_for_a_tick() {
    let r = rig();
    r.picture(101.0, 1000.0, 3600.0);
    r.vm.tick(101.5);
    assert_eq!(r.vm.transport().phase, Phase::Playing);
    r.vm.send(PlayerIntent::TogglePlay, 101.6);
    assert!(r.engine.has("pause"), "the engine is told within the click");
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 101.61);
    assert_eq!(r.vm.transport().phase, Phase::Paused);
    assert!(!r.vm.transport().running);
    r.vm.send(PlayerIntent::TogglePlay, 102.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Playing), 102.01);
    assert_eq!(r.vm.transport().phase, Phase::Playing);
    assert!(r.vm.transport().running);
}

#[test]
fn seek_stands_on_the_target_and_reports_it() {
    let r = rig();
    r.picture(101.0, 5.0, 3600.0);
    r.vm.tick(101.5);
    r.vm.send(PlayerIntent::SeekTo(1200.0), 102.0);
    assert!(r.engine.has("seek 1200"));
    assert_eq!(r.vm.transport().position, 1200.0);
    assert_eq!(r.reports.last().seconds, 1200.0);
    // The engine still reports the old clock for a moment: the display keeps the target.
    r.vm.engine_event(
        EngineEvent::Clock {
            position: 6.0,
            source_time: 6.0,
        },
        102.2,
    );
    r.vm.display_tick(102.25);
    assert_eq!(r.vm.transport().position, 1200.0);
}

#[test]
fn repeated_skips_add_up_in_the_indicator_and_it_goes_after_700_ms() {
    let r = rig();
    r.picture(101.0, 100.0, 3600.0);
    r.vm.tick(101.5);
    r.vm.send(PlayerIntent::Forward, 102.0);
    r.vm.send(PlayerIntent::Forward, 102.2);
    assert_eq!(r.vm.controls().jump_display, Some((1, 20)));
    assert_eq!(r.vm.transport().position, 120.0);
    r.vm.send(PlayerIntent::Back, 102.3);
    assert_eq!(r.vm.controls().jump_display, Some((-1, 10)));
    assert_eq!(r.vm.transport().position, 110.0);
    r.vm.display_tick(103.1);
    assert_eq!(r.vm.controls().jump_display, None);
}

#[test]
fn controls_hide_after_four_seconds_only_while_playing() {
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    r.vm.send(PlayerIntent::WakeControls, 102.0);
    r.run(102.0, 105.5, 0.0);
    assert!(r.vm.controls().visible);
    r.run(105.5, 106.5, 3.5);
    assert!(!r.vm.controls().visible);
    // A tap shows them; paused they stay.
    r.vm.send(PlayerIntent::ToggleControls, 107.0);
    assert!(r.vm.controls().visible);
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 107.0);
    r.run(107.0, 120.0, 4.0);
    assert!(r.vm.controls().visible);
    // A panel keeps them too.
    r.vm.engine_event(EngineEvent::State(EngineState::Playing), 120.0);
    r.vm.send(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), 120.0);
    r.run(120.0, 130.0, 4.0);
    assert!(r.vm.controls().visible);
}

#[test]
fn track_panel_lists_labels_and_forwards_the_choice() {
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    let t = r.vm.tracks();
    assert_eq!(t.audio.len(), 2);
    assert!(t.audio[0].selected && !t.audio[1].selected);
    assert!(t.audio[1].label.starts_with("German"));
    assert!(t.subtitles_off);
    r.vm.send(PlayerIntent::SelectAudio(2), 102.0);
    assert!(r.vm.tracks().audio[1].selected);
    // The engine has no list yet: nothing is asked of it; the choice is kept for the lists.
    r.vm.send(PlayerIntent::SelectSubtitle(3), 102.0);
    assert!(!r.vm.tracks().subtitles_off);
}

#[test]
fn the_original_language_audio_track_carries_the_original_tag() {
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    assert!(
        r.vm.tracks()
            .audio
            .iter()
            .all(|t| !t.label.contains("(Original)"))
    );
    r.vm.set_original_language(Some("de".into()));
    let t = r.vm.tracks();
    assert!(
        t.audio[1].label.ends_with("(Original)"),
        "{}",
        t.audio[1].label
    );
    assert!(!t.audio[0].label.contains("Original"));
}

#[test]
fn intro_prompt_skips_to_the_end_of_the_segment_and_auto_skip_does_it_once() {
    let r = rig();
    r.vm.set_sections(vec![Segment::new(Art::IntroSegment, 5.0, 95.0)]);
    r.picture(101.0, 10.0, 3600.0);
    r.vm.tick(101.5);
    assert!(matches!(
        r.vm.offer().view,
        OfferView::Button {
            next_episode: false,
            ..
        }
    ));
    r.vm.send(PlayerIntent::PressOffering, 102.0);
    assert!(r.engine.has("seek 95"));
    assert_eq!(r.vm.transport().position, 95.0);
    assert_eq!(r.vm.offer().view, OfferView::Hidden);

    let auto = rig_with(
        0.0,
        false,
        PlayerPrefs {
            auto_skip: true,
            ..PlayerPrefs::default()
        },
    );
    auto.vm
        .set_sections(vec![Segment::new(Art::IntroSegment, 5.0, 95.0)]);
    auto.picture(101.0, 10.0, 3600.0);
    auto.vm.tick(101.5);
    auto.vm.tick(102.0);
    // The offer shows first with its countdown running; nothing is skipped yet.
    assert!(matches!(auto.vm.offer().view, OfferView::Button { .. }));
    assert_eq!(seek_count(&auto), 0);
    auto.run(102.0, 105.0, 12.0);
    assert_eq!(seek_count(&auto), 0);
    auto.run(105.0, 120.0, 15.0);
    assert_eq!(seek_count(&auto), 1);
    assert_eq!(auto.vm.offer().view, OfferView::Hidden);
}

fn seek_count(r: &Rig) -> usize {
    r.engine
        .calls()
        .iter()
        .filter(|c| c.starts_with("seek"))
        .count()
}

fn auto_prefs(auto_skip: bool) -> PlayerPrefs {
    PlayerPrefs {
        auto_skip,
        next_automatic: false,
        ..PlayerPrefs::default()
    }
}

#[test]
fn auto_skip_dismiss_cancels_the_intro_skip() {
    let r = rig_with(0.0, false, auto_prefs(true));
    r.vm.set_sections(vec![Segment::new(Art::IntroSegment, 5.0, 95.0)]);
    r.picture(101.0, 10.0, 3600.0);
    r.run(101.0, 103.0, 10.0);
    r.vm.send(PlayerIntent::Back2, 103.0);
    assert_eq!(r.vm.offer().view, OfferView::Hidden);
    r.run(103.0, 130.0, 12.0);
    assert_eq!(seek_count(&r), 0);
}

#[test]
fn auto_skip_off_waits_for_the_user_on_intro_and_outro() {
    let r = rig_with(0.0, true, auto_prefs(false));
    r.vm.set_sections(vec![
        Segment::new(Art::IntroSegment, 5.0, 95.0),
        Segment::new(Art::Credits, 3000.0, 3400.0),
    ]);
    r.picture(101.0, 10.0, 3600.0);
    r.run(101.0, 160.0, 10.0);
    assert_eq!(seek_count(&r), 0);
    // The outro does not reach the end: the offer is a skip button, which also just waits.
    r.run(160.0, 163.0, 3001.0);
    r.run(163.0, 200.0, 3004.0);
    assert_eq!(seek_count(&r), 0);
    assert!(
        !r.vm
            .take_effects()
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. }))
    );
}

/// The end of the file with a next episode: a short episode and an outro that stops well before the end get no
/// card (the scene after the credits stays untouched), and the file used to end with nothing started.
#[test]
fn the_end_of_the_file_starts_the_next_episode_without_a_card_while_automatic_is_on() {
    let started = |r: &Rig| {
        r.vm.take_effects()
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. }))
    };
    for sections in [vec![], vec![Segment::new(Art::Credits, 6.0, 10.0)]] {
        let r = rig_with(0.0, true, PlayerPrefs::default());
        r.vm.set_sections(sections.clone());
        r.picture(101.0, 100.0, 130.0);
        r.run(101.0, 120.0, 100.0);
        assert_eq!(r.vm.offer().view, OfferView::Hidden, "{sections:?}");
        assert!(!started(&r), "{sections:?}: not before the end");
        r.run(120.0, 135.0, 119.0);
        assert!(started(&r), "{sections:?}: the end of the file advances");
    }
    // "Next episode automatically" off: nothing advances by itself.
    let off = PlayerPrefs {
        next_automatic: false,
        ..PlayerPrefs::default()
    };
    let r = rig_with(0.0, true, off);
    r.vm.set_sections(vec![Segment::new(Art::Credits, 6.0, 10.0)]);
    r.picture(101.0, 100.0, 130.0);
    r.run(101.0, 140.0, 100.0);
    assert!(!started(&r));
    // No next episode: nothing to start.
    let r = rig_with(0.0, false, PlayerPrefs::default());
    r.picture(101.0, 100.0, 130.0);
    r.run(101.0, 140.0, 100.0);
    assert!(!started(&r));
}

#[test]
fn auto_skip_outro_card_counts_down_first_then_advances_and_dismiss_cancels() {
    // Wanted: the card with its countdown first; the episode only changes after it.
    let r = rig_with(0.0, true, auto_prefs(true));
    // The "Next episode automatically" setting is off: the outro still counts down.
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3499.0, 3600.0);
    r.run(101.0, 103.0, 3499.0);
    r.run(103.0, 105.0, 3501.0);
    assert!(matches!(r.vm.offer().view, OfferView::Card { .. }));
    let started = |r: &Rig| {
        r.vm.take_effects()
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. }))
    };
    assert!(!started(&r));
    r.run(105.0, 120.0, 3503.0);
    assert!(started(&r));

    // Dismissed: stays on this episode.
    let r = rig_with(0.0, true, auto_prefs(true));
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3499.0, 3600.0);
    r.run(101.0, 105.0, 3499.0);
    r.run(105.0, 106.0, 3503.0);
    r.vm.send(PlayerIntent::Back2, 106.0);
    assert_eq!(r.vm.offer().view, OfferView::Hidden);
    r.run(106.0, 140.0, 3504.0);
    assert!(!started(&r));
}

#[test]
fn a_pointer_wake_leaves_the_next_episode_card_up_and_a_deliberate_one_cancels_it() {
    // The Mac: movement shows the controls (`controlsShow(through: .beside)`) and the card keeps running; a click or key
    // (`.deliberate`) takes it away.
    let card_up = || {
        let r = rig_with(0.0, true, PlayerPrefs::default());
        r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
        r.picture(101.0, 3499.0, 3600.0);
        r.run(101.0, 103.0, 3499.0);
        r.run(103.0, 104.0, 3501.0);
        assert!(matches!(r.vm.offer().view, OfferView::Card { .. }));
        r
    };
    let r = card_up();
    r.vm.send(PlayerIntent::WakeControlsBeside, 104.2);
    assert!(r.vm.controls().visible);
    assert!(
        matches!(r.vm.offer().view, OfferView::Card { .. }),
        "a pointer wake dismissed the card"
    );
    // After a pointer wake the countdown still runs out and starts the next episode.
    let r = card_up();
    r.vm.send(PlayerIntent::WakeControlsBeside, 104.2);
    r.run(104.2, 125.0, 3502.0);
    assert!(
        r.vm.take_effects()
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. })),
        "the card did not advance after a pointer wake"
    );
    let r = card_up();
    r.vm.send(PlayerIntent::WakeControls, 104.2);
    assert!(r.vm.controls().visible);
    assert_eq!(
        r.vm.offer().view,
        OfferView::Hidden,
        "a deliberate wake left the card"
    );
}

#[test]
fn next_episode_is_prepared_even_without_next_automatic_but_only_on_a_good_network() {
    // The old screen prepared always (when the network is favourable); "next automatic" only gates the advance.
    let prepared = |prefs: PlayerPrefs| {
        let r = rig_with(0.0, true, prefs);
        r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
        r.picture(101.0, 3499.0, 3600.0);
        r.run(101.0, 103.0, 3499.0);
        r.run(103.0, 104.0, 3501.0);
        r.vm.take_effects()
            .contains(&PlayerEffect::PrepareNext("ep2".into()))
    };
    let off = |network_favorable| PlayerPrefs {
        next_automatic: false,
        network_favorable,
        ..PlayerPrefs::default()
    };
    assert!(prepared(off(true)));
    assert!(!prepared(off(false)));
}

#[test]
fn outro_card_counts_down_and_starts_the_next_episode() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3499.0, 3600.0);
    r.run(101.0, 103.0, 3499.0);
    // The credits start at 3500: the card shows, the countdown runs.
    r.run(103.0, 104.0, 3501.0);
    match r.vm.offer().view {
        OfferView::Card {
            title,
            seconds_left,
            ..
        } => {
            assert_eq!(title, "Second");
            assert!((1..=7).contains(&seconds_left));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        r.vm.take_effects(),
        vec![PlayerEffect::PrepareNext("ep2".into())]
    );
    r.run(104.0, 113.0, 3502.0);
    let effects = r.vm.take_effects();
    assert!(
        effects.contains(&PlayerEffect::StartEpisode {
            id: "ep2".into(),
            from_card: true,
            since: 0.0,
            paused: false
        }),
        "{effects:?}"
    );
    assert!(r.reports.kinds().contains(&ReportKind::Stop));
    assert!(r.engine.has("stop false"));
    // Loading the next title starts over and reports its own start.
    let mut next = spec(0.0, false);
    next.item_id = "ep2".into();
    r.vm.load_title(next, 114.0);
    assert_eq!(r.vm.transport().phase, Phase::Loading);
    r.vm.engine_event(EngineEvent::LoadFinished { attempt: 1 }, 114.1);
    r.vm.engine_event(EngineEvent::Duration(1800.0), 114.1);
    r.vm.engine_event(EngineEvent::FirstFrame, 114.2);
    r.vm.tick(114.5);
    assert_eq!(r.reports.last().kind, ReportKind::Start);
    assert_eq!(r.reports.last().item_id, "ep2");
}

#[test]
fn close_reports_the_stop_once_and_asks_the_host_to_leave() {
    let r = rig();
    r.picture(101.0, 321.0, 3600.0);
    r.vm.tick(101.5);
    r.vm.send(PlayerIntent::Close, 102.0);
    r.vm.send(PlayerIntent::Close, 102.1);
    let stops = r
        .reports
        .kinds()
        .into_iter()
        .filter(|k| *k == ReportKind::Stop)
        .count();
    assert_eq!(stops, 1);
    assert_eq!(r.reports.last().seconds, 321.0);
    assert_eq!(r.vm.take_effects(), vec![PlayerEffect::Close]);
    assert!(r.engine.has("stop true"));
}

#[test]
fn back_closes_card_then_panel_then_controls_then_player() {
    let r = rig();
    r.picture(101.0, 10.0, 3600.0);
    r.vm.send(PlayerIntent::WakeControls, 102.0);
    r.vm.send(PlayerIntent::Layer(Some(PlayerLayer::Settings)), 102.0);
    r.vm.send(PlayerIntent::Back2, 103.0);
    assert_eq!(r.vm.controls().layer, None);
    r.vm.send(PlayerIntent::Back2, 103.1);
    assert!(!r.vm.controls().visible);
    r.vm.send(PlayerIntent::Back2, 103.2);
    assert_eq!(r.vm.take_effects(), vec![PlayerEffect::Close]);
}

struct Group(Mutex<Vec<String>>);
impl GroupHook for Group {
    fn toggle(&self, running: bool) {
        self.0.lock().unwrap().push(format!("toggle {running}"));
    }
    fn jump(&self, to: f64) {
        self.0.lock().unwrap().push(format!("jump {to}"));
    }
}

#[test]
fn in_a_group_the_user_asks_the_group_and_the_group_drives_the_engine() {
    let r = rig();
    r.picture(101.0, 50.0, 3600.0);
    let g = Arc::new(Group(Mutex::new(Vec::new())));
    r.vm.set_group(Some(g.clone()));
    r.vm.send(PlayerIntent::TogglePlay, 102.0);
    r.vm.send(PlayerIntent::SeekTo(900.0), 102.0);
    assert_eq!(*g.0.lock().unwrap(), vec!["toggle true", "jump 900"]);
    assert!(!r.engine.has("pause") && !r.engine.has("seek 900"));
    // Next episode is not offered by hand in a group.
    r.vm.send(PlayerIntent::EnginePause, 103.0);
    r.vm.send(PlayerIntent::EngineSeek(900.0), 103.0);
    assert!(r.engine.has("pause") && r.engine.has("seek 900"));
}

#[test]
fn no_picture_in_thirty_seconds_is_a_failure_with_text() {
    let r = rig();
    r.vm.engine_event(EngineEvent::LoadFinished { attempt: 1 }, 100.5);
    r.vm.tick(105.0);
    assert_eq!(r.vm.transport().phase, Phase::Loading);
    r.vm.tick(131.0);
    let t = r.vm.transport();
    assert_eq!(t.phase, Phase::Failed);
    assert_eq!(t.error.as_deref(), Some("kein Bild nach 30 s"));
}

#[test]
fn sleep_timer_pauses_and_says_so() {
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    r.vm.send(PlayerIntent::Sleep(Some(1)), 101.0);
    assert_eq!(r.vm.controls().sleep_minutes, Some(1));
    r.vm.tick(150.0);
    assert!(!r.engine.has("pause"));
    r.vm.tick(162.0);
    assert!(r.engine.has("pause"));
    assert_eq!(
        r.vm.transport().hint.as_deref(),
        Some("Schlafzeit abgelaufen.")
    );
    assert_eq!(r.vm.controls().sleep_minutes, None);
}

#[test]
fn parts_change_separately() {
    let r = rig();
    let v = r.vm.version();
    r.picture(101.0, 0.0, 3600.0);
    r.vm.tick(101.5);
    let change = futures_executor::block_on(r.vm.changed(v));
    assert!(change.parts & swiftly_vm::part::PLAYER_TRANSPORT != 0);
    let v = change.version;
    r.vm.send(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), 102.0);
    let change = futures_executor::block_on(r.vm.changed(v));
    assert_eq!(change.parts, swiftly_vm::part::PLAYER_CONTROLS);
}

#[derive(Default)]
struct Kept(Mutex<Vec<swiftly_vm::PendingReport>>);
impl swiftly_vm::PendingSink for Kept {
    fn record(&self, report: swiftly_vm::PendingReport) {
        self.0.lock().unwrap().push(report);
    }
}

struct Inline;
impl swiftly_vm::Spawner for Inline {
    fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
        futures_executor::block_on(task);
    }
}

struct Zero;
impl swiftly_vm::Clock for Zero {
    fn now(&self) -> f64 {
        42.0
    }
}

fn client(
    mock: &Arc<swiftly_net::MockTransport>,
) -> Arc<swiftly_jellyfin::JellyfinClient<swiftly_vm::Shared<swiftly_net::MockTransport>>> {
    let config = swiftly_jellyfin::ClientConfig::new("dev", "Test", "1.0");
    let c = swiftly_jellyfin::JellyfinClient::new(
        swiftly_vm::Shared(mock.clone()),
        "https://tv.example.test",
        config,
    )
    .unwrap();
    c.set_session(Some(swiftly_jellyfin::Session {
        access_token: "T".into(),
        user_id: "u".into(),
        user_name: String::new(),
        server_url: "https://tv.example.test".into(),
        kind: swiftly_jellyfin::ServerKind::Jellyfin,
    }));
    Arc::new(c)
}

fn message(kind: ReportKind, seconds: f64) -> ReportMessage {
    ReportMessage {
        kind,
        item_id: "ep1".into(),
        plan: ReportPlan {
            play_session_id: Some("s1".into()),
            media_source_id: Some("m1".into()),
            method: PlayMethod::DirectPlay,
        },
        seconds,
        tracks: swiftly_jellyfin::TrackIndices::default(),
        runtime_ms: None,
    }
}

#[test]
fn client_reporter_sends_in_order_drops_late_progress_and_keeps_a_failed_stop() {
    let mock = Arc::new(swiftly_net::MockTransport::new());
    let kept = Arc::new(Kept::default());
    let r = swiftly_vm::ClientReporter::new(
        client(&mock),
        "acc",
        Arc::new(Inline),
        Arc::new(Zero),
        kept.clone(),
    );
    r.report(message(ReportKind::Start, 0.0));
    r.report(message(ReportKind::Progress { paused: false }, 10.0));
    r.report(message(ReportKind::Stop, 20.0));
    r.report(message(ReportKind::Progress { paused: true }, 21.0));
    r.report(message(ReportKind::Stop, 22.0));
    let paths: Vec<String> = mock
        .requests()
        .iter()
        .map(|q| q.url.path().to_owned())
        .collect();
    assert_eq!(
        paths,
        vec![
            "/Sessions/Capabilities/Full",
            "/Sessions/Playing",
            "/Sessions/Playing/Progress",
            "/Sessions/Playing/Stopped",
        ]
    );
    assert!(kept.0.lock().unwrap().is_empty());

    let down = Arc::new(
        swiftly_net::MockTransport::new()
            .route_error("Stopped", swiftly_net::ErrorKind::InvalidServerUrl),
    );
    let r = swiftly_vm::ClientReporter::new(
        client(&down),
        "acc",
        Arc::new(Inline),
        Arc::new(Zero),
        kept.clone(),
    );
    r.report(message(ReportKind::Stop, 90.0));
    let k = kept.0.lock().unwrap();
    assert_eq!(k.len(), 1);
    assert_eq!(
        (k[0].item_id.as_str(), k[0].account.as_str()),
        ("ep1", "acc")
    );
    assert_eq!(k[0].ticks, 900_000_000);
}

// MARK: Gap closing: failure, end of film, memory, delay, quality, prompts, remote order

#[derive(Default)]
struct Kv(Mutex<std::collections::HashMap<String, String>>);
impl swiftly_library::KeyValue for Kv {
    fn get(&self, key: &str) -> Option<String> {
        self.0.lock().unwrap().get(key).cloned()
    }
    fn set(&self, key: &str, value: &str) {
        self.0.lock().unwrap().insert(key.into(), value.into());
    }
}

#[test]
fn a_failed_start_shows_the_swift_wording_and_retries() {
    let r = rig();
    r.vm.engine_event(EngineEvent::StartWatchdog { attempt: 1 }, 131.0);
    let t = r.vm.transport();
    assert_eq!(t.phase, Phase::Failed);
    let f = t.failure.unwrap();
    assert_eq!(f.header, "Das startet nicht");
    assert_eq!(f, Failure::START);
    let loads = |r: &Rig| {
        r.engine
            .calls()
            .iter()
            .filter(|c| c.starts_with("load"))
            .count()
    };
    assert_eq!(loads(&r), 1);
    r.vm.send(PlayerIntent::Retry, 132.0);
    assert_eq!(loads(&r), 2);
    assert!(r.vm.transport().failure.is_none());
}

#[test]
fn the_end_of_a_film_without_next_episode_stays_open() {
    let r = rig();
    r.picture(101.0, 3590.0, 3600.0);
    r.run(101.0, 105.0, 3590.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), 106.0);
    r.run(106.0, 140.0, 3600.0);
    assert_eq!(r.vm.transport().phase, Phase::Ended);
    assert!(r.vm.controls().visible, "controls stay up at the end");
    let effects = r.vm.take_effects();
    assert!(effects.is_empty(), "{effects:?}");
}

#[test]
fn the_bar_that_faded_during_the_film_comes_back_at_its_end() {
    let r = rig();
    r.picture(101.0, 3590.0, 3600.0);
    r.run(101.0, 109.0, 3590.0);
    assert!(!r.vm.controls().visible, "the bar faded while it played");
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), 110.0);
    r.run(110.0, 140.0, 3600.0);
    assert_eq!(r.vm.transport().phase, Phase::Ended);
    assert!(
        r.vm.controls().visible,
        "the bar is up at the end and stays"
    );
}

/// What the desktop engine sends with keep-open: the clock stops at the last frame, mpv pauses, then Ended arrives
/// (no outro marker at all). The card counts down on its own, the next episode starts, the stop report says "the end".
#[test]
fn ended_from_the_desktop_engine_runs_the_next_episode_card_and_reports_the_end() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 3590.0, 3600.0);
    r.run(101.0, 109.0, 3590.0);
    let end = 109.0;
    r.vm.engine_event(
        EngineEvent::Clock {
            position: 3599.96,
            source_time: 3599.96,
        },
        end,
    );
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), end);
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), end);
    assert_eq!(r.vm.transport().phase, Phase::Ended);
    let mut t = end;
    let mut saw_card = false;
    let mut started = false;
    for _ in 0..40 {
        t += 0.5;
        r.vm.display_tick(t - 0.25);
        r.vm.tick(t);
        saw_card |= matches!(r.vm.offer().view, OfferView::Card { .. });
        started |= r.vm.take_effects().iter().any(
            |e| matches!(e, PlayerEffect::StartEpisode { id, from_card: true, .. } if id == "ep2"),
        );
    }
    assert!(
        saw_card,
        "the next-episode card with its countdown shows after Ended"
    );
    assert!(started, "the next episode starts after the countdown");
    let stop = r
        .reports
        .0
        .lock()
        .unwrap()
        .iter()
        .rev()
        .find(|m| m.kind == ReportKind::Stop)
        .cloned();
    assert_eq!(
        stop.map(|m| m.seconds),
        Some(3600.0),
        "the stop report carries the end"
    );
}

/// A short clip (10 s) with an outro from 0:07: the card counts 3 s, the clip ends on the last frame. The card must
/// still finish its countdown and start the next episode, although the file is too short for the long-file rules.
#[test]
fn a_short_clip_ending_inside_the_outro_card_still_advances() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.vm.set_sections(vec![Segment::new(Art::Credits, 7.0, 10.0)]);
    r.picture(101.0, 6.0, 10.0);
    let mut t = r.run(101.0, 105.0, 6.0);
    assert!(
        matches!(r.vm.offer().view, OfferView::Card { .. }),
        "the card is up in the outro"
    );
    r.vm.engine_event(
        EngineEvent::Clock {
            position: 9.98,
            source_time: 9.98,
        },
        t,
    );
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), t);
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), t);
    let mut started = false;
    for _ in 0..20 {
        t += 0.5;
        r.vm.display_tick(t - 0.25);
        r.vm.tick(t);
        started |= r.vm.take_effects().iter().any(
            |e| matches!(e, PlayerEffect::StartEpisode { id, from_card: true, .. } if id == "ep2"),
        );
    }
    assert!(started, "the next episode starts after the countdown");
}

/// A click on the card starts the next episode, as on the Mac (the card zooms and the switch runs).
#[test]
fn a_click_on_the_card_starts_the_next_episode_from_the_card() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3499.0, 3600.0);
    r.run(101.0, 104.0, 3499.0);
    assert!(matches!(r.vm.offer().view, OfferView::Card { .. }));
    r.vm.take_effects();
    r.vm.send(PlayerIntent::PressCard, 104.2);
    assert!(r.vm.take_effects().iter().any(
        |e| matches!(e, PlayerEffect::StartEpisode { id, from_card: true, .. } if id == "ep2")
    ));
}

#[test]
fn hand_chosen_tracks_are_remembered_for_the_series() {
    let r = rig();
    let store = Arc::new(MemoryTrackStore::default());
    r.vm.set_memory(Some(store.clone()));
    r.vm.send(PlayerIntent::SelectAudio(2), 101.0);
    let audio = store.load("tonJeTitel");
    assert!(
        audio["acct|show"].contains("\"sprache\":\"deu\""),
        "{audio:?}"
    );
    r.vm.send(PlayerIntent::SelectSubtitle(3), 101.0);
    assert!(store.load("utJeTitel")["acct|show"].starts_with('{'));
    r.vm.send(PlayerIntent::SelectSubtitle(-1), 102.0);
    assert_eq!(store.load("utJeTitel")["acct|show"], "");
}

#[test]
fn the_subtitle_delay_survives_an_episode_of_the_same_series_only() {
    let r = rig();
    r.vm.send(
        PlayerIntent::SubtitleDelay(Delay::from_milliseconds(500)),
        101.0,
    );
    let mut next = spec(0.0, false);
    next.item_id = "ep2".into();
    r.vm.load_title(next.clone(), 110.0);
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 500);
    next.item_id = "film".into();
    next.series_id = None;
    r.vm.load_title(next, 120.0);
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 0);
}

#[test]
fn the_menu_speed_row_sends_one_rate_command_and_marks_the_running_speed() {
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    assert!(
        r.vm.menu(",")
            .speeds
            .iter()
            .find(|s| s.value == 1.0)
            .unwrap()
            .selected
    );
    r.vm.send(PlayerIntent::Tempo(1.5), 102.0);
    assert!(r.engine.has("rate 1.5"));
    let menu = r.vm.menu(",");
    assert_eq!(menu.speeds.iter().filter(|s| s.selected).count(), 1);
    assert!(
        menu.speeds
            .iter()
            .find(|s| s.value == 1.5)
            .unwrap()
            .selected
    );
    assert_eq!(r.vm.transport().tempo, 1.5);
}

#[test]
fn the_menu_offset_buttons_step_clamp_and_reset_through_the_engine() {
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    assert_eq!(r.vm.menu(",").offset_text, "0 s");
    assert!(!r.vm.menu(",").can_reset);
    for step in [500, 500, 100] {
        r.vm.send(PlayerIntent::SubtitleOffsetStep(step), 102.0);
    }
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 1100);
    let menu = r.vm.menu(",");
    assert_eq!(menu.offset_text, "+1,1 s");
    assert!(menu.can_reset);
    let calls = r.engine.calls();
    let delays: Vec<&String> = calls
        .iter()
        .filter(|c| c.starts_with("subtitle-delay"))
        .collect();
    assert_eq!(
        delays,
        [
            "subtitle-delay 500",
            "subtitle-delay 1000",
            "subtitle-delay 1100"
        ]
    );
    r.vm.send(PlayerIntent::SubtitleOffsetStep(-500), 103.0);
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 600);
    r.vm.send(PlayerIntent::SubtitleOffsetReset, 104.0);
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 0);
    assert!(r.engine.has("subtitle-delay 0"));
    // Past the limit the offset stops, no command for a press that changes nothing.
    r.vm.send(
        PlayerIntent::SubtitleDelay(Delay::from_milliseconds(10_000)),
        105.0,
    );
    let before = r.engine.calls().len();
    r.vm.send(PlayerIntent::SubtitleOffsetStep(500), 106.0);
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 10_000);
    assert_eq!(r.engine.calls().len(), before);
}

#[test]
fn a_remembered_offset_reaches_the_engine_when_the_memory_comes_before_the_start() {
    let store = Arc::new(MemoryTrackStore::default());
    let mut all = std::collections::HashMap::new();
    all.insert("ep1".to_owned(), "1500".to_owned());
    store.save(swiftly_vm::OFFSET_KEY, &all);
    let engine = Arc::new(Fake::default());
    let vm = PlayerVm::new(
        engine.clone(),
        Arc::new(Reports::default()),
        Arc::new(Words),
        PlayerPrefs::default(),
        spec(0.0, false),
        100.0,
    );
    vm.set_memory(Some(store as Arc<dyn TrackMemoryStore>));
    vm.start(100.0);
    assert_eq!(vm.tracks().subtitle_delay_ms, 1500);
    assert_eq!(vm.menu(",").offset_text, "+1,5 s");
    assert_eq!(
        engine
            .calls()
            .iter()
            .filter(|c| *c == "subtitle-delay 1500")
            .count(),
        1
    );
}

#[test]
fn the_offset_is_remembered_per_title_and_the_speed_is_not() {
    let r = rig();
    let store = Arc::new(MemoryTrackStore::default());
    r.vm.set_memory(Some(store.clone() as Arc<dyn TrackMemoryStore>));
    r.picture(101.0, 0.0, 3600.0);
    r.vm.send(PlayerIntent::SubtitleOffsetStep(500), 102.0);
    r.vm.send(PlayerIntent::SubtitleOffsetStep(500), 102.5);
    r.vm.send(PlayerIntent::Tempo(2.0), 103.0);
    assert_eq!(
        store
            .load(swiftly_vm::OFFSET_KEY)
            .get("ep1")
            .map(String::as_str),
        Some("1000")
    );
    // Another film (no series): the offset does not come along, the speed starts at normal.
    let mut other = spec(0.0, false);
    other.item_id = "film".into();
    other.series_id = None;
    r.vm.load_title(other, 110.0);
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 0);
    assert_eq!(r.vm.transport().tempo, 1.0);
    assert!(r.engine.calls().iter().rev().take(6).any(|c| c == "rate 1"));
    // Back to the first title: its own offset is there again, sent to the engine.
    let mut again = spec(0.0, false);
    again.series_id = None;
    r.vm.load_title(again, 120.0);
    assert_eq!(r.vm.tracks().subtitle_delay_ms, 1000);
    assert!(
        r.engine
            .calls()
            .iter()
            .filter(|c| *c == "subtitle-delay 1000")
            .count()
            >= 2
    );
    assert_eq!(r.vm.menu(",").offset_text, "+1 s");
    // A reset forgets it.
    r.vm.send(PlayerIntent::SubtitleOffsetReset, 121.0);
    assert!(!store.load(swiftly_vm::OFFSET_KEY).contains_key("ep1"));
}

#[test]
fn a_quality_switch_reloads_at_the_position_and_says_when_the_original_plays() {
    let r = rig();
    r.picture(101.0, 600.0, 3600.0);
    r.run(101.0, 103.0, 600.0);
    assert_eq!(
        r.vm.controls().quality,
        Some(Quality {
            direct_play: true,
            limit: 0
        })
    );
    r.vm.send(PlayerIntent::Quality(Some(8)), 103.0);
    let effects = r.vm.take_effects();
    assert!(effects.contains(&PlayerEffect::QualityChosen(Quality {
        direct_play: false,
        limit: 8
    })));
    assert!(effects.contains(&PlayerEffect::ForgetPrepared));
    let since = effects
        .iter()
        .find_map(|e| match e {
            PlayerEffect::StartEpisode { id, since, .. } if id == "ep1" => Some(*since),
            _ => None,
        })
        .expect("reload of the same title");
    assert!(since > 600.0);
    assert!(r.reports.kinds().contains(&ReportKind::Stop));
    // The same choice again does nothing.
    r.vm.send(PlayerIntent::Quality(Some(8)), 104.0);
    assert!(r.vm.take_effects().is_empty());
    // The new plan is still the original: say so.
    r.vm.load_title(spec(since, false), 105.0);
    assert_eq!(
        r.vm.transport().hint.as_deref(),
        Some(ORIGINAL_QUALITY_HINT)
    );
}

#[test]
fn a_model_built_after_a_quality_choice_says_when_the_original_plays() {
    // Table: (limit chosen, switched flag, hint expected).
    for (direct_play, switched, hint) in [
        (false, true, true),
        (false, false, false),
        (true, true, false),
    ] {
        let prefs = PlayerPrefs {
            direct_play,
            bitrate_limit: 8,
            ..PlayerPrefs::default()
        };
        let r = rig_with(0.0, false, prefs);
        if switched {
            r.vm.after_quality_switch();
        }
        assert_eq!(
            r.vm.transport().hint.as_deref() == Some(ORIGINAL_QUALITY_HINT),
            hint,
            "direct_play={direct_play} switched={switched}"
        );
    }
}

#[test]
fn no_quality_choice_for_a_download() {
    let engine = Arc::new(Fake::default());
    let mut sp = spec(0.0, false);
    sp.downloaded = true;
    let vm = PlayerVm::new(
        engine,
        Arc::new(Reports::default()),
        Arc::new(Words),
        PlayerPrefs::default(),
        sp,
        100.0,
    );
    vm.start(100.0);
    assert!(vm.controls().quality.is_none());
    vm.send(PlayerIntent::Quality(Some(4)), 101.0);
    assert!(vm.take_effects().is_empty());
}

#[test]
fn rating_then_discord_prompt_after_finished_titles() {
    let kv = Arc::new(Kv::default());
    let after = AfterPlay::new(kv.clone(), "1.0.3", true);
    assert_eq!(after.done_watch(100.0, 3600.0), None, "not finished");
    assert_eq!(after.done_watch(3500.0, 30.0), None, "a clip is no title");
    assert_eq!(after.done_watch(3500.0, 3600.0), None);
    assert_eq!(after.done_watch(3500.0, 3600.0), None);
    assert_eq!(after.done_watch(3500.0, 3600.0), Some(Nudge::Rating));
    // Asked in this version: the Discord hint comes with the fifth finished title.
    assert_eq!(after.done_watch(3500.0, 3600.0), None);
    assert_eq!(after.done_watch(3500.0, 3600.0), Some(Nudge::Discord));
    assert_eq!(after.done_watch(3500.0, 3600.0), None);
    // The player hands the nudge to the host when it closes.
    let r = rig();
    let kv2 = Arc::new(Kv::default());
    swiftly_library::KeyValue::set(&*kv2, "bewertungFertig", "2");
    r.vm.set_after_play(Some(Arc::new(AfterPlay::new(kv2, "1.0.3", true))));
    r.picture(101.0, 3500.0, 3600.0);
    r.run(101.0, 103.0, 3500.0);
    r.vm.send(PlayerIntent::Close, 103.0);
    assert!(
        r.vm.take_effects()
            .contains(&PlayerEffect::Nudge(Nudge::Rating))
    );
}

#[test]
fn a_host_that_marks_when_shown_gets_the_same_nudge_again_until_it_marks() {
    let kv = Arc::new(Kv::default());
    let after = AfterPlay::marking_when_shown(kv.clone(), "1.0.3", false);
    for _ in 0..4 {
        assert_eq!(after.done_watch(3500.0, 3600.0), None);
    }
    // The fifth finished title: the Discord hint is due, but nothing marked it yet.
    assert_eq!(after.done_watch(3500.0, 3600.0), Some(Nudge::Discord));
    assert_eq!(
        swiftly_library::KeyValue::get(&*kv, "discordHinweisGezeigt"),
        None
    );
    assert_eq!(
        after.done_watch(3500.0, 3600.0),
        Some(Nudge::Discord),
        "not shown, so it comes again"
    );
    after.mark_shown(Nudge::Discord);
    assert_eq!(
        after.done_watch(3500.0, 3600.0),
        None,
        "shown once, never again"
    );
    // Apple's host marks at once.
    let kv = Arc::new(Kv::default());
    let at_once = AfterPlay::new(kv.clone(), "1.0.3", false);
    for _ in 0..5 {
        let _ = at_once.done_watch(3500.0, 3600.0);
    }
    assert_eq!(
        swiftly_library::KeyValue::get(&*kv, "discordHinweisGezeigt").as_deref(),
        Some("true")
    );
}

#[test]
fn a_newer_remote_order_overtakes_and_a_stuck_player_gives_up() {
    let orders = RemoteOrders::default();
    let a = orders.receive();
    let b = orders.receive();
    assert!(!orders.is_current(a));
    assert!(orders.is_current(b));
    let wait = ReplaceRunning::new(10.0);
    assert_eq!(wait.step(10.1, true, true), CloseStep::Wait);
    assert_eq!(wait.step(10.2, false, false), CloseStep::Wait);
    assert_eq!(wait.step(10.3, false, true), CloseStep::Gone);
    assert_eq!(wait.step(15.0, true, true), CloseStep::GaveUp);
}

// ---- volume, mute, fill, picture in picture, stream check, wake ----

#[test]
fn mute_volume_and_fill_rules() {
    let r = rig();
    r.picture(101.0, 5.0, 3600.0);
    assert_eq!(
        (r.vm.controls().volume, r.vm.controls().muted),
        (100, false)
    );
    r.vm.send(PlayerIntent::Volume(40), 102.0);
    assert!(r.engine.has("volume 40"));
    assert_eq!(r.vm.controls().volume, 40);
    r.vm.send(PlayerIntent::Mute, 102.5);
    assert!(r.engine.has("volume 0"));
    assert!(r.vm.controls().muted);
    r.vm.send(PlayerIntent::Mute, 103.0);
    assert_eq!((r.vm.controls().volume, r.vm.controls().muted), (40, false));
    r.vm.send(PlayerIntent::VolumeStep(0.05), 103.5);
    assert_eq!(r.vm.controls().volume, 45);
    r.vm.send(PlayerIntent::VolumeStep(-1.0), 104.0);
    assert!(r.vm.controls().muted);
    // A slider value above zero ends the mute.
    r.vm.send(PlayerIntent::Volume(10), 104.5);
    assert!(!r.vm.controls().muted);

    r.vm.send(PlayerIntent::Fill(true), 105.0);
    assert!(r.engine.has("fill true"));
    r.vm.send(PlayerIntent::Fill(false), 105.5);
    assert!(r.engine.has("fill false"));
}

#[test]
fn playing_in_the_small_window_is_a_state_of_its_own() {
    let r = rig();
    r.picture(101.0, 5.0, 3600.0);
    r.vm.send(PlayerIntent::WakeControls, 101.5);
    assert!(r.vm.controls().visible);
    assert_eq!(r.vm.transport().small_window, None);
    r.vm.engine_event(EngineEvent::PipPossible(true), 102.0);
    r.vm.engine_event(EngineEvent::PipActive(true), 102.0);
    assert_eq!(r.vm.transport().pip, (true, true));
    assert_eq!(r.vm.transport().small_window, Some(SMALL_WINDOW_TEXT));
    assert!(
        !r.vm.controls().visible,
        "no controls over the small window"
    );
    assert_eq!(r.vm.offer().view, OfferView::Hidden);
    r.vm.engine_event(EngineEvent::PipActive(false), 103.0);
    assert_eq!(r.vm.transport().small_window, None);
    assert!(r.vm.controls().visible);
}

fn looking(r: &Rig, t: f64, read: u64) -> Vec<PlayerEffect> {
    let reading = StreamReading {
        is_file: false,
        pictures_shown: Some(300),
        bytes_read: Some(read),
        audio_lost: None,
    };
    r.vm.send(PlayerIntent::StreamLook(reading), t);
    r.vm.take_effects()
}

#[test]
fn a_dead_stream_is_rebuilt_at_the_same_position_and_a_growing_one_is_not() {
    let r = rig();
    r.picture(101.0, 50.0, 3600.0);
    r.vm.tick(101.5);
    let loads = || {
        r.engine
            .calls()
            .iter()
            .filter(|c| c.starts_with("load"))
            .count()
    };
    assert_eq!(loads(), 1);
    // The buffer keeps growing: slow but alive.
    for i in 0..30 {
        assert!(looking(&r, 102.0 + f64::from(i), 1000 + u64::from(i as u32) * 10).is_empty());
    }
    assert_eq!(loads(), 1);
    // Nothing arrives any more.
    let mut rebuilt = None;
    for i in 0..12 {
        let effects = looking(&r, 140.0 + f64::from(i), 5000);
        if !effects.is_empty() {
            rebuilt = Some((i, effects));
            break;
        }
    }
    let (i, effects) = rebuilt.expect("rebuilt");
    assert!((4..=8).contains(&i), "{i}");
    assert!(matches!(
        effects[0],
        PlayerEffect::StreamRebuilt { position, paused: false, .. } if (position - 50.0).abs() < 1.0
    ));
    assert_eq!(loads(), 2);
    assert!(
        r.engine
            .calls()
            .iter()
            .any(|c| c == "load Some(50.0)" || c.starts_with("load Some(5"))
    );
}

#[test]
fn waking_pauses_before_and_rebuilds_once_paused_after() {
    let r = rig();
    r.picture(101.0, 50.0, 3600.0);
    r.vm.tick(101.5);
    r.vm.send(PlayerIntent::Sleeping, 200.0);
    assert!(r.engine.has("pause"));
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 200.1);
    r.vm.send(PlayerIntent::Woke, 5000.0);
    let effects = r.vm.take_effects();
    assert!(matches!(
        effects[..],
        [PlayerEffect::StreamRebuilt { paused: true, .. }]
    ));
    // The reopened stream stays paused once it is loaded.
    r.vm.engine_event(EngineEvent::LoadFinished { attempt: 2 }, 5000.5);
    assert_eq!(r.engine.calls().last().map(String::as_str), Some("pause"));
    // Windows reports the wake-up twice.
    r.vm.send(PlayerIntent::Woke, 5004.0);
    assert!(r.vm.take_effects().is_empty());
}

#[test]
fn a_stream_that_tears_down_mid_film_is_rebuilt_three_times_at_most() {
    let r = rig();
    r.picture(101.0, 500.0, 3600.0);
    r.vm.tick(101.5);
    for _ in 0..3 {
        r.vm.send(PlayerIntent::StreamTornDown, 110.0);
        assert!(matches!(
            r.vm.take_effects()[..],
            [PlayerEffect::StreamRebuilt { .. }]
        ));
    }
    r.vm.send(PlayerIntent::StreamTornDown, 111.0);
    assert!(r.vm.take_effects().is_empty());
}

#[test]
fn passthrough_and_exclusive_mode_reach_the_engine_before_the_next_load() {
    let r = rig();
    r.vm.set_audio_output(&swiftly_playback::decoder_choice::AudioOutputMode {
        spdif_codecs: Some("ac3,eac3".into()),
        exclusive: true,
    });
    assert!(r.engine.has("audio-output Some(\"ac3,eac3\") true"));
}

// MARK: The report queue (ReportQueue.swift): coalescing, deadline, awaiting, kept stops

/// Holds the drain task until `run`, so reports pile up in the queue like behind a slow server.
#[derive(Default)]
struct Held(Mutex<Vec<std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>>>);
impl swiftly_vm::Spawner for Held {
    fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
        self.0.lock().unwrap().push(task);
    }
}
impl Held {
    fn run(&self) {
        let tasks: Vec<_> = self.0.lock().unwrap().drain(..).collect();
        for t in tasks {
            futures_executor::block_on(t);
        }
    }
}

/// Runs the drain task on its own thread (awaiting a report must not nest executors).
struct OnThread;
impl swiftly_vm::Spawner for OnThread {
    fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
        std::thread::spawn(move || futures_executor::block_on(task));
    }
}

struct ForwardHeld(Arc<Held>);
impl swiftly_vm::Spawner for ForwardHeld {
    fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
        self.0.spawn(task);
    }
}

/// A server that never answers.
struct Hang;
impl swiftly_net::HttpTransport for Hang {
    fn send(
        &self,
        _request: swiftly_net::HttpRequest,
    ) -> impl std::future::Future<Output = Result<swiftly_net::HttpResponse, swiftly_net::ErrorKind>>
    + Send {
        std::future::pending()
    }
}

struct AtOnce;
impl swiftly_vm::Sleeper for AtOnce {
    fn sleep(
        &self,
        _seconds: f64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        Box::pin(std::future::ready(()))
    }
}

#[derive(Default)]
struct Book {
    kept: Mutex<Vec<swiftly_vm::PendingReport>>,
    forgotten: Mutex<Vec<String>>,
}
impl swiftly_vm::PendingSink for Book {
    fn record(&self, report: swiftly_vm::PendingReport) {
        self.kept.lock().unwrap().push(report);
    }
    fn forget(&self, item_id: &str, account: &str) {
        self.forgotten
            .lock()
            .unwrap()
            .push(format!("{account}/{item_id}"));
    }
}

fn paths_of(mock: &swiftly_net::MockTransport) -> Vec<String> {
    mock.requests()
        .iter()
        .map(|q| q.url.path().to_owned())
        .collect()
}

#[test]
fn progress_is_coalesced_and_a_stop_takes_the_unsent_progress_with_it() {
    let mock = Arc::new(swiftly_net::MockTransport::new());
    let held = Arc::new(Held::default());
    let r = swiftly_vm::ClientReporter::new(
        client(&mock),
        "acc",
        Arc::new(ForwardHeld(held.clone())),
        Arc::new(Zero),
        Arc::new(Book::default()),
    );
    r.report(message(ReportKind::Start, 0.0));
    r.report(message(ReportKind::Progress { paused: false }, 10.0));
    r.report(message(ReportKind::Progress { paused: false }, 20.0));
    r.report(message(ReportKind::Progress { paused: true }, 30.0));
    held.run();
    let paths = paths_of(&mock);
    let progress = paths.iter().filter(|p| p.ends_with("/Progress")).count();
    assert_eq!(
        progress, 1,
        "three waiting progress reports become one: {paths:?}"
    );

    r.report(message(ReportKind::Progress { paused: false }, 40.0));
    r.report(message(ReportKind::Stop, 41.0));
    held.run();
    assert_eq!(
        paths_of(&mock),
        vec![
            "/Sessions/Capabilities/Full",
            "/Sessions/Playing",
            "/Sessions/Playing/Progress",
            "/Sessions/Playing/Stopped",
        ]
    );
}

#[test]
fn the_stop_can_be_awaited_and_a_second_one_is_discarded() {
    use swiftly_vm::ReportOutcome;
    let mock = Arc::new(swiftly_net::MockTransport::new());
    let book = Arc::new(Book::default());
    let r = swiftly_vm::ClientReporter::new(
        client(&mock),
        "acc",
        Arc::new(OnThread),
        Arc::new(Zero),
        book.clone(),
    );
    let outcome =
        futures_executor::block_on(r.desk().report_and_wait(message(ReportKind::Stop, 50.0)));
    assert_eq!(outcome, ReportOutcome::Sent);
    assert_eq!(*book.forgotten.lock().unwrap(), vec!["acc/ep1".to_owned()]);
    let again =
        futures_executor::block_on(r.desk().report_and_wait(message(ReportKind::Stop, 51.0)));
    assert_eq!(again, ReportOutcome::Discarded);
    assert!(!r.desk().progress_allowed("sitzung:s1"));
}

#[test]
fn a_server_that_does_not_answer_costs_one_deadline_and_the_stop_is_kept_and_retryable() {
    use swiftly_vm::ReportOutcome;
    let book = Arc::new(Book::default());
    let config = swiftly_jellyfin::ClientConfig::new("dev", "Test", "1.0");
    let c = swiftly_jellyfin::JellyfinClient::new(
        swiftly_vm::Shared(Arc::new(Hang)),
        "https://tv.example.test",
        config,
    )
    .unwrap();
    c.set_session(Some(swiftly_jellyfin::Session {
        access_token: "T".into(),
        user_id: "u".into(),
        user_name: String::new(),
        server_url: "https://tv.example.test".into(),
        kind: swiftly_jellyfin::ServerKind::Jellyfin,
    }));
    let r = swiftly_vm::ClientReporter::new(
        Arc::new(c),
        "acc",
        Arc::new(OnThread),
        Arc::new(Zero),
        book.clone(),
    )
    .with_deadline(Arc::new(AtOnce), 6.0);
    let outcome =
        futures_executor::block_on(r.desk().report_and_wait(message(ReportKind::Stop, 60.0)));
    assert_eq!(outcome, ReportOutcome::TimedOut);
    assert_eq!(book.kept.lock().unwrap().len(), 1);
    assert_eq!(book.kept.lock().unwrap()[0].ticks, 600_000_000);
    // The failed stop released the session: a later stop is accepted again.
    let retry =
        futures_executor::block_on(r.desk().report_and_wait(message(ReportKind::Stop, 61.0)));
    assert_eq!(retry, ReportOutcome::TimedOut);
    assert_eq!(book.kept.lock().unwrap().len(), 2);
}

/// Issue #32 (Android TV / Fire TV): the "Next episode" button did not switch the video and the next
/// episode was marked watched. The button path must do what the card does: one stop for the old
/// episode (with its position), one start for the next, and the next episode is not reported as finished.
#[test]
fn the_next_episode_button_stops_the_old_one_once_and_starts_the_next() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 600.0, 3600.0);
    r.run(101.0, 103.0, 600.0);
    let _ = r.vm.take_effects();
    r.vm.send(PlayerIntent::NextEpisode, 104.0);
    let effects = r.vm.take_effects();
    let starts = effects
        .iter()
        .filter(|e| matches!(e, PlayerEffect::StartEpisode { id, .. } if id == "ep2"))
        .count();
    assert_eq!(starts, 1, "{effects:?}");
    let kinds = r.reports.kinds();
    assert_eq!(
        kinds.iter().filter(|k| **k == ReportKind::Stop).count(),
        1,
        "{kinds:?}"
    );
    let stop = r.reports.last();
    assert_eq!(
        stop.item_id, "ep1",
        "the stop belongs to the episode that was playing"
    );
    assert!(
        stop.seconds < 3540.0,
        "a stop at 600 s must not look like a finished episode: {}",
        stop.seconds
    );
}

/// The screen's tick rules (`PlaybackTick`, oracle-tested in swiftly-rules) run inside the core: scripted
/// sequence with a fake clock, the core's transport against the same rules driven by hand.
#[test]
fn the_core_transport_follows_the_swift_tick_rules_on_a_scripted_sequence() {
    use swiftly_rules::playback_tick::{self as tick, Reading, Snapshot};
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    let mut refer = Snapshot::default();
    let opened = 100.0;
    // (time, engine position, what happens first)
    let step = |t: f64, engine: f64, refer: &mut Snapshot| {
        r.vm.engine_event(
            EngineEvent::Clock {
                position: engine,
                source_time: engine,
            },
            t,
        );
        r.vm.display_tick(t - 0.25);
        r.vm.tick(t);
        let reading = Reading {
            duration: 3600.0,
            position: engine,
            good_point: engine,
            shows_image: true,
            seeks_to_start: false,
            running: true,
            has_audio_tracks: false,
        };
        tick::time_adopt(refer, engine, false, opened, t - 0.25);
        tick::compute(refer, &reading, false, false, opened, t);
        let tr = r.vm.transport();
        assert!(
            (tr.position - refer.position).abs() < 1e-9,
            "t={t}: core {} vs rules {}",
            tr.position,
            refer.position
        );
        assert_eq!(tr.leap, refer.leap.map(|j| j.target), "t={t}");
    };
    let mut t = 101.0;
    let mut p = 0.0;
    for _ in 0..6 {
        t += 0.5;
        p += 0.5;
        step(t, p, &mut refer);
    }
    // A jump: the display stands on the target (the engine's seek target) until the clock lands near it.
    r.vm.send(PlayerIntent::SeekTo(900.0), t);
    assert_eq!(r.vm.transport().leap, Some(900.0));
    assert_eq!(r.vm.transport().position, 900.0);
    t += 0.5;
    r.vm.engine_event(
        EngineEvent::Clock {
            position: 900.2,
            source_time: 900.2,
        },
        t,
    );
    r.vm.display_tick(t - 0.25);
    r.vm.tick(t);
    assert_eq!(
        r.vm.transport().leap,
        None,
        "arrived: the engine's time again"
    );
    assert!((r.vm.transport().position - 900.0).abs() < 1.0);
    assert!(r.vm.transport().running);
}

#[test]
fn restoring_shows_the_last_good_position_not_the_dead_clock() {
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    let end = r.run(101.0, 121.0, 0.0);
    let shown = r.vm.transport().position;
    assert!(shown > 15.0, "{shown}");
    r.vm.send(PlayerIntent::Restoring(true), end);
    // A dead stream: the engine reads the end of the file (it would be adopted without the flag).
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), end + 0.5);
    r.vm.display_tick(end + 0.25);
    r.vm.tick(end + 0.5);
    assert!(
        (r.vm.transport().position - shown).abs() < 2.0,
        "{}",
        r.vm.transport().position
    );
    r.vm.send(PlayerIntent::Restoring(false), end + 1.0);
}

#[test]
fn airplay_start_is_decided_by_stage_surface_and_file() {
    use swiftly_vm::{AirPlayStart, Surface, SurfaceEvent};
    let good: swiftly_model::MediaSource = serde_json::from_str(
        r#"{"Id":"s","MediaStreams":[{"Type":"Video","Codec":"h264","Index":0},{"Type":"Audio","Codec":"aac","Index":1,"IsDefault":true}]}"#,
    )
    .unwrap();
    let bad: swiftly_model::MediaSource = serde_json::from_str(
        r#"{"Id":"s","MediaStreams":[{"Type":"Video","Codec":"av1","Index":0},{"Type":"Audio","Codec":"aac","Index":1}]}"#,
    )
    .unwrap();
    let r = rig();
    // Opening: no picture yet.
    assert_eq!(r.vm.airplay_start(&good), AirPlayStart::Ignore);
    r.picture(101.0, 0.0, 3600.0);
    r.vm.tick(101.5);
    assert!(
        matches!(r.vm.stage(), swiftly_vm::PlayerStage::Playing),
        "{:?}",
        r.vm.stage()
    );
    assert!(matches!(r.vm.airplay_start(&bad), AirPlayStart::Refused(_)));
    assert_eq!(
        r.vm.surface(),
        Surface::Inline,
        "a refusal does not move the surface"
    );
    assert_eq!(
        r.vm.airplay_start(&good),
        AirPlayStart::Go {
            audio_track: Some(1)
        }
    );
    assert_eq!(r.vm.surface(), Surface::AirPlayAsking);
    assert_eq!(
        r.vm.airplay_start(&good),
        AirPlayStart::Ignore,
        "already asking"
    );
    assert_eq!(
        r.vm.surface_event(SurfaceEvent::AirPlayTaken),
        Surface::AirPlay
    );
    assert_eq!(
        r.vm.surface_event(SurfaceEvent::AirPlayBack),
        Surface::Inline
    );
    // The small window blocks AirPlay.
    r.vm.surface_event(SurfaceEvent::Pip(true));
    assert_eq!(r.vm.airplay_start(&good), AirPlayStart::Ignore);
    r.vm.send(PlayerIntent::Close, 200.0);
    assert_eq!(r.vm.surface(), Surface::Inline);
}

// ---- A subtitle while a transcoded stream plays ------------------------------------------------

const HLS: &str = "https://tv.example.test/videos/ep1/master.m3u8?VideoCodec=h264&TranscodeReasons=VideoCodecNotSupported";

/// A running title with a PGS (4), a text (3) track; `method` and the stream address as the plan gave them.
fn transcode_rig(method: PlayMethod, url: &str) -> Rig {
    let engine = Arc::new(Fake::default());
    let reports = Arc::new(Reports::default());
    let mut sp = spec(600.0, false);
    sp.plan.method = method;
    sp.request.url = url.into();
    sp.request
        .streams
        .push(stream(4, "Subtitle", "eng", "hdmv_pgs_subtitle"));
    let vm = PlayerVm::new(
        engine.clone(),
        reports.clone(),
        Arc::new(Words),
        PlayerPrefs::default(),
        sp,
        100.0,
    );
    vm.start(100.0);
    let r = Rig {
        vm,
        engine,
        reports,
    };
    r.picture(101.0, 600.0, 3600.0);
    r.run(101.0, 103.0, 600.0);
    r
}

fn reload_of(effects: &[PlayerEffect]) -> Option<(String, i64, f64)> {
    effects.iter().find_map(|e| match e {
        PlayerEffect::ReloadForSubtitle {
            id,
            subtitle,
            since,
            ..
        } => Some((id.clone(), *subtitle, *since)),
        _ => None,
    })
}

#[test]
fn a_bitmap_subtitle_on_a_transcode_reloads_at_the_position_with_the_track() {
    let r = transcode_rig(PlayMethod::Transcode, HLS);
    r.vm.take_effects();
    let calls_before = r.engine.calls().len();
    r.vm.send(PlayerIntent::SelectSubtitle(4), 104.0);
    let effects = r.vm.take_effects();
    let (id, subtitle, since) = reload_of(&effects).expect("a reload for the subtitle");
    assert_eq!((id.as_str(), subtitle), ("ep1", 4));
    assert!(since > 600.0, "{since}");
    // The plain restart effect is not sent as well, the old stream's stop went out, the engine got no track call.
    assert!(
        !effects
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. }))
    );
    assert!(r.reports.kinds().contains(&ReportKind::Stop));
    assert!(
        !r.engine.calls()[calls_before..]
            .iter()
            .any(|c| c.starts_with("subtitle"))
    );
    // The reloaded stream is burned in: the same track is no new reload, the engine has nothing to switch.
    let burned = format!("{HLS}&SubtitleMethod=Encode&SubtitleStreamIndex=4");
    r.vm.load_title(
        {
            let mut sp = spec(since, false);
            sp.plan.method = PlayMethod::Transcode;
            sp.request.url = burned.clone();
            sp.request
                .streams
                .push(stream(4, "Subtitle", "eng", "hdmv_pgs_subtitle"));
            sp.subtitle_index = 4;
            sp
        },
        105.0,
    );
    r.vm.take_effects();
    r.vm.send(PlayerIntent::SelectSubtitle(4), 106.0);
    assert!(reload_of(&r.vm.take_effects()).is_none());
    // Dropping the burned track, or taking another, needs a new plan again.
    r.vm.send(PlayerIntent::SelectSubtitle(-1), 107.0);
    assert_eq!(reload_of(&r.vm.take_effects()).map(|(_, s, _)| s), Some(-1));
}

/// Pause, pick a picture subtitle on a transcode, let the reloaded stream arrive: it pauses once it is loaded.
fn reload_after_pick(pause_first: bool) -> Rig {
    let r = transcode_rig(PlayMethod::Transcode, HLS);
    if pause_first {
        r.vm.send(PlayerIntent::TogglePlay, 104.0);
        // The engine confirms the pause (the stage reads the transport from it).
        r.vm.engine_event(EngineEvent::State(EngineState::Paused), 104.1);
    }
    r.vm.take_effects();
    r.vm.send(PlayerIntent::SelectSubtitle(4), 105.0);
    let (_, _, since) = reload_of(&r.vm.take_effects()).expect("a reload for the subtitle");
    let mut sp = spec(since, false);
    sp.plan.method = PlayMethod::Transcode;
    sp.request.url = format!("{HLS}&SubtitleMethod=Encode&SubtitleStreamIndex=4");
    sp.request
        .streams
        .push(stream(4, "Subtitle", "eng", "hdmv_pgs_subtitle"));
    sp.subtitle_index = 4;
    r.vm.load_title(sp, 106.0);
    let before = r.engine.calls().iter().filter(|c| *c == "pause").count();
    r.picture(107.0, since, 3600.0);
    let after = r.engine.calls().iter().filter(|c| *c == "pause").count();
    assert_eq!(
        after > before,
        pause_first,
        "pause calls {before} -> {after}"
    );
    r
}

/// What the Apple hosts do with the reload: the plan for it goes to a NEW model (`startEngine` builds one per plan), so
/// the old model's switch state is gone and `load_title` never runs. The old model's effect says whether the stream was
/// paused; the host hands that to the new model (`start_paused`) before the engine's load finishes. Returns the effect's
/// `paused` and the transport commands the new model gave its engine.
fn new_model_after_pick(pause_first: bool, tell_the_new_model: bool) -> (bool, Vec<String>) {
    let r = transcode_rig(PlayMethod::Transcode, HLS);
    if pause_first {
        r.vm.send(PlayerIntent::TogglePlay, 104.0);
        r.vm.engine_event(EngineEvent::State(EngineState::Paused), 104.1);
    }
    r.vm.take_effects();
    r.vm.send(PlayerIntent::SelectSubtitle(4), 105.0);
    let effects = r.vm.take_effects();
    let (_, _, since) = reload_of(&effects).expect("a reload for the subtitle");
    let paused = effects
        .iter()
        .find_map(|e| match e {
            PlayerEffect::ReloadForSubtitle { paused, .. } => Some(*paused),
            _ => None,
        })
        .expect("the reload effect");
    // The host drops the old model and builds the next one for the burned-in plan.
    let engine = Arc::new(Fake::default());
    let mut sp = spec(since, false);
    sp.plan.method = PlayMethod::Transcode;
    sp.request.url = format!("{HLS}&SubtitleMethod=Encode&SubtitleStreamIndex=4");
    sp.request
        .streams
        .push(stream(4, "Subtitle", "eng", "hdmv_pgs_subtitle"));
    sp.subtitle_index = 4;
    let vm = PlayerVm::new(
        engine.clone(),
        Arc::new(Reports::default()),
        Arc::new(Words),
        PlayerPrefs::default(),
        sp,
        106.0,
    );
    if paused && tell_the_new_model {
        vm.start_paused();
    }
    vm.start(106.0);
    // The engine's answers, in the order it gives them.
    for event in [
        EngineEvent::LoadFinished { attempt: 1 },
        EngineEvent::Duration(3600.0),
        EngineEvent::FirstFrame,
        EngineEvent::Clock {
            position: since,
            source_time: since,
        },
    ] {
        vm.engine_event(event, 107.0);
    }
    let transport = engine
        .calls()
        .into_iter()
        .filter(|c| c == "play" || c == "pause")
        .collect();
    (paused, transport)
}

#[test]
fn a_paused_title_stays_paused_when_the_host_builds_a_new_model_for_the_reload() {
    let (paused, transport) = new_model_after_pick(true, true);
    assert!(paused, "the effect says the old stream was paused");
    // The load finished: the last word to the engine is pause, and no play comes after it.
    assert_eq!(
        transport.last().map(String::as_str),
        Some("pause"),
        "{transport:?}"
    );
}

#[test]
fn the_new_model_that_is_not_told_plays_on() {
    // The measured failure: the effect said paused, the host built the new model without it, the engine got `play`
    // and no `pause` (`load, play, pause, load, play` at the engine).
    let (paused, transport) = new_model_after_pick(true, false);
    assert!(paused);
    assert_eq!(transport, vec!["play".to_string()]);
}

#[test]
fn a_playing_title_is_not_paused_by_the_reload() {
    let (paused, transport) = new_model_after_pick(false, true);
    assert!(!paused);
    assert_eq!(transport, vec!["play".to_string()]);
}

#[test]
fn a_subtitle_reload_keeps_a_paused_title_paused() {
    reload_after_pick(true);
}

#[test]
fn a_subtitle_reload_of_a_playing_title_keeps_playing() {
    reload_after_pick(false);
}

#[test]
fn direct_play_and_text_tracks_switch_in_the_engine_without_a_reload() {
    // Table: (method, address, subtitle chosen). Direct play with a bitmap, a text track on a transcode,
    // off on a transcode that burns nothing, a copying transcode with a bitmap.
    let copy =
        "https://tv.example.test/videos/ep1/master.m3u8?TranscodeReasons=ContainerNotSupported";
    for (method, url, wanted) in [
        (PlayMethod::DirectPlay, "https://tv.example.test/v", 4),
        (PlayMethod::DirectStream, "https://tv.example.test/v", 4),
        (PlayMethod::Transcode, HLS, 3),
        (PlayMethod::Transcode, HLS, -1),
        (PlayMethod::Transcode, copy, 4),
    ] {
        let r = transcode_rig(method, url);
        r.vm.take_effects();
        r.vm.send(PlayerIntent::SelectSubtitle(wanted), 104.0);
        assert!(
            reload_of(&r.vm.take_effects()).is_none(),
            "{method:?} {url} {wanted}"
        );
        assert!(
            !r.reports.kinds().contains(&ReportKind::Stop),
            "{method:?} {url} {wanted}"
        );
    }
}

#[test]
fn a_download_never_reloads_for_a_subtitle() {
    let engine = Arc::new(Fake::default());
    let mut sp = spec(0.0, false);
    sp.downloaded = true;
    sp.plan.method = PlayMethod::Transcode;
    sp.request.url = HLS.into();
    sp.request
        .streams
        .push(stream(4, "Subtitle", "eng", "hdmv_pgs_subtitle"));
    let vm = PlayerVm::new(
        engine,
        Arc::new(Reports::default()),
        Arc::new(Words),
        PlayerPrefs::default(),
        sp,
        100.0,
    );
    vm.start(100.0);
    vm.send(PlayerIntent::SelectSubtitle(4), 101.0);
    assert!(reload_of(&vm.take_effects()).is_none());
}

// ---- apple-feature-gate: contract lines 17, 19, 20 ----

/// Line 17: the buttons and keys move by the set length (30 s), never by a fixed 10 s, and stop at both ends.
#[test]
fn skip_buttons_move_by_the_set_seconds_and_clamp_at_both_ends() {
    let prefs = PlayerPrefs {
        back_seconds: 30,
        forward_seconds: 30,
        ..PlayerPrefs::default()
    };
    let r = rig_with(0.0, false, prefs);
    r.picture(101.0, 100.0, 3600.0);
    r.vm.tick(101.5);
    r.vm.send(PlayerIntent::Forward, 102.0);
    assert!(r.engine.has("seek 130"), "{:?}", r.engine.calls());
    assert_eq!(r.vm.transport().position, 130.0);
    r.vm.send(PlayerIntent::Back, 103.5);
    assert_eq!(r.vm.transport().position, 100.0);
    // Near the start: the jump back stops at 0 (not -20).
    r.vm.send(PlayerIntent::SeekTo(20.0), 105.0);
    r.vm.send(PlayerIntent::Back, 106.0);
    assert_eq!(r.vm.transport().position, 0.0);
    assert!(r.engine.has("seek 0"), "{:?}", r.engine.calls());
    // Near the end: the jump forward stops at the length.
    r.vm.send(PlayerIntent::SeekTo(3590.0), 108.0);
    r.vm.send(PlayerIntent::Forward, 109.0);
    let p = r.vm.transport().position;
    assert!(p <= 3600.0 + 1e-9, "past the end: {p}");
    assert!(p >= 3590.0, "moved back instead of forward: {p}");
}

/// Line 19 (Discord xKonan): with "next episode automatically" off the card still counts, but the
/// episode never changes on its own, even when the film runs to its very end.
#[test]
fn autoplay_off_never_plays_the_next_episode_on_its_own() {
    let prefs = PlayerPrefs {
        next_automatic: false,
        auto_skip: false,
        ..PlayerPrefs::default()
    };
    let r = rig_with(0.0, true, prefs);
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3499.0, 3600.0);
    r.run(101.0, 103.0, 3499.0);
    r.run(103.0, 160.0, 3501.0);
    let effects = r.vm.take_effects();
    assert!(
        !effects
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. })),
        "{effects:?}"
    );
    // The end of the file with autoplay off ends the player, it does not start the next episode.
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), 161.0);
    let effects = r.vm.take_effects();
    assert!(
        !effects
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. })),
        "{effects:?}"
    );
}

/// Line 20 (#18): a segment that starts at the first frame does not skip at once, and the ring is
/// not restarted by a seek inside the segment.
#[test]
fn auto_skip_does_not_act_at_frame_zero_and_the_ring_survives_a_seek_inside() {
    let r = rig_with(0.0, false, auto_prefs(true));
    r.vm.set_sections(vec![Segment::new(Art::IntroSegment, 0.0, 90.0)]);
    r.picture(101.0, 0.0, 3600.0);
    r.vm.tick(101.1);
    assert_eq!(seek_count(&r), 0, "an instant skip at frame 0");
    r.run(101.1, 104.0, 0.1);
    assert_eq!(seek_count(&r), 0, "the countdown has not run out yet");
    let ring = |r: &Rig| match r.vm.offer().view {
        OfferView::Button { countdown, .. } => countdown,
        other => panic!("{other:?}"),
    };
    let before = ring(&r).expect("ring counts");
    assert!(before > 0.0, "{before}");
    // A seek inside the segment does not put the ring back to zero.
    r.vm.send(PlayerIntent::SeekTo(20.0), 104.0);
    r.vm.tick(104.5);
    let after = ring(&r).expect("ring still there");
    assert!(after >= before, "the ring restarted: {before} -> {after}");
    r.run(104.5, 125.0, 20.5);
    assert_eq!(
        seek_count(&r),
        2,
        "one for the user's seek, one for the skip"
    );
}

// MARK: Resume position from the first frame

/// The shown time of a resumed title before the engine reported anything.
fn shown(r: &Rig) -> f64 {
    r.vm.transport().position
}

/// A title that resumes at 80 s shows 80 s from the first frame, not 0:00 until the engine's picture is up
/// (the Mac and iPhone screens seed their display with the start position the same way).
#[test]
fn resume_position_shows_from_the_first_frame() {
    let r = rig_with(80.0, false, PlayerPrefs::default());
    assert_eq!(shown(&r), 80.0, "straight after the start");
    assert_eq!(r.vm.transport().phase, Phase::Loading);
    // The remaining time is right from the first frame too: the source's runtime stands in for the engine's length.
    assert_eq!(r.vm.transport().duration, 3600.0);
    // Nothing the engine says before its picture moves it: ticks, duration, the load finishing.
    r.vm.display_tick(100.25);
    r.vm.tick(100.5);
    assert_eq!(shown(&r), 80.0, "after the first ticks");
    r.vm.engine_event(EngineEvent::Duration(150.0), 100.6);
    r.vm.engine_event(EngineEvent::LoadFinished { attempt: 1 }, 100.7);
    r.vm.display_tick(100.75);
    r.vm.tick(101.0);
    assert_eq!(
        shown(&r),
        80.0,
        "with duration and load known, picture not yet"
    );
    assert_eq!(r.vm.transport().duration, 150.0, "the engine's length wins");
    // The picture is up and the clock stands at the resume point: no step back, no jump.
    r.picture(101.1, 80.4, 150.0);
    r.vm.display_tick(101.25);
    r.vm.tick(101.5);
    assert_eq!(shown(&r), 80.4);
    assert!(r.vm.transport().picture_shown);
}

/// No resume (or one the server rounds to the beginning) keeps the clock at 0, as before.
#[test]
fn no_resume_position_starts_at_zero() {
    for start in [0.0, 0.3] {
        let r = rig_with(start, false, PlayerPrefs::default());
        assert_eq!(shown(&r), 0.0, "start {start}");
    }
    // A damaged resume point means the beginning, as the state machine reads it.
    for start in [f64::NAN, -5.0] {
        let r = rig_with(start, false, PlayerPrefs::default());
        assert_eq!(shown(&r), 0.0, "start {start}");
    }
}

/// A start that fails shows the resume point on the failure card (the point a fallback stream takes over at), not 0.
#[test]
fn failed_start_keeps_the_resume_point() {
    let r = rig_with(80.0, false, PlayerPrefs::default());
    r.vm.engine_event(
        EngineEvent::LoadFailed {
            attempt: 1,
            message: "timeout".into(),
            kind: None,
        },
        101.0,
    );
    r.vm.display_tick(101.25);
    r.vm.tick(101.5);
    assert!(r.vm.transport().failure.is_some());
    assert_eq!(shown(&r), 80.0);
}

/// The engine did not honour the start (the stream plays from the beginning): the seeded time does not stay for good.
/// The display follows the engine's real time once the start window (25 s) is over.
#[test]
fn declined_start_seek_does_not_leave_the_resume_time_for_good() {
    let r = rig_with(80.0, false, PlayerPrefs::default());
    r.picture(101.0, 0.2, 150.0);
    r.vm.display_tick(101.25);
    r.vm.tick(101.5);
    // Inside the start window the engine's low clock is held back (issue #43), the display stays at the resume point.
    assert_eq!(shown(&r), 80.0);
    // Past it the engine's own time wins.
    let end = r.run(101.5, 130.0, 1.0);
    let p = shown(&r);
    assert!(
        (p - (1.0 + (end - 101.5))).abs() < 1.0,
        "the display still shows {p} while the engine plays near {}",
        1.0 + (end - 101.5)
    );
}

// ---- Progress schedule and scrub/hide rules (item: progress every ten seconds, no hide during a scrub) ----

/// Ticks of `step` seconds from `from` to `to`, the engine clock following real time (position = t - from + at).
fn ticks_every(r: &Rig, step: f64, from: f64, to: f64, position_at_from: f64) {
    let mut t = from;
    while t < to - 1e-9 {
        t += step;
        let p = position_at_from + (t - from);
        r.vm.engine_event(
            EngineEvent::Clock {
                position: p,
                source_time: p,
            },
            t,
        );
        r.vm.tick(t);
    }
}

/// The positions of the progress reports of a film that plays in real time from 0: each is the time it went out.
fn progress_times(r: &Rig) -> Vec<f64> {
    r.reports
        .0
        .lock()
        .unwrap()
        .iter()
        .filter(|m| matches!(m.kind, ReportKind::Progress { .. }))
        .map(|m| m.seconds)
        .collect()
}

/// The server must never be more than about ten seconds behind, for a whole film and also when the host's tick
/// loop runs late (twenty late ticks used to be the only spacing: a 2 s loop reported every 40 s).
#[test]
fn progress_goes_out_every_ten_seconds_for_a_whole_film_also_with_late_ticks() {
    // 0.6 s is the rate where the rules' own count of twenty ticks (12 s) and the wall-clock beat (10.2 s) disagree:
    // both used to report, 1.8 s apart. The same holds for 0.3, 0.9 and 1.3.
    for step in [0.3, 0.5, 0.6, 0.9, 1.0, 1.3, 2.0, 4.0] {
        let r = rig();
        r.picture(101.0, 0.0, 7200.0);
        r.vm.tick(101.5);
        assert_eq!(r.reports.kinds(), vec![ReportKind::Start]);
        // 35 minutes: the length of the film in which the server once held minute 9.
        ticks_every(&r, step, 101.5, 101.5 + 35.0 * 60.0, 0.5);
        let at = progress_times(&r);
        let slack = 10.0 + step;
        assert!(
            at.len() as f64 >= 35.0 * 60.0 / slack - 1.0,
            "step {step}: only {} progress reports in 35 min",
            at.len()
        );
        let mut last = 0.5;
        for t in &at {
            assert!(
                t - last <= slack + 1e-6,
                "step {step}: gap {} s between reports",
                t - last
            );
            // One beat, one source: never a second report soon after one (a double report is not a late one).
            assert!(
                t - last >= 10.0 - 1e-6,
                "step {step}: only {} s between two reports",
                t - last
            );
            last = *t;
        }
        assert!(
            35.0 * 60.0 - last <= slack,
            "step {step}: the tail is unreported"
        );
    }
}

#[test]
fn background_reports_the_position_at_once_playing_or_paused() {
    let r = rig();
    r.picture(101.0, 100.0, 3600.0);
    r.vm.tick(101.5);
    ticks_every(&r, 0.5, 101.5, 104.0, 100.5);
    let before = progress_times(&r).len();
    r.vm.send(PlayerIntent::Background { paused: false }, 104.0);
    assert_eq!(progress_times(&r).len(), before + 1, "one report at once");
    assert_eq!(
        r.reports.last().kind,
        ReportKind::Progress { paused: false },
        "still playing"
    );
    // Playing on: the next beat still comes within ten seconds of the background report.
    ticks_every(&r, 0.5, 104.0, 114.5, 103.0);
    assert!(progress_times(&r).len() > before + 1);
    // Paused: the report says so.
    r.vm.send(PlayerIntent::TogglePlay, 115.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 115.0);
    r.vm.send(PlayerIntent::Background { paused: false }, 116.0);
    assert_eq!(r.reports.last().kind, ReportKind::Progress { paused: true });
    // Before the first picture there is nothing to report; after the close nothing goes out.
    let fresh = rig();
    fresh
        .vm
        .send(PlayerIntent::Background { paused: false }, 101.0);
    assert!(fresh.reports.kinds().is_empty());
    r.vm.send(PlayerIntent::Close, 117.0);
    let n = r.reports.kinds().len();
    r.vm.send(PlayerIntent::Background { paused: false }, 118.0);
    assert_eq!(r.reports.kinds().len(), n);
}

/// No auto-hide during a scrub, however long: touch drag with a rest in the middle (longer than the safety that lets
/// go of a stuck scrubber), and the hide timer starts only after the release.
#[test]
fn the_bar_stays_for_a_scrub_longer_than_the_hide_delay_and_hides_four_seconds_after_the_release() {
    let r = rig();
    r.picture(101.0, 0.0, 7200.0);
    r.vm.send(PlayerIntent::WakeControls, 102.0);
    r.vm.send(PlayerIntent::ScrubStart, 102.0);
    // Twelve seconds of dragging: three times the hide delay.
    let mut t = 102.0;
    while t < 114.0 {
        t += 0.5;
        r.vm.send(PlayerIntent::ScrubMove(1000.0 + t), t);
        r.vm.tick(t);
        assert!(r.vm.controls().visible, "hidden while dragging at {t}");
    }
    // The finger rests for six seconds without a move (the stuck-scrubber safety lets go after three).
    while t < 120.0 {
        t += 0.5;
        r.vm.tick(t);
        assert!(
            r.vm.controls().visible,
            "hidden under a resting finger at {t}"
        );
    }
    // Release: the timer starts here, so the bar is there for the next 3.5 s and gone after 4.5 s.
    r.vm.send(PlayerIntent::ScrubEnd(1100.0), t);
    let released = t;
    while t < released + 3.5 {
        t += 0.5;
        r.vm.engine_event(
            EngineEvent::Clock {
                position: 1100.0 + (t - released),
                source_time: 1100.0 + (t - released),
            },
            t,
        );
        r.vm.tick(t);
        assert!(
            r.vm.controls().visible,
            "hidden {} s after the release",
            t - released
        );
    }
    while t < released + 4.6 {
        t += 0.5;
        r.vm.tick(t);
    }
    assert!(!r.vm.controls().visible, "still up 4.6 s after the release");
}

/// The host paused its engine on the way out and the engine's own report has not reached the core (a backgrounded app
/// draws no frames): the report carries what the host says, not the last state the core heard.
#[test]
fn background_report_carries_the_state_the_host_declares() {
    let r = rig();
    r.picture(101.0, 100.0, 3600.0);
    r.vm.tick(101.5);
    ticks_every(&r, 0.5, 101.5, 104.0, 100.5);
    // No engine event: the core still believes it plays.
    r.vm.send(PlayerIntent::Background { paused: true }, 104.0);
    assert_eq!(
        r.reports.last().kind,
        ReportKind::Progress { paused: true },
        "the host had paused"
    );
    // The late engine report does not send the same state twice.
    let n = r.reports.kinds().len();
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 104.1);
    assert_eq!(r.reports.kinds().len(), n, "one report for one pause");
}

/// Regression: the bar hid under a resting finger. A thumb that stays on the slider for half a minute keeps the
/// bar the whole time; only the release (or a cancel the host reports as the end) starts the four seconds.
#[test]
fn a_finger_resting_for_thirty_seconds_keeps_the_bar_and_the_scrub() {
    let r = rig();
    r.picture(101.0, 0.0, 7200.0);
    r.vm.send(PlayerIntent::WakeControls, 102.0);
    r.vm.send(PlayerIntent::ScrubStart, 102.0);
    r.vm.send(PlayerIntent::ScrubMove(1000.0), 102.5);
    let mut t = 102.5;
    while t < 102.5 + 30.0 {
        t += 0.5;
        r.vm.tick(t);
        assert!(
            r.vm.controls().visible,
            "bar hidden {} s into the rest",
            t - 102.5
        );
        assert!(
            r.vm.controls().scrubbing,
            "scrub let go {} s into the rest",
            t - 102.5
        );
    }
    // The finger lets go: nothing was decided in between, so the bar is still up and then counts four seconds.
    r.vm.send(PlayerIntent::ScrubEnd(1000.0), t);
    let released = t;
    while t < released + 3.5 {
        t += 0.5;
        r.vm.tick(t);
        assert!(
            r.vm.controls().visible,
            "hidden {} s after the release",
            t - released
        );
    }
    while t < released + 4.6 {
        t += 0.5;
        r.vm.tick(t);
    }
    assert!(!r.vm.controls().visible, "still up 4.6 s after the release");
}

/// The app leaving the foreground takes the touch with it: the scrub ends there (no seek), instead of hanging for
/// ever now that no timer lets go of it.
#[test]
fn leaving_the_foreground_ends_a_scrub_in_progress() {
    let r = rig();
    r.picture(101.0, 0.0, 7200.0);
    r.vm.send(PlayerIntent::ScrubStart, 102.0);
    r.vm.send(PlayerIntent::ScrubMove(1000.0), 102.5);
    assert!(r.vm.controls().scrubbing);
    r.vm.send(PlayerIntent::Background { paused: true }, 103.0);
    assert!(!r.vm.controls().scrubbing, "the scrub is over");
}

// MARK: A failed plan for the next episode

/// A host whose plan call always fails: it counts every `StartEpisode` it is asked for and answers with
/// [`PlayerVm::switch_failed`], once per request. Everything a tick hands out passes through here.
#[derive(Default)]
struct FailingHost {
    plan_requests: usize,
    /// The hint right after the last failure answer.
    hint_after: Option<String>,
}

impl FailingHost {
    fn serve(&mut self, r: &Rig, now: f64) {
        for e in r.vm.take_effects() {
            if matches!(e, PlayerEffect::StartEpisode { .. }) {
                self.plan_requests += 1;
                r.vm.switch_failed(now);
                self.hint_after = r.vm.transport().hint;
            }
        }
    }

    /// 500 ms ticks with the clock running, the host serving what comes out; returns the clock position.
    fn ticks(&mut self, r: &Rig, from: f64, n: usize, position_at_from: f64) -> f64 {
        let mut t = from;
        for _ in 0..n {
            t += 0.5;
            let p = position_at_from + (t - from);
            r.vm.engine_event(
                EngineEvent::Clock {
                    position: p,
                    source_time: p,
                },
                t,
            );
            r.vm.display_tick(t - 0.25);
            r.vm.tick(t);
            self.serve(r, t);
        }
        t
    }
}

fn loads(r: &Rig) -> usize {
    r.engine
        .calls()
        .iter()
        .filter(|c| c.starts_with("load"))
        .count()
}

/// The old title is back in `Playing` after the engine delivered its picture again.
fn old_title_picture_again(r: &Rig, now: f64, position: f64) {
    r.picture(now, position, 3600.0);
    r.vm.tick(now + 0.1);
}

#[test]
fn a_failed_plan_brings_the_old_title_back_with_one_hint_and_no_automatic_retry() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3499.0, 3600.0);
    r.run(101.0, 103.0, 3499.0);
    // The countdown runs out: the core asks for the plan of ep2, and the host's plan call fails.
    r.run(103.0, 113.0, 3501.0);
    let mut host = FailingHost::default();
    host.serve(&r, 113.0);
    assert_eq!(host.plan_requests, 1);
    assert_eq!(
        r.vm.transport().hint.as_deref(),
        Some(SWITCH_FAILED_HINT),
        "one German line says why"
    );
    // Not stuck in `Switching`: the old title is loading again at its position, not failed, not closed.
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Opening);
    assert_ne!(r.vm.transport().phase, Phase::Failed);
    assert_eq!(loads(&r), 2, "the old title is reopened once");
    old_title_picture_again(&r, 113.2, 3511.0);
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Playing);

    // 20 ticks later (the card still counting, the end near): still one plan request, the same single hint.
    let t = host.ticks(&r, 113.3, 20, 3511.0);
    assert_eq!(host.plan_requests, 1, "a retry loop asks again every tick");
    assert_eq!(
        r.vm.transport().hint,
        None,
        "the single hint went after its time"
    );
    assert_eq!(loads(&r), 2);
    assert_eq!(
        r.reports
            .kinds()
            .iter()
            .filter(|k| **k == ReportKind::Stop)
            .count(),
        1,
        "the stop went out once"
    );
    assert_eq!(
        r.reports
            .kinds()
            .iter()
            .filter(|k| **k == ReportKind::Start)
            .count(),
        2,
        "the server hears exactly one new start for the old title that goes on"
    );

    // A second failure answer without a request changes nothing.
    r.vm.switch_failed(t);
    assert_eq!(loads(&r), 2);

    // The user's Next is the retry: it asks again (and the hint goes while the plan is asked for).
    r.vm.send(PlayerIntent::NextEpisode, t + 0.1);
    assert_eq!(r.vm.transport().hint, None);
    host.serve(&r, t + 0.1);
    assert_eq!(host.plan_requests, 2, "the manual retry asks the host once");
    assert_eq!(r.vm.transport().hint.as_deref(), Some(SWITCH_FAILED_HINT));
    host.ticks(&r, t + 0.2, 20, 3531.0);
    assert_eq!(host.plan_requests, 2, "and again no automatic loop");
}

#[test]
fn a_failed_plan_after_the_end_leaves_the_title_over_and_next_is_the_retry() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3590.0, 3600.0);
    r.run(101.0, 103.0, 3590.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), 104.0);
    let mut host = FailingHost::default();
    let t = host.ticks(&r, 104.0, 40, 3600.0);
    assert_eq!(host.plan_requests, 1, "the end advanced once");
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Ended);
    assert_eq!(r.vm.transport().phase, Phase::Ended);
    assert_eq!(host.hint_after.as_deref(), Some(SWITCH_FAILED_HINT));
    assert_eq!(
        r.vm.transport().hint,
        None,
        "and the hint went after its time"
    );
    assert_eq!(loads(&r), 1, "an ended title is not reopened");
    host.ticks(&r, t, 20, 3600.0);
    assert_eq!(host.plan_requests, 1);
    r.vm.send(PlayerIntent::NextEpisode, t + 20.0);
    host.serve(&r, t + 20.0);
    assert_eq!(host.plan_requests, 2);
}

#[test]
fn a_failed_plan_for_a_paused_title_brings_it_back_paused() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 600.0, 3600.0);
    r.run(101.0, 103.0, 600.0);
    r.vm.send(PlayerIntent::TogglePlay, 103.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 103.0);
    r.run(103.0, 104.0, 602.0);
    r.vm.send(PlayerIntent::NextEpisode, 104.0);
    let mut host = FailingHost::default();
    host.serve(&r, 104.0);
    assert_eq!(host.plan_requests, 1);
    assert_eq!(loads(&r), 2);
    old_title_picture_again(&r, 104.2, 602.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Paused), 104.3);
    r.vm.tick(104.5);
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Paused);
    assert_eq!(r.vm.transport().hint.as_deref(), Some(SWITCH_FAILED_HINT));
}

/// A title that ended, whose next-episode plan failed: the old title is still over on its last frame.
fn ended_after_a_failed_plan() -> (Rig, f64) {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.vm.set_sections(vec![Segment::new(Art::Credits, 3500.0, 3600.0)]);
    r.picture(101.0, 3590.0, 3600.0);
    r.run(101.0, 103.0, 3590.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), 104.0);
    let mut host = FailingHost::default();
    let t = host.ticks(&r, 104.0, 40, 3600.0);
    assert_eq!(host.plan_requests, 1, "the end asked for the plan once");
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Ended);
    assert_eq!(
        loads(&r),
        1,
        "an ended title is not reopened by the failure"
    );
    (r, t)
}

#[test]
fn replay_after_a_failed_plan_from_an_ended_title_loads_it_again() {
    let (r, t) = ended_after_a_failed_plan();
    // The switch stopped the engine; the title is over, so the play button replays it from the start.
    r.vm.send(PlayerIntent::TogglePlay, t + 1.0);
    assert_eq!(
        loads(&r),
        2,
        "replay opens the title again, not a dead still frame"
    );
    assert_eq!(
        r.engine.calls().last().map(String::as_str),
        Some("load None"),
        "from the start"
    );
    // Its picture comes back and it plays again: no longer over.
    let e = |ev| r.vm.engine_event(ev, t + 2.0);
    e(EngineEvent::LoadFinished { attempt: 2 });
    e(EngineEvent::State(EngineState::Playing));
    e(EngineEvent::FirstFrame);
    e(EngineEvent::Clock {
        position: 1.0,
        source_time: 1.0,
    });
    r.vm.tick(t + 2.5);
    assert_ne!(r.vm.transport().phase, Phase::Ended);
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Playing);
    let kinds = r.reports.kinds();
    let count = |k: ReportKind| kinds.iter().filter(|x| **x == k).count();
    assert_eq!(
        count(ReportKind::Stop),
        1,
        "the switch's stop went out once"
    );
    assert_eq!(
        count(ReportKind::Start),
        2,
        "the replay reports a new start"
    );
}

#[test]
fn a_timeline_seek_after_a_failed_plan_from_an_ended_title_loads_it_again() {
    let (r, t) = ended_after_a_failed_plan();
    r.vm.send(PlayerIntent::SeekTo(1800.0), t + 1.0);
    assert_eq!(loads(&r), 2, "the seek reopens the title at the target");
    assert!(
        r.engine.has("load Some(1800.0)"),
        "at the target: {:?}",
        r.engine.calls()
    );
}

#[test]
fn a_failed_plan_that_arrives_after_the_player_was_closed_does_nothing() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 600.0, 3600.0);
    r.run(101.0, 103.0, 600.0);
    r.vm.send(PlayerIntent::NextEpisode, 103.0);
    assert!(
        r.vm.take_effects()
            .iter()
            .any(|e| matches!(e, PlayerEffect::StartEpisode { .. })),
        "the plan is asked for"
    );
    // The user closes the player while the plan is fetched.
    r.vm.send(PlayerIntent::Close, 103.5);
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Closed);
    let stops = |r: &Rig| {
        r.reports
            .kinds()
            .iter()
            .filter(|k| **k == ReportKind::Stop)
            .count()
    };
    assert_eq!(stops(&r), 1, "the switch already sent the one stop");
    assert!(r.engine.has("stop false"));
    let before = r.engine.calls();
    let effects = r.vm.take_effects();
    assert!(
        effects.iter().any(|e| matches!(e, PlayerEffect::Close)),
        "{effects:?}"
    );

    // The plan call then fails: nothing comes back to life.
    r.vm.switch_failed(104.0);
    assert_eq!(r.engine.calls(), before, "no load, no second stop");
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Closed);
    assert_eq!(r.vm.transport().hint, None, "no line over a closed player");
    assert_eq!(stops(&r), 1);
    assert!(
        !r.reports.kinds().contains(&ReportKind::Start)
            || r.reports
                .kinds()
                .iter()
                .filter(|k| **k == ReportKind::Start)
                .count()
                == 1,
        "no new start report for the old title"
    );
    r.vm.tick(105.0);
    assert_eq!(r.engine.calls(), before);
}

#[test]
fn a_plan_that_arrives_after_the_player_was_closed_does_not_reopen_it() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 600.0, 3600.0);
    r.run(101.0, 103.0, 600.0);
    r.vm.send(PlayerIntent::NextEpisode, 103.0);
    let spec = r.vm.spec();
    r.vm.send(PlayerIntent::Close, 103.5);
    let before = r.engine.calls();
    r.vm.load_title(spec, 104.0);
    assert_eq!(r.engine.calls(), before, "a closed player loads nothing");
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Closed);
}

#[test]
fn replay_of_an_ended_film_leaves_the_ended_phase_once_its_picture_is_back() {
    let r = rig();
    r.picture(101.0, 3590.0, 3600.0);
    r.run(101.0, 105.0, 3590.0);
    r.vm.engine_event(EngineEvent::State(EngineState::Ended), 106.0);
    r.run(106.0, 110.0, 3600.0);
    assert_eq!(r.vm.transport().phase, Phase::Ended);
    r.vm.send(PlayerIntent::TogglePlay, 111.0);
    assert_eq!(loads(&r), 2, "replay opens the film again");
    let e = |ev| r.vm.engine_event(ev, 112.0);
    e(EngineEvent::LoadFinished { attempt: 2 });
    e(EngineEvent::State(EngineState::Playing));
    e(EngineEvent::FirstFrame);
    e(EngineEvent::Clock {
        position: 1.0,
        source_time: 1.0,
    });
    r.vm.tick(112.5);
    assert_ne!(r.vm.transport().phase, Phase::Ended);
    assert_eq!(r.vm.stage(), swiftly_vm::PlayerStage::Playing);
}

#[test]
fn every_hint_goes_after_the_same_time_on_the_player_clock() {
    use swiftly_vm::HINT_SECONDS;
    // A failed plan: the line stays for HINT_SECONDS, whatever the clock does in between, then it goes.
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 600.0, 3600.0);
    r.run(101.0, 103.0, 600.0);
    r.vm.send(PlayerIntent::TogglePlay, 103.0);
    r.vm.send(PlayerIntent::NextEpisode, 104.0);
    let mut host = FailingHost::default();
    host.serve(&r, 104.0);
    assert_eq!(r.vm.transport().hint.as_deref(), Some(SWITCH_FAILED_HINT));
    r.vm.tick(104.0 + HINT_SECONDS - 0.5);
    assert_eq!(
        r.vm.transport().hint.as_deref(),
        Some(SWITCH_FAILED_HINT),
        "still there just before its time"
    );
    r.vm.tick(104.0 + HINT_SECONDS);
    assert_eq!(r.vm.transport().hint, None, "gone at its time");

    // The sleep timer's line goes the same way.
    let r = rig();
    r.picture(101.0, 0.0, 3600.0);
    r.vm.send(PlayerIntent::Sleep(Some(1)), 101.0);
    r.vm.tick(162.0);
    assert_eq!(
        r.vm.transport().hint.as_deref(),
        Some("Schlafzeit abgelaufen.")
    );
    r.vm.tick(162.0 + HINT_SECONDS - 0.5);
    assert!(r.vm.transport().hint.is_some());
    r.vm.tick(162.0 + HINT_SECONDS);
    assert_eq!(r.vm.transport().hint, None);

    // The original-quality line (set when the new plan arrives) goes the same way.
    let prefs = PlayerPrefs {
        direct_play: false,
        bitrate_limit: 8,
        ..PlayerPrefs::default()
    };
    let r = rig_with(0.0, false, prefs);
    r.vm.after_quality_switch();
    assert_eq!(
        r.vm.transport().hint.as_deref(),
        Some(ORIGINAL_QUALITY_HINT)
    );
    r.picture(101.0, 0.0, 3600.0);
    r.vm.tick(100.0 + HINT_SECONDS + 0.5);
    assert_eq!(r.vm.transport().hint, None, "no hint stays for good");
}

// MARK: The end of an episode that no outro reaches the end of the file of (17.11.).

/// Runs 500 ms ticks from `from` (clock at `position`) until the file's end, where the engine reports the end, and on
/// for `after` seconds. Returns the time reached.
fn play_to_the_end(r: &Rig, from: f64, position: f64, duration: f64, after: f64) -> f64 {
    let (mut t, mut p, mut ended) = (from, position, false);
    let stop = from + (duration - position) + after;
    while t < stop - 1e-9 {
        t += 0.5;
        p = (p + 0.5).min(duration);
        if p >= duration && !ended {
            r.vm.engine_event(EngineEvent::State(EngineState::Ended), t);
            ended = true;
        }
        r.vm.engine_event(
            EngineEvent::Clock {
                position: p,
                source_time: p,
            },
            t,
        );
        r.vm.display_tick(t - 0.25);
        r.vm.tick(t);
    }
    t
}

fn episodes_started(r: &Rig) -> usize {
    r.vm.take_effects()
        .iter()
        .filter(|e| matches!(e, PlayerEffect::StartEpisode { .. }))
        .count()
}

fn is_card(r: &Rig) -> bool {
    matches!(r.vm.offer().view, OfferView::Card { .. })
}

#[test]
fn a_short_episode_without_markers_shows_the_card_in_its_last_seconds_and_then_starts_the_next() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 100.0, 120.0);
    let t = r.run(101.0, 109.0, 100.0);
    assert!(!is_card(&r), "the card came 11 s before the end");
    // 113 s of 120: the last seven seconds.
    let t = r.run(t, t + 5.0, 108.0);
    assert!(is_card(&r), "no card in the last seconds");
    assert_eq!(episodes_started(&r), 0, "the fill has not run out");
    play_to_the_end(&r, t, 113.0, 120.0, 6.0);
    assert_eq!(
        episodes_started(&r),
        1,
        "the next episode starts once, at the end"
    );
}

#[test]
fn a_long_episode_without_any_marker_shows_the_short_card_and_not_the_thirty_second_one() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 1450.0, 1500.0);
    // From 1470 s on (30 s left) the old card showed: nothing shows there any more.
    let t = r.run(101.0, 126.0, 1450.0);
    assert!(!is_card(&r), "the old thirty second card came back");
    let t = r.run(t, t + 19.0, 1475.0);
    assert!(is_card(&r), "no card in the last seven seconds");
    assert_eq!(episodes_started(&r), 0, "the fill has not run out");
    play_to_the_end(&r, t, 1494.0, 1500.0, 6.0);
    assert_eq!(episodes_started(&r), 1, "the next episode starts once");
}

#[test]
fn an_outro_that_ends_early_shows_the_card_in_the_last_seconds_and_then_starts_the_next() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.vm.set_sections(vec![Segment::new(Art::Credits, 1300.0, 1440.0)]);
    r.picture(101.0, 1480.0, 1500.0);
    let t = r.run(101.0, 111.0, 1480.0);
    assert!(!is_card(&r), "the card came 10 s before the end");
    let t = r.run(t, t + 4.0, 1490.0);
    assert!(is_card(&r), "no card in the last seconds");
    assert_eq!(episodes_started(&r), 0);
    play_to_the_end(&r, t, 1494.0, 1500.0, 6.0);
    assert_eq!(episodes_started(&r), 1);
}

#[test]
fn cancelling_the_closing_card_keeps_the_player_on_the_last_frame() {
    let r = rig_with(0.0, true, PlayerPrefs::default());
    r.picture(101.0, 100.0, 120.0);
    let t = r.run(101.0, 119.0, 100.0);
    assert!(is_card(&r));
    r.vm.send(PlayerIntent::Back2, t);
    assert_eq!(r.vm.offer().view, OfferView::Hidden);
    play_to_the_end(&r, t, 118.0, 120.0, 30.0);
    assert_eq!(episodes_started(&r), 0, "a cancelled card still advanced");
}

#[test]
fn autoplay_off_gives_no_closing_card_and_no_advance() {
    let prefs = PlayerPrefs {
        next_automatic: false,
        auto_skip: false,
        ..PlayerPrefs::default()
    };
    let r = rig_with(0.0, true, prefs);
    r.picture(101.0, 100.0, 120.0);
    let t = r.run(101.0, 115.0, 100.0);
    assert!(!is_card(&r));
    play_to_the_end(&r, t, 114.0, 120.0, 30.0);
    assert_eq!(episodes_started(&r), 0);
}

#[test]
fn a_movie_or_the_last_episode_gets_no_closing_card() {
    let r = rig_with(0.0, false, PlayerPrefs::default());
    r.picture(101.0, 100.0, 120.0);
    let t = r.run(101.0, 115.0, 100.0);
    assert!(!is_card(&r));
    play_to_the_end(&r, t, 114.0, 120.0, 30.0);
    assert_eq!(episodes_started(&r), 0);
}

// MARK: Chapter list

fn chapter_list() -> Vec<swiftly_rules::chapter::Chapter> {
    use swiftly_rules::chapter::Chapter;
    vec![
        Chapter::new("Anfang", 0.0),
        Chapter::new("Die Reise", 600.0),
        Chapter::new("", 1500.0),
        Chapter::new("Finale", 2700.0),
    ]
}

#[test]
fn the_chapter_list_has_one_row_per_chapter_with_the_running_one_marked() {
    let r = rig();
    r.picture(101.0, 1600.0, 3600.0);
    r.vm.tick(101.5);
    assert!(r.vm.chapters().rows.is_empty(), "no chapters, no rows");
    r.vm.set_chapters(chapter_list());
    let part = r.vm.chapters();
    assert_eq!((part.title, part.number_title), ("Kapitel", "Kapitel %lld"));
    let shown: Vec<(usize, Option<&str>, i64, f64, bool)> = part
        .rows
        .iter()
        .map(|c| (c.index, c.name.as_deref(), c.number, c.start, c.current))
        .collect();
    assert_eq!(
        shown,
        vec![
            (0, Some("Anfang"), 1, 0.0, false),
            (1, Some("Die Reise"), 2, 600.0, false),
            // A chapter the file does not name: the host writes "Kapitel 3" from the number.
            (2, None, 3, 1500.0, true),
            (3, Some("Finale"), 4, 2700.0, false),
        ]
    );
    assert!(
        part.rows.iter().all(|c| c.preview.is_none()),
        "no trickplay, no picture"
    );
}

#[test]
fn a_chapter_row_carries_the_trickplay_tile_of_its_start() {
    use swiftly_playback::trickplay::Trickplay;
    let r = rig();
    r.picture(101.0, 10.0, 3600.0);
    r.vm.set_chapters(chapter_list());
    let tp = Trickplay {
        width: 320,
        height: 180,
        tiles_wide: 10,
        tiles_up: 10,
        count: 360,
        interval: 10_000,
    };
    r.vm.set_trickplay(Some(tp));
    let rows = r.vm.chapters().rows;
    assert_eq!(rows[1].preview, tp.tile(600.0));
    assert_eq!(
        rows[1].preview.map(|t| (t.sheet, t.x, t.y)),
        Some((0, 0, 180 * 6))
    );
}

#[test]
fn choosing_a_chapter_seeks_to_its_start_and_closes_the_panel() {
    let r = rig();
    r.picture(101.0, 50.0, 3600.0);
    r.vm.set_chapters(chapter_list());
    r.vm.send(PlayerIntent::Layer(Some(PlayerLayer::Chapters)), 102.0);
    assert_eq!(r.vm.controls().layer, Some(PlayerLayer::Chapters));
    r.vm.send(PlayerIntent::JumpToChapter(2), 103.0);
    assert!(
        r.engine.has("seek 1500"),
        "the engine was told to seek to the start of chapter 3: {:?}",
        r.engine.calls()
    );
    assert_eq!(r.vm.transport().position, 1500.0);
    assert_eq!(r.vm.controls().layer, None, "the choice closes the panel");
    // The clock reaches the start: the running chapter is the chosen one.
    r.vm.engine_event(
        EngineEvent::Clock {
            position: 1500.0,
            source_time: 1500.0,
        },
        103.5,
    );
    let rows = r.vm.chapters().rows;
    assert!(rows[2].current && rows.iter().filter(|c| c.current).count() == 1);
}

#[test]
fn a_chapter_index_past_the_list_does_nothing() {
    let r = rig();
    r.picture(101.0, 50.0, 3600.0);
    r.vm.set_chapters(chapter_list());
    r.vm.send(PlayerIntent::Layer(Some(PlayerLayer::Chapters)), 102.0);
    let before = r.engine.calls().len();
    r.vm.send(PlayerIntent::JumpToChapter(9), 103.0);
    assert_eq!(r.engine.calls().len(), before);
    assert_eq!(r.vm.controls().layer, Some(PlayerLayer::Chapters));
}

/// The top bar is up from the first frame, under the start veil; the centre and the timeline wait for the picture.
#[test]
fn top_bar_is_up_while_loading_and_the_middle_waits() {
    let r = rig();
    let (t, c) = (r.vm.transport(), r.vm.controls());
    assert_eq!(t.phase, Phase::Loading);
    assert!(t.veil_up(), "veil while loading");
    assert!(c.top_bar_up(), "top bar from the first frame");
    assert!(!c.middle_up(&t), "middle waits for the picture");
    r.picture(101.0, 0.4, 3600.0);
    r.vm.display_tick(101.25);
    r.vm.tick(101.5);
    let (t, c) = (r.vm.transport(), r.vm.controls());
    assert!(!t.veil_up());
    assert!(c.top_bar_up(), "the bar does not change when loading ends");
    assert!(c.middle_up(&t));
}

/// A slow stream: the idle timer does not hide the bar under the start veil, and it starts counting at the picture.
#[test]
fn bar_stays_through_a_slow_load_then_hides_after_the_picture() {
    let r = rig();
    for step in 1..=20 {
        let now = 100.0 + step as f64; // 20 s of loading, far past the idle time
        r.vm.tick(now);
        assert!(
            r.vm.controls().visible,
            "still up while loading at +{step} s"
        );
    }
    r.picture(121.0, 0.4, 3600.0);
    r.vm.display_tick(121.25);
    r.vm.tick(121.5);
    assert!(
        r.vm.controls().visible,
        "not hidden the moment the picture arrives"
    );
    r.run(121.5, 127.0, 0.9);
    assert!(
        !r.vm.controls().visible,
        "hidden by the idle timer after the picture"
    );
}
