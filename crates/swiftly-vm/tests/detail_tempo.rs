//! How fast the detail page shows its content and how fast Play starts, against a server with a latency per request
//! (a title answer 40 ms, every other call 40 ms, the playback info 400 ms because the server probes the file).
//! Each test runs five times and prints the median (`cargo test -p swiftly-vm --test detail_tempo -- --nocapture`).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

use common::account;
use common::script::{Script, host, list, param, wait_for};
use futures_executor::block_on;
use swiftly_cache::{CacheConfig, EntityCache};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_playback::device_profile::Flavour;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{
    DetailIntent, DetailOptions, DetailVm, HomeIntent, HomePrefs, HomeVm, Host, NextSource,
    StartAnswer, StartRequest, StartSettings, ViewCache, play_start,
};

const ITEM_MS: u64 = 40;
const OTHER_MS: u64 = 40;
const PLAN_MS: u64 = 400;
const BITRATE: i64 = 120_000_000;
const RUNS: usize = 5;
const COLLECTIONS: usize = 12;

/// The tests measure time and share the short-term memory of the page; one at a time keeps both honest.
static SERIAL: Mutex<()> = Mutex::new(());

/// A timer that needs no runtime: a thread sleeps and wakes the future.
struct Pause {
    state: Arc<Mutex<(bool, Option<Waker>)>>,
}

fn pause(ms: u64) -> Pause {
    let state = Arc::new(Mutex::new((false, None::<Waker>)));
    let s = Arc::clone(&state);
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(ms));
        let waker = {
            let mut g = s.lock().unwrap();
            g.0 = true;
            g.1.take()
        };
        if let Some(w) = waker {
            w.wake();
        }
    });
    Pause { state }
}

impl Future for Pause {
    type Output = ();
    fn poll(self: std::pin::Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut g = self.state.lock().unwrap();
        if g.0 {
            Poll::Ready(())
        } else {
            g.1 = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}

/// The scripted server behind a latency per request; remembers when each request came in.
struct Slow {
    inner: Arc<Script>,
    seen: Mutex<Vec<(Instant, String)>>,
}

impl Slow {
    fn count(&self, needle: &str) -> usize {
        self.seen
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, u)| u.contains(needle))
            .count()
    }
    /// Plain title requests (`/Items/f1` without a `Fields` extra).
    fn title_requests(&self) -> usize {
        self.seen
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, u)| {
                u.contains("/Items/f1")
                    && !u.contains("/Items/f1/")
                    && !u.contains("Fields=Chapters")
                    && !u.contains("Fields=Trickplay")
            })
            .count()
    }
}

impl HttpTransport for Slow {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let path = request.url.path().to_owned();
        let ms = if path.ends_with("/PlaybackInfo") {
            PLAN_MS
        } else if path.ends_with("/Items/f1") {
            ITEM_MS
        } else {
            OTHER_MS
        };
        self.seen
            .lock()
            .unwrap()
            .push((Instant::now(), request.url.to_string()));
        let answer = self.inner.send(request);
        let wait = pause(ms);
        async move {
            wait.await;
            answer.await
        }
    }
}

const STREAMS: &str = r#"[
 {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160},
 {"Index":1,"Type":"Audio","Codec":"eac3","Language":"ger","IsDefault":true},
 {"Index":2,"Type":"Subtitle","Codec":"subrip","Language":"ger"}
]"#;

fn server() -> Arc<Slow> {
    server_with(Arc::new(AtomicBool::new(false)))
}

