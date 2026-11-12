//! The soak workload: many sessions against the real core (`swiftly_uniffi::Core`) over the
//! in-process server: home sessions, paging through a 10k-item library, search, cancelation
//! storms, account switches and image cache churn (`swiftly-images` loader with a size cap).

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_compat::Compat;
use futures_util::FutureExt;
use swiftly_images::loader::{ImageLoader, Priority, Slot};
use swiftly_jellyfin::ServerKind;
use swiftly_library::ShelfSource;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport, ReqwestTransport, Url};
use swiftly_uniffi::{Core, LibrarySpec};
use swiftly_vm::{AccountRef, HomeIntent, LibraryIntent, LibraryStatus, SearchIntent, Status};

use super::host::{Control, SoakHttp, SoakKv, SoakPlatform, SoakSecrets};
use super::sample::{self, Sample, Verdict};
use super::{Config, server};
use crate::Rng;

/// reqwest needs a tokio context; the image loader's threads have none, so every request runs
/// inside `Compat` (what the Apple build avoids by using the host's HTTP).
pub struct CompatTransport(pub ReqwestTransport);

impl HttpTransport for CompatTransport {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        Compat::new(self.0.send(request)).await
    }
}

/// Upper bound (never slept in full) for a library step: a debug build on a busy machine parses the whole list per view model.
pub const LIBRARY_WAIT_MS: u64 = 20_000;

pub const IMAGE_BUDGET: usize = 4 * 1024 * 1024;

pub struct Rig {
    pub core: Arc<Core>,
    pub ctl: Arc<Control>,
    pub acct: AccountRef,
    pub acct2: AccountRef,
    /// The same server asked as an Emby account (user-bound paths, other token header).
    pub acct_emby: AccountRef,
    pub base: String,
    pub ws_base: String,
    pub handle: tokio::runtime::Handle,
    pub loader: ImageLoader<CompatTransport>,
}

pub fn account(base: &str, user: &str) -> AccountRef {
    AccountRef {
        base_url: base.to_owned(),
        user_id: user.to_owned(),
        token: "fixture-token".to_owned(),
        server_kind: ServerKind::Jellyfin,
        device_id: "soak-device".to_owned(),
        plex_machine_id: None,
        plex_account_token: None,
    }
}

pub fn rig(big: usize) -> Rig {
    let base = server::start(big);
    let ctl = Control::new();
    let core = Core::new(
        Arc::new(SoakPlatform(Arc::clone(&ctl))),
        Arc::new(SoakSecrets::new(Arc::clone(&ctl))),
        Arc::new(SoakKv::new(Arc::clone(&ctl))),
        Arc::new(SoakHttp::new(Arc::clone(&ctl))),
    );
    let handle = Compat::new(async { tokio::runtime::Handle::current() })
        .now_or_never()
        .expect("runtime handle");
    let loader = ImageLoader::with_budget(
        Arc::new(CompatTransport(super::host::soak_transport())),
        None,
        IMAGE_BUDGET,
    );
    let ws_base = super::ws::start(7);
    let acct_emby = AccountRef {
        server_kind: ServerKind::Emby,
        ..account(&base, "e1")
    };
    Rig {
        acct: account(&base, "u1"),
        acct2: account(&base, "u2"),
        acct_emby,
        core,
        ctl,
        base,
        ws_base,
        handle,
        loader,
    }
}

