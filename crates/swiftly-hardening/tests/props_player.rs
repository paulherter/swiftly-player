//! Random event/intent sequences for the engine-neutral `PlayerState`, with a small host model
//! that answers loads, seeks and the start watchdog (late, out of order, or not at all).
//! A failure prints the seed; replay with `HARDENING_SEED=<n>`.
//!
//! (`PlayerVm` is not a thin wrapper around this state: it adds reporting, sessions and timers,
//! so it keeps its own tests.)

mod common;

use swiftly_hardening::Rng;
use swiftly_model::MediaStream;
use swiftly_playback::engine::{
    AudioDelivery, Cue, CueBody, EngineEvent, EngineState, EngineTrack, PipCmd, Rect, Route,
};
use swiftly_playback::player_state::{Command, EngineRequest, Intent, PlayerState};
use swiftly_playback::track_mapping::SubtitleFile;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::delay::Delay;

fn stream(index: i64, ty: &str, external: bool) -> MediaStream {
    MediaStream {
        index: Some(index),
        type_: Some(ty.into()),
        language: Some("deu".into()),
        codec: Some("x".into()),
        is_external: Some(external),
        ..MediaStream::default()
    }
}

fn track(id: i64) -> EngineTrack {
    EngineTrack {
        id,
        codec: "x".into(),
        language: None,
        name: format!("t{id}"),
        channels: 2,
        is_default: id % 2 == 0,
        is_forced: false,
    }
}

fn request(rng: &mut Rng) -> (EngineRequest, Option<i64>, i64) {
    let device_file = rng.chance(15);
    let streams = if device_file {
        Vec::new()
    } else {
        vec![
            stream(1, "Audio", false),
            stream(2, "Audio", false),
            stream(3, "Audio", false),
            stream(4, "Subtitle", false),
            stream(5, "Subtitle", false),
            stream(6, "Subtitle", true),
        ]
    };
    let files = if device_file {
        Vec::new()
    } else {
        vec![SubtitleFile {
            index: 6,
            address: "https://s/sub/6".into(),
            attribute: None,
        }]
    };
    let req = EngineRequest {
        item_id: if device_file {
            String::new()
        } else {
            "item".into()
        },
        streams,
        runtime: if rng.chance(70) { 100.0 } else { 0.0 },
        subtitle_files: files,
        url: "https://s/v".into(),
        headers: Vec::new(),
        software_decode: false,
        buffer_level: BufferLevel::Normal,
        frame_rate_match: false,
        external_track_id_base: 1000,
    };
    let audio = [None, Some(1), Some(2), Some(9)][rng.below(4) as usize];
    let sub = [-1, 4, 5, 6, 8][rng.below(5) as usize];
    (req, audio, sub)
}

struct Host {
    s: PlayerState,
    rng: Rng,
    attempt: u32,
    /// Answers the host still owes: (event).
    pending: Vec<EngineEvent>,
    stopped: bool,
    running_seen: bool,
    failed_this_attempt: u32,
    cancel_this_attempt: u32,
    /// Bumped by everything that lets a track choice be applied again.
    audio_cmds: u32,
    sub_cmds: u32,
    log: Vec<String>,
}

impl Host {
    fn ctx(&self, step: usize) -> String {
        let tail: Vec<&String> = self.log.iter().rev().take(6).collect();
        format!("step {step}; last (newest first): {tail:?}")
    }

    fn readouts(&self, ctx: &str) {
        let s = &self.s;
        let p = s.position();
        assert!(p.is_finite() && p >= 0.0, "{ctx}: position {p}");
        let g = s.last_good();
        assert!(g.is_finite() && g >= 0.0, "{ctx}: last_good {g}");
        let d = s.duration_seconds();
        assert!(d.is_finite() && d >= 0.0, "{ctx}: duration {d}");
        assert_eq!(
            s.is_playing(),
            self.running_seen,
            "{ctx}: is_playing against the Running commands"
        );
        let cues = s.active_cues();
        if s.subtitle_index() < 0 {
            assert!(
                cues.text.is_none() && cues.images.is_empty(),
                "{ctx}: cues while subtitles are off"
            );
        }
    }

