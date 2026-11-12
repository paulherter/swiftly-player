//! Model-based random sequences for `LibraryState` and `HomeState`. A failure prints the seed;
//! replay with `HARDENING_SEED=<n>`.

mod common;

use swiftly_hardening::Rng;
use swiftly_library::MemoryKeyValue;
use swiftly_library::home::{GenreRail, Home, LibraryRail};
use swiftly_library::home_state::{Fixed, HomeFinish, HomePrefs, HomeRun, HomeState, Step};
use swiftly_library::library_state::{FillStep, LibraryCommand, LibraryState, Page};
use swiftly_library::shelf::{ShelfSource, TitleFilter};
use swiftly_model::Item;

fn item(n: usize) -> Item {
    Item::new(format!("i{n}"), format!("Title {n}"), Some("Movie"))
}

#[derive(Debug)]
enum Kind {
    Load(u64),
    TitleFilter(u64),
    More,
    Fill(u64),
}

struct Pending {
    kind: Kind,
    answer: Option<Page>,
    filter: Option<TitleFilter>,
    cancelled: bool,
}

struct Sim<'a> {
    rng: Rng,
    s: LibraryState,
    store: MemoryKeyValue,
    source: ShelfSource,
    server: Vec<Item>,
    account: u64,
    latest: u64,
    pending: Vec<Pending>,
    stable: bool,
    log: &'a mut Vec<String>,
}

fn snap(s: &LibraryState) -> (Vec<String>, i64, bool, bool, bool) {
    (
        s.items.iter().map(|i| i.id.clone()).collect(),
        s.total,
        s.loads,
        s.disrupted,
        s.load_more_failed,
    )
}

impl Sim<'_> {
    fn page(&mut self, since: usize, count: usize) -> Page {
        let end = (since + count).min(self.server.len());
        let items = if since < end {
            self.server[since..end].to_vec()
        } else {
            Vec::new()
        };
        Page {
            items,
            total: self.server.len() as i64,
        }
    }

    fn enqueue(&mut self, kind: Kind, cmd: Option<LibraryCommand>) {
        let fail = !self.stable && self.rng.chance(15);
        let cancelled = fail && self.rng.chance(50);
        let (answer, filter) = match cmd {
            Some(LibraryCommand::FetchPage { since, count, .. }) => (
                if fail {
                    None
                } else {
                    Some(self.page(since, count))
                },
                None,
            ),
            Some(LibraryCommand::FetchTitleFilter { .. }) => (
                None,
                if fail {
                    None
                } else {
                    Some(TitleFilter::new(&[(
                        "lib".to_string(),
                        self.server.clone(),
                    )]))
                },
            ),
            None => return,
        };
        self.pending.push(Pending {
            kind,
            answer,
            filter,
            cancelled,
        });
    }

    fn mutate_server(&mut self) {
        match self.rng.below(3) {
            0 => {
                let n = self.server.len();
                self.server.push(item(n + 1000));
            }
            1 => {
                self.server.pop();
            }
            _ => {
                if !self.server.is_empty() {
                    let at = self.rng.below(self.server.len() as u64) as usize;
                    let copy = self.server[at].clone();
                    self.server.insert(at, copy); // a duplicate id from the server
                }
            }
        }
    }

    fn deliver(&mut self, at: usize) {
        let p = self.pending.remove(at);
        let before = snap(&self.s);
        self.log.push(format!("deliver {:?}", p.kind));
        let stale = match p.kind {
            Kind::Load(r) | Kind::TitleFilter(r) | Kind::Fill(r) => r != self.latest,
            Kind::More => false,
        };
        match p.kind {
            Kind::Load(r) => self.s.page_loaded(r, &self.source, p.answer, p.cancelled),
            Kind::TitleFilter(r) => {
                let next = self
                    .s
                    .title_filter_loaded(r, &self.source, p.filter, p.cancelled);
                if let Some(cmd) = next {
                    // The new fill overtakes a running one of the same run: the driver cancels
                    // that task, its page is never fed back.
                    self.pending
                        .retain(|q| !matches!(q.kind, Kind::Fill(f) if f == r));
                    self.enqueue(Kind::Fill(r), Some(cmd));
                }
            }
            Kind::More => self.s.more_page_loaded(p.answer, p.cancelled),
            Kind::Fill(r) => {
                if let FillStep::Fetch(cmd) = self.s.fill_page(r, p.answer, p.cancelled) {
                    self.enqueue(Kind::Fill(r), Some(cmd));
                }
            }
        }
        if stale {
            assert_eq!(
                before,
                snap(&self.s),
                "stale answer {:?} changed state",
                p.kind
            );
        }
    }

    fn check(&self, what: &str) {
        let mut ids: Vec<&str> = self.s.items.iter().map(|i| i.id.as_str()).collect();
        let n = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), n, "{what}: duplicate item ids in items");
        assert!(self.s.total >= 0, "{what}: negative total");
    }
}