pub fn wait_until(ms: u64, f: impl Fn() -> bool) -> bool {
    let end = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < end {
        if f() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    f()
}

pub fn library_spec() -> LibrarySpec {
    LibrarySpec {
        source: ShelfSource {
            parent: Some("lib-movies".to_owned()),
            only_out: Vec::new(),
            art: None,
            collection: false,
        },
        genre: None,
        remember_name: Some("soak".to_owned()),
    }
}

#[derive(Default)]
pub struct Stats {
    pub home: AtomicU64,
    pub library: AtomicU64,
    pub pages: AtomicU64,
    pub max_tiles: AtomicU64,
    pub search: AtomicU64,
    pub storms: AtomicU64,
    pub cancels: AtomicU64,
    pub switches: AtomicU64,
    pub images: AtomicU64,
    pub flaps: AtomicU64,
    pub ws_connects: AtomicU64,
    pub ws_lost: AtomicU64,
    pub beats: AtomicU64,
    pub max_stall_ms: AtomicU64,
    pub problems: Mutex<Vec<String>>,
}

impl Stats {
    fn problem(&self, text: String) {
        let mut p = self
            .problems
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if p.len() < 20 {
            p.push(text);
        }
    }

    pub fn line(&self) -> String {
        let g = |a: &AtomicU64| a.load(Ordering::Relaxed);
        format!(
            "home={} library={} pages={} max_tiles={} search={} storms={} cancelled={} switches={} images={} flaps={} ws_connects={} ws_lost={} beats={} max_stall_ms={}",
            g(&self.home),
            g(&self.library),
            g(&self.pages),
            g(&self.max_tiles),
            g(&self.search),
            g(&self.storms),
            g(&self.cancels),
            g(&self.switches),
            g(&self.images),
            g(&self.flaps),
            g(&self.ws_connects),
            g(&self.ws_lost),
            g(&self.beats),
            g(&self.max_stall_ms)
        )
    }
}

fn home_session(r: &Rig, rng: &mut Rng, st: &Stats) {
    let acct = if rng.chance(30) {
        r.acct_emby.clone()
    } else {
        r.acct.clone()
    };
    let Ok(vm) = r.core.home_vm(acct, "de".into()) else {
        return;
    };
    vm.send(HomeIntent::Load);
    if !wait_until(5000, || !matches!(vm.status().status, Status::Loading)) {
        st.problem("home: still loading after 5 s".into());
    }
    if let Some(rail) = vm.rails().rails.first() {
        let _ = vm.tiles(rail.id.clone(), 0, 12);
    }
    if rng.chance(40) {
        vm.send(HomeIntent::Refresh);
        std::thread::sleep(Duration::from_millis(rng.below(30)));
    }
    st.home.fetch_add(1, Ordering::Relaxed);
}

fn library_paging(r: &Rig, rng: &mut Rng, st: &Stats) {
    let acct = if rng.chance(30) {
        r.acct_emby.clone()
    } else {
        r.acct.clone()
    };
    let Ok(vm) = r.core.library_vm(acct, "de".into(), library_spec()) else {
        return;
    };
    vm.send(LibraryIntent::Load);
    if !wait_until(LIBRARY_WAIT_MS, || {
        matches!(vm.status().status, LibraryStatus::Ready)
    }) {
        st.problem(format!("library: not ready after {LIBRARY_WAIT_MS} ms"));
        return;
    }
    let pages = rng.range(1, 60);
    for _ in 0..pages {
        let before = vm.grid().tiles.len();
        if !vm.status().more_available {
            break;
        }
        // A LoadMore that arrives while the view model still loads (after a re-sort) is ignored by design, so the
        // intent is repeated until one is taken; a taken one blocks the others until its page is in.
        let grew = wait_until(LIBRARY_WAIT_MS, || {
            if vm.grid().tiles.len() > before || !vm.status().more_available {
                return true;
            }
            vm.send(LibraryIntent::LoadMore);
            false
        });
        if !grew {
            st.problem(format!(
                "library: LoadMore did not grow the grid from {before}"
            ));
            break;
        }
        st.pages.fetch_add(1, Ordering::Relaxed);
    }
    let grid = vm.grid();
    st.max_tiles
        .fetch_max(grid.tiles.len() as u64, Ordering::Relaxed);
    if grid.total > 0 && grid.tiles.len() as i64 > grid.total {
        st.problem(format!(
            "library: {} tiles for a total of {}",
            grid.tiles.len(),
            grid.total
        ));
    }
    if rng.chance(30) {
        // A re-sort reloads the grid; the view model must come back to Ready with the new order.
        let latest = swiftly_library::library_filter::Sorting::Latest;
        vm.send(LibraryIntent::SetSorting { sorting: latest });
        let back = wait_until(LIBRARY_WAIT_MS, || {
            let status = vm.status();
            matches!(status.status, LibraryStatus::Ready) && status.sorting == latest
        });
        if !back {
            st.problem("library: not ready after a re-sort".into());
        }
    }
    st.library.fetch_add(1, Ordering::Relaxed);
}

fn search_session(r: &Rig, rng: &mut Rng, st: &Stats) {
    let Ok(vm) = r.core.search_vm(r.acct.clone(), "de".into()) else {
        return;
    };
    for _ in 0..rng.range(1, 6) {
        let word = rng.word(&["no", "rd", "li", "cht", "som", "mer", "re", "gen"], 3);
        vm.send(SearchIntent::Query { text: word });
        std::thread::sleep(Duration::from_millis(rng.below(40)));
    }
    st.search.fetch_add(1, Ordering::Relaxed);
}

fn cancel_storm(r: &Rig, rng: &mut Rng, st: &Stats) {
    let n = rng.range(8, 24);
    let mut homes = Vec::new();
    let mut libs = Vec::new();
    for i in 0..n {
        if let Ok(h) = r.core.home_vm(r.acct.clone(), "de".into()) {
            h.send(HomeIntent::Load);
            homes.push(h);
        }
        // A library view model lists and sorts the whole title list (10 000 here); a few of them are a storm already.
        if i % 4 != 0 {
            continue;
        }
        if let Ok(l) = r
            .core
            .library_vm(r.acct.clone(), "de".into(), library_spec())
        {
            l.send(LibraryIntent::Load);
            libs.push(l);
        }
    }
    std::thread::sleep(Duration::from_millis(rng.below(15)));
    // Some LoadMore in flight when everything is dropped.
    for l in libs.iter().take(4) {
        l.send(LibraryIntent::LoadMore);
    }
    st.cancels
        .fetch_add((homes.len() + libs.len()) as u64, Ordering::Relaxed);
    drop(homes);
    drop(libs);
    st.storms.fetch_add(1, Ordering::Relaxed);
}

fn account_switch(r: &Rig, rng: &mut Rng, st: &Stats) {
    let Ok(home) = r.core.home_vm(r.acct.clone(), "de".into()) else {
        return;
    };
    let Ok(lib) = r
        .core
        .library_vm(r.acct.clone(), "de".into(), library_spec())
    else {
        return;
    };
    home.send(HomeIntent::Load);
    lib.send(LibraryIntent::Load);
    for i in 0..rng.range(2, 8) {
        std::thread::sleep(Duration::from_millis(rng.below(25)));
        let next = match i % 3 {
            0 => Some(r.acct2.clone()),
            1 => None,
            _ => Some(r.acct.clone()),
        };
        home.send(HomeIntent::AccountSwitched {
            account: next.clone(),
        });
        lib.send(LibraryIntent::AccountSwitched { account: next });
        st.switches.fetch_add(1, Ordering::Relaxed);
    }
}

fn image_churn(r: &Rig, rng: &mut Rng, st: &Stats) {
    let mut asked = Vec::new();
    for _ in 0..rng.range(20, 80) {
        let id = if rng.chance(5) {
            format!("x{}", rng.below(100_000))
        } else {
            format!("m{}", rng.below(5000))
        };
        let Ok(url) = Url::parse(&format!(
            "{}/Items/{id}/Images/Primary?tag=t&maxWidth=120",
            r.base
        )) else {
            continue;
        };
        let prio = if rng.chance(50) {
            Priority::Visible
        } else {
            Priority::Ahead
        };
        if matches!(r.loader.request(&url, 120, prio), Slot::Ready(_)) {
            st.images.fetch_add(1, Ordering::Relaxed);
        }
        asked.push(url);
        if rng.chance(30)
            && let Some(u) = asked.get(rng.below(asked.len() as u64) as usize)
        {
            r.loader.cancel(u);
        }
        if rng.chance(30) {
            r.loader.poll();
        }
    }
    if rng.chance(2) {
        r.loader.wipe();
    }
    std::thread::sleep(Duration::from_millis(rng.below(40)));
    r.loader.poll();
    let (_, used) = r.loader.memory_use();
    if used > IMAGE_BUDGET + 2 * 1024 * 1024 {
        st.problem(format!(
            "images: memory cache uses {used} bytes for a budget of {IMAGE_BUDGET}"
        ));
    }
}

/// The connection of one account drops while its view models load and comes back: loads must end (not hang)
/// and a refresh after the return must bring the data.
fn flap_session(r: &Rig, rng: &mut Rng, st: &Stats, worker: usize) {
    let token = format!("flap-token-{worker}");
    let mut acct = account(&r.base, "u3");
    acct.token = token.clone();
    let Ok(home) = r.core.home_vm(acct.clone(), "de".into()) else {
        return;
    };
    let Ok(lib) = r.core.library_vm(acct, "de".into(), library_spec()) else {
        return;
    };
    r.ctl.set_offline(&token, true);
    home.send(HomeIntent::Load);
    lib.send(LibraryIntent::Load);
    if !wait_until(LIBRARY_WAIT_MS, || {
        !matches!(home.status().status, Status::Loading)
            && !matches!(lib.status().status, LibraryStatus::Loading)
    }) {
        st.problem("flap: a load never ended while offline".into());
    }
    std::thread::sleep(Duration::from_millis(rng.below(60)));
    r.ctl.set_offline(&token, false);
    st.flaps.fetch_add(1, Ordering::Relaxed);
    home.send(HomeIntent::Refresh);
    lib.send(LibraryIntent::Load);
    let ok = wait_until(LIBRARY_WAIT_MS, || {
        matches!(lib.status().status, LibraryStatus::Ready)
            && matches!(home.status().status, Status::Ready)
    });
    if !ok {
        st.problem(format!(
            "flap: no recovery after coming back online (home {:?}, library {:?})",
            home.status().status,
            lib.status().status
        ));
    }
}

struct Counting(Arc<Stats>);

impl swiftly_uniffi::RemoteListener for Counting {
    fn event(&self, event: swiftly_uniffi::RemoteEvent) {
        if matches!(event, swiftly_uniffi::RemoteEvent::ConnectionLost) {
            self.0.ws_lost.fetch_add(1, Ordering::Relaxed);
        }
    }
    fn connected(&self) {
        self.0.ws_connects.fetch_add(1, Ordering::Relaxed);
    }
}

/// A control channel over a real WebSocket that the server keeps dropping: it reconnects, and stopping it ends its tasks.
fn ws_session(r: &Rig, rng: &mut Rng, st: &Arc<Stats>) {
    let link = Arc::new(swiftly_wslink::TungsteniteLink::default());
    let account = account(&r.ws_base, "u4");
    let Ok(channel) = r
        .core
        .remote_channel(account, link, Arc::new(Counting(Arc::clone(st))))
    else {
        return;
    };
    Arc::clone(&channel).start();
    std::thread::sleep(Duration::from_millis(300 + rng.below(4700)));
    channel.stop();
}

/// The stand-in for the main thread: reads the view models it owns every few milliseconds, like a UI frame would.
/// A read that takes longer than the budget is a stall (a lock held across slow work).
fn heartbeat(r: &Rig, st: &Stats, stop: &AtomicBool) {
    let (Ok(home), Ok(lib)) = (
        r.core.home_vm(r.acct.clone(), "de".into()),
        r.core
            .library_vm(r.acct.clone(), "de".into(), library_spec()),
    ) else {
        return;
    };
    home.send(HomeIntent::Load);
    lib.send(LibraryIntent::Load);
    while !stop.load(Ordering::SeqCst) {
        let t0 = Instant::now();
        let _ = (home.status(), home.rails(), lib.status(), lib.grid());
        let ms = t0.elapsed().as_millis() as u64;
        st.max_stall_ms.fetch_max(ms, Ordering::Relaxed);
        st.beats.fetch_add(1, Ordering::Relaxed);
        std::thread::sleep(Duration::from_millis(4));
    }
}

pub struct Report {
    pub verdict: Verdict,
    pub stats: Arc<Stats>,
    pub samples: Vec<Sample>,
}

/// Runs the soak for `cfg.secs`; prints the seed and the samples summary.
pub fn run(cfg: &Config) -> Report {
    println!(
        "soak: seed={} secs={} workers={} big={} (repeat with HARDENING_SOAK_SEED={})",
        cfg.seed, cfg.secs, cfg.workers, cfg.big, cfg.seed
    );
    let r = Arc::new(rig(cfg.big));
    let stats = Arc::new(Stats::default());
    let started = Instant::now();
    let stop = Arc::new(AtomicBool::new(false));
    let sampler = sample::sampler(
        started,
        r.handle.clone(),
        Duration::from_millis(cfg.sample_ms),
        Arc::clone(&stop),
    );
    let deadline = started + Duration::from_secs(cfg.secs);
    let beat_stop = Arc::new(AtomicBool::new(false));
    let beat = {
        let (r, stats, stop) = (Arc::clone(&r), Arc::clone(&stats), Arc::clone(&beat_stop));
        std::thread::spawn(move || heartbeat(&r, &stats, &stop))
    };
    let workers: Vec<_> = (0..cfg.workers)
        .map(|w| {
            let (r, stats) = (Arc::clone(&r), Arc::clone(&stats));
            let seed = cfg.seed.wrapping_add(w as u64);
            std::thread::spawn(move || {
                let mut rng = Rng::new(seed);
                while Instant::now() < deadline {
                    match rng.below(12) {
                        0..=1 => home_session(&r, &mut rng, &stats),
                        2..=4 => library_paging(&r, &mut rng, &stats),
                        5 => search_session(&r, &mut rng, &stats),
                        6 => cancel_storm(&r, &mut rng, &stats),
                        7 => account_switch(&r, &mut rng, &stats),
                        8..=9 => image_churn(&r, &mut rng, &stats),
                        10 => flap_session(&r, &mut rng, &stats, w),
                        _ => ws_session(&r, &mut rng, &stats),
                    }
                }
            })
        })
        .collect();
    for w in workers {
        if w.join().is_err() {
            stats.problem("a worker panicked".into());
        }
    }
    beat_stop.store(true, Ordering::SeqCst);
    let _ = beat.join();
    // Everything dropped: let spawned tasks and image jobs wind down, then take the idle sample.
    r.loader.settle();
    wait_until(4000, || r.handle.metrics().num_alive_tasks() <= 4);
    std::thread::sleep(Duration::from_millis(300));
    let idle = sample::take(started, &r.handle);
    stop.store(true, Ordering::SeqCst);
    let samples = sampler.join().unwrap_or_default();
    let mut verdict = sample::judge(&samples, idle, cfg.rss_mb);
    if let Ok(p) = stats.problems.lock() {
        verdict.problems.extend(p.iter().cloned());
    }
    let stall = stats.max_stall_ms.load(Ordering::Relaxed);
    if stall > cfg.stall_ms {
        verdict.problems.push(format!(
            "heartbeat stalled {stall} ms (budget {} ms)",
            cfg.stall_ms
        ));
    }
    println!("soak: {}", stats.line());
    println!("soak: {}", verdict.summary);
    Report {
        verdict,
        stats,
        samples,
    }
}