    /// Everything a batch of commands must obey, whatever caused it.
    fn absorb(&mut self, cmds: &[Command], ctx: &str) {
        let mut arm_seen = false;
        for c in cmds {
            match c {
                Command::ArmStartWatchdog { attempt, seconds } => {
                    assert!(!self.stopped, "{ctx}: arm after stop");
                    assert_eq!(
                        *attempt,
                        self.attempt + 1,
                        "{ctx}: attempt numbers must count up by one"
                    );
                    assert_eq!(*seconds, 30.0, "{ctx}: watchdog seconds");
                    self.attempt = *attempt;
                    self.failed_this_attempt = 0;
                    self.cancel_this_attempt = 0;
                    self.audio_cmds = 0;
                    self.sub_cmds = 0;
                    arm_seen = true;
                    // The old attempt's answers stay in the queue: they must be ignored later.
                    self.pending
                        .push(EngineEvent::StartWatchdog { attempt: *attempt });
                }
                Command::Load(_) => {
                    assert!(arm_seen, "{ctx}: Load without the Arm before it");
                    assert!(!self.stopped, "{ctx}: load after stop");
                    arm_seen = false;
                    let a = self.attempt;
                    if self.rng.chance(85) {
                        self.pending.push(EngineEvent::LoadFinished { attempt: a });
                    } else {
                        self.pending.push(EngineEvent::LoadFailed {
                            attempt: a,
                            message: "boom".into(),
                            kind: self.rng.chance(50).then(|| "k".to_string()),
                        });
                    }
                }
                Command::Seek(t) => {
                    assert!(t.is_finite() && *t >= 0.0, "{ctx}: seek to {t}");
                    self.pending.push(EngineEvent::SeekLanded { target: *t });
                }
                Command::CancelStartWatchdog => {
                    self.cancel_this_attempt += 1;
                    assert!(
                        self.cancel_this_attempt <= 1,
                        "{ctx}: the watchdog was cancelled twice in one attempt"
                    );
                    let a = self.attempt;
                    self.pending.retain(
                        |e| !matches!(e, EngineEvent::StartWatchdog { attempt } if *attempt == a),
                    );
                }
                Command::Failed(_) => {
                    self.failed_this_attempt += 1;
                    assert!(
                        self.failed_this_attempt <= 1,
                        "{ctx}: two failures reported in one attempt"
                    );
                    assert!(!self.stopped, "{ctx}: failure after stop");
                }
                Command::Running(r) => {
                    assert_ne!(*r, self.running_seen, "{ctx}: Running({r}) repeated");
                    assert!(!self.stopped, "{ctx}: Running after stop");
                    self.running_seen = *r;
                }
                Command::SelectAudio(_) => self.audio_cmds += 1,
                // A hand-over is not latched as applied (72815f37): a late engine list may still select the track after it.
                Command::SelectSubtitle(_) | Command::ClearSubtitle => self.sub_cmds += 1,
                Command::SetVolume(v) => assert!(*v <= 100, "{ctx}: volume {v}"),
                _ => {}
            }
        }
        assert!(!arm_seen, "{ctx}: Arm without a Load after it");
        assert!(
            self.audio_cmds <= 1,
            "{ctx}: the same audio choice was applied {} times",
            self.audio_cmds
        );
        assert!(
            self.sub_cmds <= 1,
            "{ctx}: the same subtitle choice was applied {} times",
            self.sub_cmds
        );
    }