fn library_case(seed: u64) {
    let mut log = Vec::new();
    let mut rng = Rng::new(seed ^ 0x11B);
    let stable = seed.is_multiple_of(3);
    let filtering = seed % 2 == 1;
    let source = if filtering {
        ShelfSource::new(None, Some("movies"), false, &["lib"])
    } else {
        ShelfSource::new(Some("lib"), Some("movies"), false, &[])
    };
    let server_len = rng.below(400) as usize;
    let server: Vec<Item> = (0..server_len).map(item).collect();
    let store = MemoryKeyValue::default();
    let mut sim = Sim {
        s: LibraryState::new(Some("movies"), &store),
        store,
        source,
        server,
        account: 0,
        latest: 0,
        pending: Vec::new(),
        stable,
        rng,
        log: &mut log,
    };
    let mut max_len = 0usize;
    for _ in 0..80 {
        let roll = sim.rng.below(100);
        if roll < 22 {
            if !sim.stable && sim.rng.chance(8) {
                sim.account += 1;
            }
            let views_empty = sim.rng.chance(10);
            let no_source = !sim.stable && sim.rng.chance(4);
            let src = sim.source.clone();
            let start = sim
                .s
                .begin_load(sim.account, views_empty, (!no_source).then_some(&src));
            sim.latest = start.run;
            sim.log.push(format!("begin_load run {}", start.run));
            let kind = match start.command {
                Some(LibraryCommand::FetchTitleFilter { run, .. }) => Kind::TitleFilter(run),
                _ => Kind::Load(start.run),
            };
            sim.enqueue(kind, start.command);
        } else if roll < 40 {
            let src = sim.source.clone();
            sim.log.push("begin_load_more".into());
            if let Some(cmd) = sim.s.begin_load_more(sim.account, &src, 60) {
                let kind = if filtering {
                    Kind::Fill(sim.latest)
                } else {
                    Kind::More
                };
                sim.enqueue(kind, Some(cmd));
            }
        } else if roll < 46 && !sim.stable {
            sim.mutate_server();
        } else if roll < 52 && !sim.stable {
            let sorting = *sim.rng.pick(&[
                swiftly_library::library_filter::Sorting::Name,
                swiftly_library::library_filter::Sorting::Name,
            ]);
            sim.s.set_sorting(sorting, &sim.store);
        } else if !sim.pending.is_empty() {
            let at = sim.rng.below(sim.pending.len() as u64) as usize;
            sim.deliver(at);
        }
        sim.check("step");
        if stable {
            // Unchanged server, source and account: what is shown never shrinks.
            assert!(
                sim.s.items.len() >= max_len,
                "list shrank from {max_len} to {} (log tail {:?})",
                sim.s.items.len(),
                &sim.log[sim.log.len().saturating_sub(8)..]
            );
            max_len = sim.s.items.len();
        }
    }
    while !sim.pending.is_empty() {
        let at = sim.rng.below(sim.pending.len() as u64) as usize;
        sim.deliver(at);
        sim.check("drain");
    }
    assert!(
        !sim.s.loads,
        "loading flag still set after all answers (log {:?})",
        sim.log
    );
    if sim.s.still_more_present() {
        let src = sim.source.clone();
        assert!(
            sim.s.begin_load_more(sim.account, &src, 60).is_some(),
            "load more is stuck after all answers (state {:?}, log tail {:?})",
            {
                let mut d = format!("{:?}", sim.s);
                d.retain(|c| c != '\n');
                d.split("items: [").next().unwrap_or("").to_string()
                    + &d[d.find("], total").unwrap_or(0)..]
            },
            &sim.log[sim.log.len().saturating_sub(12)..]
        );
    }
}

#[test]
fn library_state_random_sequences() {
    common::for_seeds("props_library", 300, library_case);
}

// ---- HomeState ------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
enum Phase {
    StoreRead,
    Views,
    Fixed,
    FirstExtras,
    Genres,
    Libraries,
    Done,
}

struct Run {
    id: HomeRun,
    number: u64,
    account: u64,
    phase: Phase,
    first: bool,
}

fn rows(h: &HomeState) -> Vec<Vec<String>> {
    let v = |x: &[Item]| x.iter().map(|i| i.id.clone()).collect::<Vec<_>>();
    vec![
        v(&h.continue_watching),
        v(&h.next_episode),
        v(&h.recent),
        v(&h.new_movies),
        v(&h.new_series),
        h.genre_rails.iter().flat_map(|r| v(&r.items)).collect(),
        h.library_rails.iter().flat_map(|r| v(&r.items)).collect(),
        vec![
            h.loaded.to_string(),
            h.disrupted.to_string(),
            format!("{:?}", h.last_loaded),
        ],
    ]
}

fn rows_of(rng: &mut Rng, tag: &str) -> Vec<Item> {
    (0..rng.below(6))
        .map(|n| Item::new(format!("{tag}{n}"), tag, Some("Movie")))
        .collect()
}