/// The scripted server; once `more` is set, the first collection holds one more title.
fn server_with(more: Arc<AtomicBool>) -> Arc<Slow> {
    let script = Script::new(move |r| {
        let p = r.url.path().to_owned();
        let q = r.url.query().unwrap_or("").to_owned();
        let streams: serde_json::Value = serde_json::from_str(STREAMS).unwrap();
        let source = serde_json::json!([{"Id": "s0", "Name": "V", "Container": "mkv", "Size": 5_000_000_000_i64,
            "SupportsDirectPlay": true, "DefaultAudioStreamIndex": 1, "MediaStreams": streams}]);
        if p.ends_with("/Items/f1") {
            let mut v = serde_json::json!({
                "Id": "f1", "Name": "Film", "Type": "Movie", "ProductionYear": 2019, "RunTimeTicks": 72_000_000_000_i64,
                "Overview": "Text", "MediaSources": source, "CommunityRating": 7.5, "OfficialRating": "12",
                "People": [{"Id": "p1", "Name": "A", "Type": "Actor", "Role": "R"}],
                "UserData": {"PlaybackPositionTicks": 6_000_000_000_i64}
            });
            if q.contains("Fields=Chapters") {
                v["Chapters"] = serde_json::json!([
                    {"Name": "Anfang", "StartPositionTicks": 0},
                    {"Name": "Mitte", "StartPositionTicks": 36_000_000_000_i64},
                    {"Name": "Ende", "StartPositionTicks": 54_000_000_000_i64}
                ]);
            }
            return Some(v.to_string());
        }
        if p.ends_with("/Items/f1/PlaybackInfo") {
            return Some(
                serde_json::json!({"MediaSources": source, "PlaySessionId": "ps1"}).to_string(),
            );
        }
        if p.ends_with("/Similar") || p.ends_with("/SpecialFeatures") {
            return Some(list(&[], 0));
        }
        if p.ends_with("/UserViews") {
            return Some(list(
                &[serde_json::json!({"Id": "v1", "Name": "Filme", "CollectionType": "movies"})],
                1,
            ));
        }
        // A library with a dozen collections; only the first holds the film.
        if q.contains("BoxSet") {
            let all: Vec<_> = (1..=COLLECTIONS)
                .map(|n| serde_json::json!({"Id": format!("c{n}"), "Name": format!("Reihe {n}"), "Type": "BoxSet"}))
                .collect();
            return Some(list(&all, all.len()));
        }
        if let Some(parent) = param(r, "ParentId") {
            let m = |id: &str| serde_json::json!({"Id": id, "Name": id, "Type": "Movie"});
            let members = if parent == "c1" {
                let mut members = vec![m("f1"), m("g1"), m("g2")];
                if more.load(Ordering::SeqCst) {
                    members.push(m("g3"));
                }
                members
            } else {
                vec![m(&format!("{parent}-a")), m(&format!("{parent}-b"))]
            };
            return Some(list(&members, members.len()));
        }
        Some("{}".into())
    });
    Arc::new(Slow {
        inner: script,
        seen: Mutex::new(Vec::new()),
    })
}

fn entry() -> Item {
    serde_json::from_value(serde_json::json!({"Id": "f1", "Name": "Film", "Type": "Movie"}))
        .unwrap()
}

fn options() -> DetailOptions {
    DetailOptions {
        max_bitrate: BITRATE,
        ..DetailOptions::default()
    }
}

fn start_request() -> StartRequest {
    StartRequest {
        item_id: "f1".into(),
        source_id: None,
        since: None,
        flavour: Flavour::Aether,
        hardware_av1: false,
        no_dolby_vision_decoder: false,
        ask_versions: true,
        downloaded: None,
        ordered: None,
        account_key: Some("acct".into()),
        settings: StartSettings {
            audio_language: String::new(),
            subtitle_language: "ger".into(),
            automatic_subtitles: false,
            device_language: None,
            max_bitrate: BITRATE,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            server_extracts_text: true,
        },
        next: NextSource::None,
    }
}

fn median(mut v: Vec<u128>) -> u128 {
    v.sort_unstable();
    v[v.len() / 2]
}

/// The same for the account `token` (each account has its own short-term memory).
fn open_page_as(net: &Arc<Slow>, token: &str) -> (DetailVm<Slow>, [u128; 3]) {
    open_page_on(net, token, host())
}

/// The same on the host `on` (pages of one running app share their host, and with it what they remember of the
/// account).
fn open_page_on(net: &Arc<Slow>, token: &str, on: Host) -> (DetailVm<Slow>, [u128; 3]) {
    // Another title id per run is not needed: the memory is keyed by account and title, and a run only starts
    // after the earlier one ended, so each run begins with a fresh `Slow` (and an unseen account token).
    let vm = DetailVm::new(net.clone(), on, entry(), Some(account(token))).unwrap();
    vm.send(DetailIntent::Options(Box::new(options())));
    let began = Instant::now();
    vm.send(DetailIntent::Load);
    let at = Mutex::new([0u128; 3]);
    wait_for("the page", || {
        let now = began.elapsed().as_millis();
        let mut at = at.lock().unwrap();
        if at[0] == 0 && vm.actions().play.ready.is_ready() {
            at[0] = now;
        }
        if at[1] == 0 && vm.actions().proof.visible {
            at[1] = now;
        }
        if at[2] == 0 && vm.bottom().ready {
            at[2] = now;
        }
        at.iter().all(|t| *t > 0)
    });
    let at = *at.lock().unwrap();
    (vm, at)
}

