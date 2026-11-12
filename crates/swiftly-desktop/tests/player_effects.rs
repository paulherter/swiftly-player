//! The desktop player runs the core's effects exactly once, in one place: next episode (card and countdown), quality
//! change at the same position, subtitle reload on a transcode, close. A fake host answers the plan requests.
#![allow(clippy::unwrap_used)]

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use swiftly_desktop::login_screen::Pending;
use swiftly_desktop::player_host::{PlanAsk, Planner, Switched};
use swiftly_desktop::player_screen::{PlayerScenario, PlayerScreen};
use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_layout::Size;
use swiftly_model::MediaStream;
use swiftly_playback::player_state::EngineRequest;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{NextEpisode, PlayerIntent, PlayerSpec, Quality};

const STEP: f64 = 1000.0 / 60.0;

/// Answers every plan with a bare title of that id; records what it was asked.
struct Fake {
    asks: Mutex<Vec<PlanAsk>>,
    saved: Mutex<Vec<Quality>>,
    forgot: AtomicUsize,
    warmed: AtomicUsize,
    fail: bool,
}

impl Fake {
    fn new(fail: bool) -> Fake {
        Fake {
            asks: Mutex::new(Vec::new()),
            saved: Mutex::new(Vec::new()),
            forgot: AtomicUsize::new(0),
            warmed: AtomicUsize::new(0),
            fail,
        }
    }
}

fn stream(index: i64, kind: &str, codec: &str) -> MediaStream {
    MediaStream {
        index: Some(index),
        type_: Some(kind.into()),
        language: Some("eng".into()),
        codec: Some(codec.into()),
        ..MediaStream::default()
    }
}