    fn apply(&mut self, ev: EngineEvent, step: usize) {
        let ctx = self.ctx(step);
        self.log.push(format!("event {ev:?}"));
        let before = format!("{:?}", self.s);
        let was_stopped = self.stopped;
        let shown = self.s.picture_shown();
        let stale_attempt = match &ev {
            EngineEvent::LoadFinished { attempt }
            | EngineEvent::LoadFailed { attempt, .. }
            | EngineEvent::StartWatchdog { attempt } => *attempt != self.attempt,
            _ => false,
        };
        let watchdog_now =
            matches!(&ev, EngineEvent::StartWatchdog { attempt } if *attempt == self.attempt);
        let near_end =
            self.s.duration_seconds() > 0.0 && self.s.position() > self.s.duration_seconds() - 3.0;
        let failed_before = self.failed_this_attempt;
        let settled_before = self.s.start_settled();
        let pos_before = self.s.position();
        let dur_before = self.s.duration_seconds();
        let cmds = self.s.apply(ev.clone());
        self.absorb(&cmds, &ctx);
        if was_stopped {
            assert!(
                cmds.is_empty(),
                "{ctx}: a stopped player answered an event with {cmds:?}"
            );
        }
        if stale_attempt {
            assert!(cmds.is_empty(), "{ctx}: a stale answer produced {cmds:?}");
            assert_eq!(
                before,
                format!("{:?}", self.s),
                "{ctx}: a stale answer changed the state"
            );
        }
        if matches!(ev, EngineEvent::FirstFrame) && shown {
            assert!(
                cmds.is_empty(),
                "{ctx}: a second first picture produced {cmds:?}"
            );
        }
        if watchdog_now && !was_stopped {
            if shown {
                assert!(
                    cmds.is_empty(),
                    "{ctx}: the watchdog failed a start that has its picture"
                );
            } else if failed_before == 0 && !near_end {
                assert!(
                    cmds.iter().any(|c| matches!(c, Command::Failed(_))),
                    "{ctx}: no picture within 30 s was not reported"
                );
            }
        }
        if let EngineEvent::SeekLanded { target } = ev
            && !was_stopped
            && !settled_before
            && pos_before == target
            && pos_before != dur_before
        {
            assert!(
                self.s.start_settled(),
                "{ctx}: the seek to {target} landed but the start is unsettled"
            );
        }
        self.readouts(&ctx);
    }