#[test]
fn the_page_shows_its_title_before_the_slow_plan_arrives() {
    let _one_at_a_time = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let mut first = Vec::new();
    let mut proof = Vec::new();
    let mut whole = Vec::new();
    for run in 0..RUNS {
        let net = server();
        // A new account per run: every run is a first visit (nothing remembered about the account's collections).
        let (_vm, at) = open_page_as(&net, &format!("TOKEN-FIRST-{run}"));
        first.push(at[0]);
        proof.push(at[1]);
        whole.push(at[2]);
        assert_eq!(
            net.count("/PlaybackInfo"),
            1,
            "the page asks for the plan once"
        );
    }
    println!(
        "TEMPO page: Play usable {} ms, proof row {} ms, whole page {} ms (median of {RUNS}; plan call {PLAN_MS} ms, title {ITEM_MS} ms)",
        median(first.clone()),
        median(proof.clone()),
        median(whole.clone())
    );
    // The title (and so the usable button) does not wait for the probing plan call.
    assert!(
        median(first) + 200 < median(proof),
        "the button waited for the plan"
    );
}

#[test]
fn play_after_the_page_starts_from_what_the_page_holds() {
    let _one_at_a_time = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let mut warm = Vec::new();
    let mut cold = Vec::new();
    let mut asked_again = false;
    for run in 0..RUNS {
        // After the page: the title and the plan are in hand, nothing is asked twice.
        let net = server();
        // The page and the start are one running app: they share its host (and with it the short-term memory).
        let app = host();
        let (_vm, _) = open_page_on(&net, "TOKEN-A", app.clone());
        let before = (net.count("/PlaybackInfo"), net.title_requests());
        let began = Instant::now();
        let answer = block_on(play_start(
            net.clone(),
            &app,
            &account("TOKEN-A"),
            &start_request(),
            None,
        ))
        .unwrap();
        warm.push(began.elapsed().as_millis());
        assert!(
            matches!(answer, StartAnswer::Ready(_)),
            "run {run}: {answer:?}"
        );
        asked_again |= (net.count("/PlaybackInfo"), net.title_requests()) != before;
        // Without a page (another account, nothing remembered): the whole sequence.
        let net = server();
        let began = Instant::now();
        let answer = block_on(play_start(
            net.clone(),
            &host(),
            &account("TOKEN-COLD"),
            &start_request(),
            None,
        ))
        .unwrap();
        cold.push(began.elapsed().as_millis());
        let StartAnswer::Ready(ready) = answer else {
            panic!("{answer:?}");
        };
        // The version's id is not a title of its own (one version): no request for it, and the chapters and the
        // preview information come from one request for the title.
        assert_eq!(
            net.count("/Items/s0"),
            0,
            "asked for a source id as a title"
        );
        assert_eq!(
            net.count("Fields=Chapters"),
            1,
            "chapters and trickplay in one request"
        );
        assert!(!ready.chapters.is_empty(), "the chapters of the title");
    }
    println!(
        "TEMPO play: from the page {} ms, without a page {} ms (median of {RUNS})",
        median(warm.clone()),
        median(cold.clone())
    );
    assert!(
        !asked_again,
        "the start asked again for what the page holds"
    );
    // A start from the page never waits for the plan call it already holds (PLAN_MS) and is clearly cheaper than the whole
    // sequence. Not a tight round-trip bound: a loaded shared runner stretches every sleep (168 ms measured against the
    // old 140 ms limit for a 40 ms round trip), while a repeated plan call or a sequential start would cost 400 ms or more.
    let (warm, cold) = (median(warm), median(cold));
    assert!(
        warm < u128::from(PLAN_MS),
        "a start from the page waited like a plan call ({warm} ms)"
    );
    assert!(
        warm + u128::from(PLAN_MS) / 2 < cold,
        "a start from the page ({warm} ms) is not clearly cheaper than one without ({cold} ms)"
    );
}

/// How many requests of the collection lookup (the list of collections, the members of each one) the net has seen.
fn collection_requests(net: &Slow) -> usize {
    net.count("BoxSet") + net.count("ParentId=")
}

#[test]
fn the_collections_are_asked_once_and_not_on_every_page() {
    let _one_at_a_time = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let (mut first, mut second, mut third) = (Vec::new(), Vec::new(), Vec::new());
    let (mut first_asks, mut later_asks) = (0, 0);
    for run in 0..RUNS {
        // One account, three visits one after another: the lookup of the collections belongs to the account, not to the page.
        let token = format!("TOKEN-COLL-{run}");
        let net = server();
        let app = host();
        let (vm, at) = open_page_on(&net, &token, app.clone());
        first.push(at[2]);
        first_asks = collection_requests(&net);
        drop(vm);
        let (vm, at) = open_page_on(&net, &token, app.clone());
        second.push(at[2]);
        drop(vm);
        let (_vm, at) = open_page_on(&net, &token, app);
        third.push(at[2]);
        // Whatever refreshes in the background is not part of the page: give it time, then count.
        std::thread::sleep(Duration::from_millis(300));
        later_asks = collection_requests(&net);
    }
    println!(
        "TEMPO collections: whole page, first visit {} ms, second {} ms, third {} ms (median of {RUNS}); lookup requests: after the first visit {first_asks}, after three visits {later_asks}",
        median(first.clone()),
        median(second.clone()),
        median(third.clone())
    );
    assert!(
        median(second) + 60 < median(first),
        "the second visit asked for the collections again"
    );
    assert!(
        later_asks <= first_asks,
        "three visits sent {later_asks} lookup requests, the first alone {first_asks}"
    );
}