fn spec(id: &str, next: Option<&str>) -> PlayerSpec {
    PlayerSpec {
        item_id: id.into(),
        title: format!("Titel {id}"),
        plan: ReportPlan {
            play_session_id: None,
            media_source_id: Some("v1".into()),
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: id.into(),
            streams: vec![stream(1, "Audio", "eac3"), stream(3, "Subtitle", "subrip")],
            runtime: 2700.0,
            subtitle_files: Vec::new(),
            url: format!("demo://{id}"),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: 0.0,
        audio_index: Some(1),
        subtitle_index: -1,
        next: next.map(|n| NextEpisode {
            id: n.into(),
            title: format!("Folge {n}"),
        }),
        series_id: Some("serie".into()),
        track_title: None,
        downloaded: false,
    }
}

impl Planner for Fake {
    fn plan(&self, ask: PlanAsk) -> Pending<Result<Switched, String>> {
        let (tx, rx) = Pending::channel();
        let answer = if self.fail {
            Err("Der Server antwortet nicht.".to_owned())
        } else {
            Ok(Switched::bare(
                spec(&ask.id, None),
                (format!("Titel {}", ask.id), String::new()),
            ))
        };
        self.asks.lock().unwrap().push(ask);
        let _ = tx.send(answer);
        rx
    }
    fn quality(&self) -> Quality {
        Quality {
            direct_play: true,
            limit: 0,
        }
    }
    fn save_quality(&self, quality: Quality) {
        self.saved.lock().unwrap().push(quality);
    }
    fn prepare_next(&self, _ask: PlanAsk) {
        self.warmed.fetch_add(1, Ordering::SeqCst);
    }
    fn forget_prepared(&self) {
        self.forgot.fetch_add(1, Ordering::SeqCst);
    }
}

fn rig(fail: bool) -> (PlayerScreen, std::sync::Arc<Fake>, f64) {
    let env = Env::new(Size::new(1280.0, 720.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let fake = std::sync::Arc::new(Fake::new(fail));
    s.set_planner(std::sync::Arc::clone(&fake) as std::sync::Arc<dyn Planner>);
    let _ = s.frame(0.0);
    (s, fake, 0.0)
}

/// What a real engine reports after a load.
fn settle(s: &mut PlayerScreen, now: f64) {
    use swiftly_playback::engine::{EngineEvent, EngineState};
    s.engine_event(EngineEvent::LoadFinished { attempt: 1 }, now);
    s.engine_event(EngineEvent::Duration(2700.0), now);
    s.engine_event(EngineEvent::State(EngineState::Playing), now);
    s.engine_event(EngineEvent::FirstFrame, now);
}

fn run(s: &mut PlayerScreen, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

#[test]
fn next_episode_from_the_card_plans_once_and_loads_it() {
    let (mut s, fake, mut now) = rig(false);
    run(&mut s, &mut now, 1000.0);
    s.jump_clock(2700.0 - 20.0, now);
    run(&mut s, &mut now, 600.0);
    s.send_intent(PlayerIntent::PressOffering, now);
    run(&mut s, &mut now, 500.0);
    let asks = fake.asks.lock().unwrap().clone();
    assert_eq!(asks.len(), 1, "{asks:?}");
    assert_eq!(
        (asks[0].id.as_str(), asks[0].reload, asks[0].since),
        ("demo-ep2", false, 0.0)
    );
    assert!(!s.switching());
    assert_eq!(
        s.vm().spec().item_id,
        "demo-ep2",
        "the next episode is loaded"
    );
}

#[test]
fn the_countdown_starts_the_next_episode_without_a_press() {
    let (mut s, fake, mut now) = rig(false);
    run(&mut s, &mut now, 1000.0);
    s.jump_clock(2700.0 - 12.0, now);
    run(&mut s, &mut now, 14_000.0);
    let asks = fake.asks.lock().unwrap().clone();
    assert_eq!(asks.len(), 1, "once, not once per frame: {asks:?}");
    assert_eq!(asks[0].id, "demo-ep2");
    assert!(asks[0].from_card || asks[0].since == 0.0);
    assert_eq!(s.vm().spec().item_id, "demo-ep2");
}

#[test]
fn a_quality_change_files_the_choice_and_reloads_at_the_same_position() {
    let (mut s, fake, mut now) = rig(false);
    run(&mut s, &mut now, 1000.0);
    s.vm()
        .load_title(spec("demo-ep", Some("demo-ep2")), now / 1000.0);
    settle(&mut s, now);
    run(&mut s, &mut now, 2500.0);
    s.jump_clock(600.0, now);
    run(&mut s, &mut now, 600.0);
    s.send_intent(PlayerIntent::Quality(Some(8)), now);
    let ask = s.switch_ask().cloned().expect("the plan is asked");
    assert!(ask.reload && ask.subtitle.is_none());
    assert_eq!(
        ask.quality,
        Quality {
            direct_play: false,
            limit: 8
        },
        "the plan carries the choice just made"
    );
    assert_eq!(ask.source_id.as_deref(), Some("v1"), "the version stays");
    assert!(ask.since >= 600.0 && ask.since < 620.0, "{}", ask.since);
    run(&mut s, &mut now, 300.0);
    assert_eq!(
        *fake.saved.lock().unwrap(),
        vec![Quality {
            direct_play: false,
            limit: 8
        }]
    );
    assert_eq!(
        fake.forgot.load(Ordering::SeqCst),
        1,
        "the prepared plan of the next episode is dropped"
    );
    assert_eq!(fake.asks.lock().unwrap().len(), 1);
    let now_playing = s.vm().spec();
    assert_eq!(now_playing.item_id, "demo-ep");
    assert!(
        (now_playing.start_at - ask.since).abs() < 1e-9,
        "reloaded at the same position"
    );
    // The same choice again changes nothing.
    s.send_intent(PlayerIntent::Quality(Some(8)), now);
    assert!(!s.switching());
}

#[test]
fn a_subtitle_on_a_transcode_reloads_with_the_track_and_a_direct_play_does_not() {
    let (mut s, fake, mut now) = rig(false);
    run(&mut s, &mut now, 1000.0);
    // Direct play: the engine switches by itself.
    s.send_intent(PlayerIntent::SelectSubtitle(3), now);
    assert!(!s.switching() && fake.asks.lock().unwrap().is_empty());
    // A transcode with a picture subtitle (the core's rule says: replan).
    let mut sp = spec("demo-ep", Some("demo-ep2"));
    sp.plan.method = PlayMethod::Transcode;
    sp.request.url = "https://tv.example.test/videos/ep1/master.m3u8?VideoCodec=h264&TranscodeReasons=VideoCodecNotSupported".into();
    sp.request
        .streams
        .push(stream(4, "Subtitle", "hdmv_pgs_subtitle"));
    s.vm().load_title(sp, now / 1000.0);
    settle(&mut s, now);
    run(&mut s, &mut now, 2500.0);
    s.jump_clock(300.0, now);
    run(&mut s, &mut now, 600.0);
    s.send_intent(PlayerIntent::SelectSubtitle(4), now);
    let ask = s.switch_ask().cloned().expect("a reload is asked");
    assert!(
        ask.reload && ask.subtitle == Some(4) && ask.id == "demo-ep",
        "{ask:?}"
    );
    assert!(
        ask.since >= 300.0 && ask.since < 320.0,
        "since {}",
        ask.since
    );
    run(&mut s, &mut now, 300.0);
    assert_eq!(fake.asks.lock().unwrap().len(), 1);
    let loaded = s.vm().spec();
    assert_eq!(loaded.subtitle_index, 4, "the title starts on the track");
    assert!((loaded.start_at - ask.since).abs() < 1e-9);
}

#[test]
fn close_leaves_the_screen_and_plans_nothing() {
    let (mut s, fake, mut now) = rig(false);
    run(&mut s, &mut now, 500.0);
    s.send_intent(PlayerIntent::Close, now);
    assert!(s.is_closed());
    run(&mut s, &mut now, 300.0);
    assert!(fake.asks.lock().unwrap().is_empty() && !s.switching());
}

#[test]
fn a_plan_that_fails_shows_the_failed_screen_and_asks_only_once() {
    let (mut s, fake, mut now) = rig(true);
    run(&mut s, &mut now, 1000.0);
    s.send_intent(PlayerIntent::NextEpisode, now);
    run(&mut s, &mut now, 1500.0);
    assert_eq!(fake.asks.lock().unwrap().len(), 1);
    assert!(!s.switching());
    assert!(
        s.log().iter().any(|l| l.contains("switch failed")),
        "{:?}",
        s.log()
    );
    assert!(!s.is_closed());
}
