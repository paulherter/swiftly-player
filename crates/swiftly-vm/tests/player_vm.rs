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
    Reporter, SMALL_WINDOW_TEXT, StreamReading, TrackMemoryStore,
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
            since: 0.0
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