#[test]
fn the_home_page_asks_for_the_collections_so_the_first_page_finds_them() {
    let _one_at_a_time = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let mut whole = Vec::new();
    let mut asked_by_the_page = 0;
    for run in 0..RUNS {
        let token = format!("TOKEN-HOME-{run}");
        let net = server();
        let app = host();
        let home = HomeVm::new(
            net.clone(),
            app.clone(),
            HomePrefs::default(),
            Some(account(&token)),
        )
        .unwrap();
        home.send(HomeIntent::Load);
        wait_for("the home page asked for the collections", || {
            net.count("BoxSet") > 0
        });
        // The lookup is a few stages (the views, the collections, their members); wait until it is quiet.
        let seen = Mutex::new(0);
        wait_for("the lookup of the collections ended", || {
            std::thread::sleep(Duration::from_millis(150));
            let now = collection_requests(&net);
            let mut seen = seen.lock().unwrap();
            let quiet = now == *seen && now > 1;
            *seen = now;
            quiet
        });
        let before = collection_requests(&net);
        let (_vm, at) = open_page_on(&net, &token, app);
        whole.push(at[2]);
        asked_by_the_page = collection_requests(&net) - before;
    }
    println!(
        "TEMPO collections after the home page: whole page of the first visit {} ms (median of {RUNS}); lookup requests of the page itself: {asked_by_the_page}",
        median(whole)
    );
    assert!(
        asked_by_the_page <= 1,
        "the first page asked {asked_by_the_page} times for the collections after the home page had"
    );
}

#[test]
fn marking_the_title_watched_makes_the_next_start_ask_for_the_title_again() {
    let _one_at_a_time = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let net = server();
    let (vm, _) = open_page_as(&net, "TOKEN-WATCHED");
    vm.send(DetailIntent::SetWatched { on: true });
    wait_for("the flag reached the server", || {
        net.count("/UserPlayedItems/f1") > 0 || net.count("/PlayedItems/f1") > 0
    });
    let before = net.title_requests();
    let answer = block_on(play_start(
        net.clone(),
        &host(),
        &account("TOKEN-WATCHED"),
        &start_request(),
        None,
    ))
    .unwrap();
    assert!(matches!(answer, StartAnswer::Ready(_)), "{answer:?}");
    assert!(
        net.title_requests() > before,
        "the start took the title the page remembered before the change"
    );
}

/// Tiles in each "part of the collection" row of the page.
fn rail_sizes(vm: &DetailVm<Slow>) -> Vec<usize> {
    vm.bottom()
        .collections
        .iter()
        .map(|c| c.tiles.len())
        .collect()
}

#[test]
fn a_library_change_makes_the_next_page_ask_again_and_the_open_page_takes_the_new_row() {
    let _one_at_a_time = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let more = Arc::new(AtomicBool::new(false));
    let net = server_with(Arc::clone(&more));
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    let app = Host {
        cache: Some(cache.clone()),
        ..host()
    };
    let token = "TOKEN-OPEN-ROW";
    let (first, _) = open_page_on(&net, token, app.clone());
    assert_eq!(rail_sizes(&first), [2]);
    drop(first);

    // The library changes on the server and the event reaches the app.
    more.store(true, Ordering::SeqCst);
    std::thread::sleep(Duration::from_millis(300));
    let asked = collection_requests(&net);
    let event = swiftly_cache::parse_ws(
        r#"{"MessageType":"LibraryChanged","Data":{"ItemsAdded":["g3"],"ItemsUpdated":["c1"],"ItemsRemoved":[]}}"#,
    )
    .unwrap();
    cache.apply_event(&account(token), &event);

    let second = DetailVm::new(net.clone(), app, entry(), Some(account(token))).unwrap();
    second.send(DetailIntent::Options(Box::new(options())));
    second.send(DetailIntent::Load);
    wait_for("the bottom of the page", || second.bottom().ready);
    assert_eq!(
        rail_sizes(&second),
        [2],
        "the page draws from the stored collections at once, it does not wait for the server"
    );
    wait_for("the row of the changed collection", || {
        rail_sizes(&second) == [3]
    });
    assert!(
        collection_requests(&net) > asked,
        "the change did not make the page ask for the collections again"
    );
}
