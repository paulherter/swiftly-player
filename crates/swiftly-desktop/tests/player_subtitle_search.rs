//! "Untertitel suchen …" in the player's Tracks layer: the screen draws the core's `SubtitleSearchPart` (language chips,
//! hit rows, messages) and sends its intents; a finished download reloads the title at the position with the added
//! track switched on. A scripted search stands in for the core's.
#![allow(clippy::unwrap_used)]

use std::sync::{Arc, Mutex};
use swiftly_desktop::login_screen::Pending;
use swiftly_desktop::player_host::{PlanAsk, Planner, SubtitleSearch, Switched};
use swiftly_desktop::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{
    PlayerIntent, PlayerLayer, Quality, SubtitleHitRow, SubtitleLanguage, SubtitleSearchIntent,
    SubtitleSearchPart, SubtitleSearchPhase,
};

fn part(phase: SubtitleSearchPhase) -> SubtitleSearchPart {
    let results = matches!(
        phase,
        SubtitleSearchPhase::Results | SubtitleSearchPhase::Downloading
    );
    SubtitleSearchPart {
        version: 1,
        phase,
        title: "Untertitel suchen".into(),
        languages: vec![
            SubtitleLanguage {
                value: "de".into(),
                label: "Deutsch".into(),
                selected: true,
            },
            SubtitleLanguage {
                value: "en".into(),
                label: "Englisch".into(),
                selected: false,
            },
        ],
        rows: if results {
            (1..=3)
                .map(|i| SubtitleHitRow {
                    id: format!("fx_{i}"),
                    title: format!("Example.Show.S01E0{i}.de.srt"),
                    source_line: "SRT · Fixture".into(),
                    meta_line: format!("Bewertung 8,{i} · {i}00 Downloads"),
                    rating: Some(format!("8,{i}")),
                    downloads: Some(i * 100),
                    hearing_impaired: false,
                    matches_file: false,
                    busy: phase == SubtitleSearchPhase::Downloading && i == 1,
                })
                .collect()
        } else {
            Vec::new()
        },
        message: (phase == SubtitleSearchPhase::Done).then(|| "Untertitel hinzugefügt.".to_owned()),
        tracks: Vec::new(),
        added: i64::from(phase == SubtitleSearchPhase::Done),
        selected_track: (phase == SubtitleSearchPhase::Done).then_some(5),
    }
}

/// Answers a search with three hits and a download with `Done` (the added track is stream 5).
struct Scripted {
    now: Mutex<SubtitleSearchPart>,
    seen: Mutex<Vec<SubtitleSearchIntent>>,
}

impl SubtitleSearch for Scripted {
    fn part(&self) -> Arc<SubtitleSearchPart> {
        Arc::new(self.now.lock().unwrap().clone())
    }
    fn send(&self, intent: SubtitleSearchIntent) {
        let phase = match &intent {
            SubtitleSearchIntent::Search { .. } => SubtitleSearchPhase::Results,
            SubtitleSearchIntent::Download { .. } => SubtitleSearchPhase::Done,
        };
        *self.now.lock().unwrap() = part(phase);
        self.seen.lock().unwrap().push(intent);
    }
}

struct Host {
    asks: Mutex<Vec<PlanAsk>>,
    forgot: Mutex<u32>,
    search: Arc<Scripted>,
    offered: bool,
}

impl Planner for Host {
    fn plan(&self, ask: PlanAsk) -> Pending<Result<Switched, String>> {
        let (tx, rx) = Pending::channel();
        self.asks.lock().unwrap().push(ask);
        drop(tx);
        rx
    }
    fn quality(&self) -> Quality {
        Quality {
            direct_play: true,
            limit: 0,
        }
    }
    fn save_quality(&self, _quality: Quality) {}
    fn forget_prepared(&self) {
        *self.forgot.lock().unwrap() += 1;
    }
    fn offers_subtitle_search(&self) -> bool {
        self.offered
    }
    fn subtitle_search(&self, _item_id: &str) -> Option<Arc<dyn SubtitleSearch>> {
        self.offered
            .then(|| Arc::clone(&self.search) as Arc<dyn SubtitleSearch>)
    }
}