    fn intent(&mut self, intent: Intent, step: usize) {
        let ctx = self.ctx(step);
        self.log.push(format!("intent {intent:?}"));
        let before = format!("{:?}", self.s);
        let was_stopped = self.stopped;
        let attempt_before = self.attempt;
        let epoch_reset = matches!(intent, Intent::SwitchAudio(_) | Intent::SelectSubtitle(_));
        if epoch_reset {
            self.audio_cmds = 0;
            self.sub_cmds = 0;
        }
        let cmds = self.s.intent(intent.clone());
        self.absorb(&cmds, &ctx);
        let loaded = self.attempt != attempt_before;
        match &intent {
            Intent::Stop { reset_display } => {
                assert_eq!(
                    cmds,
                    vec![Command::Stop {
                        reset_display: *reset_display
                    }],
                    "{ctx}: stop"
                );
                self.stopped = true;
            }
            Intent::Start(_) if was_stopped => {
                assert!(cmds.is_empty(), "{ctx}: a stopped player started")
            }
            Intent::Start(_) if !was_stopped => {
                assert!(
                    loaded && matches!(cmds.last(), Some(Command::Load(_))),
                    "{ctx}: Start did not load"
                );
            }
            Intent::Seek(t) if !was_stopped => {
                if loaded {
                    assert!(
                        matches!(cmds.last(), Some(Command::Load(_))),
                        "{ctx}: Seek after the end must load"
                    );
                } else {
                    let want = t.max(0.0);
                    assert_eq!(cmds, vec![Command::Seek(want)], "{ctx}: seek");
                    assert!(
                        !self.s.start_settled(),
                        "{ctx}: a seek under way counts as settled"
                    );
                    assert_eq!(
                        self.s.position(),
                        want,
                        "{ctx}: the seek target is shown until it lands"
                    );
                    assert_eq!(self.s.last_good(), want, "{ctx}: last_good after a seek");
                }
            }
            Intent::Resume if !was_stopped => {
                assert!(
                    (loaded && matches!(cmds.last(), Some(Command::Load(_))))
                        || cmds == vec![Command::Play],
                    "{ctx}: resume gave {cmds:?}"
                );
            }
            Intent::Pause => assert_eq!(cmds, vec![Command::Pause], "{ctx}: pause"),
            Intent::SetTempo(t) => assert_eq!(self.s.tempo(), *t, "{ctx}: tempo"),
            Intent::SetVolume(v) => assert_eq!(
                cmds,
                vec![Command::SetVolume((*v).clamp(0, 100) as u8)],
                "{ctx}: volume"
            ),
            Intent::SetFill(on) => assert_eq!(cmds, vec![Command::SetFill(*on)], "{ctx}: fill"),
            Intent::SwitchAudio(i) => {
                assert_eq!(self.s.audio_index(), Some(*i), "{ctx}: audio index");
                // Choosing the same track again changes nothing.
                let again = self.s.intent(Intent::SwitchAudio(*i));
                assert!(
                    again.is_empty(),
                    "{ctx}: the same audio switch twice gave {again:?}"
                );
            }
            Intent::SelectSubtitle(i) => {
                if *i < 0 {
                    assert_eq!(self.s.subtitle_index(), -1, "{ctx}: subtitles off");
                } else if self.s.subtitle_index() != *i {
                    // Unknown track: nothing changed at all.
                    assert!(cmds.is_empty(), "{ctx}: unknown subtitle produced {cmds:?}");
                    assert_eq!(
                        before,
                        format!("{:?}", self.s),
                        "{ctx}: unknown subtitle changed the state"
                    );
                }
            }
            Intent::SetSubtitleDelay(d) => {
                let again = self.s.intent(Intent::SetSubtitleDelay(*d));
                assert!(
                    again.is_empty(),
                    "{ctx}: subtitle delay twice gave {again:?}"
                );
            }
            Intent::SetAudioDelay(d) => {
                let again = self.s.intent(Intent::SetAudioDelay(*d));
                assert!(again.is_empty(), "{ctx}: audio delay twice gave {again:?}");
            }
            _ => {}
        }
        if loaded {
            // A new load starts the choices over.
            assert!(
                !self.s.picture_shown(),
                "{ctx}: picture_shown survived a new load"
            );
        }
        self.readouts(&ctx);
    }