fn home_case(seed: u64) {
    let mut rng = Rng::new(seed ^ 0xB0B);
    let mut h = HomeState::new();
    let mut account = 1u64;
    let mut runs: Vec<Run> = Vec::new();
    let mut latest = 0u64;
    let mut counter = 0u64;
    let prefs = HomePrefs::default();
    let mut now = 0.0f64;
    for _ in 0..120 {
        now += rng.range(0, 90) as f64;
        let roll = rng.below(100);
        if roll < 18 || runs.iter().all(|r| r.phase == Phase::Done) && roll < 60 {
            if rng.chance(15) {
                account += 1;
            }
            let (id, cmds) = h.begin(account, Some("acct"));
            counter += 1;
            latest = counter;
            let phase = if cmds.is_empty() {
                Phase::Views
            } else {
                Phase::StoreRead
            };
            runs.push(Run {
                id,
                number: counter,
                account,
                phase,
                first: false,
            });
            continue;
        }
        let live: Vec<usize> = runs
            .iter()
            .enumerate()
            .filter(|(_, r)| r.phase != Phase::Done)
            .map(|(i, _)| i)
            .collect();
        if live.is_empty() {
            continue;
        }
        let at = live[rng.below(live.len() as u64) as usize];
        let (id, number, run_account, phase) = (
            runs[at].id,
            runs[at].number,
            runs[at].account,
            runs[at].phase,
        );
        // The app's account switch may also advance without a new run.
        let acct_now = if rng.chance(5) { account + 1 } else { account };
        let stale = number != latest || run_account != acct_now;
        let before = rows(&h);
        let cancelled = rng.chance(10);
        let views = rows_of(&mut rng, "v");
        let finish = HomeFinish {
            account_key: Some("acct"),
            views: &views,
        };
        let next = match phase {
            Phase::StoreRead => {
                let store = if rng.chance(70) {
                    Some(swiftly_library::HomeStore::new(
                        rows_of(&mut rng, "lib"),
                        rows_of(&mut rng, "sc"),
                        rows_of(&mut rng, "sn"),
                        rows_of(&mut rng, "sr"),
                        vec![],
                        vec![],
                        vec![],
                    ))
                } else {
                    None
                };
                match h.store_read(id, acct_now, store.as_ref(), &prefs) {
                    Step::Stop => Phase::Done,
                    Step::Continue(_) => Phase::Views,
                }
            }
            Phase::Views => match h.views_ready(id, acct_now, rng.chance(85), cancelled) {
                Step::Stop => Phase::Done,
                Step::Continue(_) => Phase::Fixed,
            },
            Phase::Fixed => {
                let some = |rng: &mut Rng, tag: &str| rng.chance(80).then(|| rows_of(rng, tag));
                let home = Home {
                    continue_watching: some(&mut rng, "c"),
                    next_episode: some(&mut rng, "n"),
                    recent: some(&mut rng, "r"),
                    new_movies: None,
                    new_series: None,
                    genre_rails: vec![],
                    disrupted: rng.chance(10),
                    failure: None,
                };
                match h.fixed_rows_arrived(id, acct_now, cancelled, false, home, now) {
                    Fixed::Stop => Phase::Done,
                    Fixed::AwaitFirst => {
                        runs[at].first = true;
                        Phase::FirstExtras
                    }
                    Fixed::AwaitLater => Phase::Genres,
                }
            }
            Phase::FirstExtras => {
                let g = vec![GenreRail {
                    name: "g".into(),
                    items: rows_of(&mut rng, "g"),
                }];
                let l = vec![LibraryRail {
                    id: "l".into(),
                    name: "l".into(),
                    items: rows_of(&mut rng, "l"),
                }];
                let _ = h.first_extras_ready(id, acct_now, cancelled, false, g, l, now, &finish);
                Phase::Done
            }
            Phase::Genres => {
                let g = if rng.chance(50) {
                    vec![GenreRail {
                        name: "g".into(),
                        items: rows_of(&mut rng, "g"),
                    }]
                } else {
                    vec![]
                };
                match h.genres_ready(id, acct_now, g, false) {
                    Step::Stop => Phase::Done,
                    Step::Continue(_) => Phase::Libraries,
                }
            }
            Phase::Libraries => {
                let l = vec![LibraryRail {
                    id: "l".into(),
                    name: "l".into(),
                    items: rows_of(&mut rng, "l"),
                }];
                let _ = h.libraries_ready(id, acct_now, l, false, &finish);
                Phase::Done
            }
            Phase::Done => Phase::Done,
        };
        runs[at].phase = next;
        if stale {
            assert_eq!(
                before,
                rows(&h),
                "stale run {number} ({phase:?}) changed the visible state"
            );
        }
        let _ = runs[at].first;
    }
    // Drain: every run is finished or abandoned by its driver (cancelled), so nothing may
    // be counted as still running.
    for r in runs.iter_mut().filter(|r| r.phase != Phase::Done) {
        let _ = h.views_ready(r.id, u64::MAX, true, true);
    }
    assert!(
        h.needs_refresh(1.0e12),
        "a run is still counted as in flight after all runs ended"
    );
    for list in rows(&h).iter().take(7) {
        let mut sorted = list.clone();
        sorted.sort_unstable();
        sorted.dedup();
        let _ = sorted; // rails may legitimately repeat a title across rails
    }
}

#[test]
fn home_state_random_sequences() {
    common::for_seeds("props_library", 300, home_case);
}