fn rig(idiom: Idiom, size: (f32, f32), offered: bool) -> (PlayerScreen, Arc<Host>, f64) {
    let env = Env::new(Size::new(size.0, size.1), 1.0, idiom);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let host = Arc::new(Host {
        asks: Mutex::new(Vec::new()),
        forgot: Mutex::new(0),
        search: Arc::new(Scripted {
            now: Mutex::new(part(SubtitleSearchPhase::Idle)),
            seen: Mutex::new(Vec::new()),
        }),
        offered,
    });
    s.set_planner(Arc::clone(&host) as Arc<dyn Planner>);
    let _ = s.frame(0.0);
    (s, host, 0.0)
}

fn settle(s: &mut PlayerScreen, from: f64) -> f64 {
    let mut now = from;
    for _ in 0..40 {
        now += 16.0;
        let _ = s.frame(now);
    }
    now
}

fn tap(s: &mut PlayerScreen, key: &str, now: f64) -> f64 {
    let [x, y, w, h] = s
        .frame_of(key)
        .unwrap_or_else(|| panic!("no control {key}"));
    let (cx, cy) = (x + w / 2.0, y + h / 2.0);
    s.touch_down(cx, cy, now);
    s.touch_up(cx, cy, now + 40.0);
    settle(s, now + 40.0)
}

const FORMS: [(Idiom, (f32, f32)); 2] = [
    (Idiom::Desktop, (1280.0, 800.0)),
    (Idiom::Phone, (844.0, 390.0)),
];

#[test]
fn the_entry_shows_only_when_the_server_can_search() {
    for (idiom, size) in FORMS {
        let (mut s, _host, now) = rig(idiom, size, false);
        let now = settle(&mut s, now);
        s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now);
        settle(&mut s, now);
        assert!(
            s.frame_of("search:open").is_none(),
            "{idiom:?}: entry without a provider call"
        );
        let (mut s, _host, now) = rig(idiom, size, true);
        let now = settle(&mut s, now);
        s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now);
        settle(&mut s, now);
        assert!(
            s.frame_of("search:open").is_some(),
            "{idiom:?}: entry missing"
        );
    }
}

#[test]
fn a_search_draws_the_cores_rows_and_a_download_reloads_the_title_with_the_new_track() {
    for (idiom, size) in FORMS {
        let (mut s, host, now) = rig(idiom, size, true);
        let mut now = settle(&mut s, now);
        s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Tracks)), now);
        now = settle(&mut s, now);
        now = tap(&mut s, "search:open", now);
        assert_eq!(
            host.search.seen.lock().unwrap().first(),
            Some(&SubtitleSearchIntent::Search { language: None }),
            "{idiom:?}: the search starts in the language of the settings"
        );
        for i in 1..=3 {
            assert!(
                s.frame_of(&format!("search:dl:fx_{i}")).is_some(),
                "{idiom:?}: hit {i} is not drawn"
            );
        }
        assert!(
            s.frame_of("search:lang:en").is_some(),
            "{idiom:?}: language chip"
        );
        assert!(
            s.frame_of("search:open").is_none(),
            "{idiom:?}: the columns are gone while searching"
        );
        // Esc goes back to the columns, the layer stays.
        assert!(s.key(PlayerKey::Escape, now));
        now = settle(&mut s, now);
        assert!(
            s.frame_of("search:open").is_some(),
            "{idiom:?}: Esc returns to the columns"
        );
        now = tap(&mut s, "search:open", now);
        let pos = s.vm().transport().position;
        now = tap(&mut s, "search:dl:fx_2", now);
        let _ = now;
        assert_eq!(
            host.search.seen.lock().unwrap().last(),
            Some(&SubtitleSearchIntent::Download { id: "fx_2".into() }),
            "{idiom:?}"
        );
        let asks = host.asks.lock().unwrap();
        assert_eq!(asks.len(), 1, "{idiom:?}: one reload");
        assert!(
            asks[0].reload && asks[0].subtitle == Some(5),
            "{idiom:?}: {:?}",
            asks[0]
        );
        assert!(
            (asks[0].since - pos).abs() < 1.0,
            "{idiom:?}: reloads at the position"
        );
        assert_eq!(
            *host.forgot.lock().unwrap(),
            1,
            "{idiom:?}: the warm plan is dropped"
        );
        assert!(
            s.vm().controls().layer.is_none(),
            "{idiom:?}: the layer closes"
        );
    }
}
