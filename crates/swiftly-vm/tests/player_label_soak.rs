//! A long film: 100 000 clock events, ticks and panel reads must not ask the host for language names again and again.
//!
//! This is a cost guard, not the cause of the crash of the iPhone build 1.1.0 (48). That crash was a stack overflow
//! on the main thread after about half an hour of playback, and its cause was the receiver closure kept in a
//! `Mutex<closure?>` inside `PlayerEngineDriver`, which grew the call chain by two frames per engine event (guarded
//! by `PlayerEngineDriverTests.theStackDoesNotGrowWithEveryEngineEvent` and `PlayerClockSoakTests`). Separately, the
//! track panel was rebuilt after every clock event and every rebuild asked the host (a Swift callback,
//! `Locale.localizedString`) for the name of every track's language: 250 to 1000 host calls per event. The names are
//! now kept per code and interface language, so the host is asked once per language.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_l10n::Locale;
use swiftly_model::MediaStream;
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
};
use swiftly_playback::player_state::EngineRequest;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{
    LabelWords, NameSource, PlayerPrefs, PlayerSpec, PlayerVm, ReportMessage, Reporter, host_calls,
    set_name_source,
};

#[derive(Default)]
struct Quiet;

impl PlaybackEngine for Quiet {
    fn load(&self, _: EngineLoad) {}
    fn play(&self) {}
    fn pause(&self) {}
    fn seek(&self, _: f64) {}
    fn set_rate(&self, _: f32) {}
    fn set_volume(&self, _: u8) {}
    fn set_audio_delay(&self, _: i32) {}
    fn set_subtitle_delay(&self, _: i32) {}
    fn select_audio(&self, _: i32) -> bool {
        true
    }
    fn select_subtitle(&self, _: i32) -> SubtitleRoute {
        SubtitleRoute::Cues
    }
    fn set_fill(&self, _: bool) {}
    fn place(&self, _: Rect) {}
    fn stop(&self, _: bool) {}
    fn pip(&self, _: PipCmd) {}
    fn set_audio_output(&self, _: &swiftly_playback::decoder_choice::AudioOutputMode) {}
}

#[derive(Default)]
struct Reports(Mutex<usize>);

impl Reporter for Reports {
    fn report(&self, _: ReportMessage) {
        *self.0.lock().unwrap() += 1;
    }
}

/// The host's names, counting the questions like the Swift callback that reaches `Locale`.
struct Counting(AtomicUsize);

impl NameSource for Counting {
    fn name(&self, code: &str, language: &str) -> Option<String> {
        self.0.fetch_add(1, Ordering::Relaxed);
        Some(format!("{code} in {language}"))
    }
    fn knows(&self, _: &str) -> bool {
        self.0.fetch_add(1, Ordering::Relaxed);
        true
    }
}

const LANGUAGES: [&str; 15] = [
    "deu", "eng", "fra", "spa", "ita", "por", "rus", "jpn", "kor", "zho", "nld", "pol", "tur",
    "swe", "dan",
];

fn film(subtitles: usize) -> PlayerSpec {
    let mut streams = vec![
        stream(1, "Audio", "eng", "ac3"),
        stream(2, "Audio", "deu", "eac3"),
    ];
    for i in 0..subtitles {
        let mut s = stream(
            10 + i as i64,
            "Subtitle",
            LANGUAGES[i % LANGUAGES.len()],
            "subrip",
        );
        s.is_forced = Some(i % 7 == 0);
        streams.push(s);
    }
    PlayerSpec {
        item_id: "film".into(),
        title: "Film".into(),
        plan: ReportPlan {
            play_session_id: Some("s1".into()),
            media_source_id: Some("m1".into()),
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: "film".into(),
            streams,
            runtime: 7200.0,
            subtitle_files: Vec::new(),
            url: "https://tv.example.test/v".into(),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: 0.0,
        audio_index: Some(1),
        subtitle_index: -1,
        next: None,
        series_id: None,
        track_title: None,
        downloaded: false,
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

#[test]
fn a_long_film_asks_the_host_for_each_language_once() {
    let names = Arc::new(Counting(AtomicUsize::new(0)));
    set_name_source(Some(names.clone()));
    let vm = PlayerVm::new(
        Arc::new(Quiet),
        Arc::new(Reports::default()),
        Arc::new(LabelWords::new(Locale::parse("de"))),
        PlayerPrefs::default(),
        film(40),
        100.0,
    );
    vm.start(100.0);
    vm.engine_event(EngineEvent::LoadFinished { attempt: 1 }, 100.0);
    vm.engine_event(EngineEvent::Duration(7200.0), 100.0);
    vm.engine_event(EngineEvent::State(EngineState::Playing), 100.0);
    vm.engine_event(EngineEvent::FirstFrame, 100.0);
    let first = vm.tracks();
    assert_eq!(first.subtitles.len(), 40);
    let after_first_look = names.0.load(Ordering::Relaxed);
    assert!(
        after_first_look <= 2 * LANGUAGES.len() + 2,
        "the first look asked {after_first_look} times for {} languages",
        LANGUAGES.len()
    );

    let mut now = 100.0;
    let mut position = 0.0;
    for i in 0..100_000u32 {
        now += 0.1;
        position += 0.1;
        vm.engine_event(
            EngineEvent::Clock {
                position,
                source_time: position,
            },
            now,
        );
        if i % 5 == 0 {
            vm.display_tick(now);
        }
        if i % 5 == 3 {
            vm.tick(now);
            // The screen reads all four parts after a change.
            let _ = (vm.transport(), vm.controls(), vm.tracks(), vm.offer());
        }
    }
    let asked = names.0.load(Ordering::Relaxed) - after_first_look;
    assert_eq!(
        asked, 0,
        "100 000 clock events asked the host {asked} more times"
    );
    assert_eq!(
        vm.tracks().subtitles.len(),
        40,
        "the track list stays as it is"
    );
    assert!(host_calls() <= 2 * LANGUAGES.len() + 2);
    set_name_source(None);
}