    fn random_event(&mut self) -> EngineEvent {
        let r = &mut self.rng;
        let attempt = |r: &mut Rng, cur: u32| match r.below(4) {
            0 => cur.saturating_sub(1),
            1 => cur + 1,
            _ => cur,
        };
        let cur = self.attempt;
        match r.below(20) {
            0 => EngineEvent::State(EngineState::Playing),
            1 => EngineEvent::State(EngineState::Paused),
            2 => EngineEvent::State(EngineState::Ended),
            3 => EngineEvent::State(EngineState::Error {
                message: "e".into(),
                kind: r.chance(50).then(|| "k".into()),
            }),
            4 => EngineEvent::State(
                [
                    EngineState::Idle,
                    EngineState::Loading,
                    EngineState::Seeking,
                ][r.below(3) as usize]
                    .clone(),
            ),
            5 => EngineEvent::FirstFrame,
            6 | 7 => {
                let p = [
                    0.0,
                    5.0,
                    50.0,
                    99.0,
                    99.9,
                    100.0,
                    -3.0,
                    f64::NAN,
                    f64::INFINITY,
                ][r.below(9) as usize];
                let p = if r.chance(50) { r.unit() * 100.0 } else { p };
                EngineEvent::Clock {
                    position: p,
                    source_time: r.unit() * 100.0,
                }
            }
            8 => EngineEvent::Duration(
                [0.0, 100.0, 60.0, -1.0, f64::NAN, 1.0e9][r.below(6) as usize],
            ),
            9 => EngineEvent::VideoSize {
                width: 1920.0,
                height: 1080.0,
            },
            10 | 11 => {
                let ids = [1, 2, 3, 4, 5, 6, 1000, 1001];
                let audio = ids[..3]
                    .iter()
                    .filter(|_| r.chance(70))
                    .map(|i| track(*i))
                    .collect();
                let subtitles = ids[3..]
                    .iter()
                    .filter(|_| r.chance(60))
                    .map(|i| track(*i))
                    .collect();
                let pick = |r: &mut Rng| r.chance(50).then(|| ids[r.below(8) as usize]);
                EngineEvent::Tracks {
                    audio,
                    subtitles,
                    active_audio: pick(r),
                    active_subtitle: pick(r),
                }
            }
            12 => {
                let n = r.below(4);
                EngineEvent::Cues(
                    (0..n)
                        .map(|i| {
                            let start = r.unit() * 90.0;
                            Cue {
                                id: i as i64,
                                start,
                                end: start + 1.0 + r.unit() * 5.0,
                                body: match r.below(3) {
                                    0 => CueBody::Text("line\\Nnext".into()),
                                    1 => CueBody::Rich(vec!["a".into(), "b".into()]),
                                    _ => CueBody::Image {
                                        position: Rect::default(),
                                        canvas: (1.0, 1.0),
                                    },
                                },
                            }
                        })
                        .collect(),
                )
            }
            13 => EngineEvent::AudioDelivery(if r.chance(30) {
                AudioDelivery::DroppedNoPipeline
            } else {
                AudioDelivery::Ok
            }),
            14 => {
                EngineEvent::Route([Route::AirPlay, Route::Cast, Route::Local][r.below(3) as usize])
            }
            15 => EngineEvent::PipPossible(r.chance(50)),
            16 => EngineEvent::PipActive(r.chance(50)),
            17 => EngineEvent::LoadFinished {
                attempt: attempt(r, cur),
            },
            18 => EngineEvent::LoadFailed {
                attempt: attempt(r, cur),
                message: "x".into(),
                kind: None,
            },
            _ => EngineEvent::StartWatchdog {
                attempt: attempt(r, cur),
            },
        }
    }

    fn random_intent(&mut self) -> Intent {
        let r = &mut self.rng;
        match r.below(40) {
            0..=3 => Intent::Start(
                [0.0, 0.3, 0.6, 42.0, 99.0, -5.0, f64::NAN, f64::INFINITY][r.below(8) as usize],
            ),
            4..=9 => Intent::Seek([0.0, 10.0, 99.5, 150.0, -4.0, f64::NAN][r.below(6) as usize]),
            10 | 11 => Intent::Pause,
            12..=14 => Intent::Resume,
            15 => Intent::SetTempo([0.5, 1.0, 1.5, 2.0][r.below(4) as usize]),
            16 => Intent::SetVolume(r.range(-50, 200) as i32),
            17 => Intent::SetFill(r.chance(50)),
            18..=21 => Intent::SwitchAudio(r.range(1, 4)),
            22..=26 => Intent::SelectSubtitle(r.range(-1, 8)),
            27 => Intent::SetSubtitleDelay(Delay::from_milliseconds(r.range(-2000, 2000))),
            28 => Intent::SetAudioDelay(Delay::from_milliseconds(r.range(-2000, 2000))),
            29 => Intent::Pip([PipCmd::Start, PipCmd::Stop, PipCmd::Refresh][r.below(3) as usize]),
            30 if r.chance(25) => Intent::Stop {
                reset_display: r.chance(50),
            },
            _ => Intent::Resume,
        }
    }

    /// The host delivers one owed answer, possibly late and out of order.
    fn deliver(&mut self, step: usize) {
        if self.pending.is_empty() {
            return;
        }
        let at = self.rng.below(self.pending.len() as u64) as usize;
        let ev = self.pending.remove(at);
        self.apply(ev, step);
    }
}

fn case(seed: u64) {
    let mut rng = Rng::new(seed ^ 0x9A7E_0001);
    let (req, audio, sub) = request(&mut rng);
    let device_file = req.item_id.is_empty();
    let host_rng = Rng::new(rng.next_u64());
    let mut h = Host {
        s: PlayerState::new(req, audio, sub),
        rng: host_rng,
        attempt: 0,
        pending: Vec::new(),
        stopped: false,
        running_seen: false,
        failed_this_attempt: 0,
        cancel_this_attempt: 0,
        audio_cmds: 0,
        sub_cmds: 0,
        log: Vec::new(),
    };
    let start = [0.0, 30.0][rng.below(2) as usize];
    h.intent(Intent::Start(start), 0);
    let steps = 60 + rng.below(140) as usize;
    for step in 1..=steps {
        match h.rng.below(10) {
            0..=3 => h.deliver(step),
            4..=6 => {
                let ev = h.random_event();
                h.apply(ev, step);
            }
            _ => {
                let i = h.random_intent();
                h.intent(i, step);
            }
        }
    }

    // Drain. A stopped player is inert; any other one reaches a settled start once the host
    // has answered every load and seek.
    let ctx = h.ctx(usize::MAX);
    if h.stopped {
        for ev in [
            EngineEvent::FirstFrame,
            EngineEvent::State(EngineState::Playing),
            EngineEvent::LoadFinished { attempt: h.attempt },
        ] {
            assert!(h.s.apply(ev).is_empty(), "{ctx}: a stopped player reacted");
        }
        assert!(
            h.s.intent(Intent::Start(0.0)).is_empty(),
            "{ctx}: a stopped player started again"
        );
        return;
    }
    // After the end (or a failure) the user resumes; a pending Resume must load.
    if h.s.position() >= h.s.duration_seconds() && h.s.duration_seconds() > 0.0 {
        h.intent(Intent::Resume, usize::MAX);
    }
    h.intent(Intent::Start(0.0), usize::MAX - 1);
    // A new engine session starts its clock again.
    h.apply(
        EngineEvent::Clock {
            position: 0.0,
            source_time: 0.0,
        },
        usize::MAX,
    );
    let mut guard = 0;
    while !h.pending.is_empty() {
        guard += 1;
        assert!(guard < 1000, "{ctx}: the host answers never run out");
        // In the drain every load succeeds, late failures and watchdogs of old attempts are fed too.
        let ev = h.pending.remove(0);
        let ev = match ev {
            EngineEvent::LoadFailed { attempt, .. } => EngineEvent::LoadFinished { attempt },
            e => e,
        };
        h.apply(ev, usize::MAX);
    }
    assert!(
        h.s.start_settled(),
        "{ctx}: the start is still unsettled after every answer"
    );
    h.apply(EngineEvent::FirstFrame, usize::MAX);
    assert!(
        h.s.picture_shown(),
        "{ctx}: no picture after the first frame"
    );
    assert!(
        h.pending.is_empty()
            || h.pending
                .iter()
                .all(|e| !matches!(e, EngineEvent::StartWatchdog { .. }))
    );
    h.apply(
        EngineEvent::Clock {
            position: 12.5,
            source_time: 12.5,
        },
        usize::MAX,
    );
    assert_eq!(
        h.s.position(),
        12.5,
        "{ctx}: the clock is shown once everything has settled"
    );
    assert_eq!(h.s.last_good(), 12.5, "{ctx}: last_good follows the clock");
    // A late watchdog of the settled attempt does nothing.
    let a = h.attempt;
    h.apply(EngineEvent::StartWatchdog { attempt: a }, usize::MAX);
    let _ = device_file;
}

#[test]
fn player_state_random_sequences() {
    common::for_seeds("props_player", 500, case);
}
